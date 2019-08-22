#!/bin/bash
#############################################
#
# MASTER_ADDRESSES must be a comma delimited environment variable
# HOSTGROUPS must be a comma delimted environment variable
# SELF_HOSTNAME must be set
# PEER_ADDRESSES must be set
# DEBUG is a boolean, accepts 1 or true
#
#############################################

#Imported from start.sh
mkdir -p /etc/snmp
touch /etc/snmp/snmp.local.conf
echo "mibs +all" >> /etc/snmp/snmp.local.conf
mv -f mibs/* /usr/share/snmp/mibs
chmod g+w /usr/share/snmp/mibs
chown root:apache /usr/share/snmp/mibs

mkdir -p /opt/monitor/.ssh
mkdir -p /root/.ssh

chmod -R 700 /opt/monitor/.ssh
chmod -R 700 /root/.ssh

mv -f /usr/libexec/entrypoint.d/sshd/sshd_config /etc/ssh/sshd_config
chown root /etc/ssh/sshd_config

cp -f /usr/libexec/entrypoint.d/ssh/* /root/.ssh/
mv -f /usr/libexec/entrypoint.d/ssh/* /opt/monitor/.ssh/

chmod 600 /etc/ssh/sshd_config

chmod -R 600 /root/.ssh/id_rsa
chmod -R 640 /root/.ssh/authorized_keys
chmod -R 644 /root/.ssh/id_rsa.pub
chmod -R 600 /root/.ssh/config

chmod -R 600 /opt/monitor/.ssh/id_rsa
chmod -R 640 /opt/monitor/.ssh/authorized_keys
chmod -R 644 /opt/monitor/.ssh/id_rsa.pub
chmod -R 600 /opt/monitor/.ssh/config

chown -R root /root/.ssh
chown -R monitor /opt/monitor/.ssh

chmod -R +x /usr/libexec/entrypoint.d/hooks/ \
chmod +x /usr/libexec/entrypoint.d/entrypoint.sh \
chmod +x /usr/libexec/entrypoint.d/hooks.py \
mv -f /usr/libexec/entrypoint.d/tmux.conf /etc/tmux.conf


# Create Array From Comma Delimited List
#masters=(${MASTER_ADDRESSES//,/ })
#peers=(${PEER_HOSTNAMES//,/ })

# set default password to your set variable 'monitor' by default
echo "root:${ROOT_PASSWORD}" | chpasswd

print(){
    if [ $1 == "info" ];then 
        echo -e '\033[36m' [INFO] $2 '\033[39;49m'
    elif [ $1 == "warn" ];then
        echo -e '\033[33m' [WARN] $2 '\033[39;49m'
    elif [ $1 == "error" ]; then
        echo -e '\033[31m' [ERROR] $2 '\033[39;49m'
    elif [ $1 == "success" ]; then
        echo -e '\033[32m' [SUCCESS] $2 '\033[39;49m'
    fi 
}

trigger_hooks() {
    echo "Triggering ${1} hooks"
    /usr/libexec/entrypoint.d/hooks.py $1
}

import_backup() {
    if [ ! -z "${IMPORT_BACKUP}" ]; then
        file="/usr/libexec/entrypoint.d/backups/${IMPORT_BACKUP}"
        if [ ! -e "$file" ]; then
            echo -e "Error importing backup. Backup file ${file} does not exist."
        else
            echo -e "Backup file found. Importing: ${file} ..."
    		op5-restore -n -b ${file}
    		# remove all peer and poller nodes
    		for node in `mon node list --type=peer,poller`; do mon node remove "$node"; done;
    		mon stop
        fi
    fi
}

import_license() {
    if [ ! -z "$LICENSE_KEY" ]; then
    	file="/usr/libexec/entrypoint.d/licenses/${LICENSE_KEY}"
    	if [ ! -e "$file" ]; then
            echo -e "Error importing license. License file ${file} does not exist."
    	else
    		if [[ "$file" =~ \.lic$ ]]; then
    			echo -e "License file found. Importing license file: ${file} ..."
    			mv $file /etc/op5license/op5license.lic
    			chown apache:apache /etc/op5license/op5license.lic
    			chmod 664 /etc/op5license/op5license.lic
    		else
    			echo -e "Unable to import license file. License file extension must be .lic"
    		fi
    	fi
    fi
}

service_online(){
    service sshd start
    service mysqld start
    service merlind start
    service naemon start
    service httpd start
    # service nrpe start
    # service processor start
    service rrdcached start
    service synergy start
    # service smsd start
    # service collector start
}

advertise_masters(){
    # Create Array From Comma Delimited List
    masters=(${MASTER_ADDRESSES//,/ })
    for i in "${!masters[@]}"
        do
            if [ $1 == "add" ]; then
                print "info" "Performing Add On ${masters[i]}"
                mon node add ${masters[i]} type=master
                mon node ctrl --type=master mon node add ${SELF_HOSTNAME} type=poller hostgroup=${HOSTGROUPS} takeover=no
	            #mon node ctrl  ${masters[i]} -- /usr/local/scripts/add_sync.sh ${SELF_HOSTNAME}
                mon node ctrl --type=master mon restart
                grep -q "notifies = no" /opt/monitor/op5/merlin/merlin.conf || sed -i '/module {/a\        notifies = no' /opt/monitor/op5/merlin/merlin.conf
            else
                 for node in `mon node list --type=master`
                    do 
                        print "info" "Performing Remove On $node"
                        mon node ctrl "$node" mon node remove ${SELF_HOSTNAME}
                        mon node ctrl "$node" mon restart
                        mon node remove "$node"
                    done
            fi
        done
}

advertise_peers(){
    # Create Array From Comma Delimited List
    peers=(${PEER_HOSTNAMES//,/ })
    if [ $1 == "add" ]; then
        for i in "${!peers[@]}"
            do
                    if [[ "$?" == "0" ]]; then
                        print "info" "Performing Add On ${peers[i]}"
                        mon node add ${peers[i]} type=peer
                        mon node ctrl ${peers[i]} mon node add ${SELF_HOSTNAME} type=peer
                        #mon node ctrl  ${masters[i]} -- /usr/local/scripts/add_sync.sh ${SELF_HOSTNAME}
                        mon node ctrl ${peers[i]} mon restart
                    else
                        print "error" "${peers[i]} not up, ignoring."
                    fi
            done
     else
		for node in `mon node list --type=peer`
            do 
                print "info" "Performing Remove On $node"
                mon node ctrl "$node" mon node remove ${SELF_HOSTNAME}
                mon node ctrl "$node" mon restart
                mon node remove "$node"
            done

    fi
}

get_config(){
    # Only getting config from one master because mon oconf always exits 0
    # The fetch will initiate a restart of the the local merlind.
    # This should be the only time we need to to restart locally since new pollers will restart us.
    print "info" "Syncing Configuration With ${masters[0]}"
    mon node ctrl ${masters[0]} asmonitor mon oconf push ${SELF_HOSTNAME}
}


shutdown_sigend(){
    # If container is gracefully shutdown with SIGTERM (e.g. docker stop), remove
    # pre-emptively remove itself
    print "warn" "SIGTERM Caught! Removing From Cluster"
    advertise_peers remove
    advertise_masters remove
    kill ${!}; trigger_hooks poststop
}


keep_swimming(){
    # This function should be the last thing to run. This is how the Container will
    # persist. Under normal conditions we show a tail of merlins log and fork it 
    # because this script needs to be PID 1 with NO CHILDREN due to the way parent
    # processes handle SIGTERM                                                      
    # The container must be run with -it for proper console access
    
    trigger_hooks poststart
    if [ "${debugging}" == "1" ]; then
        read -n1 -r -p "Press Any Key To Enter The Debug Console..."
        debug_console
    else    
        
        print "info" "Getting Config From Master"
        get_config

        tail -f /var/log/op5/merlin/daemon.log &
        wait $!
        
    fi
}

debug_console(){
    tmux new-session -d '/bin/bash' \; rename-window -t 0 Shell \; new-window -d 'multitail --mergeall /var/log/op5/merlin/daemon.log /var/log/op5/merlin/neb.log' \; rename-window -t 1 Merlind \; attach
}

check_debug(){
    # This should be the first thing to run. Other functions that need to
    # figure out if we are in debug mode should check if ${debugging} is 1
    if [ "${DEBUG,,}" == "true" ] || [ "${DEBUG}" == "1" ]; then
        debugging=1
        print "warn" "DEBUG INFORMATION WILL BE DISPLAYED"
        run_debug
    else
        return
    fi
}


run_debug(){
    # If debugging is 1, anything to run before the debug console
    # should be placed here.
    if [[ "${IS_POLLER}" =~ ^(yes|YES|Yes)$ ]]; then
        if [ -z ${MASTER_ADDRESSES} ]; then
            print "error" "No Master Addresses Are Set!"
        else
            print "success" "Master Addresses Are: ${MASTER_ADDRESSES}"
        fi
        if [ -z ${HOSTGROUPS} ]; then
            print "error" "I Am Not A Member Of Any Hostgroups!"
        else
            print "success" "My Hostgroups Are: ${HOSTGROUPS}"
        fi
        if [ -z ${SELF_HOSTNAME} ]; then
            print "error" "Hostname Is Not Set!"
        else
            print "success" "My Hostname Is: ${SELF_HOSTNAME}"
        fi
    fi
    if [[ "${IS_PEER}" =~ ^(yes|YES|Yes)$ ]]; then
        if [ -z ${PEER_ADDRESSES} ]; then
            print "warn" "No Peer Addresses Are Set!"
        else
            print "success" "Peer Addresses Are: ${PEER_ADDRESSES}"
        fi
        if [ -z ${SELF_HOSTNAME} ]; then
            print "error" "Hostname Is Not Set!"
        else
            print "success" "My Hostname Is: ${SELF_HOSTNAME}"
        fi
    fi
    
    # Change OP5 Log levels 
    sed -i 's/level:.*/level: debug/' /etc/op5/log.yml
    sed -i 's/log_level = info;/log_level = debug;/' /opt/monitor/op5/merlin/merlin.conf

}

