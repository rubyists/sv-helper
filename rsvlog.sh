#!/bin/sh
# Author: TJ Vanderpoel
# Licence: MIT
# This is a generic 'run' script meant to be linked in a log/ directory
# of a runit, daemontools, s6, or similar service.
# It requires svlogd available in the path.

# If the file './conf' exists, it can modify the behavior
# of the svlogd in these ways:

# SV_LOG_SYSLOG=<anything> (if set, uses syslog)
# SV_LOG_SYSLOG_PRIORITY=daemon.info (default daemon.info)

# If SV_LOG_SYSLOG is unset, these variables are used for the svlogd
# configuration
# USERGROUP=user:group (default rsvlog:adm when that account exists and
#                       we are root; the invoking user otherwise)
# SV_LOG_BASE=/path/to/logs (default depends on the platform and UID, below)
# SV_LOGDIR=subdir (relative to SV_LOG_BASE, or absolute; default the
#                   service's own name)
# CURRENT_LOG_FILE=filename.log (default 'current')

# The log base defaults to the only place the invoking user is certain to be
# able to write:
#
#   macOS (any UID)   $(brew --prefix)/var/log
#   Linux as root     /var/log
#   Linux as a user   ${XDG_STATE_HOME:-$HOME/.local/state}/sv-helper/log

set -e

# release-please rewrites this line on every release, through the marker.
sv_version=4.2.1 # x-release-please-version

# Answered before the checks below, which only make sense for the log
# service itself, so the installed command can say what it is.
if [ "$1" = --version ]
then
	echo "rsvlog (sv-helper) $sv_version"
	exit 0
fi

if [ "$(basename "$0")" != "run" ]
then
	echo "This script meant to be linked as ./run in a service/log directory only!" >&2
	exit 1
fi
curdir=$(basename "$(pwd)")
if [ "$curdir" != "log" ]
then
	echo "This script meant to be run from a service/log directory only!" >&2
	exit 1
fi

if [ -f ./conf ]
then
	# shellcheck disable=SC1091  # written by the service, not shipped here
	. ./conf
fi

if [ -n "$SV_LOG_SYSLOG" ]
then
	prio=${SV_LOG_SYSLOG_PRIORITY:-daemon.info}
	echo "Logging to Syslog with priority ${prio}"
	exec logger -p "$prio"
fi

is_root() {
	[ "$(id -u)" -eq 0 ]
}

# BSD and GNU stat disagree on everything except the word "stat".
owner_of() {
	stat -c '%U:%G' "$1" 2>/dev/null || stat -f '%Su:%Sg' "$1"
}

# macOS runs on Homebrew's runit, so its prefix holds the logs too. Probe
# the standard prefixes as well, because Homebrew's launch agent does not
# supply an interactive shell's PATH.
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
	command -v svlogd >/dev/null 2>&1 && return 0
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

default_log_base() {
	if [ "$(uname -s)" = Darwin ]
	then
		prefix=$(brew_prefix) || {
			echo "Homebrew not found; sv-helper needs Homebrew's runit on macOS" >&2
			return 1
		}
		printf '%s/var/log\n' "$prefix"
		return 0
	fi
	if is_root
	then
		printf '/var/log\n'
		return 0
	fi
	printf '%s/sv-helper/log\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# ./current is the name every other tool expects; svlogd itself writes it
# inside ./main.
link_current() {
	[ -L ./current ] || ln -s main/current current
}

# An optional second name for the live log, inside the log directory.
link_alias() {
	dir=$1
	[ -n "$CURRENT_LOG_FILE" ] || return 0
	[ -e "$dir/$CURRENT_LOG_FILE" ] || ln -s current "$dir/$CURRENT_LOG_FILE"
}

# Only root can hand the logs to another account; a regular user's services
# log as that user, with no escalation and no required logging account.
take_ownership() {
	dir=$1
	[ -n "$user_group" ] || return 0
	is_root || return 0
	[ "$(owner_of "$dir")" = "$user_group" ] || chown -R "$user_group" "$dir"
}

# Run svlogd under $user_group when there is one and we can; otherwise run
# it as ourselves. Everything that execs the logger goes through here.
exec_svlogd() {
	dir=$1
	if [ -n "$user_group" ] && is_root
	then
		exec chpst -u "$user_group" svlogd -t "$dir"
	fi
	exec svlogd -t "$dir"
}

# rsvlog:adm is a convention, not a requirement: plenty of hosts and almost
# every container have no such account. Dropping to it when it exists keeps
# the old behaviour; falling back to the current user when it does not
# keeps the log service from crash-looping on `chown: unknown user`. An
# account the operator named explicitly is a different matter - that one is
# a real configuration error, and silently logging as root instead would be
# a downgrade nobody asked for.
if [ -n "$USERGROUP" ]
then
	if ! id -u "${USERGROUP%%:*}" >/dev/null 2>&1
	then
		echo "USERGROUP is $USERGROUP but there is no such user" >&2
		exit 1
	fi
	user_group=$USERGROUP
elif is_root && id -u rsvlog >/dev/null 2>&1
then
	user_group=rsvlog:adm
else
	user_group=
fi

ensure_runit_on_path

# An existing ./main wins: it is this service's established log layout, and
# changing where it writes would strand the logs already there.
if [ -d ./main ]
then
	take_ownership ./main
	link_current
	link_alias ./main
	echo "Logging in existing $PWD/main directory"
	exec_svlogd ./main
fi

service_name=$(basename "$(dirname "$(pwd)")")
log_base=${SV_LOG_BASE:-$(default_log_base)}
logdir=${SV_LOGDIR:-${LOGDIR:-$service_name}}

case "$logdir" in
/*) target=$logdir ;;
*) target="$log_base/$logdir" ;;
esac

# mkdir -p is the test: a base that cannot be created or written is not a
# base, and the logs stay in the log directory itself rather than vanishing.
if mkdir -p "$target" 2>/dev/null && [ -w "$target" ]
then
	ln -sfn "$target" ./main
	link_current
	link_alias "$target"
	take_ownership "$target"
	echo "Logging to $target${user_group:+ as $user_group}"
	exec_svlogd ./main
fi

echo "Logging in $PWD"
link_alias .
exec_svlogd ./

# vim: set noet ts=8 sw=8 sts=8
