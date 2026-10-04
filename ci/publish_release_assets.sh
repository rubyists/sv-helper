#!/bin/sh
# Uploads a built payload to a GitHub release, idempotently.
#
#   ci/publish_release_assets.sh TAG DIR [--repo OWNER/REPO]
#
# Normally the release workflow builds the payload and attaches it to the
# draft release in one step. This script exists for the other case: a run
# that died partway through, leaving some assets up and some not. Running
# it again finishes the job.
#
# The rule it enforces is that an asset already on the release is never
# silently replaced. If the bytes match what we just built, it is skipped;
# if they differ, the script stops and says so, because that means the
# release and the payload disagree about what this version is, and
# overwriting either one hides that. Delete the asset deliberately if you
# really do mean to replace it.
#
# Needs gh authenticated with contents: write on the repository.

set -e

TAG=$1
DIR=$2
shift 2 2>/dev/null || true

REPO=${GH_REPO:-}
while [ $# -gt 0 ]
do
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

if [ -z "$TAG" ] || [ -z "$DIR" ]
then
	echo "Usage: $0 TAG DIR [--repo OWNER/REPO]" >&2
	exit 2
fi
[ -d "$DIR" ] || {
	echo "$0: $DIR is not a directory" >&2
	exit 1
}

REPO_ARGS=""
[ -n "$REPO" ] && REPO_ARGS="--repo $REPO"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sv-helper-publish.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

digest() {
	if command -v sha256sum >/dev/null 2>&1
	then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

# shellcheck disable=SC2086  # REPO_ARGS is deliberately two words or none
existing=$(gh release view "$TAG" $REPO_ARGS --json assets \
	--jq '.assets[].name' 2>/dev/null || true)

has_asset() {
	printf '%s\n' "$existing" | grep -Fxq "$1"
}

uploaded=0
skipped=0

for path in "$DIR"/*
do
	[ -f "$path" ] || continue
	name=$(basename "$path")

	if ! has_asset "$name"
	then
		echo "uploading $name"
		# shellcheck disable=SC2086
		gh release upload "$TAG" "$path" $REPO_ARGS
		uploaded=$((uploaded + 1))
		continue
	fi

	rm -rf "$WORK/check"
	mkdir -p "$WORK/check"
	# shellcheck disable=SC2086
	gh release download "$TAG" $REPO_ARGS --pattern "$name" --dir "$WORK/check"

	if [ "$(digest "$path")" = "$(digest "$WORK/check/$name")" ]
	then
		echo "skipping  $name (already published, identical)"
		skipped=$((skipped + 1))
		continue
	fi

	cat >&2 <<ERROR
$0: $name is already published with different bytes.

  built:     $(digest "$path")
  published: $(digest "$WORK/check/$name")

Refusing to replace it. Either rebuild from the released commit, or delete
the published asset first if you really mean to change it:

  gh release delete-asset $TAG $name $REPO_ARGS
ERROR
	exit 1
done

echo
echo "$uploaded uploaded, $skipped already published"

# vim: set noet ts=8 sw=8 sts=8
