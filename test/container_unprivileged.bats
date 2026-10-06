#!/usr/bin/env bats
# The runit lifecycle in a container that never runs as root: runit as
# PID 1 under a regular UID, services and logs in that user's own default
# paths, and a shutdown that goes through stage 3 and ends with the
# container exiting on its own.
#
# Three containers from one image, started together:
#
#   USER_NAME       the image's own user, UID 1000. The whole lifecycle.
#   ARBITRARY_NAME  a UID the image has never heard of, with GID 0, as
#                   OpenShift assigns them. Owns nothing in the image.
#   NOGROUP_NAME    a UID without GID 0, which cannot write the state the
#                   image prepared. Stage 1 has to refuse to boot, and the
#                   container still has to exit by itself.
#   HOSTNAME_NAME   the image's user, with its tree chosen by SV_ROOT and
#                   hostname. Stage 3 and sv-helper have to act on that
#                   tree, which neither of them could work out alone.

IMAGE=sv-helper-unprivileged-test
USER_NAME=sv-helper-unprivileged-test
ARBITRARY_NAME=sv-helper-unprivileged-test-arbitrary
NOGROUP_NAME=sv-helper-unprivileged-test-nogroup
HOSTNAME_NAME=sv-helper-unprivileged-test-hostname
# Inside rootless podman's usual 65536 subordinate IDs, so the test runs
# without any host configuration.
ARBITRARY_UID=54321
STOP_TIMEOUT=30
USER_HOME=/home/sv
USER_SVDIR=$USER_HOME/.local/state/sv-helper/service
USER_LOG=$USER_HOME/.local/state/sv-helper/log/hello/current
# web-<replicaset>-<pod>, as Kubernetes names a Deployment's pods. Two
# trailing components come off, leaving "web".
HOSTNAME_HOST=web-7f9c4-x2k
HOSTNAME_ROOT=$USER_HOME/app
HOSTNAME_SVDIR=$HOSTNAME_ROOT/service/web

setup_file() {
    load 'test_helper/container'
    REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd -P)
    export REPO_ROOT

    if ! ENGINE=$(container_engine)
    then
        export CONTAINER_SKIP="neither podman nor docker is installed"
        return 0
    fi
    export ENGINE

    "$ENGINE" rm -f "$USER_NAME" "$ARBITRARY_NAME" "$NOGROUP_NAME" "$HOSTNAME_NAME" >/dev/null 2>&1 || true
    "$ENGINE" build -q -f "$REPO_ROOT/container/Containerfile.unprivileged" \
        -t "$IMAGE" "$REPO_ROOT" >/dev/null

    # SYS_BOOT is only for runit's final reboot(2), exactly as in the root
    # container. For a nonzero UID the runtime puts it in the ambient set.
    # See container/Readme.md.
    "$ENGINE" run -d --cap-add SYS_BOOT --name "$USER_NAME" "$IMAGE" >/dev/null
    "$ENGINE" run -d --cap-add SYS_BOOT --user "$ARBITRARY_UID:0" \
        --name "$ARBITRARY_NAME" "$IMAGE" >/dev/null
    "$ENGINE" run -d --cap-add SYS_BOOT --user "$ARBITRARY_UID:$ARBITRARY_UID" \
        --name "$NOGROUP_NAME" "$IMAGE" >/dev/null
    # The tree is made at boot, then runit takes over as PID 1 through exec.
    "$ENGINE" run -d --cap-add SYS_BOOT --hostname "$HOSTNAME_HOST" \
        -e "SV_ROOT=$HOSTNAME_ROOT" --name "$HOSTNAME_NAME" "$IMAGE" \
        sh -c "mkdir -p $HOSTNAME_SVDIR && ln -s $USER_HOME/.config/sv-helper/sv/hello $HOSTNAME_SVDIR/hello && exec /usr/sbin/runit" \
        >/dev/null
    sleep 6
}

teardown_file() {
    [ -n "${ENGINE:-}" ] || return 0
    "$ENGINE" rm -f "$USER_NAME" "$ARBITRARY_NAME" "$NOGROUP_NAME" "$HOSTNAME_NAME" >/dev/null 2>&1 || true
}

setup() {
    load 'test_helper/common'
    load 'test_helper/container'
    load 'test_helper/sv'
    common_setup
    [ -z "${CONTAINER_SKIP:-}" ] || skip "$CONTAINER_SKIP"
}

# Stop a container and fail unless it exited by itself, through stage 3,
# before the runtime gave up on it and killed it.
assert_stops_cleanly() {
    local name="$1" start elapsed
    start=$(date +%s)
    "$ENGINE" stop -t "$STOP_TIMEOUT" "$name" >/dev/null 2>&1 || true
    elapsed=$(($(date +%s) - start))

    assert_equal "$("$ENGINE" inspect "$name" --format '{{.State.Status}}')" "exited"
    assert [ "$elapsed" -lt "$STOP_TIMEOUT" ]

    run "$ENGINE" logs "$name"
    assert_output --partial "stage 3: done"
    assert_output --partial "runit: power off"
}

@test "runit boots through stage 1 into stage 2 as uid 1000" {
    run "$ENGINE" logs "$USER_NAME"
    assert_success
    assert_output --partial "stage 1: preparing the container as uid 1000"
    assert_output --partial "enter stage: /etc/runit/2"
}

