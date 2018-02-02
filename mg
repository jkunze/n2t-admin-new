#!/bin/bash

set -u

notify=jak@ucop.edu	# xxx backup, sysupdate, or other failure
me=$( basename $0 )
function usage {

summary="
       # $me [-v] [status | [hard-]stop | [re]start | start1 | repltest [N]]
xxx cmd port dbpath dblog [replsetname [n]]
       $me build Dir
"
	cat << EOT

SYNOPSIS                          ($0)
       $me - mongodb service builder

USAGE $summary

DESCRIPTION
       The $me tool performs various setup tasks for MongoDB
       clents and servers running under the "svu" service version that is
       currently in effect (or "cur" if none -- type "svu" for details).
       The -v option makes it more verbose for some forms.  A non-zero
       exit status indicates an error.

       The "build" form creates a mongo database in directory, Dir,
       establishing configuration and log files there.

EXAMPLES
       $me build apache2/exdb [ Nreplicas ]
       $me [re]start apache2/exdb
       $me stop apache2/exdb

SUMMARY $summary

EOT
}

rsetname_default=rset

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

# args: set_name set_size host starter_port
# returns by side-effect: two global
#   instance_args, args_per_instance
# returns via stdout: number of args per instance

instance_args=()		# global instance descriptions
args_per_instance=

repSetHosts=''			# list of servers in replica set
repSetAdd=''			# list of servers to add to set

