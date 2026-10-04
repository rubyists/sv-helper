#!/usr/bin/env bash
# Shared by the container suites. Loaded from setup_file, which runs before
# setup() and so before common_setup.

# podman first: rootless, and what the examples in container/ are written
# against. docker works the same way.
container_engine() {
	local candidate
	for candidate in podman docker
	do
		if command -v "$candidate" >/dev/null 2>&1
		then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

# Every distinct "real effective saved filesystem" UID set held by a
# process in the container, one per line. Read from /proc rather than ps,
# because busybox's ps has no numeric uid column.
container_uids() {
	# shellcheck disable=SC2016  # expanded by the container's shell, not ours
	"$ENGINE" exec "$1" sh -c \
		'cat /proc/[0-9]*/status 2>/dev/null | awk "/^Uid:/ { print \$2, \$3, \$4, \$5 }" | sort -u'
}
