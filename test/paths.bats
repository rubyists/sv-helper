#!/usr/bin/env bats
# Path resolution: which service tree, definition directories and logs an
# invocation picks, and what overrides it. The rule under test throughout
# is that the invoking UID decides the scope - a writable system directory
# never promotes a regular user to system-wide state - and that an
# explicit override always wins.

setup() {
    load 'test_helper/common'
    load 'test_helper/sv'
    common_setup

    HOME_DIR="$TEST_TMP/a home"   # a space, because paths have them
    mkdir -p "$HOME_DIR"
    SVHELPER="$REPO_ROOT/sv-helper.sh"
}

resolved_svdir() {
    as_user "$HOME_DIR" "$SVHELPER" paths | sed -n 's/^svdir: *//p'
}

@test "help works before any service directory exists" {
    run as_user "$HOME_DIR" "$SVHELPER" -h
    assert_success
    assert_output --partial "Valid Commands"
}

@test "listing services before any exist is empty, not an error" {
    run as_user "$HOME_DIR" "$SVHELPER" sv-list
    assert_success
    assert_output ""
}

@test "a regular user gets their own tree" {
    assert_equal "$(resolved_svdir)" "$(expected_svdir "$HOME_DIR")"
}

@test "a non-root invocation never selects a system tree" {
    # /var/service, /service and /etc/service are consulted only for UID 0.
    # On the machines this runs on at least one of them usually exists and
    # is often writable, which is exactly the trap being tested for.
    case "$(resolved_svdir)" in
        /var/service|/service|/etc/service)
            fail "a non-root invocation selected the system tree $(resolved_svdir)" ;;
    esac
}

@test "an explicit SVDIR wins, spaces and all" {
    mkdir -p "$TEST_TMP/explicit tree"
    run as_user "$HOME_DIR" env "SVDIR=$TEST_TMP/explicit tree" "$SVHELPER" paths
    assert_success
    assert_line --partial "svdir:        $TEST_TMP/explicit tree"
}

@test "a nonexistent SVDIR is an error, not a silent fallback" {
    # 127 is this project's "no service directory" status, not a missing
    # command; naming it keeps bats from warning about the exit code.
    run -127 as_user "$HOME_DIR" env "SVDIR=$TEST_TMP/nope" "$SVHELPER" paths
    assert_output --partial "No service directory found"
}

@test "SV_SOURCE_DIR is searched for service definitions" {
    mkdir -p "$TEST_TMP/defs/thing"
    run as_user "$HOME_DIR" env "SV_SOURCE_DIR=$TEST_TMP/defs" "$SVHELPER" sv-find thing
    assert_success
    assert_output "$TEST_TMP/defs/thing"
}

@test "a service directory inside the enabled tree is found" {
    local svdir
    svdir=$(expected_svdir "$HOME_DIR")
    mkdir -p "$svdir/inline"
    run as_user "$HOME_DIR" "$SVHELPER" sv-find inline
    rmdir "$svdir/inline"
    assert_success
    assert_output "$svdir/inline"
}

@test "sv-find reports an unknown service" {
    run as_user "$HOME_DIR" "$SVHELPER" sv-find nothing-here
    assert_failure
    assert_output --partial "No such service"
}

@test "runsvdir.sh resolves the same tree sv-helper does" {
    # The two resolve it independently, so that each works standalone. A
    # disagreement would mean enabling a service in one tree and
    # supervising another, with no error anywhere.
    #
    # runsvdir.sh ends in `exec runsvdir -P DIR`, so a stub named runsvdir
    # at the front of PATH reports the directory it settled on without
    # starting a real supervision tree.
    mkdir -p "$TEST_TMP/stub"
    cat > "$TEST_TMP/stub/runsvdir" <<'STUB'
#!/bin/sh
echo "STUB-SVDIR=$2"
STUB
    chmod +x "$TEST_TMP/stub/runsvdir"

    run as_user "$HOME_DIR" env "PATH=$TEST_TMP/stub:$PATH" "$REPO_ROOT/runsvdir.sh"
    assert_success
    assert_output --partial "STUB-SVDIR=$(expected_svdir "$HOME_DIR")"
}
