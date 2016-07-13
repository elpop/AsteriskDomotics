#!/usr/bin/perl
#===================================================================#
# Program => arduino_control.pl                       (In Perl 5.x) #
#===================================================================#
# Autor         => Fernando "El Pop" Romo        (pop@cofradia.org) #
# Creation date => 2/may/2013                                       #
#-------------------------------------------------------------------#
# Info => This program is a server who make a connection with a     #
#         asterisk server trough the TCP port 5038,take request     #
#         from a TPC clients and dispach messages to them.          #
#-------------------------------------------------------------------#
# This code are released under the GPL 3.0 License. Any change must #
# be report to the authors                                          #
#              (c) 2013 - Fernando Romo / Incuvox                   #
#-------------------------------------------------------------------#
#        For the change history use "cvs log" command               #
#===================================================================#
 
# Last update:
# $Id$
 
# Load Modules
use strict;
use DBI;
 
#use parms;
use POSIX;
use IO::Socket;
use IO::Select;
use Socket;
use Fcntl;
use Tie::RefHash;
use Time::Local;
use Time::HiRes qw(usleep);
use Proc::PID::File;
use File::Basename;
use Data::Dumper;
use threads;
use Thread::Queue;
use Device::SerialPort;
 
if (defined($ARGV[0])) {
    if ($ARGV[0] eq '-d') {
        defined(my $pid = fork) or die "Can't Fork: $!";
        exit if $pid;
        setsid or die "Can't start a new session: $!";
    }
}
 
# check PID File
die 'Already runnig' if Proc::PID::File->running( name => basename("$0",'.pl'));
 
#--------------------#
# Control Parameters #
#--------------------#
 
#--------------------------------------------------------------------
# [Pop] Developer Note: The Sys_Parms() load the necesary values from
# the Parameter table in the DB. I left this values comment for test
# and documentation purposes.
#--------------------------------------------------------------------
my %Parm = ();
 
##  Arduino server parameters
$Parm{arduino}{debug}            = 0;              # Flag to print debug information
$Parm{arduino}{port}             = 4446;           # port for clients
$Parm{arduino}{dev}              = '/dev/ttyACM0';
 
##  Asterisk manager parameters
$Parm{asterisk}{host}        = '127.0.0.1';    # IP address of * Server
$Parm{asterisk}{port}        = 5038;           # * manager port
$Parm{asterisk}{user}        = 'arduino';      # * Manager user
$Parm{asterisk}{pass}        = 'openhardware'; # * Manager password
$Parm{asterisk}{events}      = 1;              # Flag to request event log to * manager
#--------------------------------------------------------------------
 
my $PBX_ID = 1;
 
#-------------------#
# Working Variables #
#-------------------#
 
my $VERSION = q{$Id$};
   $VERSION =~ s/\$|Id:\s//g;
my $HELP = "$VERSION\n\nCommands:\n\n";
 
# Timers Info
my $Start_Time = time();
my $Reload_Time = 0;
 
# Socket handlers
my $asterisk_handler;
my $asterisk_select;
my $asterisk_client;
 
# signal traps
$SIG{PIPE} = 'IGNORE';
$SIG{INT}  = $SIG{TERM} = $SIG{HUP} = 'Terminate';
 
#Load_Parameters();
 
# Queues to pass data between Threads
my $Command_Queue   = Thread::Queue->new;
my $Response_Queue  = Thread::Queue->new;
my $tid                 = 0;
 
# Open Socket connection to accept clients requests
my $server = IO::Socket::INET->new(LocalPort => $Parm{arduino}{port},
                                   Listen    => 100,
                                   ReuseAddr => 1 )
  or die "Can't make server socket: $@\n";
Nonblock($server);
my $select = IO::Select->new($server);
 
# begin with empty buffers
my %inbuffer  = ();
my %outbuffer = ();
my %ready     = ();
my %sessions  = ();
my %who       = ();
 
tie %ready, 'Tie::RefHash';
my $event_str = q{};
my $XML_msg   = q{};
 
# Flags to connect to Asterisk
my $manager_connect_time = 0;
my $manager_connect_flag = 1;
 
