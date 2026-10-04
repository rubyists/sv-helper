#!/usr/bin/env bash
# Loaded by every .bats file:
#
#   setup() {
#       load 'test_helper/common'
#       common_setup
#   }
#
# Keeps the per-file boilerplate to those two lines, so a test file is
# about sv-helper and not about bats.

# shellcheck disable=SC2034  # read by bats, not by this file
BATS_LIB_PATH="${BATS_TEST_DIRNAME}/test_helper"

common_setup() {
	# `run -N` and `run !` need this; declaring it once here keeps every
	# suite from having to remember.
	bats_require_minimum_version 1.5.0

	load "${BATS_TEST_DIRNAME}/test_helper/bats-support/load"
	load "${BATS_TEST_DIRNAME}/test_helper/bats-assert/load"

	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd -P)
	export REPO_ROOT

	# One scratch directory per test, removed by common_teardown. $BATS_TEST_TMPDIR
	# is already per-test, but tests want a name they can nest under.
	TEST_TMP="${BATS_TEST_TMPDIR}/work"
	mkdir -p "$TEST_TMP"
	export TEST_TMP
}

common_teardown() {
	:
}
