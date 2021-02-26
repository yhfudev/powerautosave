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
  if [ "${UNIT_TEST}" = "1" ]; then
    echo "$(date +"%Y-%m-%d %H:%M:%S.%N" | cut -c1-23) [self=${BASHPID},$(basename "$0")] $@" | tee -a ${FN_LOG} 1>&2
  else
    logger -t powerautosave "$@" #DEBUG#
  fi
}

fatal_error() {
  if [ "${UNIT_TEST}" = "1" ]; then
    echo "$(date +"%Y-%m-%d %H:%M:%S.%N" | cut -c1-23) [self=${BASHPID},$(basename "$0")] FATAL: $@" | tee -a ${FN_LOG} 1>&2
  else
    logger -t powerautosave "[FATAL] $@"
  fi
  exit 1
}

################################################################################
EXEC_BASH="$(which bash)"
if [ ! -x "${EXEC_BASH}" ]; then
  echo "[ERROR] not found bash"
  exit 1
fi

EXEC_CURL="$(which curl)"
if [ ! -x "${EXEC_CURL}" ]; then
  echo "[ERROR] not found curl"
  exit 1
fi

EXEC_UCI="$(which uci)"
if [ ! -x "${EXEC_UCI}" ]; then
  echo "[ERROR] not found uci"
  if [ ! "${UNIT_TEST}" = "1" ]; then
    exit 1
  fi
fi

EXEC_OWIPCALC="$(which owipcalc)"
if [ ! -x "${EXEC_OWIPCALC}" ]; then
  echo "[ERROR] not found owipcalc"
  if [ ! "${UNIT_TEST}" = "1" ]; then
    exit 1
  fi
fi

EXEC_ETHERWAKE="$(which etherwake)"
if [ ! -x "${EXEC_ETHERWAKE}" ]; then
  echo "[ERROR] not found etherwake"
  exit 1
fi

EXEC_CONNTRACK="$(which conntrack)"
if [ ! -x "${EXEC_CONNTRACK}" ]; then
  echo "[ERROR] not found conntrack"
  if [ ! "${UNIT_TEST}" = "1" ]; then
    exit 1
  fi
fi

EXEC_UUIDGEN="$(which uuidgen)"
if [ ! -x "${EXEC_UUIDGEN}" ]; then
  echo "[ERROR] not found uuidgen"
  exit 1
fi

install_software() {
  opkg update
  opkg install bash curl conntrack owipcalc etherwake uuidgen
}

################################################################################
# register routines which will be called on exit
RTLST_ONEXIT=
function on_exit_run_routines() {
  #mr_trace "[DEBUG] remove RTLST_ONEXIT=${RTLST_ONEXIT}"
  echo "${RTLST_ONEXIT}" | awk -F, '{for (i=1;i<=NF; i++) print $i; }' | while read a; do
    if [ ! "${a}" = "" ] ; then
      mr_trace "[INFO] run ${a}"
      ${a}
    fi
  done
  RTLST_ONEXIT=
}
function on_exit_register() {
  local PARAM_PS=$1
  shift
  #mr_trace "[DEBUG] add to list: ${PARAM_PS}"
  RTLST_ONEXIT="${RTLST_ONEXIT},${PARAM_PS}"
  #mr_trace "[DEBUG] added RTLST_ONEXIT=${RTLST_ONEXIT}"
}

function finish {
  #mr_trace "[DEBUG] on_exit_run_routines ..."
  on_exit_run_routines
}
trap finish EXIT

#function ctrl_c() {
#  mr_trace "[DEBUG] user break ..."
#  finish
#  mr_trace "[DEBUG] exit ..."
#  exit 0
#}
#trap ctrl_c INT

