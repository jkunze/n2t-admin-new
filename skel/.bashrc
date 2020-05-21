# This file of bash settings is source'd on shell start up to create
# an environment suitable for N2T.net administration.

PATH=$HOME/local/bin:$PATH

# As of 2019.09.16 the NAAN distribution was very heavy in the 80000's
# 2: 59
# 3: 52
# 4: 53
# 5: 53
# 6: 56
# 7: 57
# 8: 146

#function svu { eval `svu_run "$PS1"\|\|\|b $*`; }
if [ -f "$HOME/.svudef" ]; then
	source $HOME/.svudef
fi
if [ -f "$HOME/warts/env.sh" ]; then
	source $HOME/warts/env.sh
fi

export PERL_INSTALL_BASE=~/local	# note: this can change via svu
export PERL5LIB=~/local/lib/perl5	# note: this can change via svu
# This PYTHONPATH setting lets us use ~/n2t_create/mdsadmin.
export PYTHONPATH=$HOME/sv/cur/lib64/python2.6/dist-packages
export LC_ALL=C		# set computer mode locale, so all chars/scripts work

alias vi=vim
export LESS='ieFRX'	# ignore case, quit on 2nd EOF, honor color escapes,...
export LESSCHARSET=utf-8

# To run EZID and YAMZ locally
export PYTHONPATH=/usr/local/lib/python2.7/site-packages:$PYTHONPATH:$HOME/wr/ezid/SITE/PROJECT
export DJANGO_SETTINGS_MODULE=settings.localdev

# Some aliases that make n2t/eggnog development and testing easier.
#
alias blib="perl -Mblib"
# $PERL_INSTALL_BASE interpolated at run time, eg, when "svu cur" in effect
alias mkperl='perl Makefile.PL INSTALL_BASE=$PERL_INSTALL_BASE'

# XXX should source these from $se/s/n2t/service.cfg

n2prda='n2t@ids-n2t-prd-2a.n2t.net'
	alias n2prda="ssh $n2prda"
n2prdb='n2t@ids-n2t-prd-2b.n2t.net'
	alias n2prdb="ssh $n2prdb"
ezprd='ezid@ezid.cdlib.org'
	alias ezprd="ssh $ezprd"
n2stga='n2t@ids-n2t-stg-2a.n2t.net'
	alias n2stga="ssh $n2stga"
n2stgb='n2t@ids-n2t-stg-2b.n2t.net'
	alias n2stgb="ssh $n2stgb"
n2stgc='n2t@ids-n2t-stg-2c.n2t.net'
	alias n2stgc="ssh $n2stgc"
n2dev='n2t@ids-n2t-dev.n2t.net'
	alias n2dev="ssh $n2dev"
n2dev2='n2t@ids-n2t2-dev.n2t.net'
	alias n2dev2="ssh $n2dev2"
n2stg2='n2t@ids-n2t2-stg.n2t.net'
	alias n2stg2="ssh $n2stg2"
n2prd2='n2t@ids-n2t2-prd.n2t.net'
	alias n2prd2="ssh $n2prd2"
n2devb='n2t@ids-n2t2-dev-2b.n2t.net'
	alias n2devb="ssh $n2devb"
n2edina='n2t@n2tlx.edina.ac.uk'
	alias n2edina="ssh $n2edina"

alias ezmonit='~/ezidclient p admin:$(wegnpw ezidadmin) pause monitor'
alias zp='ezcl p admin:$(wegnpw ezidadmin) pause'

if [ ! -z "${PS1:-}" ]; then		# if interactive shell

	[ -f /usr/local/etc/bash_completion ] &&
		source /usr/local/etc/bash_completion
	#blue=$(tput setaf 4)
	yellow=$(tput setaf 3)
	reset=$(tput sgr0)
        #PS1='\[$blue\]\h:\W \u\$ \[$reset\]'
	# Make bash check its window size after a process completes
	shopt -s direxpand	# make tab completion stop escaping $var
	shopt -s checkwinsize
	#set -o vi		# for vi-style command line editing

	# Code below sets prompt to indicate which mercurial or git
	# branch is active, and whether there's anything to commit.

	# Code adapted (--quiet, changing ⚡ to ** because of utf8 character
	# width problems) from
	# https://blog.progs.be/351/change-bash-prompt-to-include-dvcs-branch-and-dirty-indicator

	# From https://stackoverflow.com/questions/7112774/how-to-escape-unicode-characters-in-bash-prompt-correctly
	# tput sc/rc gets around bash bug in correct unicode char widths
	#dirty='\[$yellow\]**\[$reset\]'
	dvcs_dirty_mark='⚡'
