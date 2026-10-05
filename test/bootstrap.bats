#!/usr/bin/env bats
# bootstrap/install.sh, the `curl | bash` installer, against a release
# payload built here with ci/build_release_payload.sh and served through
# file:// - the same layout as GitHub's releases/download/<tag>/, with no
# network involved. Resolving "latest" needs GitHub's redirect, so every
# test here names a VERSION.

RELEASE=9.8.7

setup_file() {
    REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd -P)
    export REPO_ROOT
    export PRISTINE="${BATS_FILE_TMPDIR}/releases"
    "$REPO_ROOT/ci/build_release_payload.sh" "$RELEASE" "$PRISTINE/download/v$RELEASE" >/dev/null
    # Stands in for the signed bundle. Only the fake packslip below reads it.
    echo '{}' > "$PRISTINE/download/v$RELEASE/packslip.sigstore.json"
}

setup() {
    load 'test_helper/common'
    load 'test_helper/sv'
    common_setup

    # A copy per test, so a test can tamper with its release freely.
    RELEASES="$TEST_TMP/releases"
    cp -R "$PRISTINE" "$RELEASES"
    ASSETS="$RELEASES/download/v$RELEASE"
    PREFIX_DIR="$TEST_TMP/prefix"
    FAKEBIN="$TEST_TMP/fakebin"
    mkdir -p "$FAKEBIN" "$TEST_TMP/tmp"

    case "$(uname -s)" in
        Darwin) ARCHIVE=sv-helper-darwin.tar.gz ;;
        *) ARCHIVE=sv-helper-linux.tar.gz ;;
    esac

    # Every test starts without packslip, whether or not this host has it.
    export SV_HELPER_DOWNLOAD_BASE="file://$RELEASES"
    export SV_HELPER_PACKSLIP=no-such-packslip
    export TMPDIR="$TEST_TMP/tmp"
}

# The way a user runs it: piped into bash, arguments after `bash -s --`.
bootstrap() {
    bash -s -- "$@" < "$REPO_ROOT/bootstrap/install.sh"
}

# A packslip that records how it was called, and passes or fails on
# command.
fake_packslip() {
    local status="$1"
    cat > "$FAKEBIN/packslip" <<FAKE
#!/bin/sh
printf '%s\n' "\$@" > "$TEST_TMP/packslip-args"
exit $status
FAKE
    chmod +x "$FAKEBIN/packslip"
    export SV_HELPER_PACKSLIP="$FAKEBIN/packslip"
}

assert_nothing_installed() {
    refute [ -e "$PREFIX_DIR/bin/sv-helper" ]
}

assert_cleaned_up() {
    run find "$TEST_TMP/tmp" -mindepth 1
    assert_output ""
}

@test "a pinned version installs, and says the signature was not checked" {
    VERSION="v$RELEASE" run bootstrap --prefix "$PREFIX_DIR"
    assert_success
    assert_output --partial "Installing sv-helper v$RELEASE"
    assert_output --partial "Checksum verified"
    assert_output --partial "Signature not checked, because packslip is not installed"

    run "$PREFIX_DIR/bin/svls" --version
    assert_success
    assert_output --partial "svls (sv-helper)"
    assert [ -x "$PREFIX_DIR/bin/rsvlog" ]
    assert [ -x "$PREFIX_DIR/bin/runsvdir.sh" ]
    assert_cleaned_up
}

@test "a version without the v installs the same release" {
    VERSION="$RELEASE" run bootstrap --prefix "$PREFIX_DIR"
    assert_success
    assert_output --partial "Installing sv-helper v$RELEASE"
    assert [ -x "$PREFIX_DIR/bin/sv-helper" ]
}

@test "PREFIX in the environment reaches install.sh" {
    VERSION="$RELEASE" PREFIX="$PREFIX_DIR" run bootstrap
    assert_success
    assert [ -x "$PREFIX_DIR/bin/sv-helper" ]
}

@test "a release that does not exist is named, and nothing is installed" {
    VERSION=v1.2.3 run -4 bootstrap --prefix "$PREFIX_DIR"
    assert_output --partial "no release v1.2.3"
    assert_nothing_installed
    assert_cleaned_up
}

