#!/bin/bash

set -u
notify=jak@ucop.edu	# xxx failures
repsetlog=$HOME/logs/mg_repsetlog
configfile=$HOME/warts/env.sh
config_unread=1

# xxx
# new protocol: on ec2 instance start, boot mongo then apache;
#  boot mongo means 1. start mongo daemon 2. attempt to add to existing
#    rset (but how do you know where to connect to it?),
#    well-known connection point is default primary with default config
#      primary: n2t.net:27016:ids-n2t-2b.n2t.net:27017
#        and failing that attempt init rset and add it
# 
# On system boot, "apache start" calls something, eg, "mg rs_start"
# "mg rs_start" consults env vars set in ~/warts/env.sh

me=$( basename $0 )
function usage {

	local port=$mg_live_port_default
	local snam=$mg_live_repsetname_default

summary="
       $me [flags] start [ Port [ Setname ] ]
       $me [flags] restart [ Port ]
       $me [flags] stop [ Port ]
       $me [flags] hard-stop [ Port ]
       $me [flags] status [ Port ]

       $me [flags] rs_start
       $me [flags] rs_stop
       $me [flags] rs_status
       $me [flags] rs_add Port
       $me [flags] rs_del Port
       $me [flags] repltest [ Setcount ]
"
	cat << EOT

SYNOPSIS                          ($0)
       $me - mongodb service manager

USAGE $summary

DESCRIPTION
       The $me tool manages various administrative tasks for MongoDB clents and
       servers. It currently assumes you are running under an "svu" service
       version (type "svu" for details). A non-zero exit status indicates an
       error. Port (default $port) and Setname (default $snam) are optional.

xxx how can Port be optional?
       Operating on one MongoDB server instance given by Port, the commands

           start, restart, stop, hard-stop, status

       do what the name suggests. Each instance starts up ready to be part of
       the replica set, Setname, regardless of whether it ever actually joins
       the set.

       Operating on one of two MongoDB replica sets, the commands

           rs_start, rs_stop, rs_status, rs_add, rs_del

       The effected replica set is the "live" public-facing set (ports starting
       from 27017) unless the -t flag is present, in which case it is a test
       replica set (ports starting 47017).

       The "repltest" command operates on the test replica set. It starts up
       Setsize servers, adds them to the "test" replica set, and writes data
       to the set. It then attempts to read that data back from each replica
       instance in the set, and then shuts everything down. A Setsize of 1 is
       possible, but the test ... sometimes fails... to write since (?) a
       replica set with fewer than 3 members cannot elect a primary and becomes
       read-only. Specify a Setsize of 0 to reinitialize the testing framework
       (when it gets wedged).

       xxx
       To manage a replica set, each replica should boot and start it's own
       local daemon(s) (27017, 27018?) with the default replica set name.

OPTION FLAGS
       -v, --verbose   be much more wordy
       -t, --test      run in test mode (away from "live" data directory)

FILES
       xxx process files, log files

EXAMPLES
       $me start
       $me stop
       $me repltest 11

SUMMARY $summary

EOT
}

# Global variables we need but whose values depend on $mg_mode.
# Unsetting them here helps flush out "unbound" errors (via "set -u").

# xxx refresh this list
unset	mg_root mg_root_alt \
	mg_port mg_host mg_hostport \
	mg_setname mg_dbname mg_mode \
	mg_dbdir_base mg_proc_base mg_rset_base \
	mg_dbdir mg_dblog mg_dbpath mg_flags mg_procfile \
	mg_rs_history mg_rs_high_port \
	mg_local_daemons mg_live_local_daemons mg_test_local_daemons \
tesnu

# Configures replica set (global var that govern replica set flags).
# yyy a better way might be to _return_ values, not set as globals

# Global mg constants overridable via environment variables.

mg_live_port_default=27017		# standard port
mg_test_port_default=47017		# 20K more
mg_live_repsetname_default=live		# default live replica set name
mg_test_repsetname_default=test		# default test replica set name

mg_repsetopts_default="socketTimeoutMS=30000&readPreference=primaryPreferred"
					# connection string options (see below)

# Global variables (changing)
unset mg_dlist				# actual local daemon list
unset mg_cstring			# actual connection string
mg_initialized=				# trick to speed up rs_start

# --- notes on repsetopts ---
# does readpref work in the connection string?
#     ???? best to leave readpref as primary?
#readpref=nearest	# yyy often not updated soon enough for our test
#repSetOpts+="readPreference=$readpref&"	# replica to read from
#repSetOpts+="socketTimeoutMS=45000&"	# wait up to 45 secs for reply
# XXX commented out maxTimeMS setting for now because it triggers
#     an error message even though the connection seems to succeed
#     The perl module docs say this is an important attribute to
#     set, so we want to uncomment this next line when we figure
#     out what's wrong (eg, a module bug gets fixed?)
#repSetOpts+="maxTimeMS=15000&"		# wait up to 15 secs to do DB command
			# NB: maxTimeMS must be shorter than socketTimeoutMS

# Other global mg constants.

mg_live_root=$HOME/sv/cur/apache2/mongo
mg_test_root=$HOME/sv/cur/apache2/mongo_test
mg_live_dbname=live		# live replica set name
mg_test_dbname=test		# test replica set name
mg_live_mode=live		# 'live' or 'test'
mg_test_mode=test		# 'live' or 'test'

mg_other="--fork --logappend"		# additional mongod daemon flags
mg_other+=" --storageEngine wiredTiger"
#--bind_ip 'localhost,172.31.23.24'	# no space after comma
#--rest		# deprecated since 3.2: admin UI: http://localhost:28017

# Call to init other globals depending on whether we're in live or test mode.

