#!/usr/bin/env bats
# release.toml, checked against the real packslip rather than read and
# hoped about. These sign with a throwaway key and skip the transparency
# log, which is what packslip documents for exactly this - checking a
# manifest locally. Production signing is keyless with the workflow's own
# OIDC identity and is always logged; nothing here changes that.

setup_file() {
    REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd -P)
    export REPO_ROOT

    if ! command -v packslip >/dev/null 2>&1
    then
        export PACKSLIP_SKIP="packslip is not installed"
        return 0
    fi

    export VERSION=3.6.0-test
    export PAYLOAD="$REPO_ROOT/dist"
    export BUNDLE_DIR="${BATS_FILE_TMPDIR}/bundle"
    export KEY="${BATS_FILE_TMPDIR}/test.key"
    export PUBKEY="${BATS_FILE_TMPDIR}/test.pub"

    rm -rf "$PAYLOAD"
    "$REPO_ROOT/ci/build_release_payload.sh" "$VERSION" "$PAYLOAD" >/dev/null
    packslip keygen --out "$KEY" >/dev/null 2>&1

    # Run from the repository root: release.toml's paths are relative to
    # where packslip runs, not to where the manifest lives.
    cd "$REPO_ROOT"
    packslip create --manifest release.toml \
        --project github.com/rubyists/sv-helper --version "$VERSION" \
        --url-base "https://github.com/rubyists/sv-helper/releases/download/v$VERSION" \
        --key "$KEY" --no-log --out "$BUNDLE_DIR" >/dev/null 2>&1
    export BUNDLE="$BUNDLE_DIR/packslip.sigstore.json"
}

teardown_file() {
    rm -rf "${REPO_ROOT:?}/dist"
}

setup() {
    load 'test_helper/common'
    common_setup
    [ -z "${PACKSLIP_SKIP:-}" ] || skip "$PACKSLIP_SKIP"
}

artifact_field() {
    packslip show "$BUNDLE" | python3 -c "
import json, sys
doc = json.load(sys.stdin)
for a in doc['predicate']['artifacts']:
    if a['name'] == '$1':
        print(json.dumps(a.get('$2')))
        break
"
}

@test "release.toml describes every published artifact" {
    run packslip show "$BUNDLE"
    assert_success
    for name in sv-helper-linux.tar.gz sv-helper-darwin.tar.gz \
                sv-helper.sh rsvlog runsvdir.sh
    do
        assert_output --partial "\"$name\""
    done
}

@test "Linux and macOS support are recorded explicitly" {
    assert_equal "$(artifact_field sv-helper-linux.tar.gz os)" '"linux"'
    assert_equal "$(artifact_field sv-helper-darwin.tar.gz os)" '"darwin"'
}

@test "no artifact claims an architecture or a C library" {
    # Shell scripts run anywhere. Left to infer, packslip reads libc from
    # the executables, fails to parse a script, and settles on gnu -
    # which would make a consumer refuse to install on Alpine.
    for name in sv-helper-linux.tar.gz sv-helper-darwin.tar.gz
    do
        assert_equal "$(artifact_field "$name" arch)" "null"
        assert_equal "$(artifact_field "$name" libc)" "null"
    done
}

@test "the suite archives are the only artifacts without a variant" {
    # Default selection only considers artifacts with no variant. If a
    # loose script had none, a consumer could install rsvlog alone and
    # believe it had installed sv-helper - or refuse outright, because
    # two artifacts tied for the same platform.
    assert_equal "$(artifact_field sv-helper-linux.tar.gz variant)" "null"
    assert_equal "$(artifact_field sv-helper-darwin.tar.gz variant)" "null"
    for name in sv-helper.sh rsvlog runsvdir.sh
    do
        refute [ "$(artifact_field "$name" variant)" = "null" ]
    done
}

@test "every helper alias is declared, resolved to its path in the archive" {
    local bins
    bins=$(artifact_field sv-helper-linux.tar.gz bin)
    for name in sv-helper sv-start sv-stop sv-restart sv-list svls \
                sv-enable sv-disable sv-find rsvlog runsvdir.sh
    do
        assert [ "${bins#*/bin/$name\"}" != "$bins" ]
    done
}

@test "runit is required and the logging tools stay optional" {
    local requires
    requires=$(artifact_field sv-helper-linux.tar.gz requires)
    assert [ "${requires#*\"sv\"}" != "$requires" ]
    assert [ "${requires#*runsvdir}" != "$requires" ]
    # A host with no svlogd can still run every helper command; only
    # rsvlog itself needs one.
    assert [ "${requires#*svlogd}" = "$requires" ]
    assert [ "$(artifact_field rsvlog requires)" != "null" ]
}

@test "the bundle verifies against the artifacts it describes" {
    cd "$REPO_ROOT"
    run packslip verify "$BUNDLE" --pubkey "$PUBKEY" --allow-unlogged \
        --artifact dist/sv-helper-linux.tar.gz \
        --artifact dist/sv-helper-darwin.tar.gz \
        --artifact dist/rsvlog
    assert_success
    assert_output --partial "ok: github.com/rubyists/sv-helper"
}

@test "a modified artifact fails verification" {
    cp "$PAYLOAD/rsvlog" "$TEST_TMP/rsvlog"
    echo "# added by someone else" >> "$TEST_TMP/rsvlog"

    cd "$TEST_TMP"
    run packslip verify "$BUNDLE" --pubkey "$PUBKEY" --allow-unlogged \
        --artifact "$TEST_TMP/rsvlog"
    assert_failure
    assert_output --partial "verification failed"
}