# xxx until Nov 2018, high sierra, bash 4.4.12, this next pad was only one
#     space, ie, ' '; not tested this under linux2
# xxx maybe this need for padding etc is obviated!
	dvcs_dirty_pad='  '	# same width as dirty mark, for width bug
	dvcs_branch=
	function parse_dvcs_branch {
		dvcs_branch=$( hg branch 2> /dev/null ) && {
			echo "$dvcs_branch"
			#echo "<\[$yellow\]$dvcs_branch\[$reset\]>"
			#echo "<$dvcs_branch>"
			return
		}
		dvcs_branch=$( git branch --no-color 2> /dev/null ) ||
			return		# no git repo
		dvcs_branch=$( sed -ne 's/^\* //p' <<< "$dvcs_branch" ) && {
			# cleans up multi-line git branch message
			echo "$dvcs_branch"
			#echo "<$dvcs_branch>"
			return
		}
		# yyy wish I could save $dvcs_branch in calling shell
	}
	function parse_dvcs_dirty {
		[[ $( hg --quiet status 2> /dev/null ) != "" ]] && {
			echo "$dvcs_dirty_mark"
			return
		}
		local gitish=
		dvcs_dirty=$( git status 2> /dev/null ) &&
			gitish=1		# git repo present
		[[ "$gitish" && ! $( tail -n1 <<< "$dvcs_dirty" ) =~ \
				'nothing to commit, working' ]] && {
			echo "$dvcs_dirty_mark"
			return
		}
		echo "$dvcs_dirty_pad"
		return
	}
	#PS1+='$(parse_dvcs_branch)\[$yellow\]$(parse_dvcs_dirty)\[$reset\]'
	PS1='\[$yellow\]\h\[$reset\]:\W \u'
	PS1+='<\[$yellow\]$(parse_dvcs_branch)\[$reset\]>'
	PS1+='\[`tput sc`\]$dvcs_dirty_pad\[`tput rc`$(parse_dvcs_dirty)\]'
	#PS1+='\[`tput sc`\]$dvcs_dirty_pad\[`tput rc`$dvcs_dirty_mark\]'
	PS1+='\$ '
fi

# General aliases and functions.
# xxx should the aliases below become functions?
alias c=clear	# health: clear often so eyes/neck not always at screen bottom
alias h="history | tail -100"
alias edate="date '+%Y%m%d%H%M%S'"              # ERC-style date
alias isodate="date '+%Y-%m-%dT%H:%M:%S%z'"	# ISO8601-style date

# "command" prevents recursion
function ls { command ls -F "$@"; }
function cp { command cp -p "$@"; }
function scp { command scp -p "$@"; }
function df { command df -k "$@"; }

function j() { jobs -l "$@"; }
function j() { jobs -l "$@"; }
function m() { less "$@"; }
function q() { exit "$@"; }
function rl() { rlogin "$@"; }
function z() { suspend "$@"; }
function pd() { pushd "$@"; }
function pp() { popd "$@"; }
function ll() { ls -lF "$@"; }

# usage:  mm any_command
#function mm()  { $* $2 $3 $4 $5 $6 $7 $8 $9 | 2>&1 more ; }
function mm()   { "$@" | 2>&1 less ; }
# usage:  g pattern any_command
function g() { $2 $3 $4 $5 $6 $7 $8 $9 | grep -i "$1" ; }
function hd()   { "$@" | head -5 ; }
function hd1()  { "$@" | head -1 ; }
function hd2()  { "$@" | head -10 ; }
function llt()  { hd ls -lt ; }
function llt1() { hd1 ls -lt ; }
function llt2() { hd2 ls -lt ; }
function val { v=$(bc <<< "scale=5; "$@""); echo v=$v ; }
function v { v=`sed "s/  */+/g" <<< "scale=5;"$@"" | bc`; echo v=$v; }

function eztest () {
	ezcl p - status '*'
	echo -n "mint test: "
	ezcl p apitest:apitest mint ark:/99999/fk4
}

