#!/usr/bin/env bash
# Helpers shared by sv-helper's suites: a clean invoking environment, and
# the paths each platform is expected to resolve to.

# Run a command as this user would, with a HOME of our choosing and every
# variable sv-helper reads cleared, so a test never inherits one from the
# shell that started it.
as_user() {
	local home="$1"
	shift
	env -u SVDIR -u SV_ROOT -u SV_SOURCE_DIR -u SV_LOG_BASE -u SV_PREFIX \
		-u XDG_CONFIG_HOME -u XDG_STATE_HOME -u HOMEBREW_PREFIX \
		"HOME=$home" "$@"
}

brew_prefix() {
	if [ -n "${HOMEBREW_PREFIX:-}" ]
	then
		printf '%s\n' "$HOMEBREW_PREFIX"
		return 0
	fi
	brew --prefix
}

# macOS runs on Homebrew's runit, so a user's tree, definitions and logs
# all sit under Homebrew's prefix instead of in XDG directories. Tests
# assert the real defaults for the platform they run on.
expected_svdir() {
	if [ "$(uname -s)" = Darwin ]
	then
		printf '%s/var/service\n' "$(brew_prefix)"
	else
		printf '%s/.local/state/sv-helper/service\n' "$1"
	fi
}

expected_defs_dir() {
	if [ "$(uname -s)" = Darwin ]
	then
		printf '%s/etc/sv\n' "$(brew_prefix)"
	else
		printf '%s/.config/sv-helper/sv\n' "$1"
	fi
}

expected_log_dir() {
	if [ "$(uname -s)" = Darwin ]
	then
		printf '%s/var/log\n' "$(brew_prefix)"
	else
		printf '%s/.local/state/sv-helper/log\n' "$1"
	fi
}

# `svls NAME` reports the service and its log service on one line:
#   run: /path/ticker: (pid 123) 4s; run: log: (pid 122) 9s
# Everything after the first semicolon is the log service, so it is cut
# off before reading a pid - a greedy match would return the logger's,
# which does not change across a restart.
service_pid() {
	cut -d';' -f1 | sed -n 's/.*(pid \([0-9]*\)).*/\1/p'
}

# Skip the calling test unless every named command exists.
require_commands() {
	local tool
	for tool in "$@"
	do
		if ! command -v "$tool" >/dev/null 2>&1
		then
			skip "$tool is not installed"
		fi
	done
}

# Shut a supervision tree down the way stage 3 does, then stop runsvdir.
#
# Order matters. runsvdir exits immediately on TERM and leaves its runsv
# children running, orphaned but still holding every file descriptor they
# inherited - including the pipe bats reads its own output from, which
# makes the whole run hang after the last test has already passed. Asking
# each runsv to exit first avoids that.
#
# The supervisor is found by the tree it was given rather than by a
# remembered $!, because the $! of a backgrounded shell function is the
# wrapper subshell, which is not necessarily the process that goes on to
# become runsvdir. `runsvdir -P <tree>` names the tree in its own argv, so
# it can always be identified from the tree alone - unlike its runsv
# children, which it starts as plain `runsv NAME` with the tree as their
# working directory, and which no path-based search can find.
stop_supervision_tree() {
	local svdir="$1" pid waited

	sv_shutdown_each "$svdir"

	for pid in $(supervisor_pids "$svdir")
	do
		# HUP, not TERM: it passes TERM on to any runsv still standing
		# before exiting, rather than abandoning it.
		kill -HUP "$pid" 2>/dev/null || true
		waited=0
		while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 10 ]
		do
			sleep 1
			waited=$((waited + 1))
		done
		kill -KILL "$pid" 2>/dev/null || true
	done

	# Once more, for anything runsvdir started between the first sweep
	# and the HUP: it rescans the tree on its own schedule, so a service
	# enabled moments earlier can appear after the sweep has passed.
	sv_shutdown_each "$svdir"
}

# Every runsvdir supervising exactly this tree. -ww stops ps truncating
# the argument list to the terminal width, which a temporary directory
# easily exceeds.
supervisor_pids() {
	local svdir="$1" pid args
	ps -ww -eo pid=,args= | while read -r pid args
	do
		case "$args" in
		"runsvdir -P $svdir"*) printf '%s\n' "$pid" ;;
		esac
	done
}

sv_shutdown_each() {
	local service
	for service in "$1"/*
	do
		[ -e "$service" ] || continue
		sv -w 5 force-stop "$service" >/dev/null 2>&1 || true
		sv -w 5 shutdown "$service" >/dev/null 2>&1 || true
	done
}
