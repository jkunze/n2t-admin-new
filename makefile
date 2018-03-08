# Support for creating an exportable tar file of "n2t_create".

# yyy To do:
# - add code to autogenerate (openssl x509 -in file.crt -text -noout) a
#   text version (README) of cert in the warts/ssl dir


HOST=`hostname -f`
EGNAPA_HCLASS=`admegn class | sed 's/ .*//'`
LBIN=$(HOME)/local/bin
LOGS=$(HOME)/sv/cur/apache2/logs
TMP=/tmp/n2t_create
# removed recently: $(HOME)/init.d/apache 
UTILITIES=$(LBIN)/n2t $(LBIN)/wegn $(LBIN)/wegnpw $(LBIN)/admegn \
	$(LBIN)/logwhich $(LBIN)/logwatch $(LBIN)/bdbkeys $(LBIN)/mrm \
		$(LBIN)/ezcl $(LBIN)/ia $(LBIN)/ezmdsadmin \
		$(LBIN)/pfx $(LBIN)/mg $(LBIN)/showargs \
		$(LBIN)/make_shdr $(LBIN)/shdr_exists $(LBIN)/make_ezacct \
		$(LBIN)/doip2naan $(LBIN)/naan $(LBIN)/valsh \
	$(LBIN)/granvl $(LBIN)/set_crontab $(LBIN)/replicate \
	$(LBIN)/egg_batch
FILES=boot_install_n2t db-5.3.28.tar.gz zlib-1.2.8.tar.gz \
	make_instance set_crontab replicate n2t apache svu_run
# NB: that the two ezid rlogs get pride of place over all other binders
QLINKS=$(HOME)/shoulders $(HOME)/minters $(HOME)/binders
QL=$(HOME)/logs
QLOGLINKS=$(QL)/access_log $(QL)/error_log $(QL)/rewrite_log \
	$(QL)/binders/ezid/egg.rlog \
	$(QL)/binders/ezid/rrm.rlog

# default target
basic: basicdirs basicfiles hostname svu utilities $(HOME)/init.d/apache cron

# a bigger target
all: basic n2t_create.tar.gz

# sub-targets of "basic"
utilities: $(UTILITIES)

# this uses a "static pattern"
$(UTILITIES): $(LBIN)/%: %
	cp -p $< $(LBIN)

#quicklinks: $(QLINKS) $(QLOGLINKS)
##
##@[[ -L $(HOME)/$$(basename $@) ]] || ln -s $@ $(HOME)
##$(HOME)/logs/access_log : %
##	ln -s ~/sv/cur/apache2/logs/$@ ~
##
#$(QLINKS):
#	ln -s $@ $(HOME)
#
##[[ -L $(HOME)/logs/$$(basename $@) ]] || ln -s $@ $(HOME)/logs
#$(QLOGLINKS):
#	date

svu: $(LBIN)/svu_run $(HOME)/sv

# XXXXXXXX why was this so necessary to set up at one time!!??
# This is the production master cert dir; should start with a 4-digit year.
# If there's more than one, take only the latest (lexically last) one.
#CERT_DIR=`cd skel; ls -d ssl/20[0-9][0-9]* | tail -1`

hostname: $(HOME)/warts/env.sh

# yyy probably should link to copies in ~/warts/ssl/.. of system-supplied
# certs dropped into (~/ssl)

$(HOME)/warts/env.sh:
	@echo -e > $@ \
"#!/bin/sh\n\
# This shell script sets some instance-specific environment variables.\n\
# The build_server_tree script (eggnog source) reads these for host and\n\
# certificate configuration.\n\
#\n\
# Use EGNAPA_SSL_CERTFILE for the full path of a signed certificate,\n\
# if any, and similarly for EGNAPA_SSL_KEYFILE and EGNAPA_SSL_CHAINFILE.\n\
#\n\
#"
	@read -t 60 -p "HOSTNAME (default $(HOST)): " && echo -e >> $@ \
"export EGNAPA_HOST=$${REPLY:-$(HOST)}\n\
export EGNAPA_HOST_CLASS=dev              # often one of dev, stg, prd\n\
export EGNAPA_SSL_CERTFILE=\n\
export EGNAPA_SSL_KEYFILE=\n\
export EGNAPA_SSL_CHAINFILE="

# yyy after waiting period, drop EGNAPA_HOST_CLASS defs from warts
# yyy bug? some things require a defined EGNAPA_HOST_CLASS (chicken and egg)
# yyy 
#@ export EGN_CLASS=$$( admegn class | sed 's/ .*//' )

egnapa:
	@if [[ -z "$(EGNAPA_HCLASS)" ]]; then \
		echo 'EGNAPA_HCLASS not defined (see "admegn class")'; \
		exit 1; \
	fi
	@echo "Defining host class \"$(EGNAPA_HCLASS)\""

#egnapa:
#	@if [[ -z "$(EGNAPA_HOST_CLASS)" ]]; then \
#		echo "EGNAPA_HOST_CLASS not defined (see ~/warts/env.sh)"; \
#		exit 1; \
#	fi
#	@echo "Defining $(EGNAPA_CLASS) host class \"$(EGNAPA_HOST_CLASS)\" via ~/warts/env.sh. xxx next time via 'admegn class'"

