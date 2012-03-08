#!/usr/bin/env bash

# **stack.sh** is an opinionated openstack developer installation.

# This script installs and configures *nova*, *glance*, *horizon* and *keystone*

# This script allows you to specify configuration options of what git
# repositories to use, enabled services, network configuration and various
# passwords.  If you are crafty you can run the script on multiple nodes using
# shared settings for common resources (mysql, rabbitmq) and build a multi-node
# developer install.

# To keep this script simple we assume you are running on an **Ubuntu 11.10
# Oneiric** machine.  It should work in a VM or physical server.  Additionally
# we put the list of *apt* and *pip* dependencies and other configuration files
# in this repo.  So start by grabbing this script and the dependencies.

# Learn more and get the most recent version at http://devstack.org

# Sanity Check
# ============

# Warn users who aren't on oneiric, but allow them to override check and attempt
# installation with ``FORCE=yes ./stack``
DISTRO=$(lsb_release -c -s)

if [[ ! ${DISTRO} =~ (oneiric) ]]; then
    echo "WARNING: this script has only been tested on oneiric"
    if [[ "$FORCE" != "yes" ]]; then
        echo "If you wish to run this script anyway run with FORCE=yes"
        exit 1
    fi
fi

# Keep track of the current devstack directory.
TOP_DIR=$(cd $(dirname "$0") && pwd)

# Import common functions
. $TOP_DIR/functions

# stack.sh keeps the list of **apt** and **pip** dependencies in external
# files, along with config templates and other useful files.  You can find these
# in the ``files`` directory (next to this script).  We will reference this
# directory using the ``FILES`` variable in this script.
FILES=$TOP_DIR/files
if [ ! -d $FILES ]; then
    echo "ERROR: missing devstack/files - did you grab more than just stack.sh?"
    exit 1
fi



# Settings
# ========

# This script is customizable through setting environment variables.  If you
# want to override a setting you can either::
#
#     export MYSQL_PASSWORD=anothersecret
#     ./stack.sh
#
# You can also pass options on a single line ``MYSQL_PASSWORD=simple ./stack.sh``
#
# Additionally, you can put any local variables into a ``localrc`` file, like::
#
#     MYSQL_PASSWORD=anothersecret
#     MYSQL_USER=hellaroot
#
# We try to have sensible defaults, so you should be able to run ``./stack.sh``
# in most cases.
#
# We support HTTP and HTTPS proxy servers via the usual environment variables
# http_proxy and https_proxy.  They can be set in localrc if necessary or
# on the command line::
#
#     http_proxy=http://proxy.example.com:3128/ ./stack.sh
#
# We source our settings from ``stackrc``.  This file is distributed with devstack
# and contains locations for what repositories to use.  If you want to use other
# repositories and branches, you can add your own settings with another file called
# ``localrc``
#
# If ``localrc`` exists, then ``stackrc`` will load those settings.  This is
# useful for changing a branch or repository to test other versions.  Also you
# can store your other settings like **MYSQL_PASSWORD** or **ADMIN_PASSWORD** instead
# of letting devstack generate random ones for you.
source ./stackrc

# Destination path for installation ``DEST``
DEST=${DEST:-/opt/stack}

# Check to see if we are already running a stack.sh
if type -p screen >/dev/null && screen -ls | egrep -q "[0-9].stack"; then
    echo "You are already running a stack.sh session."
    echo "To rejoin this session type 'screen -x stack'."
    echo "To destroy this session, kill the running screen."
    exit 1
fi

# OpenStack is designed to be run as a regular user (Horizon will fail to run
# as root, since apache refused to startup serve content from root user).  If
# stack.sh is run as root, it automatically creates a stack user with
# sudo privileges and runs as that user.

if [[ $EUID -eq 0 ]]; then
    ROOTSLEEP=${ROOTSLEEP:-10}
    echo "You are running this script as root."
    echo "In $ROOTSLEEP seconds, we will create a user 'stack' and run as that user"
    sleep $ROOTSLEEP

    # since this script runs as a normal user, we need to give that user
    # ability to run sudo
    dpkg -l sudo || apt_get update && apt_get install sudo

    if ! getent passwd stack >/dev/null; then
        echo "Creating a user called stack"
        useradd -U -G sudo -s /bin/bash -d $DEST -m stack
    fi

    echo "Giving stack user passwordless sudo priviledges"
    # some uec images sudoers does not have a '#includedir'. add one.
    grep -q "^#includedir.*/etc/sudoers.d" /etc/sudoers ||
        echo "#includedir /etc/sudoers.d" >> /etc/sudoers
    ( umask 226 && echo "stack ALL=(ALL) NOPASSWD:ALL" \
        > /etc/sudoers.d/50_stack_sh )

    echo "Copying files to stack user"
    STACK_DIR="$DEST/${PWD##*/}"
    cp -r -f -T "$PWD" "$STACK_DIR"
    chown -R stack "$STACK_DIR"
    if [[ "$SHELL_AFTER_RUN" != "no" ]]; then
        exec su -c "set -e; cd $STACK_DIR; bash stack.sh; bash" stack
    else
        exec su -c "set -e; cd $STACK_DIR; bash stack.sh" stack
    fi
    exit 1
else
    # Our user needs passwordless priviledges for certain commands which nova
    # uses internally.
    # Natty uec images sudoers does not have a '#includedir'. add one.
    sudo grep -q "^#includedir.*/etc/sudoers.d" /etc/sudoers ||
        echo "#includedir /etc/sudoers.d" | sudo tee -a /etc/sudoers
    TEMPFILE=`mktemp`
    cat $FILES/sudo/nova > $TEMPFILE
    sed -e "s,%USER%,$USER,g" -i $TEMPFILE
    chmod 0440 $TEMPFILE
    sudo chown root:root $TEMPFILE
    sudo mv $TEMPFILE /etc/sudoers.d/stack_sh_nova
fi

# Set True to configure stack.sh to run cleanly without Internet access.
# stack.sh must have been previously run with Internet access to install
# prerequisites and initialize $DEST.
OFFLINE=`trueorfalse False $OFFLINE`

# Set the destination directories for openstack projects
NOVA_DIR=$DEST/nova
HORIZON_DIR=$DEST/horizon
GLANCE_DIR=$DEST/glance
KEYSTONE_DIR=$DEST/keystone
NOVACLIENT_DIR=$DEST/python-novaclient
KEYSTONECLIENT_DIR=$DEST/python-keystoneclient
NOVNC_DIR=$DEST/noVNC
SWIFT_DIR=$DEST/swift
QUANTUM_DIR=$DEST/quantum
QUANTUM_CLIENT_DIR=$DEST/python-quantumclient
MELANGE_DIR=$DEST/melange
MELANGECLIENT_DIR=$DEST/python-melangeclient

# Default Quantum Plugin
Q_PLUGIN=${Q_PLUGIN:-openvswitch}
# Default Quantum Port
Q_PORT=${Q_PORT:-9696}
# Default Quantum Host
Q_HOST=${Q_HOST:-localhost}

# Default Melange Port
M_PORT=${M_PORT:-9898}
# Default Melange Host
M_HOST=${M_HOST:-localhost}
# Melange MAC Address Range
M_MAC_RANGE=${M_MAC_RANGE:-404040/24}

# Specify which services to launch.  These generally correspond to screen tabs
ENABLED_SERVICES=${ENABLED_SERVICES:-g-api,g-reg,key,n-api,n-crt,n-obj,n-cpu,n-net,n-vol,n-sch,n-novnc,n-xvnc,n-cauth,horizon,mysql,rabbit}

# Name of the lvm volume group to use/create for iscsi volumes
VOLUME_GROUP=${VOLUME_GROUP:-nova-volumes}
VOLUME_NAME_PREFIX=${VOLUME_NAME_PREFIX:-volume-}
INSTANCE_NAME_PREFIX=${INSTANCE_NAME_PREFIX:-instance-}

# Nova hypervisor configuration.  We default to libvirt whth  **kvm** but will
# drop back to **qemu** if we are unable to load the kvm module.  Stack.sh can
# also install an **LXC** based system.
VIRT_DRIVER=${VIRT_DRIVER:-libvirt}
LIBVIRT_TYPE=${LIBVIRT_TYPE:-kvm}

# nova supports pluggable schedulers.  ``SimpleScheduler`` should work in most
# cases unless you are working on multi-zone mode.
SCHEDULER=${SCHEDULER:-nova.scheduler.simple.SimpleScheduler}

HOST_IP_IFACE=${HOST_IP_IFACE:-eth0}
# Use the eth0 IP unless an explicit is set by ``HOST_IP`` environment variable
if [ -z "$HOST_IP" -o "$HOST_IP" == "dhcp" ]; then
    HOST_IP=`LC_ALL=C /sbin/ifconfig ${HOST_IP_IFACE} | grep -m 1 'inet addr:'| cut -d: -f2 | awk '{print $1}'`
    if [ "$HOST_IP" = "" ]; then
        echo "Could not determine host ip address."
        echo "Either localrc specified dhcp on ${HOST_IP_IFACE} or defaulted to eth0"
        exit 1
    fi
fi

# Allow the use of an alternate hostname (such as localhost/127.0.0.1) for service endpoints.
SERVICE_HOST=${SERVICE_HOST:-$HOST_IP}

# Configure services to syslog instead of writing to individual log files
SYSLOG=`trueorfalse False $SYSLOG`
SYSLOG_HOST=${SYSLOG_HOST:-$HOST_IP}
SYSLOG_PORT=${SYSLOG_PORT:-516}

# Service startup timeout
SERVICE_TIMEOUT=${SERVICE_TIMEOUT:-60}

