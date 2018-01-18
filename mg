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
	set_name=${1:-$tmongo_replset}	# number of names to generate
	n=${2:-$def_set_size}		# number of names to generate
	[[ "$n" == '-' ]] &&		# default number of replicas
		n=5
	max=20				# max number of replicas
	# $n is even if $even == $n; $even == 0 if $n isn't a number
	(( even=( "$n" / 2 * 2 ) ))		# or $n == 1
	if [[ $even -eq 0 || $n -eq $even || $n -lt 0 || $n -ge $max ]]
	then
		echo "error: replica count ($n) should be an odd" \
			"integer < $max and > 1" 1>&2
		return 1
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
		repSetHosts+=",$hostport"		# push on replica list
		repSetAdd+=";rs.add('$hostport')"	# add to "add" list
		(( i++ ))
	done
	args_per_instance=${#instance[@]}
	return
}

# call with one arg: rs_port

function rs_init {

	local rs_port=$1
	local retstatus=0		# optimist
	[[ "$verbose" ]] &&
		echo "Doing rs.initiate() on via port $rs_port"
	out=$( echo mongo --port $final --eval "rs.initiate()" )
	retstatus=$?
	out_if $retstatus error "$out"
	[[ "$verbose" ]] && {
		echo "rs.initiate():"
		echo "$out"
	}
	return $retstatus
}

# call with two args: rs_port, rs_name, hostport
# $rs_port is port number of local daemon that our client is talking to
# (always the one that we called rs.initiate on, at least for first "add"?)
# $hostport is what we're operating on

function rs_add {

	local rs_port=$1
	local hostport=$2
	local retstatus=0		# optimist

	[[ "$verbose" ]] && {
		echo "removing $tmongo_dbdir/data_$rs_port/*"
		echo contacting port $rs_port to add $hostport
	}
	# Docs: "Make sure the new member’s data directory does not contain
	# data. The new member will copy the data from an existing member."
	rm -fr $tmongo_dbdir/data_$rs_port
	mkdir -p $tmongo_dbdir/data_$rs_port

	out=$( echo mongo --port $rs_port --eval "rs.add('$hostport')" )
	retstatus=$?
	out_if $restatus error "$out"
	[[ "$verbose" ]] &&
		echo "$out"
	return $retstatus
}

function rs_del {

	local rs_port=$1
	local hostport=$2
	local retstatus=0		# optimist

	[[ "$verbose" ]] &&
		echo contacting port $rs_port to remove $hostport
	out=$( echo mongo --port $rs_port --eval "rs.remove('$hostport')" )
	retstatus=$?
	out_if $restatus error "$out"
	[[ "$verbose" ]] &&
		echo "$out"
	return $retstatus
}

function repltest {

	local n=${1:-$def_set_size}		# proposed set size
	local setname=${2:-$tmongo_replset}	# set name

	# next call inits $instance_args, $repSetAdd, and $repSetHosts
	replset_gen_params $setname "$n" || {
		echo "error: could not generate instance names" 1>&2
		return 1
	}
	# If we get here, results are in the instance_args array, a 2-d
	# array projected onto a 1-d array, which we use to start instances.

#	echo REMOVING OLD REPLICA SET
#	echo rm -fr $tmongo_dbdir
#	rm -fr $tmongo_dbdir		# yyy too crude? more of realclean?
#	mkdir -p $tmongo_dbdir

	local set_size
	(( set_size=" ${#instance_args[@]} / $args_per_instance " ))

	local out args hostport host port
	local arg2 rest
	(( rest=" $args_per_instance - 1 " ))	# number of args to consume

	echo Starting $n servers with --replSet $setname
	local i=0 cmd
	while [[ $i -lt ${#instance_args[@]} ]]
	do
		hostport=${instance_args[$i]}
		port=${hostport##*:}		# delete up to last colon
		host=${hostport%:*}		# colon and beyond
		#echo hostport $hostport, port $port
		(( arg2=" $i + 1 " ))
		args="${instance_args[@]:$arg2:$rest}"
		#args="$port $dbpath $tmongo_dblog $tmongo_replset $set_size"

		cmd="$me $verbose start $port $args"
		(( i+= $args_per_instance ))
		# start daemon
		# yyy why have another process? because it's not
		# encapsulated in a function, but inlined in case statement
		echo echo $me $verbose start $port $args || {
			echo "error in \"$cmd\"" 1>&2
			continue
		}
		# if no error in starting, save to a file
		echo $cmd > $tmongod_proc$port
	done

	# After exiting the above loop, $port is the port number of the final
	# instance (all on localhost right now). Now initiate the replica set
	# by connecting to that final instance and running rs.initiate().
	#
	local rsinit final=$port

	#members+="
	#	{'_id' : $j, 'host' : '$instance', 'stateStr' : 'PRIMARY'},"
	#rsinit="rs.initiate({ '_id' : '$setname', 'members' : [ $members ] })"

# yyy write re-usable routine to initiate rs?
# yyy get it to inherit $verbose setting
	rs_init $final ||
		return 1

	# determine current master and add a member
	rs_add $rsetname $hostport || {
		echo complain
		xxxcleanup
		return 1
	}
	# actually -- determine current master before adding each member


# xxx write routine to add one at a time (re-usable in real life)
# yyy get it to inherit $verbose setting
# xxx write routine to remove one at a time (re-usable in real life)
# yyy get it to inherit $verbose setting
	echo "Doing rs.add(...) $n times"
echo repSetAdd $repSetAdd
	[[ "$verbose" ]] &&	echo "$repSetAdd"
	out=$( echo mongo --port $final --eval "$repSetAdd" )
	out_if $? error "$out"
	[[ "$verbose" ]] && {
		echo "$repSetAdd:"
		echo "$out"
	}

exit
# XXX need to save repsetURL too

	[[ "$verbose" ]] && {
		echo === Replica set status after adding replicas ===
		mongo --port $final --eval "rs.status()"
	}

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
	#     and error message even though the connection seems to succeed
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
tmongod_proc=$tmongo_dbdir/proc_port=		# mongod process file
tmongo_dbpath=
tmongo_dblog=$tmongo_dbdir/log
tmongo_replset=rst			# test replica set name
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
no_exec=
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
		no_exec=1
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

