#!/bin/sh
# Author: TJ Vanderpoel
# License: MIT
#
# Starts a runsvdir supervision tree. Usable three ways, with the same
# resolution rules in all of them:
#
#   * directly by a regular user, to supervise their own services
#   * as runit's stage 2 in a container (see etc/runit/2)
#   * from a checkout whose service definitions live beside it
#
# The tree is chosen from the environment and the invoking UID, never from
# where this script is installed, so an installed copy and a copy in a
# checkout behave the same:
#
#   SVDIR     supervise exactly this directory. Always wins.
#   SV_ROOT   pick $SV_ROOT/service/<tree> by hostname (see below).
#   neither   the invoking user's default tree:
#               macOS (any UID)  $(brew --prefix)/var/service
#               Linux as root    /var/service, /service or /etc/service
#               Linux as a user  ${XDG_STATE_HOME:-$HOME/.local/state}/sv-helper/service
#
# Hostname selection, used with SV_ROOT, tries $HOSTNAME, then the hostname
# with one trailing -component removed, then two, each optionally prefixed
# with $SV_PREFIX, and falls back to "generic".
#
#   runsvdir.sh --print-svdir   print the tree it would supervise, and
#                               change nothing
#
# As runit's stage 2 it also records the tree it chose in
# ${SV_SVDIR_RECORD:-/run/runit/svdir}. Stage 3 stops exactly that tree,
# and sv-helper manages it, rather than either working it out again.

set -e

# release-please rewrites this line on every release, through the marker.
sv_version=4.3.0 # x-release-please-version

# Before anything resolves, creates or supervises a tree.
if [ "$1" = --version ]
then
	echo "runsvdir.sh (sv-helper) $sv_version"
	exit 0
fi

# Printing only, the answer is the whole of stdout, so the chatter below
# has to stay on stderr rather than being folded into it.
print_only=0
if [ "$1" = --print-svdir ]
then
	print_only=1
else
	exec 2>&1
fi

warn() {
	echo "$@" >&2
}

die() {
	warn "$@"
	exit 1
}

is_root() {
	[ "$(id -u)" -eq 0 ]
}

# Homebrew's launch agent gives a minimal PATH, so probe the standard
# prefixes rather than requiring an interactive shell environment.
brew_prefix() {
	if [ -n "$HOMEBREW_PREFIX" ]
	then
		printf '%s\n' "$HOMEBREW_PREFIX"
		return 0
	fi
	if command -v brew >/dev/null 2>&1
	then
		brew --prefix
		return 0
	fi
	for prefix in /opt/homebrew /usr/local /home/linuxbrew/.linuxbrew
	do
		if [ -x "$prefix/bin/brew" ]
		then
			printf '%s\n' "$prefix"
			return 0
		fi
	done
	return 1
}

# Homebrew's runit launch agent runs with PATH=/usr/bin:/bin:/usr/sbin:/sbin
# plus runit's own opt_bin, and nothing else - see the formula's `service`
# block. Anything started under it therefore cannot see $(brew --prefix)/bin.
# Put runit's tools back on PATH when they are missing, so a service does
# not have to know where Homebrew put them.
ensure_runit_on_path() {
	command -v runsvdir >/dev/null 2>&1 && return 0
	prefix=$(brew_prefix) || return 0
	for dir in "$prefix/opt/runit/bin" "$prefix/bin" "$prefix/sbin"
	do
		case ":$PATH:" in
		*":$dir:"*) ;;
		*) [ -d "$dir" ] && PATH="$PATH:$dir" ;;
		esac
	done
	export PATH
}

