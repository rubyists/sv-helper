#!/bin/sh
# Author: TJ Vanderpoel
# License: MIT
#
# Installs sv-helper's scripts and their command links. Works the same from
# a checkout and from an unpacked release archive, needs neither packslip
# nor Homebrew to install sv-helper itself, and never escalates privilege:
# if a destination is not writable it says so and stops.
#
#   ./install.sh                      install under the default prefix
#   ./install.sh install --prefix ~/.local
#   ./install.sh uninstall            remove exactly what install put there
#
# The runit stages for a container are installed by the installed
# sv-helper, not by this script: `sv-helper install-stages`.
#
# PREFIX is where the files will live when they run. DESTDIR is a staging
# root prepended at install time only, for package builds; nothing resolves
# against it at runtime. Both may be given as flags or in the environment.

set -e

PROG=$(basename "$0")

# Installed name -> the names it may be called in the source tree. An
# unpacked release archive ships bin/<name>; a checkout ships <name>.sh.
COMMANDS="sv-helper rsvlog runsvdir.sh"
# Alias links, all pointing at sv-helper.
ALIASES="sv-start sv-stop sv-restart sv-list svls sv-enable sv-disable sv-find"
DOCS="Readme.adoc COPYING CHANGELOG.md"
# The runit stages for a container, installed as sv-helper's own data for
# `sv-helper install-stages` to copy into /etc/runit. Nothing boots from
# where this puts them.
STAGES="1 2 3 ctrlaltdel"

FORCE=0
DRY_RUN=0

warn() {
	echo "$@" >&2
}

die() {
	warn "$PROG: $*"
	exit 1
}

run() {
	if [ "$DRY_RUN" -eq 1 ]
	then
		echo "would: $*"
		return 0
	fi
	"$@"
}

usage() {
	cat <<USAGE
Usage: $PROG [COMMAND] [OPTIONS]

Commands:
  install            Install the scripts and command links (default)
  uninstall          Remove the files and links install created
  help               Show this message

Options:
  --prefix DIR       Runtime prefix (default: $(default_prefix))
  --destdir DIR      Staging root, prepended at install time only
  --bindir DIR       Override PREFIX/bin
  --docdir DIR       Override PREFIX/share/doc/sv-helper
  --force            Replace files and links this installer did not create
  --dry-run          Print what would happen, change nothing

The runit stages for a container: sv-helper install-stages -h
USAGE
}

default_prefix() {
	if [ "$(id -u)" -eq 0 ]
	then
		echo /usr/local
	else
		echo "$HOME/.local"
	fi
}

# The directory this script was unpacked or checked out into.
source_dir() {
	dir=$(dirname "$0")
	(cd "$dir" && pwd -P)
}

