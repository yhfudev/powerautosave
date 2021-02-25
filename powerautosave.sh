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
    #echo "$(date +"%Y-%m-%d %H:%M:%S.%N" | cut -c1-23) [self=${BASHPID},$(basename "$0")] $@" | tee -a ${FN_LOG} 1>&2
    logger -t powerautosave "$@"
}

fatal_error() {
  #echo "$(date +"%Y-%m-%d %H:%M:%S.%N" | cut -c1-23) [self=${BASHPID},$(basename "$0")] FATAL: $@" | tee -a ${FN_LOG} 1>&2
  logger -t powerautosave "[FATAL] $@"
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
  #apt -y install sysstat # for mpstat
  apt -y install pcp #for dstat
}

################################################################################
# manage temp files
FNLST_TEMP=
function remove_temp_files() {
  #mr_trace "remove FNLST_TEMP=${FNLST_TEMP}"
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
  #mr_trace "add to list: ${PARAM_FN}"
  FNLST_TEMP="${FNLST_TEMP},${PARAM_FN}"
  #mr_trace "added FNLST_TEMP=${FNLST_TEMP}"
}

# mange background processes
PSLST_BACK=
function remove_processes() {
  #mr_trace "remove PSLST_BACK=${PSLST_BACK}"
  echo "${PSLST_BACK}" | awk -F, '{for (i=1;i<=NF; i++) print $i; }' | while read a; do
    if [ ! "${a}" = "" ] ; then
      echo kill "${a}"
      kill -9 "${a}"
      sleep 0.5
      kill -9 "${a}"
    fi
  done
  PSLST_BACK=
}
function add_process() {
  local PARAM_PS=$1
  shift
  #mr_trace "add to list: ${PARAM_PS}"
  PSLST_BACK="${PSLST_BACK},${PARAM_PS}"
  #mr_trace "added PSLST_BACK=${PSLST_BACK}"
}

function finish {
  #mr_trace "remove_processes ..."
  remove_processes
  #mr_trace "remove_temp_files ..."
  remove_temp_files
}
trap finish EXIT

#function ctrl_c() {
#  mr_trace "user break ..."
#  finish
#  mr_trace "exit ..."
#  exit 0
#}
#trap ctrl_c INT

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
    if [ "$PROC" = "" ]; then
      continue
    fi
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
  ping -c 1 -W 1 ${PARAM_IP} > /dev/null 2>&1
  if [ "$?" = "0" ]; then
    # awk -v rseed=$RANDOM 'BEGIN{srand(rseed);}{print rand()" "$0}'
    sleep $( echo | awk -v A=$RANDOM '{printf("%4.3f\n", (A%20+1)*0.3);}' )
    # push to the list
    #mr_trace "add to list: ${PARAM_IP} ..."
    echo "${PARAM_IP}" >> ${PARAM_FN_LIST}
  fi

  mp_notify_child_exit ${PARAM_SESSION_ID}
}

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
  #mr_trace "ping_ip_list_from_file ..."

  HDFF_NUM_CLONE=300
  while read IP; do
    worker_ping_ip "$(mp_get_session_id)" "${IP}" "${PARAM_FN_OUT}" &
    PID_CHILD=$!
    mp_add_child_check_wait ${PID_CHILD}
  done < "${PARAM_FN_IN}"
  mp_wait_all_children
  #mr_trace "HDFF_NUM_CLONE=${HDFF_NUM_CLONE}"
  HDFF_NUM_CLONE=16
}

## @fn ping_ip_range()
## @brief detect the IP range
## @param ip1 the ip/prefix 1
## @param ip2 the ip/prefix 2
## return the detected host IPs
ping_ip_range() {
  local PARAM_FN_OUT=$1
  shift
  local PARAM_IP1=$1
  shift
  local PARAM_IP2=$1
  shift
  #mr_trace "ping_ip_range ..."

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
  rm -f "${FN_LIST}" # add_temp_file "${FN_LIST}"
}

