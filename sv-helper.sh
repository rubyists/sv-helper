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
#   SV_SVDIR_RECORD the tree runit's stage 2 recorded it was supervising
#                   (default /run/runit/svdir); used when it is ours
#   SV_SOURCE_DIR   where service definitions live (searched before the
#                   built-in locations; may be a colon-separated list)
#   SV_STAGE_DIR    where install-stages takes the runit stages from
#   HOMEBREW_PREFIX  macOS/Linuxbrew prefix, when `brew` is not on PATH
#
# The one thing found relative to this script is the runit stages it
# ships, because they are its own files rather than anyone's services.

set -e

# release-please rewrites this line on every release, through the marker.
sv_version=4.3.0 # x-release-please-version

commands="sv-list svls sv-find sv-enable sv-disable sv-start sv-stop sv-restart"

# Container stages, and runit's control files, which are linked into
# sv_control_dir so they stay writable by whatever UID the container runs
# as, and /etc/runit never has to be. Deliberately not in $commands: these
# change how a machine boots, so they never get an alias of their own.
sv_stages="1 2 3 ctrlaltdel"
sv_controls="stopit reboot"
sv_control_dir=/run/runit
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
	for dir in "$prefix/opt/runit/bin" "$prefix/bin" "$prefix/sbin"
	do
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

# BSD and GNU stat disagree on everything except the word "stat". -L,
# because Void and others link supervise/ into /run.
owner_of() {
	stat -L -c %U "$1" 2>/dev/null || stat -L -f %Su "$1"
}

# Numeric, because a container's arbitrary UID has no name to compare.
uid_of() {
	stat -L -c %u "$1" 2>/dev/null || stat -L -f %u "$1"
}

# The tree runit's stage 2 is supervising, as runsvdir.sh recorded it when
# it started. Only a record this user wrote counts: stage 2 runs as the
# container's user, and anyone else's record describes a tree that is not
# theirs to manage.
sv_recorded_svdir() {
	record=${SV_SVDIR_RECORD:-/run/runit/svdir}
	[ -f "$record" ] || return 1
	[ "$(uid_of "$record")" = "$(id -u)" ] || return 1
	IFS= read -r recorded <"$record" || return 1
	[ -d "$recorded" ] || return 1
	printf '%s\n' "$recorded"
}

