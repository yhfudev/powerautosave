#!/usr/bin/env bash
# turn system to sleep when system is idle.

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
    echo "$(date +"%Y-%m-%d %H:%M:%S.%N" | cut -c1-23) [self=${BASHPID},$(basename "$0")] $@" | tee -a ${FN_LOG} 1>&2
    #logger -t powerautosave "$@"
}

fatal_error() {
  echo "$(date +"%Y-%m-%d %H:%M:%S.%N" | cut -c1-23) [self=${BASHPID},$(basename "$0")] FATAL: $@" | tee -a ${FN_LOG} 1>&2
  #logger -t powerautosave "[FATAL] $@"
  exit 1
}

################################################################################
EXEC_BASH="$(which bash)"
if [ ! -x "${EXEC_BASH}" ]; then
    mr_trace "[ERR] not found bash"
    exit 1
fi

EXEC_PRIPS="$(which prips)"
if [ ! -x "${EXEC_PRIPS}" ]; then
    mr_trace "[ERR] not found prips"
    exit 1
fi

EXEC_IPCALC="$(which ipcalc)"
if [ ! -x "${EXEC_IPCALC}" ]; then
    mr_trace "[ERR] not found ipcalc"
    exit 1
fi

intall_software() {
  apt update
  apt -y install bash prips ipcalc
}

################################################################################
if [ -f "./libshrt.sh" ]; then
. ./libshrt.sh
HDFF_NUM_CLONE=16
fi

# generate session for this process and its children
#  use mp_get_session_id to get the session id later
mp_new_session

################################################################################

# detect if the processes is active
# return 0 on no process
detect_processes() {
  local RET=0
  local PROC=""
  #mr_trace "PARAM=$@"
  for PROC in $@; do
    if [ ! "`pgrep $PROC`" = "" ]; then
      RET=1
      break
    fi
  done
  echo "${RET}"
}

## @fn worker_ping_ip()
## @brief a worker for ping host
## @param session_id the session id
## @param ip the host ip
## @param fn the file to save the IPs
## and also the bash library libshrt.sh
function worker_ping_ip() {
    local PARAM_SESSION_ID="$1"
    shift
    local PARAM_IP="$1"
    shift
    local PARAM_FN_LIST="$1"
    shift

    #mr_trace "ping -c 1 -W 1 ${PARAM_IP} ..."
    ping -c 1 -W 1 ${PARAM_IP}
    if [ "$?" = "0" ]; then
      # awk -v rseed=$RANDOM 'BEGIN{srand(rseed);}{print rand()" "$0}'
      sleep $( echo | awk -v A=$RANDOM '{printf("%4.3f\n", (A%20+1)*0.3);}' )
      # push to the list
      mr_trace "add to list: ${PARAM_IP} ..."
      echo "${PARAM_IP}" >> ${PARAM_FN_LIST}
    fi

    mp_notify_child_exit ${PARAM_SESSION_ID}
}
mr_trace "here 200000 ..."

## @fn ping_ip_list_from_file()
## @brief ping the IP from the list in a file
## @param fn_in the file contains the IPs to be ping
## @param fn_out the file contains the IPs that are actived
## return 0 if none actived, 1 if host exists
ping_ip_list_from_file() {
  local PARAM_FN_IN=$1
  shift
  local PARAM_FN_OUT=$1
  shift
  mr_trace "ping_ip_list_from_file ..."

  HDFF_NUM_CLONE=300
  while read IP; do
    worker_ping_ip "$(mp_get_session_id)" "${IP}" "${PARAM_FN_OUT}" &
    PID_CHILD=$!
    mp_add_child_check_wait ${PID_CHILD}
  done < "${PARAM_FN_IN}"
  mp_wait_all_children
  mr_trace "HDFF_NUM_CLONE=${HDFF_NUM_CLONE}"
  HDFF_NUM_CLONE=16
}
mr_trace "here 300000 ..."

