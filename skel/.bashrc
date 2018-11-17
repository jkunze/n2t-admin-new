PATH=$HOME/local/bin:$PATH

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
export LESSCHARSET=utf-8

# Some aliases that make n2t/eggnog development and testing easier.
#
alias blib="perl -Mblib"
# $PERL_INSTALL_BASE interpolated at run time, eg, when "svu cur" in effect
alias mkperl='perl Makefile.PL INSTALL_BASE=$PERL_INSTALL_BASE'

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
n2edina='n2t@n2tlx.edina.ac.uk'
	alias n2edina="ssh $n2edina"

alias zp='ezcl p admin:$(wegnpw ezidadmin) pause'

alias n2edina="ssh n2t@n2tlx.edina.ac.uk"

# XXX it's not clear if this file is always source'd by convention,
#     but that's what the SLES /etc/... startup files for bash do it;
#     we'll go along because we really only want this next bit done if
#     we're an interactive shell and _after_ the svu function is defined
if [ ! -z "${PS1:-}" ]; then	# if there's a prompt, make it decent
        PS1='\h:\W \u\$ '
	# Make bash check its window size after a process completes
	shopt -s checkwinsize
fi

# General aliases and functions.
# xxx should the aliases below become functions?
#
alias c=clear	# health: clear often so eyes/neck not always at screen bottom
alias h="history | tail -100"
alias edate="date '+%Y%m%d%H%M%S'"              # ERC-style date
# "command" prevents recursion
function ls { command ls -F "$@"; }
function cp { command cp -p "$@"; }
function scp { command scp -p "$@"; }
function df { command df -k "$@"; }

function j() { jobs -l "$@"; }
function j() { jobs -l "$@"; }
function m() { more "$@"; }
function q() { exit "$@"; }
function rl() { rlogin "$@"; }
function z() { suspend "$@"; }
function pd() { pushd "$@"; }
function pp() { popd "$@"; }
function ll() { ls -lF "$@"; }

# usage:  mm any_command
#function mm()  { $* $2 $3 $4 $5 $6 $7 $8 $9 | 2>&1 more ; }
function mm()   { "$@" | 2>&1 more ; }
# usage:  g pattern any_command
function g() { $2 $3 $4 $5 $6 $7 $8 $9 | grep -i "$1" ; }
function hd()   { "$@" | head -5 ; }
function hd1()  { "$@" | head -1 ; }
function hd2()  { "$@" | head -10 ; }
function llt()  { hd ls -lt ; }
function llt1() { hd1 ls -lt ; }
function llt2() { hd2 ls -lt ; }

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

