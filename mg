#!/bin/bash

set -u
notify=jak@ucop.edu	# xxx backup, sysupdate, or other failure

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
# 
# EGNAPA_MG_CONNECT_STRING_DEFAULT=
# EGNAPA_MG_LOCAL_DAEMONS=rsetname/port,...
#     
#     Port Setname
#     Port Setname

## Global Mongo constants
#
#rs_live_root=$HOME/sv/cur/apache2/mongo
#rs_test_root=$HOME/sv/cur/apache2/mongo_test
#rs_live_first_port=27017		# standard port
#rs_test_first_port=47017		# 20K more
#rs_live_setname=live			# live replica set name
#rs_test_setname=test			# test replica set name
#rs_mode=				# 'test' or 'live'
#
#dfltrset=$rs_live_setname		# default
#dfltport=$rs_live_first_port		# default
#
#mongo_flags=()
#mongo_other="--fork --logappend"			# other flags
#mongo_other+=" --storageEngine wiredTiger"
##--bind_ip 'localhost,172.31.23.24'	# no space after comma
##--rest		# deprecated since 3.2: admin UI: http://localhost:28017

me=$( basename $0 )
function usage {

	local port=$mg_live_port
	local snam=$mg_live_setname

summary="
       $me [flags] start [ Port [ Setname ] ]
       $me [flags] restart [ Port ]
       $me [flags] stop [ Port ]
       $me [flags] hard-stop [ Port ]
       $me [flags] status [ Port ]

       $me [flags] rs_start Setname
       $me [flags] rs_stop Setname
       $me [flags] rs_status Setname
       $me [flags] rs_add [ Port [ Setname ] ]
       $me [flags] rs_del [ Port [ Setname ] ]
       $me [flags] repltest [ Setsize ]
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

       The start, restart, stop, hard-stop, and status commands do what the
       command name suggests for exactly one MongoDB server instance. Each
       instance starts up ready to be part of the replica set, Setname,
       regardless of whether it ever actually joins the set.

       xxx
       The commands beginning "rs_" work on replica sets, with configuration
       information specified by the Setname, of which two are defined:

           Setname $mg_live_setname, Port $mg_live_port
	   Setname $mg_test_setname, Port $mg_test_port

       The repltest form starts up Setsize servers, adds them to the "test"
       replica set, writes data to the set, attempts to read that data back
       from each replica instance in the set, and then shuts everything down.

       To manage a replica set, each replica should boot and start it's own
       local daemon(s) (27017, 27018) with the default replica set name.
       One distinguished hostname, ending it "-2a" should attempt to run
       rs_init and add itself. The others should only attempt that if they
       haven't been contacted by the

OPTION FLAGS
       -v, --verbose   be much more wordy
       -t, --test      run in test mode (away from "live" data directory)

EXAMPLES
       $me start
       $me stop
       $me repltest 11

SUMMARY $summary

EOT
}

# Global variables we need but whose values depend on $mg_mode.
# Unsetting them here helps flush out "unbound" errors (via "set -u").

unset	mg_root mg_root_alt \
	mg_port mg_host mg_hostport \
	mg_setname mg_dbname mg_mode \
	mg_dbdir_base mg_proc_base mg_rset_base \
	mg_dbdir mg_dblog mg_dbpath mg_flags mg_procfile \
	mg_rs_history mg_rs_conn mg_rs_high_port

# Configures replica set (global var that govern replica set flags).
# yyy a better way might be to _return_ values, not set as globals

# Global mg constants

mg_live_root=$HOME/sv/cur/apache2/mongo
mg_test_root=$HOME/sv/cur/apache2/mongo_test
mg_live_port=27017		# standard port
mg_test_port=47017		# 20K more
mg_live_setname=live		# live replica set name
mg_test_setname=test		# test replica set name
mg_live_dbname=live		# live replica set name
mg_test_dbname=test		# test replica set name
mg_live_mode=live		# 'live' or 'test'
mg_test_mode=test		# 'live' or 'test'

mg_other="--fork --logappend"			# other flags
mg_other+=" --storageEngine wiredTiger"
#--bind_ip 'localhost,172.31.23.24'	# no space after comma
#--rest		# deprecated since 3.2: admin UI: http://localhost:28017