@test "a version that is not a version is refused before downloading anything" {
    VERSION=v.0.1 run -4 bootstrap --prefix "$PREFIX_DIR"
    assert_output --partial "VERSION=v.0.1 is not a release version"
    refute_output --partial "Installing"
    assert_nothing_installed
}

@test "an archive that does not match SHA256SUMS is not installed" {
    printf 'tampered' >> "$ASSETS/$ARCHIVE"

    VERSION="$RELEASE" run -6 bootstrap --prefix "$PREFIX_DIR"
    assert_output --partial "$ARCHIVE does not match v$RELEASE's SHA256SUMS"
    assert_nothing_installed
    assert_cleaned_up
}

@test "an archive missing from SHA256SUMS is not installed" {
    grep -v "$ARCHIVE" "$ASSETS/SHA256SUMS" > "$TEST_TMP/sums"
    mv "$TEST_TMP/sums" "$ASSETS/SHA256SUMS"

    VERSION="$RELEASE" run -6 bootstrap --prefix "$PREFIX_DIR"
    assert_output --partial "has no entry for $ARCHIVE"
    assert_nothing_installed
}

@test "with packslip, the signature is verified against the release workflow" {
    fake_packslip 0

    VERSION="$RELEASE" run bootstrap --prefix "$PREFIX_DIR"
    assert_success
    assert_output --partial "Signature verified"

    run cat "$TEST_TMP/packslip-args"
    assert_line --index 0 verify
    assert_line "https://github.com/rubyists/sv-helper/.github/workflows/main.yaml@"
    assert_line "https://token.actions.githubusercontent.com"
    assert_output --regexp "/$ARCHIVE\$"
}

@test "a failed signature is not installed" {
    fake_packslip 1

    VERSION="$RELEASE" run -6 bootstrap --prefix "$PREFIX_DIR"
    assert_output --partial "failed signature verification"
    assert_nothing_installed
    assert_cleaned_up
}

@test "with packslip, a release without a signature bundle is not installed" {
    fake_packslip 0
    rm "$ASSETS/packslip.sigstore.json"

    VERSION="$RELEASE" run -6 bootstrap --prefix "$PREFIX_DIR"
    assert_output --partial "signature bundle could not be downloaded"
    assert_nothing_installed
}

@test "an unsupported platform is named and refused" {
    cat > "$FAKEBIN/uname" <<'FAKE'
#!/bin/sh
echo FreeBSD
FAKE
    chmod +x "$FAKEBIN/uname"

    VERSION="$RELEASE" PATH="$FAKEBIN:$PATH" run -3 bootstrap --prefix "$PREFIX_DIR"
    assert_output --partial "FreeBSD is not supported"
    assert_nothing_installed
}

@test "install.sh's own failure is its exit status" {
    # install.sh refuses an option it does not know with status 1.
    VERSION="$RELEASE" run -1 bootstrap --no-such-option
    assert_output --partial "Unknown option '--no-such-option'"
    assert_output --partial "install.sh exited 1"
    assert_cleaned_up
}

@test "a download cut off before the last line runs nothing" {
    # Everything but the call to main: what bash gets when the connection
    # drops after the last function and before the end.
    VERSION="$RELEASE" run bash -s -- --prefix "$PREFIX_DIR" \
        < <(grep -v '^main "\$@"$' "$REPO_ROOT/bootstrap/install.sh")
    assert_success
    assert_output ""
    assert_nothing_installed
}

@test "a download cut off inside main runs nothing" {
    local half
    half=$(($(grep -n '^main() {$' "$REPO_ROOT/bootstrap/install.sh" | cut -d: -f1) + 20))

    VERSION="$RELEASE" run bash -s -- --prefix "$PREFIX_DIR" \
        < <(head -n "$half" "$REPO_ROOT/bootstrap/install.sh")
    refute_output --partial "Installing"
    assert_nothing_installed
}

@test "it never escalates privilege" {
    run grep -nwE 'sudo|doas|su|pkexec' "$REPO_ROOT/bootstrap/install.sh"
    assert_failure
}
