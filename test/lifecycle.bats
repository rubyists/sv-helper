#!/usr/bin/env bats
# A regular user's whole service lifecycle against a real runsvdir:
# install, define, enable, supervise, inspect, stop, start, restart, log,
# disable. Nothing here runs as root and nothing escalates.
#
# One supervision tree is shared by the file, because starting and
# stopping runsvdir per test would cost more than it proves.

setup_file() {
    load 'test_helper/common'
    load 'test_helper/sv'

    REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd -P)
    export REPO_ROOT

    for tool in runsvdir runsv sv svlogd
    do
        if ! command -v "$tool" >/dev/null 2>&1
        then
            export LIFECYCLE_SKIP="runit is not installed ($tool missing)"
            return 0
        fi
    done

    # Not $BATS_TEST_TMPDIR: this has to outlive a single test.
    export LIFE_HOME="${BATS_FILE_TMPDIR}/a home"
    export BIN="${BATS_FILE_TMPDIR}/bin"
    export SVDIR_PATH="$(expected_svdir "$LIFE_HOME")"
    export DEFS="$(expected_defs_dir "$LIFE_HOME")/ticker"
    export LOGDIR="$(expected_log_dir "$LIFE_HOME")/ticker"
    mkdir -p "$LIFE_HOME" "$BIN"

    # The commands, linked straight out of the checkout rather than
    # installed: this suite is about what the scripts do, and nothing
    # here should fail because installation is broken. The aliases are
    # relative links to sv-helper, which is how it learns which command
    # it was asked to be.
    ln -s "$REPO_ROOT/sv-helper.sh" "$BIN/sv-helper"
    ln -s "$REPO_ROOT/rsvlog.sh" "$BIN/rsvlog"
    ln -s "$REPO_ROOT/runsvdir.sh" "$BIN/runsvdir.sh"
    for name in sv-start sv-stop sv-restart sv-list svls sv-enable sv-disable sv-find
    do
        ln -s sv-helper "$BIN/$name"
    done

    mkdir -p "$DEFS/log"
    cat > "$DEFS/run" <<'RUN'
#!/bin/sh
exec 2>&1
while true
do
	echo "tick"
	sleep 1
done
RUN
    chmod +x "$DEFS/run"
    ln -s "$BIN/rsvlog" "$DEFS/log/run"

    as_user "$LIFE_HOME" "$BIN/sv-enable" ticker >/dev/null 2>&1

    # 3>&- is not optional: bats reads its own output on fd 3, and a
    # background process that inherits it keeps that pipe open forever,
    # so the run hangs after the last test instead of finishing.
    as_user "$LIFE_HOME" "$BIN/runsvdir.sh" \
        > "$BATS_FILE_TMPDIR/runsvdir.log" 2>&1 3>&- &
    sleep 3
}

teardown_file() {
    load 'test_helper/sv'
    stop_supervision_tree "$SVDIR_PATH"
    # On macOS these live in the shared Homebrew prefix, so they do not
    # disappear along with $BATS_FILE_TMPDIR.
    rm -rf "${DEFS:?}" "${LOGDIR:?}" 2>/dev/null || true
}

setup() {
    load 'test_helper/common'
    load 'test_helper/sv'
    common_setup
    [ -z "${LIFECYCLE_SKIP:-}" ] || skip "$LIFECYCLE_SKIP"
}

status_of() {
    as_user "$LIFE_HOME" "$BIN/svls" ticker 2>&1
}

@test "sv-list finds the user's own definition" {
    run as_user "$LIFE_HOME" "$BIN/sv-list"
    assert_success
    assert_output --partial "ticker"
}

@test "enable linked the definition into the user's own tree" {
    assert [ -L "$SVDIR_PATH/ticker" ]
    assert_equal "$(readlink "$SVDIR_PATH/ticker")" "$DEFS"
}

@test "runsvdir.sh supervises the user's own tree" {
    run grep -F "Starting runsvdir in $SVDIR_PATH" "$BATS_FILE_TMPDIR/runsvdir.log"
    assert_success
}

@test "svls reports the service running" {
    run status_of
    assert_success
    assert_output --regexp '^run: '
}

@test "sv-stop stops it and sv-start brings it back" {
    as_user "$LIFE_HOME" "$BIN/sv-stop" ticker >/dev/null 2>&1
    sleep 1
    run status_of
    assert_output --regexp '^down: '

    as_user "$LIFE_HOME" "$BIN/sv-start" ticker >/dev/null 2>&1
    sleep 1
    run status_of
    assert_output --regexp '^run: '
}

@test "sv-restart replaces the running process" {
    local before after
    before=$(status_of | service_pid)
    as_user "$LIFE_HOME" "$BIN/sv-restart" ticker >/dev/null 2>&1
    sleep 2
    after=$(status_of | service_pid)

    refute [ -z "$before" ]
    refute [ -z "$after" ]
    refute [ "$before" = "$after" ]
}

@test "logs land in the user's own log directory" {
    assert [ -s "$LOGDIR/current" ]
}

@test "the log is owned by the invoking user, with no chown or sudo" {
    local owner
    owner=$(stat -c '%U' "$LOGDIR/current" 2>/dev/null || stat -f '%Su' "$LOGDIR/current")
    assert_equal "$owner" "$(id -un)"
}

@test "sv-disable removes the link from the tree" {
    # Last on purpose: the tree is shared by the file, and re-enabling
    # afterwards would race runsvdir's own scan of it.
    as_user "$LIFE_HOME" "$BIN/sv-disable" ticker >/dev/null 2>&1
    refute [ -e "$SVDIR_PATH/ticker" ]
}
