NAME = sv-helper
SHELL = /bin/bash
INSTALL = /usr/bin/install
MSGFMT = /usr/bin/msgfmt
SED = /bin/sed
DESTDIR = /usr/local
BINDIR = /bin
DOCDIR = /share/doc/$(NAME)

BATS = test/bats/bin/bats

all:

# The suite lives in test/ and runs under the vendored bats submodules;
# see test/README.md. A clone without them fetched gets a pointer to the
# one command that fixes it rather than "no such file or directory".
test:
	@test -x $(BATS) || { \
		echo "bats is missing. Run: git submodule update --init --recursive" >&2; \
		exit 1; \
	}
	$(BATS) test/

install: all
	$(INSTALL) -d -m 0755 $(DESTDIR)$(BINDIR)
	$(INSTALL) -d -m 0755 $(DESTDIR)$(DOCDIR)
	$(INSTALL) -m 0755 rsvlog.sh $(DESTDIR)$(BINDIR)/rsvlog
	$(INSTALL) -m 0755 runsvdir.sh $(DESTDIR)$(BINDIR)/runsvdir.sh
	$(INSTALL) -m 0755 sv-helper.sh $(DESTDIR)$(BINDIR)/sv-helper
	$(INSTALL) -m 0644 README.md $(DESTDIR)$(DOCDIR)/README.md
	$(INSTALL) -m 0644 COPYING $(DESTDIR)$(DOCDIR)/COPYING
	cd $(DESTDIR)$(BINDIR); \
	for sv in sv-start sv-stop sv-restart sv-list svls sv-enable sv-disable sv-find; do \
		ln -s sv-helper "$$sv"; \
	done

uninstall:
	rm -vf $(DESTDIR)$(BINDIR)/sv-helper
	rm -vf $(DESTDIR)$(BINDIR)/rsvlog
	rm -vf $(DESTDIR)$(BINDIR)/runsvdir.sh
	for sv in sv-start sv-stop sv-restart sv-list svls sv-enable sv-disable sv-find; do \
		rm -vf $(DESTDIR)$(BINDIR)/"$$sv"; \
	done
	rm -vr $(DESTDIR)$(DOCDIR)

.PHONY: all test install uninstall
