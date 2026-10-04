#!/usr/bin/env bats
# Services this user cannot ask runsv about (issue #1). runsv makes
# supervise/ 0700 and supervise/ok 0600, so a regular user pointed at
# root's tree gets "access denied" from sv for every service. sv-helper
# says why, names the account that can, and fails - it never runs sudo
# itself.
#
# Root ignores permissions, so this is simulated as a regular user with a
# supervise/ it cannot search, owned by itself, and skipped as root.

setup() {
    load 'test_helper/common'
    load 'test_helper/sv'
    common_setup
    [ "$(id -u)" -ne 0 ] || skip "root can read any supervise directory"

    ME=$(id -un)
    TREE="$TEST_TMP/service"
    BIN="$TEST_TMP/bin"
    mkdir -p "$TREE/locked/supervise" "$TREE/open" "$BIN"
    chmod 000 "$TREE/locked/supervise"

    local name
    for name in svls sv-start
    do
        ln -s "$REPO_ROOT/sv-helper.sh" "$BIN/$name"
    done
}

teardown() {
    chmod -R u+rwx "$TEST_TMP" 2>/dev/null || true
}

@test "svls lists what it can and sums up what it cannot" {
    run -13 env SVDIR="$TREE" "$BIN/svls"
    # The service runsv has not started is still reported, by sv itself.
    assert_output --partial "$TREE/open:"
    assert_output --partial "Cannot ask runsv about 1 service(s) in $TREE as $ME"
    assert_output --partial "Run it as $ME instead: sudo -u $ME env SVDIR=$TREE svls"
    refute_output --partial "access denied"
}

@test "svls on one service names the supervise directory and repeats the command" {
    run -13 env SVDIR="$TREE" "$BIN/svls" locked
    assert_output --partial "$TREE/locked/supervise belongs to $ME"
    assert_output --partial "sudo -u $ME env SVDIR=$TREE svls locked"
}

@test "controlling a service is refused the same way" {
    run -13 env SVDIR="$TREE" "$BIN/sv-start" locked
    assert_output --partial "sudo -u $ME env SVDIR=$TREE sv-start locked"
}

@test "through sv-helper, the hint repeats the subcommand, not a bare ls" {
    run -13 env SVDIR="$TREE" "$REPO_ROOT/sv-helper.sh" ls
    assert_output --partial "env SVDIR=$TREE sv-helper.sh ls"
}

@test "an ok fifo this user cannot write is a refusal too" {
    chmod 700 "$TREE/locked/supervise"
    : > "$TREE/locked/supervise/ok"
    chmod 000 "$TREE/locked/supervise/ok"

    run -13 env SVDIR="$TREE" "$BIN/svls" locked
    assert_output --partial "Cannot ask runsv about locked"
}

@test "a tree with nothing refused still exits 0" {
    rmdir "$TREE/locked/supervise"
    run env SVDIR="$TREE" "$BIN/svls"
    assert_success
    refute_output --partial "Cannot ask runsv"
}
