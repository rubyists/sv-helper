#!/bin/sh
# sv-helper's test suite. POSIX sh, no dependencies beyond the tools the
# project itself needs. Tests that need runit or a container runtime skip
# themselves when it is absent, and say so.
#
#   ./tests/run.sh            run everything available
#   ./tests/run.sh installer  run one group: paths, installer, archive,
#                             lifecycle, container, or lint

set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sv-helper-tests.XXXXXX")
PASS=0
FAIL=0
SKIP=0

cleanup() {
	# Any runsv a lifecycle test started lives under $WORK; stopping
	# runsvdir first lets runsv exit on its own.
	if [ -n "$RUNSVDIR_PID" ]; then
		kill "$RUNSVDIR_PID" 2>/dev/null || true
		sleep 1
		pkill -P "$RUNSVDIR_PID" 2>/dev/null || true
	fi
	rm -rf "$WORK"
	return 0
}
trap cleanup EXIT INT TERM

ok() {
	PASS=$((PASS + 1))
	echo "  ok   $*"
}

no() {
	FAIL=$((FAIL + 1))
	echo "  FAIL $*" >&2
}

skip() {
	SKIP=$((SKIP + 1))
	echo "  skip $*"
}

group() {
	echo
	echo "== $* =="
}

# assert_eq EXPECTED ACTUAL DESCRIPTION
assert_eq() {
	if [ "$1" = "$2" ]; then
		ok "$3"
	else
		no "$3"
		echo "       expected: $1" >&2
		echo "       actual:   $2" >&2
	fi
}

# assert_ok DESCRIPTION -- COMMAND...
assert_ok() {
	desc=$1
	shift
	[ "$1" = "--" ] && shift
	if output=$("$@" 2>&1); then
		ok "$desc"
	else
		no "$desc"
		echo "$output" | sed 's/^/       /' >&2
	fi
}

# assert_fails DESCRIPTION -- COMMAND...
assert_fails() {
	desc=$1
	shift
	[ "$1" = "--" ] && shift
	if output=$("$@" 2>&1); then
		no "$desc (command unexpectedly succeeded)"
		echo "$output" | sed 's/^/       /' >&2
	else
		ok "$desc"
	fi
}

assert_file() {
	if [ -f "$1" ] && [ ! -L "$1" ]; then
		ok "$2"
	else
		no "$2 ($1 is not a regular file)"
	fi
}

assert_link_to() {
	if [ -L "$1" ] && [ "$(readlink "$1")" = "$2" ]; then
		ok "$3"
	else
		no "$3 ($1 -> $(readlink "$1" 2>/dev/null || echo 'missing'))"
	fi
}

assert_executable() {
	if [ -x "$1" ]; then
		ok "$2"
	else
		no "$2 ($1 is not executable)"
	fi
}

assert_absent() {
	if [ -e "$1" ] || [ -L "$1" ]; then
		no "$2 ($1 still exists)"
	else
		ok "$2"
	fi
}

ALIASES="sv-start sv-stop sv-restart sv-list svls sv-enable sv-disable sv-find"
UNAME=$(uname -s)

# macOS runs on Homebrew's runit, so the user's tree, definitions and logs
# all live under Homebrew's prefix rather than in XDG directories. The
# tests assert the real defaults for the platform they run on rather than
# assuming Linux.
brew_prefix() {
	if [ -n "$HOMEBREW_PREFIX" ]; then
		printf '%s\n' "$HOMEBREW_PREFIX"
		return 0
	fi
	brew --prefix
}

expected_svdir() {
	if [ "$UNAME" = Darwin ]; then
		printf '%s/var/service\n' "$(brew_prefix)"
	else
		printf '%s/.local/state/sv-helper/service\n' "$1"
	fi
}

expected_defs_dir() {
	if [ "$UNAME" = Darwin ]; then
		printf '%s/etc/sv\n' "$(brew_prefix)"
	else
		printf '%s/.config/sv-helper/sv\n' "$1"
	fi
}

