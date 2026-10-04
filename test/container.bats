#!/usr/bin/env bats
# The root-container runit lifecycle, against a real container: runit as
# PID 1, a supervised service, a service that crashes and is restarted,
# logs written through rsvlog, and - the part actually worth testing - a
# shutdown that goes through stage 3 and ends with the container exiting
# on its own, rather than being killed when the runtime gives up.
#
# One container is shared by the file. The shutdown happens in its own
# test near the end; the tests after it read what that left behind.

CONTAINER_IMAGE=sv-helper-container-test
CONTAINER_NAME=sv-helper-container-test
STOP_TIMEOUT=30

container_engine() {
    local candidate
    for candidate in podman docker; do
        if command -v "$candidate" >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

setup_file() {
    REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd -P)
    export REPO_ROOT

    if ! ENGINE=$(container_engine); then
        export CONTAINER_SKIP="neither podman nor docker is installed"
        return 0
    fi
    export ENGINE

    "$ENGINE" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    "$ENGINE" build -q -f "$REPO_ROOT/container/Containerfile" \
        -t "$CONTAINER_IMAGE" "$REPO_ROOT" >/dev/null

    # SYS_BOOT is what lets runit's final reboot(2) end the PID namespace,
    # so the container exits by itself. Without it everything up to and
    # including stage 3 still works, but the runtime has to kill the
    # container afterwards. See container/Readme.md.
    "$ENGINE" run -d --cap-add SYS_BOOT --name "$CONTAINER_NAME" \
        "$CONTAINER_IMAGE" >/dev/null
    sleep 6
}

teardown_file() {
    [ -n "${ENGINE:-}" ] || return 0
    "$ENGINE" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}

setup() {
    load 'test_helper/common'
    load 'test_helper/sv'
    common_setup
    [ -z "${CONTAINER_SKIP:-}" ] || skip "$CONTAINER_SKIP"
}

in_container() {
    "$ENGINE" exec "$CONTAINER_NAME" "$@"
}

@test "runit boots through stage 1 into stage 2" {
    run "$ENGINE" logs "$CONTAINER_NAME"
    assert_success
    assert_output --partial "enter stage: /etc/runit/1"
    assert_output --partial "enter stage: /etc/runit/2"
}

@test "the hello service is supervised" {
    run in_container svls
    assert_success
    assert_output --regexp 'run: .*/hello:'
}

@test "an explicit SVDIR is the tree that gets supervised" {
    # The Containerfile sets SVDIR=/etc/service. Quietly supervising
    # /service instead would leave every `sv` command pointing somewhere
    # the services are not.
    run "$ENGINE" logs "$CONTAINER_NAME"
    assert_output --partial "Starting runsvdir in /etc/service"
}

@test "sv-enable works inside the container" {
    run in_container sv-enable crasher
    assert_success
    sleep 3
}

@test "a crashing service is restarted" {
    # crasher exits about once a second, so a single sample can easily
    # catch it while it is down and see no pid at all. Sample across
    # several restarts and count the distinct pids runsv handed out.
    local pids="" pid i=0
    while [ "$i" -lt 12 ]; do
        pid=$(in_container svls crasher 2>/dev/null | service_pid)
        case " $pids " in
            *" $pid "*) ;;
            *) [ -n "$pid" ] && pids="$pids $pid" ;;
        esac
        i=$((i + 1))
        sleep 1
    done

    assert [ "$(echo "$pids" | wc -w)" -ge 2 ]
}

@test "PID 1 reaps the children the crash loop leaves behind" {
    local zombies
    zombies=$(in_container sh -c "ps -o stat= -A | grep -c '^Z' || true")
    assert_equal "${zombies:-0}" "0"
}

@test "rsvlog is writing the service's log" {
    run in_container test -s /var/log/hello/current
    assert_success
}

@test "stopping the container runs stage 3 and exits before the timeout" {
    local before start elapsed
    before=$(in_container sh -c 'wc -l < /var/log/hello/current' | tr -d ' ')
    echo "$before" > "$BATS_FILE_TMPDIR/lines-before"

    start=$(date +%s)
    "$ENGINE" stop -t "$STOP_TIMEOUT" "$CONTAINER_NAME" >/dev/null 2>&1 || true
    elapsed=$(($(date +%s) - start))

    assert_equal "$("$ENGINE" inspect "$CONTAINER_NAME" --format '{{.State.Status}}')" "exited"
    # Reaching the timeout means the runtime killed it, which is the
    # failure this whole shutdown path exists to avoid.
    assert [ "$elapsed" -lt "$STOP_TIMEOUT" ]
}

@test "stage 3 ran to completion" {
    run "$ENGINE" logs "$CONTAINER_NAME"
    assert_output --partial "enter stage: /etc/runit/3"
    assert_output --partial "stage 3: stopping services"
    assert_output --partial "stage 3: letting log services finish"
    assert_output --partial "stage 3: done"
}

@test "the log survived shutdown" {
    local before after
    before=$(cat "$BATS_FILE_TMPDIR/lines-before")
    "$ENGINE" cp "$CONTAINER_NAME:/var/log/hello/current" "$TEST_TMP/current"
    after=$(wc -l < "$TEST_TMP/current" | tr -d ' ')

    # svlogd only flushes when its stdin closes, which is what stage 3's
    # second sweep is for. A truncated file here means the logs were cut
    # off mid-shutdown.
    assert [ "$after" -gt 0 ]
    assert [ "$after" -ge "$before" ]
}
