#!/usr/bin/env bats
# The release payload: what ci/build_release_payload.sh produces, that it
# produces the same bytes twice from the same source, and that what comes
# out can actually be installed. Every installation path consumes
# exactly these files, so a mistake here is a mistake in all of them at
# once.

VERSION=0.0.0-test

setup_file() {
    REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd -P)
    export REPO_ROOT
    export PAYLOAD="${BATS_FILE_TMPDIR}/dist"
    export UNPACKED="${BATS_FILE_TMPDIR}/unpacked"
    export TREE="$UNPACKED/sv-helper-0.0.0-test"

    "$REPO_ROOT/ci/build_release_payload.sh" 0.0.0-test "$PAYLOAD" >/dev/null
    mkdir -p "$UNPACKED"
    tar -xzf "$PAYLOAD/sv-helper-linux.tar.gz" -C "$UNPACKED"
}

setup() {
    load 'test_helper/common'
    load 'test_helper/sv'
    common_setup
}

@test "both platform archives and the standalone scripts are built" {
    for asset in \
        sv-helper-linux.tar.gz \
        sv-helper-darwin.tar.gz \
        rsvlog sv-helper.sh runsvdir.sh SHA256SUMS
    do
        assert [ -f "$PAYLOAD/$asset" ]
    done
}

@test "every asset matches the checksums published beside it" {
    cd "$PAYLOAD"
    if command -v sha256sum >/dev/null 2>&1
    then
        run sha256sum -c SHA256SUMS
    else
        run shasum -a 256 -c SHA256SUMS
    fi
    assert_success
}

@test "building the same source twice produces the same bytes" {
    # The recovery path in publish_release_assets.sh refuses to replace a
    # published asset whose bytes differ. That is only a useful rule if a
    # rebuild of the same commit is reproducible.
    local second="$TEST_TMP/dist2"
    "$REPO_ROOT/ci/build_release_payload.sh" "$VERSION" "$second" >/dev/null

    run diff "$PAYLOAD/SHA256SUMS" "$second/SHA256SUMS"
    assert_success
}

@test "the archive ships the scripts under their public names" {
    for name in bin/sv-helper bin/rsvlog bin/runsvdir.sh
    do
        assert [ -f "$TREE/$name" ]
        assert [ -x "$TREE/$name" ]
    done
}

@test "the archive ships the command links, so unpacking is enough" {
    # Unpacking the archive and putting bin/ on PATH has to give every
    # command, without running the installer first.
    for name in sv-start sv-stop sv-restart sv-list svls sv-enable sv-disable sv-find
    do
        assert [ -L "$TREE/bin/$name" ]
        assert_equal "$(readlink "$TREE/bin/$name")" "sv-helper"
    done
}

@test "the archive bundles the installer and the container stages" {
    assert [ -f "$TREE/install.sh" ]
    assert [ -x "$TREE/install.sh" ]
    for stage in 1 2 3 ctrlaltdel
    do
        assert [ -f "$TREE/etc/runit/$stage" ]
    done
}

@test "the archive bundles the documentation" {
    assert [ -f "$TREE/share/doc/sv-helper/Readme.adoc" ]
    assert [ -f "$TREE/share/doc/sv-helper/COPYING" ]
    assert [ -f "$TREE/share/doc/sv-helper/CHANGELOG.md" ]
}

@test "the archive carries only what the file list names" {
    # Built from an explicit list rather than from the working tree, so
    # anything untracked sitting in the repository - a scratch
    # directory, a dist/ from an earlier build, a sibling checkout -
    # can never be shipped by accident.
    refute [ -e "$TREE/dist" ]
    refute [ -e "$TREE/.git" ]
    refute [ -e "$TREE/test" ]
}

@test "the two platform archives carry the same build" {
    local linux darwin
    mkdir -p "$TEST_TMP/d"
    tar -xzf "$PAYLOAD/sv-helper-darwin.tar.gz" -C "$TEST_TMP/d"

    run diff -r "$TREE" "$TEST_TMP/d/sv-helper-$VERSION"
    assert_success
}

@test "the unpacked archive installs and its commands run" {
    local prefix="$TEST_TMP/from archive"

    run "$TREE/install.sh" install --prefix "$prefix"
    assert_success

    assert [ -f "$prefix/bin/sv-helper" ]
    run "$prefix/bin/svls" -h
    assert_success
}

@test "the standalone scripts are the same files the archive holds" {
    run diff "$PAYLOAD/rsvlog" "$TREE/bin/rsvlog"
    assert_success
    run diff "$PAYLOAD/sv-helper.sh" "$TREE/bin/sv-helper"
    assert_success
    run diff "$PAYLOAD/runsvdir.sh" "$TREE/bin/runsvdir.sh"
    assert_success
}

@test "a version is required" {
    run "$REPO_ROOT/ci/build_release_payload.sh"
    assert_failure
    assert_output --partial "Usage"
}