expected_log_dir() {
	if [ "$UNAME" = Darwin ]; then
		printf '%s/var/log\n' "$(brew_prefix)"
	else
		printf '%s/.local/state/sv-helper/log\n' "$1"
	fi
}

# Run a command as this user would, with a HOME of our choosing and every
# override this project reads cleared, so a test never inherits one.
as_user() {
	home=$1
	shift
	env -u SVDIR -u SV_ROOT -u SV_SOURCE_DIR -u SV_LOG_BASE -u XDG_CONFIG_HOME \
		-u XDG_STATE_HOME -u HOMEBREW_PREFIX "HOME=$home" "$@"
}

test_lint() {
	group "lint"
	if ! command -v shellcheck >/dev/null 2>&1; then
		skip "shellcheck is not installed"
		return 0
	fi
	for script in \
		"$ROOT/sv-helper.sh" "$ROOT/rsvlog.sh" "$ROOT/runsvdir.sh" \
		"$ROOT/install.sh" "$ROOT/tests/run.sh" "$ROOT/tests/container.sh" \
		"$ROOT/etc/runit/1" "$ROOT/etc/runit/2" "$ROOT/etc/runit/3" \
		"$ROOT/etc/runit/ctrlaltdel" \
		"$ROOT/ci/build_release_payload.sh" "$ROOT/ci/publish_release_assets.sh" \
		"$ROOT/ci/verify_release.sh" \
		"$ROOT/container/sv/hello/run" "$ROOT/container/sv/crasher/run"; do
		[ -f "$script" ] || continue
		assert_ok "shellcheck $(basename "$(dirname "$script")")/$(basename "$script")" \
			-- shellcheck -s sh "$script"
	done
}

test_paths() {
	group "path resolution"
	home="$WORK/paths home"
	mkdir -p "$home"

	# Before anything exists at all.
	assert_ok "help works with no service directory" \
		-- as_user "$home" "$ROOT/sv-helper.sh" -h
	assert_eq "" "$(as_user "$home" "$ROOT/sv-helper.sh" sv-list | tr -d ' ')" \
		"sv-list is empty, not an error, before any service exists"

	svdir=$(as_user "$home" "$ROOT/sv-helper.sh" paths | sed -n 's/^svdir: *//p')
	assert_eq "$(expected_svdir "$home")" "$svdir" \
		"a regular user gets their own tree, not a system one"

	# /var/service, /service and /etc/service are consulted only for UID
	# 0; a non-root invocation must not land in one however writable it is.
	case "$svdir" in
	/var/service | /service | /etc/service)
		no "a non-root invocation selected the system tree $svdir"
		;;
	*) ok "a non-root invocation never selects a system tree" ;;
	esac

	# Explicit overrides win. Kept in its own variable so the checks
	# below still test the default tree, not the override.
	mkdir -p "$WORK/explicit tree"
	override=$(as_user "$home" env "SVDIR=$WORK/explicit tree" "$ROOT/sv-helper.sh" paths |
		sed -n 's/^svdir: *//p')
	assert_eq "$WORK/explicit tree" "$override" "an explicit SVDIR wins, spaces and all"

	assert_fails "a nonexistent SVDIR is an error, not a silent fallback" \
		-- as_user "$home" env "SVDIR=$WORK/nope" "$ROOT/sv-helper.sh" paths

	mkdir -p "$WORK/defs/thing"
	found=$(as_user "$home" env "SV_SOURCE_DIR=$WORK/defs" "$ROOT/sv-helper.sh" sv-find thing)
	assert_eq "$WORK/defs/thing" "$found" "SV_SOURCE_DIR is searched for definitions"

	# A service name that is only a directory in the enabled tree, with no
	# definition anywhere, still resolves - that is how an enabled tree
	# that holds real directories rather than links behaves.
	mkdir -p "$svdir/inline"
	found=$(as_user "$home" "$ROOT/sv-helper.sh" sv-find inline)
	assert_eq "$svdir/inline" "$found" "a service directory inside the tree is found"
	rmdir "$svdir/inline"

	assert_fails "sv-find reports an unknown service" \
		-- as_user "$home" "$ROOT/sv-helper.sh" sv-find nothing-here
}