function replset_gen_params {

	local set_name n max even i host starter_port
	set_name=${1:-$tmongo_replset}	# replica set name
	n=${2:-$def_set_size}		# number of names to generate
	[[ "$n" == '-' ]] &&		# default number of replicas
		n=5
	max=20				# max number of replicas
	# $n is even if $even == $n; $even == 0 if $n isn't a number
	(( even=( "$n" / 2 * 2 ) ))		# or $n == 1
	if [[ $even -eq 0 || $n -eq $even || $n -lt 0 || $n -ge $max ]]
	then
		[[ $n -ne 1 ]] && {
			echo "error: replica count ($n) should be an odd" \
				"integer < $max and > 1" 1>&2
			return 1
		}
		# if we get here, $n -eq 1, which we allow under caution
		echo "replica count 1 (no replicas) -- baseline testing" 1>&2
	fi
	host=${3:-$( hostname -f )}	# host where daemon runs
	starter_port=${4:-$tmongo_port}		# base port where daemon runs

	local instance port hostport
	i=1
	while [[ $i -le $n ]]			# generate instances
	do
		port=$(( $starter_port + $i ))
		hostport="$host:$port"
		instance=(
			"$hostport"		# first elem MUST be host:port
			"$tmongo_dbdir/data_$port"	# data dbpath for $port
			"$tmongo_dblog"		# log file
			"$set_name"		# replica set name
			"$n"			# replica set size
		)		# save instance so we can return its size
		# eg, 5 lines => every 5 array elements describes an instance
		# all elements but first are passed to $me after stop||start
		# First element must always be host:port combination.

		instance_args+=( "${instance[@]}" )
		(( i++ ))
	done
	args_per_instance=${#instance[@]}
	return
}

# call with: port args...
# args...?

function instance_startup {

	# yyy why isolate $port at all?
	local port=$1			# set -u aborts if not set
	shift
	local retstatus=0		# optimist
	local cmd="$me $verbose start $port $*"
	[[ "$verbose" ]] &&
		echo "+ doing \"$cmd via port $port"
	# start daemon
	# yyy why have another process? because it's not
	# encapsulated in a function, but inlined in case statement
	[[ "$noexec" ]] &&
		cmd="echo + '"$cmd"'"
	$cmd || {
		echo "error in \"$cmd\"" 1>&2
		return 1
	}
}

# call with: hostport|port [ 'hard-stop' ]

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
# returns output via MSH_out global variable
# also returns broken-out values in {returnvar}_* if returnvar present

function mongosh {

	local op=$1
	local rs_conn=$2
	local r=${3:-}
	local out json retstatus error=

	# JSON.stringify has two virtues: (a) it makes the JSON parsable to
	# the jq tool and (b) puts it all on one line, making it possible to
	# filter out connection messages and diagnostics.

	out=$( mongo --eval "JSON.stringify($op)" $rs_conn ) || {
		retstatus=$?
		echo "mongosh: error invoking JSON.stringify($op) on $rs_conn"
		if [[ "$verbose" ]]
		then
			sed 's/^/  /' <<< "$out" 1>&2
		else
			# next line is supposed to pull out error messages from
			# sometimes copious warnings and informational messages
			grep '^....-..-..T..:..:......-.... E ' <<< "$out"
			# yyy kludgy check for error condition
		fi
		return $retstatus
	}

	local emsg=
	MSH_out="$out"			# this global return always set yyy?
	grep --quiet '^{.*"ok":1' <<< "$out" ||		# or error occurred
		error=1
	emsg=$( grep '"error:' <<< "$out" ) &&
		error=1

	[[ "$error" && ! "$r" ]] &&	# if error and user delined messages
		r=MSH			# they're going to get them anyway
	[[ ! "$r" ]] &&			# set on error or if user requests
		return 0

	# If we get here, we take time to break out values into shell vars.

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
		@sh \"${r}_hosts=( \(.hosts) )\"
	" <<< "$json" )
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
	#local rsetname=${1:--}
	#[[ $rsetname == '-' ]] &&
	#	rsetname=$rsetname_default
	#local port=${hostport##*:}	# delete up to last ':'
	local retstatus=0		# optimist
	[[ "$verbose" ]] &&
		echo "+ doing rs.initiate() via $hostport"
	#out=$( mongo --port $port --eval "rs.initiate()" )
	mongosh "rs.initiate()" $hostport m
	retstatus=$?
	#out_if $retstatus error "$out"
	[[ "$verbose" ]] && {
		echo "+ $out"
	}
	return $retstatus
}

# puts hostport of replica set primary on stdout and messages on stderr
# call with: rs_conn
#	{'_id' : $j, 'host' : '$instance', 'stateStr' : 'PRIMARY'},"

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

# puts ','-separated list of replicas on stdout, with primary first
# call with: rs_conn
#	{'_id' : $j, 'host' : '$instance', 'stateStr' : 'PRIMARY'},"

function rs_list {
	local rep rs_conn=$1
	mongosh "db.isMaster()" $rs_conn m
	if [[ $? == 0 ]]
	then
		echo "+ replicas:" $( sed -e 's| |,|g' \
			-e "s|\(${m_primary:-null}\)|*\1|" <<< "${m_hosts[@]}" )
	else		# yyy not even checking $m_ok
		echo "error in mongo db.isMaster"
	fi
	return 0
}

# add replica instance
# call with: rs_conn hostport

function rs_add {

	local rs_conn=$1
	local hostport=$2		# set -u aborts if not set
	#local port=${hostport##*:}	# delete up to last ':'
	local retstatus=0		# optimist

	local out
	#out=$( mongo --port $port --eval "rs.add('$hostport')" )
	#local op="JSON.stringify(rs.add('$hostport'))"
	#out=$( mongo --eval "$op" $rs_conn | grep '^{' )
	mongosh "rs.add('$hostport')" $rs_conn m
	retstatus=$?
	#out_if $retstatus error "$MSH_out"
	[[ "$verbose" ]] &&
		sed 's/^/  /' <<< "$MSH_out"
	return $retstatus
}

# must shutdown instance before you do rs.remove(hostport)
function rs_del {	# call with: rs_conn hostport

	local rs_conn=$1
	local hostport=$2		# set -u aborts if not set
	local retstatus=0		# optimist

	mongosh "rs.remove('$hostport')" $rs_conn m
	retstatus=$?
	[[ "$verbose" ]] &&
		sed 's/^/  /' <<< "$m_out"
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

	local rs_conn=$1 cmd hostport
	local i iport			# an instance and its port
	local stop_op=stop

	local instances
	# small optimization: reverse the replica list since primary would
	# otherwise likely be the first
	instances=( $( command ls $tmongod_proc* | sort -r ) )
	local total=${#instances[@]}		# total instances remaining

	echo "beginning teardown of $total servers"
	for i in ${instances[@]}		# for each instance i
	do
		# yyy ignoring host part of host:port
		hostport=${i##*_}		# delete to last '_'
		iport=${i##*:}			# delete to last ':'
		[[ $total -eq 2 ]] && {
			echo "fewer than 3 instances requires hard-stop"
			stop_op=hard-stop
		}
		# NB: must shutdown instance before removing from replica set
		instance_shutdown $iport $stop_op || {
			echo "error in \"instance_shutdown $iport\""
			read -t 30 -p "Force shutdown? [y] " ||
				echo "Timeout or EOF -- assuming yes"
			[[ "${REPLY:-y}" =~ ^[yY] ]] && {
				instance_shutdown $iport hard-stop ||
					echo " - 'hard-stop' failed"
			}
			continue
		}
		if [[ $total -gt 2 ]]		# otherwise there's no primary
		then				# that can perform rs.remove
			cmd="rs_del $rs_conn ${i##*_}"
			[[ "$verbose" ]] &&
				echo  "+ doing $cmd"
			$cmd ||
				echo "error: $cmd failed"
			rs_conn=$( rs_connect_str del $rs_conn $hostport )
			grs_conn="$rs_conn"	# update global
			rs_list $rs_conn
		else
			rs_conn=$( rs_connect_str del $rs_conn $hostport )
			grs_conn="$rs_conn"	# update global
		fi
		rm $i
		(( total-- ))
	done
}

repSetOpts=				# replica set connection string options
repSetOpts+="socketTimeoutMS=30000&"	# wait up to 30 secs for reply
#repSetOpts+="socketTimeoutMS=45000&"	# wait up to 45 secs for reply
# XXX commented out maxTimeMS setting for now because it triggers
#     an error message even though the connection seems to succeed
#     The perl module docs say this is an important attribute to
#     set, so we want to uncomment this next line when we figure
#     out what's wrong (eg, a module bug gets fixed?)
#repSetOpts+="maxTimeMS=15000&"		# wait up to 15 secs to do DB command
			# NB: maxTimeMS must be shorter than socketTimeoutMS
#repSetOpts+="readPreference=$readpref&"	# replica to read from

# args either: init setname hostport [ dbname ]
# args or:     add|del connstr hostport

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
		hostport=$3
		dbname=${4:-}
		# NB: options MUST precede replicaSet=foo, which must terminate
		# the string.
		rs_conn="mongodb://$hostport/$dbname?$repSetOpts"
		rs_conn+="replicaSet=$setname"
		echo "$rs_conn"
		return 0
		;;
	*)
		echo "error: rs_connect_str usage: command hostport ..." 1>&2
		return 1
		;;
	esac
}

function repltest {

	local n=${1:-$def_set_size}		# proposed set size
	local snam=${2:-$tmongo_replset}	# set name

	# next call inits $instance_args
	replset_gen_params $snam "$n" || {
		echo "error: could not generate instance names" 1>&2
		return 1
	}
	# If we get here, results are in the instance_args array, a 2-d
	# array projected onto a 1-d array, which we use to start instances.

	local set_size
	(( set_size=" ${#instance_args[@]} / $args_per_instance " ))

	local out args hostport host port
	local arg2 rest
	(( rest=" $args_per_instance - 1 " ))	# number of args to consume

	echo Starting $n servers
	#echo Starting $n servers with --replSet $snam
	local i=0 cmd rset

	local rs_conn=			# replica set connection string
	grs_conn=			# global version of the same
	trap repltest_wrapup SIGINT	# trigger cleanup using global

	while [[ $i -lt ${#instance_args[@]} ]]
	do
		hostport=${instance_args[$i]}
		port=${hostport##*:}		# delete up to last colon
		host=${hostport%:*}		# colon and beyond
		#echo hostport $hostport, port $port
		(( arg2=" $i + 1 " ))
		args="${instance_args[@]:$arg2:$rest}"
		#args="$port $dbpath $tmongo_dblog $tmongo_replset $set_size"

		[[ "$verbose" ]] && {
			echo "+ purging files $tmongo_dbdir/data_$port/*"
		}
		# Docs: "Make sure the new member’s data directory does not
		# contain data. The new member will copy the data from an
		# existing member."
		rm -fr $tmongo_dbdir/data_$port
		mkdir -p $tmongo_dbdir/data_$port
# yyy ?need to remove all server data dirs before starting in case previous
#     run failed and left things in a bad state?

		instance_startup $port $args ||  {
			echo "error in \"instance_startup $port\"" 1>&2
			continue
		}
		# if no error in starting, save to a file
		echo "instance_startup $port $args" > $tmongod_proc$hostport

		if [[ $i == 0 ]]	# first time through, init replica set
		then
			rs_init $hostport ||
				return 1
			rs_conn=$( rs_connect_str init $snam $hostport )
			grs_conn="$rs_conn"	# update global
			rs_list $rs_conn
		else
			# Connect mongo shell to replica set (NB: no dbname
			# in this particular string):
			# mongo mongodb://10.10.10.15:27001,10.10.10.16:27002,
			#  10.10.10.17:27000/?replicaSet=replicaSet1
			rs_add $rs_conn $hostport || {
				echo rs_add failed on $hostport
			}
			rs_conn=$( rs_connect_str add $rs_conn $hostport )
			grs_conn="$rs_conn"	# update global
			rs_list $rs_conn
		fi
		(( i+=$args_per_instance ))
	done


	[[ "$verbose" ]] && {
		echo === Replica set status after adding replicas ===
		mongo --eval "rs.status()" $rs_conn	# old way has virtues
		#mongosh "rs.status()" $rs_conn m ; echo "json: $m_json"
	}

repltest_teardown $rs_conn
exit

	# yyy need to pause really?
	local s=2	# number of seconds to pause while replicas wake up
	echo Sleep $s seconds to let servers stand up...
	sleep $s

	# To add data, construct the connection string, repSetURL.
	#
	local readpref=nearest
	#local readpref=primaryPreferred
	local repSetURL='mongodb://'	# build replica set URL in pieces
	repSetURL+=${repSetHosts/,/}	# strip initial comma from set list
	repSetURL+="/?replicaSet=$tmongo_replset"	# specify set name
	repSetURL+="&socketTimeoutMS=30000"	# wait up to 30 secs for reply
	# XXX commented out maxTimeMS setting for now because it triggers
	#     an error message even though the connection seems to succeed
	#     The perl module docs say this is an important attribute to
	#     set, so we want to uncomment this next line when we figure
	#     out what's wrong (eg, a module bug gets fixed?)
	#repSetURL+="&maxTimeMS=15000"	# wait up to 15 secs to do DB command
			# NB: maxTimeMS must be shorter than socketTimeoutMS
	repSetURL+="&readPreference=$readpref"	# replica to read from

	# generate data ($fate) containing date to get different data each run
	local fate="timely data $( date )"
	local perl_add_data
	read -r -d '' perl_add_data << 'EOT'

	# start embedded Perl program
	# takes two arguments: connection_string and test data_string
	use 5.010;
	use strict;
	use MongoDB;
	use Try::Tiny;		# for exceptions
	use Safe::Isa;		# provides $_isa
	# use Try::Tiny::Retry	# yyy (one day) for automatic retries

	my $connection_string = $ARGV[0] || '';
	my $data_string = $ARGV[1] || '';
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
	my ($pfx, $docs);
	try {
		$pfx = $client->ns("test.prefixes");	# "prefixes" collection
		$pfx->insert({ name => "JDoe", fate => "$data_string" });
		$docs = $pfx->find();
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
	echo Connecting to $repSetURL
	out=$( perl -we "$perl_add_data" "$repSetURL" "$fate" )
	local doclen=${#fate}
	[[ "$out" != "$fate" ]] && {
		echo "Warning: doc stored (len $doclen) not read from" \
			"$readpref replica (len ${#out})"
	}

	local stored_doc
	if [[ $? -eq 0 ]]
	then
		stored_doc=$fate
		echo "Test document data of length $doclen added:"
		sed 's/^/    /' <<< "$stored_doc"	# indent data
	else
		echo "problem adding test document via $repSetURL"
		echo "$out"
	fi

	[[ "$verbose" ]] && {
		echo === Replica set status after inserting document ===
		mongo --port $final --eval "rs.status()"
	}

	echo Sleep 5 to let data propagate
	sleep 5
	# now stop each replica after proving data written to each one
	i=1; while [[ $i -le $n ]]
	do
		(( port=$tmongo_port + $i ))
# xxx prefixes?
		out=$( mongo --port $final --quiet \
			--eval "db.prefixes.find()" test )

		if [[ $? -eq 0 ]]
		then
			fgrep -sq "$stored_doc" <<< "$out"
			if [[ $? -eq 0 ]]
			then
				echo -n "Replica $port has doc copy, "
			else
				echo -n "Replica $port does not" \
					"have doc copy, "
			fi
		else
			echo "problem fetching test docs (port $final)"
			echo "$out"
		fi

		dbpath=$tmongo_dbdir/d$i
		#args="$port $dbpath $tmongo_dblog $tmongo_replset $n"
		args="$port $dbpath $tmongo_dblog"
		[[ "$verbose" ]] &&
			echo "Instance $i: $me stop $args"
		# We don't need most of those args for "stop" except $port,
		# but we supply them to satisfy $me syntax checker.
		#
		out=$( $me stop $args )
		if [[ $? -ne 0 ]]
		then
			echo error: problem stopping server with \
				$me stop $args:
			echo "$out"
			echo Trying hard-stop
			out=$( $me hard-stop $args )
			if [[ $? -ne 0 ]]
			then
				echo error: problem stopping server
				echo "$out"
				echo Giving up
			else
				echo "$out"
			fi
		else
			echo "$out"
		fi
		(( i++ ))
	done
	# yyy now purge replica set config completely?
}

# Mongo database settings
#
#mongo_dbpath=$HOME/sv/cur/apache2/pfx
mongo_dbdir=$HOME/sv/cur/apache2/mongo_dbdir		# XXX not used!
mongo_dbpath=$mongo_dbdir				# data goes here
mongo_dblog=$HOME/sv/cur/apache2/logs/mongod_log	# logs go here
mongo_port=27017					# daemon port
mongo_replset=rs0					# replica set name
mongo_other="--fork --logappend"			# other flags
mongo_other+=" --storageEngine wiredTiger"
#--bind_ip 'localhost,172.31.23.24'	# no space after comma
#--rest		# deprecated since 3.2: admin UI: http://localhost:28017

# Test Mongo database settings
#
tmongo_dbdir=$HOME/sv/cur/apache2/tmongod
tmongod_started=$tmongo_dbdir/../tmongod_started	# yyy needed?
tmongod_proc=$tmongo_dbdir/proc_	# mongod process file base
tmongo_dbpath=
tmongo_dblog=$tmongo_dbdir/log
tmongo_replset=rstest			# test replica set name
tmongo_port=47017			# 20K more than standard port
tmongo_other="$mongo_other"

def_set_size=5			# default set size yyy repeated

# Single port argument required.
# quietly tests if mongod is running, returns via process status
function is_mongo_up () {
	local port=$1
	nohup mongo --port $port < /dev/null > /dev/null 2>&1
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
while [[ "${1:-}" =~ ^- ]]	# $1 starts as the _second_ (post-command) arg
do
	case $1 in
	-v*|--v*)
		verbose='--v'
		# doubles as "True" and value inherited by sub-processes
		shift
		;;
	-y)
		yes=1
		shift
		;;
	-n)
		noexec=1
		shift
		;;
	*)
		echo "Error: unknown option: $1"
		usage
		exit 1
	esac
done

cmd=${1:-help}

case $cmd in

repltest)
	# yyy $setname is an undocumented arg in $3
	setsize=${2:-} setname=${3:-}
	# The repltest function calls back to this function.
	repltest "$setsize" "$setname"
	exit
	;;

help|"")
	usage
	exit
	;;
esac

# set '-' as default value for first three args
port=${2:--} dbpath=${3:--} dblog=${4:--}
# no default for remaining args
setname=${5:-} setsize=${6:-}

[[ "$cmd" && "$port" && "$dbpath" && "$dblog" ]] || {
	usage
	exit 1
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
		echo "starting mongod, flags: ${flags[*]"
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
		echo "restarting mongod, flags: ${flags[*]"
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
	exit $status
	;;

*)
	[[ "$cmd" ]] &&
		echo "$me: $cmd: unknown argument"
	echo "Use one of these as an argument:" \
		"status, start[1], stop, restart, or repltest."
	exit 1
	;;
esac