# The enabled service tree. A non-root invocation never selects a system
# tree, however writable that tree happens to be.
svdir() {
	if [ -n "$SVDIR" ]
	then
		[ -d "$SVDIR" ] || die 127 "No service directory found at \$SVDIR ($SVDIR)"
		printf '%s\n' "$SVDIR"
		return 0
	fi

	# In a container, the tree stage 2 chose - by SV_ROOT and hostname,
	# say - rather than a second opinion about it.
	if sv_recorded_svdir
	then
		return 0
	fi

	if [ "$sv_uname" = Darwin ]
	then
		prefix=$(sv_require_brew_prefix) || exit $?
		printf '%s/var/service\n' "$prefix"
		return 0
	fi

	if sv_is_root
	then
		for dir in /var/service /service /etc/service
		do
			if [ -d "$dir" ]
			then
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
	if [ -n "$SV_SOURCE_DIR" ]
	then
		printf '%s\n' "$SV_SOURCE_DIR" | tr ':' '\n'
		return 0
	fi

	ln_dir=$(svdir) || exit $?

	if [ "$sv_uname" = Darwin ]
	then
		prefix=$(sv_require_brew_prefix) || exit $?
		printf '%s/etc/sv\n' "$prefix"
		printf '%s/var/sv\n' "$prefix"
	elif sv_is_root
	then
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
	if [ -L "$ln_dir/$service" ]
	then
		if location=$(sv_readlink "$ln_dir/$service")
		then
			printf '%s\n' "$location"
			return 0
		fi
	elif [ -d "$ln_dir/$service" ]
	then
		printf '%s\n' "$ln_dir/$service"
		return 0
	fi

	sv_source_dirs | while IFS= read -r dir
	do
		if [ -d "$dir/$service" ]
		then
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

# runsv makes supervise/ 0700 and supervise/ok 0600, so only the account
# running runsv can ask it anything - sv itself refuses everyone else with
# "access denied". A supervise/ that does not exist yet is not a refusal:
# that is a service runsv has not started, which sv reports on its own.
status_denied() {
	supervise=$1/supervise
	[ -d "$supervise" ] || return 1
	[ -x "$supervise" ] || return 0
	[ -e "$supervise/ok" ] && [ ! -w "$supervise/ok" ]
}

# The command the caller just ran, as the account that can run it. sudo
# drops SVDIR, so an explicit one is passed back through env.
as_owner() {
	owner=$1
	shift
	prefix=sudo
	[ "$owner" = root ] || prefix="sudo -u $owner"
	if [ -n "$SVDIR" ]
	then
		prefix="$prefix env SVDIR=$SVDIR"
	fi
	if [ $# -gt 0 ]
	then
		echo "$prefix $invoked $*"
	else
		echo "$prefix $invoked"
	fi
}

# Report, rather than silently escalating, as require_writable does.
die_denied() {
	target=$1
	shift
	owner=$(owner_of "$target/supervise")
	die 13 "Cannot ask runsv about $(basename "$target") as $(id -un): $target/supervise belongs to $owner.
Run it as $owner instead: $(as_owner "$owner" "$@")"
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
	if [ -z "$source_dir" ] || [ ! -d "$source_dir" ]
	then
		die 1 "No such service '$service'"
	fi

	ln_dir=$(svdir) || exit $?
	ensure_svdir "$ln_dir"
	if [ -L "$ln_dir/$service" ] || [ -d "$ln_dir/$service" ]
	then
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
	if [ -n "$1" ]
	then
		if status_denied "$ln_dir/$1"
		then
			die_denied "$ln_dir/$1" "$1"
		fi
		sv s "$ln_dir/$1"
		return 0
	fi

	echo "Listing All Services"
	found=0
	denied=0
	denied_owner=
	for entry in "$ln_dir"/*
	do
		[ -e "$entry" ] || continue
		found=1
		if status_denied "$entry"
		then
			denied=$((denied + 1))
			denied_owner=${denied_owner:-$(owner_of "$entry/supervise")}
			continue
		fi
		sv s "$entry" || true
	done
	[ "$found" -eq 1 ] || echo "No services enabled in $ln_dir"

	# One summary rather than one "access denied" per service, and a
	# failing exit, so a script reading svls cannot take silence for "all
	# down".
	if [ "$denied" -gt 0 ]
	then
		die 13 "Cannot ask runsv about $denied service(s) in $ln_dir as $(id -un): they belong to $denied_owner.
Run it as $denied_owner instead: $(as_owner "$denied_owner")"
	fi
}

# Names of every available service definition, deduplicated across sources.
available() {
	sv_source_dirs | while IFS= read -r dir
	do
		[ -d "$dir" ] || continue
		for entry in "$dir"/*
		do
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
	if status_denied "$target"
	then
		die_denied "$target" "$service"
	fi
	sv "$action" "$target"
}

# Deprecated: `install.sh` owns installation. Kept so an existing checkout
# that calls it keeps working.
make_links() {
	me=$0
	here=$(cd "$(dirname "$me")" && pwd)
	warn "make-links is deprecated; use ./install.sh instead"
	for link in $commands
	do
		[ -L "$here/$link" ] || ln -s "$(basename "$me")" "$here/$link"
	done
}

# The directory holding this script, with symlinks resolved: the aliases
# are links to it, and so is whatever packslip puts on PATH.
sv_self_dir() {
	self=$0
	# Follow at most a few links; a longer chain is a loop worth failing on.
	for _ in 1 2 3 4 5 6 7 8
	do
		[ -L "$self" ] || break
		self=$(sv_readlink "$self") || return 1
	done
	(cd "$(dirname "$self")" && pwd -P)
}

# A directory holding every stage.
sv_has_stages() {
	for stage in $sv_stages
	do
		[ -f "$1/$stage" ] || return 1
	done
}

# Where install-stages takes the stages from: SV_STAGE_DIR, then an
# installation's share directory, then the source tree this script was
# unpacked or checked out in, which is only ever recognised by its
# install.sh. That keeps a copy installed in /bin from mistaking the live
# /etc/runit for its own source.
sv_stage_dirs() {
	if [ -n "$SV_STAGE_DIR" ]
	then
		printf '%s\n' "$SV_STAGE_DIR"
		return 0
	fi
	here=$(sv_self_dir) || return 0
	printf '%s\n' "$here/../share/sv-helper/runit"
	[ -f "$here/../install.sh" ] && printf '%s\n' "$here/../etc/runit"
	[ -f "$here/install.sh" ] && printf '%s\n' "$here/etc/runit"
	return 0
}

sv_stage_dir() {
	sv_stage_dirs | while IFS= read -r dir
	do
		if sv_has_stages "$dir"
		then
			(cd "$dir" && pwd -P)
			break
		fi
	done
}

stages_usage() {
	cat <<USAGE
Usage: sv-helper install-stages [OPTIONS]
       sv-helper uninstall-stages [OPTIONS]

Install, or remove, runit stages 1, 2, 3 and ctrlaltdel for a container,
and link its stopit and reboot files into $sv_control_dir. This changes how
the machine boots, so it is never done by installing sv-helper itself.

Options:
  --runit-dir DIR    Where the stages go (default: /etc/runit)
  --destdir DIR      Staging root, prepended at install time only
  --force            Replace files and links these commands did not create
  --dry-run          Print what would happen, change nothing

The stages come from \$SV_STAGE_DIR when set, and otherwise from:
$(sv_stage_dirs | sed 's/^/  /')
USAGE
}

stage_run() {
	if [ "$dry_run" -eq 1 ]
	then
		echo "would: $*"
		return 0
	fi
	"$@"
}

# A destination is safe to write when it is absent, or already exactly what
# we would write. Anything else is someone else's file, and saying so beats
# silently replacing it.
stage_check_file() {
	src=$1
	dest=$2
	[ -e "$dest" ] || [ -L "$dest" ] || return 0
	[ "$force" -eq 1 ] && return 0
	if [ -L "$dest" ]
	then
		die 1 "$dest is a symlink to $(readlink "$dest"), not a stage sv-helper wrote.
Remove it, or re-run with --force."
	fi
	[ -d "$dest" ] && die 1 "$dest is a directory. Remove it, or choose another --runit-dir."
	cmp -s "$src" "$dest" && return 0
	die 1 "$dest already exists with different contents.
Remove it, or re-run with --force."
}

stage_check_link() {
	target=$1
	dest=$2
	[ -e "$dest" ] || [ -L "$dest" ] || return 0
	[ "$force" -eq 1 ] && return 0
	if [ -L "$dest" ]
	then
		[ "$(readlink "$dest")" = "$target" ] && return 0
		die 1 "$dest is a symlink to $(readlink "$dest"), not to $target.
Remove it, or re-run with --force."
	fi
	die 1 "$dest already exists and is not a symlink to $target.
Remove it, or re-run with --force."
}

stage_install_file() {
	src=$1
	dest=$2
	stage_check_file "$src" "$dest"
	stage_run rm -f "$dest"
	stage_run cp "$src" "$dest"
	stage_run chmod 0755 "$dest"
	echo "installed $dest"
}

stage_install_link() {
	target=$1
	dest=$2
	stage_check_link "$target" "$dest"
	stage_run rm -f "$dest"
	stage_run ln -s "$target" "$dest"
	echo "linked    $dest -> $target"
}

stage_is_ours() {
	[ ! -L "$2" ] && cmp -s "$1" "$2"
}

# Remove only what we put there. An unrelated file at the same path is left
# alone and reported, so an uninstall never eats a neighbour's work.
stage_remove_file() {
	src=$1
	dest=$2
	[ -e "$dest" ] || [ -L "$dest" ] || return 0
	if [ "$force" -eq 0 ] && ! stage_is_ours "$src" "$dest"
	then
		warn "skipping $dest: not the stage sv-helper installed"
		return 0
	fi
	stage_run rm -f "$dest"
	echo "removed   $dest"
}

stage_remove_link() {
	target=$1
	dest=$2
	if [ ! -L "$dest" ]
	then
		[ -e "$dest" ] && warn "skipping $dest: not a symlink"
		return 0
	fi
	if [ "$force" -eq 0 ] && [ "$(readlink "$dest")" != "$target" ]
	then
		warn "skipping $dest: points at $(readlink "$dest"), not $target"
		return 0
	fi
	stage_run rm -f "$dest"
	echo "removed   $dest"
}

install_stages() {
	if [ ! -d "$runitdir" ]
	then
		stage_run mkdir -p "$runitdir" || die 1 "Could not create $runitdir"
	fi
	# Report, rather than silently escalating, as require_writable does.
	if [ "$dry_run" -eq 0 ] && [ ! -w "$runitdir" ]
	then
		die 13 "Cannot install the runit stages: $runitdir is not writable by $(id -un).
Re-run as its owner."
	fi
	for stage in $sv_stages
	do
		stage_install_file "$stage_dir/$stage" "$runitdir/$stage"
	done
	for control in $sv_controls
	do
		stage_install_link "$sv_control_dir/$control" "$runitdir/$control"
	done
	echo
	echo "runit stages installed in $runitdir"
}

uninstall_stages() {
	if [ -d "$runitdir" ] && [ "$dry_run" -eq 0 ] && [ ! -w "$runitdir" ]
	then
		die 13 "Cannot remove the runit stages: $runitdir is not writable by $(id -un).
Re-run as its owner."
	fi
	for stage in $sv_stages
	do
		stage_remove_file "$stage_dir/$stage" "$runitdir/$stage"
	done
	for control in $sv_controls
	do
		stage_remove_link "$sv_control_dir/$control" "$runitdir/$control"
	done
}

# install-stages and uninstall-stages, with their own options. PREFIX has
# nothing to do with where runit looks, so the stages take only a runit
# directory and a staging root.
stages_command() {
	action=$1
	shift
	runit_dir=/etc/runit
	destdir=
	force=0
	dry_run=0
	while [ $# -gt 0 ]
	do
		case "$1" in
		--runit-dir | --destdir)
			[ $# -ge 2 ] || die 1 "$1 needs a directory. Try 'sv-helper $action -h'."
			if [ "$1" = --runit-dir ]
			then
				runit_dir=$2
			else
				destdir=$2
			fi
			shift 2
			;;
		--force)
			force=1
			shift
			;;
		--dry-run)
			dry_run=1
			shift
			;;
		-h | --help)
			stages_usage
			exit 0
			;;
		*) die 1 "Unknown option '$1'. Try 'sv-helper $action -h'." ;;
		esac
	done
	runitdir="$destdir$runit_dir"

	if [ -n "$SV_STAGE_DIR" ] && ! sv_has_stages "$SV_STAGE_DIR"
	then
		die 127 "No runit stages found at \$SV_STAGE_DIR ($SV_STAGE_DIR)"
	fi
	stage_dir=$(sv_stage_dir)
	if [ -z "$stage_dir" ]
	then
		# Removing with --force needs nothing to compare against.
		if [ "$action" = uninstall-stages ] && [ "$force" -eq 1 ]
		then
			stage_dir=/nonexistent
		else
			die 127 "No runit stages found. Looked in:
$(sv_stage_dirs | sed 's/^/  /')
Set SV_STAGE_DIR to the directory holding 1, 2, 3 and ctrlaltdel."
		fi
	fi
	if [ -d "$runitdir" ] && [ "$(cd "$runitdir" && pwd -P)" = "$stage_dir" ]
	then
		die 1 "$runitdir is where the stages would come from, not somewhere to put them."
	fi

	case "$action" in
	install-stages) install_stages ;;
	uninstall-stages) uninstall_stages ;;
	esac
}

# GNU style: the package alone when called by its own name, and the alias
# with the package beside it otherwise, so `svls --version` says which
# package svls belongs to.
print_version() {
	name=$1
	if [ "$name" = sv-helper ] || [ "$name" = sv-helper.sh ]
	then
		echo "sv-helper $sv_version"
	else
		echo "$name (sv-helper) $sv_version"
	fi
}

# Every path this invocation would use, for diagnosing a surprising default.
paths() {
	printf 'uname:        %s\n' "$sv_uname"
	printf 'uid:          %s (%s)\n' "$(id -u)" "$(id -un)"
	ln_dir=$(svdir) || exit $?
	printf 'svdir:        %s\n' "$ln_dir"
	printf 'source dirs:  %s\n' "$(sv_source_dirs | tr '\n' ' ')"
	stage_dir=$(sv_stage_dir)
	printf 'stage dir:    %s\n' "${stage_dir:-(none found)}"
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
	paths) echo "paths - Show the service, definition and stage paths this invocation resolves" ;;
	version) echo "version - Show sv-helper's version (every command also takes --version)" ;;
	install-stages) echo "install-stages [options] - Install runit stages 1, 2, 3 and ctrlaltdel for a container (-h for options)" ;;
	uninstall-stages) echo "uninstall-stages [options] - Remove the runit stages install-stages put in place (-h for options)" ;;
	commands)
		echo "Valid Commands: ${commands} paths version make-links install-stages uninstall-stages"
		echo "use command -h for help"
		;;
	*) echo "Invalid command (${commands})" ;;
	esac
}

# Start main program

sv_ensure_runit_on_path

cmd=$(basename "$0")
# How this was called, for repeating it back in a message: `svls`, or
# `sv-helper ls` - never a bare `ls`.
invoked=$cmd
via_helper=0
if [ "$cmd" = "sv-helper" ] || [ "$cmd" = "sv-helper.sh" ]
then
	via_helper=1
	invoked="$cmd $1"
	cmd=$1
	if [ -z "$cmd" ]
	then
		cmd=commands
	else
		shift
	fi
fi

# The version, like help, has to work before any service directory exists,
# and from every alias: `svls --version` as much as `sv-helper version`.
if [ "$cmd" = version ] || [ "$cmd" = --version ] || [ "$1" = --version ]
then
	print_version "$(basename "$0")"
	exit 0
fi

# The stages commands take long options, which getopts below would
# complain about letter by letter, and they answer only to sv-helper
# itself: a link named install-stages is not a way to call them.
case "$cmd" in
install-stages | uninstall-stages)
	[ "$via_helper" -eq 1 ] || die 1 "$cmd is only run as: sv-helper $cmd"
	stages_command "$cmd" "$@"
	exit 0
	;;
esac

# Help must work before any service directory exists, so it is answered
# before anything resolves a path.
while getopts h options
do
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
