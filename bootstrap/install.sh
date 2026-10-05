#!/usr/bin/env bash
# Author: TJ Vanderpoel
# License: MIT
#
# Installs a published sv-helper release in one line:
#
#   curl -fsSL https://raw.githubusercontent.com/rubyists/sv-helper/main/bootstrap/install.sh | bash
#   curl -fsSL .../bootstrap/install.sh | VERSION=v4.2.0 bash
#   curl -fsSL .../bootstrap/install.sh | bash -s -- --prefix /opt/sv
#
# It downloads the release's archive for this platform, checks it against
# the release's own SHA256SUMS - and against its signature, when packslip
# is installed - and hands it to the install.sh inside it. Arguments go to
# that install.sh unchanged, and so does the environment, so PREFIX and
# DESTDIR mean what they mean there. Nothing here escalates privilege.
#
#   VERSION                  the release, v4.2.0 or 4.2.0 (default: latest)
#   SV_HELPER_DOWNLOAD_BASE  where releases are downloaded from (default:
#                            https://github.com/rubyists/sv-helper/releases),
#                            for a mirror, or a local payload in the tests
#   SV_HELPER_PACKSLIP       the packslip to verify signatures with
#                            (default: packslip, if it is on PATH)
#
# Nothing runs until the last line calls main, so a download cut off
# partway through only ever defines functions.

REPO=rubyists/sv-helper
IDENTITY_PREFIX="https://github.com/$REPO/.github/workflows/main.yaml@"
ISSUER=https://token.actions.githubusercontent.com

# One exit status per kind of failure. A failing install.sh exits with its
# own status instead.
E_TOOL=2
E_PLATFORM=3
E_RELEASE=4
E_DOWNLOAD=5
E_VERIFY=6
E_UNPACK=7
E_TEMP=8

# Global, not local to main: the EXIT trap runs after main has returned.
WORK=

say() {
	printf '%s\n' "$*"
}

complain() {
	printf 'sv-helper install: %s\n' "$*" >&2
}

cleanup() {
	if [ -n "$WORK" ]
	then
		rm -rf "$WORK"
	fi
}

require_tools() {
	local tool
	for tool in curl tar gzip uname mktemp awk
	do
		command -v "$tool" >/dev/null 2>&1 || {
			complain "$tool is required, and is not on PATH"
			exit "$E_TOOL"
		}
	done
	if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1
	then
		complain "sha256sum or shasum is required to check the download, and neither is on PATH"
		exit "$E_TOOL"
	fi
}

sha256_of() {
	local sum
	if command -v sha256sum >/dev/null 2>&1
	then
		sum=$(sha256sum "$1") || return 1
	else
		sum=$(shasum -a 256 "$1") || return 1
	fi
	printf '%s\n' "${sum%% *}"
}

# HTTPS only, redirects included. file:// is for a local payload, which
# can only be asked for by whoever sets SV_HELPER_DOWNLOAD_BASE.
fetch() {
	curl -fsSL --retry 3 --proto '=https,file' --proto-redir '=https' -o "$2" "$1"
}

# The tag GitHub's /releases/latest redirects to, resolved once, so every
# file comes from the same release even if another is published meanwhile.
latest_tag() {
	local url tag
	url=$(curl -fsSLI --retry 3 --proto '=https' --proto-redir '=https' \
		-o /dev/null -w '%{url_effective}' "$1/latest") || return 1
	tag=${url##*/tag/}
	if [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]]
	then
		printf '%s\n' "$tag"
		return 0
	fi
	return 1
}

