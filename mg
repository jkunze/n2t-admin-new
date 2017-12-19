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

function repltest {

	local n=$1 setname=$2		# setsize and setname
	[[ "$n" == '-' ]] &&		# default number of replicas
		n=5
	[[ "$setname" == '-' ]] &&	# default replica set name
		setname=$tmongo_replset
	local max=20			# max number of replicas
	[[ $n == clean ]] && {		# XXXX do this
		# to purge replica set config completely (leaving user
		# database), restart each instance/daemon without --replSet
		# option (and on different port?) and drop the
		# local.system.replset collection
		#     mongo local --eval "db.system.replset.drop()"
		# see http://serverfault.com/questions/424465/how-to-reset-mongodb-replica-set-settings
		echo rm -fr $tmongo_dbdir
		rm -fr $tmongo_dbdir	# XXX far too crude? better above?
		return
	}
	# XXX drop the above given that we clean up before every run?
	echo REMOVING OLD REPLICA SET
	echo rm -fr $tmongo_dbdir
	rm -fr $tmongo_dbdir	# XXX far too crude? better above?
	if [[ ! "$n" =~ ^[0-9][0-9]*$ || $n -ge $max || $n -lt 1 ]]
	then
		echo "error: replica count ($n) should be 'clean' or an odd" \
			"positive integer < $max"
		return 1
	fi

	mkdir -p $tmongo_dbdir
	local port out args instance host
	host=$( hostname -f )		# host where daemon will run
	local repSetHosts=''		# list of servers in replica set
	local members=''		# server members of replica set

	echo Starting $n servers with --replSet $setname
	local i=1
	while [[ $i -le $n ]]	# start up all replicas
	do
		(( port=$tmongo_port + $i ))
		dbpath=$tmongo_dbdir/d$i
		args="$port $dbpath $tmongo_dblog $tmongo_replset $n"
		[[ "$verbose" ]] &&
			echo "Instance $i: $me start $args"
		$me start $args		# start daemon
		instance="$host:$port"
		repSetHosts+=",$instance"	# push onto replica list
		#[[ $i -ne $n ]] &&		# if not final, push onto
		#	repSetAdd+=";rs.add('$instance')"	# add list
		repSetAdd+=";rs.add('$instance')"	# add to list
		(( i++ ))
	done

	# At this point, $port is the port number of the final instance
	# (all on localhost right now). Now initiate the replica set by
	# connecting to that final instance and running rs.initiate().
	#
	local final=$port rsinit

	#members+="
	#	{'_id' : $j, 'host' : '$instance', 'stateStr' : 'PRIMARY'},"
	#rsinit="rs.initiate({ '_id' : '$setname', 'members' : [ $members ] })"

	echo "Doing rs.initiate() on server at $host:$final"
	out=$( mongo --port $final --eval "rs.initiate()" )
	out_if $? error "$out"
	[[ "$verbose" ]] && {
		echo "rs.intiate():"
		echo "$out"
	}

	echo "Doing rs.add(...) $n times"
	[[ "$verbose" ]] &&	echo "$repSetAdd"
	out=$( mongo --port $final --eval "$repSetAdd" )
	out_if $? error "$out"
	[[ "$verbose" ]] && {
		echo "$repSetAdd:"
		echo "$out"
	}

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
tmongo_dbpath=
tmongo_dblog=$tmongo_dbdir/log
tmongo_replset=rst			# test replica set name
tmongo_port=47017			# 20K more than standard port
tmongo_other="$mongo_other"

# Single port argument required.
# quietly tests if mongod is running, returns via process status
function is_mongo_up () {
	local port=$1
	nohup mongo --port $port < /dev/null > /dev/null 2>&1
}

# Arguments described in comments
# first arg is action, eg, start, stop
#	--dbpath $mongo_dbpath		# data goes here
#	--logpath $HOME/sv/cur/apache2/logs/mongod_log	# logs go here
#	--port $mongo_port
#	--replSet $mongo_replset	# replica set "rs0"
#	#dbpath logpath port replset
function mongodaemon () {
	local cmd=$1
	if [[ "$cmd" == repltest ]]
	then
		# yyy $setname is an undocumented arg in $3
		local setsize=$2 setname=$3
		# The repltest function calls back to this function.
		repltest "$setsize" "$setname"
		return
	fi
	local port=$2 dbpath=$3 dblog=$4 setname=$5 setsize=$6
	[[ "$cmd" && "$port" && "$dbpath" && "$dblog" ]] || {
		echo "error: usage:" \
			"mongodaemon cmd port dbpath dblog [replsetname [n]]"
		return 1
	}

	[[ "$port" == '-' ]]	&& port=$mongo_port	# default port
	[[ "$dbpath" == '-' ]]	&& dbpath=$mongo_dbpath	# default dbpath
	[[ "$dblog" == '-' ]]	&& dblog=$mongo_dblog	# default dblog

	# XXX plan to change to using REPLICAS BY DEFAULT
	local replicas=		# default: no replicas
	[[ "$setname" ]]	&& replicas="--replSet $setname"

	[[ "$cmd" == start1 ]] &&			# if start1 command
		replicas=''				# force no replicas

	[[ "$port" =~ ^[0-9][0-9]*$ ]] || {
		echo "error: port ($port) must be a number or '-'"
		return 1
	}
	[[ -d $dbpath ]] || mkdir $dbpath || {
		echo "error: cannot create directory $dbpath"
		return 1
	}
	local flags=(			# inline mongod config file
		--dbpath $dbpath --logpath $dblog --port $port
		$replicas $mongo_other
	)

	local out=
	ulimit -n 4096		# set a higher limit than mongod assumes

	case $cmd in
	start*)				# matches start or start1
		is_mongo_up $port
		if [[ $? -eq 0 ]]
		then
			echo "mongod appears to be up already"
			return
		fi
		# start in background
		out=$( mongod ${flags[*]} )
		if [[ $? -eq 0 ]]
		then
			echo "mongod OK (port $port) -- started"
			return 0
		else
			echo "mongod $cmd NOT OK"
			echo "$out"
			return 1
		fi
		;;

	stop|graceful-stop|hard-stop)
		local force= stopped=stopped
		[[ "$cmd" == hard-stop ]] && {
			force="{ 'force' : 'true' }"
			stopped=hard-stopped
		}
		cmd=stop
		is_mongo_up $port
		if [[ $? -ne 0 ]]
		then
			echo "mongod (port $port) appears to be down already"
			return
		fi
		#local try1 try2
		out=$( mongo --port $port \
			--eval "db.shutdownServer($force)" admin )
		if [[ $? -eq 0 ]]
		then
			echo "mongod OK (port $port) -- $stopped"
			[[ $verbose ]] && echo "$out"
			return 0
		else
			echo "problem shutting down mongod (port $port)"
			echo "$out"
			return 1
		fi
		;;

	restart|graceful|hard-restart)
		cmd=restart
		is_mongo_up $port
		if [[ $? -ne 0 ]]
		then
			echo "mongod (port $port) appears to be down"
		else
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
		mongod ${flags[*]} > /dev/null	# start in background
		if [[ $? -eq 0 ]]
		then
			echo "mongod OK (port $port) -- restarted"
			return 0
		else
			echo "mongod $cmd NOT OK"
			return 1
		fi
		;;

	status)
		pidcount=`netstat -an | grep -c "mongodb.*$port"`
		is_mongo_up $port
		local status=$?
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
		;;

	*)
		[[ "$cmd" ]] &&
			echo "mong: $cmd: unknown argument"
		echo "Use one of these as an argument:" \
			"status, start[1], stop, restart, or repltest."
		return 1
		;;

	esac
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
		verbose=1
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
	setsize=${2:--} setname=${3:--}
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
	# start in background
	out=$( mongod ${flags[*]} )
	if [[ $? -eq 0 ]]
	then
		echo "mongod OK (port $port) -- started"
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
	#try1 try2
	out=$( mongo --port $port \
		--eval "db.shutdownServer($force)" admin )
	if [[ $? -eq 0 ]]
	then
		echo "mongod OK (port $port) -- $stopped"
		[[ $verbose ]] && echo "$out"
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
	mongod ${flags[*]} > /dev/null	# start in background
	if [[ $? -eq 0 ]]
	then
		echo "mongod OK (port $port) -- restarted"
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
		echo "mg: $cmd: unknown argument"
	echo "Use one of these as an argument:" \
		"status, start[1], stop, restart, or repltest."
	exit 1
	;;
esac