#----------------------------------------------------------------------------------------------
# [Developer Note]: the process of each client request is declared in the %Client_Handler
#                   Hash and use references for speed operations in the event detection cycle.
#----------------------------------------------------------------------------------------------
 
my %Client_Handler = (
    #----------------------------------------------------------------------------------------------------------------
    # relay: [relay number]
    #----------------------------------------------------------------------------------------------------------------
    "relay" => sub {
        my $client = shift;
        my $control = shift;
        if (@{$control} < 1) {
            $outbuffer{$client} = "Missing relay number\n";
        }
        else {
            if ($control->[1] =~ /\d+/) {
                $Command_Queue->enqueue('relay|' . $control->[1]);
            } 
            else {
                $outbuffer{$client} = "Invalid relay number (must be digits)\n";
            }  # End if ($control->[1] =~ /\d+/)
        } # End if (@{$control} < 0)
    },
    #----------------------------------------------------------------------------------------------------------------
    # HELP
    #----------------------------------------------------------------------------------------------------------------
    "help" => sub {
        my $client = shift;
        $outbuffer{$client} = $HELP;
    },
    #----------------------------------------------------------------------------------------------------------------
    # PARM: List Process parameters
    #----------------------------------------------------------------------------------------------------------------
    "parm" => sub {
        my $client = shift;
        my $control = shift;
        if (@{$control} < 2) {
            $outbuffer{$client} = '';
            foreach my $category  (sort keys %Parm) {
                $outbuffer{$client} .= "$category\n";
                foreach my $keyword  (sort keys %{$Parm{$category}}) {
                    $outbuffer{$client} .= "    $keyword => $Parm{$category}{$keyword}\n";
                }
            }
        }
    },
    #----------------------------------------------------------------------------------------------------------------
    # QUIT or EXIT: terminate client session
    #----------------------------------------------------------------------------------------------------------------
    "quit" => sub {
        my $client = shift;
        delete $inbuffer{$client};
        delete $outbuffer{$client};
        delete $ready{$client};
        delete $sessions{$client};
        delete $who{$client};
        $select->remove($client);
        close($client);
    },
    #----------------------------------------------------------------------------------------------------------------
    # STATUS
    #----------------------------------------------------------------------------------------------------------------
    "status" => sub {
        my $client = shift;
        $Command_Queue->enqueue('relay|7828');
    },
    #----------------------------------------------------------------------------------------------------------------
    # UPTIME: elapsed time of the running service
    #----------------------------------------------------------------------------------------------------------------
    "uptime" => sub {
        my $client = shift;
        $outbuffer{$client} = Convert_To_Time(time() - $Start_Time) . "\n";
    },
    #----------------------------------------------------------------------------------------------------------------
    # TEST
    #----------------------------------------------------------------------------------------------------------------
    "test" => sub {
        my $client = shift;
        $Command_Queue->enqueue('relay|8378');
    },
    #----------------------------------------------------------------------------------------------------------------
    # TIME: current system time
    #----------------------------------------------------------------------------------------------------------------
    "time" => sub {
        my $client = shift;
        $outbuffer{$client} = Current_Time() . "\n";
    },
    #----------------------------------------------------------------------------------------------------------------
    # VERSION: Bring information about this program
    #----------------------------------------------------------------------------------------------------------------
    "version" => sub {
        my $client = shift;
        $outbuffer{$client} = "$VERSION\n";
    },
    #----------------------------------------------------------------------------------------------------------------
    # WHO: List agents and extensions active for control
    #----------------------------------------------------------------------------------------------------------------
    "who" => sub {
        my $client = shift;
        $outbuffer{$client} = "\nConnections " . (scalar keys %sessions) . "\n";
        foreach my $online (sort keys %who) {
            my ($port, $address) = unpack_sockaddr_in(getpeername($who{$online}));
            my $ip_address = inet_ntoa($address);
            $outbuffer{$client} .= "$ip_address\:$port\n";
         }
    },
);
 
#------------------------------------------------------------------#
# [Pop] Developer Note: I declare the "exit" command Out of the    #
# initial %Client_Handler Hash declaration to avoid perl compiler  #
# errors because i try to invoque a non declare hash into the      #
# same hash :P                                                     #
#                                                                  #
# The trick is receive the "exit" command and call the same        #
# rutine of the "quit" event.                                      #
#------------------------------------------------------------------#
 
