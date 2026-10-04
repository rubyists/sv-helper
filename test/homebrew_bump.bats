#!/usr/bin/env bats
# ci/bump_homebrew_formula.sh, which is the whole of what the tap-update
# job does. A wrong digest here ships a formula that refuses to install,
# or worse installs something nobody signed, so it is checked here rather
# than discovered in the tap.

setup() {
    load 'test_helper/common'
    load 'test_helper/sv'
    common_setup

    BUMP="$REPO_ROOT/ci/bump_homebrew_formula.sh"
    FORMULA_DIR="$TEST_TMP/Formula/sv-helper"
    FORMULA="$FORMULA_DIR/sv-helper.rb"
    mkdir -p "$FORMULA_DIR"

    cat > "$FORMULA" <<'RUBY'
class SvHelper < Formula
  version File.read(File.expand_path(".version", __dir__)).chomp

  on_macos do
    url "https://github.com/rubyists/sv-helper/releases/download/v#{version}/sv-helper-darwin.tar.gz"
    sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  end

  on_linux do
    url "https://github.com/rubyists/sv-helper/releases/download/v#{version}/sv-helper-linux.tar.gz"
    sha256 "1111111111111111111111111111111111111111111111111111111111111111"
  end
end
RUBY
    echo "3.5.0" > "$FORMULA_DIR/.version"

    LINUX_SHA=aaaa000000000000000000000000000000000000000000000000000000000001
    DARWIN_SHA=bbbb000000000000000000000000000000000000000000000000000000000002
    SUMS="$TEST_TMP/SHA256SUMS"
    {
        echo "$DARWIN_SHA  sv-helper-darwin.tar.gz"
        echo "$LINUX_SHA  sv-helper-linux.tar.gz"
        echo "cccc000000000000000000000000000000000000000000000000000000000003  rsvlog"
    } > "$SUMS"
}

@test "writes the version into the formula's .version file" {
    run "$BUMP" "$FORMULA" v3.6.0 "$SUMS"
    assert_success
    assert_equal "$(cat "$FORMULA_DIR/.version")" "3.6.0"
}

@test "writes each platform's digest beside its own url" {
    "$BUMP" "$FORMULA" v3.6.0 "$SUMS"

    # The darwin url comes first in the formula, so a substitution that
    # ignored which url it was under would put the linux digest there.
    run grep -A1 'sv-helper-darwin.tar.gz' "$FORMULA"
    assert_output --partial "$DARWIN_SHA"

    run grep -A1 'sv-helper-linux.tar.gz' "$FORMULA"
    assert_output --partial "$LINUX_SHA"
}

@test "leaves the url lines alone" {
    "$BUMP" "$FORMULA" v3.6.0 "$SUMS"
    # They interpolate #{version} themselves, so they are constants and
    # must survive untouched.
    run grep -c 'v#{version}/sv-helper-' "$FORMULA"
    assert_output "2"
}

@test "a tag without the v prefix is refused" {
    # The urls hardcode a literal v, so a bare version would write a
    # .version that does not match what the url then requests.
    run "$BUMP" "$FORMULA" 3.6.0 "$SUMS"
    assert_failure
    assert_output --partial "must start with 'v'"
    assert_equal "$(cat "$FORMULA_DIR/.version")" "3.5.0"
}

@test "a missing checksum stops the bump and changes nothing" {
    grep -v 'sv-helper-darwin' "$SUMS" > "$SUMS.partial"
    mv "$SUMS.partial" "$SUMS"

    run "$BUMP" "$FORMULA" v3.6.0 "$SUMS"
    assert_failure
    assert_output --partial "no checksum for sv-helper-darwin.tar.gz"
    # Neither half may land on its own: a bumped .version with stale
    # digests is a formula that downloads the new release and rejects it.
    assert_equal "$(cat "$FORMULA_DIR/.version")" "3.5.0"
    run grep -c '0000000000000000000000000000000000000000000000000000000000000000' "$FORMULA"
    assert_output "1"
}

@test "a truncated digest is refused rather than written" {
    echo "dead  sv-helper-linux.tar.gz" > "$SUMS"
    echo "$DARWIN_SHA  sv-helper-darwin.tar.gz" >> "$SUMS"

    run "$BUMP" "$FORMULA" v3.6.0 "$SUMS"
    assert_failure
    assert_output --partial "not 64 characters"
}

@test "running it twice for the same release changes nothing the second time" {
    "$BUMP" "$FORMULA" v3.6.0 "$SUMS"
    cp "$FORMULA" "$TEST_TMP/first.rb"

    "$BUMP" "$FORMULA" v3.6.0 "$SUMS"

    # This is what keeps a re-run from opening a second tap pull request:
    # create-pull-request opens nothing when the tree is unchanged.
    run diff "$TEST_TMP/first.rb" "$FORMULA"
    assert_success
}

@test "a missing formula is reported" {
    run "$BUMP" "$TEST_TMP/nowhere.rb" v3.6.0 "$SUMS"
    assert_failure
    assert_output --partial "no formula at"
}
