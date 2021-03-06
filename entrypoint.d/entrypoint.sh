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
print "mibs +all" >> /etc/snmp/snmp.local.conf
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
print "root:${ROOT_PASSWORD}" | chpasswd

print(){
    if [ $1 == "info" ];then 
        print -e '\033[36m' [INFO] $2 '\033[39;49m'
    elif [ $1 == "warn" ];then
        print -e '\033[33m' [WARN] $2 '\033[39;49m'
    elif [ $1 == "error" ]; then
        print -e '\033[31m' [ERROR] $2 '\033[39;49m'
    elif [ $1 == "success" ]; then
        print -e '\033[32m' [SUCCESS] $2 '\033[39;49m'
    fi 
}

trigger_hooks() {
    print "info" "Triggering ${1} hooks"
    /usr/libexec/entrypoint.d/hooks.py $1
}

import_backup() {
    if [ ! -z "${IMPORT_BACKUP}" ]; then
        file="/usr/libexec/entrypoint.d/backups/${IMPORT_BACKUP}"
        if [ ! -e "$file" ]; then
            print -e "Error importing backup. Backup file ${file} does not exist."
        else
            print -e "Backup file found. Importing: ${file} ..."
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
            print -e "Error importing license. License file ${file} does not exist."
    	else
    		if [[ "$file" =~ \.lic$ ]]; then
    			print -e "License file found. Importing license file: ${file} ..."
    			mv $file /etc/op5license/op5license.lic
    			chown apache:apache /etc/op5license/op5license.lic
    			chmod 664 /etc/op5license/op5license.lic
    		else
    			print -e "Unable to import license file. License file extension must be .lic"
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

remove_node(){
for node in `mon node list`
    do
        mon node ctrl $node "mon node remove ${SELF_HOSTNAME} && mon restart"
    done
}

add_peer_to_master(){
if [ $1 == "add" ]; then
    do
        print "info" "Performing Add On ${MASTER}"
        mon node add ${MASTER} type=peer
        mon node ctrl ${MASTER} mon node add ${SELF_HOSTNAME} type=peer
        while true; 
            do
                sleep $[ ( $RANDOM % 10 )  + 1 ]s
                ssh root@${MASTER} -o IdentitiesOnly=yes -o BatchMode=yes "/opt/plugins/check_procs -p 1 -w 1:1 -c 1:1 -C naemon"
                if [[ $? == 0 ]]; then
                    naemon=0
                else
                    naemon=1
                fi
                sleep $[ ( $RANDOM % 10 )  + 1 ]s
                ssh root@${MASTER} -o IdentitiesOnly=yes -o BatchMode=yes "/opt/plugins/check_procs -w 2:1 -c 1:1 -C merlind"
                if [[ $? == 0 ]]; then
                    merlin=0
                else
                    merlin=1
                fi
                if [[ $naemon == 0 ]] && [[ $merlin == 0 ]]; then
                    print "info" "Monitor is UP on ${MASTER}"
                    print "info" "Performing Restart On ${MASTER}"
                    ssh root@${MASTER} -o IdentitiesOnly=yes -o BatchMode=yes "mon restart"
                else
                    print "info" "Monitor is DOWN on ${MASTER}"
                    print "info" "Testing Again"
                    continue
                fi
                break
            done
        for peer in `ssh ${MASTER} -o IdentitiesOnly=yes -o BatchMode=yes mon node list --type=peer`
            do
                mon node add $peer type=peer
                mon node ctrl $peer mon node add ${SELF_HOSTNAME} type=peer
                while true; 
                    do
                        sleep $[ ( $RANDOM % 10 )  + 1 ]s
                        ssh root@$peer -o IdentitiesOnly=yes -o BatchMode=yes "/opt/plugins/check_procs -p 1 -w 1:1 -c 1:1 -C naemon"
                        if [[ $? == 0 ]]; then
                            naemon=0
                        else
                            naemon=1
                        fi
                        sleep $[ ( $RANDOM % 10 )  + 1 ]s
                        ssh root@$peer -o IdentitiesOnly=yes -o BatchMode=yes "/opt/plugins/check_procs -w 2:1 -c 1:1 -C merlind"
                        if [[ $? == 0 ]]; then
                            merlin=0
                        else
                            merlin=1
                        fi
                        if [[ $naemon == 0 ]] && [[ $merlin == 0 ]]; then
                            print "info" "Monitor is UP on $peer"
                            print "info" "Performing Restart On $peer"
                            mon node ctrl $node mon restart
                        else
                            print "info" "Monitor is DOWN on $peer"
                            print "info" "Testing Again"
                            continue
                        fi
                        break
                    done
            done
        poller_list=$(ssh root@${MASTER} -o IdentitiesOnly=yes -o BatchMode=yes mon node show |sed -n '/poller/,/^$/p'|grep ADDRESS|awk -F = '{print $2}')
        for poller in ${poller_list}
            do
                poller_hostgroup=$(ssh root@${MASTER} -o IdentitiesOnly=yes -o BatchMode=yes mon node show |sed -n "/${POLLER}/,/^$/p"|grep HOSTGROUP|awk -F = '{print $2}')
                mon node add $poller type=poller type=poller hostgroup=${poller_hostgroup} takeover=no
                mon node ctrl $poller mon node add ${SELF_HOSTNAME} type=master
                while true; 
                    do
                        sleep $[ ( $RANDOM % 10 )  + 1 ]s
                        ssh root@$peer -o IdentitiesOnly=yes -o BatchMode=yes "/opt/plugins/check_procs -p 1 -w 1:1 -c 1:1 -C naemon"
                        if [[ $? == 0 ]]; then
                            naemon=0
                        else
                            naemon=1
                        fi
                        sleep $[ ( $RANDOM % 10 )  + 1 ]s
                        ssh root@$peer -o IdentitiesOnly=yes -o BatchMode=yes "/opt/plugins/check_procs -w 2:1 -c 1:1 -C merlind"
                        if [[ $? == 0 ]]; then
                            merlin=0
                        else
                            merlin=1
                        fi
                        if [[ $naemon == 0 ]] && [[ $merlin == 0 ]]; then
                            print "info" "Monitor is UP on $poller"
                            print "info" "Performing Restart On $poller"
                            mon node ctrl $poller mon restart
                        else
                            print "info" "Monitor is DOWN on $poller"
                            print "info" "Testing Again"
                            continue
                        fi
                        break
                    done
            done
    done
else
    print "info" "Nothing to do for master"
fi
}

add_poller(){
if [ $1 == "add" ]; then
    do
        while true:
            do
                HOSTGROUP_TEST=$(mon node ctrl ${MASTER} "mon query ls hostgroups -c name name=${HOSTGROUPS}")
                if [[ ${HOSTGROUPS} == $HOSTGROUP_TEST ]]
                    print "info" "hostgroup exists"
                else
                    print "info" "adding hostgroup"
                    api_user=$(date +%s | sha256sum | base64 | head -c 32 ; echo)
                    mon node ctrl ${MASTER} "op5-manage-users --update --username=$api_user --realname=$api_user --group=admins --password=$api_user --modules=Default"
                    curl --insecure -XPOST -H 'content-type: application/json' -d '{"name": "test","file_id": "etc/hostgroups.cfg"}' 'https://${MASTER}/api/config/hostgroup' -u "$api_user:$api_user"
                    sleep 5s
                    curl --insecure -XPOST 'https://${MASTER}/api/config/change' -u "$api_user:$api_user"
                    sleep 15s
                    mon node ctrl ${MASTER} "op5-manage-users --remove --username=$api_user"
                    continue
                fi
                break
            done
        print "info" "Performing Add On ${MASTER}"
        mon node add ${MASTER} type=master
        mon node ctrl ${MASTER} mon node add ${SELF_HOSTNAME} type=poller hostgroup=${HOSTGROUPS} takeover=no
        while true; 
            do
                sleep $[ ( $RANDOM % 10 )  + 1 ]s
                ssh root@${MASTER} -o IdentitiesOnly=yes -o BatchMode=yes "/opt/plugins/check_procs -p 1 -w 1:1 -c 1:1 -C naemon"
                if [[ $? == 0 ]]; then
                    naemon=0
                else
                    naemon=1
                fi
                sleep $[ ( $RANDOM % 10 )  + 1 ]s
                ssh root@${MASTER} -o IdentitiesOnly=yes -o BatchMode=yes "/opt/plugins/check_procs -w 2:1 -c 1:1 -C merlind"
                if [[ $? == 0 ]]; then
                    merlin=0
                else
                    merlin=1
                fi
                if [[ $naemon == 0 ]] && [[ $merlin == 0 ]]; then
                    print "info" "Monitor is UP on ${MASTER}"
                    print "info" "Performing Restart On ${MASTER}"
                    ssh root@${MASTER} -o IdentitiesOnly=yes -o BatchMode=yes "mon restart"
                else
                    print "info" "Monitor is DOWN on ${MASTER}"
                    print "info" "Testing Again"
                    continue
                fi
                break
            done
        for master_peer in `ssh ${MASTER} -o IdentitiesOnly=yes -o BatchMode=yes mon node list --type=peer`
            do
                mon node add ${master_peer} type=master
                mon node ctrl ${master_peer} mon node add ${SELF_HOSTNAME} type=poller hostgroup=${HOSTGROUPS} takeover=no
                while true; 
                    do
                        sleep $[ ( $RANDOM % 10 )  + 1 ]s
                        ssh root@${master_peer} -o IdentitiesOnly=yes -o BatchMode=yes "/opt/plugins/check_procs -p 1 -w 1:1 -c 1:1 -C naemon"
                        if [[ $? == 0 ]]; then
                            naemon=0
                        else
                            naemon=1
                        fi
                        sleep $[ ( $RANDOM % 10 )  + 1 ]s
                        ssh root@${master_peer} -o IdentitiesOnly=yes -o BatchMode=yes "/opt/plugins/check_procs -w 2:1 -c 1:1 -C merlind"
                        if [[ $? == 0 ]]; then
                            merlin=0
                        else
                            merlin=1
                        fi
                        if [[ ${naemon} == 0 ]] && [[ ${merlin} == 0 ]]; then
                            print "info" "Monitor is UP on ${master_peer}"
                            print "info" "Performing Restart On ${master_peer}"
                            mon node ctrl ${master_peer} mon restart
                        else
                            print "info" "Monitor is DOWN on ${master_peer}"
                            print "info" "Testing Again"
                            continue
                        fi
                        break
                    done
            done
        poller_peer_list=$(ssh ${MASTER} -o IdentitiesOnly=yes -o BatchMode=yes mon node show |sed -n '/poller/,/^$/p'| sed -n "/$HOSTGROUP/,/^$/p"|grep ADDRESS|awk -F = '{print $2}')
        for poller_peer in ${poller_peer_list}
            do
                mon node add ${poller_peer} type=peer
                mon node ctrl ${poller_peer} mon node add ${SELF_HOSTNAME} type=peer
                while true; 
                    do
                        sleep $[ ( $RANDOM % 10 )  + 1 ]s
                        ssh root@${poller_peer} -o IdentitiesOnly=yes -o BatchMode=yes "/opt/plugins/check_procs -p 1 -w 1:1 -c 1:1 -C naemon"
                        if [[ $? == 0 ]]; then
                            naemon=0
                        else
                            naemon=1
                        fi
                        sleep $[ ( $RANDOM % 10 )  + 1 ]s
                        ssh root@${poller_peer} -o IdentitiesOnly=yes -o BatchMode=yes "/opt/plugins/check_procs -w 2:1 -c 1:1 -C merlind"
                        if [[ $? == 0 ]]; then
                            merlin=0
                        else
                            merlin=1
                        fi
                        if [[ ${naemon} == 0 ]] && [[ ${merlin} == 0 ]]; then
                            print "info" "Monitor is UP on ${master_peer}"
                            print "info" "Performing Restart On ${master_peer}"
                            mon node ctrl ${poller_peer} mon restart
                        else
                            print "info" "Monitor is DOWN on ${poller_peer}"
                            print "info" "Testing Again"
                            continue
                        fi
                        break
                    done
            done
    done
    grep -q "notifies = no" /opt/monitor/op5/merlin/merlin.conf || sed -i '/module {/a\        notifies = no' /opt/monitor/op5/merlin/merlin.conf
    # ssh ${MASTER} -o IdentitiesOnly=yes -o BatchMode=yes "asmonitor mon oconf push ${SELF_HOSTNAME}"
else
    print "info" "Nothing to do for master"
fi
}

get_config(){
    # Only getting config from one master because mon oconf always exits 0
    # The fetch will initiate a restart of the the local merlind.
    # This should be the only time we need to to restart locally since new pollers will restart us.
    print "info" "Syncing Configuration With ${MASTER}"
    mon node ctrl ${MASTER} asmonitor mon oconf push ${SELF_HOSTNAME}
}


shutdown_sigend(){
    # If container is gracefully shutdown with SIGTERM (e.g. docker stop), remove
    # pre-emptively remove itself
    print "warn" "SIGTERM Caught! Removing From Cluster"
    remove_node
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

    #print "OP5_BGP_ADDR: $OP5_BGP_ADDR"
    #print "   BGP_ADDR: $BGP_ADDR"
    #print "GW_SRC_ADDR: $GW_SRC_ADDR"
    #print "    GW_ADDR: $GW_ADDR"
    #print "     GW_INT: $GW_INT"

    EXITCODE=1

    if [ "x" = "x$OP5_BGP_ADDR" ]; then
        print "No configured BGP addr found, quitting"
        exit $EXITCODE
    fi

    EXITCODE=$(($EXITCODE + 1))

    if [ "x" = "x$BGP_ADDR" ]; then
        print "No BGP addr found, quitting"
        exit $EXITCODE
    fi

    EXITCODE=$(($EXITCODE + 1))

    if [ "x$OP5_BGP_ADDR" != "x$BGP_ADDR" ]; then
        print "Configured BGP address $OP5_BGP_ADDR does not match detected address $BGP_ADDR, quitting"
        exit $EXITCODE
    fi

    EXITCODE=$(($EXITCODE + 1))

    if [ "x" = "x$GW_ADDR" ]; then
        print "Could not determine gateway address, quitting"
        exit $EXITCODE
    fi

    EXITCODE=$(($EXITCODE + 1))

    if [ "x" = "x$GW_INT" ]; then
        print "Could not determine gateway interface, quitting"
        exit $EXITCODE
    fi

    EXITCODE=$(($EXITCODE + 1))

    ## route set correctly
    if [ "x$OP5_BGP_ADDR" = "x$GW_SRC_ADDR" ]; then
        print "Routing is correct. Exiting without changes"
        exit 0
    fi

    print "Source-address needs setting"

    ## delete the current default route
    ip route del default

    ## add the new one, with the correct source IP
    ip route add default via $GW_ADDR dev $GW_INT src $BGP_ADDR

    ## verify/fix
    CUR_ROUTE=$(ip route | grep default)
    if [ "x" = "x$CUR_ROUTE" ]; then
        print "No default route found, trying original one"
        ip route add default via $GW_ADDR dev $GW_INT
        exit $EXITCODE
    else
        print "Success! Default route via $GW_ADDR dev $GW_INT src $BGP_ADDR"
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
        add_peer_to_master add 
    else
        print -e "No Peers to Add"
    fi    
    if [[ "${IS_POLLER}" =~ ^(yes|YES|Yes)$ ]]; then
        add_poller add
    else
        print -e "No Masters to Add"
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



 for i in cat test.txt |sed -n '/poller/,/^$/p'| sed -n "/$HOSTGROUP/,/^$/p"|grep ADDRESS | awk -F = '{print $2}'; do printf "this is $i"; done