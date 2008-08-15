# Makefile for AutoRescan plugin for SqueezeCentre 7.0 (and later)
# Copyright © Stuart Hickinbottom 2007-2008

# This file is part of AutoRescan.
#
# AutoRescan is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# AutoRescan is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with AutoRescan; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA

# $Id$

VERSION=1.0b5
PERLSOURCE=Plugin.pm Settings.pm Monitor_Linux.pm
HTMLSOURCE=HTML/EN/plugins/AutoRescan/settings/basic.html
SOURCE=$(PERLSOURCE) $(HTMLSOURCE) INSTALL strings.txt install.xml LICENSE
RELEASEDIR=releases
STAGEDIR=stage
SLIMDIR=/usr/local/squeezecenter/server
PLUGINSDIR=$(SLIMDIR)/Plugins
PLUGINDIR=AutoRescan
REVISION=`svn info . | grep "^Revision:" | cut -d' ' -f2`
DISTFILE=AutoRescan-$(VERSION).tgz
DISTFILEDIR=$(RELEASEDIR)/$(DISTFILE)
SVNDISTFILE=AutoRescan.tgz
LATESTLINK=$(RELEASEDIR)/AutoRescan-latest.tgz
PREFS=/etc/squeezecenter.pref

.SILENT:

all:
	echo Try 'make install', 'make release' or 'make pretty'
	echo Or, 'make install restart logtail'

FORCE:

make-stage:
	echo "Creating plugin stage files (v$(VERSION))..."
	-chmod -R +w $(STAGEDIR)/* >/dev/null 2>&1
	-rm -rf $(STAGEDIR)/* >/dev/null 2>&1
	for FILE in $(SOURCE); do \
		mkdir -p "$(STAGEDIR)/$(PLUGINDIR)/`dirname $$FILE`"; \
		sed "s/@@VERSION@@/$(VERSION)/" <"$$FILE" >"$(STAGEDIR)/$(PLUGINDIR)/$$FILE"; \
	done
	chmod -R -w $(STAGEDIR)/*

# Regenerate tags.
tags: $(PERLSOURCE)
	echo Tagging...
	exuberant-ctags $^

# Run the plugin through the Perl beautifier.
pretty:
	for FILE in $(PERLSOURCE); do \
		perltidy -b -ce -et=4 $$FILE && rm $$FILE.bak; \
	done
	echo "You're Beautiful..."

# Install the plugin in SqueezeCentre.
install: make-stage
	echo Installing plugin...
	-[[ -d "$(PLUGINSDIR)/$(PLUGINDIR)" ]] && sudo chmod -R +w "$(PLUGINSDIR)/$(PLUGINDIR)"
	-[[ -d "$(PLUGINSDIR)/$(PLUGINDIR)" ]] && sudo rm -r "$(PLUGINSDIR)/$(PLUGINDIR)"
	sudo cp -r "$(STAGEDIR)/$(PLUGINDIR)" "$(PLUGINSDIR)"
	sudo chmod -R -w "$(PLUGINSDIR)/$(PLUGINDIR)"

# Restart SqueezeCentre, quite forcefully. This is obviously quite
# Gentoo-specific.
restart:
	echo "Forcefully restarting SqueezeCentre..."
	-sudo pkill -9 squeezeslave
	sudo /etc/init.d/squeezeslave zap
	sudo /etc/init.d/squeezecenter stop
	sudo /etc/init.d/squeezecenter zap
	sleep 2
	sudo sh -c ">/var/log/squeezecenter/server.log"
	sudo sh -c ">/var/log/squeezecenter/scanner.log"
	sudo sh -c ">/var/log/squeezecenter/perfmon.log"
	sudo /etc/init.d/squeezecenter restart
	sudo /etc/init.d/squeezeslave restart

logtail:
	echo "Following the end of the SqueezeCentre log..."
	multitail -f /var/log/squeezecenter/server.log

# TODO - fix this for new package layout
# Build a distribution package for this Plugin.
release: make-stage
	echo Building distfile: $(DISTFILE)
	echo Remember to have committed and updated first.
	-rm "$(DISTFILEDIR)" >/dev/null 2>&1
	(cd "$(STAGEDIR)" && tar czvf "../$(DISTFILEDIR)" "$(PLUGINDIR)")
	-rm "$(LATESTLINK)" >/dev/null 2>&1
	ln -s "$(DISTFILE)" "$(LATESTLINK)"
	cp $(DISTFILEDIR) $(SVNDISTFILE)
