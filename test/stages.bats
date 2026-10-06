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

# A runit package's own /etc/runit, as Debian ships it: its own stages,
# and stopit and reboot linked somewhere other than ours.
distro_runit() {
    mkdir -p "$RUNIT"
    local name
    for name in $STAGES
    do
        printf '#!/bin/sh\n# the distribution stage %s\n' "$name" > "$RUNIT/$name"
        chmod 0755 "$RUNIT/$name"
    done
    ln -s /run/runit.stopit "$RUNIT/stopit"
    ln -s /run/runit.reboot "$RUNIT/reboot"
    snapshot "$RUNIT" > "$TEST_TMP/distro.before"
}

# Every entry in a directory with its contents or link target, so a round
# trip can be checked byte for byte.
snapshot() {
    local entry
    for entry in "$1"/*
    do
        if [ -L "$entry" ]
        then
            printf '%s -> %s\n' "${entry##*/}" "$(readlink "$entry")"
        else
            printf '%s %s\n' "${entry##*/}" "$(cksum < "$entry")"
        fi
    done
}

@test "a runit package's own stages are refused, and nothing is written" {
    distro_runit

    run stages install-stages --destdir "$ROOT"
    assert_failure
    assert_output --partial "sv-helper did not install it"
    assert_output --partial "--force"
    assert_equal "$(snapshot "$RUNIT")" "$(cat "$TEST_TMP/distro.before")"
    refute [ -e "$RUNIT/.sv-helper-installed" ]
}

@test "a conflict anywhere refuses before anything is written" {
    # Only the last stage is someone else's. Checking each one just before
    # writing it would already have replaced the first three.
    mkdir -p "$RUNIT"
    echo "someone else's" > "$RUNIT/ctrlaltdel"

    run stages install-stages --destdir "$ROOT"
    assert_failure
    refute [ -e "$RUNIT/1" ]
    refute [ -e "$RUNIT/stopit" ]
}

@test "--force sets a runit package's stages aside, and uninstall-stages puts them back" {
    distro_runit

    run stages install-stages --destdir "$ROOT" --force
    assert_success
    assert_output --partial "set aside $RUNIT/2 -> $RUNIT/.sv-helper-displaced/2"
    cmp "$REPO_ROOT/etc/runit/2" "$RUNIT/2"
    assert_equal "$(readlink "$RUNIT/stopit")" /run/runit/stopit

    run stages uninstall-stages --destdir "$ROOT"
    assert_success
    assert_output --partial "restored  $RUNIT/2"
    assert_equal "$(snapshot "$RUNIT")" "$(cat "$TEST_TMP/distro.before")"
    refute [ -e "$RUNIT/.sv-helper-installed" ]
    refute [ -e "$RUNIT/.sv-helper-displaced" ]
}

@test "--dry-run over a runit package's stages changes nothing" {
    distro_runit
    run stages install-stages --destdir "$ROOT" --force --dry-run
    assert_success
    assert_output --partial "would: mv"
    assert_equal "$(snapshot "$RUNIT")" "$(cat "$TEST_TMP/distro.before")"
    refute [ -e "$RUNIT/.sv-helper-displaced" ]
}

@test "a link that is already right but not ours is kept, and never removed" {
    # Void's runit links stopit and reboot exactly where ours go.
    mkdir -p "$RUNIT"
    ln -s /run/runit/stopit "$RUNIT/stopit"
    ln -s /run/runit/reboot "$RUNIT/reboot"

    run stages install-stages --destdir "$ROOT"
    assert_success
    assert_output --partial "kept      $RUNIT/stopit"

    run stages uninstall-stages --destdir "$ROOT"
    assert_success
    refute [ -e "$RUNIT/2" ]
    assert_equal "$(readlink "$RUNIT/stopit")" /run/runit/stopit
    assert_equal "$(readlink "$RUNIT/reboot")" /run/runit/reboot
}

@test "uninstall-stages with nothing installed touches nothing" {
    distro_runit
    run stages uninstall-stages --destdir "$ROOT" --force
    assert_success
    assert_output --partial "installed nothing"
    assert_equal "$(snapshot "$RUNIT")" "$(cat "$TEST_TMP/distro.before")"
}

