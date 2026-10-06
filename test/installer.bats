#!/usr/bin/env bats
# The standalone installer: what it puts where, that running it twice is
# fine, that it refuses to walk over files it did not write, and that
# uninstalling takes back exactly its own and nothing else.
#
# Every test installs into its own prefix under $TEST_TMP, so none of them
# can see each other's work and none of them touch the real system.

setup() {
    load 'test_helper/common'
    load 'test_helper/sv'
    common_setup

    INSTALL="$REPO_ROOT/install.sh"
    PREFIX="$TEST_TMP/a prefix"   # a space, because prefixes have them
    BIN="$PREFIX/bin"
    DOC="$PREFIX/share/doc/sv-helper"
    ALIASES="sv-start sv-stop sv-restart sv-list svls sv-enable sv-disable sv-find"
}

install_here() {
    "$INSTALL" install --prefix "$PREFIX" "$@"
}

@test "installs the three scripts under their public names" {
    run install_here
    assert_success

    for name in sv-helper rsvlog runsvdir.sh
    do
        assert [ -f "$BIN/$name" ]
        assert [ ! -L "$BIN/$name" ]
        assert [ -x "$BIN/$name" ]
    done
}

@test "installs every command alias as a relative link to sv-helper" {
    install_here

    for name in $ALIASES
    do
        assert [ -L "$BIN/$name" ]
        # Relative, so the links still resolve after the tree is moved,
        # staged into a package, or unpacked somewhere else entirely.
        assert_equal "$(readlink "$BIN/$name")" "sv-helper"
    done
}

@test "an installed alias dispatches through sv-helper" {
    install_here

    run "$BIN/svls" -h
    assert_success
    assert_output --partial "svls"
}

@test "installs the documentation" {
    install_here
    assert [ -f "$DOC/Readme.adoc" ]
    assert [ -f "$DOC/COPYING" ]
}

@test "installing twice over an identical tree succeeds" {
    install_here
    run install_here
    assert_success
}

@test "a conflicting file where a link belongs is reported, not replaced" {
    install_here
    rm "$BIN/sv-start"
    echo "someone else's sv-start" > "$BIN/sv-start"

    run install_here
    assert_failure
    assert_output --partial "sv-start"
    assert_equal "$(cat "$BIN/sv-start")" "someone else's sv-start"
}

@test "a foreign symlink is reported, not replaced" {
    install_here
    ln -sf /bin/sh "$BIN/svls"

    run install_here
    assert_failure
    assert_equal "$(readlink "$BIN/svls")" "/bin/sh"
}

@test "a modified installed file is reported on reinstall" {
    install_here
    echo "edited by hand" >> "$BIN/rsvlog"

    run install_here
    assert_failure
    assert_output --partial "different contents"
}

@test "--force replaces what a plain install refused to" {
    install_here
    rm "$BIN/sv-start"
    echo "in the way" > "$BIN/sv-start"

    run install_here --force
    assert_success
    assert_equal "$(readlink "$BIN/sv-start")" "sv-helper"
}

@test "uninstall removes its own files and links" {
    install_here
    run "$INSTALL" uninstall --prefix "$PREFIX"
    assert_success

    for name in sv-helper rsvlog runsvdir.sh $ALIASES
    do
        refute [ -e "$BIN/$name" ]
        refute [ -L "$BIN/$name" ]
    done
}

@test "uninstall leaves unrelated content alone" {
    install_here
    echo "not ours" > "$BIN/unrelated"
    ln -s /bin/sh "$BIN/unrelated-link"

    "$INSTALL" uninstall --prefix "$PREFIX"

    assert [ -f "$BIN/unrelated" ]
    assert_equal "$(cat "$BIN/unrelated")" "not ours"
    assert_equal "$(readlink "$BIN/unrelated-link")" "/bin/sh"
}

@test "uninstall leaves a hand-modified file alone rather than deleting it" {
    install_here
    echo "edited by hand" >> "$BIN/rsvlog"

    run "$INSTALL" uninstall --prefix "$PREFIX"
    assert_success
    # It is no longer the file we installed, so it is no longer ours to
    # remove. Saying so beats deleting someone's edit.
    assert [ -f "$BIN/rsvlog" ]
    assert_output --partial "contents differ"
}

@test "DESTDIR stages under a build root and writes nothing outside it" {
    local stage="$TEST_TMP/stage"

    run "$INSTALL" install --destdir "$stage" --prefix /usr/local
    assert_success

    assert [ -f "$stage/usr/local/bin/sv-helper" ]
    assert_equal "$(readlink "$stage/usr/local/bin/svls")" "sv-helper"
    # PREFIX says where it will live; DESTDIR says where to put it now.
    # Confusing the two is how a package build installs onto the builder.
    refute [ -e /usr/local/bin/sv-helper ]
}

@test "install does not install the container stages" {
    local stage="$TEST_TMP/stage"
    "$INSTALL" install --destdir "$stage" --prefix /usr/local
    refute [ -e "$stage/etc/runit/2" ]
    refute [ -L "$stage/etc/runit/stopit" ]
}

@test "install-stages puts the runit stages in place as a separate step" {
    local stage="$TEST_TMP/stage"

    run "$INSTALL" install-stages --destdir "$stage"
    assert_success

    for name in 1 2 3 ctrlaltdel
    do
        assert [ -f "$stage/etc/runit/$name" ]
        assert [ -x "$stage/etc/runit/$name" ]
    done
}

@test "install-stages links runit's control files into /run/runit" {
    # So a container running as a regular user can arm stopit without
    # /etc/runit being writable. See container/Readme.md.
    local stage="$TEST_TMP/stage" name

    run "$INSTALL" install-stages --destdir "$stage"
    assert_success

    for name in stopit reboot
    do
        assert_equal "$(readlink "$stage/etc/runit/$name")" "/run/runit/$name"
    done
}

@test "uninstall-stages takes them back" {
    local stage="$TEST_TMP/stage"
    "$INSTALL" install-stages --destdir "$stage"

    run "$INSTALL" uninstall-stages --destdir "$stage"
    assert_success
    refute [ -e "$stage/etc/runit/2" ]
    refute [ -L "$stage/etc/runit/stopit" ]
}

@test "the makefile drives the same installer" {
    local stage="$TEST_TMP/mk"

    run make -C "$REPO_ROOT" install DESTDIR="$stage" PREFIX=/usr
    assert_success
    assert [ -f "$stage/usr/bin/sv-helper" ]

    run make -C "$REPO_ROOT" uninstall DESTDIR="$stage" PREFIX=/usr
    assert_success
    refute [ -e "$stage/usr/bin/sv-helper" ]
}

@test "help works and names both prefix semantics" {
    run "$INSTALL" help
    assert_success
    assert_output --partial "--prefix"
    assert_output --partial "--destdir"
}

@test "an unknown command is refused rather than guessed at" {
    run "$INSTALL" instal
    assert_failure
    assert_output --partial "Unknown command"
}