$Client_Handler{exit} = (sub {
    my $client = shift;
    $Client_Handler{quit}->($client);
});
 
$Client_Handler{'?'} = (sub {
    my $client = shift;
    $Client_Handler{help}->($client);
});
 
foreach my $command (sort keys %Client_Handler) {
    $HELP .= "     $command\n";
}
 
#--------------------------------------------------------------------------------------#
# [Developer Note]: the process of each packet comming from the asteris manager (AMI), #
#                   is declared in the %Event_Handler Hash and use references for      #
#                   speed operations in the event detection cycle.                     #
#--------------------------------------------------------------------------------------#
 
my %Event_Handler = (
    #-----------------------------
    # Event: UserEvent
    # Privilege: user,all
    # UserEvent: RELAY|1
    # Action: UserEvent
    #-----------------------------
    "UserEvent" => sub {
        my $packet_content_ref = shift;
        my ($userevent) = $$packet_content_ref =~ /UserEvent\:\s(.*?)\n/isx;
        #----------------------------------------------------------------------------------------------------------------
        # UserEvent(RELAY|number)
        #----------------------------------------------------------------------------------------------------------------
        my @Response = split(/_/, $userevent);
        if ($Response[0] eq 'RELAY') {
            $Command_Queue->enqueue('relay|' . $Response[1]);
        }
    },
    #-----------------------
    # Event: Shutdown
    # Privilege: system,all
    # Shutdown: Cleanly
    # Restart: False
    #-----------------------
    "Shutdown" => sub  {
        my $packet_content_ref = shift;
        # Terminate(); # if asterisk end then stop pms server
    },
);
 
#---------------------------------------------------------#
#  Function: Terminate()                                  #
#---------------------------------------------------------#
# Objetive: catch the {INT}  signal and close connection  #
#           to sockets and terminate program.             #
#   Params: none                                          #
#    Usage:                                               #
#          $SIG{INT}  = 'Terminate';                      #
#---------------------------------------------------------#
 
sub Terminate
{
    #$thread_die = 1; # Flag to indicate to the child process die
    $Command_Queue->enqueue('stop');   
    my $client;
    # Clean up connections
    foreach $client (keys %sessions) {
        $select->remove($client);
        close($client);
    }
    close($server);                   # destroy socket handler
    close($asterisk_handler);         # destroy asterisk manager conection
    $tid->join() if ($tid);
    exit(0);                          # Exit without error
}
 
#-----------------------------------------------#
#  Function: Nonblock([TCP socket handler])     #
#-----------------------------------------------#
# Objetive: puts socket into nonblocking mode   #
#   Params: [TCP Socket Handler]                #
#    Usage:                                     #
#          Nonblock($socket);                   #
#-----------------------------------------------#
 
sub Nonblock {
    my $socket = shift;
    my $flags;
 
    $flags = fcntl($socket, F_GETFL, 0)
             or die "Can't get flags for socket: $!\n";
    fcntl($socket, F_SETFL, $flags | O_NONBLOCK)
             or die "Can't make socket nonblocking: $!\n";
}
 
#-----------------------------------------------#
#  Function: Manager_Login                      #
#-----------------------------------------------#
# Objetive: Send Login Action to Asterisk API   #
#   Params: none                                #
#    Usage:                                     #
#          Manager_Login();                     #
#-----------------------------------------------#
 
sub Manager_Login {
    my $command  = "Action: Login\r\n";
    $command .= "Username: $Parm{asterisk}{user}\r\n";
    $command .= "Secret: $Parm{asterisk}{pass}\r\n";
    $command .= "Events: ";
    if ($Parm{asterisk}{events}) {
        $command .= 'on';
    } 
    else {
        $command .= 'off';
    }
    $command .= "\r\n\r\n";
    print "---------------\n$command\n" if ($Parm{arduino}{debug});
    Send_To_Asterisk(\$command);
}
 
