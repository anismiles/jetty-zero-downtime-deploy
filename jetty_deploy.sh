#!/bin/bash
#
# jetty_deploy.sh start_new: starts a new Jetty server on an unused port (either 8080 or 8081)
# jetty_deploy.sh stop_previous: stops the Jetty running in the opposite port of the "current" Jetty
# jetty_deploy.sh switch_apache_ports: only switches the port settings in $APACHE_HOST_CONF
#

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
	echo "Usage: ${0##*/} {start_new | stop_previous | switch_apache_ports } "
    exit 1
}

get_opposite_port() {
	if [[ $1 -eq 8080 ]]; then
		echo 8081
	else
		echo 8080
	fi
}

# Optional argument: new port. If not specified, the function 
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
	echo "New ProxyPass port: $new_proxy_port. Don't forget to restart httpd"
}

get_sed_args() {
	if [[ `uname` == "Darwin" ]]; then
		echo "-i ''"
	else 
		echo "-i"
	fi
}

action=$1
[[ $# -eq 1 && ($action == "start_new" || $action == "stop_previous" || $action == "switch_apache_ports" ) ]] || usage

if [[ -z "$JETTY_HOME" ]]; then 
	echo "JETTY_HOME should be defined"
	exit 1
fi

current_running_port=`grep 'JETTY_PORT=' $JETTY_CONFIG | sed 's/JETTY_PORT=//'`

if [[ $action == "stop_previous" ]]; then
	shutdown_port=$(get_opposite_port $current_running_port)
	pid_file=$JETTY_HOME/jetty.$shutdown_port/jetty.pid

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
		nc -z localhost $shutdown_port > /dev/null

		if [[ $? -eq 0 ]]; then
			echo "PID file of port $shutdown_port not found"
		else
			echo "Port $shutdown_port was already down"
		fi
	fi
elif [[ $action == "start_new" ]]; then
	new_port=$(get_opposite_port $current_running_port)

	sed_args=$(get_sed_args)
	sed $sed_args "s/JETTY_PORT=\(.*\)/JETTY_PORT=$new_port/" $JETTY_CONFIG
	jetty_run=$JETTY_HOME/jetty.$new_port
	mkdir -p $jetty_run
	sed $sed_args "s|JETTY_RUN=\(.*\)|JETTY_RUN=$jetty_run|" $JETTY_CONFIG
	ln -nfs $jetty_run $JETTY_HOME/jetty_run
	ln -nfs $JETTY_HOME/jetty_run/jetty.pid $JETTY_HOME/jetty.pid

	$JETTY_HOME/bin/jetty.sh -d start
	curl_result=1

	while [[ $curl_result -gt 0 ]]; do
		sleep 2
		echo "Checking http://localhost:$new_port"
		curl -sI http://localhost:$new_port 2>&1 > /dev/null
		curl_result=$?
	done

	echo "Jetty started at port $new_port"

	change_apache_ports $new_port
elif [[ $action == "switch_apache_ports" ]]; then
	change_apache_ports
fi