function use_mg {			# call with: port|'any' [ setname ]

	[[ "$config_unread" && -f "$configfile" ]] && {	# read once per process
		[[ "$verbose" ]] &&
			echo "reading $configfile" 1>&2
		source $configfile
		config_unread=
		# Adjust globals depending on what definitions just came in.
		mg_test_port=${MG_TEST_PORT:-$mg_test_port_default}
		mg_live_local_daemons=${MG_LOCAL_DAEMONS:-}
		# NB: MG_CSTRING_HOSTS only defaults if undefined (- not :-)
		mg_live_cstring_hosts=${MG_CSTRING_HOSTS-$mg_live_local_daemons}
		mg_repsetopts=${MG_REPSETOPTS:-$mg_repsetopts_default}
		mg_repsetname=${MG_REPSETNAME:-$mg_repsetname_default}
	}
	[[ -z ${mg_host+x} ]] && {	# if unset (sets only once per process)
		mg_host=${MG_HOST:-}		# try env var
		[[ "$mg_host" ]] || {		# if still empty, call hostname
			mg_host=$( hostname -f )	# where daemon runs
		}
		[[ ! "$mg_host" =~ \. ]] &&	# some networks (eg, some wifi)
			mg_host+=.local		# don't add qualifier we need
	}
	# From docs:
	#  "Either all host names in a replica set configuration must
	#   be localhost references, or none must be."

	local hostport=${1:-}			# yyy we don't use host part
	local port=${hostport##*:}		# delete up to last ':'
	if [[ $mg_mode == $mg_live_mode ]]
	then
		mg_port=${port:-$mg_live_port_default}
		mg_setname=${2:-$mg_live_repsetname_default}
		mg_dbname=${2:-$mg_live_dbname}
		mg_root=$mg_live_root
		mg_root_alt=$mg_test_root
		mg_local_daemons=${mg_live_local_daemons:-}
		mg_cstring_hosts=${mg_live_cstring_hosts:-}

	elif [[ $mg_mode == $mg_test_mode ]]
	then
		mg_port=${port:-$mg_test_port_default}
		mg_setname=${2:-$mg_test_repsetname_default}
		mg_dbname=${2:-$mg_test_dbname}
		mg_root=$mg_test_root
		mg_root_alt=$mg_live_root
		mg_local_daemons=${mg_dlist-}	# might be from repltest
		mg_cstring_hosts=$mg_local_daemons
	else
		echo "error: unknown mode: $mode" 1>&2
		return 1
	fi

	# mg_proc_base_alt lets "stop" remove a procfile, started in either
	# live or test mode, knowing only the port
	mg_proc_base_alt=$mg_root_alt/proc_

	mg_proc_base=$mg_root/proc_
	mg_rset_base=$mg_root/rset_
	mg_dbdir_base=$mg_root/data_
	mg_rs_history=$mg_root/rs_history

	# yyy? Maybe separate function should set stuff above once per process
	local cstring_dlist=${mg_cstring_hosts-$mg_local_daemons}
		# NB: MG_CSTRING_HOSTS only defaults if undefined (- not :-)
	mg_cstring="mongodb://$cstring_dlist/?"
		mg_cstring+="${mg_repsetopts:-$mg_repsetopts_default}"
		mg_cstring+="&replicaSet=$mg_setname"

	# If we weren't given a specific port, we can leave early knowing
	# that we've now set as many variables as we can without requiring a
	# real port number.

	# yyy rethink these conditional bits
	[[ "$mg_port" == 'any' ]] &&		# nothing more we can set now
		return 0			#   so leave early
	[[ "$mg_port" =~ ^[0-9][0-9]*$ ]] || {	# anything else must be numeric
		echo "error: port ($mg_port) must be numeric" 1>&2
		return 1
	}
	mg_hostport="$mg_host:$mg_port"

	mg_dbdir=$mg_dbdir_base$mg_port		# all server-related data
	mg_dblog=$mg_dbdir/mg_log
	mg_dbpath=$mg_dbdir

	# yyy "local" could one day be a hostname
	mg_procfile="$mg_proc_base""local:$mg_port"
	mg_procfile_alt="$mg_proc_base_alt""local:$mg_port"
	mg_flags=(
		--port $mg_port --replSet $mg_setname
		--dbpath $mg_dbpath --logpath $mg_dblog
		$mg_other
	)
	mkdir -p $mg_dbdir $mg_dbpath
	return 0
}

def_setsize=5			# default set size yyy repeated
max_setsize=50
max_voting_members=7

# Usage: out_if exitcode [ error | stderr | any ] [ message ]
#
# Output message based on exitcode and condition:
#   error - on error print message on stdout for non-zero exitcode
#   stderr - on error print message on stderr for non-zero exitcode
#   any - always print message on stdout
#
function out_if {
	local ecode=$1 condition=$2 message=$3
	[[ "$ecode" ]] || ecode="no exit code for out_if?"
	[[ "$condition" ]] || condition=error
	[[ "$message" ]] || message="no message"
	local msg
	if [[ $ecode == 0 ]]		# if previous command had no error
	then
		msg="Success:"
	else
		msg="Error: exit code $ecode:"
	fi
	if [[ "$condition" == any ]]
	then
		echo "$msg" "$message"
		return
	elif [[ $ecode == 0 ]]		# else only print errors, so if none
	then
		return			# then return
	fi
	# If we get here, then $ecode detected an error.
	case "$condition" in
	error)
		echo "$msg" "$message"
		;;
	stderr)
		echo "$msg" "$message" 1>&2
		;;
	*)
		echo "$msg" "out_if: unrecognized condition ($condition):" \				"$message" 1>&2
		;;
	esac
	return
}

instance_args=()		# global instance descriptions


# runs mongo shell operation and parses outputs
# call with: operation, cstring, [ returnvar ]
#  cstring can be a hostport or a connection string
# returns output via ${returnvar}_out global variable (default "MSH")
# also returns broken-out values in {returnvar}_* if returnvar present

