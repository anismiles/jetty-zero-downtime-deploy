#!/bin/bash
#
# jetty_deploy.sh start_new: starts a new Jetty server on an unused port (either 8080 or 8081)
# jetty_deploy.sh stop_previous: stops the Jetty running in the opposite port of the "current" Jetty
# jetty_deploy.sh rollback: revert the configuration to the opposite port
# jetty_deploy.sh status: shows general status information
#

#set -x

if [[ -z "$JETTY_CONFIG" || ! -f "$JETTY_CONFIG" ]]; then
	echo "JETTY_CONFIG not found or not defined. It should point to the Jetty configuration file (like /etc/default/jetty, for example)"
	exit 1
fi

source $JETTY_CONFIG

if [[ -z "$APACHE_HOST_CONF" ]]; then
	echo "APACHE_HOST_CONF should be defined, pointing to the httpd host configuration of your domain"
	exit 1
fi

usage() {
	echo "Usage: ${0##*/} {start_new | stop_previous | rollback | status } "
    exit 1
}

get_opposite_port() {
	if [[ $1 -eq 8080 ]]; then
		echo 8081
	else
		echo 8080
	fi
}

# $1 (optional): new port. If not specified, the function 
# takes the current value in APACHE_HOST_CONF and switches it
change_apache_ports() {
	sed_args=$(get_sed_args)
	current_proxy_port=`egrep -m 1 -o "http[s]?://localhost:([0-9]+)" $APACHE_HOST_CONF | cut -d':' -f 3`

	if [[ ! -z "$1" ]]; then
		new_proxy_port=$1
	else
		new_proxy_port=$(get_opposite_port $current_proxy_port)
	fi
	
	sed $sed_args "s/localhost:$current_proxy_port/localhost:$new_proxy_port/" $APACHE_HOST_CONF
	echo "New Apache ProxyPass port: $new_proxy_port"
}

show_restart_webserver_message() {
	echo "Don't forget to restart the webserver"
}

get_sed_args() {
	if [[ `uname` == "Darwin" ]]; then
		echo "-i ''"
	else 
		echo "-i"
	fi
}

# $1: port number to activate
activate_port() {
	local new_port=$1
	local sed_args=$(get_sed_args)
	sed $sed_args "s/JETTY_PORT=\(.*\)/JETTY_PORT=$new_port/" $JETTY_CONFIG
	local jetty_run=$JETTY_HOME/jetty.$new_port
	mkdir -p $jetty_run
	sed $sed_args "s|JETTY_RUN=\(.*\)|JETTY_RUN=$jetty_run|" $JETTY_CONFIG
	ln -nfs $jetty_run $JETTY_HOME/jetty_run
	ln -nfs $JETTY_HOME/jetty_run/jetty.pid $JETTY_HOME/jetty.pid
	change_apache_ports $new_port
}

# $1: port number
is_port_running() {
	nc -z localhost $1 > /dev/null
}

has_available_port() {
	is_port_running 8080
	local p1=$?

	is_port_running 8081
	local p2=$?

	let result=$p1+$p2

	if [[ $result -eq 0 ]]; then
		 return 1
	else 
		return 0
	fi
}

action=$1
[[ $# -eq 1 && ($action == "start_new" || $action == "stop_previous" || $action == "rollback" || $action == "status" ) ]] || usage

if [[ -z "$JETTY_HOME" ]]; then 
	echo "JETTY_HOME should be defined"
	exit 1
fi

current_running_port=`egrep -o 'JETTY_PORT=(.*)' $JETTY_CONFIG | sed 's/JETTY_PORT=//'`

if [[ $action == "stop_previous" ]]; then
	shutdown_port=$(get_opposite_port $current_running_port)
	pid_file=$JETTY_HOME/jetty.$shutdown_port/jetty.pid

	echo "Trying to stop port $shutdown_port"

	if [[ -f $pid_file ]]; then
		kill_pid=`cat $pid_file`
		kill $kill_pid 2> /dev/null
		timeout=30

		still_running() {
			local PID=$(cat $pid_file 2> /dev/null) || return 1
			kill -0 $PID 2> /dev/null
		}

		while still_running; do
			if [[ timeout-- -le 0 ]]; then
				kill -KILL $kill_pid 2> /dev/null
			fi

			sleep 1
		done

		echo "Port $shutdown_port finished"
		rm -f $pid_file
	else
		if is_port_running $shutdown_port; then
			echo "PID file of port $shutdown_port not found"
		else
			echo "Port $shutdown_port is already down"
		fi
	fi
elif [[ $action == "status" ]]; then
	#set -x
	is_port_running 8080
	p1=$?

	is_port_running 8081
	p2=$?

	if [[ $p1 -gt 0 && $p2 -gt 0 ]]; then
		echo "Neither port 8080 nor 8081 is running"
		exit 0
	fi

	proxy_port=`egrep -o -m 1 'localhost:([0-9]*)' $APACHE_HOST_CONF | cut -d':' -f 2`
	if [[ $proxy_port != $current_running_port ]]; then
		echo "ERROR: The proxy port is configured as $proxy_port at '$APACHE_HOST_CONF', while Jetty is configured to use $current_running_port at '$JETTY_CONFIG'" 
		exit 0
	fi

	check_running_port() {
		condition=$1
		port=$2

		if [[ $condition -eq 0 ]]; then
			echo -n "ERROR: port $port is configured, but it's not running "

			if [[ $port -eq 8080 && $p2 -eq 0 ]]; then
				echo -n " (however port 8081 is, which is odd)"
			elif [[ $port -eq 8081 && $p1 -eq 0 ]]; then
				echo -n " (however port 8080 is, which is odd)"
			fi

			echo ""
			exit 0
		fi
	}

	[[ $p1 -eq 0 && $current_running_port -ne 8080 && $p2 -ne 0 ]]
	check_running_port $? 8081

	[[ $p2 -eq 0 && $current_running_port -ne 8081 && $p1 -ne 0 ]]
	check_running_port $? 8080

	echo "OK: Current running port: $current_running_port"
elif [[ $action == "start_new" ]]; then
	if ! has_available_port; then
		echo "No available port was found, cannot start a new Jetty instance"
		exit 1
	fi

	new_port=$(get_opposite_port $current_running_port)
	activate_port $new_port
	source $JETTY_CONFIG

	$JETTY_HOME/bin/jetty.sh -d start
	curl_result=1

	while [[ $curl_result -gt 0 ]]; do
		sleep 2
		echo "Checking http://localhost:$new_port"
		curl -sI http://localhost:$new_port 2>&1 > /dev/null
		curl_result=$?
	done

	echo "Jetty started at port $new_port"
	show_restart_webserver_message
elif [[ $action == "rollback" ]]; then
	opposite_port=$(get_opposite_port $current_running_port)
	is_port_running $opposite_port

	if [[ $? -gt 0 ]]; then
		echo "Port $opposite_port is not running, cannot rollback"
		exit 1
	fi

	activate_port $opposite_port
	show_restart_webserver_message
fi
