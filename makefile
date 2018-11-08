NAME = sv-helper
SHELL = /bin/bash
INSTALL = /usr/bin/install
MSGFMT = /usr/bin/msgfmt
SED = /bin/sed
DESTDIR =
BINDIR = /usr/bin
DOCDIR = /usr/share/doc/$(NAME)

all:

install: all
	$(INSTALL) -d $(DESTDIR)$(BINDIR)
	$(INSTALL) -d $(DESTDIR)$(DOCDIR)
	$(INSTALL) -D -m 0755 sv-helper.sh "$(DESTDIR)$(BINDIR)/sv-helper"
	$(INSTALL) -D -m 0644 README.md "$(DESTDIR)$(DOCDIR)/README.md"
	$(INSTALL) -D -m 0644 COPYING "$(DESTDIR)$(DOCDIR)/COPYING"
	cd "$(DESTDIR)$(BINDIR)"; \
	for sv in sv-start sv-stop sv-restart sv-list svls sv-enable sv-disable sv-find; do \
		ln -s sv-helper "$$sv"; \
	done

uninstall:
	rm $(DESTDIR)$(BINDIR)/sv-helper
	for sv in sv-start sv-stop sv-restart sv-list svls sv-enable sv-disable sv-find; do \
		rm "$(DESTDIR)$(BINDIR)/$$sv"; \
	done
	rm -r $(DESTDIR)$(DOCDIR)
