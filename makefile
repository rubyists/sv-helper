NAME = sv-helper
SHELL = /bin/bash
INSTALL = /usr/bin/install
MSGFMT = /usr/bin/msgfmt
SED = /bin/sed
DESTDIR = /usr/local
BINDIR = /bin
DOCDIR = /share/doc/$(NAME)

all:

install: all
	$(INSTALL) -d -m 0755 $(DESTDIR)$(BINDIR)
	$(INSTALL) -d -m 0755 $(DESTDIR)$(DOCDIR)
	$(INSTALL) -m 0755 rsvlog.sh "$(DESTDIR)$(BINDIR)/rsvlog"
	$(INSTALL) -m 0755 sv-helper.sh "$(DESTDIR)$(BINDIR)/sv-helper"
	$(INSTALL) -m 0644 README.md "$(DESTDIR)$(DOCDIR)/README.md"
	$(INSTALL) -m 0644 COPYING "$(DESTDIR)$(DOCDIR)/COPYING"
	cd "$(DESTDIR)$(BINDIR)"; \
	for sv in sv-start sv-stop sv-restart sv-list svls sv-enable sv-disable sv-find; do \
		ln -s sv-helper "$$sv"; \
	done

uninstall:
	rm -vf $(DESTDIR)$(BINDIR)/sv-helper
	rm -vf $(DESTDIR)$(BINDIR)/rsvlog
	for sv in sv-start sv-stop sv-restart sv-list svls sv-enable sv-disable sv-find; do \
		rm -vf "$(DESTDIR)$(BINDIR)/$$sv"; \
	done
	rm -vr $(DESTDIR)$(DOCDIR)