test_installer() {
	group "installer"
	prefix="$WORK/user prefix"
	bin="$prefix/bin"

	assert_ok "install into a prefix containing a space" \
		-- "$ROOT/install.sh" install --prefix "$prefix"
	assert_file "$bin/sv-helper" "sv-helper is a real file"
	assert_file "$bin/rsvlog" "rsvlog is a real file"
	assert_file "$bin/runsvdir.sh" "runsvdir.sh is a real file"
	assert_executable "$bin/sv-helper" "sv-helper is executable"
	for name in $ALIASES; do
		assert_link_to "$bin/$name" sv-helper "$name links to sv-helper"
	done
	assert_file "$prefix/share/doc/sv-helper/README.md" "README.md is installed"

	assert_ok "installing again over an identical tree succeeds" \
		-- "$ROOT/install.sh" install --prefix "$prefix"

	# Unrelated content must survive both install and uninstall.
	echo "someone else's" >"$bin/unrelated"
	ln -s /bin/sh "$bin/unrelated-link"

	echo "not ours" >"$bin/sv-start.tmp"
	mv "$bin/sv-start" "$bin/sv-start.ours"
	echo "conflicting" >"$bin/sv-start"
	assert_fails "a conflicting file at a link's path is reported, not replaced" \
		-- "$ROOT/install.sh" install --prefix "$prefix"
	assert_eq "conflicting" "$(cat "$bin/sv-start")" "the conflicting file is left untouched"
	assert_ok "--force replaces a conflicting file" \
		-- "$ROOT/install.sh" install --prefix "$prefix" --force
	assert_link_to "$bin/sv-start" sv-helper "the link is restored by --force"
	rm -f "$bin/sv-start.ours" "$bin/sv-start.tmp"

	ln -sf /bin/sh "$bin/svls"
	assert_fails "a foreign symlink is reported, not replaced" \
		-- "$ROOT/install.sh" install --prefix "$prefix"
	assert_eq "/bin/sh" "$(readlink "$bin/svls")" "the foreign symlink is left untouched"
	rm -f "$bin/svls"

	printf 'modified by hand\n' >>"$bin/rsvlog"
	assert_fails "a modified installed file is reported on reinstall" \
		-- "$ROOT/install.sh" install --prefix "$prefix"
	assert_ok "uninstall leaves a modified file alone" \
		-- "$ROOT/install.sh" uninstall --prefix "$prefix"
	assert_file "$bin/rsvlog" "the hand-modified rsvlog survives uninstall"
	rm -f "$bin/rsvlog"

	assert_absent "$bin/sv-helper" "uninstall removed sv-helper"
	for name in $ALIASES; do
		assert_absent "$bin/$name" "uninstall removed the $name link"
	done
	assert_file "$bin/unrelated" "an unrelated file survives uninstall"
	assert_link_to "$bin/unrelated-link" /bin/sh "an unrelated symlink survives uninstall"

	# DESTDIR stages into a build root without touching PREFIX.
	stage="$WORK/stage"
	assert_ok "staged install with DESTDIR" \
		-- "$ROOT/install.sh" install --destdir "$stage" --prefix /usr/local
	assert_file "$stage/usr/local/bin/sv-helper" "DESTDIR+PREFIX stages under the build root"
	assert_link_to "$stage/usr/local/bin/svls" sv-helper "staged links are relative, so they work once unpacked"
	assert_absent /usr/local/bin/sv-helper "a staged install writes nothing outside DESTDIR"

	# Container stages are a separate, explicit operation.
	assert_absent "$stage/etc/runit/2" "install does not install runit stages"
	assert_ok "install-stages into a staged /etc/runit" \
		-- "$ROOT/install.sh" install-stages --destdir "$stage"
	for stage_file in 1 2 3 ctrlaltdel; do
		assert_file "$stage/etc/runit/$stage_file" "stage $stage_file is installed"
	done
	assert_ok "uninstall-stages" -- "$ROOT/install.sh" uninstall-stages --destdir "$stage"
	assert_absent "$stage/etc/runit/2" "uninstall-stages removed stage 2"

	assert_ok "the makefile drives the same installer" \
		-- make -C "$ROOT" install DESTDIR="$WORK/mk" PREFIX=/usr
	assert_file "$WORK/mk/usr/bin/sv-helper" "make install stages through DESTDIR"
	assert_ok "make uninstall" -- make -C "$ROOT" uninstall DESTDIR="$WORK/mk" PREFIX=/usr
	assert_absent "$WORK/mk/usr/bin/sv-helper" "make uninstall removed it"
}

