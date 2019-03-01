# yyy? Support for creating an exportable tar file of "n2t_create".

#PATH=$(HOME)/local/bin:/usr/local/bin:/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/sbin
SHELL=bash
HOST=`hostname -f`
# ?= differs from = in not setting the value if it's already set; more at
EGNAPA_HOST_CLASS ?= `admegn class | sed 's/ .*//'`

#EGNAPA_HOST_CLASS=`admegn class | sed 's/ .*//'`
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
	$(LBIN)/granvl $(LBIN)/replicate \
	$(LBIN)/egg_batch
FILES=boot_install_n2t db-5.3.28.tar.gz zlib-1.2.8.tar.gz \
	make_instance replicate n2t apache svu_run
# NB: that the two ezid rlogs get pride of place over all other binders
#QLINKS=$(HOME)/shoulders $(HOME)/minters $(HOME)/binders
QL=$(HOME)/logs
QLOGLINKS=$(QL)/access_log $(QL)/error_log $(QL)/rewrite_log \
	$(QL)/binders/ezid/egg.rlog \
	$(QL)/binders/ezid/rrm.rlog

# default target
basic: basicdirs basicfiles hostname svu utilities $(HOME)/init.d/apache cron sslreadme

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

hostname: $(HOME)/warts/env.sh


# XXX this making of env.sh likely obsolete! see ec2_bootmake

$(HOME)/warts/env.sh:
	@echo -e > $@ \
"#!/bin/sh\n\
\n\
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
export EGNAPA_HOST_CLASS=$${EGNAPA_HOST_CLASS:-mac}              # eg, one of dev, stg, prd, mac\n\
\n\
export EGNAPA_SSL_CERTFILE=\n\
export EGNAPA_SSL_KEYFILE=\n\
export EGNAPA_SSL_CHAINFILE=\n\
\n\
# Define fully qualified hostname (don't trust hostname -f on some networks).\n\
export MG_HOST=\$$EGNAPA_HOST\n\
\n\
# Define the hostports of the mongod daemons that should start up.\n\
export MG_LOCAL_DAEMONS=\"\$$MG_HOST:27017,\$$MG_HOST:27018,\$$MG_HOST:27019\"\n\
\n\
# Define connection string hosts, which may include non-local servers.\n\
# If undefined, this var defaults to MG_LOCAL_DAEMONS.\n\
export MG_CSTRING_HOSTS=\"\$$MG_LOCAL_DAEMONS\"\n\
\n\
# Define default mongo replica set options for the connection string.\n\
export MG_REPSETOPTS=\"socketTimeoutMS=30000&readPreference=primaryPreferred\"\n\
\n\
# Define default mongo replica set name for the connection string.\n\
export MG_REPSETNAME=\"live\"\n\
\n\
# Define default starter port (in a series) for replica set testing.\n\
export MG_TEST_PORT=\"47017\"\
"

egnapa:
	@if [[ -z "$(EGNAPA_HOST_CLASS)" ]]; then \
		echo 'EGNAPA_HOST_CLASS not defined (see "admegn class")'; \
		exit 1; \
	fi
	@echo "Defining host class \"$(EGNAPA_HOST_CLASS)\""

#egnapa:
#	@if [[ -z "$(EGNAPA_HOST_CLASS)" ]]; then \
#		echo "EGNAPA_HOST_CLASS not defined (see ~/warts/env.sh)"; \
#		exit 1; \
#	fi
#	@echo "Defining $(EGNAPA_CLASS) host class \"$(EGNAPA_HOST_CLASS)\" via ~/warts/env.sh. xxx next time via 'admegn class'"

# yyy to do: preprocess crontab files so that MAILTO var gets set via a
#     setting in warts/env.sh

cron: egnapa
	@cd cron; \
	if [[ ! -s $$( readlink crontab ) ]]; then \
		rm -f crontab; \
		ln -s "crontab.$(EGNAPA_HOST_CLASS)" crontab; \
	fi; \
	if [[ ! -s $$( readlink crontab ) ]]; then \
		echo 'Error: not updating crontab from zero-length file'; \
	elif [[ $$(readlink crontab) != crontab.$(EGNAPA_HOST_CLASS) ]]; then \
		echo "Error: crontab doesn't link to a $(EGNAPA_HOST_CLASS)-class file"; \
	else \
		crontab -l > crontab_saved; \
		cmp --silent crontab_saved crontab && { \
			exit 0; \
		}; \
		echo Updating crontab via $$( readlink crontab ); \
		crontab crontab; \
	fi

# Goal here is to reflect basic skeleton in the maintenance/role account.

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
		mkdir -p $@; \
	fi

$(LBIN) $(HOME)/warts $(HOME)/warts/ssl $(HOME)/init.d $(HOME)/batches:
	mkdir -p $@

sslreadme:
	@ cfile=$$( echo $(HOME)/warts/ssl/*.crt ); \
	  rfile=$(HOME)/warts/ssl/README ; \
	if [[ -f "$$cfile" && ( ! -f $$rfile || $$cfile -nt $$rfile ) ]]; \
	then \
		openssl x509 -in $$cfile -text -noout > $$rfile ; \
	fi

# xxx add $(HOME) to last arg of ln -s ...  ?? (else problem if run in
# wrong directory)
$(HOME)/logs:
	mkdir -p $@
	-ln -s $(LOGS)/{access,error,rewrite}_log $@
	-ln -s $(HOME)/sv/cur/apache2/binders/ezid/egg.rlog $@/ezid.rlog
	-ln -s $(HOME)/sv/cur/apache2/binders/ezid/rrm.rlog $@/ezid.rrmlog

# NB: don't create dirs under apache2, since "n2t rollout" does special
#     processing the first time through

$(HOME)/minters $(HOME)/binders:
	rm -f $@
	ln -s $(HOME)/sv/cur/apache2/$$(basename $@) $@

$(HOME)/.ssh: $(HOME)/.ssh/id_rsa
	@mkdir -p $@

$(HOME)/.ssh/id_rsa:
	ssh-keygen -t rsa
	chmod 700 $(HOME)/.ssh

$(HOME)/init.d/apache: $(LBIN)/apache $(LBIN)/egnapa apache
	cp -p apache $(HOME)/init.d/

$(LBIN)/apache:
	-ln -s $(HOME)/init.d/apache $(LBIN)/apache

$(LBIN)/egnapa:
	-ln -s $(HOME)/init.d/apache $(LBIN)/egnapa

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
