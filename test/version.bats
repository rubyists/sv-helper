#!/usr/bin/env bats
# --version on every command, and the guard that keeps it honest: each
# script carries its own copy of the version, rewritten by release-please,
# so a script left out of its extra-files would quietly report an old one.

setup() {
    load 'test_helper/common'
    load 'test_helper/sv'
    common_setup
    VERSION=$(cat "$REPO_ROOT/version.txt")
    export VERSION
}

@test "sv-helper --version and sv-helper version" {
    run "$REPO_ROOT/sv-helper.sh" --version
    assert_success
    assert_output "sv-helper $VERSION"

    run "$REPO_ROOT/sv-helper.sh" version
    assert_success
    assert_output "sv-helper $VERSION"
}

@test "every alias takes --version and names its package" {
    local name
    for name in svls sv-list sv-find sv-enable sv-disable sv-start sv-stop sv-restart
    do
        ln -s "$REPO_ROOT/sv-helper.sh" "$TEST_TMP/$name"
        run "$TEST_TMP/$name" --version
        assert_success
        assert_output "$name (sv-helper) $VERSION"
    done
}

@test "rsvlog --version works outside a log directory" {
    cd "$TEST_TMP"
    run "$REPO_ROOT/rsvlog.sh" --version
    assert_success
    assert_output "rsvlog (sv-helper) $VERSION"
}

@test "runsvdir.sh --version answers without creating or supervising a tree" {
    local home="$TEST_TMP/home"
    mkdir -p "$home"

    run as_user "$home" "$REPO_ROOT/runsvdir.sh" --version
    assert_success
    assert_output "runsvdir.sh (sv-helper) $VERSION"
    refute [ -e "$home/.local" ]
}

@test "svls --version needs no service directory" {
    # A regular user's tree is created on demand, and a version query is
    # not a demand.
    local home="$TEST_TMP/home"
    mkdir -p "$home"
    ln -s "$REPO_ROOT/sv-helper.sh" "$TEST_TMP/svls"

    run as_user "$home" "$TEST_TMP/svls" --version
    assert_success
    refute [ -e "$home/.local" ]
}

@test "every file with a release-please version marker is in its extra-files" {
    local file missing=""
    while IFS= read -r file
    do
        if ! grep -Fq "\"path\": \"$file\"" "$REPO_ROOT/.release-please-config.json"
        then
            missing="$missing $file"
        fi
    done < <(git -C "$REPO_ROOT" grep -l 'x-release-please-' -- ':!test/*' ':!docs/*' ':!CHANGELOG.md')

    assert_equal "$missing" ""
}

@test "every version marker carries the current version" {
    # Catches a file added to extra-files after a release, still holding
    # whatever version it was written with.
    local line found stale=""
    while IFS= read -r line
    do
        found=$(printf '%s\n' "$line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        if [ "$found" != "$VERSION" ]
        then
            stale="$stale
$line"
        fi
    done < <(git -C "$REPO_ROOT" grep -n 'x-release-please-version' -- ':!test/*' ':!docs/*' ':!CHANGELOG.md')

    assert_equal "$stale" ""
}