test_archive_install() {
	group "release archive"
	if [ ! -x "$ROOT/ci/build_release_payload.sh" ]; then
		skip "ci/build_release_payload.sh is not present"
		return 0
	fi
	out="$WORK/payload"
	assert_ok "build the release payload" \
		-- "$ROOT/ci/build_release_payload.sh" 0.0.0-test "$out"

	archive="$out/sv-helper-0.0.0-test-linux.tar.gz"
	assert_file "$archive" "the linux archive was built"
	assert_file "$out/sv-helper-0.0.0-test-darwin.tar.gz" "the darwin archive was built"
	assert_file "$out/SHA256SUMS" "checksums were written"

	assert_ok "the checksums match the files" \
		-- sh -c "cd '$out' && sha256sum -c SHA256SUMS >/dev/null"

	unpack="$WORK/unpack"
	mkdir -p "$unpack"
	tar -xzf "$archive" -C "$unpack"
	tree="$unpack/sv-helper-0.0.0-test"
	assert_file "$tree/bin/sv-helper" "the archive ships bin/sv-helper"
	assert_executable "$tree/bin/sv-helper" "archived scripts keep their executable bit"
	assert_link_to "$tree/bin/svls" sv-helper "the archive ships the command links"
	assert_file "$tree/install.sh" "the archive bundles the installer"
	assert_file "$tree/etc/runit/3" "the archive bundles the container stages"
	assert_absent "$tree/packslip" "the archive excludes any local packslip checkout"

	prefix="$WORK/from-archive"
	assert_ok "install from the unpacked archive" \
		-- "$tree/install.sh" install --prefix "$prefix"
	assert_file "$prefix/bin/sv-helper" "the archive's installer installs sv-helper"
	assert_eq "sv-helper" "$("$prefix/bin/svls" -h | cut -d' ' -f1 | tr -d '\n' | sed 's/svls.*/sv-helper/')" \
		"an installed alias dispatches through sv-helper"
}

# `svls NAME` reports the service and its log service on one line:
#   run: /path/ticker: (pid 123) 4s; run: log: (pid 122) 9s
# Everything after the first semicolon belongs to the log service, so it is
# cut off before reading a pid - a greedy match would return the logger's,
# which does not change across a restart.
service_pid() {
	as_user "$1" "$2/bin/svls" "$3" 2>/dev/null |
		cut -d';' -f1 |
		sed -n 's/.*(pid \([0-9]*\)).*/\1/p'
}

