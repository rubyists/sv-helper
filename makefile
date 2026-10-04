NAME = sv-helper
SHELL = /bin/sh

# PREFIX is where the files live when they run; DESTDIR is a staging root
# used only while installing. Earlier versions of this makefile used
# DESTDIR for both, so a package build and a real install could not be
# told apart - pass PREFIX for what used to be DESTDIR.
PREFIX = /usr/local
DESTDIR =
BINDIR = $(PREFIX)/bin
DOCDIR = $(PREFIX)/share/doc/$(NAME)
RUNIT_DIR = /etc/runit

BATS = test/bats/bin/bats

INSTALL_FLAGS = --prefix '$(PREFIX)' --bindir '$(BINDIR)' --docdir '$(DOCDIR)' --destdir '$(DESTDIR)'

all:

# One installation path, shared with release archives and package builds,
# so there is only ever one definition of what "installed" means.
install: all
	./install.sh install $(INSTALL_FLAGS)

uninstall:
	./install.sh uninstall $(INSTALL_FLAGS)

# Container stages are deliberately not part of `make install`: dropping
# files in /etc/runit changes how the host boots.
install-stages:
	./install.sh install-stages --destdir '$(DESTDIR)' --runit-dir '$(RUNIT_DIR)'

uninstall-stages:
	./install.sh uninstall-stages --destdir '$(DESTDIR)' --runit-dir '$(RUNIT_DIR)'

# The command links `sv-helper make-links` used to create. Here for the
# muscle memory; `install` creates them too.
make-links: install

# The suite lives in test/ and runs under the vendored bats submodules;
# see test/README.md. A clone without them fetched gets a pointer to the
# one command that fixes it rather than "no such file or directory".
test:
	@test -x $(BATS) || { \
		echo "bats is missing. Run: git submodule update --init --recursive" >&2; \
		exit 1; \
	}
	$(BATS) test/

.PHONY: all test install uninstall install-stages uninstall-stages make-links