function yaml {
	[[ "$1" ]] || {
		cat << EOT 1>&2
Usage: yaml [--bash] FILE ...
This function checks the YAML syntax of each FILE argument. The --bash option
causes it to output equivalent bash-style environment variable settings.
EOT
		return 1
	}
	local envout=		# "false"
	[[ "$1" == "--bash" ]] && {
		shift
		# this means we'll output bash-style env vars
		# xxx to do: create a warts section inside egg_config
		envout='
			my $warts = $cfh->{warts};
			while (my ($k, $v) = each %$warts) {
				say "$k=$v";
			}'
	}
	local status=0
	for f in $@
	do
		# verify YAML; use non-Tiny YAML for better error messages
		perl -CS -E '
			use YAML "LoadFile";
			my $cfh = LoadFile("'"$f"'");
			'"$envout"			|| {
			echo "syntax not ok - $f"
			status=1
			continue
		}
		[[ "$envout" ]] ||
			echo syntax ok - $f
	done
	return $status
}

# As of 2019.09.16 the NAAN distribution was very heavy in the 80000's
# 1: 63
# 2: 59
# 3: 52
# 4: 53
# 5: 53
# 6: 56
# 7: 57
# 8: 146

function naan_distrib {
	local i
	for i in 1 2 3 4 5 6 7 8
	do
		echo -n "$i: "
		grep -c "what:[      ]*$i" master_naans
	done
}

function in_ezid {
	local id n=5
	[[ "$1" ]] || {
		cat << EOT 1>&2
Usage: in_ezid ID_START ...

Print any ids (up to $n) in the EZID binder that start with ID_START. Examples:

	in_ezid ark:/13030
	in_ezid doi:10.5070/P2
EOT
		return 1
	}
	for id in "$@"
	do
		echo "=== $id ==="
		egg -d ~/binders/ezid list $n "$id"
	done
}

# For .vimrc, to change "::" into "make_shdr --remove"
# :map KM yyP2smake_shdr --remove^[

function modversion () {
	[[ "$1" ]] || {
		echo "Usage: modversion ModuleName ..."
		return
	}
	local module file
	for module in $@
	do
		file=$( perldoc -l $module )
		echo -n "$module: "; grep '\<VERSION.*=' $file
	done
}

function run () {
	local me=run
	local in=$me.in times=$me.times out=$me.out
	Command="$1"
	[[ ! "$Command" ]] && {
		echo "Usage: $me Command

Run Command in background with nohup, appending time history to $times and
overwriting $out with stdout and stderr.  Command may consist of multiple
shell commands, for example,

    $me 'make && make test'

Added to timing info is a mnemonic (eg, \"maktest\") derived from Command.
"

		return
	}
	# Contrive a tag out of command by dropping all spaces and non-word
	# chars and returning the first 3 plus the last 4 chars.
	#
	local tag=$( perl -pe \
		's/\W//g; $n = length; $n > 7 and substr($_, 3, $n - 7) = ""' \
			<<< "$Command" )
	local d=$( date "+%Y.%m.%d_%H:%M:%S $tag:" )
	echo "Backgrounding \"$Command\"; see $out and $times ($tag)."

	# There may be a bash bug that prevents the true exit status ($?) from
	# getting recorded.  For now, don't trust the status saved in $times.
	#
	nohup time -p bash -c "($Command) > $out 2>&1; echo -n \"$d\"$?\ " |
		perl -00 -pe 's/    */ /g; s/\n(.)/ $1/g' >> $times &
}

# lists all functions/aliases if no arg, else shows defs for given args
function func() {
	if [[ ! "$@" ]]; then
		echo === ALIASES ===
		alias
		echo
		echo === FUNCTIONS ===
		declare -f | sed '/^}/a\
\
' | perl -00 -pe 's/\s*\(/\t(/; s/\n{\s*/{ /; s/\n}\s*$/; }\n/; s/\n\s+/ /g; s/\(\) //;'
		return
	fi;
	for f in "$@"; do
		type $f;
	done;
}

# Because of the primitive way we switch in an out of svu modes, we want
# the change into svu mode to be the last PATH change we need to do.
# Put it here at the end to be safe.
# 
if [ ! -z "${SVU_USING:-}" ]; then	# if SVU mode is set
	svu reset > /dev/null	# clear it out
fi
svu cur			# this is what we want by default

# XXX maybe these should be set by svurun?
sa=$sv/apache2
se=$sv/build/eggnog
sn=~/n2t_create