main() {
	local base os archive tag expected actual packslip tree status

	base=${SV_HELPER_DOWNLOAD_BASE:-https://github.com/$REPO/releases}
	base=${base%/}

	require_tools

	os=$(uname -s) || {
		complain "uname -s failed, so the platform is unknown"
		exit "$E_PLATFORM"
	}
	case "$os" in
	Linux) archive=sv-helper-linux.tar.gz ;;
	Darwin) archive=sv-helper-darwin.tar.gz ;;
	*)
		complain "$os is not supported. sv-helper releases are built for Linux and macOS (Darwin)"
		exit "$E_PLATFORM"
		;;
	esac

	if [ -n "$VERSION" ]
	then
		if [[ ! $VERSION =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]
		then
			complain "VERSION=$VERSION is not a release version. Use one like v4.2.0 or 4.2.0"
			exit "$E_RELEASE"
		fi
		tag=v${VERSION#v}
	else
		tag=$(latest_tag "$base") || {
			complain "could not find the latest release at $base/latest. Set VERSION to choose one"
			exit "$E_RELEASE"
		}
	fi

	WORK=$(mktemp -d "${TMPDIR:-/tmp}/sv-helper-install.XXXXXX") || {
		complain "could not create a temporary directory in ${TMPDIR:-/tmp}"
		exit "$E_TEMP"
	}
	trap cleanup EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM

	say "Installing sv-helper $tag for $os"

	# Every release since 4.0.0 publishes SHA256SUMS, so a release without
	# one is a release that does not exist, or one that cannot be reached.
	fetch "$base/download/$tag/SHA256SUMS" "$WORK/SHA256SUMS" || {
		status=$?
		complain "could not download $tag's SHA256SUMS from $base (curl exit $status)."
		complain "Either there is no release $tag (the first with installable assets is v4.0.0), or it cannot be reached"
		exit "$E_RELEASE"
	}
	fetch "$base/download/$tag/$archive" "$WORK/$archive" || {
		status=$?
		complain "could not download $archive for $tag from $base (curl exit $status)"
		exit "$E_DOWNLOAD"
	}

	expected=$(awk -v name="$archive" '$2 == name || $2 == "*" name { print $1 }' "$WORK/SHA256SUMS") || {
		complain "could not read $tag's SHA256SUMS"
		exit "$E_VERIFY"
	}
	if [ -z "$expected" ]
	then
		complain "$tag's SHA256SUMS has no entry for $archive. Not installing it"
		exit "$E_VERIFY"
	fi
	actual=$(sha256_of "$WORK/$archive") || {
		complain "could not compute the checksum of $archive"
		exit "$E_VERIFY"
	}
	if [ "$actual" != "$expected" ]
	then
		complain "$archive does not match $tag's SHA256SUMS. Not installing it"
		complain "  expected $expected"
		complain "  got      $actual"
		exit "$E_VERIFY"
	fi
	say "Checksum verified"

	# SHA256SUMS comes from the same place as the archive, so on its own it
	# proves the download is intact, not who made it. The signature does.
	packslip=${SV_HELPER_PACKSLIP:-packslip}
	if command -v "$packslip" >/dev/null 2>&1
	then
		fetch "$base/download/$tag/packslip.sigstore.json" "$WORK/packslip.sigstore.json" || {
			complain "packslip is installed, but $tag's signature bundle could not be downloaded. Not installing it"
			exit "$E_VERIFY"
		}
		"$packslip" verify "$WORK/packslip.sigstore.json" \
			--identity-prefix "$IDENTITY_PREFIX" \
			--issuer "$ISSUER" \
			--artifact "$WORK/$archive" || {
			complain "$archive failed signature verification. Not installing it"
			exit "$E_VERIFY"
		}
		say "Signature verified"
	else
		say "Signature not checked, because packslip is not installed (https://packslip.dev)."
		say "The download was checked against $tag's SHA256SUMS."
	fi

	mkdir "$WORK/src" || {
		complain "could not create $WORK/src"
		exit "$E_UNPACK"
	}
	tar -xzf "$WORK/$archive" -C "$WORK/src" || {
		complain "could not unpack $archive"
		exit "$E_UNPACK"
	}
	tree="$WORK/src/sv-helper-${tag#v}"
	if [ ! -x "$tree/install.sh" ]
	then
		complain "$archive has no sv-helper-${tag#v}/install.sh. Not installing it"
		exit "$E_UNPACK"
	fi

	"$tree/install.sh" "$@" || {
		status=$?
		complain "install.sh exited $status"
		exit "$status"
	}
}

main "$@"

# vim: set noet ts=8 sw=8 sts=8