function use_mg {			# call with: port|'any' [ setname ]

	local hostport=${1:-}			# yyy we don't use host part
	local port=${hostport##*:}		# delete up to last ':'
	if [[ $mg_mode == $mg_live_mode ]]
	then
		mg_port=${port:-$mg_live_port}
		mg_setname=${2:-$mg_live_setname}
		mg_dbname=${2:-$mg_live_dbname}
		mg_root=$mg_live_root
		mg_root_alt=$mg_test_root

	elif [[ $mg_mode == $mg_test_mode ]]
	then
		mg_port=${port:-$mg_test_port}
		mg_setname=${2:-$mg_test_setname}
		mg_dbname=${2:-$mg_test_dbname}
		mg_root=$mg_test_root
		mg_root_alt=$mg_live_root
	else
		echo "error: unknown mode: $mode" 1>&2
		return 1
	fi
	[[ -z ${mg_host+x} ]] && {	# if unset (sets only once per process)
		mg_host=$( hostname -f )	# mg_host: where daemon runs
		[[ ! "$mg_host" =~ \. ]] &&	# some wifi networks won't add
			mg_host+=.local		# a qualifier, which we need
	}
	# yyy would using localhost avoid problems like ambiguity and
	#     hostname -f malfunctions? Answer: maybe, but from docs:
	#     "Either all host names in a replica set configuration must be
	#     localhost references, or none must be"

	# mg_proc_base_alt lets "stop" remove a procfile, started in either
	# live or test mode, knowing only the port
	mg_proc_base_alt=$mg_root_alt/proc_

	mg_proc_base=$mg_root/proc_
	mg_rset_base=$mg_root/rset_
	mg_dbdir_base=$mg_root/data_
	mg_rs_history=$mg_root/rs_history

	# If we weren't given a specific port, we can leave early knowing
	# that we've now set as many variables as we can without requiring a
	# real port number.

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

## Configures replica set (global var that govern replica set flags).
#
#function use_rs {		# call with: port setname [ 'clean' ]
#
#	local hostport=${1:-$dfltport}		# default
#	local setname=${2:-$dfltrset}		# default
#	local clean=${3:-}
#	local port=${hostport##*:}		# delete up to last ':'
#	[[ ! "$clean" || "$clean" == 'clean' ]] || {
#		echo "error: use_rs arg 3 must be empty or \"clean\"" 1>&2
#		return 1
#	}
#	[[ "$port" == 'all' || "$port" =~ ^[0-9][0-9]*$ ]] || {
#		echo "error: port ($port) must be numeric" 1>&2
#		return 1
#	}
#	if [[ "$setname" == 'test' ]]
#	then
#		rs_mode=$setname		# set global mode
## xxx how many of these vars are still relevant?
## yyy except for generating dirs during testing...?
#		mongo_root=$rs_test_root
#		mongo_setname=$rs_test_setname
#		mongo_first_port=$rs_test_first_port
#	elif [[ "$setname" == 'live' ]]
#	then
#		rs_mode=$setname
#		mongo_root=$rs_live_root
#		mongo_setname=$rs_live_setname
#		mongo_first_port=$rs_live_first_port
#	else
#		echo "error: mode ($setname) unknown" 1>&2
#		return 1
#	fi
#	mongo_port=$port
#	mongo_dbdir_base=$mongo_root/data_
#	mongo_proc_base=$mongo_root/proc_
#	mongo_rset_base=$mongo_root/rset_
#	[[ "$port" == 'all' ]] && {
#		[[ "$clean" ]] && {			# if "live all clean"
#			[[ "$setname" == 'live' && ! "$force" ]] && {
#				echo "error: this would remove \"live\" data;" \
#					"override with --force" 1>&2
#				return 1
#			}
#			rm -fr $mongo_dbdir_base*	# "all" -- serious step
#		}
#		return 0		# leave early since no port specified
#	}
#	mongo_procfile="$mongo_proc_base$( get_hostport $port )" || {
#		echo "error: get_hostport failed" 1>&2
#		return 1
#	}
## xxx how many of these vars are still relevant?
#	mongo_dbdir=$mongo_dbdir_base$port	# of central interest
#	mongo_dblog=$mongo_dbdir/mongo_log
#	mongo_dbpath=$mongo_dbdir
## xxx this is the real output, right?
#	mongo_flags=(
#		--port $port --replSet $setname
#		--dbpath $mongo_dbpath --logpath $mongo_dblog
#		$mongo_other
#	)
#	[[ "$clean" ]] && {
#		[[ "$verbose" ]] && {
#			echo "+ purging directory $mongo_dbdir" 1>&2
#		}
#		rm -fr $mongo_dbdir
#	}
#	mkdir -p $mongo_dbdir $mongo_dbpath
#	return 0
#}
#
## Sets globals that govern whether test or real mongo data will be used.
## Arg 2 can be hostport or port or 'all', where 'all' means init all
## port-base directories not just one directory. 'all' plus clean clears
## all replica dirs.
## call with: mode=test|real hostport|port|'all' [ 'clean' ]
#
#function use_mongo {
#
#	local mode=${1:-test}			# cautious default
#	local hostport=${2:-$mongo_test_port}	# cautious default
#	local port=${hostport##*:}		# delete up to last ':'
#	local clean=${3:-}
#	[[ ! "$clean" || "$clean" == clean ]] || {
#		echo "error: arg 3 must be empty or \"clean\"" 1>&2
#		return 1
#	}
#	[[ "$port" == 'all' || "$port" =~ ^[0-9][0-9]*$ ]] || {
#		echo "error: port ($port) must be numeric" 1>&2
#		return 1
#	}
#	if [[ "$mode" == 'test' ]]
#	then
#		rs_mode=$mode		# set global mode
#		mongo_root=$rs_test_root
#		mongo_setname=$rs_test_setname
#		mongo_first_port=$rs_test_first_port
#	elif [[ "$mode" == 'real' ]]
#	then
#		rs_mode=$mode
#		mongo_root=$rs_real_root
#		mongo_setname=$rs_real_setname
#		mongo_first_port=$rs_real_first_port
#	else
#		echo "error: mode ($mode) unknown" 1>&2
#		return 1
#	fi
#	mongo_port=$mongo_first_port
#	mongo_dbdir_base=$mongo_root/data_
#	mongo_proc_base=$mongo_root/proc_
#	mongo_rset_base=$mongo_root/rset_
#	[[ "$port" == 'all' ]] && {
#		[[ "$clean" ]] && {			# if "real all clean"
#			[[ "$mode" == 'real' && ! "$force" ]] && {
#				echo "error: this would remove \"real\" data;" \
#					"override with --force" 1>&2
#				return 1
#			}
#			rm -fr $mongo_dbdir_base*	# "all" -- serious step
#		}
#		return 0		# leave early since no port specified
#	}
#	mongo_dbdir=$mongo_dbdir_base$port	# of central interest
#	mongo_dblog=$mongo_dbdir/mongo_log
#	mongo_dbpath=$mongo_dbdir
#	[[ "$clean" ]] && {
#		[[ "$verbose" ]] && {
#			echo "+ purging directory $mongo_dbdir"
#		}
#		rm -fr $mongo_dbdir
#	}
#	mkdir -p $mongo_dbdir
#	return 0
#}
#
## Test Mongo database settings
#
#tmongo_dbdir=$HOME/sv/cur/apache2/tmongod
#tmongod_proc=$tmongo_dbdir/proc_	# mongod process file base
#tmongo_dbpath=
##"$tmongo_dbdir/data_$port"		# data dbpath for $port
#tmongo_dblog=$tmongo_dbdir/log
#tmongo_replset=rstest			# test replica set name
#tmongo_port=47017			# 20K more than standard port
#tmongo_other="$mongo_other"

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

#args_per_instance=
#
#repSetHosts=''			# list of servers in replica set
#repSetAdd=''			# list of servers to add to set
#
#function get_hostport {			# call with: port
#
#	# yyy add check that port is numeric?
#	local port=$1
#	local host=$( hostname -f )		# host where daemon runs
#	[[ ! "$host" =~ \. ]] &&		# some wifi networks won't
#		host+=.local			# qualify and we need that
#	# yyy would using localhost avoid problems like ambiguity and
#	#     hostname -f malfunctions?
#	#host=${3:-localhost}			# host where daemon runs
#	# Answer: maybe, but from docs: "Either all host names in a replica
#	# set configuration must be localhost references, or none must be"
#	echo "$host:$port"
#}
#
## xxx prior code to go in function: replset_check N -> host ?
## yyy move this code back into repltest?
#function replset_check {	# call with: N   (proposed set size)
#
#	local n even host
#	n=${1:-}			# number of names to generate
#	# $n is even if $even == $n; $even == 0 if $n isn't a number
#	(( even=( "$n" / 2 * 2 ) ))		# or $n == 1
#	if [[ $even -eq 0 || $n -eq $even || $n -lt 0 || $n -ge $max_setsize ]]
#	then
#		[[ $n -ne 1 ]] && {
#			echo "error: replica count ($n) should be an odd" \
#				"integer < $max_setsize and > 1" 1>&2
#			return 1
#		}
#		# if we get here, $n -eq 1, which we allow under caution
#		echo "replica count 1 (no replicas) -- baseline testing" 1>&2
#	fi
## xxx use get_hostport()
#	host=${3:-$( hostname -f )}		# host where daemon runs
#	[[ ! "$host" =~ \. ]] &&		# some wifi networks won't
#		host+=.local			# qualify and we need that
#	# yyy would using localhost avoid problems like ambiguity and
#	#     hostname -f malfunctions?
#	#host=${3:-localhost}			# host where daemon runs
#	# Answer: maybe, but from docs: "Either all host names in a replica
#	# set configuration must be localhost references, or none must be"
#	echo "$host"
#	return 0
#}
#
#function replset_gen_params {	# call with: test|real setsize
#
## xxx drop these lines next
#	local setname n max even i host starter_port
#	local mode=${1:-test}
#	n=${2:-$def_setsize}		# number of names to generate
#	[[ "$n" == '-' ]] &&		# default number of replicas
#		n=5
#	max=20				# max number of replicas
##	# $n is even if $even == $n; $even == 0 if $n isn't a number
##	(( even=( "$n" / 2 * 2 ) ))		# or $n == 1
##	if [[ $even -eq 0 || $n -eq $even || $n -lt 0 || $n -ge $max ]]
##	then
##		[[ $n -ne 1 ]] && {
##			echo "error: replica count ($n) should be an odd" \
##				"integer < $max and > 1" 1>&2
##			return 1
##		}
##		# if we get here, $n -eq 1, which we allow under caution
##		echo "replica count 1 (no replicas) -- baseline testing" 1>&2
##	fi
##	host=${3:-$( hostname -f )}		# host where daemon runs
##	[[ ! "$host" =~ \. ]] &&		# some wifi networks won't
##		host+=.local			# qualify and we need that
##	# yyy would using localhost avoid problems like ambiguity and
##	#     hostname -f malfunctions?
##	#host=${3:-localhost}			# host where daemon runs
##	# Answer: maybe, but from docs: "Either all host names in a replica
##	# set configuration must be localhost references, or none must be"
## xxx code below to move to repltest, eliminating need for instance array?
#	host=$( replset_check $n ) || {
#		echo "error: failed replset_check" 1>&2
#		return 1
#	}
#
#	use_mongo "$mode" all
#	starter_port=${4:-$mongo_first_port}	# base port where daemon runs
#	#starter_port=${4:-$tmongo_port}	# base port where daemon runs
#
#	local instance port hostport
#	i=1
#	while [[ $i -le $n ]]			# generate instances
#	do
#		port=$(( $starter_port + $i ))
#		hostport="$host:$port"
#
#		use_mongo "$mode" "$hostport"
#		instance=(
#			"$hostport"		# first elem MUST be host:port
#			"$mongo_dbdir"		# data dbpath for $port
#			"$mongo_dblog"		# log file
#			"$mongo_setname"	# replica set name
#			"$n"			# replica set size
#		)		# save instance so we can return its size
#		# eg, 5 lines => every 5 array elements describes an instance
#		# all elements but first are passed to $me after stop||start
#		# First element must always be host:port combination.
#
#		instance_args+=( "${instance[@]}" )
#		(( i++ ))
#	done
#	args_per_instance=${#instance[@]}
#	return
#}
#
## call with: hostport args...
## args...?
## creates a file as side-effect used for tracking and tearing down instances
#
## xxx drop?
#function startup_instance {
#
#	local hostport=$1			# set -u aborts if not set
#	# yyy why isolate $port at all? because mongo start...
#	local port=${hostport##*:}
#	local setname=${2:-}
#	local replica_args=
#	[[ "$setname" ]] &&
#		replica_args="--replSet $setname"
#	#shift
#	local mongod_args=(			# inline mongod config file
#		--dbpath $mongo_dbpath --logpath $mongo_dblog --port $port
#		$replica_args $mongo_other
#	)
##	local cmd="$me $verbose start $port $*"
#	local cmd="start1 $port ${mongod_args[*]}"
#	[[ "$verbose" ]] &&
#		echo "+ running \"$cmd\"" 1>&2
#	# start daemon
#	# yyy why have another process? because it's not
#	# encapsulated in a function, but inlined in case statement
#	[[ "$noexec" ]] &&
#		cmd="echo + '"$cmd"'" 1>&2
#	start1 $port ${mongod_args[*]} || {
#		echo "error in \"$cmd\"" 1>&2
#		return 1
#	}
#	# create file we can use later for tracking and teardown
#	# setname will be '-' if there's no replica set
#	echo "startup_instance $port ${setname:--} ${mongod_args[*]}" \
#		> $mongo_proc_base$hostport
#}
#
## call with: hostport [ 'hard-stop' ]
## xxx replace with "stop"?
#
#function shutdown_instance {
#
#	local hostport=$1			# set -u aborts if not set
#	local port=${hostport##*:}
#	local op=${2:-stop}		# stop (default) or hard-stop
#	local retstatus=0		# optimist
#	local cmd="$me $verbose $op $port"
#	[[ "$verbose" ]] &&
#		echo "+ doing \"$cmd via port $port"
#	[[ "$noexec" ]] &&
#		cmd="echo + '"$cmd"'"
#	$cmd || {
#		echo "error in \"$cmd\"" 1>&2
#		return 1
#	}
#}

# runs mongo shell operation and parses outputs
# call with: operation, rs_conn, [ returnvar ]
#  rs_conn can be a hostport or a connection string
# returns output via ${returnvar}_out global variable (default "MSH")
# also returns broken-out values in {returnvar}_* if returnvar present

function mongosh {

	local op=$1
	local rs_conn=$2
	local r=${3:-}			# return variable name
	local out json retstatus error=

	[[ "$verbose" ]] && {
		echo "mongosh: doing JSON.stringify($op) on $rs_conn" 1>&2
	}

	# JSON.stringify has two virtues: (a) it makes the JSON parsable to
	# the jq tool and (b) puts it all on one line, making it possible to
	# filter out connection messages and diagnostics.

	out=$( mongo --eval "JSON.stringify($op)" $rs_conn ) || {
		retstatus=$?
		echo "mongosh: error invoking JSON.stringify($op) on $rs_conn" \
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
# NB: rs.initiate on server S seems to add S as first replica
#     ie, no need to add S itself?

function rs_init {

	local hostport=$1		# set -u aborts if not set
	local retstatus=0		# optimist
	[[ "$verbose" ]] &&
		echo "+ doing rs.initiate() via $hostport" 1>&2

	#out=$( mongo --port $port --eval "rs.initiate()" )
	# NB: need to convert hostport into connection string because for some
	# reason mongo shell won't connect to host:port UNLESS host is a dotted
	# quad, eg, host as DNS name WON'T work.

	mongosh "rs.initiate()" "mongodb://$hostport" m ||
		return 1		# since m_* vars will be undefined
	[[ "$verbose" ]] && {
		echo "+ $m_out" 1>&2
	}
	return 0
}

# puts hostport of replica set primary on stdout and messages on stderr
# call with: rs_conn
#	{'_id' : $j, 'host' : '$instance', 'stateStr' : 'PRIMARY'},"

# yyy no one calls this
function rs_primary {

	local rs_conn=$1
	local rsnam=${rs_conn##*=}	# YYY must end in replicaSet=foo!!
	#local hostport=$2		# set -u aborts if not set
	#local port=${hostport##*:}	# delete up to last ':'
	local retstatus=0		# optimist
	[[ "$verbose" ]] &&
		echo "+ doing rs_primary via $rs_conn for rset $rsnam" 1>&2
		#echo "doing db.isMaster() via port $port" 1>&2
	#local op="JSON.stringify(db.isMaster('$hostport'))"
	local op="JSON.stringify(db.isMaster())"
	local out
	#out=$( mongo --quiet --port $port --eval "$op" ) || 
	out=$( mongo --quiet --eval "$op" $rs_conn | grep '^{' ) || {
		#	| perl -ne '/^\d{4}-\d\d-\d\dT\d\d/ or print' ) || 
		echo "error: $op call failed on $rs_conn" 1>&2
		#echo "error: $op call failed on port $port" 1>&2
		sed 's/^/  /' <<< "$out" 1>&2
		#echo "$out" 1>&2
		return 1
	}
	[[ "$verbose" ]] && {
		sed 's/^/  /' <<< "$out" 1>&2
	}
	# JSON output looks like
	#        "setName" : "rst",
	#        "setVersion" : 1,
	#        "ismaster" : true,
	#        "primary" : "jak-macbook.local:47018",
	#        "secondary" : false,
	# -r does "raw output", removing quotes around strings
	fields=( $( jq -r '.setName, .primary' <<< "$out" ) )
	local snam=${fields[0]:-}
	local primary=${fields[1]:-}
	[[ "$snam" == "$rsnam" ]] || {
		#echo -n "error: requested hostport ($hostport) is not a" 
		echo -n "error: requested hostport (hostport) is not a" \
			"member of replica set \"$rsnam\"" 1>&2
			[[ "$snam" ]] &&
				 echo -n ", but is a member of \"$snam\"" 1>&2
		echo 1>&2	# end the line
		return 1	# no output
	}
	[[ "$primary" ]] || {
		echo "no primary" 1>&2
		#echo "fields is ${fields[@]}" 1>&2
		return 1	# no output
	}
	echo "$primary"		# main return value
	[[ "$verbose" ]] &&
		echo "+ primary is $primary" 1>&2
	return 0		# return status probably ignored
}

# on stdout puts "N replicas: " followed by a ','-separated list of replicas,
# with primary indicated by a *

function rs_list { # call with: rs_conn

	local rep rs_conn=$1
	[[ ! "$rs_conn" ]] && {
		echo "rs_list: connection string not initialized" 1>&2
		return 1
	}
# xxx [[ ! "$rs_conn" ]] && ...
#[[ ! "$rs_conn" ]] && echo "rs_list: rs_conn is empty" 1>&2
	mongosh "db.isMaster()" $rs_conn m
	if [[ $? == 0 ]]
	then
		echo "${#m_hosts[@]} replicas:" $( sed -e 's| |,|g' \
			-e "s|\(${m_primary:-null}\)|*\1|" <<< "${m_hosts[@]}" )
	else		# yyy not even checking $m_ok
		echo "error in mongo db.isMaster"
	fi
	return 0
}

# always outputs a number

function rs_size {	# call with: rs_conn

	local out rs_conn=$1
	local setsize=1		# something non-zero, used to proceed on error
	out=$( rs_list $rs_conn ) || {
		echo "failed: rs_list $rs_conn" 1>&2
		return 1
	}
	setsize=$( sed -n 's/^\([0-9][0-9]*\) .*/\1/p' <<< "$out" )
	echo "$setsize"
	[[ "$setsize" ]] ||
		return 1
	return 0
}

# add replica instance

function rs_add_instance { # call with: rs_conn hostport

	# rs.add({host: "mongodbd4.example.net:27017", priority: 0, votes: 0})
	# "Replica set configuration contains 8 voting members,
	# but must be at least 1 and no more than 7"
	# non-voting members must have priority 0

	local rs_conn=$1
	local hostport=$2		# needs to be both host and port
	#local port=${hostport##*:}	# delete up to last ':'
	local retstatus=0		# optimist

	# do rs_list first to see how many members there are
	local out setsize
	out=$( rs_list $rs_conn ) || {
		echo "failed: rs_list $rs_conn" 1>&2
		return 1
	}
	setsize=$( sed 's/^\([0-9][0-9]*\).*/\1/' <<< "$out" )
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
	#out=$( mongo --port $port --eval "rs.add('$hostport')" )
	#local op="JSON.stringify(rs.add('$hostport'))"
	#out=$( mongo --eval "$op" $rs_conn | grep '^{' )
	#mongosh "rs.add('$hostport' $non_voting)" $rs_conn m
	mongosh "rs.add( { host: \"$hostport\" $non_voting } )" $rs_conn m
	retstatus=$?
	[[ "$verbose" ]] &&
		sed 's/^/  /' <<< "$m_out" 1>&2
	return $retstatus
}

# sets mg_rs_conn and mg_rs_high_port, given a port, and optionally a setname
# call with port and optional setname; if no setname assume we are to figure it
# out from given port (as if called by rs_del)
# yyy allow 'any' or '-' (default)? to list any rset_* files
#     allow '-' and rsetname? to report on that set?
#     this would support "./mg rs_status" what about "./mg status"?

function use_rs_conn {		# call with: hostport [ setname ]

	use_mg any
	local hostport=$1
	local port=${hostport##*:}
	local setname=${2:-}
	local pfile rfile last x
	if [[ ! "$setname" ]]	# must figure out $setname based on port
	then
		pfile="$mg_proc_base""local:$port"
		[[ -f $pfile ]] || {			# first try
			pfile="$mg_proc_base_alt""local:$port"
			[[ -f $pfile ]] ||		# second try
				pfile=/dev/null
		}
		setname=$( perl -ne 'm/--replSet\s*(\S*)/ and print "$1"' \
			< $pfile )
	fi
	mg_rs_conn=				# initialize for return
	mg_rs_high_port=			# initialize for return

	rfile=$mg_rset_base$setname		# NB: setname fails quietly
	last=$( tail -1 $rfile 2> /dev/null )
	[[ ! "$last" ]] && {
		echo ""		# no replica set yet, so no connection string
		return 0
	}
	# Example last line:
	# Tue Feb 20 07:40:10 PST 2018 added jak-macbook.local:47023 - mongodb://jak-macbook.local:47023,jak-macbook.local:47022,jak-macbook.local:47021,jak-macbook.local:47020,jak-macbook.local:47019,jak-macbook.local:47018,jak-macbook.local:47017/?socketTimeoutMS=30000&readPreference=primaryPreferred&replicaSet=test

	x=$( perl -ne '
		chomp;
		s,.*mongodb://,mongodb://, and print;	# print conn string
		s,/\?.*,,;				# drop query string
		print ":";				# separator
		@x = sort {$b <=> $a} m/:(\d+)/g;	# descending order
		scalar(@x) and print "$x[0]";		# print highest
		' <<< "$last" )
	mg_rs_conn=${x%:*}				# delete after last ':'
	mg_rs_high_port=${x##*:}			# delete up to last ':'
	return 0
}

# start instance, add to replica set, and output new connection string
# setname implied by $rs_mode, which rs_list requires to be initialized
# creates and adds to a file as side-effect to track replica set states

function rs_add {	# call with: hostport setname

	local hostport=$1
	local port=${hostport##*:}
# xxx setname to be optional?
	local setname=$2
	local out setsize
	local retstatus=0		# optimistic

	use_rs_conn $hostport $setname		# known setname
	local rs_conn=$mg_rs_conn
	local snam=$mg_setname

	echo "starting up and adding $hostport" 1>&2
	#start $hostport $setname || 
	start $port $setname || {
		echo "rs_add: error in \"start $port $setname\"" 1>&2
		return 1
	}

	if [[ ! "$rs_conn" ]]	# first time through, init replica set
	then
		[[ "$verbose" ]] && {
			echo "doing: rs_init $mg_hostport" 1>&2
		}
		#rs_init $hostport || {	# eg, still up from prior run
		rs_init $mg_hostport || {	# eg, still up from prior run
			echo "rs_add: rs_init error; you may want to tear" \
				"down old set" 1>&2
			return 1
		}
		rs_conn=$( rs_connect_str init $snam $mg_hostport $mg_dbname )
		grs_conn="$rs_conn"	# update global
		# initialize file to track replica set states
		echo "$(date) created with $mg_hostport - $rs_conn" \
			> $mg_rset_base$snam	# NB: overwrite, not append
	else
		# Connect mongo shell to replica set (NB: no dbname
		# in this particular string):
		# mongo mongodb://10.10.10.15:27001,10.10.10.16:27002,
		#  10.10.10.17:27000/?replicaSet=replicaSet1
		rs_add_instance $rs_conn $mg_hostport || {
			echo rs_add_instance failed on $mg_hostport 1>&2
			return 1
		}
		rs_conn=$( rs_connect_str add $rs_conn $mg_hostport )
		# yyy relationship between grs_conn and mg_rs_conn?
		grs_conn="$rs_conn"	# update global
		# add to file to track replica set states
		echo "$(date) added $mg_hostport - $rs_conn" \
			>> $mg_rset_base$snam
		echo "$(date) added $mg_hostport - $rs_conn" \
			>> $mg_rs_history
	fi
	echo "rs_conn: $rs_conn"
	return 0
}

# must shutdown instance before you do rs.remove(hostport)
function rs_del_instance {	# call with: rs_conn hostport

	local rs_conn=$1
	local hostport=$2		# set -u aborts if not set
	local retstatus=0		# optimist

	mongosh "rs.remove('$hostport')" $rs_conn m
	retstatus=$?
	[[ "$verbose" ]] &&
		sed 's/^/  /' <<< "$m_out" 1>&2
	return $retstatus
}

# shutdown instance, remove from replica set, and output new connection string
# setname implied by $rs_mode, which rs_list requires to be initialized
# adds to a file as side-effect to track replica set states

function rs_del {	# call with: hostport

	local hostport=$1
	local port=${hostport##*:}
	local out setsize stop_op=stop
	local retstatus=0		# optimistic

	use_rs_conn $hostport			# unknown set name
	local rs_conn=$mg_rs_conn

	setsize=$( rs_size $rs_conn ) || {
		echo "error: cannot determine set size" 1>&2
		setsize=0
		#return 1
	}
	[[ "$setsize" -lt 3 ]] && {
		echo "fewer than 3 instances (no primary) requires hard-stop" \
			1>&2
		stop_op=hard-stop
	}
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
		cmd="rs_del_instance $rs_conn $mg_hostport"
		[[ "$verbose" ]] &&
			echo  "+ doing $cmd" 1>&2
		$cmd ||
			echo "error: $cmd failed" 1>&2
		rs_conn=$( rs_connect_str del $rs_conn $mg_hostport )
		rs_list $rs_conn
	else				# else there's no primary for that
		rs_conn=$( rs_connect_str del $rs_conn $mg_hostport )
	fi
	# add record to file to track replica set states

	echo "$(date) deleted $mg_hostport - $rs_conn" >> $mg_rset_base$snam
	echo "$(date) deleted $mg_hostport - $rs_conn" >> $mg_rs_history
	[[ "$rs_conn" =~ mongodb:/// ]] &&	# if replica set is finished
		rm $mg_rset_base$snam		#   remove its file
	echo "rs_conn: $rs_conn"
	return $retstatus
}

# Called via "trap" on receipt of signal for the purpose of doing cleanup
# Args are only passed at trap definition time, so the current state of a
# replica set connection string has to reside in a global, grs_conn.
# call without args.

function wrapup_repltest {
	echo "SIGINT caught: now killing test servers"
	teardown_repltest $grs_conn
}

# clean up by shutting down servers that we started
# call with: rs_conn

function teardown_repltest {

	local rs_conn=$1
	local i out hostport port instances

	# Use rs_conn list as basis for which servers to shutdown.
	# efficiency: rs_conn is constructed by prepending newer replicas
	#   to older replicas, making the primary likely to be last, so we're
	#   unlikely to shutdown the primary (and it takes time for mongo to
	#   elect a new primary) until the very end.

	instances=( $( perl -ne '
		s|mongodb://||;			# drop up to host list
		s|/.*|,|;			# drop query string, add ','
		print join "\n", split /,/;	# now a comma-separated list
		' <<< "$rs_conn" ) )

	local total=${#instances[@]}		# total instances remaining

	echo "tearing down $total-server replica set"
	for i in ${instances[@]}		# for each instance i
	do
		hostport=${i##*_}		# delete to last '_'
		port=${hostport##*:}		# delete to last ':'
		[[ "$hostport" =~ ^local: ]] &&
			hostport="$mg_host:$port"
		echo "shutting down and removing $hostport"
		out=$( rs_del $hostport ) || {
			echo "error: rs_del $rs_conn $hostport failed" 1>&2
			echo "out: $out" 1>&2
			continue
		}
		rs_conn=$( sed -n 's/^rs_conn: *//p' <<< "$out" )
		grs_conn="$rs_conn"
		(( total-- ))
	done
}

repSetOpts=				# replica set connection string options
repSetOpts+="socketTimeoutMS=30000&"	# wait up to 30 secs for reply
# yyy does readpref work in the connection string?
readpref=primaryPreferred	# set to permit reading from secondaries at all
repSetOpts+="readPreference=$readpref&"	# replica to read from
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

# args either: init setname hostport_list [ dbname ]
#      or:     add|del connstr hostport
#      or:     hostports connstr

function rs_connect_str {

	local hostport cs setname dbname rs_conn
	local cmd=${1:-}
	case "$cmd" in
	add|del)
		cs=$2			# connection string
		hostport=$3		# to add or delete
		if [[ $cmd == add ]]; then
			cs=$( perl -pe "s|//|//$hostport,|" <<< "$cs" )
			# add hostport to list in mongodb://...,.../ URL
		else
			cs=$( perl -pe "s|$hostport,?||; s|,/|/|" <<< "$cs" )
			# drop hostport and if it was last, drop trailing ,
		fi
		echo "$cs"
		return 0
		;;
	init)
		setname=$2
		hostport=$3	# could be a comma-separated list of hostports,
			# eg, extracted from existing rs_conn with "hostports"
			# when you're re-init'ing in order to add a database
		dbname=${4:-}
		# NB: options MUST precede replicaSet=foo, which must terminate
		# the string.
		rs_conn="mongodb://$hostport/$dbname?$repSetOpts"
		rs_conn+="replicaSet=$setname"
		echo "$rs_conn"
		return 0
		;;
	hostports)
		cs=$2			# existing connection string
		echo $( sed 's|mongodb://*\([^/]*\)/.*|\1|' <<< "$cs" )
		return 0
		;;
	*)
		echo "error: rs_connect_str usage: command hostport ..." 1>&2
		return 1
		;;
	esac
}

function repltest {

	local n i even hostport starter_port cmd

	n=${1:-$def_setsize}		# proposed set size
	[[ ! "$n" || "$n" == '-' ]] &&		# default number of replicas
		n=$def_setsize

	# $n is even if $even == $n; $even == 0 if $n isn't a number
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

	echo beginning $n-server replica set test
	local rs_conn=			# replica set connection string
	grs_conn=			# global version of the same
	trap wrapup_repltest SIGINT	# trigger cleanup using global

	mg_mode=$mg_test_mode		# enforce --test before calling use_mg
	use_mg

	# we'll use the test port as the base port for replicas
	starter_port=$mg_port		# base port number where daemon runs
	local snam=$mg_setname
	local port out
	i=0

	while [[ $i -lt $n ]]			# generate instances
	do
		# mg_rs_high_port+1 might potentially one day be used to pick
		#       the next localhost instance
		port=$(( $starter_port + $i ))
		hostport="$mg_host:$port"	# yyy don't use host yet

		# Docs: "Make sure the new member’s data directory does not
		# contain data. The new member will copy the data from an
		# existing member."

		use_mg $hostport $snam		# defines globals
		[[ "$mg_dbdir" =~ $mg_test_root/ ]] || { # NB: need final '/'
			echo "abort: won't remove $mg_dbdir because it" \
				"doesn't descend from test root:" \
				"$mg_test_root" 1>&2
			return 1
		}
		rm -fr $mg_dbdir

		#out=$( rs_add "$rs_conn" "$hostport" "$mg_setname" ) || 
# xxx make rs_add accept - for hostport, and pull port++ from setname
		out=$( rs_add "$hostport" "$mg_setname" ) || {
			echo "error in adding \"$hostport\"" 1>&2
			[[ ! "$rs_conn" ]] && {
				rs_conn=$( rs_connect_str init $snam $hostport )
				teardown_repltest $rs_conn
				return 1
			}
			(( i++ ))
			continue
		}
		rs_conn=$( sed -n 's/^rs_conn: *//p' <<< "$out" )
		grs_conn="$rs_conn"
		(( i++ ))
	done

	[[ "$verbose" ]] && {
		echo === Replica set status after adding replicas ===
		mongo --eval "rs.status()" $rs_conn  # old way has its virtues
		#mongosh "rs.status()" $rs_conn m ; echo "json: $m_json"
	}

	## yyy need to pause really?
	#local s=2	# number of seconds to pause while replicas wake up
	#echo Sleep $s seconds to let servers stand up...
	#sleep $s

	# We could have added the database name to the connection string early
	# on, but here we can test re-initializing that string after extracting
	# the host list we've built up and re-inserting it in the new string.

	local hostport_list collection db_coll_name
	# extraction step
	hostport_list=$( rs_connect_str hostports $rs_conn )
	collection=testcoll
	db_coll_name="$mg_dbname.$collection"

	local old_rs_conn="$rs_conn"		# save it just in case
	# re-insertion step
	rs_conn=$( rs_connect_str init $snam $hostport_list $mg_dbname )
	grs_conn="$rs_conn"			# update global

	# Done editing rs_conn.
	# Now add data to the replica set.

	local perl_add_data
	# generate data ($fate) containing date to get different data each run
	local fate="timely data $( date )"
	read -r -d '' perl_add_data << 'EOT'

	# start embedded Perl program
	# call with: rs_conn, $dbtest.$collection, test_data_string
	use 5.010;
	use strict;
	use MongoDB;
	use Try::Tiny;		# for exceptions
	use Safe::Isa;		# provides $_isa
	# use Try::Tiny::Retry	# yyy (one day) for automatic retries

	my $connection_string = $ARGV[0] || '';
	my $db_coll_name = $ARGV[1] || '';	# db_name.collection_name
	my $data_string = $ARGV[2] || '';
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
	try {
		$col = $client->ns($db_coll_name);
		$col->insert({ name => "JDoe", fate => "$data_string" });
		$docs = $col->find();
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

	out=$( perl -we "$perl_add_data" "$rs_conn" "$db_coll_name" "$fate" )
	local retstatus=$?
	local doclen=${#fate}	# number of characters in the string $fate
	[[ "$out" != "$fate" ]] && {
		echo "Warning: doc stored (len $doclen) not read from" \
			"replica (len ${#out})"
	}

	local stored_doc=$fate
	if [[ $retstatus -eq 0 ]]
	then
		echo "test data (length $doclen) = |$stored_doc|"
		#sed 's/^/    /' <<< "$stored_doc"	# indent data
	else
		echo "error: could not add test document via $rs_conn" 1>&2
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
		# hostname -f, depending on what network we're connected to
		[[ "$hostport" =~ ^local: ]] &&
			hostport="$mg_host:$port"

		# database name carried in $rs_conn
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

	teardown_repltest $rs_conn
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
		echo "mongod on port $mg_port appears to be up already"
		return
	fi
	#use_rs $port $setname ||	# define mongo_flags and mongo_procfile
	#	return 1
	[[ "$verbose" ]] &&
		echo "starting mongod, flags: ${mg_flags[*]}" 1>&2
	# start in background
	out=$( mongod ${mg_flags[*]} )
	if [[ $? -ne 0 ]]
	then
		echo "mongod start NOT OK"
		echo "$out"
		return 1
	fi
	[[ "$verbose" ]] && echo "$out"
	echo "mongod OK (port $mg_port) -- started"

	# Finally create a file we can use later for tracking and teardown.
	echo "startup $mg_port $mg_setname: ${mg_flags[*]}" > $mg_procfile
	return 0
}

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
		echo "mongod (port $mg_port) appears to be down"
	else
		[[ "$verbose" ]] &&
			echo "shutting down server on port $mg_port"
		# yyy change echo pipe to --eval opt
		out=$( echo -e "use admin \n db.shutdownServer()" |
			mongo --port $mg_port )
		if [[ $? -eq 0 ]]
		then
			echo "mongod OK (port $mg_port) -- stopped"
		else
			echo "mongod shutdown NOT OK"
			echo "$out"
		fi
	fi
	sleep 1		# pause seems to help here under Linux
	#use_rs $port $setname
	[[ "$verbose" ]] &&
		echo "restarting mongod, flags: ${mg_flags[*]}"
	mongod ${mg_flags[*]} > /dev/null	# start in background
	if [[ $? -ne 0 ]]
	then
		echo "mongod $cmd NOT OK"
		return 1
	fi
	echo "mongod OK (port $mg_port) -- restarted"
	[[ "$verbose" ]] && echo "$out"
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
		echo "mongod (port $mg_port) appears to be down already"
		rm $mg_procfile		# yyy leave around just in case?
		return 0
	fi
	[[ "$verbose" ]] &&
		echo "shutting down server on port $mg_port"
	out=$( mongo --port $mg_port \
		--eval "db.shutdownServer($force)" admin )
	if [[ $? -ne 0 ]]
	then
		echo "problem shutting down mongod (port $mg_port)"
		echo "$out"
		return 1
	fi
	echo "mongod OK (port $mg_port) -- $stopped"
	[[ "$verbose" ]] && echo "$out"
	rm -f $mg_procfile $mg_procfile_alt
	return 0
}

function start1 {	# call with: port dbpath dblog

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

configfile=$HOME/warts/env.sh

function rs_start {		# no args
	source $configfile
	local cstring="${EGNAPA_MG_CONNECT_STRING_DEFAULT:-}"
	local daemons="${EGNAPA_MG_LOCAL_DAEMONS:-}"
	[[ "$EGNAPA_MG_CONNECT_STRING_DEFAULT" ]] || {
		echo "error: EGNAPA_MG_CONNECT_STRING_DEFAULT not set in" \
			"$configfile" 1>&2
		return 1
	}
	[[ "$EGNAPA_MG_LOCAL_DAEMONS" ]] || {
		echo "error: EGNAPA_MG_LOCAL_DAEMONS not set in" \
			"$configfile" 1>&2
		return 1
	}
	EGNAPA_MG_LOCAL_DAEMONS=rsetname/port,...
}

#function rs_stop {		# no args
#}

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

case $cmd in

start)
	start "$@"
	exit
	;;

stop|graceful-stop|hard-stop)
	stop $cmd "$@"
	;;

restart|graceful|hard-restart)
	cmd=restart			# ie, ignore differences in invocation
	restart $cmd "$@"
	;;

stat|status)
	status "$@"
	exit
	;;

repltest)
	## yyy $setname is an undocumented arg in $3
	#setsize=${2:-} setname=${3:-}
	# The repltest function calls back to this function.
	#repltest "$setsize" "$setname"
	repltest "$@"
	exit
	;;

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
help)
	usage
	exit
	;;

*)
	[[ "$cmd" ]] &&
		echo "$me: $cmd: unknown argument"
	usage
	exit 1
	;;
esac

