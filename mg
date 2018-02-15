#!/bin/bash

set -u

notify=jak@ucop.edu	# xxx backup, sysupdate, or other failure
me=$( basename $0 )
function usage {

summary="
       $me [flags] [re]start [ Port Dbpath Dblog ]
       $me [flags] [hard-]stop [ Port Dbpath Dblog ]
       $me [flags] status [ Port Dbpath Dblog ]
       $me [flags] start1 [ Port Dbpath Dblog ]
       $me [flags] repltest [ Setsize ]
  port=\${2:--} dbpath=\${3:--} dblog=\${4:--} setname=\${5:-} setsize=\${6:-}
"
	cat << EOT

SYNOPSIS                          ($0)
       $me - mongodb service manager

USAGE $summary

DESCRIPTION
       The $me tool manages various administrative tasks for MongoDB clents and
       servers. It currently assumes you are running under an "svu" service
       version (type "svu" for details). A non-zero exit status indicates an
       error. By default, $me commands affect onl test servers and replicas;
       use "--mode real" to affect real servers.

       The start, restart, stop, hard-stop, and status commands do what the
       command name suggests. The start1 command starts a single instance mongo
       (no replicas).

       The repltest form starts up Setsize servers, adds them to a replica set,
       writes data to the set, attempts to read that data back from each
       replica in the set, and then shuts everything down.

OPTION FLAGS
       -v, --verbose      be much more wordy
       -m, --mode MODE    set mode to "test" (default) or "real"

EXAMPLES
       $me start
       $me stop
       $me repltest 11

SUMMARY $summary

EOT
}

# Global Mongo constants

mongo_real_root=$HOME/sv/cur/apache2/mongo
mongo_test_root=$HOME/sv/cur/apache2/mongo_test
mongo_real_first_port=27017		# standard port
mongo_test_first_port=47017		# 20K more
mongo_real_setname=rs0			# real replica set name
mongo_test_setname=rstest		# test replica set name
mongo_mode=test				# 'test' (default) or 'real'

mongo_other="--fork --logappend"			# other flags
mongo_other+=" --storageEngine wiredTiger"
#--bind_ip 'localhost,172.31.23.24'	# no space after comma
#--rest		# deprecated since 3.2: admin UI: http://localhost:28017

# Global variables we need but whose values depend on $mongo_mode.
# Unsetting them here helps flush out "unbound" errors (via "set -u").

unset mongo_root mongo_dbdir_base mongo_proc_base mongo_rset_base \
	mongo_dbdir mongo_dblog mongo_dbpath mongo_setname mongo_first_port

# Sets globals that govern whether test or real mongo data will be used.
# Arg 2 can be hostport or port or 'all', where 'all' means init all
# port-base directories not just one directory. 'all' plus clean clears
# all replica dirs.
# call with: mode=test|real hostport|port|'all' [ 'clean' ]

