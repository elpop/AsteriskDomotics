#!/bin/bash
### BEGIN INIT INFO
# Provides:          arduino
# Required-Start:    freepbx
# Required-Stop:     freepbx
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Start Arduino Asterisk Control
# Description:       Start Arduino Asterisk Control
### END INIT INFO
 
#
# chkconfig: 35 99 99
# description: Arduino Server
# processname: arduino_control.pl
 
# source function library
. /lib/lsb/init-functions
#. /etc/rc.d/init.d/functions
 
DAEMON="/root/arduino/arduino_control.pl >> /dev/null 2>&1"
OPTIONS=-d
RETVAL=0
 
case "$1" in
  start)
    echo -n "Starting Arduino server: "
    daemon $DAEMON $OPTIONS
    RETVAL=$?
    echo
    [ $RETVAL -eq 0 ] && touch /var/lock/arduino_control.pl
    ;;
  stop)
    echo -n "Shutting down Arduino server: "
    killproc arduino_control.pl
    RETVAL=$?
 
    echo
    [ $RETVAL -eq 0 ] && rm -f /var/lock/arduino_control.pl
    ;;
  restart)
    $0 stop
    $0 start
    RETVAL=$?
    ;;
  reload)
    echo -n "Reloading Arduino server: "
    killproc arduino_control.pl -HUP
    RETVAL=$?
    echo
    ;;
  status)
    status arduino_control.pl
    RETVAL=$?
    ;;
  *)
    echo "Usage: arduino_control {start|stop|status|restart|reload}"
    exit 1
esac
 
exit $RETVAL