# Generic helper to configure passwords
function read_password {
    set +o xtrace
    var=$1; msg=$2
    pw=${!var}

    localrc=$TOP_DIR/localrc

    # If the password is not defined yet, proceed to prompt user for a password.
    if [ ! $pw ]; then
        # If there is no localrc file, create one
        if [ ! -e $localrc ]; then
            touch $localrc
        fi

        # Presumably if we got this far it can only be that our localrc is missing
        # the required password.  Prompt user for a password and write to localrc.
        echo ''
        echo '################################################################################'
        echo $msg
        echo '################################################################################'
        echo "This value will be written to your localrc file so you don't have to enter it "
        echo "again.  Use only alphanumeric characters."
        echo "If you leave this blank, a random default value will be used."
        pw=" "
        while true; do
            echo "Enter a password now:"
            read -e $var
            pw=${!var}
            [[ "$pw" = "`echo $pw | tr -cd [:alnum:]`" ]] && break
            echo "Invalid chars in password.  Try again:"
        done
        if [ ! $pw ]; then
            pw=`openssl rand -hex 10`
        fi
        eval "$var=$pw"
        echo "$var=$pw" >> $localrc
    fi
    set -o xtrace
}

# This function will check if the service(s) specified in argument is
# enabled by the user in ENABLED_SERVICES.
#
# If there is multiple services specified as argument it will act as a
# boolean OR or if any of the services specified on the command line
# return true.
#
# There is a special cases for some 'catch-all' services :
#      nova would catch if any service enabled start by n-
#    glance would catch if any service enabled start by g-
#   quantum would catch if any service enabled start by q-
function is_service_enabled() {
    services=$@
    for service in ${services}; do
        [[ ,${ENABLED_SERVICES}, =~ ,${service}, ]] && return 0
        [[ ${service} == "nova" && ${ENABLED_SERVICES} =~ "n-" ]] && return 0
        [[ ${service} == "glance" && ${ENABLED_SERVICES} =~ "g-" ]] && return 0
        [[ ${service} == "quantum" && ${ENABLED_SERVICES} =~ "q-" ]] && return 0
    done
    return 1
}

# Nova Network Configuration
# --------------------------

# FIXME: more documentation about why these are important flags.  Also
# we should make sure we use the same variable names as the flag names.

PUBLIC_INTERFACE=${PUBLIC_INTERFACE:-br100}
FIXED_RANGE=${FIXED_RANGE:-10.0.0.0/24}
FIXED_NETWORK_SIZE=${FIXED_NETWORK_SIZE:-256}
FLOATING_RANGE=${FLOATING_RANGE:-172.24.4.224/28}
NET_MAN=${NET_MAN:-FlatDHCPManager}
EC2_DMZ_HOST=${EC2_DMZ_HOST:-$SERVICE_HOST}
FLAT_NETWORK_BRIDGE=${FLAT_NETWORK_BRIDGE:-br100}
VLAN_INTERFACE=${VLAN_INTERFACE:-eth0}

# Test floating pool and range are used for testing.  They are defined
# here until the admin APIs can replace nova-manage
TEST_FLOATING_POOL=${TEST_FLOATING_POOL:-test}
TEST_FLOATING_RANGE=${TEST_FLOATING_RANGE:-192.168.253.0/29}

# Multi-host is a mode where each compute node runs its own network node.  This
# allows network operations and routing for a VM to occur on the server that is
# running the VM - removing a SPOF and bandwidth bottleneck.
MULTI_HOST=${MULTI_HOST:-False}

# If you are using FlatDHCP on multiple hosts, set the ``FLAT_INTERFACE``
# variable but make sure that the interface doesn't already have an
# ip or you risk breaking things.
#
# **DHCP Warning**:  If your flat interface device uses DHCP, there will be a
# hiccup while the network is moved from the flat interface to the flat network
# bridge.  This will happen when you launch your first instance.  Upon launch
# you will lose all connectivity to the node, and the vm launch will probably
# fail.
#
# If you are running on a single node and don't need to access the VMs from
# devices other than that node, you can set the flat interface to the same
# value as ``FLAT_NETWORK_BRIDGE``.  This will stop the network hiccup from
# occurring.
FLAT_INTERFACE=${FLAT_INTERFACE:-eth0}

## FIXME(ja): should/can we check that FLAT_INTERFACE is sane?

# Using Quantum networking:
#
# Make sure that quantum is enabled in ENABLED_SERVICES.  If it is the network
# manager will be set to the QuantumManager.  If you want to run Quantum on
# this host, make sure that q-svc is also in ENABLED_SERVICES.
#
# If you're planning to use the Quantum openvswitch plugin, set Q_PLUGIN to
# "openvswitch" and make sure the q-agt service is enabled in
# ENABLED_SERVICES.
#
# With Quantum networking the NET_MAN variable is ignored.

# Using Melange IPAM:
#
# Make sure that quantum and melange are enabled in ENABLED_SERVICES.
# If they are then the melange IPAM lib will be set in the QuantumManager.
# Adding m-svc to ENABLED_SERVICES will start the melange service on this
# host.


# MySQL & RabbitMQ
# ----------------

# We configure Nova, Horizon, Glance and Keystone to use MySQL as their
# database server.  While they share a single server, each has their own
# database and tables.

# By default this script will install and configure MySQL.  If you want to
# use an existing server, you can pass in the user/password/host parameters.
# You will need to send the same ``MYSQL_PASSWORD`` to every host if you are doing
# a multi-node devstack installation.
MYSQL_HOST=${MYSQL_HOST:-localhost}
MYSQL_USER=${MYSQL_USER:-root}
read_password MYSQL_PASSWORD "ENTER A PASSWORD TO USE FOR MYSQL."