## @fn ping_ip_range()
## @brief detect the IP range
## @param ip1 the ip/prefix 1
## @param ip1 the ip/prefix 2
## return the detected host IPs
ping_ip_range() {
  local PARAM_FN_OUT=$1
  shift
  local PARAM_IP1=$1
  shift
  local PARAM_IP2=$1
  shift
  mr_trace "ping_ip_range ..."

  # ipcalc -b 192.168.0.1/24
  # prips 192.168.0.1 192.168.1.3
  if [ "${PARAM_IP2}" = "" ]; then
    # only ip/prefix
    IP1=$( ipcalc -b ${PARAM_IP1} | grep "HostMin:" | awk '{print $2}' )
    IP2=$( ipcalc -b ${PARAM_IP1} | grep "HostMax:" | awk '{print $2}' )
  else
    # IP range
    IP1=$( ipcalc -b ${PARAM_IP1} | grep "Address:" | awk '{print $2}' )
    IP2=$( ipcalc -b ${PARAM_IP2} | grep "Address:" | awk '{print $2}' )
  fi
  local FN_LIST="/tmp/tmp-list-$(uuidgen)"
  prips $IP1 $IP2 > "${FN_LIST}"
  ping_ip_list_from_file "${FN_LIST}" "${PARAM_FN_OUT}"
  #cat "${PARAM_FN_OUT}"
  rm -f "${FN_LIST}"
}

LST_ACTIVE_IP=
## @fn ping_list()
## @brief ping the IP in the list
## return 1 if there exist host or 0 if none, and update LST_ACTIVE_IP
ping_list() {
  local FN_LIST="/tmp/tmp-list-$(uuidgen)"
  local FN_OUT="/tmp/tmp-out-$(uuidgen)"
  echo ${LST_ACTIVE_IP} > "${FN_LIST}"
  ping_ip_list_from_file "${FN_LIST}" "${FN_OUT}"
  rm -f "${FN_LIST}"
  LST_ACTIVE_IP=$( cat "${FN_OUT}" )
  mr_trace "LST_ACTIVE_IP=${LST_ACTIVE_IP}"
}


## @fn detect_ip()
## @brief detect the IP range
## @param ip1 the ip/prefix 1
## @param ip1 the ip/prefix 2
## return 1 if there exist host or 0 if none, and set LST_ACTIVE_IP
detect_ip() {
  local PARAM_IP1=$1
  shift
  local PARAM_IP2=$1
  shift
}

detect_hd() {
  local PARAM_PROC=$1
  shift

  echo ""
}

# turn the host to sleep mode
# mode: one of suspend
enter_sleep() {
  PARAM_MODE=$1
  shift

  mr_trace "enter sleep mode '${PARAM_MODE}' ..."
  sync && sleep 2 && systemctl ${PARAM_MODE}
}

# the main loop to detect the background activities
# if the system is idle, then go to sleep
do_detect() {
  mr_trace "do_detect() ..."
  mr_trace "check if host exists ..."
  mr_trace "check if CPUs are idle ..."
  mr_trace "check if disks are idle ..."
  mr_trace "check if exist background processes ..."
  mr_trace "wake up at specific time ..."
  #enter_sleep suspend
}

################################################################################
# tests:

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

test_detect_processes() {
  local RET1=0

  RET1=`detect_processes bash`
  #mr_trace "RET1=${RET1}"
  assert $LINENO "'${RET1}' = '1'"

  RET1=`detect_processes 'abc'`
  assert $LINENO "'${RET1}' = '0'"
}

test_detect_ip() {
  local FN_LIST="/tmp/tmp-list-$(uuidgen)"
  rm -f "${FN_LIST}"
  touch "${FN_LIST}"
  #ping_ip_range "10.1.1.160/27"
  ping_ip_range "${FN_LIST}" "10.1.2.1/24"
  echo "output IP list:"
  cat "${FN_LIST}"
  rm -f "${FN_LIST}"
}

test_all() {

  test_detect_processes
  test_detect_ip

  mr_trace "Done tests successfully!"
}

test_all

do_detect