#--------------------------------------------------#
# Function: Connect_To_Asterisk()                  #
#--------------------------------------------------#
# Objetive: connect program with asterisk manager  #
#   Params: None                                   #
#    Usage:                                        #
#          Connect_To_Asterisk();                  #
#--------------------------------------------------#
 
sub Connect_To_Asterisk
{
    $asterisk_handler = new IO::Socket::INET->new( PeerAddr => $Parm{asterisk}{host},
                                                   PeerPort => $Parm{asterisk}{port},
                                                   Proto    => "tcp",
                                                   ReuseAddr => 1,
                                                   Type     => SOCK_STREAM );
    if ($asterisk_handler) {
        $asterisk_handler->autoflush(1);
        Nonblock($asterisk_handler);
        $select->add($asterisk_handler);
        $manager_connect_time = time;
        return 0;
    } 
    else {
        return 1;
    }
}
 
#--------------------------------------------------------#
# Function: Send_To_Asterisk([message])                  #
#--------------------------------------------------------#
# Objetive: Send  message to Asterik manager             #
#   Params: message, socket_handler                      #
#    Usage:                                              #
#          Send_To_Asterisk($message,$socket)            #
#--------------------------------------------------------#
 
sub Send_To_Asterisk
{
    my $command_ref = shift;
    unless ($$command_ref eq "" && $manager_connect_flag == 1) {
        #--------------------------------------------------------------------------------#
        # Developer Note: in some cases, the API Manager sufer of a requets override and #
        #                 is necesary put a little time wait between requests.           #
        #--------------------------------------------------------------------------------#
        # usleep 200_000;
 
        # if the socket exists send data, if not, turn on reconnection flag
        # if (defined(getpeername($asterisk_handler))) {
        unless($asterisk_handler eq "") {
            my $rv;
            eval { $rv = $asterisk_handler->send($$command_ref, 0) };
            unless (defined $rv) {
                # if send fails, turn on reconnection flag
                $manager_connect_flag = 1;
            }
        } 
        else {
            $manager_connect_flag = 1;
        }
    }
}
 
#-------------------------------------------------------#
#  Fuction: Trim([var|array])                           #
#-------------------------------------------------------#
# Objetive: Take out blank spaces in the rigth and left #
#           of the field                                #
#   Params: one string or array                         #
#    Usage:                                             #
#          $sample = Trim(" vs ");                      #
#          $sample = Trim($foo);                        #
#          @sample = Trim(@data);                       #
#-------------------------------------------------------#
 
sub Trim {
    my @out = @_;
    for (@out) {
        s/^\s+//g;
        s/\s+$//g;
    }
    return wantarray ? @out : $out[0];
}
 
#---------------------------------------------------#
# Function: Dial([phone number],[agent],[campaign], #
#                [Warehouse_id],[call_id])          #
#---------------------------------------------------#
# Objetive: originate a phone call via the asterisk #
#                                                   #
#   Params: phone number                            #
#    Usage:                                         #
#          Dial("85909000","1001")                  #
#---------------------------------------------------#
 
sub Dial {
    my ($tcp_client, $class, $number, $wid, $call_id) = @_;
    my $command  = "Action: Originate\r\n";
    # $command .= "Channel: Local/$number\@default/n\r\n";
    $command .= "Channel: $Parm{asterisk}{trunk}/$number\r\n";
    $command .= "Context: default\r\n";
    $command .= "Priority: 1\r\n";
    $command .= "Async: true\r\n";
    $command .= "Timeout: 30000\r\n";
    $command .= "Variable: TIMEOUT(absolute)=$Parm{arduino}{absolute_timeout}\r\n";
    $command .= "Variable: CDR(dnis)=$number\r\n";
    $command .= "Variable: CDR(call_type)=2\r\n";
    $command .= "Variable: CDR(origin)=4\r\n";
    $command .= "Variable: CDR(pbx)=$PBX_ID\r\n";
    $command .= "Callerid: $number\r\n";
    my ($tcp_client_hex_part) = $tcp_client =~ /\((.*?)\)/;
    $command .= "ActionID: C\|$tcp_client_hex_part\|$call_id\|$wid\|$number";
    $command .= "\r\n\r\n";
    Send_To_Asterisk(\$command);
}
 
