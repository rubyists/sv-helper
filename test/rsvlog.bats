#!/usr/bin/env bats
# rsvlog, the generic log/run script. It ends in `exec svlogd`, so these
# tests put a stub svlogd (and logger, and chpst) at the front of PATH:
# each one prints how it was called and exits, which is exactly the
# decision under test. Nothing here starts a real logger.

setup() {
    load 'test_helper/common'
    load 'test_helper/sv'
    common_setup

    HOME_DIR="$TEST_TMP/a home"
    mkdir -p "$HOME_DIR"

    # A service directory with a log/ in it, which is the only place
    # rsvlog agrees to run.
    SERVICE="$TEST_TMP/sv/ticker"
    LOGDIR="$SERVICE/log"
    mkdir -p "$LOGDIR"
    ln -s "$REPO_ROOT/rsvlog.sh" "$LOGDIR/run"

    STUBS="$TEST_TMP/stubs"
    mkdir -p "$STUBS"
    for tool in svlogd logger chpst; do
        {
            echo '#!/bin/sh'
            echo "echo \"STUB-$tool \$*\""
        } > "$STUBS/$tool"
        chmod +x "$STUBS/$tool"
    done
}

# Run rsvlog the way runsv does: as ./run, from inside the log directory.
run_rsvlog() {
    cd "$LOGDIR" || return 1
    as_user "$HOME_DIR" env "PATH=$STUBS:$PATH" "$@" ./run
}

default_log_base() {
    expected_log_dir "$HOME_DIR"
}

@test "refuses to run under any name but ./run" {
    cd "$LOGDIR"
    cp "$REPO_ROOT/rsvlog.sh" ./notrun
    chmod +x ./notrun
    run ./notrun
    assert_failure
    assert_output --partial "meant to be linked as ./run"
}

@test "refuses to run outside a log directory" {
    cd "$SERVICE"
    ln -s "$REPO_ROOT/rsvlog.sh" ./run
    run ./run
    assert_failure
    assert_output --partial "service/log directory only"
}

@test "SV_LOG_SYSLOG hands off to logger and ignores everything else" {
    echo 'SV_LOG_SYSLOG=true' > "$LOGDIR/conf"
    echo 'SV_LOG_SYSLOG_PRIORITY=local7.info' >> "$LOGDIR/conf"

    run run_rsvlog
    assert_success
    assert_output --partial "STUB-logger -p local7.info"
    # No log directory was created, because syslog owns the logs now.
    refute [ -e "$LOGDIR/main" ]
}

@test "syslog priority defaults to daemon.info" {
    echo 'SV_LOG_SYSLOG=1' > "$LOGDIR/conf"
    run run_rsvlog
    assert_output --partial "STUB-logger -p daemon.info"
}

@test "a regular user logs under their own log base, named for the service" {
    run run_rsvlog
    assert_success
    assert_output --partial "Logging to $(default_log_base)/ticker"
    assert [ -d "$(default_log_base)/ticker" ]
}

@test "./main points at the log directory and ./current at the live file" {
    run_rsvlog
    assert_equal "$(readlink "$LOGDIR/main")" "$(default_log_base)/ticker"
    assert_equal "$(readlink "$LOGDIR/current")" "main/current"
}

@test "SV_LOG_BASE overrides where the logs go" {
    mkdir -p "$TEST_TMP/elsewhere"
    run run_rsvlog "SV_LOG_BASE=$TEST_TMP/elsewhere"
    assert_success
    assert_output --partial "Logging to $TEST_TMP/elsewhere/ticker"
}

@test "SV_LOGDIR names a subdirectory of the log base" {
    echo 'SV_LOGDIR=ticker/service_logs' > "$LOGDIR/conf"
    run run_rsvlog
    assert_success
    assert_output --partial "Logging to $(default_log_base)/ticker/service_logs"
}

@test "an absolute SV_LOGDIR is used as given" {
    # conf is sourced as shell, so a value with a space is quoted in it
    # the same way it would be in any other shell file.
    echo "SV_LOGDIR='$TEST_TMP/absolute logs'" > "$LOGDIR/conf"
    run run_rsvlog
    assert_success
    assert_output --partial "Logging to $TEST_TMP/absolute logs"
}

@test "CURRENT_LOG_FILE adds a second name for the live log" {
    echo 'CURRENT_LOG_FILE=ticker.log' > "$LOGDIR/conf"
    run_rsvlog
    assert_equal "$(readlink "$(default_log_base)/ticker/ticker.log")" "current"
}

@test "an existing ./main directory is kept, wherever the base would point" {
    mkdir -p "$LOGDIR/main"
    run run_rsvlog
    assert_success
    # Moving an established layout would strand the logs already in it.
    assert_output --partial "Logging in existing"
    assert_output --partial "STUB-svlogd -t ./main"
    refute [ -L "$LOGDIR/main" ]
}

@test "an unwritable log base falls back to the log directory itself" {
    run run_rsvlog "SV_LOG_BASE=/proc/nowhere-at-all"
    assert_success
    assert_output --partial "Logging in $LOGDIR"
    assert_output --partial "STUB-svlogd -t ./"
}

@test "a regular user's logger runs as themselves, with no chpst and no chown" {
    run run_rsvlog
    assert_success
    assert_output --partial "STUB-svlogd"
    # chpst -u would mean dropping privilege we never had.
    refute_output --partial "STUB-chpst"
}

@test "a USERGROUP naming no such account fails loudly" {
    echo 'USERGROUP=nosuchuser:nosuchgroup' > "$LOGDIR/conf"
    run run_rsvlog
    assert_failure
    assert_output --partial "no such user"
    # Falling back to the current user here would quietly log as whoever
    # started the service, which is the opposite of what was asked for.
    refute_output --partial "STUB-svlogd"
}

@test "the service name comes from the service directory, not the cwd" {
    local other="$TEST_TMP/sv/another-name"
    mkdir -p "$other/log"
    ln -s "$REPO_ROOT/rsvlog.sh" "$other/log/run"

    cd "$other/log"
    run as_user "$HOME_DIR" env "PATH=$STUBS:$PATH" ./run
    assert_success
    assert_output --partial "Logging to $(default_log_base)/another-name"
}