FN_LIST_ACTIVE_IP="/tmp/tmp-list-activeip-$(uuidgen)"
## @fn ping_list()
## @brief ping the IP in the list
## @param fn_in the file contains the IP range list to be ping. such as
##    host_begin1/24 host_end1/24
##    host_2
##    ...
## return 1 if there exist host or 0 if none, and update LST_ACTIVE_IP
ping_list() {
  local PARAM_FN_IN=$1
  shift

  local FN_TMPOUT="/tmp/tmp-tmpout-$(uuidgen)"
  touch "${FN_LIST_ACTIVE_IP}" "${FN_TMPOUT}"
  ping_ip_list_from_file "${FN_LIST_ACTIVE_IP}" "${FN_TMPOUT}"
  mv "${FN_TMPOUT}" "${FN_LIST_ACTIVE_IP}"

  if [ `cat "${FN_LIST_ACTIVE_IP}" | wc -l` -gt 0 ]; then
    echo "1"
    return
  fi

  # ping all
  local IP1=
  local IP2=
  while read IP1 IP2; do
    ping_ip_range "${FN_LIST_ACTIVE_IP}" "$IP1" "$IP2"
  done < "${PARAM_FN_IN}"
  if [ `cat "${FN_LIST_ACTIVE_IP}" | wc -l` -gt 0 ]; then
    echo "1"
    return
  fi
  echo "0"
}

start_dstat() {
  local PARAM_FN_OUT=$1
  shift

  # dstat: real time CPU/Network/Disk-Activity
  # versatile replacement for vmstat, iostat, mpstat, netstat and ifstat
  # https://github.com/dstat-real/dstat.git
  # https://packages.debian.org/sid/dstat
  # updated by dool
  # https://github.com/scottchiefbaker/dool.git
  # RedHat version: https://www.redhat.com/en/blog/implementing-dstat-performance-co-pilot
  # dstat --nocolor -c -d -n --output out.csv
#"Dstat 0.8.0 CSV output"
#"Author:","Dag Wieers <dag@wieers.com>",,,,"URL:","http://dag.wieers.com/home-made/dstat/"
#"Host:","mce",,,,"User:","yhfu"
#"Cmdline:","dstat --nocolor -c -d -n --output out.csv",,,,"Date:","24 Feb 2021 15:07:42 EST"
#"total cpu usage",,,,,"dsk/total",,"net/total",
#"usr","sys","idl","wai","stl","read","writ","recv","send"
#24.806,5.705,69.202,0.287,0,26528.650,105565.894,0,0
#9.608,1.643,88.748,0,0,0,0,1751,2613
#6.289,1.635,92.075,0,0,0,32768,675,0
#6.431,1.387,92.182,0,0,0,0,2495,1100

# pcp:
# dstat --nocolor -c -d -n --output out.csv
#"pcp-dstat 5.0.3 CSV Output"
#"Author:","PCP team <pcp@groups.io> and Dag Wieers <dag@wieers.com>",,,,"URL:","https://pcp.io/ and http://dag.wieers.com/home-made/dstat/"
#"Host:","mce",,,,"User:","yhfu"
#"Cmdline:","dstat --nocolor -c -d -n --output out.csv",,,,"Date:","24 Feb 2021 15:37:42 EST"
#"total usage",,,,,"dsk/total",,"net/total",
#"total usage:usr","total usage:sys","total usage:idl","total usage:wai","total usage:stl","dsk/total:read","dsk/total:writ","net/total:recv","net/total:send"
#4.369,0.624,94.248,0,0,0,0,0,0
#6.874,1.000,92.243,0,0,0,0,341.975,0
#4.125,1.125,94.002,0,0,0,0,66.001,637.010
#4.500,0.500,94.620,0,0,0,0,0,0
#3.375,0.625,95.491,0,0,0,0,341.966,0
#3.627,0.750,95.297,0.125,0,0,32.016,66.033,94.047
#3.499,0.250,95.338,0,0,0,0,0,0
#4.250,0.500,95.122,0,0,0,0,341.988,0

  dstat --nocolor -c -d -n --output "${PARAM_FN_OUT}" > /dev/null 2>&1 &
  local PID_CHILD=$!
  sleep 0.5
  # remove the file header, the dstat will continue to put the data to the end of file
  rm -f "${FN_CSV_DSTAT}"
  add_process $PID_CHILD
}

# turn the host to sleep mode
# mode: one of suspend
enter_sleep() {
  PARAM_MODE=$1
  shift

  mr_trace "enter sleep mode '${PARAM_MODE}' ..."
  sync && sleep 2 && systemctl ${PARAM_MODE}
}

FN_CSV_DSTAT="/tmp/tmp-csv-dstat-$(uuidgen)"

