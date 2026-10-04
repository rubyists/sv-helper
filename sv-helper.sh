#!/bin/sh
# Author: bougyman <tj@rubyists.com>
# License: MIT
# This utility adds helper commands for administering runit services.
#
# Every path it uses is resolved from the environment and the invoking UID,
# never from where this script happens to be installed, so it behaves the
# same run from a checkout, from /usr/bin, from ~/.local/bin, or from a
# packslip tree.
#
# Overrides, honoured in this order and never second-guessed:
#
#   SVDIR           the enabled service tree runsvdir supervises
#   SV_SOURCE_DIR   where service definitions live (searched before the
#                   built-in locations; may be a colon-separated list)
#   HOMEBREW_PREFIX  macOS/Linuxbrew prefix, when `brew` is not on PATH

set -e

commands="sv-list svls sv-find sv-enable sv-disable sv-start sv-stop sv-restart"

sv_uname=$(uname -s)

warn() {
	echo "$@" >&2
}

die() {
	status=$1
	shift
	warn "$@"
	exit "$status"
}

# Resolve one symlink to an absolute path without readlink -f, which older
# macOS does not have.
sv_readlink() {
	link=$1
	target=$(readlink "$link") || return 1
	case "$target" in
	/*) printf '%s\n' "$target" ;;
	*)
		dir=$(cd "$(dirname "$link")" && cd "$(dirname "$target")" && pwd) || return 1
		printf '%s/%s\n' "$dir" "$(basename "$target")"
		;;
	esac
}

# macOS runs on Homebrew's runit, so its prefix is the root of everything.
# Homebrew's launch agent gives a minimal PATH, so fall back to probing the
# standard prefixes rather than requiring an interactive shell environment.
sv_brew_prefix() {
	if [ -n "$HOMEBREW_PREFIX" ]; then
		printf '%s\n' "$HOMEBREW_PREFIX"
		return 0
	fi
	if command -v brew >/dev/null 2>&1; then
		brew --prefix
		return 0
	fi
	for prefix in /opt/homebrew /usr/local /home/linuxbrew/.linuxbrew; do
		if [ -x "$prefix/bin/brew" ]; then
			printf '%s\n' "$prefix"
			return 0
		fi
	done
	return 1
}

sv_require_brew_prefix() {
	sv_brew_prefix || die 127 \
		"Homebrew not found. sv-helper needs Homebrew's runit on macOS: https://brew.sh"
}

# Homebrew's runit launch agent runs with PATH=/usr/bin:/bin:/usr/sbin:/sbin
# plus runit's own opt_bin, and nothing else - see the formula's `service`
# block. Anything started under it therefore cannot see $(brew --prefix)/bin.
# Put runit's tools back on PATH when they are missing, so a service does
# not have to know where Homebrew put them.
sv_ensure_runit_on_path() {
	command -v sv >/dev/null 2>&1 && return 0
	prefix=$(sv_brew_prefix) || return 0
	for dir in "$prefix/opt/runit/bin" "$prefix/bin" "$prefix/sbin"; do
		case ":$PATH:" in
		*":$dir:"*) ;;
		*) [ -d "$dir" ] && PATH="$PATH:$dir" ;;
		esac
	done
	export PATH
}

sv_state_home() {
	printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

sv_config_home() {
	printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

sv_is_root() {
	[ "$(id -u)" -eq 0 ]
}

# The enabled service tree. A non-root invocation never selects a system
# tree, however writable that tree happens to be.
svdir() {
	if [ -n "$SVDIR" ]; then
		[ -d "$SVDIR" ] || die 127 "No service directory found at \$SVDIR ($SVDIR)"
		printf '%s\n' "$SVDIR"
		return 0
	fi

	if [ "$sv_uname" = Darwin ]; then
		prefix=$(sv_require_brew_prefix) || exit $?
		printf '%s/var/service\n' "$prefix"
		return 0
	fi

	if sv_is_root; then
		for dir in /var/service /service /etc/service; do
			if [ -d "$dir" ]; then
				printf '%s\n' "$dir"
				return 0
			fi
		done
		die 127 "No service directory found (tried /var/service, /service, /etc/service)"
	fi

	printf '%s/sv-helper/service\n' "$(sv_state_home)"
}

# Where service definitions are looked for, most specific first. Printed one
# per line so paths containing spaces survive.
sv_source_dirs() {
	if [ -n "$SV_SOURCE_DIR" ]; then
		printf '%s\n' "$SV_SOURCE_DIR" | tr ':' '\n'
		return 0
	fi

	ln_dir=$(svdir) || exit $?

	if [ "$sv_uname" = Darwin ]; then
		prefix=$(sv_require_brew_prefix) || exit $?
		printf '%s/etc/sv\n' "$prefix"
		printf '%s/var/sv\n' "$prefix"
	elif sv_is_root; then
		printf '/etc/sv\n'
	else
		printf '%s/sv-helper/sv\n' "$(sv_config_home)"
	fi

	# Trees that keep their definitions beside the enabled directory.
	printf '%s/../sv\n' "$ln_dir"
	printf '%s/../Service\n' "$ln_dir"
	printf '%s/../Services\n' "$ln_dir"
}

# Locate a service: an enabled symlink wins, then the definition directories.
find_service() {
	service=$1
	[ -n "$service" ] || return 0

	ln_dir=$(svdir) || exit $?
	if [ -L "$ln_dir/$service" ]; then
		if location=$(sv_readlink "$ln_dir/$service"); then
			printf '%s\n' "$location"
			return 0
		fi
	elif [ -d "$ln_dir/$service" ]; then
		printf '%s\n' "$ln_dir/$service"
		return 0
	fi

	sv_source_dirs | while IFS= read -r dir; do
		if [ -d "$dir/$service" ]; then
			printf '%s\n' "$dir/$service"
			break
		fi
	done
}

# Report, rather than silently escalating. Managing another user's services
# is a deliberate act, so it stays the caller's to make.
require_writable() {
	dir=$1
	what=$2
	[ -w "$dir" ] || die 13 "Cannot $what: $dir is not writable by $(id -un).
Re-run as its owner, or point SVDIR at a tree you own."
}

# Create the invoking user's tree on demand; a system tree is never created.
ensure_svdir() {
	ln_dir=$1
	[ -d "$ln_dir" ] && return 0
	sv_is_root && die 127 "No service directory found at $ln_dir"
	mkdir -p "$ln_dir" || die 1 "Could not create $ln_dir"
	warn "Created $ln_dir"
}

# Symlink a service definition into the enabled tree.
enable_service() {
	service=$1
	[ -n "$service" ] || die 1 "$(usage sv-enable)"
	warn "Enabling $service"

	source_dir=$(find_service "$service")
	if [ -z "$source_dir" ] || [ ! -d "$source_dir" ]; then
		die 1 "No such service '$service'"
	fi

	ln_dir=$(svdir) || exit $?
	ensure_svdir "$ln_dir"
	if [ -L "$ln_dir/$service" ] || [ -d "$ln_dir/$service" ]; then
		warn "Service already enabled!"
		warn "  $(sv s "$ln_dir/$service" 2>&1)"
		exit 1
	fi

	require_writable "$ln_dir" "enable $service"
	ln -s "$source_dir" "$ln_dir/$service"
}

# Remove a service's symlink from the enabled tree.
disable_service() {
	service=$1
	[ -n "$service" ] || die 1 "$(usage sv-disable)"
	warn "Disabling $service"

	ln_dir=$(svdir) || exit $?
	[ -L "$ln_dir/$service" ] || die 1 "Service not enabled!"
	require_writable "$ln_dir" "disable $service"
	rm "$ln_dir/$service"
}

# Status of one service, or of every enabled service.
list() {
	ln_dir=$(svdir) || exit $?
	if [ -n "$1" ]; then
		sv s "$ln_dir/$1"
		return 0
	fi

	echo "Listing All Services"
	found=0
	for entry in "$ln_dir"/*; do
		[ -e "$entry" ] || continue
		found=1
		sv s "$entry" || true
	done
	[ "$found" -eq 1 ] || echo "No services enabled in $ln_dir"
}

# Names of every available service definition, deduplicated across sources.
available() {
	sv_source_dirs | while IFS= read -r dir; do
		[ -d "$dir" ] || continue
		for entry in "$dir"/*; do
			[ -d "$entry" ] || continue
			basename "$entry"
		done
	done | sort -u
}

# Act on a service through `sv`, resolving it the same way `sv-find` does.
control() {
	action=$1
	service=$2
	[ -n "$service" ] || die 1 "Which service? ($(available | tr '\n' ' '))"
	target=$(find_service "$service")
	[ -n "$target" ] || die 1 "No such service '$service'"
	sv "$action" "$target"
}

# Deprecated: `install.sh` owns installation. Kept so an existing checkout
# that calls it keeps working.
make_links() {
	me=$0
	here=$(cd "$(dirname "$me")" && pwd)
	warn "make-links is deprecated; use ./install.sh instead"
	for link in $commands; do
		[ -L "$here/$link" ] || ln -s "$(basename "$me")" "$here/$link"
	done
}

# Every path this invocation would use, for diagnosing a surprising default.
paths() {
	printf 'uname:        %s\n' "$sv_uname"
	printf 'uid:          %s (%s)\n' "$(id -u)" "$(id -un)"
	ln_dir=$(svdir) || exit $?
	printf 'svdir:        %s\n' "$ln_dir"
	printf 'source dirs:  %s\n' "$(sv_source_dirs | tr '\n' ' ')"
}

usage() {
	cmd=$1
	case "$cmd" in
	sv-enable) echo "sv-enable <service> - Enable a service and start it (will restart on boots)" ;;
	sv-disable) echo "sv-disable <service> - Disable a service from starting (also stop the service)" ;;
	sv-stop) echo "sv-stop <service> - Stop a service (will come back on reboot)" ;;
	sv-start) echo "sv-start <service> - Start a stopped service" ;;
	sv-restart) echo "sv-restart <service> - Restart a running service" ;;
	svls) echo "svls [<service>] - Show list of services (Default: all services, pass a service name to see just one)" ;;
	sv-find) echo "sv-find <service> - Find a service, if it exists" ;;
	sv-list) echo "sv-list - List available services" ;;
	make-links) echo "make-links - Deprecated; use ./install.sh" ;;
	paths) echo "paths - Show the service, definition and log paths this invocation resolves" ;;
	commands)
		echo "Valid Commands: ${commands} paths make-links"
		echo "use command -h for help"
		;;
	*) echo "Invalid command (${commands})" ;;
	esac
}

# Start main program

sv_ensure_runit_on_path

cmd=$(basename "$0")
if [ "$cmd" = "sv-helper" ] || [ "$cmd" = "sv-helper.sh" ]; then
	cmd=$1
	if [ -z "$cmd" ]; then
		cmd=commands
	else
		shift
	fi
fi

# Help must work before any service directory exists, so it is answered
# before anything resolves a path.
while getopts h options; do
	case $options in
	h)
		usage "$cmd"
		exit
		;;
	*) ;;
	esac
done

case "$cmd" in
enable | sv-enable) enable_service "$1" ;;
disable | sv-disable) disable_service "$1" ;;
start | sv-start) control u "$1" ;;
restart | sv-restart) control t "$1" ;;
stop | sv-stop) control d "$1" ;;
ls | svls) list "$1" ;;
make-links) make_links ;;
paths) paths ;;
find | sv-find)
	svc=$(find_service "$1")
	[ -n "$svc" ] || die 1 "No such service '$1'"
	printf '%s\n' "$svc"
	;;
list | sv-list) available | tr '\n' ' ' && echo ;;
*) usage commands ;;
esac

# vim: set noet ts=8 sw=8 sts=8
