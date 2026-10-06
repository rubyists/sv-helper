#!/usr/bin/env bats
# install-stages and uninstall-stages over a runit package's own
# /etc/runit, in containers with the real packages installed:
#
#   Debian  its own stages, and stopit and reboot linked to
#           /run/runit.stopit and /run/runit.reboot - not where ours go
#   Void    its own stages, and stopit and reboot linked to exactly
#           where ours go, which still does not make them ours
#
# Nothing here boots runit. What is under test is that the package's
# files are refused, set aside only with --force, and put back byte for
# byte, and that nothing of the package's is ever removed.

DEBIAN_IMAGE=sv-helper-distro-test-debian
VOID_IMAGE=sv-helper-distro-test-void

setup_file() {
    load 'test_helper/container'
    REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd -P)
    export REPO_ROOT

    if ! ENGINE=$(container_engine)
    then
        export CONTAINER_SKIP="neither podman nor docker is installed"
        return 0
    fi
    export ENGINE

    # sv-helper installed the usual way, over each distribution's own
    # runit package.
    local install='COPY install.sh sv-helper.sh rsvlog.sh runsvdir.sh Readme.adoc COPYING /src/
COPY etc /src/etc
RUN cd /src && ./install.sh install --prefix /usr/local'

    "$ENGINE" build -q -t "$DEBIAN_IMAGE" -f - "$REPO_ROOT" >/dev/null <<EOF
FROM docker.io/library/debian:stable-slim
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y runit \
    && rm -rf /var/lib/apt/lists/*
$install
EOF
    "$ENGINE" build -q -t "$VOID_IMAGE" -f - "$REPO_ROOT" >/dev/null <<EOF
FROM ghcr.io/void-linux/void-musl:latest
RUN xbps-install -Syu xbps && xbps-install -y runit-void
$install
EOF
}

setup() {
    load 'test_helper/common'
    common_setup
    [ -z "${CONTAINER_SKIP:-}" ] || skip "$CONTAINER_SKIP"
}

# Every entry in /etc/runit with its contents or link target, dotfiles
# included, so a round trip is checked byte for byte and anything left
# behind shows up.
SNAPSHOT='for f in /etc/runit/* /etc/runit/.[!.]*
do
    [ -e "$f" ] || [ -L "$f" ] || continue
    if [ -L "$f" ]
    then
        echo "$f -> $(readlink "$f")"
    elif [ -d "$f" ]
    then
        echo "$f/"
    else
        echo "$f $(cksum < "$f")"
    fi
done'

# Compared in the container's own shell: Void has neither cmp nor diff.
in_image() {
    "$ENGINE" run --rm "$1" sh -c "$2"
}

refuses_and_changes_nothing() {
    run in_image "$1" "$SNAPSHOT > /tmp/before
sv-helper install-stages
echo \"exit=\$?\"
$SNAPSHOT > /tmp/after
[ \"\$(cat /tmp/before)\" = \"\$(cat /tmp/after)\" ] && echo UNCHANGED"
    assert_output --partial "sv-helper did not install it"
    assert_output --partial "exit=1"
    assert_output --partial "UNCHANGED"
}

force_round_trip_restores() {
    run in_image "$1" "$SNAPSHOT > /tmp/before
sv-helper install-stages --force || exit 1
grep -q 'runit stage 3 - shutdown' /etc/runit/3 && echo OURS-INSTALLED
sv-helper uninstall-stages || exit 1
$SNAPSHOT > /tmp/after
[ \"\$(cat /tmp/before)\" = \"\$(cat /tmp/after)\" ] && echo RESTORED"
    assert_success
    assert_output --partial "OURS-INSTALLED"
    assert_output --partial "RESTORED"
}

uninstall_without_install_touches_nothing() {
    run in_image "$1" "$SNAPSHOT > /tmp/before
sv-helper uninstall-stages --force || exit 1
$SNAPSHOT > /tmp/after
[ \"\$(cat /tmp/before)\" = \"\$(cat /tmp/after)\" ] && echo UNCHANGED"
    assert_success
    assert_output --partial "installed nothing"
    assert_output --partial "UNCHANGED"
}

@test "Debian: the runit package's stages are refused, and nothing changes" {
    refuses_and_changes_nothing "$DEBIAN_IMAGE"
}

@test "Debian: --force sets them aside, and uninstall-stages restores /etc/runit exactly" {
    force_round_trip_restores "$DEBIAN_IMAGE"
}

@test "Debian: uninstall-stages before any install touches nothing" {
    uninstall_without_install_touches_nothing "$DEBIAN_IMAGE"
}

@test "Void: the runit package's stages are refused, and nothing changes" {
    refuses_and_changes_nothing "$VOID_IMAGE"
}

@test "Void: --force sets them aside, and uninstall-stages restores /etc/runit exactly" {
    # Including stopit and reboot, which are left in place throughout:
    # they already point where ours would, and they are Void's.
    force_round_trip_restores "$VOID_IMAGE"
}

@test "Void: uninstall-stages before any install leaves its stopit and reboot alone" {
    uninstall_without_install_touches_nothing "$VOID_IMAGE"
}

@test "Void has no cmp, and neither installer needs one" {
    run in_image "$VOID_IMAGE" "command -v cmp || echo NO-CMP
cd /src && ./install.sh install --prefix /usr/local && echo REINSTALLED"
    assert_output --partial "NO-CMP"
    assert_output --partial "REINSTALLED"
}
