#!/bin/sh
# Verifies the root-container runit lifecycle end to end against a real
# container: it boots with runit as PID 1, supervises a service, restarts
# one that crashes, writes logs through rsvlog, and - the part worth
# testing - shuts itself down through stage 3 and exits before the
# runtime's stop timeout, rather than being killed.
#
#   tests/container.sh [podman|docker]

set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
IMAGE=sv-helper-container-test
NAME=sv-helper-container-test
STOP_TIMEOUT=30

ENGINE=${1:-}
if [ -z "$ENGINE" ]; then
	for candidate in podman docker; do
		if command -v "$candidate" >/dev/null 2>&1; then
			ENGINE=$candidate
			break
		fi
	done
fi
[ -n "$ENGINE" ] || {
	echo "No container engine found (podman or docker)" >&2
	exit 2
}

FAIL=0

ok() { echo "  ok   $*"; }
no() {
	echo "  FAIL $*" >&2
	FAIL=1
}

cleanup() {
	"$ENGINE" rm -f "$NAME" >/dev/null 2>&1
	return 0
}
trap cleanup EXIT INT TERM

echo "Using $ENGINE"
cleanup

"$ENGINE" build -q -f "$ROOT/container/Containerfile" -t "$IMAGE" "$ROOT" >/dev/null

# SYS_BOOT is what lets runit's final reboot(2) end the PID namespace, so
# the container exits on its own. Without it everything up to and
# including stage 3 still works, but the runtime has to kill the container
# afterwards - see container/Readme.md.
"$ENGINE" run -d --cap-add SYS_BOOT --name "$NAME" "$IMAGE" >/dev/null
sleep 6

if "$ENGINE" exec "$NAME" svls 2>&1 | grep -q '^run: .*/hello:'; then
	ok "the hello service is supervised"
else
	no "the hello service is supervised"
	"$ENGINE" logs "$NAME" 2>&1 | sed 's/^/       /' >&2
fi

if "$ENGINE" exec "$NAME" sv-enable crasher >/dev/null 2>&1; then
	ok "sv-enable works inside the container"
else
	no "sv-enable works inside the container"
fi
sleep 3

# crasher exits every second or so, so a single sample can easily catch it
# while it is down and see no pid at all. Sample across several restarts
# and count how many distinct pids runsv handed out.
pids=""
i=0
while [ "$i" -lt 12 ]; do
	# Cut at the first semicolon: anything after it describes the log
	# service, whose pid does not change when the service restarts.
	pid=$("$ENGINE" exec "$NAME" svls crasher 2>/dev/null |
		cut -d';' -f1 |
		sed -n 's/.*(pid \([0-9]*\)).*/\1/p')
	case " $pids " in
	*" $pid "*) ;;
	*) [ -n "$pid" ] && pids="$pids $pid" ;;
	esac
	i=$((i + 1))
	sleep 1
done
count=$(echo "$pids" | wc -w | tr -d ' ')
if [ "$count" -ge 2 ]; then
	ok "a crashing service is restarted ($count distinct pids:$pids)"
else
	no "a crashing service is restarted ($count distinct pids:$pids)"
fi

# Nothing should be left behind by the crash loop: runit as PID 1 has to
# reap the children runsv hands it.
zombies=$("$ENGINE" exec "$NAME" sh -c "ps -o stat= -A | grep -c '^Z' || true")
if [ "${zombies:-0}" -eq 0 ]; then
	ok "no zombies: PID 1 reaps its children"
else
	no "no zombies: found $zombies"
fi

if "$ENGINE" exec "$NAME" sh -c 'test -s /var/log/hello/current'; then
	ok "rsvlog is writing to /var/log/hello/current"
else
	no "rsvlog is writing to /var/log/hello/current"
fi
before_lines=$("$ENGINE" exec "$NAME" sh -c 'wc -l < /var/log/hello/current' | tr -d ' ')

start=$(date +%s)
"$ENGINE" stop -t "$STOP_TIMEOUT" "$NAME" >/dev/null 2>&1 || true
elapsed=$(($(date +%s) - start))

logs=$("$ENGINE" logs "$NAME" 2>&1)
case "$logs" in
*"enter stage: /etc/runit/3"*) ok "stage 3 ran" ;;
*)
	no "stage 3 ran"
	echo "$logs" | tail -20 | sed 's/^/       /' >&2
	;;
esac
case "$logs" in
*"stage 3: done"*) ok "stage 3 finished" ;;
*) no "stage 3 finished" ;;
esac
case "$logs" in
*"letting log services finish"*) ok "log services were given a chance to drain" ;;
*) no "log services were given a chance to drain" ;;
esac

state=$("$ENGINE" inspect "$NAME" --format '{{.State.Status}}')
if [ "$state" = exited ]; then
	ok "the container exited"
else
	no "the container is $state, not exited"
fi

if [ "$elapsed" -lt "$STOP_TIMEOUT" ]; then
	ok "it exited in ${elapsed}s, inside the ${STOP_TIMEOUT}s stop timeout"
else
	no "it took ${elapsed}s, so the runtime killed it"
fi

# svlogd flushes on shutdown, so the file must have grown after stage 3
# closed its stdin - that is what "logs finish" means.
"$ENGINE" cp "$NAME:/var/log/hello/current" "$ROOT/.container-test-log" 2>/dev/null || true
if [ -f "$ROOT/.container-test-log" ]; then
	after_lines=$(wc -l <"$ROOT/.container-test-log" | tr -d ' ')
	rm -f "$ROOT/.container-test-log"
	if [ "$after_lines" -ge "$before_lines" ] && [ "$after_lines" -gt 0 ]; then
		ok "the log survived shutdown ($before_lines -> $after_lines lines)"
	else
		no "the log was truncated on shutdown ($before_lines -> $after_lines lines)"
	fi
else
	no "could not read the log out of the stopped container"
fi

exit "$FAIL"

# vim: set noet ts=8 sw=8 sts=8