################################################################################
# record temp files and delete it on exit
FNLST_TEMP=
function remove_temp_files() {
  #mr_trace "[DEBUG] remove FNLST_TEMP=${FNLST_TEMP}"
  echo "${FNLST_TEMP}" | awk -F, '{for (i=1;i<=NF; i++) print $i; }' | while read a; do
    if test -f "${a}" ; then
      #mr_trace "[DEBUG] rm -f ${a}"
      rm -f "${a}"
    fi
  done
  FNLST_TEMP=
}
function add_temp_file() {
  local PARAM_FN=$1
  shift
  #mr_trace "[DEBUG] add to list: ${PARAM_FN}"
  FNLST_TEMP="${FNLST_TEMP},${PARAM_FN}"
  #mr_trace "[DEBUG] added FNLST_TEMP=${FNLST_TEMP}"
}

# record background process IDs and kill on exit
PSLST_BACK=
function remove_processes() {
  #mr_trace "[DEBUG] remove PSLST_BACK=${PSLST_BACK}"
  echo "${PSLST_BACK}" | awk -F, '{for (i=1;i<=NF; i++) print $i; }' | while read a; do
    if [ ! "${a}" = "" ] ; then
      #mr_trace "[DEBUG] kill ${a}"
      kill -9 "${a}" > /dev/null 2>&1
      sleep 0.5
      kill -9 "${a}" > /dev/null 2>&1
    fi
  done
  PSLST_BACK=
}
function add_process() {
  local PARAM_PS=$1
  shift
  #mr_trace "[DEBUG] add to list: ${PARAM_PS}"
  PSLST_BACK="${PSLST_BACK},${PARAM_PS}"
  #mr_trace "[DEBUG] added PSLST_BACK=${PSLST_BACK}"
}

on_exit_register remove_processes
on_exit_register remove_temp_files

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
    #mr_trace "[DEBUG] uci -q get network.${INTF}.ipaddr"
    IP=`uci -q get network.${INTF}.ipaddr`
    MASK=`uci -q get network.${INTF}.netmask`
    if [ "${IP}" = "" ]; then
      #mr_trace "[WARNING] ignore ${INTF} ipaddr"
      continue
    fi
    if [ "${MASK}" = "" ]; then
      #mr_trace "[WARNING] ignore ${INTF} netmask"
      continue
    fi
    #mr_trace "[INFO] owipcalc ${IP}/${MASK} contains ${HOST_IP}"
    local RET=`owipcalc "${IP}/${MASK}" contains ${HOST_IP}`
    if [ "$RET" = "1" ] ; then
      local TYPE=`uci -q get network.${INTF}.type`
      if [ "${TYPE}" = "bridge" ]; then
        echo "br-${INTF}"
      else
        local IFNAME=`uci -q get network.${INTF}.ifname`
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
    #mr_trace "[DEBUG] CNT=${CNT}; NUM2=${NUM_SVR}"
    #mr_trace "[DEBUG] uci -q get dhcp.@host[${CNT}].ip"
    IP=`uci -q get dhcp.@host[${CNT}].ip`
    #mr_trace "[DEBUG] IP=${IP}; HOST_IP=${HOST_IP}"
    if [ "${IP}" = "${HOST_IP}" ]; then
      #mr_trace "[DEBUG] uci -q get dhcp.@host[${CNT}].mac"
      MAC=`uci -q get dhcp.@host[${CNT}].mac 2>&1`
      if [ $? = 0 ]; then
        #mr_trace "[DEBUG] MAC=$MAC"
        echo ${MAC}
      fi
      break
    fi
    CNT=$(( CNT + 1 ))
    #mr_trace "[DEBUG] CNT=${CNT}"
  done
}

