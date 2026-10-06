#!/usr/bin/env bats
# sv-helper install-stages and uninstall-stages: putting the container's
# runit stages in place from wherever sv-helper itself is - a checkout, an
# installed prefix, an unpacked archive - refusing to walk over files it
# did not write, and taking back exactly its own.
#
# Every test stages into its own --destdir under $TEST_TMP, so none of
# them touch the real /etc/runit.

setup() {
    load 'test_helper/common'
    load 'test_helper/sv'
    common_setup

    HOME_DIR="$TEST_TMP/home"
    mkdir -p "$HOME_DIR"
    ROOT="$TEST_TMP/a root"   # a space, because paths have them
    RUNIT="$ROOT/etc/runit"
    SVHELPER="$REPO_ROOT/sv-helper.sh"
    STAGES="1 2 3 ctrlaltdel"
}

stages() {
    as_user "$HOME_DIR" "$SVHELPER" "$@"
}

@test "install-stages puts every stage in place, executable" {
    run stages install-stages --destdir "$ROOT"
    assert_success

    local name
    for name in $STAGES
    do
        assert [ -f "$RUNIT/$name" ]
        assert [ -x "$RUNIT/$name" ]
        cmp "$REPO_ROOT/etc/runit/$name" "$RUNIT/$name"
    done
}

@test "install-stages links runit's control files into /run/runit" {
    # So a container running as a regular user can arm stopit without
    # /etc/runit being writable. See container/Readme.md.
    run stages install-stages --destdir "$ROOT"
    assert_success

    local name
    for name in stopit reboot
    do
        assert_equal "$(readlink "$RUNIT/$name")" "/run/runit/$name"
    done
}

@test "install-stages twice over its own work is fine" {
    stages install-stages --destdir "$ROOT"
    run stages install-stages --destdir "$ROOT"
    assert_success
}

@test "--runit-dir puts them somewhere else" {
    run stages install-stages --destdir "$ROOT" --runit-dir /opt/runit
    assert_success
    assert [ -f "$ROOT/opt/runit/2" ]
    refute [ -e "$RUNIT" ]
}

@test "--dry-run says what it would do and changes nothing" {
    run stages install-stages --destdir "$ROOT" --dry-run
    assert_success
    assert_output --partial "would: cp"
    refute [ -e "$ROOT" ]
}

@test "a stage it did not write is refused, and --force replaces it" {
    mkdir -p "$RUNIT"
    echo "the distribution's own" > "$RUNIT/2"

    run stages install-stages --destdir "$ROOT"
    assert_failure
    assert_output --partial "already exists with different contents"
    assert_equal "$(cat "$RUNIT/2")" "the distribution's own"

    run stages install-stages --destdir "$ROOT" --force
    assert_success
    cmp "$REPO_ROOT/etc/runit/2" "$RUNIT/2"
}

@test "a control link pointing elsewhere is refused" {
    mkdir -p "$RUNIT"
    ln -s /somewhere/else "$RUNIT/stopit"

    run stages install-stages --destdir "$ROOT"
    assert_failure
    assert_output --partial "not to /run/runit/stopit"
}

@test "uninstall-stages takes back exactly its own" {
    stages install-stages --destdir "$ROOT"
    echo "changed since" >> "$RUNIT/3"

    run stages uninstall-stages --destdir "$ROOT"
    assert_success
    refute [ -e "$RUNIT/2" ]
    refute [ -L "$RUNIT/stopit" ]
    # Not what it installed any more, so not its to remove.
    assert [ -f "$RUNIT/3" ]
    assert_output --partial "skipping $RUNIT/3"
}

@test "an unwritable runit directory is reported, never escalated" {
    [ "$(id -u)" -ne 0 ] || skip "root can write anywhere"
    mkdir -p "$RUNIT"
    chmod 0555 "$RUNIT"

    run -13 stages install-stages --destdir "$ROOT"
    chmod 0755 "$RUNIT"
    assert_output --partial "not writable by $(id -un)"
    refute_output --partial "sudo"
}

@test "an installed sv-helper installs the stages it was installed with" {
    local prefix="$TEST_TMP/prefix"
    "$REPO_ROOT/install.sh" install --prefix "$prefix" >/dev/null 2>&1

    run as_user "$HOME_DIR" "$prefix/bin/sv-helper" paths
    assert_success
    assert_line "stage dir:    $prefix/share/sv-helper/runit"

    run as_user "$HOME_DIR" "$prefix/bin/sv-helper" install-stages --destdir "$ROOT"
    assert_success
    cmp "$REPO_ROOT/etc/runit/3" "$RUNIT/3"
}

@test "a copy with no stages beside it says where it looked" {
    # The standalone sv-helper.sh release asset is exactly this.
    mkdir -p "$TEST_TMP/lone"
    cp "$SVHELPER" "$TEST_TMP/lone/sv-helper"

    run -127 as_user "$HOME_DIR" "$TEST_TMP/lone/sv-helper" install-stages --destdir "$ROOT"
    assert_output --partial "No runit stages found"
    assert_output --partial "$TEST_TMP/lone/../share/sv-helper/runit"
    assert_output --partial "SV_STAGE_DIR"
    refute [ -e "$ROOT" ]
}

@test "SV_STAGE_DIR overrides where the stages come from" {
    mkdir -p "$TEST_TMP/mine"
    local name
    for name in $STAGES
    do
        echo "#!/bin/sh" > "$TEST_TMP/mine/$name"
    done

    run as_user "$HOME_DIR" env "SV_STAGE_DIR=$TEST_TMP/mine" "$SVHELPER" install-stages --destdir "$ROOT"
    assert_success
    cmp "$TEST_TMP/mine/2" "$RUNIT/2"
}

@test "an SV_STAGE_DIR without the stages is an error, not a fallback" {
    run -127 as_user "$HOME_DIR" env "SV_STAGE_DIR=$TEST_TMP/nope" "$SVHELPER" install-stages --destdir "$ROOT"
    assert_output --partial "No runit stages found at \$SV_STAGE_DIR"
}

@test "the stages are never copied onto themselves" {
    mkdir -p "$TEST_TMP/src"
    cp "$REPO_ROOT"/etc/runit/* "$TEST_TMP/src/"

    run as_user "$HOME_DIR" env "SV_STAGE_DIR=$TEST_TMP/src" "$SVHELPER" install-stages --runit-dir "$TEST_TMP/src"
    assert_failure
    assert_output --partial "where the stages would come from"
    cmp "$REPO_ROOT/etc/runit/2" "$TEST_TMP/src/2"
}

@test "they answer only to sv-helper, and no alias is made for them" {
    local prefix="$TEST_TMP/prefix" name
    "$REPO_ROOT/install.sh" install --prefix "$prefix" >/dev/null 2>&1
    for name in install-stages uninstall-stages
    do
        refute [ -e "$prefix/bin/$name" ]
    done
    run grep -E '^commands=.*stages' "$SVHELPER"
    assert_failure

    ln -s sv-helper "$prefix/bin/install-stages"
    run as_user "$HOME_DIR" "$prefix/bin/install-stages" --destdir "$ROOT"
    assert_failure
    assert_output --partial "only run as: sv-helper install-stages"
    refute [ -e "$ROOT" ]
}

@test "-h describes the options, before anything resolves" {
    run stages install-stages -h
    assert_success
    assert_output --partial "--runit-dir"
    assert_output --partial "--dry-run"

    run stages -h
    assert_output --partial "install-stages"
}

@test "an unknown option is refused" {
    run stages install-stages --prefix /usr
    assert_failure
    assert_output --partial "Unknown option '--prefix'"
}