volume_mount(){
    if [[ "${VOLUME_MOUNT}" =~ ^(yes|YES|Yes)$ ]]; then    
        if [[ "${VOLUME_INITIALIZE}" =~ ^(yes|YES|Yes)$ ]]; then
            print "info" "Initializing Local Persistent Storage"
	        # mkdir ${VOLUME_PATH}/etc
	        # mkdir ${VOLUME_PATH}/ssh
	        # mkdir ${VOLUME_PATH}/perfdata
	        # mkdir ${VOLUME_PATH}/mysql
	        mkdir ${VOLUME_PATH}/merlin
	        mv /opt/monitor/etc $VOLUME_PATH/
            mv /opt/monitor/.ssh $VOLUME_PATH/
            mv /opt/monitor/op5/pnp/perfdata $VOLUME_PATH/
            mv /var/lib/mysql $VOLUME_PATH/
            mv /opt/monitor/op5/merlin/merin.conf $VOLUME_PATH/merin/merlin.conf
        else
            print "info" "Local Persistent Storage Existing Assumed"
        fi
        if [ -z ${VOLUME_PATH} ]; then
            print "warn" "Volume Path Is Not Set!"
        else
            print "info" "The persistent volume path is: ${VOLUME_PATH}"
	        ln -s ${VOLUME_PATH}/etc /opt/monitor/etc
	        ln -s ${VOLUME_PATH}/.ssh /opt/monitor/.ssh
	        ln -s ${VOLUME_PATH}/perfdata /opt/monitor/op5/pnp/
	        ln -s ${VOLUME_PATH}/mysql /var/lib/mysql
	        ln -s ${VOLUME_PATH}/merlin/merlin.conf /opt/monitor/op5/merlin/merlin.conf
        fi                                                             
    fi                                                                 
}