#----------------------------------------------------#
# Function: User_Event([Message])                    #
#----------------------------------------------------#
# Objetive: Send a User Event to communicate state   #
#           with other process                       #
#   Params: Agent, mode                              #
#    Usage:                                          #
#          User_Event($msg);                         #
#----------------------------------------------------#
 
sub User_Event {
    my ($msg) = @_;
    my $command  = "Action: UserEvent\r\n";
    $command .= "UserEvent: $msg\r\n\r\n";
    Send_To_Asterisk(\$command);
}
 
#---------------------------------------------------------#
#  Fuction: Pad([string],[Width],[fill_char],[Direction]) #
#---------------------------------------------------------#
# Objetive: Fill with character selected one string in    #
#           the right or left                             #
#   Params: string, Max_Width, fill_char,                 #
#           Direction (0 = left, 1 = rigth)               #
#    Usage:                                               #
#          Pad($month,2,'0',0)                            #
#---------------------------------------------------------#
 
sub Pad {
    my ($string, $lmax, $char, $dir) = @_;
    my $l = length $string;
    if ($l > $lmax) {
        $string = substr($string, 0, $lmax);
    } 
    else {
        if ($dir) {
            $string = $string . ($char x ($lmax - $l));
        } 
        else {    
            $string = ($char x ($lmax - $l)) . $string;
        }
    }
    return $string;
}
 
#===========================================================#
# Convert_To_Time                                           #
#-----------------------------------------------------------#
# Fuction to convert elapsed time in seconds to a friendly  #
# format like hhh:mm:ss                                     #
#                                                           #
# Arguments:                                                #
#            a integer number that mean seconds             #
# Sample:                                                   #
#            $seconds = 11145;                              #
#            print "call elapsed time = ";                  #
#            print Convert_To_Time($seconds);               #
# Result:                                                   #
#            call elapsed time = 3:05'45                    #
#===========================================================#
 
sub Convert_To_Time {
    my $time=$_[0];
    my $days = int($time / 86400);
    my $aux = $time % 86400;
    my $hours = int($aux / 3600);
       $aux = $aux % 3600;
    my $minutes = int($aux / 60);
    my $seconds = $time % 60;
    my $result = "";
    if ($days == 1) {
        $result = "$days day ";
    } 
    elsif ($days > 1) {
        $result = "$days days ";
    }
    $result .= $hours.":".Pad($minutes,2,'0',0)."'".Pad($seconds,2,'0',0);
    return $result;
}
 
#-------------------------------------------------#
#  Function: Current_Time                         #
#-------------------------------------------------#
# Objetive: Return current formated date and time #
#   Params: none                                  #
#    Usage:                                       #
#          $date = CurrentTime_();                #
#-------------------------------------------------#
 
sub Current_Time {
    my ($second, $minute, $hour, $day, $month, $year) = (localtime(time()))[0,1,2,3,4,5];
    $month++;
    $year += 1900;
    return "$year-" . Pad($month,2,'0',0) . '-' .Pad($day,2,'0',0) .' ' .
            Pad($hour,2,'0',0) . ':' . Pad($minute,2,'0',0).':'.Pad($second,2,'0',0);
} 
 
#--------------------------------------------------------#
# Function: Arduino_Handler()                   [Thread] #
#--------------------------------------------------------#
# Objetive: Process serial comunication with Arduino USB #
#   Params: file device                                  #
#    Usage:                                              #
#       $tid = threads->create(\&Arduino_Handler,$dev);  #
#--------------------------------------------------------#
 