# generate a client list
#   <ip range>,<region>
#
uci_generate_client_list() {
  local FN_OUT_CLI=$1
  shift

  local NUM_CLI=`uci show wolonconn | egrep 'wolonconn.@client\[[0-9]+\]=' | sort | uniq | wc -l`
  #if [[ ${CNT1} < $NUM_SVR ]]; then echo "ok"; else echo "fail"; fi
  local CNT1=0
  while [ `echo | awk -v A=${CNT1} -v B=${NUM_CLI} '{if (A<B) print 1; else print 0;}'` = 1 ]; do
    local CONF_REGION=`uci -q get wolonconn.@client[${CNT1}].region`
    local CONF_IPRANGE=`uci -q get wolonconn.@client[${CNT1}].iprange`
    #mr_trace "[INFO] client[${CNT1}].iprange=${CONF_IPRANGE}; region=${CONF_REGION}"
    echo "${CONF_IPRANGE},${CONF_REGION}" >> "${FN_OUT_CLI}"
    CNT1=$(( CNT1 + 1 ))
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
  local FN_OUT_CLI=$1
  shift

  #mr_trace "[INFO] check_client_send_wol ip='${IP_CLI}' intf='${INTF_SVR}' mac='${MAC_SVR}' dest='${DEST_SVR}'"
  local LINE=
  while read LINE; do
    local CONF_IPRANGE=`echo $LINE | awk -F, '{print $1}'`
    local CONF_REGION=`echo $LINE | awk -F, '{print $2}'`
    #mr_trace "[INFO] client.iprange=${CONF_IPRANGE}; region=${CONF_REGION}"

    if [ ! "${CONF_IPRANGE}" = "" ]; then
      #mr_trace "[INFO] owipcalc ${CONF_IPRANGE} contains ${IP_CLI} ..."
      if [ `owipcalc ${CONF_IPRANGE} contains ${IP_CLI}` = 1 ] ; then
        #mr_trace "[INFO] etherwake -i ${INTF_SVR} ${MAC_SVR}"
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
        #mr_trace "[INFO] etherwake -i ${INTF_SVR} ${MAC_SVR}"
        etherwake -i "${INTF_SVR}" "${MAC_SVR}"
        mr_trace "[INFO] Sent MagicPacket(tm) to ${MAC_SVR} on connection from $clientip to ${DEST_SVR}"
      fi
    fi

  done < "${FN_OUT_CLI}"

}

# generate a client list:
#   <interface>,<mac>,<ip>,<port>
#
# example of conntrack:
# conntrack -L -p tcp --reply-src 10.1.1.23 --reply-port-src 80 --state SYN_SENT
#tcp      6 119 SYN_SENT src=10.1.1.178 dst=10.1.1.23 sport=39226 dport=80 packets=3 bytes=180 [UNREPLIED] src=10.1.1.23 dst=10.1.1.178 sport=80 dport=39226 packets=0 bytes=0 mark=0 use=1
uci_generate_server_list() {
  local FN_OUT_SVR=$1
  shift
  #uci show wolonconn

  mr_trace "[DEBUG] check_conn_send_wol tmp='${FN_TMP}'" #DEBUG#

  local NUM_SVR=`uci show wolonconn | egrep 'wolonconn.@server\[[0-9]+\]=' | sort | uniq | wc -l`
  mr_trace "[DEBUG] NUM_SVR=${NUM_SVR}" #DEBUG#
  #if [[ ${CNT} < $NUM_SVR ]]; then echo "ok"; else echo "fail"; fi
  local CNT=0
  while [ `echo | awk -v A=${CNT} -v B=${NUM_SVR} '{if (A<B) print 1; else print 0;}'` = 1 ]; do
    mr_trace "[DEBUG] CNT=${CNT}" #DEBUG#
    local CONF_INTF=`uci -q get wolonconn.@server[${CNT}].interface`
    local CONF_MAC=`uci -q get wolonconn.@server[${CNT}].mac`
    local CONF_IP=
    local CONF_HOST=`uci -q get wolonconn.@server[${CNT}].host`
    local CONF_PORTS=`uci -q get wolonconn.@server[${CNT}].ports`
    CNT=$(( CNT + 1 ))

    if [ "${CONF_HOST}" = "" ]; then
      mr_trace "[WARNING] not set host='${CONF_HOST}': mac=${CONF_MAC}; ports=${CONF_PORTS};" #DEBUG#
      continue
    fi
    # detect the IP address
    nslookup "${CONF_HOST}" | grep "\-addr.arpa"
    if [ "$?" = "0" ]; then
      CONF_IP="${CONF_HOST}"
    else
      CONF_IP=`nslookup "${CONF_HOST}" | grep "Address 1" | awk -F: '{print $2}'`
    fi
    if [ "${CONF_IP}" = "" ]; then
      mr_trace "[WARNING] not available of server ip: host='${CONF_HOST}'; mac=${CONF_MAC}; ports=${CONF_PORTS};"
      continue
    fi
    if [ "${CONF_PORTS}" = "" ]; then
      #mr_trace "[WARNING] not set server port: mac=${CONF_MAC}; ip=${CONF_IP}"
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
      mr_trace "[WARNING] unable to find the mac of ${CONF_IP}"
      continue
    fi
    if [ "${CONF_INTF}" = "" ]; then
      mr_trace "[WARNING] unable to find the network interface of ${CONF_IP}"
      continue
    fi

    #mr_trace "[INFO] server[${CNT}].mac=${CONF_MAC}; IP=${CONF_IP}"
    for PORT in ${CONF_PORTS}; do
      echo "${CONF_INTF},${CONF_MAC},${CONF_IP},${PORT}" >> "${FN_OUT_SVR}"
    done

  done
}

