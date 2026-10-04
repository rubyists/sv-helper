# Tests

The suite runs under [bats](https://github.com/bats-core/bats-core), which
is vendored here as a git submodule along with `bats-support` and
`bats-assert`. Nothing is installed system-wide.

## Running them

A fresh clone has empty submodule directories, so fetch them once:

    git submodule update --init --recursive

Then:

    make test              # every .bats file in test/
    test/bats/bin/bats test/smoke.bats     # one file
    test/bats/bin/bats --filter 'scratch' test/   # one test by name

## Writing a test

Each file starts the same way, which loads both helper libraries and sets
`REPO_ROOT` and `TEST_TMP`:

    setup() {
        load 'test_helper/common'
        common_setup
    }

`REPO_ROOT` is the checkout under test - call the scripts through it
rather than relying on `PATH`. `TEST_TMP` is a scratch directory bats
removes after each test, so a test never has to clean up after itself or
touch anything outside it.
