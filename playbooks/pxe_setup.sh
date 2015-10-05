#!/bin/bash
#### Script for Automated un-attended kickstart installation
#### About : Script will validate hostname, ip, console access than update dhcpd.conf , generate pxe files and reboot the host via CLI
#### Author : Samir Parekh
## Version : 1.1
## Date: 25/03/3014

## Version: 1.2
## Added support of RHEL 6.5 and RHEL 7.0 OS
## Date: 01/10/2014

### Variable declaration
DHCP_CONF="/etc/dhcp/dhcpd.conf"
PXELINUX="/var/lib/tftpboot/pxelinux.cfg"
IPMI="/opt/smcipmitool"
ARG=$1
HOST=$2
OPT1=$3
OPT2=$5
OS=$4
VER=$6
TOTAL_ARG=$#
FILE=$2
RAN=$RANDOM

usage () {

        echo ; echo "Usage :    pxe_setup -h <Help> " ; echo
        echo "|Single Host|"
        echo "  pxe_setup -H <hostname> -O <OS: centos|rhel> -V <OS Version: 6.3>"
        echo "          EXAMPLE : pxe_setup -H ggvaapp51 -O centos -V 6.3"
        echo ; echo "|Multiple hosts|"
        echo "  pxe_setup -f <filename>"
        echo "  File format : <HOSTNAME> <OS> <VERSION>, Ex: ggvaapp51 centos 6.3"
        echo "  EXAMPLE File : /root/bin/build_hosts"
        echo "  Execute : pxe_setup -f /tmp/hostfile" ; echo
        exit
}

console_check () {

        host ${HOST}-con > /dev/null
        if [[ $? -ne 0 ]]
        then
                echo ; echo "Console IP is not reserved in DNS, Please do it as ${HOST}-con , Skipping ..."
                error="Console IP is not registered in DNS"
                return 1
        else
                console_ip=`host ${HOST}-con | awk '{print $NF}'`
        fi

        if (! ping $console_ip -w 2 > /dev/null 2>&1)
        then
                echo "Console IP is not live, Please check and investigate, Skipping ..."
                error="Console IP is not live"
                echo ; return 1
        fi

        echo "Checking IPMI Console Access ...."
        ipmitool -H $console_ip -U admin -P admin power status > /dev/null 2>&1
        if [[ $? -ne 0 ]]
        then
                echo ; echo "Console is not accessible, Please check wth DC Team and try again ...Skipping "
                error="Console is not accessible"
                return 1
        else
                echo "IPMI Console access looks good!!! Lets go ahead ..."
                ipmitool -H $console_ip -U admin -P admin power status
        fi

}


primary_check () {

        case $ARG in
        -H)
                [[ $TOTAL_ARG -ne 6 ]] && usage
                [[ $OPT1 != "-O" ]] && usage
                [[ $OPT2 != "-V" ]] && usage
                [[ -z $HOST ]] && usage
                [[ -z $OS ]] && usage
                [[ -z $VER ]] && usage
                FILE=/tmp/build_host
                echo "$HOST     $OS     $VER" > $FILE
                ;;

        -f)
                [[ $TOTAL_ARG -ne 2 ]] && usage
                [[ ! -f $FILE ]] && printf "\n\nINFO: $FILE does not exist, than try again ..." && echo && usage
                ;;

        -h|help|-help|--help)
                usage
                ;;

        *)      printf "\n\nInvalid option given, re-run again ......\n\n" ; usage ;;
        esac

}

validate () {

#### Host check ####
        host $HOST > /dev/null
        [[ $? -ne 0 ]] && echo "        Error: $HOST is not registered in DNS, skipping ...." && error="Host is not registered in DNS" &&  return 1

        if (ping $HOST -w 2 > /dev/null  2>&1)
        then
                printf "\n$HOST is live, Are you sure to rebuild? [y|n] : "
                read ANS < /dev/tty
                if [[ -n $(echo $ANS | egrep "^y|^Y|^yes|^YES") ]]
                then
                        rebuild=1 ; echo "Proceding further ..."
                else
                        echo "Skipping ..." ; error="Host is live, no rebuild selected" ; return 1
                fi
        fi

##### IP Check ####

        ip_third_oct=`host $HOST | awk '{print $NF}' | cut -d. -f3`
        ip_last_oct=`host $HOST | awk '{print $NF}' | cut -d. -f4`
        ip_third_oct_new=`expr $ip_third_oct - 2`
        IP=`host $HOST | awk '{print $NF}' | cut -d. -f1-2`.$ip_third_oct_new.$ip_last_oct

        host $IP > /dev/null
        if [[ $? -ne 0 ]]
        then
                printf "\n$IP not found in DNS, Please enter Valid eth0 IP address : "
                read IP < /dev/tty
                host $IP > /dev/null
                if [[ $? -ne 0 ]]
                then
                        echo "$IP not registered in DNS, please register and re-run script ...Skipping ..."
                        error="Eth0 IP is not registered in DNS"
                        return 1
                fi
        fi

#       if [[ $rebuild -eq 0 ]]; then
#               if (ping $IP -w 2 > /dev/null  2>&1)
#               then
#                       echo "$IP is live, Please check and investigate, Skipping ..."
#                       return 1
#               fi
#       fi

        IP_CHK=`host $IP | awk '{print $NF}'`
        if (! echo $IP_CHK | grep $HOST  > /dev/null)
        then
                echo "$IP is pointing to different hostname, Please check and investigate , Skipping .. "
                host $IP
                error="IP is pointing to different hostname"
                return 1
        fi


###### OS Version Check ########

        if (! ls /var/www/html/$OS/$VER > /dev/null)
        then
                echo "$OS $VER is not found in repository, Skipping ..."
                ls /var/www/html/$OS ; echo
                error="OS version is not found in repository"
                return 1
        fi

##### Console Check #####
        console_check
}


