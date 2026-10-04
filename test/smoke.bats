#!/usr/bin/env bats
# Proves the harness itself works: bats runs, both helper libraries load,
# and a test can reach the repository under test. Everything else builds
# on these three facts, so when a later suite fails oddly, run this first.

setup() {
    load 'test_helper/common'
    common_setup
}

@test "bats-support and bats-assert are loaded" {
    run echo "hello"
    assert_success
    assert_output "hello"
}

@test "REPO_ROOT points at the repository under test" {
    assert [ -f "$REPO_ROOT/sv-helper.sh" ]
    assert [ -f "$REPO_ROOT/rsvlog.sh" ]
}

@test "each test gets its own writable scratch directory" {
    assert [ -d "$TEST_TMP" ]
    echo "written" > "$TEST_TMP/file"
    assert [ -f "$TEST_TMP/file" ]
}