# the main loop to detect the background activities
# if the system is idle, then go to sleep
## @param exptimes the number of consequence idle values that cause the system sleep
## @param fn_ip_pair a list of IP pairs for host IP ranges, if there's no exist any of the host, then it's idle
## @param fn_proc a list of process names, if there's no exist any of the process, then it's idle
do_detect() {
  PARAM_EXPTIMES=$1
  shift
  PARAM_FN_IP_PAIR=$1
  shift
  PARAM_FN_PROC=$1
  shift

  mr_trace "do_detect() ..."

  start_dstat "${FN_CSV_DSTAT}"

  local FN_CSV_TMP="/tmp/tmp-csv-tmp-$(uuidgen)"
  local RET=0
  local CNT=0
  local CNTRD=0
  while true; do
    CNT=$(( CNT + 1 ))

    #mr_trace "check if host exists ..."
    RET=`ping_list "${PARAM_FN_IP_PAIR}"`
    # ... reset to CNT=0 if exist IP
    if [ "$RET" = "1" ]; then
      CNT=0
    fi

    #mr_trace "check if exist background processes ..."
    local ALLPS=`cat "${PARAM_FN_PROC}"`
    RET=`detect_processes ${ALLPS}`
    # ... reset to CNT=0 if exist processes
    if [ "$RET" = "1" ]; then
      CNT=0
    fi

    if [ "$CNT" = "0" ]; then
      mr_trace "previous check reset CNT, continue"
      rm -f "${FN_CSV_DSTAT}"
      continue
    fi

    mv "${FN_CSV_DSTAT}" "${FN_CSV_TMP}"
    CNTRD=0
    while read LINE; do
      mr_trace "read line: '$LINE'"
      mr_trace "check if CPUs are idle ..."
      mr_trace "check if disks are idle ..."
      mr_trace "check if have large background network traffic ..."

      #"usr","sys","idl", "wai","stl", "read","writ", "recv","send"
      #24.806,5.705,69.202, 0.287,0, 26528.650,105565.894, 0,0
      # cpu >90%
      # disk r/w < 100k
      # net recv/send < 1k
      RET=`echo $LINE | awk -F, 'BEGIN{out=0}{ if ($3 < 90.0) out=1; if ($6 > 100000) out=1;if ($7 > 100000) out=1; if ($8 > 1000) out=1;if ($9 > 1000) out=1; }END{print out;}'`
      if [ "$RET" = "1" ]; then
        #mr_trace "reset CNT=0"
        CNT=0
      fi

      CNTRD=$(( CNTRD + 1 ))
      if [ $CNTRD -gt 5 ]; then
        #mr_trace "break CNT=$CNT"
        break
      fi
    done < "${FN_CSV_TMP}"
    rm -f "${FN_CSV_TMP}"
    #mr_trace "PARAM_EXPTIMES=$PARAM_EXPTIMES"

    if [ $CNT -gt $PARAM_EXPTIMES ]; then
      mr_trace "wake up at specific time ..."
      enter_sleep suspend
    fi
    sleep 3
  done
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

  if test $PARAM_COND ; then
    return
    # and continue executing the script.
  else
    echo "Assertion failed at \"$0\":$PARAM_LINE : \"$PARAM_COND\""
    exit $E_ASSERT_FAILED
  fi
} # Insert a similar assert() function into a script you need to debug.

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

test_add_process() {
  local PID_1=
  local PID_2=
  local RET=

  sleep 10000 &
  PID_1=$!
  assert $LINENO "'${PSLST_BACK}' = ''"
  add_process $PID_1
  assert $LINENO "! '${PSLST_BACK}' = ''"
  sleep 1.8
  ps -ef | grep -v grep |  grep $PID_1
  RET=$?
  assert $LINENO " $RET = 0 "

  sleep 20000 &
  PID_2=$!
  add_process $PID_2
  sleep 2.7
  ps -ef | grep -v grep |  grep $PID_2
  RET=$?
  assert $LINENO " $RET = 0 "

  sleep 1.1
  remove_processes
  assert $LINENO "'${PSLST_BACK}' = ''"
  ps -ef | grep -v grep |  grep $PID_1
  RET=$?
  assert $LINENO " $RET = 1 "
  ps -ef | grep -v grep |  grep $PID_2
  RET=$?
  assert $LINENO " $RET = 1 "
}

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
  test_add_process
  test_add_temp_files
  test_detect_processes
  test_detect_ip

  mr_trace "Done tests successfully!"
}

add_test_config() {
  FN_IP="/tmp/out-ip"
  FN_PROC="/tmp/out-proc"
  rm -f "${FN_IP}" "${FN_PROC}"
  touch "${FN_IP}" "${FN_PROC}"
  echo "10.1.1.160/24" >> "${FN_IP}"
  echo "bash" >> "${FN_PROC}"
}

#add_test_config
test_all

add_temp_file "${FN_CSV_DSTAT}"
add_temp_file "${FN_LIST_ACTIVE_IP}"

FN_IP="/etc/powerautosave/pas-ip.list"
FN_PROC="/etc/powerautosave/pas-proc.list"
do_detect 30 "${FN_IP}" "${FN_PROC}"