function use_mongo {

	local mode=${1:-test}			# cautious default
	local hostport=${2:-$mongo_test_port}	# cautious default
	local port=${hostport##*:}		# delete up to last ':'
	local clean=${3:-}
	[[ ! "$clean" || "$clean" == clean ]] || {
		echo "error: arg 3 must be empty or \"clean\"" 1>&2
		return 1
	}
	[[ "$port" == 'all' || "$port" =~ ^[0-9][0-9]*$ ]] || {
		echo "error: port ($port) must be numeric" 1>&2
		return 1
	}
	if [[ "$mode" == 'test' ]]
	then
		mongo_mode=$mode		# set global mode
		mongo_root=$mongo_test_root
		mongo_setname=$mongo_test_setname
		mongo_first_port=$mongo_test_first_port
	elif [[ "$mode" == 'real' ]]
	then
		mongo_mode=$mode
		mongo_root=$mongo_real_root
		mongo_setname=$mongo_real_setname
		mongo_first_port=$mongo_real_first_port
	else
		echo "error: mode ($mode) unknown" 1>&2
		return 1
	fi
	mongo_port=$mongo_first_port
	mongo_dbdir_base=$mongo_root/data_
	mongo_proc_base=$mongo_root/proc_
	mongo_rset_base=$mongo_root/rset_
	[[ "$port" == 'all' ]] && {
		[[ "$clean" ]] && {			# if "real all clean"
			[[ "$mode" == 'real' && ! "$force" ]] && {
				echo "error: this would remove \"real\" data;" \
					"override with --force" 1>&2
				return 1
			}
			rm -fr $mongo_dbdir_base*	# "all" -- serious step
		}
		return 0		# leave early since no port specified
	}
	mongo_dbdir=$mongo_dbdir_base$port	# of central interest
	mongo_dblog=$mongo_dbdir/mongo_log
	mongo_dbpath=$mongo_dbdir
	[[ "$clean" ]] && {
		[[ "$verbose" ]] && {
			echo "+ purging directory $mongo_dbdir"
		}
		rm -fr $mongo_dbdir
	}
	mkdir -p $mongo_dbdir
	return 0
}

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

# args: setname set_size host starter_port
# returns by side-effect: two global
#   instance_args, args_per_instance
# returns via stdout: number of args per instance

instance_args=()		# global instance descriptions
args_per_instance=

repSetHosts=''			# list of servers in replica set
repSetAdd=''			# list of servers to add to set

# xxx prior code to go in function: replset_check N -> host ?
function replset_check {	# call with: N   (proposed set size)

	local n even host
	n=${1:-}			# number of names to generate
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
	host=${3:-$( hostname -f )}		# host where daemon runs
	[[ ! "$host" =~ \. ]] &&		# some wifi networks won't
		host+=.local			# qualify and we need that
	# yyy would using localhost avoid problems like ambiguity and
	#     hostname -f malfunctions?
	#host=${3:-localhost}			# host where daemon runs
	# Answer: maybe, but from docs: "Either all host names in a replica
	# set configuration must be localhost references, or none must be"
	echo "$host"
	return 0
}

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

# call with: hostport args...
# args...?
# creates a file as side-effect used for tracking and tearing down instances

function instance_startup {

	local hostport=$1			# set -u aborts if not set
	# yyy why isolate $port at all? because mongo start...
	local port=${hostport##*:}
	shift
	local retstatus=0		# optimist
	local cmd="$me $verbose start $port $*"
	[[ "$verbose" ]] &&
		echo "+ doing \"$cmd\" via port $port" 1>&2
	# start daemon
	# yyy why have another process? because it's not
	# encapsulated in a function, but inlined in case statement
	[[ "$noexec" ]] &&
		cmd="echo + '"$cmd"'" 1>&2
	$cmd || {
		echo "error in \"$cmd\"" 1>&2
		return 1
	}
	# create file we can use later for tracking and teardown
	echo "instance_startup $port $*" > $mongo_proc_base$hostport
}

# call with: hostport [ 'hard-stop' ]

function instance_shutdown {

	local hostport=$1			# set -u aborts if not set
	local port=${hostport##*:}
	local op=${2:-stop}		# stop (default) or hard-stop
	local retstatus=0		# optimist
	local cmd="$me $verbose $op $port"
	[[ "$verbose" ]] &&
		echo "+ doing \"$cmd via port $port"
	[[ "$noexec" ]] &&
		cmd="echo + '"$cmd"'"
	$cmd || {
		echo "error in \"$cmd\"" 1>&2
		return 1
	}
}

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
			# yyy kludgy check for error condition
		fi
		return $retstatus
	}

	local emsg=
	grep --quiet '^{.*"ok":1' <<< "$out" ||		# or error occurred
		error=1
	emsg=$( grep '"error:' <<< "$out" ) &&
		error=1

	[[ "$error" && ! "$r" ]] &&	# if error and user delined messages
		r=MSH			# they're going to get them anyway
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

	local out
	local setsize=1		# something non-zero, used to proceed on error
	out=$( rs_list $rs_conn ) || {
		echo "failed: rs_list $rs_conn" 1>&2
		return 1
	}
	setsize=$( sed -n 's/^\([0-9][0-9]*\).*/\1/p' <<< "$out" )
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
	local hostport=$2		# set -u aborts if not set
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

# start instance, add to replica set, and output new connection string
# setname implied by $mongo_mode, which rs_list requires to be initialized
# creates and adds to a file as side-effect to track replica set states

function rs_add {	# call with: rs_conn hostport start_args

	local rs_conn=$1
	local hostport=$2
	local start_args=$3
	local out setsize
	local retstatus=0		# optimistic

	echo "starting up and adding $hostport" 1>&2
	instance_startup $hostport $start_args ||  {
		echo "rs_add: error in \"instance_startup $port\"" 1>&2
		return 1
	}
	#mongosh "db._adminCommand( {getCmdLineOpts: 1})" $hostport m
	#if [[ $? -eq 0 ]]
	#then
	#	echo "m_out: $m_out"
	#fi
	local snam=$mongo_setname
	# if no error in starting, save to a file


	if [[ ! "$rs_conn" ]]	# first time through, init replica set
	then
		[[ "$verbose" ]] && {
			echo "doing: rs_init $hostport" 1>&2
		}
		rs_init $hostport || {	# eg, still up from prior run
			rs_conn=$( rs_connect_str init $snam $hostport )
			repltest_teardown $rs_conn
			echo "rs_add: rs_init error; you may want to tear" \
				"down old set" 1>&2
			return 1
		}
		rs_conn=$( rs_connect_str init $snam $hostport )
		grs_conn="$rs_conn"	# update global
		# initialize file to track replica set states
		echo "$(date) created with $hostport - $rs_conn" \
			> $mongo_rset_base$snam
	else
		# Connect mongo shell to replica set (NB: no dbname
		# in this particular string):
		# mongo mongodb://10.10.10.15:27001,10.10.10.16:27002,
		#  10.10.10.17:27000/?replicaSet=replicaSet1
		rs_add_instance $rs_conn $hostport || {
			echo rs_add_instance failed on $hostport 1>&2
			return 1
		}
		rs_conn=$( rs_connect_str add $rs_conn $hostport )
		grs_conn="$rs_conn"	# update global
		# add to file to track replica set states
		echo "$(date) added $hostport - $rs_conn" \
			>> $mongo_rset_base$snam
	fi
	#[[ "$verbose" ]] && {
	#	echo "doing: rs_list $rs_conn" 1>&2
	#}
	#rs_list $rs_conn
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
# setname implied by $mongo_mode, which rs_list requires to be initialized
# adds to a file as side-effect to track replica set states

function rs_del {	# call with: rs_conn hostport [ setsize ]

	local rs_conn=$1
	local hostport=$2
	local out setsize stop_op=stop
	local retstatus=0		# optimistic

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
	instance_shutdown $hostport $stop_op || {
		#echo "error: shutdown failed; you might want to run" \
		#	"\"instance_shutdown $hostport\" hard-stop" 1>&2
		#read -t 30 -p "Force shutdown? [y] " ||
		#	echo "Timeout or EOF -- assuming yes" 1>&2
		#[[ "${REPLY:-y}" =~ ^[yY] ]] && {
		#	instance_shutdown $hostport hard-stop ||
		#		echo " - 'hard-stop' failed" 1>&2
		#}
		instance_shutdown $hostport hard-stop || {
			echo " - 'hard-stop' failed" 1>&2
			retstatus=1
		}
	}
	local cmd
	if [[ "$setsize" -gt 2 ]]	# ok, there should be a primary
	then				# that can perform the rs.remove
		cmd="rs_del_instance $rs_conn $hostport"
		[[ "$verbose" ]] &&
			echo  "+ doing $cmd" 1>&2
		$cmd ||
			echo "error: $cmd failed" 1>&2
		rs_conn=$( rs_connect_str del $rs_conn $hostport )
		rs_list $rs_conn
	else				# else there's no primary for that
		rs_conn=$( rs_connect_str del $rs_conn $hostport )
	fi
	# add record to file to track replica set states
	echo "$(date) deleted $hostport - $rs_conn" >> $mongo_rset_base$snam
	echo "rs_conn: $rs_conn"
	return $retstatus
}

# Called via "trap" on receipt of signal for the purpose of doing cleanup
# Args are only passed at trap definition time, so the current state of a
# replica set connection string has to reside in a global, grs_conn.
# call without args.

function repltest_wrapup {
	echo "SIGINT caught: now killing test servers"
	repltest_teardown $grs_conn
}

# clean up by shutting down servers that we started
# call with: rs_conn

function repltest_teardown {

	local rs_conn=$1 stop_op=stop
	local out cmd hostport i instances
	# small optimization: reverse the replica list since primary would
	# otherwise likely be the first
	#instances=( $( command ls $tmongod_proc* | sort -r ) )
	instances=( $( command ls $mongo_proc_base* | sort -r ) )
	local total=${#instances[@]}		# total instances remaining

	echo "tearing down $total-server replica set"
	for i in ${instances[@]}		# for each instance i
	do
		hostport=${i##*_}		# delete to last '_'
		echo "shutting down and removing $hostport"
		out=$( rs_del $rs_conn $hostport ) || {
			echo "error: rs_del $rs_conn $hostport failed" 1>&2
			continue
		}
		rs_conn=$( sed -n 's/^rs_conn: *//p' <<< "$out" )
		grs_conn="$rs_conn"
		rm $i
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

	local n i host port hostport starter_port cmd out

	n=${1:-$def_setsize}		# proposed set size
	[[ ! "$n" || "$n" == '-' ]] &&		# default number of replicas
		n=$def_setsize
	host=$( replset_check $n ) || {
		echo "error: failed replset_check" 1>&2
		return 1
	}

	echo beginning $n-server replica set test
	local rs_conn=			# replica set connection string
	grs_conn=			# global version of the same
	trap repltest_wrapup SIGINT	# trigger cleanup using global

	use_mongo test all		# defines $mongo_first_port, et al.
	starter_port=$mongo_first_port	# base port number where daemon runs
	local snam=$mongo_setname

	i=0
	while [[ $i -lt $n ]]			# generate instances
	do
		port=$(( $starter_port + $i ))
		hostport="$host:$port"

		# Docs: "Make sure the new member’s data directory does not
		# contain data. The new member will copy the data from an
		# existing member."

		use_mongo test $hostport clean	# defines globals for $args

		args="$mongo_dbpath $mongo_dblog $mongo_setname $n"

		out=$( rs_add "$rs_conn" "$hostport" "$args" ) || {
			echo "error in adding \"$hostport\"" 1>&2
			[[ ! "$rs_conn" ]] && {
				rs_conn=$( rs_connect_str init $snam $hostport )
				repltest_teardown $rs_conn
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

	local hostport_list testdb collection db_coll_name
	# extraction step
	hostport_list=$( rs_connect_str hostports $rs_conn )
	testdb=testdb
	collection=testcoll
	db_coll_name="$testdb.$collection"

	local old_rs_conn="$rs_conn"		# save it just in case
	# re-insertion step
	rs_conn=$( rs_connect_str init $snam $hostport_list $testdb )
	grs_conn="$rs_conn"			# update global

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
	};
	while (my $doc = $docs->next) {
		print "$doc->{'fate'}\n";	# save for testing replicas
	}
	# end embedded Perl program
EOT

	# Now call the script, just saved in $perl_add_data, pass in values
	# via command line arguments.
	#
	local retstatus doclen

	out=$( perl -we "$perl_add_data" "$rs_conn" "$db_coll_name" "$fate" )
	retstatus=$?
	doclen=${#fate}		# number of characters in the string $fat
	[[ "$out" != "$fate" ]] && {
		echo "Warning: doc stored (len $doclen) not read from" \
			"replica (len ${#out})"
	}

	local stored_doc
	if [[ $retstatus -eq 0 ]]
	then
		stored_doc=$fate
		echo "test data (length $doclen) = |$stored_doc|"
		#sed 's/^/    /' <<< "$stored_doc"	# indent data
	else
		echo "problem adding test document via $rs_conn"
		echo "$out"
	fi

	#echo Sleep 5 to let data propagate
	#sleep 5

	# now prove that the data was written to each instance

	local instances
	instances=( $mongo_proc_base* )

	for i in ${instances[@]}		# for each instance i
	do
		hostport=${i##*_}		# delete to last '_'
		# database name carried in $rs_conn
		local tries=1 maxtries=5 pause=1

		while [[ $tries -le $maxtries ]]
		do
			# rs.slaveOk() permits reading from secondaries
			out=$( mongo --quiet --eval \
					"rs.slaveOk(); db.$collection.find()" \
					"$hostport/$testdb" ) || {
				echo "problem fetching test docs ($hostport)"
				echo "$out"
				break
			}
			fgrep -sq "$stored_doc" <<< "$out"
			if [[ $? -eq 0 ]]
			then
				echo + replica $hostport has doc copy \
					after $tries tries
				break
			else
				echo + replica $hostport does not have doc \
					copy after $tries tries
				[[ "$verbose" ]] &&
					echo "from find: $out"
			fi
			(( tries++ ))
			sleep $pause
		done
	done

	repltest_teardown $rs_conn
}

# Single port argument required.
# quietly tests if mongod is running, returns via process status
function is_mongo_up () {
	local port=$1
	nohup mongo --port $port < /dev/null > /dev/null 2>&1
}

function rs_status {

	local status pidcount
	pidcount=`netstat -an | grep -c "mongodb.*$port"`
	is_mongo_up $port
	status=$?
	if [[ $status -eq 0 ]]
	then
		echo "OK -- running (mongod, port $port)"
		[[ "$pidcount" -eq 0 ]] &&
			echo "WARNING: but the pidcount is $pidcount?"
		[[ "$verbose" ]] && {
			echo "=== Mongo Configuration ==="
			mongo --port $port --eval "db.serverStatus()"
			echo "=== Mongo Replica Set Configuration  ==="
			mongo --port $port --eval "rs.conf()"
			echo "=== Mongo Replica Set Status  ==="
			mongo --port $port --eval "rs.status()"
		}
			
	else
		echo "NOT running (mongod, port $port)"
		[[ "$pidcount" -ne 0 ]] &&
			echo "WARNING: but the pidcount is $pidcount?"
	fi
	return $status
}

# MAIN

# Pick up whatever SVU mode may be in effect for the caller.
#
svumode=$( sed 's/^[^:]*://' <<< $SVU_USING )
[[ "$svumode" ]] ||
	svumode=cur		# if none, default to "cur"
ap_top=$HOME/sv/$svumode/apache2

#cmd=${1:-}			# the first command word is the operation
#shift			# $1 is now first command arg

verbose=
yes=
noexec=
force=
while [[ "${1:-}" =~ ^- ]]	# $1 starts as the _second_ (post-command) arg
do
	flag="${1:-}"
	case $flag in
	-m*|--m*)
		shift
		mode_arg=${1:-}			# gobble up next arg
		shift
		[[ "$mode_arg" && \
			  ("$mode_arg" == real || "$mode_arg" == test) ]] || {
			echo "error: --mode must be followed by \"test\"" \
					"or \"real\"" 1>&2
			usage
			exit 1
		}
		mongo_mode=$mode_arg		# set global
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

use_mongo $mongo_mode all			# define essential globals

cmd=${1:-help}

case $cmd in

repltest)
	# yyy $setname is an undocumented arg in $3
	setsize=${2:-} setname=${3:-}
	# The repltest function calls back to this function.
	#repltest "$setsize" "$setname"
	repltest "$setsize"
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
help|"")
	usage
	exit
	;;
esac

# If we get here, we're considering commands that require a bunch of standard
# arguments, which we check for next.

# set '-' as default value for first three args
port=${2:--} dbpath=${3:--} dblog=${4:--}
# no default for remaining args
setname=${5:-} setsize=${6:-}

[[ "$cmd" && "$port" && "$dbpath" && "$dblog" ]] || {
	usage
	exit 1
}

use_mongo $mongo_mode $port			# define more global variables

[[ "$port" == '-' ]]	&& port=$mongo_port	# default port
[[ "$cmd" == status ]] && {
	rs_status
	exit
}

# Arguments described in comments
# first arg is action, eg, start, stop
#	--dbpath $mongo_dbpath		# data goes here
#	--logpath $HOME/sv/cur/apache2/logs/mongod_log	# logs go here
#	--port $mongo_port
#	--replSet $mongo_replset	# replica set "rs0"
#	#dbpath logpath port replset

[[ "$port" == '-' ]]	&& port=$mongo_port	# default port
[[ "$dbpath" == '-' ]]	&& dbpath=$mongo_dbpath	# default dbpath
[[ "$dblog" == '-' ]]	&& dblog=$mongo_dblog	# default dblog

# XXX plan to change to using REPLICAS BY DEFAULT
# XXX force 3 replicas default?
replicas=		# default: no replicas
[[ "$setname" ]]	&& replicas="--replSet $setname"

[[ "$cmd" == start1 ]] &&			# if start1 command
	replicas=''				# force no replicas

[[ "$port" =~ ^[0-9][0-9]*$ ]] || {
	echo "error: port ($port) must be a number or '-'"
	exit 1
}
[[ -d $dbpath ]] || mkdir $dbpath || {
	echo "error: cannot create directory $dbpath"
	exit 1
}
flags=(			# inline mongod config file
	--dbpath $dbpath --logpath $dblog --port $port
	$replicas $mongo_other
)

out=
ulimit -n 4096		# set a higher limit than mongod assumes

case $cmd in

start*)				# matches start or start1
	is_mongo_up $port
	if [[ $? -eq 0 ]]
	then
		echo "mongod appears to be up already"
		exit
	fi
	[[ "$verbose" ]] &&
		echo "starting mongod, flags: ${flags[*]}"
	# start in background
	out=$( mongod ${flags[*]} )
	if [[ $? -eq 0 ]]
	then
		echo "mongod OK (port $port) -- started"
		[[ "$verbose" ]] && echo "$out"
		exit 0
	else
		echo "mongod $cmd NOT OK"
		echo "$out"
		exit 1
	fi
	;;

stop|graceful-stop|hard-stop)
	force= stopped=stopped
	[[ "$cmd" == hard-stop ]] && {
		force="{ 'force' : 'true' }"
		stopped=hard-stopped
	}
	cmd=stop
	is_mongo_up $port
	if [[ $? -ne 0 ]]
	then
		echo "mongod (port $port) appears to be down already"
		exit
	fi
	[[ "$verbose" ]] &&
		echo "shutting down server on port $port"
	#try1 try2
	out=$( mongo --port $port \
		--eval "db.shutdownServer($force)" admin )
	if [[ $? -eq 0 ]]
	then
		echo "mongod OK (port $port) -- $stopped"
		[[ "$verbose" ]] && echo "$out"
		exit 0
	else
		echo "problem shutting down mongod (port $port)"
		echo "$out"
		exit 1
	fi
	;;

restart|graceful|hard-restart)
	cmd=restart
	is_mongo_up $port
	if [[ $? -ne 0 ]]
	then
		echo "mongod (port $port) appears to be down"
	else
		[[ "$verbose" ]] &&
			echo "shutting down server on port $port"
		# xxx change echo pipe to --eval opt
		out=$( echo -e "use admin \n db.shutdownServer()" |
			mongo --port $port )
		if [[ $? -eq 0 ]]
		then
			echo "mongod OK (port $port) -- stopped"
		else
			echo "mongod shutdown NOT OK"
			echo "$out"
		fi
	fi
	sleep 1		# pause seems to help here under Linux
	[[ "$verbose" ]] &&
		echo "restarting mongod, flags: ${flags[*]}"
	mongod ${flags[*]} > /dev/null	# start in background
	if [[ $? -eq 0 ]]
	then
		echo "mongod OK (port $port) -- restarted"
		[[ "$verbose" ]] && echo "$out"
		exit 0
	else
		echo "mongod $cmd NOT OK"
		exit 1
	fi
	;;

status)
	rs_status "$@"
	exit
	;;
#	pidcount=`netstat -an | grep -c "mongodb.*$port"`
#	is_mongo_up $port
#	status=$?
#	if [[ $status -eq 0 ]]
#	then
#		echo "OK -- running (mongod, port $port)"
#		[[ "$pidcount" -eq 0 ]] &&
#			echo "WARNING: but the pidcount is $pidcount?"
#		[[ "$verbose" ]] && {
#			echo "=== Mongo Configuration ==="
#			mongo --port $port --eval "db.serverStatus()"
#			echo "=== Mongo Replica Set Configuration  ==="
#			mongo --port $port --eval "rs.conf()"
#			echo "=== Mongo Replica Set Status  ==="
#			mongo --port $port --eval "rs.status()"
#		}
#			
#	else
#		echo "NOT running (mongod, port $port)"
#		[[ "$pidcount" -ne 0 ]] &&
#			echo "WARNING: but the pidcount is $pidcount?"
#	fi
#	exit $status

*)
	[[ "$cmd" ]] &&
		echo "$me: $cmd: unknown argument"
	usage
	#echo "Use one of these as an argument:" \
	#	"status, start[1], stop, restart, or repltest."
	exit 1
	;;
esac

