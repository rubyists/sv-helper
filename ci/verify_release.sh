#!/bin/sh
# Verifies a published release from the outside, the way a consumer would:
# download every asset, check each against the release's own SHA256SUMS,
# confirm the expected files are all there, and unpack the archive to see
# that the commands and their permissions survived the round trip.
#
#   ci/verify_release.sh TAG [--repo OWNER/REPO]
#
# Run by the release workflow once a release is published, and by hand
# when checking a release that already went out.

set -e

TAG=$1
shift 2>/dev/null || true

REPO=${GH_REPO:-rubyists/sv-helper}
while [ $# -gt 0 ]; do
	case "$1" in
	--repo)
		REPO=$2
		shift 2
		;;
	*)
		echo "Unknown option '$1'" >&2
		exit 2
		;;
	esac
done

[ -n "$TAG" ] || {
	echo "Usage: $0 TAG [--repo OWNER/REPO]" >&2
	exit 2
}

VERSION=${TAG#v}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sv-helper-verify.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

fail() {
	echo "verify: $*" >&2
	exit 1
}

echo "Downloading $TAG from $REPO"
gh release download "$TAG" --repo "$REPO" --dir "$WORK" --clobber

[ -f "$WORK/SHA256SUMS" ] || fail "the release has no SHA256SUMS asset"

echo "Checking every asset against SHA256SUMS"
(
	cd "$WORK"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum -c SHA256SUMS
	else
		shasum -a 256 -c SHA256SUMS
	fi
) || fail "a published asset does not match its checksum"

# The payload the installer and Homebrew both consume. A release
# missing one of these is incomplete, however green the workflow looked.
for required in \
	sv-helper-linux.tar.gz \
	sv-helper-darwin.tar.gz \
	rsvlog sv-helper.sh runsvdir.sh; do
	[ -f "$WORK/$required" ] || fail "the release is missing $required"
done
echo "All expected assets are present"

# An archive nobody can unpack, or one missing the commands, passes a
# checksum check perfectly well.
unpack="$WORK/unpack"
mkdir -p "$unpack"
tar -xzf "$WORK/sv-helper-linux.tar.gz" -C "$unpack" ||
	fail "the linux archive does not unpack"
tree="$unpack/sv-helper-$VERSION"
for expected in bin/sv-helper bin/rsvlog bin/runsvdir.sh install.sh etc/runit/3; do
	[ -e "$tree/$expected" ] || fail "the archive is missing $expected"
done
[ -x "$tree/bin/sv-helper" ] || fail "bin/sv-helper is not executable in the archive"
for alias_name in sv-start sv-stop sv-restart sv-list svls sv-enable sv-disable sv-find; do
	[ -L "$tree/bin/$alias_name" ] || fail "the archive is missing the $alias_name link"
done
echo "The archive contains the commands and keeps their permissions"

echo
echo "$TAG verified"

# vim: set noet ts=8 sw=8 sts=8