set_default_route(){
    BGP_ADDR=$(ip addr  | grep "scope global lo"   | tr '/' ' '| tr -s " " | tr " " "\n" | grep -A1 inet | tail -1)
    GW_INT=$(ip route | grep default | tr -s " " | tr " " "\n"  | grep -A1 dev  | tail -1)
    GW_ADDR=$(ip route | grep default | tr -s " " | tr " " "\n"  | grep -A1 via  | tail -1)
    GW_SRC_ADDR=$(ip route | grep default | tr -s " " | tr " " "\n"  | grep -A1 src  | tail -1)

    #echo "OP5_BGP_ADDR: $OP5_BGP_ADDR"
    #echo "   BGP_ADDR: $BGP_ADDR"
    #echo "GW_SRC_ADDR: $GW_SRC_ADDR"
    #echo "    GW_ADDR: $GW_ADDR"
    #echo "     GW_INT: $GW_INT"

    EXITCODE=1

    if [ "x" = "x$OP5_BGP_ADDR" ]; then
        echo "No configured BGP addr found, quitting"
        exit $EXITCODE
    fi

    EXITCODE=$(($EXITCODE + 1))

    if [ "x" = "x$BGP_ADDR" ]; then
        echo "No BGP addr found, quitting"
        exit $EXITCODE
    fi

    EXITCODE=$(($EXITCODE + 1))

    if [ "x$OP5_BGP_ADDR" != "x$BGP_ADDR" ]; then
        echo "Configured BGP address $OP5_BGP_ADDR does not match detected address $BGP_ADDR, quitting"
        exit $EXITCODE
    fi

    EXITCODE=$(($EXITCODE + 1))

    if [ "x" = "x$GW_ADDR" ]; then
        echo "Could not determine gateway address, quitting"
        exit $EXITCODE
    fi

    EXITCODE=$(($EXITCODE + 1))

    if [ "x" = "x$GW_INT" ]; then
        echo "Could not determine gateway interface, quitting"
        exit $EXITCODE
    fi

    EXITCODE=$(($EXITCODE + 1))

    ## route set correctly
    if [ "x$OP5_BGP_ADDR" = "x$GW_SRC_ADDR" ]; then
        echo "Routing is correct. Exiting without changes"
        exit 0
    fi

    echo "Source-address needs setting"

    ## delete the current default route
    ip route del default

    ## add the new one, with the correct source IP
    ip route add default via $GW_ADDR dev $GW_INT src $BGP_ADDR

    ## verify/fix
    CUR_ROUTE=$(ip route | grep default)
    if [ "x" = "x$CUR_ROUTE" ]; then
        echo "No default route found, trying original one"
        ip route add default via $GW_ADDR dev $GW_INT
        exit $EXITCODE
    else
        echo "Success! Default route via $GW_ADDR dev $GW_INT src $BGP_ADDR"
    fi

    exit 0
}

main(){
    volume_mount
    check_debug
    # trigger_hooks prestart
    # import_backup
    import_license
    if [[ "${IS_PEER}" =~ ^(yes|YES|Yes)$ ]]; then
        print "info" "Checking For Online Peers"
        advertise_peers add 
    else
        echo -e "No Peers to Add"
    fi    
    if [[ "${IS_POLLER}" =~ ^(yes|YES|Yes)$ ]]; then
        advertise_masters add
    else
        echo -e "No Masters to Add"
    fi
    if [[ ! -z "${OP5_BGP_ADDR}" ]]
        then
                set_default_route
        else
                print "info" "No BGP Address Present"
    fi
    service_online
    keep_swimming
}

# Graceful shutdown handling and run main()
trap shutdown_sigend SIGKILL SIGTERM SIGHUP SIGINT EXIT
main
