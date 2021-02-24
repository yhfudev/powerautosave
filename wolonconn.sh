#!/usr/bin/env bash
#
### BEGIN INIT INFO
# Provides: wol-on-conn
# Short-Description: Wakes up server on incoming connection in OpenWrt
# Homepage: 
# Requires: bash curl conntrack owipcalc etherwake
### END INIT INFO
#
################################################################################
if [ "${FN_LOG}" = "" ]; then
    FN_LOG=mrtrace.log
    #FN_LOG="/dev/stderr"
fi

if [ "${FN_LOG}" = "" ]; then
    FN_LOG="/dev/stderr"
fi

## @fn mr_trace()
## @brief print a trace message
## @param msg the message
##
## pass a message to log file, and also to stdout
mr_trace() {
    #echo "$(date +"%Y-%m-%d %H:%M:%S.%N" | cut -c1-23) [self=${BASHPID},$(basename "$0")] $@" | tee -a ${FN_LOG} 1>&2
    logger -t wolonconn "$@"
}

################################################################################
EXEC_BASH="$(which bash)"
if [ ! -x "${EXEC_BASH}" ]; then
    mr_trace "[ERR] not found bash"
    exit 1
fi

EXEC_CURL="$(which curl)"
if [ ! -x "${EXEC_CURL}" ]; then
    mr_trace "[ERR] not found curl"
    exit 1
fi

EXEC_UCI="$(which uci)"
if [ ! -x "${EXEC_UCI}" ]; then
    mr_trace "[ERR] not found uci"
    exit 1
fi

EXEC_OWIPCALC="$(which owipcalc)"
if [ ! -x "${EXEC_OWIPCALC}" ]; then
    mr_trace "[ERR] not found owipcalc"
    exit 1
fi

EXEC_ETHERWAKE="$(which etherwake)"
if [ ! -x "${EXEC_ETHERWAKE}" ]; then
    mr_trace "[ERR] not found etherwake"
    exit 1
fi

EXEC_CONNTRACK="$(which conntrack)"
if [ ! -x "${EXEC_CONNTRACK}" ]; then
    mr_trace "[ERR] not found conntrack"
    exit 1
fi

intall_software() {
  opkg update
  opkg install bash curl conntrack owipcalc etherwake
}
################################################################################
# manage temp files
FNLST_TEMP=
function remove_temp_files() {
  mr_trace "remove FNLST_TEMP=${FNLST_TEMP}"
  echo "${FNLST_TEMP}" | awk -F, '{for (i=1;i<=NF; i++) print $i; }' | while read a; do
    if test -f "${a}" ; then
      echo rm -f "${a}"
      rm -f "${a}"
    fi
  done
  FNLST_TEMP=
}
function add_temp_file() {
  local PARAM_FN=$1
  shift
  mr_trace "add to list: ${PARAM_FN}"
  FNLST_TEMP="${FNLST_TEMP},${PARAM_FN}"
  mr_trace "added FNLST_TEMP=${FNLST_TEMP}"
}

################################################################################

# find the interface name, where the host locate, from config
# ip
find_intf_by_ip() {
  local HOST_IP=$1
  shift

  #local NUM_INTF=`uci show network | grep '=interface' | sort | uniq | wc -l`

  local INTF=''
  local IP=''
  local MASK=''
  local LIST_INTF=`uci show network | grep '=interface' | awk -F= '{print $1}' | awk -F. '{print $2}'`
  for INTF in ${LIST_INTF}; do
    #mr_trace "[DBG] uci get network.${INTF}.ipaddr"
    IP=`uci get network.${INTF}.ipaddr`
    MASK=`uci get network.${INTF}.netmask`
    if [ "${IP}" = "" ]; then
      #mr_trace "[WARN] ignore ${INTF} ipaddr"
      continue
    fi
    if [ "${MASK}" = "" ]; then
      #mr_trace "[WARN] ignore ${INTF} netmask"
      continue
    fi
    #mr_trace "owipcalc ${IP}/${MASK} contains ${HOST_IP}"
    local RET=`owipcalc "${IP}/${MASK}" contains ${HOST_IP}`
    if [ "$RET" = "1" ] ; then
      local TYPE=`uci get network.${INTF}.type`
      if [ "${TYPE}" = "bridge" ]; then
        echo "br-${INTF}"
      else
        local IFNAME=`uci get network.${INTF}.ifname`
        echo "${IFNAME}"
      fi
      break
    fi
  done
}