@test "nothing in the container runs as root" {
    run container_uids "$USER_NAME"
    assert_success
    assert_output "1000 1000 1000 1000"
}

@test "stage 2 supervises the user's own default tree" {
    run "$ENGINE" logs "$USER_NAME"
    assert_output --partial "Starting runsvdir in $USER_SVDIR"

    run "$ENGINE" exec "$USER_NAME" svls
    assert_success
    assert_output --regexp "run: $USER_SVDIR/hello:"
}

@test "runit's control files live in /run/runit and belong to the user" {
    run "$ENGINE" exec "$USER_NAME" readlink /etc/runit/stopit
    assert_success
    assert_output /run/runit/stopit

    run "$ENGINE" exec "$USER_NAME" stat -c %u /run/runit/stopit
    assert_success
    assert_output 1000
}

@test "sv-enable works as the user, and a crashing service is restarted" {
    run "$ENGINE" exec "$USER_NAME" sv-enable crasher
    assert_success

    # runsvdir picks a new service up on its next scan, within five
    # seconds. Then sample across several restarts and count the distinct
    # pids runsv handed out, as container.bats does.
    sleep 6
    local i=0
    while [ "$i" -lt 12 ]
    do
        "$ENGINE" exec "$USER_NAME" svls crasher 2>/dev/null | service_pid >>"$TEST_TMP/pids"
        i=$((i + 1))
        sleep 1
    done

    assert [ "$(sort -u "$TEST_TMP/pids" | grep -c .)" -ge 2 ]
}

@test "rsvlog is writing the user's log" {
    run "$ENGINE" exec "$USER_NAME" test -s "$USER_LOG"
    assert_success
}

@test "stopping the user's container runs stage 3 and exits before the timeout" {
    local before after
    before=$("$ENGINE" exec "$USER_NAME" sh -c "wc -l < $USER_LOG" | tr -d ' ')

    assert_stops_cleanly "$USER_NAME"

    "$ENGINE" cp "$USER_NAME:$USER_LOG" "$TEST_TMP/current"
    after=$(wc -l < "$TEST_TMP/current" | tr -d ' ')
    assert [ "$after" -ge "$before" ]
}

@test "an arbitrary uid with gid 0 boots and supervises from the same image" {
    run container_uids "$ARBITRARY_NAME"
    assert_success
    assert_output "$ARBITRARY_UID $ARBITRARY_UID $ARBITRARY_UID $ARBITRARY_UID"

    run "$ENGINE" exec "$ARBITRARY_NAME" svls
    assert_success
    assert_output --regexp "run: $USER_SVDIR/hello:"

    run "$ENGINE" exec "$ARBITRARY_NAME" test -s "$USER_LOG"
    assert_success
}

@test "an arbitrary uid with gid 0 stops cleanly through stage 3" {
    assert_stops_cleanly "$ARBITRARY_NAME"
}

@test "without write access to its state, stage 1 refuses to boot and the container exits" {
    # Stage 1 exits 100, runit skips stage 2 and goes straight to stage 3,
    # and the container ends on its own - no stop request, no kill.
    local waited=0
    while [ "$("$ENGINE" inspect "$NOGROUP_NAME" --format '{{.State.Status}}')" != exited ] &&
        [ "$waited" -lt "$STOP_TIMEOUT" ]
    do
        sleep 1
        waited=$((waited + 1))
    done

    run "$ENGINE" logs "$NOGROUP_NAME"
    assert_output --partial "stage 1: /run/runit is not writable by uid $ARBITRARY_UID"
    refute_output --partial "enter stage: /etc/runit/2"
    assert_output --partial "stage 3: done"
    assert_equal "$("$ENGINE" inspect "$NOGROUP_NAME" --format '{{.State.Status}}')" "exited"
}

@test "a tree chosen by SV_ROOT and hostname is what stage 2 supervises" {
    run "$ENGINE" logs "$HOSTNAME_NAME"
    assert_output --partial "Starting runsvdir in $HOSTNAME_SVDIR"

    run "$ENGINE" exec "$HOSTNAME_NAME" cat /run/runit/svdir
    assert_success
    assert_output "$HOSTNAME_SVDIR"
}

@test "sv-helper manages the tree stage 2 chose by hostname" {
    # Without SV_ROOT's rules of its own, sv-helper would list the user's
    # default tree, which holds a hello that nothing is supervising.
    run "$ENGINE" exec "$HOSTNAME_NAME" svls
    assert_success
    assert_output --regexp "run: $HOSTNAME_SVDIR/hello:"
}

@test "stage 3 stops the tree stage 2 chose by hostname" {
    local log=$USER_HOME/.local/state/sv-helper/log/hello/current before after
    before=$("$ENGINE" exec "$HOSTNAME_NAME" sh -c "wc -l < $log" | tr -d ' ')

    assert_stops_cleanly "$HOSTNAME_NAME"

    run "$ENGINE" logs "$HOSTNAME_NAME"
    assert_output --partial "stage 3: stopping services in $HOSTNAME_SVDIR (recorded by stage 2"
    assert_output --partial "stage 3: letting log services finish"

    "$ENGINE" cp "$HOSTNAME_NAME:$log" "$TEST_TMP/current"
    after=$(wc -l < "$TEST_TMP/current" | tr -d ' ')
    assert [ "$after" -ge "$before" ]
}