test_lifecycle() {
	group "user service lifecycle"
	for tool in runsvdir runsv sv svlogd; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			skip "runit is not installed ($tool missing)"
			return 0
		fi
	done

	home="$WORK/life home"
	mkdir -p "$home"
	prefix="$home/.local"
	"$ROOT/install.sh" install --prefix "$prefix" >/dev/null

	svdir=$(expected_svdir "$home")
	defs="$(expected_defs_dir "$home")/ticker"
	logdir="$(expected_log_dir "$home")/ticker"
	mkdir -p "$defs/log"
	cat >"$defs/run" <<'RUN'
#!/bin/sh
exec 2>&1
while true; do echo "tick"; sleep 1; done
RUN
	chmod +x "$defs/run"
	ln -s "$prefix/bin/rsvlog" "$defs/log/run"

	assert_eq "ticker" "$(as_user "$home" "$prefix/bin/sv-list" | tr -d ' ')" \
		"sv-list finds the user's own definition"
	assert_ok "sv-enable" -- as_user "$home" "$prefix/bin/sv-enable" ticker
	assert_link_to "$svdir/ticker" "$defs" \
		"enable links the definition into the user's tree"

	as_user "$home" "$prefix/bin/runsvdir.sh" >"$WORK/runsvdir.log" 2>&1 &
	RUNSVDIR_PID=$!
	sleep 3

	if ! grep -q "Starting runsvdir in $svdir" "$WORK/runsvdir.log"; then
		no "runsvdir.sh supervises the user's own tree"
		sed 's/^/       /' "$WORK/runsvdir.log" >&2
	else
		ok "runsvdir.sh supervises the user's own tree"
	fi

	status=$(as_user "$home" "$prefix/bin/svls" ticker 2>&1)
	case "$status" in
	run:*) ok "svls reports the service running" ;;
	*)
		no "svls reports the service running"
		echo "       $status" >&2
		;;
	esac

	as_user "$home" "$prefix/bin/sv-stop" ticker >/dev/null 2>&1
	sleep 1
	case "$(as_user "$home" "$prefix/bin/svls" ticker 2>&1)" in
	down:*) ok "sv-stop stops it" ;;
	*) no "sv-stop stops it" ;;
	esac

	as_user "$home" "$prefix/bin/sv-start" ticker >/dev/null 2>&1
	sleep 1
	case "$(as_user "$home" "$prefix/bin/svls" ticker 2>&1)" in
	run:*) ok "sv-start starts it again" ;;
	*) no "sv-start starts it again" ;;
	esac

	before=$(service_pid "$home" "$prefix" ticker)
	as_user "$home" "$prefix/bin/sv-restart" ticker >/dev/null 2>&1
	sleep 2
	after=$(service_pid "$home" "$prefix" ticker)
	if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
		ok "sv-restart replaces the process"
	else
		no "sv-restart replaces the process (before=$before after=$after)"
	fi

	log="$logdir/current"
	if [ -s "$log" ]; then
		ok "logs land in the user's own log directory ($logdir)"
	else
		no "logs land in the user's own log directory ($log)"
	fi
	owner=$(stat -c '%U' "$log" 2>/dev/null || stat -f '%Su' "$log")
	assert_eq "$(id -un)" "$owner" "the log is owned by the invoking user"

	assert_ok "sv-disable" -- as_user "$home" "$prefix/bin/sv-disable" ticker
	assert_absent "$svdir/ticker" "disable removes the link"

	# `|| true` throughout: with set -e, a kill or pkill that matches
	# nothing (because the process already exited) would end the run
	# right here, after every assertion passed but before the summary.
	kill "$RUNSVDIR_PID" 2>/dev/null || true
	sleep 1
	pkill -f "runsv $defs" 2>/dev/null || true
	RUNSVDIR_PID=
	# On macOS these live in the shared Homebrew prefix rather than under
	# $WORK, so they do not disappear with the temporary directory.
	rm -rf "$defs" "$logdir"
	return 0
}

test_container() {
	group "container"
	if [ ! -x "$ROOT/tests/container.sh" ]; then
		skip "tests/container.sh is not present"
		return 0
	fi
	if ! command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
		skip "neither podman nor docker is installed"
		return 0
	fi
	if "$ROOT/tests/container.sh"; then
		ok "the root container starts, supervises, logs and stops cleanly"
	else
		no "the root container starts, supervises, logs and stops cleanly"
	fi
}

case "${1:-all}" in
all)
	test_lint
	test_paths
	test_installer
	test_archive_install
	test_lifecycle
	test_container
	;;
lint) test_lint ;;
paths) test_paths ;;
installer) test_installer ;;
archive) test_archive_install ;;
lifecycle) test_lifecycle ;;
container) test_container ;;
*)
	echo "Unknown group '$1'" >&2
	exit 2
	;;
esac

echo
echo "$PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]

# vim: set noet ts=8 sw=8 sts=8