cron: egnapa
	@cd cron; \
	if [[ ! -s $$( readlink crontab ) ]]; then \
		rm -f crontab; \
		ln -s "crontab.$(EGNAPA_HCLASS)" crontab; \
	fi; \
	if [[ ! -s $$( readlink crontab ) ]]; then \
		echo 'Error: not updating crontab from zero-length file'; \
	elif [[ $$(readlink crontab) != crontab.$(EGNAPA_HCLASS) ]]; then \
		echo "Error: crontab doesn't link to a $(EGNAPA_HCLASS)-class file"; \
	else \
		crontab -l > crontab_saved; \
		cmp --silent crontab_saved crontab && { \
			exit 0; \
		}; \
		echo Updating crontab via $$( readlink crontab ); \
		crontab crontab; \
	fi

# Goal here is to reflect basic skeleton in the maintenance/role account.
# removed:     rsync -ia ssl/$(EGNAPA_HCLASS)/ $(HOME)/ssl/;
basicfiles: egnapa
	@cd skel; \
	asked=; \
	for f in `find . | sed -e 's,^\./,,' -e '/^ssl\//d'`; \
	do \
		if [[ ! -f $$f ]]; then \
			true; \
		elif [[ ! -f $(HOME)/$$f ]]; then \
			cp -p $$f $(HOME)/$$f; \
		elif [[ $$f =~ .hgrc|.bashrc|.bash_profile ]]; then \
			cmp -s $$f $(HOME)/$$f || echo "Warning: skel/$$f" \
				"different from $(HOME)/$$f"; \
		elif [[ $$f -nt $(HOME)/$$f ]]; then \
			[[ $$asked ]] || echo -e \
    "Take care overwriting files (eg, .bashrc) from skel/ with content\nto" \
    "preserve.  Content from skel may be better moved manually."; \
			cp -ip $$f $(HOME)/$$f; \
			asked=1; \
		fi; \
	done; true
	@chmod 600 $(HOME)/.hgrc

BASICDIRS=$(LBIN) $(HOME)/warts $(HOME)/warts/ssl $(HOME)/ssl \
	$(HOME)/.ssh $(HOME)/logs $(HOME)/init.d $(HOME)/backups \
	$(HOME)/shoulders $(HOME)/minters $(HOME)/binders $(HOME)/batches

basicdirs: $(BASICDIRS)

# xxx test this!
$(HOME)/backups:
	if [[ -d $(HOME)/../n2tbackup ]]; then \
		mkdir $(HOME)/../n2tbackup/backups; \
		ln -s $(HOME)/../n2tbackup/backups $@; \
	else \
		mkdir -p $@
	fi

$(LBIN) $(HOME)/warts $(HOME)/warts/ssl $(HOME)/init.d $(HOME)/batches:
	mkdir -p $@

# xxx add $(HOME) to last arg of ln -s ...  ?? (else problem if run in
# wrong directory)
$(HOME)/logs:
	mkdir -p $@
	-ln -s $(LOGS)/{access,error,rewrite}_log $@
	-ln -s $(HOME)/sv/cur/apache2/binders/ezid/egg.rlog $@/ezid.rlog
	-ln -s $(HOME)/sv/cur/apache2/binders/ezid/rrm.rlog $@/ezid.rrmlog

$(HOME)/shoulders $(HOME)/minters $(HOME)/binders:
	mkdir -p $(HOME)/sv/cur/apache2/$$(basename $@)
	ln -s $(HOME)/sv/cur/apache2/$$(basename $@) $@

$(HOME)/.ssh: $(HOME)/.ssh/id_rsa
	@mkdir -p $@

$(HOME)/.ssh/id_rsa:
	ssh-keygen -t rsa
	chmod 700 $(HOME)/.ssh

#$(LBIN)/n2t: n2t
#	cp -p $^ $(LBIN)
#
#$(LBIN)/wegn: wegn
#	cp -p $^ $(LBIN)
#
#$(LBIN)/wegnpw: wegnpw
#	cp -p $^ $(LBIN)
#
#$(LBIN)/logwatch: logwatch
#	cp -p $^ $(LBIN)
#
#$(LBIN)/bdbkeys: bdbkeys
#	cp -p $^ $(LBIN)
#
#$(LBIN)/logwhich: logwhich
#	cp -p $^ $(LBIN)
#
#$(LBIN)/set_crontab: set_crontab
#	cp -p $^ $(LBIN)
#
#$(LBIN)/replicate: replicate
#	cp -p $^ $(LBIN)

$(HOME)/init.d/apache: $(LBIN)/apache $(LBIN)/egnapa apache
	cp -p apache $(HOME)/init.d/

$(LBIN)/apache:
	-ln -s $(HOME)/init.d/apache $(LBIN)/apache

$(LBIN)/egnapa:
	-ln -s $(HOME)/init.d/apache $(LBIN)/egnapa

#$(LBIN)/cron_daily: cron_daily
#	cp -p $^ $(LBIN)
#	./cron_daily extract_crontab_entry | crontab -

$(LBIN)/svu_run: svu_run
	@echo NOTE: svu is maintained in its own repo.
	cp -p $^ $(LBIN)

$(HOME)/sv:
	@echo "Initializing SVU."
	@export PATH=$(LBIN):$$PATH; /bin/bash -c "cd; source .svudef; svu init"

n2t_create.tar.gz: $(FILES) makefile
	rm -fr $(TMP)
	mkdir $(TMP)
	cp -p $^ $(TMP)
	(cd /tmp; tar cf - n2t_create) > n2t_create.tar
	gzip n2t_create.tar