sub Arduino_Handler {
    my $arduino_dev = shift;
    my $port = undef;
    my $Serial_Connection_Flag = 1;
    #-----------------------------------------------------------------------------------
    # [Pop] Developer Note: This is tricky part of declare a sub into a sub to invoque
    #                       on the thread start and on reload :P
    #-----------------------------------------------------------------------------------
    # _Connect_Arduino() - Star serial communication with Arduino using USB
    #-----------------------------------------------------------------------------------
    local *_Connect_Arduino = sub {
        if (( -e $arduino_dev) && ($Serial_Connection_Flag == 1)) {
            $Serial_Connection_Flag = 0;
            eval { $port = Device::SerialPort->new("$arduino_dev") };
            unless ($port eq "") {
                $port->baudrate(57600); # you may change this value
                $port->databits(8); # but not this and the two following
                $port->parity("none");
                $port->stopbits(1);
                $port->handshake("none");
                $port->read_char_time(0);
                $port->read_const_time(20); 
            }
            else {
                $Serial_Connection_Flag = 1;
            }
        }
        else {
            $Serial_Connection_Flag = 1;
        }
    };
 
    #--------------------------------------------------------------------------
    # __Send_To_Arduino() - Send Info to Arduino
    #--------------------------------------------------------------------------
    local *_Send_To_Arduino = sub {
       my ($relay) = shift;
       my $count = 0;
       unless ($port eq "") {
           eval { $count = $port->write("$relay\n") };
           unless($count) {
              $Serial_Connection_Flag = 1;
           }
       }
       else {
            $Serial_Connection_Flag = 1;
       }
    };
 
    local *_Read_From_Arduino = sub {
        my $rx = '';
        eval { $rx = $port->lookfor() };
        if ($port eq "") {
              $Serial_Connection_Flag = 1;
        }
        else {
            return $rx;;
        }
    };
 
    #-------------------#
    # Main thread cycle #
    #-------------------#
 
    while (1) {
        if ($Serial_Connection_Flag) {
            _Connect_Arduino();
        }
 
        my $command = $Command_Queue->dequeue_nb;
        if ($command) {
            if ($command =~ /\|/) {
                my ($option,$value) = split(/\|/,$command);
                if ($option eq 'relay') {
                    _Send_To_Arduino($value);
                }
            }
            elsif ($command eq 'stop') {
                $port->close;
                return;
            } 
        }
 
        my $rx = _Read_From_Arduino();
        if ($rx) {
            $Response_Queue->enqueue($rx); 
        }
 
    }
    # End Main thread cycle 
}
 
#---------------------------------------------------------#
#  Function: Handle_Clients([Client TCP handler])         #
#---------------------------------------------------------#
# Objetive: Take the requests of client programs and      #
#           interface with Asterisk manager               #
#   Params: [client TCP handler]                          #
#    Usage:                                               #
#          Handle_Clients($client);                       #
#---------------------------------------------------------#
 
sub Handle_Clients {
    # requests are in $ready{$client}
    # send output to $outbuffer{$client}
    my $client = shift;
    my $request;
 
    foreach $request (@{$ready{$client}}) {
       $request =~ s/\r|\n//g;
       if ($request) {
           my @control = split (/\s+/, Trim($request));
           if (exists($Client_Handler{$control[0]})) {
               $Client_Handler{$control[0]}->($client,\@control); 
           } 
           else {
               $outbuffer{$client} = "Invalid command\n"; 
           }
       }
    }
    delete $ready{$client};
}
 
#---------------------------------------------------------#
#  Function: Handle_Events([Asterisk TCP handler])        #
#---------------------------------------------------------#
# Objetive: Take the requests of Asterisk and manipulate  #
#           the asterisk Manager events.                  #
#   Params: [Asterisk TCP handler]                        #
#    Usage:                                               #
#          Handle_Events($asterisk_handler);              #
#---------------------------------------------------------#
 
sub Handle_Events {
    # requests are in $ready{$client}
    # send output to $outbuffer{$client}
    my $client = shift;
    my $request;
    my @packet = ();
 
    foreach $request (@{$ready{$client}}) {
        $event_str .= $request if ($request);
    }
    if ($event_str =~ /\r\n\r\n/) {
 
       # put each packet in separate area
       @packet = $event_str =~ /(?:Action|Event|Message|Response).*?\r\n\r\n/isxg;
 
       # process each individual packet 
       foreach my $packet_content (@packet) {
           $packet_content =~ s/\r//g;
 
           # Analyze each packet header and process according
           my ($event) = $packet_content =~ /^Event\:\s(.*?)\n/isx;
           if (exists($Event_Handler{$event})) {
               $Event_Handler{$event}->(\$packet_content); 
           }
       }
 
       # if exists a remainder incomplet event, keep it to the next round  
       my $last_pos = rindex($event_str,"\r\n\r\n");
       $last_pos = $last_pos + 4;
       my $len = length($event_str);
       if ($len > $last_pos) {
           $event_str = substr($event_str,$last_pos);
       } 
       else {
           $event_str = "";
       }
    }
    delete $ready{$client};
}
 