# read from the server file lines:
#   <interface>,<mac>,<ip>,<port>
# and client file lines:
#   <ip range>,<region>
check_conn_send_wol() {
  local FN_LST_SVR=$1
  shift
  local FN_LST_CLI=$1
  shift
  local FN_TMP=$1
  shift

  local LINE=
  while read LINE; do
    local CONF_INTF=`echo $LINE | awk -F, '{print $1}'`
    local CONF_MAC=`echo $LINE | awk -F, '{print $2}'`
    local CONF_IP=`echo $LINE | awk -F, '{print $3}'`
    local PORT=`echo $LINE | awk -F, '{print $4}'`
    #mr_trace "[INFO] server.interface=${CONF_INTF}; mac=${CONF_MAC}; ip=${CONF_IP}; port=${PORT}"

    #mr_trace "[INFO] conntrack -L -p tcp --reply-src ${CONF_IP} --reply-port-src ${PORT} --state SYN_SENT"
    conntrack -L -p tcp --reply-src ${CONF_IP} --reply-port-src ${PORT} --state SYN_SENT 2>/dev/null > "${FN_TMP}"
    while read CLIENT_IP ; do
      local CLIENT_IP=${CLIENT_IP##*SYN_SENT src=}
      local CLIENT_IP=${CLIENT_IP%% *}

      check_client_send_wol "${CLIENT_IP}" "${CONF_INTF}" "${CONF_MAC}" "${CONF_IP}:${PORT}" "${FN_LST_CLI}"

    done < "${FN_TMP}"
  done < "${FN_LST_SVR}"
}

################################################################################
main() {
  local FN_TMP=''
  local FN_LST_SVR="/tmp/tmp-svrlst-$(uuidgen)"
  local FN_LST_CLI="/tmp/tmp-clilst-$(uuidgen)"

  local FN_LOG1=''
  FN_LOG1=`uci -q get wolonconn.basic.filelog`
  if [ $? = 0 ]; then
    FN_LOG="${FN_LOG1}"
    #mr_trace "[INFO] got wolonconn.basic.filelog=${FN_LOG}"
  else
    mr_trace "[ERROR] failed to get wolonconn.basic.filelog"
  fi

  FN_TMP=`uci -q get wolonconn.basic.filetemp`
  if [ $? = 0 ]; then
    #mr_trace "[INFO] got wolonconn.basic.filetemp=${FN_TMP}"
    echo
  else
    mr_trace "[ERROR] failed to get wolonconn.basic.filetemp"
    FN_TMP="/tmp/tmp-wol-$(uuidgen)"
  fi
  add_temp_file "${FN_TMP}"

  rm -f "${FN_LST_SVR}" "${FN_LST_CLI}"
  uci_generate_server_list "${FN_LST_SVR}"
  uci_generate_client_list "${FN_LST_CLI}"
  add_temp_file "${FN_LST_SVR}"
  add_temp_file "${FN_LST_CLI}"

  while true ; do
    sleep 1
    #mr_trace "[INFO] check_conn_send_wol ..."
    check_conn_send_wol "${FN_LST_SVR}" "${FN_LST_CLI}" "${FN_TMP}"
  done
}

if [ ! "${UNIT_TEST}" = "1" ]; then
  mr_trace "[INFO] start wolonconn ..."
  main

else # UNIT_TEST
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


test_find_intf_by_ip() {
  mr_trace "[INFO] test find_intf_by_ip"
  local INTF=`find_intf_by_ip 10.1.1.23`
  assert $LINENO "'$INTF' = 'br-office'"
}

test_find_mac_by_ip() {
  mr_trace "[INFO] test find_mac_by_ip"
  local MAC=`find_mac_by_ip 10.1.1.23`
  assert $LINENO "'$MAC' = '00:25:31:01:C2:0A'"
}

test_uci_generate_client_list() {
  #TODO:
  mr_trace "[INFO] test uci_generate_client_list"
  local FN_TMP="/tmp/tmp-wol-$(uuidgen)"

  uci_generate_client_list "${FN_TMP}"
  echo "client list file:"; cat "${FN_TMP}"

  local CNT=`cat "${FN_TMP}" | wc -l`
  assert $LINENO "'$CNT' = '1'"

  rm -f "${FN_TMP}"
}

test_uci_generate_server_list() {
  #TODO:
  mr_trace "[INFO] test uci_generate_server_list"
  local FN_TMP="/tmp/tmp-wol-$(uuidgen)"

  uci_generate_server_list "${FN_TMP}"
  echo "server list file:"; cat "${FN_TMP}"

  local CNT=
  CNT=`cat "${FN_TMP}" | wc -l`
  assert $LINENO "'$CNT' = '5'"

  CNT=`cat "${FN_TMP}" | grep br-netlab | wc -l`
  assert $LINENO "'$CNT' = '3'"

  CNT=`cat "${FN_TMP}" | grep br-office | wc -l`
  assert $LINENO "'$CNT' = '2'"

  rm -f "${FN_TMP}"
}

test_in_openwrt_main() {
  if [ ! -x "${EXEC_UCI}" ]; then
    mr_trace "[ERROR] not found uci, skip OpenWrt Unit Tests!"
    return
  fi

  mr_trace "[DEBUG] add_test_config ..."
  add_test_config

  test_find_intf_by_ip
  test_find_mac_by_ip
  test_uci_generate_client_list
  test_uci_generate_server_list

#TODO: show sequence from tcpdump:
#IP=10.1.1.178; PORT=443; tcpdump -n -r web-local-1.pcap host $IP and "tcp[tcpflags] & tcp-syn != 0" | grep ${IP}.${PORT} | awk -F, '{split($2,a," "); if (a[1] == "seq") print a[2];}' | sort | awk 'BEGIN{pre="";cnt=0;}{if (pre != $1) {if (pre != "") print cnt " " pre; cnt=0;} cnt=cnt+1; pre=$1; }END{print cnt " " pre;}'
#1 153253500
#4 3707552423
}

test_all() {

  mr_trace "[DEBUG] test_in_openwrt_main ..."
  test_in_openwrt_main

  mr_trace "[INFO] Done tests successfully!"
}

################################################################################
# config config 'basic'
#   option filetemp '/mnt/sda1/wol-on-conn.temp'
#   option filelog '/mnt/sda1/wol-on-conn.log'
#   option freegeoip 'https://freegeoip.app/csv/$clientip'
#
# config server 'xxx'
#   option host 'datahub.fu'
#   option ports '80 443'
#   option interface 'coredata'
#   option mac 'xx:xx:xx:xx:xx:xx'
# config client 'yyy'
#   option iprange '192.168.1.0/24'
# config client 'zzz'
#   option region 'regionname'
add_test_config_wol() {

  rm -f /tmp/wol-on-conn.log /tmp/wol-on-conn.temp
  rm -f /etc/config/wolonconn

  touch /etc/config/wolonconn
  uci set wolonconn.basic='config'
  uci set wolonconn.basic.filetemp='/tmp/wol-on-conn.temp'
  uci set wolonconn.basic.filelog='/tmp/wol-on-conn.log'

  uci add wolonconn server
  uci set wolonconn.@server[-1].host='datahub.fu'
  uci set wolonconn.@server[-1].ports='22 80 443'
  #uci set wolonconn.@server[-1].interface='br-lan'
  #uci set wolonconn.@server[-1].mac='11:22:33:44:55:01'

  uci add wolonconn server
  uci set wolonconn.@server[-1].host='10.1.1.23'
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

remove_uci_section() {
  local PARAM_SECTION=$1
  shift
  local PARAM_FILTER=$1
  shift

  # remove host config
  local CNT=1
  while [ `echo | awk -v A=0 -v B=${CNT} '{if (A<B) print 1; else print 0;}'` = 1 ]; do

    uci show ${PARAM_SECTION} |  awk -F. '{print $2}' | grep = | awk -F= '{print $1}' \
      | grep "${PARAM_FILTER}" | sort -r | uniq \
      | while read a; do uci -q delete ${PARAM_SECTION}.$a; done

    CNT=`uci show ${PARAM_SECTION} |  awk -F. '{print $2}' | grep = | awk -F= '{print $1}' \
      | grep "${PARAM_FILTER}" | sort -r | uniq | wc -l `

  done
}

add_uci_host_ip_mac() {
  local PARAM_NAME=$1
  shift
  local PARAM_MAC=$1
  shift
  local PARAM_IP=$1
  shift

  uci add dhcp host
  uci set dhcp.@host[-1].name="${PARAM_NAME}"
  uci set dhcp.@host[-1].mac="${PARAM_MAC}"
  uci set dhcp.@host[-1].ip="${PARAM_IP}"

  uci add dhcp domain
  uci set dhcp.@domain[-1].name="${PARAM_NAME}"
  uci set dhcp.@domain[-1].ip="${PARAM_IP}"

  uci commit dhcp
}

add_uci_domain_record() {
  local PARAM_NAME=$1
  shift
  local PARAM_IP=$1
  shift

  # dhcp.@dnsmasq[0].address='/filefetch.fu/10.1.1.23' '/datahub.fu/10.1.1.178'
  uci add_list dhcp.@dnsmasq[0].address="/${PARAM_NAME}/${PARAM_IP}"
  uci commit dhcp
}

add_test_config_dhcp() {
  remove_uci_section "dhcp" "@host"

  add_uci_host_ip_mac "home-nas-1"  "11:22:33:44:55:01" "10.1.1.178"
  add_uci_host_ip_mac "home-pogoplug-v3-2" "00:25:31:01:C2:0A" "10.1.1.23"
}

add_test_config_domain() {
  # delete
  uci -q delete dhcp.@dnsmasq[0].address
  # verify no data
  uci -q get dhcp.@dnsmasq[0].address | grep datahub.fu
  RET=$?
  assert $LINENO "'$RET' = '1'"
  uci -q get dhcp.@dnsmasq[0].address | grep datahub.fu
  RET=$?
  assert $LINENO "'$RET' = '1'"

  # add test data
  add_uci_domain_record "filefetch.fu" "10.1.1.23"
  add_uci_domain_record "datahub.fu" "10.1.1.178"

  # verify the values
  uci -q get dhcp.@dnsmasq[0].address | grep datahub.fu
  RET=$?
  assert $LINENO "'$RET' = '0'"
  uci -q get dhcp.@dnsmasq[0].address | grep filefetch.fu
  RET=$?
  assert $LINENO "'$RET' = '0'"
}

add_test_config() {
  mr_trace "[ERROR] please setup the test openwrt as hostmain."
  mr_trace "[ERROR] unit test will remove the original UCI 'dhcp@host' and 'dhcp.@dnsmasq[0].address' configs and replace with tests."

  add_test_config_dhcp
  add_test_config_domain
  /etc/init.d/dnsmasq restart

  add_test_config_wol
}

#mr_trace "[DEBUG] test_all ..."
test_all

fi # UNIT_TEST