# find the host mac record from config
# ip
find_mac_by_ip() {
  local HOST_IP=$1
  shift

  local IP=''
  local MAC=''
  local NUM_SVR=`uci show dhcp | egrep 'dhcp.@host\[[0-9]+\]=' | sort | uniq | wc -l`
  local CNT=0
  while [ `echo | awk -v A=${CNT} -v B=${NUM_SVR} '{if (A<B) print 1; else print 0;}'` = 1 ]; do
    #mr_trace "[DBG] CNT=${CNT}; NUM2=${NUM_SVR}"
    #mr_trace "[DBG] uci get dhcp.@host[${CNT}].ip"
    IP=`uci get dhcp.@host[${CNT}].ip`
    #mr_trace "[DBG] IP=${IP}; HOST_IP=${HOST_IP}"
    if [ "${IP}" = "${HOST_IP}" ]; then
      #mr_trace "[DBG] uci get dhcp.@host[${CNT}].mac"
      MAC=`uci get dhcp.@host[${CNT}].mac 2>&1`
      if [ $? = 0 ]; then
        #mr_trace "[DBG] MAC=$MAC"
        echo ${MAC}
      fi
      break
    fi
    CNT=$(( CNT + 1 ))
    #mr_trace "[DBG] CNT=${CNT}"
  done
}

# client_ip, interface, mac, dest, logfile
check_client_send_wol() {
  # the client IP
  local IP_CLI=$1
  shift
  # the interface for the LAN where server locate
  local INTF_SVR=$1
  shift
  # the server MAC
  local MAC_SVR=$1
  shift
  # the server info to log, such ip:port
  local DEST_SVR=$1
  shift

  #mr_trace "[INFO] check_client_send_wol ip='${IP_CLI}' intf='${INTF_SVR}' mac='${MAC_SVR}' dest='${DEST_SVR}'"

  local NUM_CLI=`uci show wolonconn | egrep 'wolonconn.@client\[[0-9]+\]=' | sort | uniq | wc -l`
  #if [[ ${CNT1} < $NUM_SVR ]]; then echo "ok"; else echo "fail"; fi
  local CNT1=0
  while [ `echo | awk -v A=${CNT1} -v B=${NUM_CLI} '{if (A<B) print 1; else print 0;}'` = 1 ]; do
    local CONF_REGION=`uci get wolonconn.@client[${CNT1}].region`
    local CONF_IPRANGE=`uci get wolonconn.@client[${CNT1}].iprange`
    mr_trace "[INFO] client[${CNT1}].iprange=${CONF_IPRANGE}; region=${CONF_REGION}"

    if [ ! "${CONF_IPRANGE}" = "" ]; then
      #mr_trace "[INFO] owipcalc ${CONF_IPRANGE} contains ${IP_CLI} ..."
      if [ `owipcalc ${CONF_IPRANGE} contains ${IP_CLI}` = 1 ] ; then
        mr_trace "[INFO] etherwake -i ${INTF_SVR} ${MAC_SVR}"
        etherwake -i "${INTF_SVR}" "${MAC_SVR}"
        mr_trace "[INFO] Sent MagicPacket(tm) to ${MAC_SVR} on connection from ${IP_CLI} to ${DEST_SVR}"
      fi
    fi

    if [ ! "${CONF_REGION}" = "" ]; then
      string=`curl -s https://freegeoip.app/csv/${IP_CLI}`
      IFS=',' read clientip country_code country_name region_code region_name city zip_code time_zone latitude longitude metro_code <<-EOF
$string
EOF
      if [ "$region_name" = "${CONF_REGION}" ] ; then
        mr_trace "[INFO] etherwake -i ${INTF_SVR} ${MAC_SVR}"
        etherwake -i "${INTF_SVR}" "${MAC_SVR}"
        mr_trace "[INFO] Sent MagicPacket(tm) to ${MAC_SVR} on connection from $clientip to ${DEST_SVR}"
      fi
    fi

    CNT1=$(( CNT1 + 1 ))
  done

}

