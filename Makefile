# -*- Makefile -*-

all:

## ------ Setup ------

WGET = wget
GIT = git

deps: git-submodules pmbp-install

git-submodules:
	$(GIT) submodule update --init

local/bin/pmbp.pl:
	mkdir -p local/bin
	$(WGET) -O $@ https://raw.github.com/wakaba/perl-setupenv/master/bin/pmbp.pl
pmbp-upgrade: local/bin/pmbp.pl
	perl local/bin/pmbp.pl --update-pmbp-pl
pmbp-update: pmbp-upgrade
	perl local/bin/pmbp.pl --update
pmbp-install: pmbp-upgrade
	perl local/bin/pmbp.pl --install \
            --create-perl-command-shortcut perl \
            --create-perl-command-shortcut prove \
	    --create-perl-command-shortcut plackup \
	    --create-perl-command-shortcut local/bin/which

## ------ Tests ------

PROVE = ./prove

test: test-deps test-main

test-deps: deps
	cd modules/rdb-utils && $(MAKE) deps
	cd modules/workaholicd && $(MAKE) deps

test-main:
	$(PROVE) t/*.t