#---------------------------------------------------------#
#  Function: Clean_Connection([TCP handler])              #
#---------------------------------------------------------#
# Objetive: Close client TCP connection                   #
#   Params: [TCP handler]                                 #
#    Usage:                                               #
#          Clean_Connection($client_handler);             #
#---------------------------------------------------------#
 
sub Clean_Connection {
    my $client_session = shift;
 
    # Delete working buffers
    delete $inbuffer{$client_session};
    delete $outbuffer{$client_session};
    delete $ready{$client_session};
    delete $sessions{$client_session};
    delete $who{$client_session};
 
    # Check if the connection to Asterisk Die and turn the reconnection Flag
    if ($client_session eq $asterisk_handler) {
        $manager_connect_flag =1;
    }
    $select->remove($client_session);
    close($client_session);
}
 
#======================#
#      Main block      #
#======================#
 
# $/="\0";
 
# Launch Configuration Thread for Arduino control
$tid = threads->create(\&Arduino_Handler,$Parm{arduino}{dev});
 
# Main loop 
while (1) { 
    my $client;
    my $rv;
    my $data;
    if ($manager_connect_flag) {
        $manager_connect_flag = Connect_To_Asterisk();
        unless ($manager_connect_flag) {
            Manager_Login();
        } 
    }
 
    # check for new information on the connections we have.
    # anything to read or accept?
    foreach $client ($select->can_read(1)) {
        if ($client == $server) {
            # accept a new connection
            $client = $server->accept();
            $select->add($client);
            Nonblock($client);
            $sessions{$client} = 1;
            $who{$client} = $client;
            $outbuffer{$client} = "$VERSION (? for help)\n";
        } 
        else {
            # read data
            $data = q{};
            eval { $rv   = $client->recv($data, POSIX::BUFSIZ, 0) };
            unless (defined($rv) && length $data) {
                # This would be the end of file, so close the client
                Clean_Connection($client);
                next;
            }
            $data =~ s/\0/\r\n/g;
            $inbuffer{$client} .= $data;
            # test whether the data in the buffer or the data we
            # just read means there is a complete request waiting
            # to be fulfilled.  If there is, set $ready{$client}
            # to the requests waiting to be fulfilled.
            while ($inbuffer{$client} =~ s/(.*\r\n)//) {
                push( @{$ready{$client}}, $1 );
            }
        }
    }
 
    # Read if exist response from Arduino
    my $response = $Response_Queue->dequeue_nb;
    if ($response) {
         foreach $client ($select->can_write(1)) {
             $outbuffer{$client} = $response . "\n";
         }
    }
 
    # Any complete requests to process?
    foreach $client (keys %ready) {
        if ($client eq $asterisk_handler) {
            Handle_Events($client);
        } 
        else {
            Handle_Clients($client);
        }
    }
 
    # Buffers to flush?
    foreach $client ($select->can_write(1)) {
        # Skip this client if we have nothing to say
        next unless exists $outbuffer{$client};
        # Check if the socket exists before send
        ## if (defined(getpeername($client))) {
        unless($client eq "") {
            eval { $rv = $client->send($outbuffer{$client}, 0) };
            unless (defined $rv) {
                # Whine, but move on.
                warn "I was told I could write, but I can't.\n";
                next;
            }
            if ($rv == length $outbuffer{$client} ||
                $! == POSIX::EWOULDBLOCK) {
                substr($outbuffer{$client}, 0, $rv) = q{};
                delete $outbuffer{$client} unless length $outbuffer{$client};
            } 
            else {
                Clean_Connection($client);
                next;
            }
        } 
        else {
            Clean_Connection($client);
            next;
        }
    }
 
    # Out of band data?
    foreach $client ($select->has_exception(0)) {  # arg is timeout
        # Deal with out-of-band data here, if you want to.
    }
} # End of main loop
 
#------------- End of Program ----------