# example of conntrack:
# conntrack -L -p tcp --reply-src 10.1.1.23 --reply-port-src 80 --state SYN_SENT
#tcp      6 119 SYN_SENT src=10.1.1.178 dst=10.1.1.23 sport=39226 dport=80 packets=3 bytes=180 [UNREPLIED] src=10.1.1.23 dst=10.1.1.178 sport=80 dport=39226 packets=0 bytes=0 mark=0 use=1
check_conn_send_wol() {
  local FN_TMP=$1
  shift
  #uci show wolonconn

  #mr_trace "[INFO] check_conn_send_wol tmp='${FN_TMP}'"

  local NUM_SVR=`uci show wolonconn | egrep 'wolonconn.@server\[[0-9]+\]=' | sort | uniq | wc -l`
  #if [[ ${CNT} < $NUM_SVR ]]; then echo "ok"; else echo "fail"; fi
  local CNT=0
  while [ `echo | awk -v A=${CNT} -v B=${NUM_SVR} '{if (A<B) print 1; else print 0;}'` = 1 ]; do
    local CONF_INTF=`uci get wolonconn.@server[${CNT}].interface`
    local CONF_MAC=`uci get wolonconn.@server[${CNT}].mac`
    local CONF_IP=`uci get wolonconn.@server[${CNT}].ip`
    local CONF_PORTS=`uci get wolonconn.@server[${CNT}].ports`

    if [ "${CONF_IP}" = "" ]; then
      #mr_trace "[WARN] not set server ip: mac=${CONF_MAC}; ports=${CONF_PORTS}"
      continue
    fi
    if [ "${CONF_PORTS}" = "" ]; then
      #mr_trace "[WARN] not set server port: mac=${CONF_MAC}; ip=${CONF_IP}"
      continue
    fi
    if [ "${CONF_MAC}" = "" ]; then
      # find the mac
      CONF_MAC=`find_mac_by_ip ${CONF_IP}`
    fi
    if [ "${CONF_INTF}" = "" ]; then
      # find the interface
      CONF_INTF=`find_intf_by_ip ${CONF_IP}`
    fi

    if [ "${CONF_MAC}" = "" ]; then
      mr_trace "[WARN] unable to find the mac of ${CONF_IP}"
      continue
    fi
    if [ "${CONF_INTF}" = "" ]; then
      mr_trace "[WARN] unable to find the network interface of ${CONF_IP}"
      continue
    fi

    #mr_trace "[INFO] server[${CNT}].mac=${CONF_MAC}; IP=${CONF_IP}"
    for PORT in ${CONF_PORTS}; do
      #mr_trace "[INFO] conntrack -L -p tcp --reply-src ${CONF_IP} --reply-port-src ${PORT} --state SYN_SENT"
      conntrack -L -p tcp --reply-src ${CONF_IP} --reply-port-src ${PORT} --state SYN_SENT 2>/dev/null > "${FN_TMP}"
      while read CLIENT_IP ; do
        local CLIENT_IP=${CLIENT_IP##*SYN_SENT src=}
        local CLIENT_IP=${CLIENT_IP%% *}

        check_client_send_wol "${CLIENT_IP}" "${CONF_INTF}" "${CONF_MAC}" "${CONF_IP}:${PORT}"

      done < "${FN_TMP}"
    done

    CNT=$(( CNT + 1 ))
  done
}

################################################################################

run_svr() {
  local FN_LOG=''
  local FN_TMP=''

  FN_LOG1=`uci get wolonconn.basic.filelog`
  if [ $? = 0 ]; then
    FN_LOG="${FN_LOG1}"
    mr_trace "[INFO] got wolonconn.basic.filelog=${FN_LOG}"
  else
    mr_trace "[ERR] failed to get wolonconn.basic.filelog"
  fi

  FN_TMP=`uci get wolonconn.basic.filetemp`
  if [ $? = 0 ]; then
    mr_trace "[INFO] got wolonconn.basic.filetemp=${FN_TMP}"
  else
    mr_trace "[ERR] failed to get wolonconn.basic.filetemp"
    FN_TMP="/tmp/tmp-wol-$(uuidgen)"
  fi
  add_temp_file "${FN_TMP}"

  while true ; do
    sleep 1
    #mr_trace "[INFO] check_conn_send_wol ..."
    check_conn_send_wol "${FN_TMP}"
  done
}

################################################################################
assert ()                 #  If condition false,
{                         #+ exit from script
                          #+ with appropriate error message.
  E_PARAM_ERR=98
  E_ASSERT_FAILED=99

  local PARAM_LINE=$1
  shift
  local PARAM_COND=$1
  shift

  if [ -z "$PARAM_COND" ]; then #  Not enough parameters passed
                          #+ to assert() function.
    return $E_PARAM_ERR   #  No damage done.
  fi

  if [ ! $PARAM_COND ]; then
    echo "Assertion failed:  \"$PARAM_COND\""
    echo "File \"$0\", line $PARAM_LINE"    # Give name of file and line number.
    exit $E_ASSERT_FAILED
  # else
  #   return
  #   and continue executing the script.
  fi
} # Insert a similar assert() function into a script you need to debug.

test_in_openwrt_main() {
  #find_intf_by_ip 10.1.1.23
  local INTF=`find_intf_by_ip 10.1.1.23`
  local MAC=`find_mac_by_ip 10.1.1.23`
  assert $LINENO "'$INTF' = 'br-office'"
  assert $LINENO "'$MAC' = '00:25:31:01:C2:0A'"

#TODO: show sequence from tcpdump:
#IP=10.1.1.178; PORT=443; tcpdump -n -r web-local-1.pcap host $IP and "tcp[tcpflags] & tcp-syn != 0" | grep ${IP}.${PORT} | awk -F, '{split($2,a," "); if (a[1] == "seq") print a[2];}' | sort | awk 'BEGIN{pre="";cnt=0;}{if (pre != $1) {if (pre != "") print cnt " " pre; cnt=0;} cnt=cnt+1; pre=$1; }END{print cnt " " pre;}'
#1 153253500
#4 3707552423
}

test_add_temp_files() {
  FNLST_TEMP=
  local FN_TEST1="/tmp/tmp-test-$(uuidgen)"
  local FN_TEST2="/tmp/tmp-test-$(uuidgen)"
  touch "${FN_TEST1}"
  touch "${FN_TEST2}"
  assert $LINENO " -f ${FN_TEST1} "
  assert $LINENO " -f ${FN_TEST2} "
  assert $LINENO "'${FNLST_TEMP}' = ''"
  add_temp_file "${FN_TEST1}"
  add_temp_file "${FN_TEST2}"
  assert $LINENO "! '${FNLST_TEMP}' = ''"
  remove_temp_files
  assert $LINENO "'${FNLST_TEMP}' = ''"
  assert $LINENO "! -f ${FN_TEST1} "
  assert $LINENO "! -f ${FN_TEST2} "
  rm -f "${FN_TEST1}"
  rm -f "${FN_TEST2}"
}

test_all() {
  test_add_temp_files
  #test_in_openwrt_main

  mr_trace "Done tests successfully!"
}

################################################################################
# config config 'basic'
#   option filetemp '/mnt/sda1/wol-on-conn.temp'
#   option filelog '/mnt/sda1/wol-on-conn.log'
#   option freegeoip 'https://freegeoip.app/csv/$clientip'
#
# config server 'xxx'
#   option interface 'coredata'
#   option mac 'xx:xx:xx:xx:xx:xx'
#   option ports '80 443'
# config client 'yyy'
#   option iprange '192.168.1.0/24'
# config client 'zzz'
#   option region 'regionname'
add_test_config() {

  touch /etc/config/wolonconn
  uci set wolonconn.basic='config'
  uci set wolonconn.basic.filetemp='/tmp/wol-on-conn.temp'
  uci set wolonconn.basic.filelog='/tmp/wol-on-conn.log'
  uci set wolonconn.basic.freegeoip='https://freegeoip.app/csv/$clientip'

  uci add wolonconn server
  uci set wolonconn.@server[-1].ip='10.1.1.178'
  uci set wolonconn.@server[-1].ports='22 80 443'
  #uci set wolonconn.@server[-1].interface='br-lan'
  #uci set wolonconn.@server[-1].mac='11:22:33:44:55:01'

  uci add wolonconn server
  uci set wolonconn.@server[-1].ip='10.1.1.23'
  uci set wolonconn.@server[-1].ports='22 80'
  #uci set wolonconn.@server[-1].interface='br-coredata'
  #uci set wolonconn.@server[-1].mac='11:22:33:44:55:02'

  #uci add wolonconn client
  #uci set wolonconn.@client[-1].region='xxxx'

  # iprange could be one of:
  #   single ip address, eg. 192.168.1.1;
  #   CIDR notation, eg. 192.168.1.0/24;
  #   subnet mask notation, eg. 192.168.1.0/255.255.255.0;
  uci add wolonconn client
  uci set wolonconn.@client[-1].iprange='10.1.0.0/16'

  # uci revert wolonconn
  uci commit wolonconn
}

rm -f /tmp/wol-on-conn.log /tmp/wol-on-conn.temp
rm -f /etc/config/wolonconn
add_test_config

test_all

run_svr