# don't specify /db in this string, so we can use it for multiple services
BASE_SQL_CONN=${BASE_SQL_CONN:-mysql://$MYSQL_USER:$MYSQL_PASSWORD@$MYSQL_HOST}

# Rabbit connection info
RABBIT_HOST=${RABBIT_HOST:-localhost}
read_password RABBIT_PASSWORD "ENTER A PASSWORD TO USE FOR RABBIT."

# Glance connection info.  Note the port must be specified.
GLANCE_HOSTPORT=${GLANCE_HOSTPORT:-$SERVICE_HOST:9292}

# SWIFT
# -----
# TODO: implement glance support
# TODO: add logging to different location.

# By default the location of swift drives and objects is located inside
# the swift source directory. SWIFT_DATA_LOCATION variable allow you to redefine
# this.
SWIFT_DATA_LOCATION=${SWIFT_DATA_LOCATION:-${SWIFT_DIR}/data}

# We are going to have the configuration files inside the source
# directory, change SWIFT_CONFIG_LOCATION if you want to adjust that.
SWIFT_CONFIG_LOCATION=${SWIFT_CONFIG_LOCATION:-${SWIFT_DIR}/config}

# devstack will create a loop-back disk formatted as XFS to store the
# swift data. By default the disk size is 1 gigabyte. The variable
# SWIFT_LOOPBACK_DISK_SIZE specified in bytes allow you to change
# that.
SWIFT_LOOPBACK_DISK_SIZE=${SWIFT_LOOPBACK_DISK_SIZE:-1000000}

# The ring uses a configurable number of bits from a path’s MD5 hash as
# a partition index that designates a device. The number of bits kept
# from the hash is known as the partition power, and 2 to the partition
# power indicates the partition count. Partitioning the full MD5 hash
# ring allows other parts of the cluster to work in batches of items at
# once which ends up either more efficient or at least less complex than
# working with each item separately or the entire cluster all at once.
# By default we define 9 for the partition count (which mean 512).
SWIFT_PARTITION_POWER_SIZE=${SWIFT_PARTITION_POWER_SIZE:-9}

# This variable allows you to configure how many replicas you want to be
# configured for your Swift cluster.  By default the three replicas would need a
# bit of IO and Memory on a VM you may want to lower that to 1 if you want to do
# only some quick testing.
SWIFT_REPLICAS=${SWIFT_REPLICAS:-3}

# We only ask for Swift Hash if we have enabled swift service.
if is_service_enabled swift; then
    # SWIFT_HASH is a random unique string for a swift cluster that
    # can never change.
    read_password SWIFT_HASH "ENTER A RANDOM SWIFT HASH."
fi

# Keystone
# --------

# Service Token - Openstack components need to have an admin token
# to validate user tokens.
read_password SERVICE_TOKEN "ENTER A SERVICE_TOKEN TO USE FOR THE SERVICE ADMIN TOKEN."
# Horizon currently truncates usernames and passwords at 20 characters
read_password ADMIN_PASSWORD "ENTER A PASSWORD TO USE FOR HORIZON AND KEYSTONE (20 CHARS OR LESS)."

# Set Keystone interface configuration
KEYSTONE_AUTH_HOST=${KEYSTONE_AUTH_HOST:-$SERVICE_HOST}
KEYSTONE_AUTH_PORT=${KEYSTONE_AUTH_PORT:-35357}
KEYSTONE_AUTH_PROTOCOL=${KEYSTONE_AUTH_PROTOCOL:-http}
KEYSTONE_SERVICE_HOST=${KEYSTONE_SERVICE_HOST:-$SERVICE_HOST}
KEYSTONE_SERVICE_PORT=${KEYSTONE_SERVICE_PORT:-5000}
KEYSTONE_SERVICE_PROTOCOL=${KEYSTONE_SERVICE_PROTOCOL:-http}

# Horizon
# -------

# Allow overriding the default Apache user and group, default both to
# current user.
APACHE_USER=${APACHE_USER:-$USER}
APACHE_GROUP=${APACHE_GROUP:-$APACHE_USER}

# Log files
# ---------

# Set up logging for stack.sh
# Set LOGFILE to turn on logging
# We append '.xxxxxxxx' to the given name to maintain history
# where xxxxxxxx is a representation of the date the file was created
if [[ -n "$LOGFILE" ]]; then
    # First clean up old log files.  Use the user-specified LOGFILE
    # as the template to search for, appending '.*' to match the date
    # we added on earlier runs.
    LOGDAYS=${LOGDAYS:-7}
    LOGDIR=$(dirname "$LOGFILE")
    LOGNAME=$(basename "$LOGFILE")
    find $LOGDIR -maxdepth 1 -name $LOGNAME.\* -mtime +$LOGDAYS -exec rm {} \;

    TIMESTAMP_FORMAT=${TIMESTAMP_FORMAT:-"%F-%H%M%S"}
    LOGFILE=$LOGFILE.$(date "+$TIMESTAMP_FORMAT")
    # Redirect stdout/stderr to tee to write the log file
    exec 1> >( tee "${LOGFILE}" ) 2>&1
    echo "stack.sh log $LOGFILE"
    # Specified logfile name always links to the most recent log
    ln -sf $LOGFILE $LOGDIR/$LOGNAME
fi

# So that errors don't compound we exit on any errors so you see only the
# first error that occurred.
trap failed ERR
failed() {
    local r=$?
    set +o xtrace
    [ -n "$LOGFILE" ] && echo "${0##*/} failed: full log in $LOGFILE"
    exit $r
}

# Print the commands being run so that we can see the command that triggers
# an error.  It is also useful for following along as the install occurs.
set -o xtrace

# Install Packages
# ================
#
# Openstack uses a fair number of other projects.

# - We are going to install packages only for the services needed.
# - We are parsing the packages files and detecting metadatas.
#  - If there is a NOPRIME as comment mean we are not doing the install
#    just yet.
#  - If we have the meta-keyword dist:DISTRO or
#    dist:DISTRO1,DISTRO2 it will be installed only for those
#    distros (case insensitive).
function get_packages() {
    local file_to_parse="general"
    local service

    for service in ${ENABLED_SERVICES//,/ }; do
        # Allow individual services to specify dependencies
        if [[ -e $FILES/apts/${service} ]]; then
            file_to_parse="${file_to_parse} $service"
        fi
        if [[ $service == n-* ]]; then
            if [[ ! $file_to_parse =~ nova ]]; then
                file_to_parse="${file_to_parse} nova"
            fi
        elif [[ $service == g-* ]]; then
            if [[ ! $file_to_parse =~ glance ]]; then
                file_to_parse="${file_to_parse} glance"
            fi
        elif [[ $service == key* ]]; then
            if [[ ! $file_to_parse =~ keystone ]]; then
                file_to_parse="${file_to_parse} keystone"
            fi
        fi
    done

    for file in ${file_to_parse}; do
        local fname=${FILES}/apts/${file}
        local OIFS line package distros distro
        [[ -e $fname ]] || { echo "missing: $fname"; exit 1 ;}

        OIFS=$IFS
        IFS=$'\n'
        for line in $(<${fname}); do
            if [[ $line =~ "NOPRIME" ]]; then
                continue
            fi

            if [[ $line =~ (.*)#.*dist:([^ ]*) ]]; then # We are using BASH regexp matching feature.
                        package=${BASH_REMATCH[1]}
                        distros=${BASH_REMATCH[2]}
                        for distro in ${distros//,/ }; do  #In bash ${VAR,,} will lowecase VAR
                            [[ ${distro,,} == ${DISTRO,,} ]] && echo $package
                        done
                        continue
            fi

            echo ${line%#*}
        done
        IFS=$OIFS
    done
}

# install apt requirements
#apt_get update
apt_get install $(get_packages)
apt_get install python-prettytable

CURWD=`pwd`
CURWD=`dirname $CURWD`


if [ -d $$CURWD/cache/pip ];then
  pippackages=`ls $CURWD/cache/pip`
  for package in ${pippackages}; do
    cd $CURWD/cache/pip/$package && sudo python setup.py install && cd -
    echo "$CURWD/cache/pip/$package"
  done
fi

# install python requirements
pip_install `cat $FILES/pips/* | uniq`

sudo chown `whoami`  `dirname $DEST`
git_clone $STACK_REPO $DEST $STACK_BRANCH

# compute service
git_clone_empty $NOVA_REPO $NOVA_DIR $NOVA_BRANCH
# python client library to nova that horizon (and others) use
git_clone_empty $KEYSTONECLIENT_REPO $KEYSTONECLIENT_DIR $KEYSTONECLIENT_BRANCH
git_clone_empty $NOVACLIENT_REPO $NOVACLIENT_DIR $NOVACLIENT_BRANCH

# glance, swift middleware and nova api needs keystone middleware
if is_service_enabled key g-api n-api swift; then
    # unified auth system (manages accounts/tokens)
    git_clone_empty $KEYSTONE_REPO $KEYSTONE_DIR $KEYSTONE_BRANCH
fi
if is_service_enabled swift; then
    # storage service
    git_clone_empty $SWIFT_REPO $SWIFT_DIR $SWIFT_BRANCH
fi
if is_service_enabled g-api n-api; then
    # image catalog service
    git_clone_empty $GLANCE_REPO $GLANCE_DIR $GLANCE_BRANCH
fi
if is_service_enabled n-novnc; then
    # a websockets/html5 or flash powered VNC console for vm instances
    git_clone_empty $NOVNC_REPO $NOVNC_DIR $NOVNC_BRANCH
fi
if is_service_enabled horizon; then
    # django powered web control panel for openstack
    git_clone_empty $HORIZON_REPO $HORIZON_DIR $HORIZON_BRANCH $HORIZON_TAG
fi
if is_service_enabled q-svc; then
    # quantum
    git_clone_empty $QUANTUM_REPO $QUANTUM_DIR $QUANTUM_BRANCH
fi
if is_service_enabled q-svc horizon; then
    git_clone_empty $QUANTUM_CLIENT_REPO $QUANTUM_CLIENT_DIR $QUANTUM_CLIENT_BRANCH
fi

if is_service_enabled m-svc; then
    # melange
    git_clone_empty $MELANGE_REPO $MELANGE_DIR $MELANGE_BRANCH
fi

if is_service_enabled melange; then
    git_clone_empty $MELANGECLIENT_REPO $MELANGECLIENT_DIR $MELANGECLIENT_BRANCH
fi

# Initialization
# ==============


# setup our checkouts so they are installed into python path
# allowing ``import nova`` or ``import glance.client``
cd $KEYSTONECLIENT_DIR; sudo python setup.py develop
cd $NOVACLIENT_DIR; sudo python setup.py develop
if is_service_enabled key g-api n-api swift; then
    cd $KEYSTONE_DIR; sudo python setup.py develop
fi
if is_service_enabled swift; then
    cd $SWIFT_DIR; sudo python setup.py develop
fi
if is_service_enabled g-api n-api; then
    cd $GLANCE_DIR; sudo python setup.py develop
fi
cd $NOVA_DIR; sudo python setup.py develop
if is_service_enabled horizon; then
    cd $HORIZON_DIR/horizon; sudo python setup.py develop
    cd $HORIZON_DIR/openstack-dashboard; sudo python setup.py develop
fi
if is_service_enabled q-svc; then
    cd $QUANTUM_DIR; sudo python setup.py develop
fi
if is_service_enabled q-svc horizon; then
    cd $QUANTUM_CLIENT_DIR; sudo python setup.py develop
fi
if is_service_enabled m-svc; then
    cd $MELANGE_DIR; sudo python setup.py develop
fi
if is_service_enabled melange; then
    cd $MELANGECLIENT_DIR; sudo python setup.py develop
fi

# Syslog
# ---------

if [[ $SYSLOG != "False" ]]; then
    apt_get install -y rsyslog-relp
    if [[ "$SYSLOG_HOST" = "$HOST_IP" ]]; then
        # Configure the master host to receive
        cat <<EOF >/tmp/90-stack-m.conf
\$ModLoad imrelp
\$InputRELPServerRun $SYSLOG_PORT
EOF
        sudo mv /tmp/90-stack-m.conf /etc/rsyslog.d
    else
        # Set rsyslog to send to remote host
        cat <<EOF >/tmp/90-stack-s.conf
*.*		:omrelp:$SYSLOG_HOST:$SYSLOG_PORT
EOF
        sudo mv /tmp/90-stack-s.conf /etc/rsyslog.d
    fi
    sudo /usr/sbin/service rsyslog restart
fi

# Rabbit
# ---------

if is_service_enabled rabbit; then
    # Install and start rabbitmq-server
    # the temp file is necessary due to LP: #878600
    tfile=$(mktemp)
    apt_get install rabbitmq-server > "$tfile" 2>&1
    cat "$tfile"
    rm -f "$tfile"
    # change the rabbit password since the default is "guest"
    sudo rabbitmqctl change_password guest $RABBIT_PASSWORD
fi

# Mysql
# ---------

if is_service_enabled mysql; then

    # Seed configuration with mysql password so that apt-get install doesn't
    # prompt us for a password upon install.
    cat <<MYSQL_PRESEED | sudo debconf-set-selections
mysql-server-5.1 mysql-server/root_password password $MYSQL_PASSWORD
mysql-server-5.1 mysql-server/root_password_again password $MYSQL_PASSWORD
mysql-server-5.1 mysql-server/start_on_boot boolean true
MYSQL_PRESEED

    # while ``.my.cnf`` is not needed for openstack to function, it is useful
    # as it allows you to access the mysql databases via ``mysql nova`` instead
    # of having to specify the username/password each time.
    if [[ ! -e $HOME/.my.cnf ]]; then
        cat <<EOF >$HOME/.my.cnf
[client]
user=$MYSQL_USER
password=$MYSQL_PASSWORD
host=$MYSQL_HOST
EOF
        chmod 0600 $HOME/.my.cnf
    fi

    # Install and start mysql-server
    apt_get install mysql-server
    # Update the DB to give user ‘$MYSQL_USER’@’%’ full control of the all databases:
    sudo mysql -uroot -p$MYSQL_PASSWORD -h127.0.0.1 -e "GRANT ALL PRIVILEGES ON *.* TO '$MYSQL_USER'@'%' identified by '$MYSQL_PASSWORD';"

    # Edit /etc/mysql/my.cnf to change ‘bind-address’ from localhost (127.0.0.1) to any (0.0.0.0) and restart the mysql service:
    sudo sed -i 's/127.0.0.1/0.0.0.0/g' /etc/mysql/my.cnf
    sudo service mysql restart
fi


# Horizon
# ---------

# Setup the django horizon application to serve via apache/wsgi

if is_service_enabled horizon; then

    # Install apache2, which is NOPRIME'd
    apt_get install apache2 libapache2-mod-wsgi

    # Link to quantum client directory.
    rm -fr ${HORIZON_DIR}/openstack-dashboard/quantum
    ln -s ${QUANTUM_CLIENT_DIR}/quantum ${HORIZON_DIR}/openstack-dashboard/quantum

    # Remove stale session database.
    rm -f $HORIZON_DIR/openstack-dashboard/local/dashboard_openstack.sqlite3

    # ``local_settings.py`` is used to override horizon default settings.
    local_settings=$HORIZON_DIR/openstack-dashboard/local/local_settings.py
    cp $FILES/horizon_settings.py $local_settings

    # Enable quantum in dashboard, if requested
    if is_service_enabled quantum; then
        sudo sed -e "s,QUANTUM_ENABLED = False,QUANTUM_ENABLED = True,g" -i $local_settings
    fi

    # Initialize the horizon database (it stores sessions and notices shown to
    # users).  The user system is external (keystone).
    cd $HORIZON_DIR/openstack-dashboard
    python manage.py syncdb

    # create an empty directory that apache uses as docroot
    sudo mkdir -p $HORIZON_DIR/.blackhole

    ## Configure apache's 000-default to run horizon
    sudo cp $FILES/000-default.template /etc/apache2/sites-enabled/000-default
    sudo sed -e "
        s,%USER%,$APACHE_USER,g;
        s,%GROUP%,$APACHE_GROUP,g;
        s,%HORIZON_DIR%,$HORIZON_DIR,g;
    " -i /etc/apache2/sites-enabled/000-default
    sudo service apache2 restart
fi


# Glance
# ------

if is_service_enabled g-reg; then
    GLANCE_IMAGE_DIR=$DEST/glance/images
    # Delete existing images
    rm -rf $GLANCE_IMAGE_DIR

    # Use local glance directories
    mkdir -p $GLANCE_IMAGE_DIR

    # (re)create glance database
    mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'DROP DATABASE IF EXISTS glance;'
    mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'CREATE DATABASE glance;'

    function glance_config {
        sudo sed -e "
            s,%KEYSTONE_AUTH_HOST%,$KEYSTONE_AUTH_HOST,g;
            s,%KEYSTONE_AUTH_PORT%,$KEYSTONE_AUTH_PORT,g;
            s,%KEYSTONE_AUTH_PROTOCOL%,$KEYSTONE_AUTH_PROTOCOL,g;
            s,%KEYSTONE_SERVICE_HOST%,$KEYSTONE_SERVICE_HOST,g;
            s,%KEYSTONE_SERVICE_PORT%,$KEYSTONE_SERVICE_PORT,g;
            s,%KEYSTONE_SERVICE_PROTOCOL%,$KEYSTONE_SERVICE_PROTOCOL,g;
            s,%SQL_CONN%,$BASE_SQL_CONN/glance,g;
            s,%SERVICE_TOKEN%,$SERVICE_TOKEN,g;
            s,%DEST%,$DEST,g;
            s,%SYSLOG%,$SYSLOG,g;
        " -i $1
    }

    # Copy over our glance configurations and update them
    GLANCE_REGISTRY_CONF=$GLANCE_DIR/etc/glance-registry.conf
    cp $FILES/glance-registry.conf $GLANCE_REGISTRY_CONF
    glance_config $GLANCE_REGISTRY_CONF

    if [[ -e $FILES/glance-registry-paste.ini ]]; then
        GLANCE_REGISTRY_PASTE_INI=$GLANCE_DIR/etc/glance-registry-paste.ini
        cp $FILES/glance-registry-paste.ini $GLANCE_REGISTRY_PASTE_INI
        glance_config $GLANCE_REGISTRY_PASTE_INI
    fi

    GLANCE_API_CONF=$GLANCE_DIR/etc/glance-api.conf
    cp $FILES/glance-api.conf $GLANCE_API_CONF
    glance_config $GLANCE_API_CONF

    if [[ -e $FILES/glance-api-paste.ini ]]; then
        GLANCE_API_PASTE_INI=$GLANCE_DIR/etc/glance-api-paste.ini
        cp $FILES/glance-api-paste.ini $GLANCE_API_PASTE_INI
        glance_config $GLANCE_API_PASTE_INI
    fi
fi

# Nova
# ----

# Put config files in /etc/nova for everyone to find
NOVA_CONF=/etc/nova
if [[ ! -d $NOVA_CONF ]]; then
    sudo mkdir -p $NOVA_CONF
fi
sudo chown `whoami` $NOVA_CONF

if is_service_enabled n-api; then
    # We are going to use a sample http middleware configuration based on the
    # one from the keystone project to launch nova.  This paste config adds
    # the configuration required for nova to validate keystone tokens.

    # Remove legacy paste config
    rm -f $NOVA_DIR/bin/nova-api-paste.ini

    # First we add a some extra data to the default paste config from nova
    cp $NOVA_DIR/etc/nova/api-paste.ini $NOVA_CONF

    # Then we add our own service token to the configuration
    sed -e "s,%SERVICE_TOKEN%,$SERVICE_TOKEN,g" -i $NOVA_CONF/api-paste.ini

    # Finally, we change the pipelines in nova to use keystone
    function replace_pipeline() {
        sed "/\[pipeline:$1\]/,/\[/s/^pipeline = .*/pipeline = $2/" -i $NOVA_CONF/api-paste.ini
    }
    replace_pipeline "ec2cloud" "ec2faultwrap logrequest totoken authtoken keystonecontext cloudrequest authorizer validator ec2executor"
    replace_pipeline "ec2admin" "ec2faultwrap logrequest totoken authtoken keystonecontext adminrequest authorizer ec2executor"
    # allow people to turn off rate limiting for testing, like when using tempest, by setting OSAPI_RATE_LIMIT=" "
    OSAPI_RATE_LIMIT=${OSAPI_RATE_LIMIT:-"ratelimit"}
    replace_pipeline "openstack_compute_api_v2" "faultwrap authtoken keystonecontext $OSAPI_RATE_LIMIT osapi_compute_app_v2"
    replace_pipeline "openstack_volume_api_v1" "faultwrap authtoken keystonecontext $OSAPI_RATE_LIMIT osapi_volume_app_v1"
fi

# Helper to clean iptables rules
function clean_iptables() {
    # Delete rules
    sudo iptables -S -v | sed "s/-c [0-9]* [0-9]* //g" | grep "nova" | grep "\-A" |  sed "s/-A/-D/g" | awk '{print "sudo iptables",$0}' | bash
    # Delete nat rules
    sudo iptables -S -v -t nat | sed "s/-c [0-9]* [0-9]* //g" | grep "nova" |  grep "\-A" | sed "s/-A/-D/g" | awk '{print "sudo iptables -t nat",$0}' | bash
    # Delete chains
    sudo iptables -S -v | sed "s/-c [0-9]* [0-9]* //g" | grep "nova" | grep "\-N" |  sed "s/-N/-X/g" | awk '{print "sudo iptables",$0}' | bash
    # Delete nat chains
    sudo iptables -S -v -t nat | sed "s/-c [0-9]* [0-9]* //g" | grep "nova" |  grep "\-N" | sed "s/-N/-X/g" | awk '{print "sudo iptables -t nat",$0}' | bash
}

if is_service_enabled n-cpu; then

    # Virtualization Configuration
    # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    apt_get install libvirt-bin

    # attempt to load modules: network block device - used to manage qcow images
    sudo modprobe nbd || true

    # Check for kvm (hardware based virtualization).  If unable to initialize
    # kvm, we drop back to the slower emulation mode (qemu).  Note: many systems
    # come with hardware virtualization disabled in BIOS.
    if [[ "$LIBVIRT_TYPE" == "kvm" ]]; then
        sudo modprobe kvm || true
        if [ ! -e /dev/kvm ]; then
            echo "WARNING: Switching to QEMU"
            LIBVIRT_TYPE=qemu
        fi
    fi

    # Install and configure **LXC** if specified.  LXC is another approach to
    # splitting a system into many smaller parts.  LXC uses cgroups and chroot
    # to simulate multiple systems.
    if [[ "$LIBVIRT_TYPE" == "lxc" ]]; then
        if [[ "$DISTRO" > natty ]]; then
            apt_get install cgroup-lite
        else
            cgline="none /cgroup cgroup cpuacct,memory,devices,cpu,freezer,blkio 0 0"
            sudo mkdir -p /cgroup
            if ! grep -q cgroup /etc/fstab; then
                echo "$cgline" | sudo tee -a /etc/fstab
            fi
            if ! mount -n | grep -q cgroup; then
                sudo mount /cgroup
            fi
        fi
    fi

    # The user that nova runs as needs to be member of libvirtd group otherwise
    # nova-compute will be unable to use libvirt.
    sudo usermod -a -G libvirtd `whoami`
    # libvirt detects various settings on startup, as we potentially changed
    # the system configuration (modules, filesystems), we need to restart
    # libvirt to detect those changes.
    sudo /etc/init.d/libvirt-bin restart


    # Instance Storage
    # ~~~~~~~~~~~~~~~~

    # Nova stores each instance in its own directory.
    mkdir -p $NOVA_DIR/instances

    # You can specify a different disk to be mounted and used for backing the
    # virtual machines.  If there is a partition labeled nova-instances we
    # mount it (ext filesystems can be labeled via e2label).
    if [ -L /dev/disk/by-label/nova-instances ]; then
        if ! mount -n | grep -q $NOVA_DIR/instances; then
            sudo mount -L nova-instances $NOVA_DIR/instances
            sudo chown -R `whoami` $NOVA_DIR/instances
        fi
    fi

    # Clean iptables from previous runs
    clean_iptables

    # Destroy old instances
    instances=`virsh list --all | grep $INSTANCE_NAME_PREFIX | sed "s/.*\($INSTANCE_NAME_PREFIX[0-9a-fA-F]*\).*/\1/g"`
    if [ ! "$instances" = "" ]; then
        echo $instances | xargs -n1 virsh destroy || true
        echo $instances | xargs -n1 virsh undefine || true
    fi

    # Logout and delete iscsi sessions
    sudo iscsiadm --mode node | grep $VOLUME_NAME_PREFIX | cut -d " " -f2 | xargs sudo iscsiadm --mode node --logout || true
    sudo iscsiadm --mode node | grep $VOLUME_NAME_PREFIX | cut -d " " -f2 | sudo iscsiadm --mode node --op delete || true

    # Clean out the instances directory.
    sudo rm -rf $NOVA_DIR/instances/*
fi

if is_service_enabled n-net; then
    # Delete traces of nova networks from prior runs
    sudo killall dnsmasq || true
    clean_iptables
    rm -rf $NOVA_DIR/networks
    mkdir -p $NOVA_DIR/networks
fi

# Storage Service
if is_service_enabled swift; then
    # We first do a bit of setup by creating the directories and
    # changing the permissions so we can run it as our user.

    USER_GROUP=$(id -g)
    sudo mkdir -p ${SWIFT_DATA_LOCATION}/drives
    sudo chown -R $USER:${USER_GROUP} ${SWIFT_DATA_LOCATION}

    # We then create a loopback disk and format it to XFS.
    # TODO: Reset disks on new pass.
    if [[ ! -e ${SWIFT_DATA_LOCATION}/drives/images/swift.img ]]; then
        mkdir -p  ${SWIFT_DATA_LOCATION}/drives/images
        sudo touch  ${SWIFT_DATA_LOCATION}/drives/images/swift.img
        sudo chown $USER: ${SWIFT_DATA_LOCATION}/drives/images/swift.img

        dd if=/dev/zero of=${SWIFT_DATA_LOCATION}/drives/images/swift.img \
            bs=1024 count=0 seek=${SWIFT_LOOPBACK_DISK_SIZE}
        mkfs.xfs -f -i size=1024  ${SWIFT_DATA_LOCATION}/drives/images/swift.img
    fi

    # After the drive being created we mount the disk with a few mount
    # options to make it most efficient as possible for swift.
    mkdir -p ${SWIFT_DATA_LOCATION}/drives/sdb1
    if ! egrep -q ${SWIFT_DATA_LOCATION}/drives/sdb1 /proc/mounts; then
        sudo mount -t xfs -o loop,noatime,nodiratime,nobarrier,logbufs=8  \
            ${SWIFT_DATA_LOCATION}/drives/images/swift.img ${SWIFT_DATA_LOCATION}/drives/sdb1
    fi

    # We then create link to that mounted location so swift would know
    # where to go.
    for x in $(seq ${SWIFT_REPLICAS}); do
        sudo ln -sf ${SWIFT_DATA_LOCATION}/drives/sdb1/$x ${SWIFT_DATA_LOCATION}/$x; done

    # We now have to emulate a few different servers into one we
    # create all the directories needed for swift
    for x in $(seq ${SWIFT_REPLICAS}); do
            drive=${SWIFT_DATA_LOCATION}/drives/sdb1/${x}
            node=${SWIFT_DATA_LOCATION}/${x}/node
            node_device=${node}/sdb1
            [[ -d $node ]] && continue
            [[ -d $drive ]] && continue
            sudo install -o ${USER} -g $USER_GROUP -d $drive
            sudo install -o ${USER} -g $USER_GROUP -d $node_device
            sudo chown -R $USER: ${node}
    done

   sudo mkdir -p ${SWIFT_CONFIG_LOCATION}/{object,container,account}-server /var/run/swift
   sudo chown -R $USER: ${SWIFT_CONFIG_LOCATION} /var/run/swift

   # swift-init has a bug using /etc/swift until bug #885595 is fixed
   # we have to create a link
   sudo ln -sf ${SWIFT_CONFIG_LOCATION} /etc/swift

   # Swift use rsync to syncronize between all the different
   # partitions (which make more sense when you have a multi-node
   # setup) we configure it with our version of rsync.
   sed -e "s/%GROUP%/${USER_GROUP}/;s/%USER%/$USER/;s,%SWIFT_DATA_LOCATION%,$SWIFT_DATA_LOCATION," $FILES/swift/rsyncd.conf | sudo tee /etc/rsyncd.conf
   sudo sed -i '/^RSYNC_ENABLE=false/ { s/false/true/ }' /etc/default/rsync

   # By default Swift will be installed with the tempauth middleware
   # which has some default username and password if you have
   # configured keystone it will checkout the directory.
   if is_service_enabled key; then
       swift_auth_server="s3token tokenauth keystone"
   else
       swift_auth_server=tempauth
   fi

   # We do the install of the proxy-server and swift configuration
   # replacing a few directives to match our configuration.
   sed -e "s,%SWIFT_CONFIG_LOCATION%,${SWIFT_CONFIG_LOCATION},g;
        s,%USER%,$USER,g;
        s,%SERVICE_TOKEN%,${SERVICE_TOKEN},g;
        s,%KEYSTONE_SERVICE_PORT%,${KEYSTONE_SERVICE_PORT},g;
        s,%KEYSTONE_SERVICE_HOST%,${KEYSTONE_SERVICE_HOST},g;
        s,%KEYSTONE_AUTH_PORT%,${KEYSTONE_AUTH_PORT},g;
        s,%KEYSTONE_AUTH_HOST%,${KEYSTONE_AUTH_HOST},g;
        s,%KEYSTONE_AUTH_PROTOCOL%,${KEYSTONE_AUTH_PROTOCOL},g;
        s/%AUTH_SERVER%/${swift_auth_server}/g;" \
          $FILES/swift/proxy-server.conf | \
       sudo tee  ${SWIFT_CONFIG_LOCATION}/proxy-server.conf

   sed -e "s/%SWIFT_HASH%/$SWIFT_HASH/" $FILES/swift/swift.conf > ${SWIFT_CONFIG_LOCATION}/swift.conf

   # We need to generate a object/account/proxy configuration
   # emulating 4 nodes on different ports we have a little function
   # that help us doing that.
   function generate_swift_configuration() {
       local server_type=$1
       local bind_port=$2
       local log_facility=$3
       local node_number

       for node_number in $(seq ${SWIFT_REPLICAS}); do
           node_path=${SWIFT_DATA_LOCATION}/${node_number}
           sed -e "s,%SWIFT_CONFIG_LOCATION%,${SWIFT_CONFIG_LOCATION},;s,%USER%,$USER,;s,%NODE_PATH%,${node_path},;s,%BIND_PORT%,${bind_port},;s,%LOG_FACILITY%,${log_facility}," \
               $FILES/swift/${server_type}-server.conf > ${SWIFT_CONFIG_LOCATION}/${server_type}-server/${node_number}.conf
           bind_port=$(( ${bind_port} + 10 ))
           log_facility=$(( ${log_facility} + 1 ))
       done
   }
   generate_swift_configuration object 6010 2
   generate_swift_configuration container 6011 2
   generate_swift_configuration account 6012 2


   # We have some specific configuration for swift for rsyslog. See
   # the file /etc/rsyslog.d/10-swift.conf for more info.
   swift_log_dir=${SWIFT_DATA_LOCATION}/logs
   rm -rf ${swift_log_dir}
   mkdir -p ${swift_log_dir}/hourly
   sudo chown -R syslog:adm ${swift_log_dir}
   sed "s,%SWIFT_LOGDIR%,${swift_log_dir}," $FILES/swift/rsyslog.conf | sudo \
       tee /etc/rsyslog.d/10-swift.conf
   sudo restart rsyslog

   # This is where we create three different rings for swift with
   # different object servers binding on different ports.
   pushd ${SWIFT_CONFIG_LOCATION} >/dev/null && {

       rm -f *.builder *.ring.gz backups/*.builder backups/*.ring.gz

       port_number=6010
       swift-ring-builder object.builder create ${SWIFT_PARTITION_POWER_SIZE} ${SWIFT_REPLICAS} 1
       for x in $(seq ${SWIFT_REPLICAS}); do
           swift-ring-builder object.builder add z${x}-127.0.0.1:${port_number}/sdb1 1
           port_number=$[port_number + 10]
       done
       swift-ring-builder object.builder rebalance

       port_number=6011
       swift-ring-builder container.builder create ${SWIFT_PARTITION_POWER_SIZE} ${SWIFT_REPLICAS} 1
       for x in $(seq ${SWIFT_REPLICAS}); do
           swift-ring-builder container.builder add z${x}-127.0.0.1:${port_number}/sdb1 1
           port_number=$[port_number + 10]
       done
       swift-ring-builder container.builder rebalance

       port_number=6012
       swift-ring-builder account.builder create ${SWIFT_PARTITION_POWER_SIZE} ${SWIFT_REPLICAS} 1
       for x in $(seq ${SWIFT_REPLICAS}); do
           swift-ring-builder account.builder add z${x}-127.0.0.1:${port_number}/sdb1 1
           port_number=$[port_number + 10]
       done
       swift-ring-builder account.builder rebalance

   } && popd >/dev/null

   sudo chmod +x /usr/local/bin/swift-*

   # We then can start rsync.
   sudo /etc/init.d/rsync restart || :

   # TODO: Bring some services in foreground.
   # Launch all services.
   swift-init all start

   unset s swift_hash swift_auth_server
fi

# Volume Service
# --------------

if is_service_enabled n-vol; then
    #
    # Configure a default volume group called 'nova-volumes' for the nova-volume
    # service if it does not yet exist.  If you don't wish to use a file backed
    # volume group, create your own volume group called 'nova-volumes' before
    # invoking stack.sh.
    #
    # By default, the backing file is 2G in size, and is stored in /opt/stack.

    # install the package
    apt_get install tgt

    if ! sudo vgs $VOLUME_GROUP; then
        VOLUME_BACKING_FILE=${VOLUME_BACKING_FILE:-$DEST/nova-volumes-backing-file}
        VOLUME_BACKING_FILE_SIZE=${VOLUME_BACKING_FILE_SIZE:-2052M}
        # Only create if the file doesn't already exists
        [[ -f $VOLUME_BACKING_FILE ]] || truncate -s $VOLUME_BACKING_FILE_SIZE $VOLUME_BACKING_FILE
        DEV=`sudo losetup -f --show $VOLUME_BACKING_FILE`
        # Only create if the loopback device doesn't contain $VOLUME_GROUP
        if ! sudo vgs $VOLUME_GROUP; then sudo vgcreate $VOLUME_GROUP $DEV; fi
    fi

    if sudo vgs $VOLUME_GROUP; then
        # Remove nova iscsi targets
        sudo tgtadm --op show --mode target | grep $VOLUME_NAME_PREFIX | grep Target | cut -f3 -d ' ' | sudo xargs -n1 tgt-admin --delete || true
        # Clean out existing volumes
        for lv in `sudo lvs --noheadings -o lv_name $VOLUME_GROUP`; do
            # VOLUME_NAME_PREFIX prefixes the LVs we want
            if [[ "${lv#$VOLUME_NAME_PREFIX}" != "$lv" ]]; then
                sudo lvremove -f $VOLUME_GROUP/$lv
            fi
        done
    fi

    # tgt in oneiric doesn't restart properly if tgtd isn't running
    # do it in two steps
    sudo stop tgt || true
    sudo start tgt
fi

function add_nova_flag {
    echo "$1" >> $NOVA_CONF/nova.conf
}

# remove legacy nova.conf
rm -f $NOVA_DIR/bin/nova.conf

# (re)create nova.conf
rm -f $NOVA_CONF/nova.conf
add_nova_flag "--verbose"
add_nova_flag "--allow_admin_api"
add_nova_flag "--scheduler_driver=$SCHEDULER"
add_nova_flag "--dhcpbridge_flagfile=$NOVA_CONF/nova.conf"
add_nova_flag "--fixed_range=$FIXED_RANGE"
if is_service_enabled n-obj; then
    add_nova_flag "--s3_host=$SERVICE_HOST"
fi
if is_service_enabled quantum; then
    add_nova_flag "--network_manager=nova.network.quantum.manager.QuantumManager"
    add_nova_flag "--quantum_connection_host=$Q_HOST"
    add_nova_flag "--quantum_connection_port=$Q_PORT"

    if is_service_enabled melange; then
        add_nova_flag "--quantum_ipam_lib=nova.network.quantum.melange_ipam_lib"
        add_nova_flag "--use_melange_mac_generation"
        add_nova_flag "--melange_host=$M_HOST"
        add_nova_flag "--melange_port=$M_PORT"
    fi
    if is_service_enabled q-svc && [[ "$Q_PLUGIN" = "openvswitch" ]]; then
        add_nova_flag "--libvirt_vif_type=ethernet"
        add_nova_flag "--libvirt_vif_driver=nova.virt.libvirt.vif.LibvirtOpenVswitchDriver"
        add_nova_flag "--linuxnet_interface_driver=nova.network.linux_net.LinuxOVSInterfaceDriver"
        add_nova_flag "--quantum_use_dhcp"
    fi
else
    add_nova_flag "--network_manager=nova.network.manager.$NET_MAN"
fi
if is_service_enabled n-vol; then
    add_nova_flag "--volume_group=$VOLUME_GROUP"
    add_nova_flag "--volume_name_template=${VOLUME_NAME_PREFIX}%08x"
    # oneiric no longer supports ietadm
    add_nova_flag "--iscsi_helper=tgtadm"
fi
add_nova_flag "--osapi_compute_extension=nova.api.openstack.compute.contrib.standard_extensions"
add_nova_flag "--my_ip=$HOST_IP"
add_nova_flag "--public_interface=$PUBLIC_INTERFACE"
add_nova_flag "--vlan_interface=$VLAN_INTERFACE"
add_nova_flag "--sql_connection=$BASE_SQL_CONN/nova"
add_nova_flag "--libvirt_type=$LIBVIRT_TYPE"
add_nova_flag "--instance_name_template=${INSTANCE_NAME_PREFIX}%08x"
# All nova-compute workers need to know the vnc configuration options
# These settings don't hurt anything if n-xvnc and n-novnc are disabled
if is_service_enabled n-cpu; then
    NOVNCPROXY_URL=${NOVNCPROXY_URL:-"http://$SERVICE_HOST:6080/vnc_auto.html"}
    add_nova_flag "--novncproxy_base_url=$NOVNCPROXY_URL"
    XVPVNCPROXY_URL=${XVPVNCPROXY_URL:-"http://$SERVICE_HOST:6081/console"}
    add_nova_flag "--xvpvncproxy_base_url=$XVPVNCPROXY_URL"
fi
if [ "$VIRT_DRIVER" = 'xenserver' ]; then
    VNCSERVER_PROXYCLIENT_ADDRESS=${VNCSERVER_PROXYCLIENT_ADDRESS=169.254.0.1}
else
    VNCSERVER_PROXYCLIENT_ADDRESS=${VNCSERVER_PROXYCLIENT_ADDRESS=127.0.0.1}
fi
# Address on which instance vncservers will listen on compute hosts.
# For multi-host, this should be the management ip of the compute host.
VNCSERVER_LISTEN=${VNCSERVER_LISTEN=127.0.0.1}
add_nova_flag "--vncserver_listen=$VNCSERVER_LISTEN"
add_nova_flag "--vncserver_proxyclient_address=$VNCSERVER_PROXYCLIENT_ADDRESS"
add_nova_flag "--api_paste_config=$NOVA_CONF/api-paste.ini"
add_nova_flag "--image_service=nova.image.glance.GlanceImageService"
add_nova_flag "--ec2_dmz_host=$EC2_DMZ_HOST"
add_nova_flag "--rabbit_host=$RABBIT_HOST"
add_nova_flag "--rabbit_password=$RABBIT_PASSWORD"
add_nova_flag "--glance_api_servers=$GLANCE_HOSTPORT"
add_nova_flag "--force_dhcp_release"
if [ -n "$INSTANCES_PATH" ]; then
    add_nova_flag "--instances_path=$INSTANCES_PATH"
fi
if [ "$MULTI_HOST" != "False" ]; then
    add_nova_flag "--multi_host"
    add_nova_flag "--send_arp_for_ha"
fi
if [ "$SYSLOG" != "False" ]; then
    add_nova_flag "--use_syslog"
fi

# You can define extra nova conf flags by defining the array EXTRA_FLAGS,
# For Example: EXTRA_FLAGS=(--foo --bar=2)
for I in "${EXTRA_FLAGS[@]}"; do
    add_nova_flag $I
done

# XenServer
# ---------

if [ "$VIRT_DRIVER" = 'xenserver' ]; then
    read_password XENAPI_PASSWORD "ENTER A PASSWORD TO USE FOR XEN."
    add_nova_flag "--connection_type=xenapi"
    add_nova_flag "--xenapi_connection_url=http://169.254.0.1"
    add_nova_flag "--xenapi_connection_username=root"
    add_nova_flag "--xenapi_connection_password=$XENAPI_PASSWORD"
    add_nova_flag "--noflat_injected"
    add_nova_flag "--flat_interface=eth1"
    add_nova_flag "--flat_network_bridge=xapi1"
    add_nova_flag "--public_interface=eth3"
    # Need to avoid crash due to new firewall support
    XEN_FIREWALL_DRIVER=${XEN_FIREWALL_DRIVER:-"nova.virt.firewall.IptablesFirewallDriver"}
    add_nova_flag "--firewall_driver=$XEN_FIREWALL_DRIVER"
else
    add_nova_flag "--connection_type=libvirt"
    LIBVIRT_FIREWALL_DRIVER=${LIBVIRT_FIREWALL_DRIVER:-"nova.virt.libvirt.firewall.IptablesFirewallDriver"}
    add_nova_flag "--firewall_driver=$LIBVIRT_FIREWALL_DRIVER"
    add_nova_flag "--flat_network_bridge=$FLAT_NETWORK_BRIDGE"
    if [ -n "$FLAT_INTERFACE" ]; then
        add_nova_flag "--flat_interface=$FLAT_INTERFACE"
    fi
fi

# Nova Database
# ~~~~~~~~~~~~~

# All nova components talk to a central database.  We will need to do this step
# only once for an entire cluster.

if is_service_enabled mysql; then
    # (re)create nova database
    mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'DROP DATABASE IF EXISTS nova;'
    mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'CREATE DATABASE nova;'

    # (re)create nova database
    $NOVA_DIR/bin/nova-manage db sync
fi


# Launch Services
# ===============

# nova api crashes if we start it with a regular screen command,
# so send the start command by forcing text into the window.
# Only run the services specified in ``ENABLED_SERVICES``

# Our screenrc file builder
function screen_rc {
    SCREENRC=$TOP_DIR/stack-screenrc
    if [[ ! -e $SCREENRC ]]; then
        # Name the screen session
        echo "sessionname stack" > $SCREENRC
        # Set a reasonable statusbar
        echo 'hardstatus alwayslastline "%-Lw%{= BW}%50>%n%f* %t%{-}%+Lw%< %= %H"' >> $SCREENRC
        echo "screen -t stack bash" >> $SCREENRC
    fi
    # If this service doesn't already exist in the screenrc file
    if ! grep $1 $SCREENRC 2>&1 > /dev/null; then
        NL=`echo -ne '\015'`
        echo "screen -t $1 bash" >> $SCREENRC
        echo "stuff \"$2$NL\"" >> $SCREENRC
    fi
}

# Our screen helper to launch a service in a hidden named screen
function screen_it {
    NL=`echo -ne '\015'`
    if is_service_enabled $1; then
        # Append the service to the screen rc file
        screen_rc "$1" "$2"

        screen -S stack -X screen -t $1
        # sleep to allow bash to be ready to be send the command - we are
        # creating a new window in screen and then sends characters, so if
        # bash isn't running by the time we send the command, nothing happens
        sleep 1.5
        screen -S stack -p $1 -X stuff "$2$NL"
    fi
}

# create a new named screen to run processes in
screen -d -m -S stack -t stack -s /bin/bash
sleep 1
# set a reasonable statusbar
screen -r stack -X hardstatus alwayslastline "%-Lw%{= BW}%50>%n%f* %t%{-}%+Lw%< %= %H"

# launch the glance registry service
if is_service_enabled g-reg; then
    screen_it g-reg "cd $GLANCE_DIR; bin/glance-registry --config-file=etc/glance-registry.conf"
fi

# launch the glance api and wait for it to answer before continuing
if is_service_enabled g-api; then
    screen_it g-api "cd $GLANCE_DIR; bin/glance-api --config-file=etc/glance-api.conf"
    echo "Waiting for g-api ($GLANCE_HOSTPORT) to start..."
    if ! timeout $SERVICE_TIMEOUT sh -c "while ! http_proxy= wget -q -O- http://$GLANCE_HOSTPORT; do sleep 1; done"; then
      echo "g-api did not start"
      exit 1
    fi
fi

if is_service_enabled key; then
    # (re)create keystone database
    mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'DROP DATABASE IF EXISTS keystone;'
    mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'CREATE DATABASE keystone;'

    # Configure keystone.conf
    KEYSTONE_CONF=$KEYSTONE_DIR/etc/keystone.conf
    cp $FILES/keystone.conf $KEYSTONE_CONF
    sudo sed -e "s,%SQL_CONN%,$BASE_SQL_CONN/keystone,g" -i $KEYSTONE_CONF
    sudo sed -e "s,%DEST%,$DEST,g" -i $KEYSTONE_CONF
    sudo sed -e "s,%SERVICE_TOKEN%,$SERVICE_TOKEN,g" -i $KEYSTONE_CONF
    sudo sed -e "s,%KEYSTONE_DIR%,$KEYSTONE_DIR,g" -i $KEYSTONE_CONF

    KEYSTONE_CATALOG=$KEYSTONE_DIR/etc/default_catalog.templates
    cp $FILES/default_catalog.templates $KEYSTONE_CATALOG

    # Add swift endpoints to service catalog if swift is enabled
    if is_service_enabled swift; then
        echo "catalog.RegionOne.object_store.publicURL = http://%SERVICE_HOST%:8080/v1/AUTH_\$(tenant_id)s" >> $KEYSTONE_CATALOG
        echo "catalog.RegionOne.object_store.adminURL = http://%SERVICE_HOST%:8080/" >> $KEYSTONE_CATALOG
        echo "catalog.RegionOne.object_store.internalURL = http://%SERVICE_HOST%:8080/v1/AUTH_\$(tenant_id)s" >> $KEYSTONE_CATALOG
        echo "catalog.RegionOne.object_store.name = 'Swift Service'" >> $KEYSTONE_CATALOG
    fi

    # Add quantum endpoints to service catalog if quantum is enabled
    if is_service_enabled quantum; then
        echo "catalog.RegionOne.network.publicURL = http://%SERVICE_HOST%:9696/" >> $KEYSTONE_CATALOG
        echo "catalog.RegionOne.network.adminURL = http://%SERVICE_HOST%:9696/" >> $KEYSTONE_CATALOG
        echo "catalog.RegionOne.network.internalURL = http://%SERVICE_HOST%:9696/" >> $KEYSTONE_CATALOG
        echo "catalog.RegionOne.network.name = 'Quantum Service'" >> $KEYSTONE_CATALOG
    fi

    sudo sed -e "s,%SERVICE_HOST%,$SERVICE_HOST,g" -i $KEYSTONE_CATALOG


    if [ "$SYSLOG" != "False" ]; then
        cp $KEYSTONE_DIR/etc/logging.conf.sample $KEYSTONE_DIR/etc/logging.conf
        sed -i -e '/^handlers=devel$/s/=devel/=production/' \
            $KEYSTONE_DIR/etc/logging.conf
        sed -i -e "/^log_file/s/log_file/\#log_file/" \
            $KEYSTONE_DIR/etc/keystone.conf
        KEYSTONE_LOG_CONFIG="--log-config $KEYSTONE_DIR/etc/logging.conf"
    fi
fi

# launch the keystone and wait for it to answer before continuing
if is_service_enabled key; then
    screen_it key "cd $KEYSTONE_DIR && $KEYSTONE_DIR/bin/keystone-all --config-file $KEYSTONE_CONF $KEYSTONE_LOG_CONFIG -d --debug"
    echo "Waiting for keystone to start..."
    if ! timeout $SERVICE_TIMEOUT sh -c "while ! http_proxy= wget -q -O- $KEYSTONE_SERVICE_PROTOCOL://$KEYSTONE_SERVICE_HOST:$KEYSTONE_SERVICE_PORT/v2.0/; do sleep 1; done"; then
      echo "keystone did not start"
      exit 1
    fi

    # initialize keystone with default users/endpoints
    pushd $KEYSTONE_DIR
    $KEYSTONE_DIR/bin/keystone-manage db_sync
    popd

    # keystone_data.sh creates services, admin and demo users, and roles.
    SERVICE_ENDPOINT=$KEYSTONE_AUTH_PROTOCOL://$KEYSTONE_AUTH_HOST:$KEYSTONE_AUTH_PORT/v2.0
    ADMIN_PASSWORD=$ADMIN_PASSWORD SERVICE_TOKEN=$SERVICE_TOKEN SERVICE_ENDPOINT=$SERVICE_ENDPOINT DEVSTACK_DIR=$TOP_DIR ENABLED_SERVICES=$ENABLED_SERVICES bash $FILES/keystone_data.sh
fi


# launch the nova-api and wait for it to answer before continuing
if is_service_enabled n-api; then
    screen_it n-api "cd $NOVA_DIR && $NOVA_DIR/bin/nova-api"
    echo "Waiting for nova-api to start..."
    if ! timeout $SERVICE_TIMEOUT sh -c "while ! http_proxy= wget -q -O- http://127.0.0.1:8774; do sleep 1; done"; then
      echo "nova-api did not start"
      exit 1
    fi
fi

# Quantum service
if is_service_enabled q-svc; then
    if [[ "$Q_PLUGIN" = "openvswitch" ]]; then
        # Install deps
        # FIXME add to files/apts/quantum, but don't install if not needed!
        apt_get install openvswitch-switch openvswitch-datapath-dkms
        # Create database for the plugin/agent
        if is_service_enabled mysql; then
            mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'DROP DATABASE IF EXISTS ovs_quantum;'
            mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'CREATE DATABASE IF NOT EXISTS ovs_quantum;'
        else
            echo "mysql must be enabled in order to use the $Q_PLUGIN Quantum plugin."
            exit 1
        fi
        QUANTUM_PLUGIN_INI_FILE=$QUANTUM_DIR/etc/plugins.ini
        # Make sure we're using the openvswitch plugin
        sed -i -e "s/^provider =.*$/provider = quantum.plugins.openvswitch.ovs_quantum_plugin.OVSQuantumPlugin/g" $QUANTUM_PLUGIN_INI_FILE
    fi
   screen_it q-svc "cd $QUANTUM_DIR && PYTHONPATH=.:$QUANTUM_CLIENT_DIR:$PYTHONPATH python $QUANTUM_DIR/bin/quantum-server $QUANTUM_DIR/etc/quantum.conf"
fi

# Quantum agent (for compute nodes)
if is_service_enabled q-agt; then
    if [[ "$Q_PLUGIN" = "openvswitch" ]]; then
        # Set up integration bridge
        OVS_BRIDGE=${OVS_BRIDGE:-br-int}
        sudo ovs-vsctl --no-wait -- --if-exists del-br $OVS_BRIDGE
        sudo ovs-vsctl --no-wait add-br $OVS_BRIDGE
        sudo ovs-vsctl --no-wait br-set-external-id $OVS_BRIDGE bridge-id br-int

       # Start up the quantum <-> openvswitch agent
       QUANTUM_OVS_CONFIG_FILE=$QUANTUM_DIR/etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini
       sed -i -e "s/^sql_connection =.*$/sql_connection = mysql:\/\/$MYSQL_USER:$MYSQL_PASSWORD@$MYSQL_HOST\/ovs_quantum/g" $QUANTUM_OVS_CONFIG_FILE
       screen_it q-agt "sleep 4; sudo python $QUANTUM_DIR/quantum/plugins/openvswitch/agent/ovs_quantum_agent.py $QUANTUM_OVS_CONFIG_FILE -v"
    fi

fi

# Melange service
if is_service_enabled m-svc; then
    if is_service_enabled mysql; then
        mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'DROP DATABASE IF EXISTS melange;'
        mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'CREATE DATABASE melange;'
    else
        echo "mysql must be enabled in order to use the $Q_PLUGIN Quantum plugin."
        exit 1
    fi
    MELANGE_CONFIG_FILE=$MELANGE_DIR/etc/melange/melange.conf
    cp $MELANGE_CONFIG_FILE.sample $MELANGE_CONFIG_FILE
    sed -i -e "s/^sql_connection =.*$/sql_connection = mysql:\/\/$MYSQL_USER:$MYSQL_PASSWORD@$MYSQL_HOST\/melange/g" $MELANGE_CONFIG_FILE
    cd $MELANGE_DIR && PYTHONPATH=.:$PYTHONPATH python $MELANGE_DIR/bin/melange-manage --config-file=$MELANGE_CONFIG_FILE db_sync
    screen_it m-svc "cd $MELANGE_DIR && PYTHONPATH=.:$PYTHONPATH python $MELANGE_DIR/bin/melange-server --config-file=$MELANGE_CONFIG_FILE"
    echo "Waiting for melange to start..."
    if ! timeout $SERVICE_TIMEOUT sh -c "while ! http_proxy= wget -q -O- http://127.0.0.1:9898; do sleep 1; done"; then
      echo "melange-server did not start"
      exit 1
    fi
    melange mac_address_range create cidr=$M_MAC_RANGE
fi

# If we're using Quantum (i.e. q-svc is enabled), network creation has to
# happen after we've started the Quantum service.
if is_service_enabled mysql; then
    # create a small network
    $NOVA_DIR/bin/nova-manage network create private $FIXED_RANGE 1 $FIXED_NETWORK_SIZE

    if is_service_enabled q-svc; then
        echo "Not creating floating IPs (not supported by QuantumManager)"
    else
        # create some floating ips
        $NOVA_DIR/bin/nova-manage floating create $FLOATING_RANGE

        # create a second pool
        $NOVA_DIR/bin/nova-manage floating create --ip_range=$TEST_FLOATING_RANGE --pool=$TEST_FLOATING_POOL
    fi
fi


# Launching nova-compute should be as simple as running ``nova-compute`` but
# have to do a little more than that in our script.  Since we add the group
# ``libvirtd`` to our user in this script, when nova-compute is run it is
# within the context of our original shell (so our groups won't be updated).
# Use 'sg' to execute nova-compute as a member of the libvirtd group.
screen_it n-cpu "cd $NOVA_DIR && sg libvirtd $NOVA_DIR/bin/nova-compute"
screen_it n-crt "cd $NOVA_DIR && $NOVA_DIR/bin/nova-cert"
screen_it n-obj "cd $NOVA_DIR && $NOVA_DIR/bin/nova-objectstore"
screen_it n-vol "cd $NOVA_DIR && $NOVA_DIR/bin/nova-volume"
screen_it n-net "cd $NOVA_DIR && $NOVA_DIR/bin/nova-network"
screen_it n-sch "cd $NOVA_DIR && $NOVA_DIR/bin/nova-scheduler"
if is_service_enabled n-novnc; then
    screen_it n-novnc "cd $NOVNC_DIR && ./utils/nova-novncproxy --flagfile $NOVA_CONF/nova.conf --web ."
fi
if is_service_enabled n-xvnc; then
    screen_it n-xvnc "cd $NOVA_DIR && ./bin/nova-xvpvncproxy --flagfile $NOVA_CONF/nova.conf"
fi
if is_service_enabled n-cauth; then
    screen_it n-cauth "cd $NOVA_DIR && ./bin/nova-consoleauth"
fi
if is_service_enabled horizon; then
    screen_it horizon "cd $HORIZON_DIR && sudo tail -f /var/log/apache2/error.log"
fi

# Install Images
# ==============

# Upload an image to glance.
#
# The default image is a small ***TTY*** testing image, which lets you login
# the username/password of root/password.
#
# TTY also uses cloud-init, supporting login via keypair and sending scripts as
# userdata.  See https://help.ubuntu.com/community/CloudInit for more on cloud-init
#
# Override ``IMAGE_URLS`` with a comma-separated list of uec images.
#
#  * **natty**: http://uec-images.ubuntu.com/natty/current/natty-server-cloudimg-amd64.tar.gz
#  * **oneiric**: http://uec-images.ubuntu.com/oneiric/current/oneiric-server-cloudimg-amd64.tar.gz

if is_service_enabled g-reg; then
    # Create a directory for the downloaded image tarballs.
    mkdir -p $FILES/images

    ADMIN_USER=admin
    ADMIN_TENANT=admin
    TOKEN=`curl -s -d  "{\"auth\":{\"passwordCredentials\": {\"username\": \"$ADMIN_USER\", \"password\": \"$ADMIN_PASSWORD\"}, \"tenantName\": \"$ADMIN_TENANT\"}}" -H "Content-type: application/json" http://$HOST_IP:5000/v2.0/tokens | python -c "import sys; import json; tok = json.loads(sys.stdin.read()); print tok['access']['token']['id'];"`

    # Option to upload legacy ami-tty, which works with xenserver
    if [ $UPLOAD_LEGACY_TTY ]; then
        if [ ! -f $FILES/tty.tgz ]; then
            wget -c http://images.ansolabs.com/tty.tgz -O $FILES/tty.tgz
        fi

        tar -zxf $FILES/tty.tgz -C $FILES/images
        RVAL=`glance add -A $TOKEN name="tty-kernel" is_public=true container_format=aki disk_format=aki < $FILES/images/aki-tty/image`
        KERNEL_ID=`echo $RVAL | cut -d":" -f2 | tr -d " "`
        RVAL=`glance add -A $TOKEN name="tty-ramdisk" is_public=true container_format=ari disk_format=ari < $FILES/images/ari-tty/image`
        RAMDISK_ID=`echo $RVAL | cut -d":" -f2 | tr -d " "`
        glance add -A $TOKEN name="tty" is_public=true container_format=ami disk_format=ami kernel_id=$KERNEL_ID ramdisk_id=$RAMDISK_ID < $FILES/images/ami-tty/image
    fi

    for image_url in ${IMAGE_URLS//,/ }; do
        # Downloads the image (uec ami+aki style), then extracts it.
        IMAGE_FNAME=`basename "$image_url"`
        if [ ! -f $FILES/$IMAGE_FNAME ]; then
            #wget -c $image_url -O $FILES/$IMAGE_FNAME
	    echo "$image_url"
        fi

        KERNEL=""
        RAMDISK=""
        case "$IMAGE_FNAME" in
            *.tar.gz|*.tgz)
                # Extract ami and aki files
                [ "${IMAGE_FNAME%.tar.gz}" != "$IMAGE_FNAME" ] &&
                    IMAGE_NAME="${IMAGE_FNAME%.tar.gz}" ||
                    IMAGE_NAME="${IMAGE_FNAME%.tgz}"
                xdir="$FILES/images/$IMAGE_NAME"
                rm -Rf "$xdir";
                mkdir "$xdir"
                tar -zxf $FILES/$IMAGE_FNAME -C "$xdir"
                KERNEL=$(for f in "$xdir/"*-vmlinuz*; do
                         [ -f "$f" ] && echo "$f" && break; done; true)
                RAMDISK=$(for f in "$xdir/"*-initrd*; do
                         [ -f "$f" ] && echo "$f" && break; done; true)
                IMAGE=$(for f in "$xdir/"*.img; do
                         [ -f "$f" ] && echo "$f" && break; done; true)
                [ -n "$IMAGE_NAME" ]
                IMAGE_NAME=$(basename "$IMAGE" ".img")
                ;;
            *.img)
                IMAGE="$FILES/$IMAGE_FNAME";
                IMAGE_NAME=$(basename "$IMAGE" ".img")
                ;;
            *.img.gz)
                IMAGE="$FILES/${IMAGE_FNAME}"
                IMAGE_NAME=$(basename "$IMAGE" ".img.gz")
                ;;
            *) echo "Do not know what to do with $IMAGE_FNAME"; false;;
        esac

        # Use glance client to add the kernel the root filesystem.
        # We parse the results of the first upload to get the glance ID of the
        # kernel for use when uploading the root filesystem.
        KERNEL_ID=""; RAMDISK_ID="";
        if [ -n "$KERNEL" ]; then
            RVAL=`glance add -A $TOKEN name="$IMAGE_NAME-kernel" is_public=true container_format=aki disk_format=aki < "$KERNEL"`
            KERNEL_ID=`echo $RVAL | cut -d":" -f2 | tr -d " "`
        fi
        if [ -n "$RAMDISK" ]; then
            RVAL=`glance add -A $TOKEN name="$IMAGE_NAME-ramdisk" is_public=true container_format=ari disk_format=ari < "$RAMDISK"`
            RAMDISK_ID=`echo $RVAL | cut -d":" -f2 | tr -d " "`
        fi
        glance add -A $TOKEN name="${IMAGE_NAME%.img}" is_public=true container_format=ami disk_format=ami ${KERNEL_ID:+kernel_id=$KERNEL_ID} ${RAMDISK_ID:+ramdisk_id=$RAMDISK_ID} < <(zcat --force "${IMAGE}")
    done
fi

# Fin
# ===

set +o xtrace

# Using the cloud
# ===============

echo ""
echo ""
echo ""

# If you installed the horizon on this server, then you should be able
# to access the site using your browser.
if is_service_enabled horizon; then
    echo "horizon is now available at http://$SERVICE_HOST/"
fi

# If keystone is present, you can point nova cli to this server
if is_service_enabled key; then
    echo "keystone is serving at $KEYSTONE_SERVICE_PROTOCOL://$KEYSTONE_SERVICE_HOST:$KEYSTONE_SERVICE_PORT/v2.0/"
    echo "examples on using novaclient command line is in exercise.sh"
    echo "the default users are: admin and demo"
    echo "the password: $ADMIN_PASSWORD"
fi

# Echo HOST_IP - useful for build_uec.sh, which uses dhcp to give the instance an address
echo "This is your host ip: $HOST_IP"

# Indicate how long this took to run (bash maintained variable 'SECONDS')
echo "stack.sh completed in $SECONDS seconds."
