#!/bin/sh
# Builds the release payload: the archives, the individual scripts, and
# their checksums. Everything downstream - manual download, the Homebrew
# formula, packslip - consumes exactly these files.
#
#   ci/build_release_payload.sh VERSION [OUTDIR]
#
# VERSION is the semver version with no leading v (3.6.0). OUTDIR defaults
# to dist/.
#
# The contents come from an explicit list, never from "everything in the
# working tree", so an untracked checkout sitting in the repository - a
# local packslip clone, a scratch directory - can never end up in a
# release. The archives are built reproducibly (sorted entries, fixed
# timestamps, no owner names, gzip without its own timestamp), so building
# the same commit twice produces the same bytes and the recovery path in
# publish_release_assets.sh can insist on that.

set -e

VERSION=$1
OUTDIR=${2:-dist}

[ -n "$VERSION" ] || {
	echo "Usage: $0 VERSION [OUTDIR]" >&2
	exit 2
}

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
NAME=sv-helper
TREE="$NAME-$VERSION"

# SOURCE:DESTINATION, relative to the repository root and the archive root.
# Add a line here when a new file becomes part of what we ship.
FILES="
sv-helper.sh:bin/sv-helper
rsvlog.sh:bin/rsvlog
runsvdir.sh:bin/runsvdir.sh
install.sh:install.sh
etc/runit/1:etc/runit/1
etc/runit/2:etc/runit/2
etc/runit/3:etc/runit/3
etc/runit/ctrlaltdel:etc/runit/ctrlaltdel
container/Containerfile:container/Containerfile
container/sv/hello/run:container/sv/hello/run
container/sv/hello/log/conf:container/sv/hello/log/conf
container/sv/crasher/run:container/sv/crasher/run
README.md:share/doc/sv-helper/README.md
COPYING:share/doc/sv-helper/COPYING
CHANGELOG.md:share/doc/sv-helper/CHANGELOG.md
conf:share/doc/sv-helper/conf.example
"

# Executables, by their path in the archive.
EXECUTABLES="
bin/sv-helper
bin/rsvlog
bin/runsvdir.sh
install.sh
etc/runit/1
etc/runit/2
etc/runit/3
etc/runit/ctrlaltdel
container/sv/hello/run
container/sv/crasher/run
"

# Command links, all to bin/sv-helper, so a consumer that just unpacks the
# archive and puts bin/ on PATH gets every command without running the
# installer.
ALIASES="sv-start sv-stop sv-restart sv-list svls sv-enable sv-disable sv-find"

# Standalone copies of the scripts, for anyone who wants one file rather
# than the suite. SOURCE:ASSET-NAME.
SCRIPTS="
rsvlog.sh:rsvlog
sv-helper.sh:sv-helper.sh
runsvdir.sh:runsvdir.sh
"

# The shell scripts are identical on every platform; the two archives exist
# so each one records the OS it is supported on rather than claiming to run
# anywhere unchecked.
#
# Their names carry no version, so that release.toml - which packslip
# needs to give an exact path, not a glob - can be a static checked-in
# file rather than something generated per release. The version is still
# in the tag, in the download URL, in the directory inside the archive,
# and in the signed release statement.
PLATFORMS="linux darwin"

die() {
	echo "$0: $*" >&2
	exit 1
}

mkdir -p "$OUTDIR"
OUTDIR=$(cd "$OUTDIR" && pwd -P)

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/sv-helper-payload.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT INT TERM

echo "Staging $TREE"
for entry in $FILES
do
	src=${entry%%:*}
	dest=${entry#*:}
	[ -f "$ROOT/$src" ] || die "missing source file: $src"
	mkdir -p "$STAGE/$TREE/$(dirname "$dest")"
	cp "$ROOT/$src" "$STAGE/$TREE/$dest"
	chmod 0644 "$STAGE/$TREE/$dest"
done

for exe in $EXECUTABLES
do
	[ -f "$STAGE/$TREE/$exe" ] || die "executable not staged: $exe"
	chmod 0755 "$STAGE/$TREE/$exe"
done

for name in $ALIASES
do
	ln -s sv-helper "$STAGE/$TREE/bin/$name"
done

# Reproducible archives: GNU tar can pin order, times and ownership. Other
# tars cannot, and a release built with one would not match a rebuild.
# Homebrew's gnu-tar installs it as gtar, so prefer that name when present.
TAR=tar
command -v gtar >/dev/null 2>&1 && TAR=gtar
if ! "$TAR" --version 2>/dev/null | head -1 | grep -q 'GNU tar'
then
	die "GNU tar is required to build reproducible archives (brew install gnu-tar on macOS)"
fi

for platform in $PLATFORMS
do
	archive="$OUTDIR/$NAME-$platform.tar.gz"
	echo "Building $(basename "$archive")"
	"$TAR" --sort=name \
		--mtime='UTC 2020-01-01' \
		--owner=0 --group=0 --numeric-owner \
		--format=gnu \
		-C "$STAGE" -cf - "$TREE" |
		gzip -9 -n >"$archive"
done

for entry in $SCRIPTS
do
	src=${entry%%:*}
	asset=${entry#*:}
	cp "$ROOT/$src" "$OUTDIR/$asset"
	chmod 0755 "$OUTDIR/$asset"
	echo "Copied $asset"
done

# One checksum file over every published asset, in a stable order, written
# aside and moved into place so it never digests a half-written copy of
# itself.
(
	cd "$OUTDIR"
	rm -f SHA256SUMS
	for file in *
	do
		[ -f "$file" ] || continue
		if command -v sha256sum >/dev/null 2>&1
		then
			sha256sum "$file"
		else
			shasum -a 256 "$file"
		fi
	done | LC_ALL=C sort -k2 >.SHA256SUMS.new
	mv .SHA256SUMS.new SHA256SUMS
)

echo
echo "Payload in $OUTDIR:"
cat "$OUTDIR/SHA256SUMS"

# vim: set noet ts=8 sw=8 sts=8