# Where the file for installed name $1 lives in the source tree.
source_for() {
	name=$1
	for candidate in "$SRC/bin/$name" "$SRC/$name.sh" "$SRC/$name"
	do
		if [ -f "$candidate" ]
		then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

doc_source_for() {
	name=$1
	for candidate in "$SRC/share/doc/sv-helper/$name" "$SRC/$name"
	do
		if [ -f "$candidate" ]
		then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

stage_source_for() {
	stage=$1
	[ -f "$SRC/etc/runit/$stage" ] || return 1
	printf '%s\n' "$SRC/etc/runit/$stage"
}

# A destination is safe to write when it is absent, or already exactly what
# we would write. Anything else is someone else's file, and saying so beats
# silently replacing it.
check_file_conflict() {
	src=$1
	dest=$2
	[ -e "$dest" ] || [ -L "$dest" ] || return 0
	[ "$FORCE" -eq 1 ] && return 0
	if [ -L "$dest" ]
	then
		die "$dest is a symlink to $(readlink "$dest"), not a file this installer wrote.
Remove it, or re-run with --force."
	fi
	[ -d "$dest" ] && die "$dest is a directory. Remove it, or choose another --bindir."
	cmp -s "$src" "$dest" && return 0
	die "$dest already exists with different contents.
Remove it, or re-run with --force."
}

check_link_conflict() {
	target=$1
	dest=$2
	[ -e "$dest" ] || [ -L "$dest" ] || return 0
	[ "$FORCE" -eq 1 ] && return 0
	if [ -L "$dest" ]
	then
		[ "$(readlink "$dest")" = "$target" ] && return 0
		die "$dest is a symlink to $(readlink "$dest"), not to $target.
Remove it, or re-run with --force."
	fi
	die "$dest already exists and is not a symlink to $target.
Remove it, or re-run with --force."
}

ensure_dir() {
	dir=$1
	[ -d "$dir" ] && return 0
	run mkdir -p "$dir" || die "Could not create $dir"
}

require_writable() {
	dir=$1
	[ "$DRY_RUN" -eq 1 ] && return 0
	[ -w "$dir" ] || die "$dir is not writable by $(id -un).
Choose a --prefix you own, or re-run this installer as its owner."
}

install_file() {
	src=$1
	dest=$2
	mode=$3
	check_file_conflict "$src" "$dest"
	run rm -f "$dest"
	run cp "$src" "$dest"
	run chmod "$mode" "$dest"
	echo "installed $dest"
}

install_link() {
	target=$1
	dest=$2
	check_link_conflict "$target" "$dest"
	run rm -f "$dest"
	run ln -s "$target" "$dest"
	echo "linked    $dest -> $target"
}

# Remove only what we put there. An unrelated file at the same path is left
# alone and reported, so an uninstall never eats a neighbour's work.
remove_file() {
	src=$1
	dest=$2
	[ -e "$dest" ] || [ -L "$dest" ] || return 0
	if [ "$FORCE" -eq 0 ] && [ -f "$src" ] && [ ! -L "$dest" ] && ! cmp -s "$src" "$dest"
	then
		warn "skipping $dest: contents differ from what was installed"
		return 0
	fi
	run rm -f "$dest"
	echo "removed   $dest"
}

remove_link() {
	target=$1
	dest=$2
	[ -L "$dest" ] || {
		[ -e "$dest" ] && warn "skipping $dest: not a symlink"
		return 0
	}
	if [ "$FORCE" -eq 0 ] && [ "$(readlink "$dest")" != "$target" ]
	then
		warn "skipping $dest: points at $(readlink "$dest"), not $target"
		return 0
	fi
	run rm -f "$dest"
	echo "removed   $dest"
}

do_install() {
	ensure_dir "$BIN"
	require_writable "$BIN"
	ensure_dir "$DOC"
	require_writable "$DOC"

	for name in $COMMANDS
	do
		src=$(source_for "$name") || die "Could not find $name in $SRC"
		install_file "$src" "$BIN/$name" 0755
	done

	for name in $ALIASES
	do
		install_link sv-helper "$BIN/$name"
	done

	for name in $DOCS
	do
		src=$(doc_source_for "$name") || continue
		install_file "$src" "$DOC/$name" 0644
	done

	ensure_dir "$STAGEDIR"
	require_writable "$STAGEDIR"
	for stage in $STAGES
	do
		src=$(stage_source_for "$stage") || die "Could not find runit stage $stage in $SRC"
		install_file "$src" "$STAGEDIR/$stage" 0755
	done

	echo
	echo "sv-helper installed in $BIN"
	case ":$PATH:" in
	*":$PREFIX/bin:"*) ;;
	*) [ -n "$DESTDIR" ] || warn "Note: $PREFIX/bin is not on your PATH" ;;
	esac
}

do_uninstall() {
	for name in $ALIASES
	do
		remove_link sv-helper "$BIN/$name"
	done

	for name in $COMMANDS
	do
		src=$(source_for "$name") || src=
		remove_file "$src" "$BIN/$name"
	done

	for name in $DOCS
	do
		src=$(doc_source_for "$name") || src=
		remove_file "$src" "$DOC/$name"
	done

	for stage in $STAGES
	do
		src=$(stage_source_for "$stage") || src=
		remove_file "$src" "$STAGEDIR/$stage"
	done

	# Only if we emptied them; a directory someone else also uses stays.
	for dir in "$DOC" "$STAGEDIR" "$(dirname "$STAGEDIR")"
	do
		[ -d "$dir" ] && rmdir "$dir" 2>/dev/null && echo "removed   $dir"
	done
	return 0
}

SRC=$(source_dir)

command=install
case "${1:-}" in
install | uninstall)
	command=$1
	shift
	;;
install-stages | uninstall-stages)
	die "$1 moved into sv-helper itself, so it works after sv-helper is installed.
Install sv-helper, then run: sv-helper $1"
	;;
help | -h | --help)
	usage
	exit 0
	;;
-*) ;;
"") ;;
*) die "Unknown command '$1'. Try '$PROG help'." ;;
esac

while [ $# -gt 0 ]
do
	case "$1" in
	--prefix)
		PREFIX=$2
		shift 2
		;;
	--destdir)
		DESTDIR=$2
		shift 2
		;;
	--bindir)
		BINDIR=$2
		shift 2
		;;
	--docdir)
		DOCDIR=$2
		shift 2
		;;
	--force)
		FORCE=1
		shift
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "Unknown option '$1'. Try '$PROG help'." ;;
	esac
done

PREFIX=${PREFIX:-$(default_prefix)}
BINDIR=${BINDIR:-$PREFIX/bin}
DOCDIR=${DOCDIR:-$PREFIX/share/doc/sv-helper}

BIN="$DESTDIR$BINDIR"
DOC="$DESTDIR$DOCDIR"
# Beside BINDIR, not under PREFIX: the installed sv-helper looks for its
# stages relative to where it is, so a --bindir of its own still finds them.
STAGEDIR="$DESTDIR$(dirname "$BINDIR")/share/sv-helper/runit"

case "$command" in
install) do_install ;;
uninstall) do_uninstall ;;
esac

# vim: set noet ts=8 sw=8 sts=8