function mongosh {

	local op=$1
	local cstring=$2
	local r=${3:-}			# return variable name
	local out json retstatus error=

	[[ "$verbose" ]] && {
		echo "mongosh: doing JSON.stringify($op) on $cstring" 1>&2
	}

	# two virtues of JSON.stringify: (a) it makes the JSON parsable to
	# the jq tool and (b) puts it all on one line, making it possible to
	# filter out connection messages and diagnostics.

	out=$( mongo --eval "JSON.stringify($op)" $cstring ) || {
		retstatus=$?
		echo "mongosh: error invoking JSON.stringify($op) on $cstring" \
			1>&2
		if [[ "$verbose" ]]
		then
			sed 's/^/  /' <<< "$out" 1>&2
		else
			# next line is supposed to pull out error messages from
			# sometimes copious warnings and informational messages
			grep '^....-..-..T..:..:......-.... E ' <<< "$out" 1>&2
			#      2018-02-20T06:55:42.255-0800 I NETWORK
			# yyy kludgy check for error condition
		fi
		return $retstatus
	}

	local emsg=
	grep --quiet '^{.*"ok":1' <<< "$out" ||		# or error occurred
		error=1
	emsg=$( grep '"error:' <<< "$out" ) &&
		error=1

	[[ "$error" && ! "$r" ]] &&	# if error and user declined messages
		r=MSH			#   they're going to get them anyway
	[[ ! "$r" ]] &&	{		# set on error or if user requests
		MSH_out="$out"		# set this global return
		return 0
	}
	# If we get here, we take time to break out values into shell vars.

	eval "${r}_out"'="$out"'
	eval "${r}_mongomsgs"'=$(egrep -v "^{|^\d\d\d\d-\d\d-\d\d" <<< "$out")'
	eval "${r}_mongologs"'=$(grep "^\d\d\d\d-\d\d-\d\d" <<< "$out")'

	json=$( grep "^{" <<< "$out" )
	eval "${r}_json"'="$json"'
	eval $( jq -r "
		@sh \"${r}_ok=\(.ok)\",
		@sh \"${r}_info=\(.info)\",
		@sh \"${r}_info2=\(.info2)\",
		@sh \"${r}_errmsg=\(.errmsg)\",
		@sh \"${r}_primary=\(.primary)\",
		@sh \"${r}_passives=( \(.passives) )\",
		@sh \"${r}_hosts=( \(.hosts) )\"
	" <<< "$json" )

	# want all members, including non-voting members
	local passives
	eval passives=\"\$${r}_passives\"
	[[ "$passives" == 'null' ]] ||
		eval "${r}_hosts+=( \"\${${r}_passives[@]}\" )"

	[[ "$error" ]] && {
		local ok errmsg
		eval ok=\"\$${r}_ok\" errmsg=\"\$${r}_errmsg\"
		echo "mongosh: error return status from $op: $ok"
		[[ "$errmsg" != null ]] &&	# from json, test "null"
			echo " - $errmsg"
		[[ "$emsg" ]] &&		# from grep, test ""
			echo " - $emsg"
		return 1
	}
	return 0
}

# initialize replica set
# call with: hostport

function rs_init {

	local hostport=$1		# set -u aborts if not set
	local retstatus=0		# optimist
	[[ "$verbose" ]] && {
		echo "+ doing rs.initiate() via $hostport" 1>&2
		#echo "+ doing rs.initiate() via $cstring" 1>&2
	}

	#out=$( mongo --port $port --eval "rs.initiate()" )
	# NB: need to convert hostport into connection string because for some
	# reason mongo shell won't connect to host:port UNLESS host is a dotted
	# quad, eg, host as DNS name WON'T work.

	# NB: looks like we cannot use a connection string unless the replica
	#     set has been initiated
	mongosh "rs.initiate()" "$hostport" m ||
		return 1		# since m_* vars will be undefined
	[[ "$verbose" ]] && {
		echo "+ $m_out" 1>&2
	}
	return 0
}

## puts hostport of replica set primary on stdout and messages on stderr
## call with: rs_conn
##	{'_id' : $j, 'host' : '$instance', 'stateStr' : 'PRIMARY'},"
#
## yyy no one calls this
#function rs_primary {
#
#	local rs_conn=$1
#	local rsnam=${rs_conn##*=}	# YYY must end in replicaSet=foo!!
#	#local hostport=$2		# set -u aborts if not set
#	#local port=${hostport##*:}	# delete up to last ':'
#	local retstatus=0		# optimist
#	[[ "$verbose" ]] &&
#		echo "+ doing rs_primary via $rs_conn for rset $rsnam" 1>&2
#		#echo "doing db.isMaster() via port $port" 1>&2
#	#local op="JSON.stringify(db.isMaster('$hostport'))"
#	local op="JSON.stringify(db.isMaster())"
#	local out
#	#out=$( mongo --quiet --port $port --eval "$op" ) || 
#	out=$( mongo --quiet --eval "$op" $rs_conn | grep '^{' ) || {
#		#	| perl -ne '/^\d{4}-\d\d-\d\dT\d\d/ or print' ) || 
#		echo "error: $op call failed on $rs_conn" 1>&2
#		#echo "error: $op call failed on port $port" 1>&2
#		sed 's/^/  /' <<< "$out" 1>&2
#		#echo "$out" 1>&2
#		return 1
#	}
#	[[ "$verbose" ]] && {
#		sed 's/^/  /' <<< "$out" 1>&2
#	}
#	# JSON output looks like
#	#        "setName" : "rst",
#	#        "setVersion" : 1,
#	#        "ismaster" : true,
#	#        "primary" : "jak-macbook.local:47018",
#	#        "secondary" : false,
#	# -r does "raw output", removing quotes around strings
#	fields=( $( jq -r '.setName, .primary' <<< "$out" ) )
#	local snam=${fields[0]:-}
#	local primary=${fields[1]:-}
#	[[ "$snam" == "$rsnam" ]] || {
#		#echo -n "error: requested hostport ($hostport) is not a" 
#		echo -n "error: requested hostport (hostport) is not a" \
#			"member of replica set \"$rsnam\"" 1>&2
#			[[ "$snam" ]] &&
#				 echo -n ", but is a member of \"$snam\"" 1>&2
#		echo 1>&2	# end the line
#		return 1	# no output
#	}
#	[[ "$primary" ]] || {
#		echo "no primary" 1>&2
#		#echo "fields is ${fields[@]}" 1>&2
#		return 1	# no output
#	}
#	echo "$primary"		# main return value
#	[[ "$verbose" ]] &&
#		echo "+ primary is $primary" 1>&2
#	return 0		# return status probably ignored
#}

# on stdout puts "N replicas: " followed by a ','-separated list of replicas,
# with primary indicated by a *

function rs_ismaster {			# call with: cstring

	use_mg

	[[ "$mg_local_daemons" ]] || {
		echo "no daemon list found; check MG_LOCAL_DAEMONS" \
			"setting in $configfile" 1>&2
		return 1
	}
	[[ ! "$mg_cstring" ]] && {
		echo "rs_ismaster: connection string not initialized" 1>&2
		return 1
	}
	mongosh "db.isMaster()" $mg_cstring m
	if [[ $? == 0 ]]
	then
		echo "${#m_hosts[@]} replicas:" $( sed -e 's| |,|g' \
			-e "s|\(${m_primary:-null}\)|*\1|" <<< "${m_hosts[@]}" )
	else		# yyy not even checking $m_ok
		echo "error in mongo db.isMaster"
	fi
	return 0
}

# list replica set
# first arg should be either 'list' (return list of instances)
# or 'count' (return just the number of instances in the set)

function rs_list {	# call with: cmd, cstring

	use_mg
	local cmd=${1:-list}
	local out cstring=${2:-$mg_cstring}
	local setsize=1		# something non-zero, used to proceed on error
	out=$( rs_ismaster $cstring ) || {
		echo "failed: rs_ismaster $cstring" 1>&2
		return 1
	}
	if [[ "$cmd" != list ]]		# 'count' means return total number
	then
		setsize=$( sed -n 's/^\([0-9][0-9]*\) .*/\1/p' <<< "$out" )
		echo "$setsize"
		[[ "$setsize" ]] ||
			return 1
	else				# 'list' command
		echo "$out"
	fi
	return 0
}

# add replica instance

function rs_add_instance { # call with: cstring hostport

	# rs.add({host: "mongodbd4.example.net:27017", priority: 0, votes: 0})
	# "Replica set configuration contains 8 voting members,
	# but must be at least 1 and no more than 7"
	# non-voting members must have priority 0

	local cstring=$1
	local hostport=$2		# needs to be both host and port
	#local port=${hostport##*:}	# delete up to last ':'
	local retstatus=0		# optimist

	local out setsize
	setsize=$( rs_list count $mg_cstring ) || {
		echo "error: cannot determine set size" 1>&2
		setsize=0
	}

	[[ "$setsize" -ge $max_setsize ]] && {
		echo "error: replica set already has $setsize members" \
			"maximum size is $max_setsize" 1>&2
		return 1
	}
	local non_voting=
	[[ "$setsize" -ge $max_voting_members ]] && {
		echo "warning: replica set already has $setsize members;" \
			"new members will be non-voting" 1>&2
		non_voting=", priority: 0, votes: 0"
	}
	mongosh "rs.add( { host: \"$hostport\" $non_voting } )" $cstring m
	retstatus=$?
	[[ $retstatus -ne 0 ]] && {
		echo "rs.add error: $m_errmsg" 1>&2
	}
	[[ "$verbose" && "${m_out:-}" ]] &&
		sed 's/^/  /' <<< "$m_out" 1>&2
	return $retstatus
}

function del_proc_base {

	use_mg any
	rm -f "$mg_proc_base"local:*
	return 0
}

## sets mg_rs_conn and mg_rs_high_port, given a port, and optionally a setname
## call with port and optional setname; if no setname assume we are to figure it
## out from given port (as if called by rs_del)
## yyy allow 'any' or '-' (default)? to list any rset_* files
##     allow '-' and rsetname? to report on that set?
##     this would support "./mg rs_status" what about "./mg status"?
#
#function use_rs_conn {		# call with: hostport [ setname ]
#
#	use_mg any
#	local hostport=$1
#	local port=${hostport##*:}
#	local setname=${2:-}
#	local pfile rfile last x
#	if [[ ! "$setname" ]]	# must figure out $setname based on port
#	then
#		pfile="$mg_proc_base""local:$port"
#		[[ -f $pfile ]] || {			# first try
#			pfile="$mg_proc_base_alt""local:$port"
#			[[ -f $pfile ]] ||		# second try
#				pfile=/dev/null
#		}
#		setname=$( perl -ne 'm/--replSet\s*(\S*)/ and print "$1"' \
#			< $pfile )
#	fi
#	mg_rs_conn=				# initialize for return
#	mg_rs_high_port=			# initialize for return
#
#	rfile=$mg_rset_base$setname		# NB: setname fails quietly
#	last=$( tail -1 $rfile 2> /dev/null )
#	[[ ! "$last" ]] && {
#		echo ""		# no replica set yet, so no connection string
#		return 0
#	}
#	# Example last line:
#	# Tue Feb 20 07:40:10 PST 2018 added jak-macbook.local:47023 - mongodb://jak-macbook.local:47023,jak-macbook.local:47022,jak-macbook.local:47021,jak-macbook.local:47020,jak-macbook.local:47019,jak-macbook.local:47018,jak-macbook.local:47017/?socketTimeoutMS=30000&readPreference=primaryPreferred&replicaSet=test
#
#	x=$( perl -ne '
#		chomp;
#		s,.*mongodb://,mongodb://, and print;	# print conn string
#		s,/\?.*,,;				# drop query string
#		print ":";				# separator
#		@x = sort {$b <=> $a} m/:(\d+)/g;	# descending order
#		scalar(@x) and print "$x[0]";		# print highest
#		' <<< "$last" )
#	mg_rs_conn=${x%:*}				# delete after last ':'
#	mg_rs_high_port=${x##*:}			# delete up to last ':'
#	return 0
#}

# start instance, add to replica set, and output new connection string
# creates and adds to a file as side-effect to track replica set states

function rs_add {	# call with: hostport [ start_msg ]

	use_mg
	local hostport=$1		# might be just a port number
	local start_msg=${2:-}
	local port=${hostport##*:}
	local host=$mg_host
	hostport="$mg_host:$port"	# make sure it's both host and port
	local out setsize
	local retstatus=0		# optimistic
	local snam=$mg_setname

	echo "starting up daemon and adding $hostport" 1>&2
	start $port $snam || {
		echo "rs_add: error in \"start $port $snam\"" 1>&2
		return 1
	}
	[[ "$verbose" ]] && echo "daemon started on $port" 1>&2

	# Connect mongo shell to replica set (NB: no dbname
	# in this particular string):
	# mongo mongodb://10.10.10.15:27001,10.10.10.16:27002,
	#  10.10.10.17:27000/?replicaSet=replicaSet1

	#mongosh "rs.add( { host: \"$hostport\" $non_voting } )" $cstring m
	#out=$( mongo --eval "rs.status()" $mg_cstring 2>&1 )

	[[ "$start_msg" ]] &&
		echo "$start_msg" 1>&2

	out=$( mongosh "rs.status()" $mg_cstring m 2>&1 )
	if [[ "$?" -ne 0 ]]
	then
		[[ "$verbose" ]] && {
			echo "rs.status() NOT OK -- output: $out" 1>&2
			echo "will call rs_init" 1>&2
		}
		#echo "- rs_add: checking if replica set \"$mg_setname\" has" \
		#	"been initialized" 1>&2
		local when="is now"
		# failure might mean we're not initialized yet
		out=$( rs_init $hostport ) || {
			if [[ "$out" =~ already\ initialized ]]
			then
				when="was already"
			else
				echo "rs_init error: $out" 1>&2
				return 1
			fi
		}
		echo "- set $when initialized" 1>&2
		mg_initialized=1
		[[ "$verbose" ]] && {
			local out
			echo "Status after init: $out" 1>&2
			out=$( mongo --eval "rs.status()" $mg_cstring ) || {
				echo "rs_status failed on $mg_cstring" 1>&2
			}
			echo "$out" 1>&2
		}
	else
		# NB: rs.initiate on server S adds S as first replica,
		# which is why we need if ... then ... else.
		# The mongodb folks should document this dammit.
		[[ "$verbose" ]] && echo "rs.status() OK" 1>&2
		out=$( rs_add_instance $mg_cstring $hostport ) || {
			#same host field
			echo "rs_add_instance failed on $hostport: $out" 1>&2
			return 1
		}
	fi

# xxx how is this file getting initialized now
	# add to file to track replica set states
	echo "$(date) added $mg_hostport - $mg_cstring" \
		>> $mg_rset_base$snam
	echo "$(date) added $mg_hostport - $mg_cstring" \
		>> $mg_rs_history

	return 0
}

# start instance, add to replica set, and output new connection string

# creates and adds to a file as side-effect to track replica set states

# must shutdown instance before you do rs.remove(hostport)
function rs_del_instance {	# call with: hostport

	local hostport=$1		# set -u aborts if not set
	local retstatus=0		# optimist
	local out

	out=$( mongosh "rs.remove('$hostport')" $mg_cstring m ) || {
		sed 's/^/  /' <<< "$m_out" 1>&2
	}
	retstatus=$?
	[[ "$verbose" ]] &&
		sed 's/^/  /' <<< "$m_out" 1>&2
	return $retstatus
}

# shutdown instance and remove from replica set

# adds to a file as side-effect to track replica set states

function rs_del {	# call with: hostport

	use_mg
	local hostport=$1		# might be just a port number
	local port=${hostport##*:}
	local host=$mg_host
	hostport="$mg_host:$port"	# make sure it's both host and port

	local out setsize stop_op=stop
	local retstatus=0		# optimistic
	local snam=$mg_setname

	setsize=$( rs_list count $mg_cstring ) || {
		echo "error: cannot determine set size" 1>&2
		setsize=0
		#return 1
	}
#	[[ "$setsize" -lt 3 ]] && {
#		echo "- fewer than 3 instances (no primary) -- doing" \
#			"hard-stop" 1>&2
#		stop_op=hard-stop
#	}
	# NB: must shutdown instance before removing from replica set
	stop $stop_op $port || {
		stop hard-stop $port || {
			echo " - 'hard-stop' failed" 1>&2
			retstatus=1
		}
	}
	local cmd
	if [[ "$setsize" -gt 2 ]]	# ok, there should be a primary
	then				# that can perform the rs.remove
		cmd="rs_del_instance $mg_hostport"
		[[ "$verbose" ]] &&
			echo  "+ doing $cmd" 1>&2
		$cmd ||
			echo "error: $cmd failed" 1>&2
	fi
	# add record to file to track replica set states

	echo "$(date) deleted $mg_hostport - $mg_cstring" >> $mg_rset_base$snam
	echo "$(date) deleted $mg_hostport - $mg_cstring" >> $mg_rs_history
	return $retstatus
}

# Called via "trap" on receipt of signal for the purpose of doing cleanup
# Args are only passed at trap definition time, so the current state of a
# replica set connection string has to reside in a global, mg_cstring.
# call without args.

function rs_teardown {
	echo "SIGINT caught: now disabling SIGINT and killing test servers" 1>&2
	trap "" SIGINT
	rs_stop "$mg_local_daemons"
}

## xxx
#repSetOpts=				# replica set connection string options
#repSetOpts+="socketTimeoutMS=30000&"	# wait up to 30 secs for reply
## yyy does readpref work in the connection string?
#readpref=primaryPreferred	# set to permit reading from secondaries at all
#repSetOpts+="readPreference=$readpref&"	# replica to read from
#
## args either: init setname hostport_list [ dbname ]
##      or:     add|del connstr hostport
##      or:     hostports connstr
#
#function rs_connect_str {
#
#	local hostport cs setname dbname rs_conn
#	local cmd=${1:-}
#	case "$cmd" in
#	add|del)
#		cs=$2			# connection string
#		hostport=$3		# to add or delete
#		if [[ $cmd == add ]]; then
#			cs=$( perl -pe "s|//|//$hostport,|" <<< "$cs" )
#			# add hostport to list in mongodb://...,.../ URL
#		else
#			cs=$( perl -pe "s|$hostport,?||; s|,/|/|" <<< "$cs" )
#			# drop hostport and if it was last, drop trailing ,
#		fi
#		echo "$cs"
#		return 0
#		;;
#	init)
#		setname=$2
#		hostport=$3	# could be a comma-separated list of hostports,
#			# eg, extracted from existing rs_conn with "hostports"
#			# when you're re-init'ing in order to add a database
#		dbname=${4:-}
#		# NB: options MUST precede replicaSet=foo, which must terminate
#		# the string.
#		rs_conn="mongodb://$hostport/$dbname?$mg_repSetOpts"
#		rs_conn+="replicaSet=$setname"
#		echo "$rs_conn"
#		return 0
#		;;
#	hostports)
#		cs=$2			# existing connection string
#		echo $( sed 's|mongodb://*\([^/]*\)/.*|\1|' <<< "$cs" )
#		return 0
#		;;
#	*)
#		echo "error: rs_connect_str usage: command hostport ..." 1>&2
#		return 1
#		;;
#	esac
#}

# Call with 0 to reinitialize tests
function repltest {

	local n i even hostport starter_port cmd
	mg_mode=$mg_test_mode		# enforce --test before calling use_mg
	use_mg

	n=${1:-$def_setsize}		# proposed set size
	[[ "$n" == "0" ]] && {
		del_proc_base		# reinitialize replica test and return
		return
	}
	[[ ! "$n" || "$n" == '-' ]] &&		# default number of replicas
		n=$def_setsize

	# set $n to even if $even == $n; $even == 0 if $n isn't a number
	(( even=( "$n" / 2 * 2 ) ))		# or $n == 1
	if [[ $even -eq 0 || $n -eq $even || $n -lt 0 || $n -ge $max_setsize ]]
	then
		[[ $n -ne 1 ]] && {
			echo "error: replica count ($n) should be an odd" \
				"integer < $max_setsize and > 1" 1>&2
			return 1
		}
		# if we get here, $n -eq 1, which we allow under caution
		echo "replica count 1 (no replicas) -- baseline testing" 1>&2
	fi
	# echo {1..10}

	echo beginning test of $n-server replica set

	starter_port=$mg_port		# base port number where daemon runs
	local port out dlist=''

	# This loop defines daemon list $dlist.

	i=0
	while [[ $i -lt $n ]]		# generate instances
	do
		port=$(( $starter_port + $i ))
		hostport="$mg_host:$port"	# yyy don't use host yet
		dlist+="$hostport"
		(( i++ ))
		[[ $i -lt $n ]] &&
			dlist+=","
	done
	mg_dlist="$dlist"

	rs_start "$dlist" || {		# arg sets mg_local_daemons to $dlist
		echo "rs_start: problem starting replica set from $dlist" 1>&2
		return 1
	}

	trap rs_teardown SIGINT		# trigger cleanup using global

	rs_test

	rs_stop $mg_dlist
	#xteardown_repltest $mg_dlist
}

# test replica set instances
# usage: rs_test  local|all  N|new [F]
# where
#  all		means test all instances in cstring
#  local	means test only local instances
#  N		is an integer number of previous test records to fetch
#  new [F]	means add new record, sized by factor F (integer)

function rs_test {

	use_mg

	local scope=${1:-local}
	local which=${2:-new}
	local factor=${3:-1}			# default factor=1

echo "xxx scope: $scope, which: $which, factor: $factor"
	## yyy need to pause really?
	#local s=2	# number of seconds to pause while replicas wake up
	#echo Sleep $s seconds to let servers stand up...
	#sleep $s

#	# We could have added the database name to the connection string early
#	# on, but here we can test re-initializing that string after extracting
#	# the host list we've built up and re-inserting it in the new string.

	local hostport_list collection db_coll_name
	# extraction step
	hostport_list="$mg_local_daemons"
	collection=testcoll
	db_coll_name="$mg_dbname.$collection"

	# Now add data to the replica set.

	local perl_add_data
	# generate data ($fate) containing date to get different data each run
	local fate="unique data $( date )"
	read -r -d '' perl_add_data << 'EOT'

	# start embedded Perl program
	# call with: $mg_cstring, $dbtest.$collection, test_data_string
	use 5.010;
	use strict;
	use MongoDB;
	use Try::Tiny;		# for exceptions
	use Safe::Isa;		# provides $_isa
	# use Try::Tiny::Retry	# yyy (one day) for automatic retries

	my $connection_string = $ARGV[0] || '';
	my $db_coll_name = $ARGV[1] || '';	# db_name.collection_name
	my $data_string = $ARGV[2] || '';
	my $factor = $ARGV[3] || 1;
	$factor =~ /^\d+$/ and $factor > 1 and
		$data_string x= $factor;
	my $client;
	try {
		$client = MongoDB::MongoClient->new(
			host => $connection_string,	# mongodb://...
		);
	}
	catch {
		print STDERR "error: $_\n";
	};
	# xxx add these attributes when support is ready
		#ssl => {		# XXX enable SSL!!
		#	SSL_ca_file	=> "xxx",
		#	SSL_cert_file	=> "xxx",
		#}
	$client or
		print(STDERR "error: couldn't connect to $connection_string"),
		exit 1;
	my ($col, $docs);
	my $rs_test = 'rs_test';
	try {
		#$col->delete_many({ name => "JDoe" });
		#$col->insert({ name => "JDoe", fate => "$data_string" });

		$col = $client->ns($db_coll_name);
		#$col->find_one({ _id => $rs_test."_counter" }, { n => 1 });
		$col->save({ _id => $rs_test, fate => "$data_string" });
			# 'save', given an _id field, replaces or inserts

		$docs = $col->find({ _id => $rs_test });
	}
	catch {
		print STDERR "error: $_\n";
		exit 1;
	};
	! $docs and
		print(STDERR "error: add to replica set failed\n"),
		exit 1;
	while (my $doc = $docs->next) {
		print "$doc->{'fate'}\n";	# save for testing replicas
	}
	# end embedded Perl program
EOT

	# Now call the script, just saved in $perl_add_data, pass in values
	# via command line arguments.

	out=$( perl -we "$perl_add_data" "$mg_cstring" "$db_coll_name" \
		"$fate" "$factor" )
	local retstatus=$?
	local doclen=${#fate}	# number of characters in the string $fate
	[[ "$out" != "$fate" ]] && {
		echo "Warning: doc stored (len $doclen) not read from" \
			"replica (len ${#out})"
		echo "out: $out"
	}

	local stored_doc=$fate
	if [[ $retstatus -eq 0 ]]
	then
		echo "test data (length $doclen) = |$stored_doc|"
		#sed 's/^/    /' <<< "$stored_doc"	# indent data
	else
		echo "error: could not add test document via $mg_cstring" 1>&2
		[[ "$n" -lt 3 ]] && {
			echo "ok - replica sets with < 3 members are readonly" \
				"since they don't have a primary" 1>&2
		}
		echo "$out" 1>&2
	fi

	#echo Sleep 5 to let data propagate
	#sleep 5

	# now prove that the data was written to each instance

	local instances
	instances=( $mg_proc_base* )

	for i in ${instances[@]}		# for each instance i
	do
		hostport=${i##*_}		# delete to last '_'
		port=${hostport##*:}		# delete to last ':'
		# yuck: rewrite hostname to particular form that comes out of
# xxx fails on ucop desktop network?
		# hostname -f, depending on what network we're connected to
		[[ "$hostport" =~ ^local: ]] &&
			hostport="$mg_host:$port"

		# yyy? database name carried in $mg_cstring
		local tries=1 maxtries=5 pause=1

		while [[ $tries -le $maxtries ]]
		do
			# rs.slaveOk() permits reading from secondaries
			out=$( mongo --quiet --eval \
					"rs.slaveOk(); db.$collection.find()" \
					"$hostport/$mg_dbname" ) || {
				echo "problem fetching test docs ($hostport)"
				echo "$out"
				break
			}
			fgrep -sq "$stored_doc" <<< "$out"
			if [[ $? -eq 0 ]]
			then
				echo \- instance $hostport has data copy \
					after $tries tries
				break
			else
				echo \- instance $hostport does not have data \
					copy after $tries tries
				[[ "$verbose" ]] &&
					echo "from find: $out"
			fi
			(( tries++ ))
			sleep $pause
		done
	done
}

# Single port argument required.
# quietly tests if mongod is running, returns via process status
function is_mongo_up () {
	local port=$1
	nohup mongo --port $port < /dev/null > /dev/null 2>&1
}

# start one server and create procfile

function start {	# call with: port setname

	use_mg "${1:-}" "${2:-}" ||	# define mg_flags, mg_procfile, etc
		return 1
	# yyy ignoring host part for now
	#local hostport=${1:-$rs_live_first_port}
	#local port=${hostport##*:}
	#local setname=${2:-$rs_live_setname}
	#local flags=( $( echo \$rs_config_$setname ) )
	#local out procfile
	[[ "$verbose" ]] &&
		echo "is_mongo_up $mg_port" 1>&2
	is_mongo_up $mg_port
	if [[ $? -eq 0 ]]
	then
		echo "mongod on port $mg_port appears to be up already" 1>&2
		return 0
	fi
	#use_rs $port $setname ||	# define mongo_flags and mongo_procfile
	#	return 1
	[[ "$verbose" ]] &&
		echo "starting mongod, flags: ${mg_flags[*]}" 1>&2
	# start in background
	out=$( mongod ${mg_flags[*]} )
	if [[ $? -ne 0 ]]
	then
		echo "mongod start NOT OK" 1>&2
		echo "$out" 1>&2
		return 1
	fi
	[[ "$verbose" ]] && echo "$out" 1>&2
	echo "mongod OK (port $mg_port) -- started" 1>&2

	# Finally create a file we can use later for tracking and teardown.
	echo "startup $mg_port $mg_setname: ${mg_flags[*]}" > $mg_procfile
	return 0
}

# xxx add 1>&2 to most of the echo commands??

function restart {			# call with: [ port ]

	local out   cmd=$1
	shift
	use_mg "${1:-}" ||		# define mg_flags, mg_procfile, etc
		return 1
	#local port=${1:-$rs_live_first_port}
	#local setname=${2:-$rs_live_setname}
	is_mongo_up $mg_port
	if [[ $? -ne 0 ]]
	then
		echo "mongod (port $mg_port) appears to be down" 1>&2
	else
		[[ "$verbose" ]] &&
			echo "shutting down server on port $mg_port" 1>&2
		# yyy change echo pipe to --eval opt
		out=$( echo -e "use admin \n db.shutdownServer()" |
			mongo --port $mg_port )
		if [[ $? -eq 0 ]]
		then
			echo "mongod OK (port $mg_port) -- stopped" 1>&2
		else
			echo "mongod shutdown NOT OK" 1>&2
			echo "$out" 1>&2
		fi
	fi
	sleep 1		# pause seems to help here under Linux
	#use_rs $port $setname
	[[ "$verbose" ]] &&
		echo "restarting mongod, flags: ${mg_flags[*]}" 1>&2
	mongod ${mg_flags[*]} > /dev/null	# start in background
	if [[ $? -ne 0 ]]
	then
		echo "mongod $cmd NOT OK" 1>&2
		return 1
	fi
	echo "mongod OK (port $mg_port) -- restarted" 1>&2
	[[ "$verbose" ]] && echo "$out" 1>&2
	[[ -f $mg_procfile ]] &&	# if procfile is there, leave it
		return 0
	# else if it's gone, recreate it
	echo "restartup $mg_port $mg_setname: ${mg_flags[*]}" > $mg_procfile
	return 0
}

# stops server and removes procfile

function stop {				# call with: cmd [ port ]

	local cmd=$1
	shift
	use_mg "${1:-}" ||		# define mg_flags, mg_procfile, etc
		return 1
	#local hostport=${1:-$rs_live_first_port}
	#local port=${hostport##*:}

	local out   force=    stopped=stopped
	[[ "$cmd" == hard-stop ]] && {
		force="{ 'force' : 'true' }"
		stopped=hard-stopped
	}
	#use_rs $port all ||		# define mongo_proc_base
	#	return 1
	#local procfile=$mongo_proc_base$port
	is_mongo_up $mg_port
	if [[ $? -ne 0 ]]
	then
		echo "mongod (port $mg_port) appears to be down already" 1>&2
		rm $mg_procfile		# yyy leave around just in case?
		return 0
	fi
	[[ "$verbose" ]] &&
		echo "shutting down server on port $mg_port" 1>&2
	out=$( mongo --port $mg_port \
		--eval "db.shutdownServer($force)" admin )
	if [[ $? -ne 0 ]]
	then
		echo "problem shutting down mongod (port $mg_port)"
		echo "$out"
		return 1
	fi
	echo "mongod OK (port $mg_port) -- $stopped" 1>&2
	[[ "$verbose" ]] && echo "$out" 1>&2
	rm -f $mg_procfile $mg_procfile_alt
	return 0
}


function start1 {	# call with: port dbpath dblog
# xxx no one calls this

	local out port=$1
	shift
	is_mongo_up $port
	if [[ $? -eq 0 ]]
	then
		echo "mongod on port $port appears to be up already"
		return
	fi
	[[ "$verbose" ]] &&
		echo "starting mongod, flags: $*"
	# start in background
	out=$( mongod $* )
	if [[ $? -eq 0 ]]
	then
		echo "mongod OK (port $port) -- started"
		[[ "$verbose" ]] && echo "$out"
		return 0
	else
		echo "mongod start1 NOT OK"
		echo "$out"
		return 1
	fi
}

function status {				# call with: [ port ]

	use_mg "${1:-}" ||		# define mg_flags, mg_procfile, etc
		return 1
	#local port=${1:-$rs_live_first_port}
	local status pidcount
	pidcount=`netstat -an | grep -c "mongodb.*$mg_port"`
	is_mongo_up $mg_port
	status=$?
	if [[ $status -eq 0 ]]
	then
		echo "OK -- running (mongod, port $mg_port)"
		[[ "$pidcount" -eq 0 ]] &&
			echo "WARNING: but the pidcount is $pidcount?"
		[[ "$verbose" ]] && {
			echo "=== Mongo Configuration ==="
			mongo --port $mg_port --eval "db.serverStatus()"
			echo "=== Mongo Replica Set Configuration ==="
			mongo --port $mg_port --eval "rs.conf()"
			echo "=== Mongo Replica Set Status ==="
			mongo --port $mg_port --eval "rs.status()"
			echo "=== Mongod startup file ==="
			cat $mg_procfile
		}
			
	else
		echo "NOT running (mongod, port $mg_port)"
		[[ "$pidcount" -ne 0 ]] &&
			echo "WARNING: but the pidcount is $pidcount?"
	fi
	return $status
}

# Set global $mg_cstring and call rs_add to start each daemon and add it to
# a replica set. Log progess. Daemons are given by the first argument if
# present (eg, test mode), or by $mg_local_daemons. Returns 0 if all daemons
# started and final replica set status check is ok, else returns non-zero.

function rs_start {

	local hostport
	local i=0 total=0
	use_mg
	# yyy call the above once per process?

	[[ "$mg_local_daemons" ]] || {
		echo "no daemon list found; check MG_LOCAL_DAEMONS" \
			"setting in $configfile" 1>&2
		return 1
	}
	echo "+==== ($mg_mode) $(date)" \
		"starting replica set via $mg_local_daemons" >> $repsetlog

	trap rs_teardown SIGINT		# trigger cleanup using global

	start_msg="- initializing set \"$mg_setname\"; this may take a while"
	for hostport in $( sed 's/,/ /g' <<< $mg_local_daemons )
	do
		# mg_rs_high_port+1 might potentially one day be used to pick
		#       the next localhost instance
		#port=$(( $starter_port + $i ))
		#hostport="$mg_host:$port"	# yyy don't use host yet

		# Docs: "Make sure the new member’s data directory does not
		# contain data. The new member will copy the data from an
		# existing member."

		(( total++ ))
		use_mg $hostport $mg_setname	# set daemon-specific globals

		if [[ "$mg_mode" == "$mg_test_mode" ]]	# don't remove any data
		then					# dirs unless test mode
			[[ "$mg_dbdir" =~ $mg_test_root/ ]] || {
				# NB: need final '/' for preceding test
				echo "abort: won't remove $mg_dbdir because" \
					"it doesn't descend from test root:" \
					"$mg_test_root" 1>&2
				return 1
			}
			echo "removing \"$mg_test_mode\" data directory" \
				"$mg_dbdir" 1>&2
			rm -fr $mg_dbdir
		fi

		out=$( rs_add "$hostport" "$start_msg") || {
			echo "rs_add: error adding \"$hostport\"" 1>&2
			continue
		}
		start_msg=	# one-time message meant only for first rs_add
		#xxx echo "rs_add ok: $out" 1>&2
		(( i++ ))
	done

	trap - SIGINT		# turn off set cleanup on SIGINT

	[[ "$total" -lt 1 ]] && {
		echo "no servers found in $mg_local_daemons" 1>&2
		return 1
	}
	[[ "$i" -lt 1 ]] && {
		echo "no servers started" 1>&2
		echo "+==== ($mg_mode) no servers started" >> $repsetlog
		return 1
	}

	# yyy old way? (no mongosh)
	out=$( mongo --eval "rs.status()" $mg_cstring ) || {
		[[ "$verbose" ]] &&
			echo "bad rs.status: $out" 1>&2
		echo "+==== ($mg_mode) bad replica set status" >> $repsetlog
		return 1
	}
	echo "+==== ($mg_mode) replica set status ok" >> $repsetlog
	echo "replica set complete - connection string is" 1>&2
	echo "  $mg_cstring" 1>&2
	echo "+==== ($mg_mode) connection string $mg_cstring" >> $repsetlog
	[[ "$verbose" ]] && {
		echo "=== Replica set status after adding replicas ==="
		echo "$out"
	}
	return 0
}

# xxxxxx why does replica set size 1 suddenly now allow writes???
# From: https://serverfault.com/questions/462780/does-a-mongodb-replica-set-require-at-least-2-or-3-members
# "You can actually run a single member "set" if you want.
# 3 members (or a higher odd number) is really best, though. Replica sets go
# read only if a majority of the set isn't available, so if you lose a member
# in a two-member set the remaining member becomes read only."

# Set global $mg_cstring and use rs_del to remove each daemon from a replica
# set and stop it. Logs progess. Daemons are given by the first argument if
# present, or by $mg_local_daemons. Returns 0 if all daemons stopped and
# final replica stopped. else returns non-zero.

function rs_stop {

	local out hostport port instances
	use_mg

	[[ "$mg_local_daemons" ]] || {
		echo "no daemon list found; check MG_LOCAL_DAEMONS" \
			"setting in $configfile" 1>&2
		return 1
	}

	echo "+==== ($mg_mode) $( date )" \
		"stopping replica set via $mg_local_daemons" >> $repsetlog
	echo "+==== ($mg_mode) connection string $mg_cstring" >> $repsetlog

	# Reverse the daemon list found in $mg_local_daemons as the basis for the
	# order to shut them down. This is efficient for testing since the
	# first server we started is likely to still be primary, and making
	# it (likely to be) the last server shut down avoids the time it
	# takes time for mongo to elect a new primary once at the very end.

	instances=( $( perl -ne '
		print join "\n", reverse 	# now a comma-separated list
		split /,/;' <<< "$mg_local_daemons" ) )

	local total=${#instances[@]}		# total instances remaining
	local i=0

	echo "tearing down $total-server replica set"
	for hp in ${instances[@]}		# for each instance hp
	do
		hostport=${hp##*_}		# delete to last '_'
		port=${hostport##*:}		# delete to last ':'
		[[ "$hostport" =~ ^local: ]] &&
			hostport="$mg_host:$port"
		echo "shutting down and ejecting $hostport"
		out=$( rs_del $hostport ) || {
			echo "error: rs_del $mg_cstring $hostport failed" 1>&2
			echo "out: $out" 1>&2
			continue
		}
		(( i++ ))
	done

	[[ "$total" -lt 1 ]] && {
		echo "no servers found in $mg_local_daemons " 1>&2
		return 1
	}
	[[ "$i" -lt "$total" ]] && {
		echo "only $i (of $total) servers stopped" 1>&2
		echo "+==== ($mg_mode) only $i (of $total) servers stopped" \
			>> $repsetlog
		return 1
	}

#	# yyy old way? (no mongosh)
#	out=$( mongo --eval "rs.status()" $mg_cstring ) || {
#		[[ "$verbose" ]] &&
#			echo "bad rs.status: $out" 1>&2
#		echo "+==== ($mg_mode) bad replica set status" >> $repsetlog
#		return 1
#	}
	echo "+==== ($mg_mode) replica set stopped" >> $repsetlog
	return 0
}

function rs_status {

	local out hostport port instances
	use_mg

	[[ "$mg_local_daemons" ]] || {
		echo "no daemon list found; check MG_LOCAL_DAEMONS" \
			"setting in $configfile" 1>&2
		return 1
	}

	# yyy old way? (no mongosh)
	out=$( mongo --eval "rs.status()" $mg_cstring ) || {
		[[ "$verbose" ]] &&
			echo "bad rs.status: $out" 1>&2
		return 1
	}
	echo "ok: $out" 1>&2
	return 0
}


# MAIN

# Pick up whatever SVU mode may be in effect for the caller.
#
svumode=$( sed 's/^[^:]*://' <<< $SVU_USING )
[[ "$svumode" ]] ||
	svumode=cur		# if none, default to "cur"
ap_top=$HOME/sv/$svumode/apache2

mg_mode=$mg_live_mode		# global default
verbose=
yes=
noexec=
force=
while [[ "${1:-}" =~ ^- ]]	# $1 starts as the _second_ (post-command) arg
do
	flag="${1:-}"
	case $flag in
	-t|--test)
		mg_mode=$mg_test_mode		# set global
		shift
		;;
	-v*|--v*)
		verbose='--v'
		# doubles as "True" and value inherited by sub-processes
		shift
		;;
	-f|--f*)			# yyy drop?
		force='--force'
		# doubles as "True" and value inherited by sub-processes
		shift
		;;
	-n)				# yyy drop?
		noexec=1
		shift
		;;
	*)
		echo "error: unknown option: $flag"
		usage
		exit 1
	esac
done

cmd=${1:-help}
shift					# $1 is now first command arg

## set '-' as default value for first three args
#port=${2:--} dbpath=${3:--} dblog=${4:--}
## no default for remaining args
#setname=${5:-} setsize=${6:-}
#
#[[ "$cmd" && "$port" && "$dbpath" && "$dblog" ]] || {
#	usage
#	exit 1
#}
#
#[[ "$port" == '-' ]]	&& port=$mongo_port	# default port
#[[ "$cmd" == status ]] && {
## xxx move this call lower
#	rs_status
#	exit
#}
#
## Arguments described in comments
## first arg is action, eg, start, stop
##	--dbpath $mongo_dbpath		# data goes here
##	--logpath $HOME/sv/cur/apache2/logs/mongod_log	# logs go here
##	--port $mongo_port
##	--replSet $mongo_replset	# replica set "live"
##	#dbpath logpath port replset
#
#[[ "$port" == '-' ]]	&& port=$mongo_port	# default port
#[[ "$dbpath" == '-' ]]	&& dbpath=$mongo_dbpath	# default dbpath
#[[ "$dblog" == '-' ]]	&& dblog=$mongo_dblog	# default dblog
#
## XXX plan to change to using REPLICAS BY DEFAULT
## XXX force 3 replicas default?
#replicas=		# default: no replicas
#[[ "$setname" ]]	&& replicas="--replSet $setname"
#
#[[ "$cmd" == start1 ]] &&			# if start1 command
#	replicas=''				# force no replicas
#
#[[ "$port" =~ ^[0-9][0-9]*$ ]] || {
#	echo "error: port ($port) must be a number or '-'"
#	exit 1
#}
#[[ -d $dbpath ]] || mkdir $dbpath || {
#	echo "error: cannot create directory $dbpath"
#	exit 1
#}
#flags=(			# inline mongod config file
#	--dbpath $dbpath --logpath $dblog --port $port
#	$replicas $mongo_other
#)

out=
ulimit -n 4096		# set a higher limit than mongod assumes yyy needed?

# First take care of commands that don't require $configfile.

case $cmd in

start)
	start "$@"
	exit
	;;
stop|graceful-stop|hard-stop)
	stop $cmd "$@"
	exit
	;;
restart|graceful|hard-restart)
	cmd=restart			# ie, ignore differences in invocation
	restart $cmd "$@"
	exit
	;;
stat|status)
	status "$@"
	exit
	;;
help)
	usage
	exit
	;;
esac

# Now commands that want any MG_REPSETOPTS defined in $configfile.

[[ -f "$configfile" ]] &&
	source "$configfile"

case $cmd in

repltest)
	## yyy $setname is an undocumented arg in $3
	#setsize=${2:-} setname=${3:-}
	# The repltest function calls back to this function.
	#repltest "$setsize" "$setname"
	repltest "$@"
	exit
	;;
esac

case $cmd in

rs_add)
	rs_add "$@"
	exit
	;;
rs_del)
	rs_del "$@"
	exit
	;;
rs_list)
	rs_list "$@"
	exit
	;;
rs_start)
	rs_start "$@"
	exit
	;;
rs_stop)
	rs_stop "$@"
	exit
	;;
rs_status|rs_stat)
	rs_status "$@"
	exit
	;;
rs_test)
	rs_test "$@"
	exit
	;;
*)
	[[ "$cmd" ]] &&
		echo "$me: $cmd: unknown argument"
	usage
	exit 1
	;;
esac