update_dhcp () {

        echo "Updating /etc/dhcp/dhcpd.conf with Host entry ...taking backup as /var/tmp/dhcpd.conf ..."
        cp -p ${DHCP_CONF} /var/tmp
        if (! grep $HOST ${DHCP_CONF} > /dev/null)
        then
                sed -i '$ d' ${DHCP_CONF}
                echo "host $HOST {" >> ${DHCP_CONF}
                echo "    option host-name $HOST;" >> ${DHCP_CONF}
                echo "    hardware ethernet $MAC;" >> ${DHCP_CONF}
                echo "    fixed-address $IP;" >> ${DHCP_CONF}
                cat >> ${DHCP_CONF} << "EOF"
    filename "pxelinux.0";
    next-server 10.143.0.24;
}

EOF
                echo "host ${HOST}-eth1 {" >> ${DHCP_CONF}
                echo "    option host-name $HOST;" >> ${DHCP_CONF}
                echo "    hardware ethernet $MAC_ETH1;" >> ${DHCP_CONF}
                echo "    fixed-address `host $HOST | awk '{print $NF}'`;" >> ${DHCP_CONF}
                cat >> ${DHCP_CONF} << "EOF"
    filename "pxelinux.0";
    next-server 10.143.0.24;
}

}
EOF
        #service dhcpd restart > /dev/null

        else
                echo "$HOST Entry Already present in dhcpd.conf file ..."
                cat ${DHCP_CONF} | grep -A6 $HOST
        fi
}

generate_pxe () {

        echo "Generating PXE Boot file under /var/lib/tftpboot/pxelinux.cfg/ ..."
        NAME=`gethostip $IP | awk '{print $NF}'`
        ETH1_IP=`host $HOST | awk '{print $NF}'`
        ETH1_NAME=`gethostip $ETH1_IP | awk '{print $NF}'`
        cat $PXELINUX/template | sed s'/x.x/'$VER'/g' | sed s'/OS/'$OS'/g' > $PXELINUX/$NAME
        cat $PXELINUX/$NAME > $PXELINUX/$ETH1_NAME

}

reboot_host () {

     if [[ -f /tmp/passed.$RAN ]]
     then
        echo "Restarting dhcp ... "
        service dhcpd restart
        sed -i '/^$/d' /tmp/passed.$RAN
        for host in `cat /tmp/passed.$RAN`
        do
                echo ; echo "Rebooting $host ......."
                console_ip=`host ${host}-con | awk '{print $NF}'`
                ipmitool -H $console_ip -U admin -P admin chassis bootparam set bootflag force_pxe
                ipmitool -H $console_ip -U admin -P admin power cycle
                echo
                sleep 15
        done
    fi
}

verify () {

        echo ; echo "Please check and verify before proceeding ..."
        echo "===================================="
        echo "Hostname: $HOST"
        echo "Eth0 IP:  $IP"
        echo "Eth1 IP:  `host $HOST | awk '{print $NF}'`"
        echo "Console:  $console_ip"
        echo "OS:               $OS"
        echo "OS VER:           $VER"
        echo "MAC:              $MAC"
        echo "==================================="
}

main () {


        cat $FILE | grep -v "^#" |  sed '/^$/d' > /tmp/hosts
        while read HOST OS VER
        do
                echo ; echo "**** Start procceding $HOST ******************************************" ; echo
                [[ -z $HOST ]] && echo "Hostname should be entered ..." && exit

                [[ -z $OS ]] && echo "OS should be entered ..." && exit

                [[ -z $VER ]] && echo "OS Version should be entered ..." && exit

                validate

                if [[ $? -eq 1 ]]
                then
                        echo "$HOST     FAILED          Reason : $error" >> /tmp/status.$RAN
                        continue
                fi

                MAC=`${IPMI}/SMCIPMITool $console_ip admin admin ipmi oem mac | cut -d: -f2,3,4,5,6,7`

                ### Calculating eth1 MAC id
                maclast=`echo $MAC | cut -d: -f6`
                hexmac=$(echo "ibase=16; $maclast"|bc)
                incout=`expr $hexmac + 1 `
                macinc=$(echo "obase=16; $incout"|bc)
                MAC_ETH1=`echo $MAC | cut -d: -f1,2,3,4,5`:$macinc

                [[ -z $MAC ]] && printf "\nUnable to get MAC, Please enter MAC in format 00:00:00:00:00:00 : " && read MAC


        #verify

#       printf "\nProceed with DHCP update, PXE generate, Reboot host, Install OS ???? [y|n] : "
#       read ANS < /dev/tty
#       if [[ -n $(echo $ANS | egrep "^y|^Y|^yes|^YES") ]]
#       then
                echo ; update_dhcp
                echo ; generate_pxe
                echo ; echo
                echo "$HOST" >> /tmp/passed.$RAN
                echo "$HOST     PASSED" >> /tmp/status.$RAN
#       else
#               echo "$HOST     FAILED          Reason : Skipped intentionally" >> /tmp/status.$RAN
#               echo "Skipping ..." && continue
#       fi

         done < /tmp/hosts
}

#### Start here
primary_check
main
reboot_host

if [[ -f /tmp/status.$RAN ]]
then
        printf "\n\n==================== STATUS REPORT =============================\n\n"
        cat /tmp/status.$RAN
fi

rm -f /tmp/status.$RAN
rm -f /tmp/passed.$RAN
echo