# The directory holding this script, with symlinks resolved, without
# needing realpath (which macOS does not ship).
script_dir() {
	dir=$(dirname "$0")
	target=$0
	# Follow at most a few links; a longer chain is a loop worth failing on.
	for _ in 1 2 3 4 5 6 7 8
	do
		[ -L "$target" ] || break
		link=$(readlink "$target")
		case "$link" in
		/*) target=$link ;;
		*) target="$dir/$link" ;;
		esac
		dir=$(dirname "$target")
	done
	(cd "$dir" && pwd -P)
}

# $service_root/<tree> chosen by hostname.
pick_by_hostname() {
	service_root=$1
	first_level_host="${hostname%-*}"
	second_level_host="${first_level_host%-*}"

	for candidate in \
		"$hostname" \
		"$first_level_host" \
		"$second_level_host" \
		"${SV_PREFIX}${first_level_host}" \
		"${SV_PREFIX}${second_level_host}"
	do
		[ -n "$candidate" ] || continue
		if [ -d "$service_root/$candidate" ]
		then
			printf '%s\n' "$service_root/$candidate"
			return 0
		fi
	done

	warn "No service directory found for $hostname"
	warn "Using $service_root/generic"
	printf '%s/generic\n' "$service_root"
}

default_svdir() {
	if [ "$(uname -s)" = Darwin ]
	then
		prefix=$(brew_prefix) ||
			die "Homebrew not found. sv-helper needs Homebrew's runit on macOS: https://brew.sh"
		printf '%s/var/service\n' "$prefix"
		return 0
	fi

	if is_root
	then
		for dir in /var/service /service /etc/service
		do
			if [ -d "$dir" ]
			then
				printf '%s\n' "$dir"
				return 0
			fi
		done
		printf '/var/service\n'
		return 0
	fi

	printf '%s/sv-helper/service\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# runit starts stage 3 itself, not from stage 2, so nothing stage 2 decides
# reaches it - not even the SVDIR exported below. This file is how it finds
# out. Written aside and moved into place, so a reader never sees half a
# path. Failing to write it is not worth refusing to boot over: stage 3
# falls back to asking --print-svdir, which is at least the same code.
record_svdir() {
	record=$1
	if ! printf '%s\n' "$servicedir" >"$record.$$" 2>/dev/null
	then
		warn "Could not write $record; stage 3 will have to work the tree out again"
		return 0
	fi
	if ! mv -f "$record.$$" "$record"
	then
		rm -f "$record.$$"
		warn "Could not write $record; stage 3 will have to work the tree out again"
	fi
}

# Only runit's stage 2 records anything. etc/runit/2 says so through
# SV_RUNIT_STAGE; an /etc/runit/2 that is a link straight to this script
# says so by its name. A user running this on a host leaves no record.
is_stage_2() {
	[ "${SV_RUNIT_STAGE:-}" = 2 ] || [ "$0" = /etc/runit/2 ]
}

ensure_runit_on_path

if [ -z "$HOSTNAME" ]
then
	hostname=$(hostname)
	warn "HOSTNAME not set, using $hostname"
else
	hostname=$HOSTNAME
	warn "HOSTNAME is $hostname"
fi

if [ -n "$SVDIR" ]
then
	servicedir=$SVDIR
elif [ -n "$SV_ROOT" ]
then
	[ -d "$SV_ROOT/service" ] || die "SV_ROOT is set but $SV_ROOT/service does not exist"
	servicedir=$(pick_by_hostname "$SV_ROOT/service")
else
	# A checkout that keeps its services beside this script still works,
	# as it did before SV_ROOT existed. Guarded so an installed copy in
	# /bin never mistakes the system's own /service for its checkout.
	legacy_root=$(cd "$(script_dir)/.." && pwd -P)
	if [ "$legacy_root" != "/" ] && [ -d "$legacy_root/service" ]
	then
		warn "Using $legacy_root/service beside this script; set SV_ROOT to make that explicit"
		servicedir=$(pick_by_hostname "$legacy_root/service")
	else
		servicedir=$(default_svdir)
	fi
fi

if [ "$print_only" -eq 1 ]
then
	printf '%s\n' "$servicedir"
	exit 0
fi

# Prepare the tree rather than refusing to start: a regular user running
# this directly has no stage 1 to have made it for them.
if [ ! -d "$servicedir" ]
then
	mkdir -p "$servicedir" || die "Could not create $servicedir"
	warn "Created $servicedir"
fi

# /service is where `sv` and everything else look when SVDIR is not set, so
# point it at this tree for the convenience of anything run later. It never
# replaces a real directory, and it never changes which tree is actually
# supervised - an explicit SVDIR stays exactly what was asked for.
if is_root && [ "$servicedir" != "/service" ]
then
	if [ ! -e /service ] || [ -L /service ]
	then
		ln -sfn "$servicedir" /service
	fi
fi

if is_stage_2
then
	# Absolute, because stage 3 does not start in this directory.
	servicedir=$(cd "$servicedir" && pwd)
	record_svdir "${SV_SVDIR_RECORD:-/run/runit/svdir}"
fi
# runsvdir hands its environment to every service. A service has no
# business knowing which stage started it.
unset SV_RUNIT_STAGE

SVDIR=$servicedir
export SVDIR

warn "Starting runsvdir in $servicedir"
exec runsvdir -P "$servicedir"

# vim: set noet ts=8 sw=8 sts=8