@test "stages from before the manifest existed are adopted, and removable" {
    # Byte for byte our own, installed by a release that kept no manifest.
    mkdir -p "$RUNIT"
    cp "$REPO_ROOT"/etc/runit/1 "$REPO_ROOT"/etc/runit/2 "$RUNIT/"

    run stages install-stages --destdir "$ROOT"
    assert_success
    assert_output --partial "adopted   $RUNIT/2"

    run stages uninstall-stages --destdir "$ROOT"
    assert_success
    refute [ -e "$RUNIT/2" ]
}

@test "a newer sv-helper replaces its own stages without --force" {
    stages install-stages --destdir "$ROOT"
    mkdir -p "$TEST_TMP/newer"
    cp "$REPO_ROOT"/etc/runit/* "$TEST_TMP/newer/"
    echo "# a later release" >> "$TEST_TMP/newer/3"

    run as_user "$HOME_DIR" env "SV_STAGE_DIR=$TEST_TMP/newer" "$SVHELPER" install-stages --destdir "$ROOT"
    assert_success
    cmp "$TEST_TMP/newer/3" "$RUNIT/3"
    refute [ -e "$RUNIT/.sv-helper-displaced" ]
}

@test "a stage changed since it was installed is neither replaced nor removed without --force" {
    stages install-stages --destdir "$ROOT"
    echo "# a local fix" >> "$RUNIT/3"

    run stages install-stages --destdir "$ROOT"
    assert_failure
    assert_output --partial "changed since sv-helper installed it"

    run stages uninstall-stages --destdir "$ROOT"
    assert_success
    assert_output --partial "skipping $RUNIT/3"
    refute [ -e "$RUNIT/2" ]
    assert [ -f "$RUNIT/3" ]
    # Still recorded, so it can still be taken back.
    run grep -c '^file 3 ' "$RUNIT/.sv-helper-installed"
    assert_output 1

    run stages uninstall-stages --destdir "$ROOT" --force
    assert_success
    refute [ -e "$RUNIT/3" ]
    refute [ -e "$RUNIT/.sv-helper-installed" ]
}

@test "an occupied set-aside slot is refused rather than overwritten" {
    distro_runit
    mkdir -p "$RUNIT/.sv-helper-displaced"
    echo "set aside earlier" > "$RUNIT/.sv-helper-displaced/2"

    run stages install-stages --destdir "$ROOT" --force
    assert_failure
    assert_output --partial "nowhere to be set aside"
    assert_equal "$(cat "$RUNIT/.sv-helper-displaced/2")" "set aside earlier"
    assert_equal "$(snapshot "$RUNIT")" "$(cat "$TEST_TMP/distro.before")"
}

@test "nothing depends on cmp, which minimal images do not have" {
    # A cmp that always fails, as a missing one would. Reinstalling over
    # identical files must still see them as identical.
    mkdir -p "$TEST_TMP/nocmp"
    printf '#!/bin/sh\nexit 2\n' > "$TEST_TMP/nocmp/cmp"
    chmod +x "$TEST_TMP/nocmp/cmp"
    local path="$TEST_TMP/nocmp:$PATH" prefix="$TEST_TMP/prefix"

    run as_user "$HOME_DIR" env "PATH=$path" "$SVHELPER" install-stages --destdir "$ROOT"
    assert_success
    run as_user "$HOME_DIR" env "PATH=$path" "$SVHELPER" install-stages --destdir "$ROOT"
    assert_success
    run as_user "$HOME_DIR" env "PATH=$path" "$SVHELPER" uninstall-stages --destdir "$ROOT"
    assert_success
    refute [ -e "$RUNIT/2" ]

    run env "PATH=$path" "$REPO_ROOT/install.sh" install --prefix "$prefix"
    assert_success
    run env "PATH=$path" "$REPO_ROOT/install.sh" install --prefix "$prefix"
    assert_success
    run env "PATH=$path" "$REPO_ROOT/install.sh" uninstall --prefix "$prefix"
    assert_success
    refute [ -e "$prefix/bin/sv-helper" ]
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
    # Physical, as sv-helper prints it: macOS's temporary directory is
    # behind a symlink.
    assert_line "stage dir:    $(cd "$prefix/share/sv-helper/runit" && pwd -P)"

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
