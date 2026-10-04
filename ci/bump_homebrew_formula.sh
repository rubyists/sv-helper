#!/bin/sh
# Points the Homebrew formula at a new sv-helper release: writes the
# version into the formula's `.version` file - its single source of truth,
# which the formula interpolates into each url itself - and replaces the
# sha256 beside each platform's url with the digest from that release's
# own SHA256SUMS.
#
#   ci/bump_homebrew_formula.sh FORMULA_PATH TAG SHA256SUMS_PATH
#
# The only real logic in main.yaml's homebrew-tap-bump job, kept here so
# it can be run and checked without a CI run. Same shape as
# rubyists/linear-cli's bump script, which the tap's conventions came
# from.

set -e

FORMULA=$1
TAG=$2
SUMS=$3

if [ -z "$FORMULA" ] || [ -z "$TAG" ] || [ -z "$SUMS" ]; then
	echo "Usage: $0 FORMULA_PATH TAG SHA256SUMS_PATH" >&2
	exit 2
fi

die() {
	echo "$0: $*" >&2
	exit 1
}

[ -f "$FORMULA" ] || die "no formula at $FORMULA"
[ -f "$SUMS" ] || die "no checksums at $SUMS"

# The formula's urls hardcode a literal v before the interpolated version
# (v#{version}/<asset>). A tag without that prefix would quietly write a
# .version that does not match what the url then asks for.
case "$TAG" in
v*) ;;
*) die "TAG must start with 'v' (e.g. v3.6.0), got: $TAG" ;;
esac

VERSION=${TAG#v}
VERSION_FILE="$(dirname "$FORMULA")/.version"

digest_of() {
	awk -v want="$1" '$2 == want { print $1; found = 1 } END { exit !found }' "$SUMS"
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sv-helper-bump.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
cp "$FORMULA" "$WORK/formula.rb"

for asset in sv-helper-linux.tar.gz sv-helper-darwin.tar.gz; do
	sha=$(digest_of "$asset") || die "no checksum for $asset in $SUMS"

	# A sha256 is always exactly 64 hex characters. Matching that
	# precisely rejects a truncated or malformed digest rather than
	# writing one into the formula.
	case "$sha" in
	????????????????????????????????????????????????????????????????) ;;
	*) die "checksum for $asset is not 64 characters: $sha" ;;
	esac

	# The url line is a constant in the formula - it always reads
	# v#{version}/<asset> verbatim, never a literal version - so only
	# the sha256 on the following line changes per release.
	before=$(cat "$WORK/formula.rb")
	awk -v asset="$asset" -v sha="$sha" '
		index($0, "/v#{version}/" asset "\"") { seen = 1 }
		seen && /sha256 "/ {
			sub(/sha256 "[0-9a-fA-F]*"/, "sha256 \"" sha "\"")
			seen = 0
		}
		{ print }
	' "$WORK/formula.rb" >"$WORK/next.rb"
	mv "$WORK/next.rb" "$WORK/formula.rb"

	if [ "$before" = "$(cat "$WORK/formula.rb")" ] &&
		! grep -Fq "\"$sha\"" "$WORK/formula.rb"; then
		die "could not find a url/sha256 pair for $asset in $FORMULA"
	fi
done

# Both writes happen only after every asset checked out and every
# substitution landed, so a failure above never leaves .version bumped
# while the digests still describe the previous release, or the reverse.
printf '%s\n' "$VERSION" >"$VERSION_FILE"
cp "$WORK/formula.rb" "$FORMULA"

echo "Wrote $VERSION_FILE ($VERSION) and updated $FORMULA's sha256 pairs"

# vim: set noet ts=8 sw=8 sts=8
