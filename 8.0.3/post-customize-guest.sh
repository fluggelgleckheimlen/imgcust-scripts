#!/bin/sh
### BEGIN INIT INFO
# Provides: post-customize-guest
# Required-Start: $network $remote_fs
# Required-Stop: $network $remote_fs
# Default-Start: 3 5
# Default-Stop: 0 1 2 6
# Description: VMware post-reboot guest customization agent
### END INIT INFO

# The above is needed in order to turn this script into a service on Suse

LOG_DIR="/var/log/vmware-imc"
LOG_FILE="${LOG_DIR}/customization.log"

POST_CUSTOMIZATION_TMP_DIR=/root/.customization
POST_CUSTOMIZATION_TMP_SCRIPT_NAME=$POST_CUSTOMIZATION_TMP_DIR/customize.sh

POST_REBOOT_PENDING_MARKER=/.guest-customization-post-reboot-pending

DATE=/bin/date
ECHO=/bin/echo
GREP=/bin/grep
RM="/bin/rm -f"
CAT=/bin/cat

if [ -f /usr/bin/logger ]; then
   LOGGER="/usr/bin/logger"
elif [ -f /bin/logger ]; then
   LOGGER="/bin/logger"
else
   LOGGER="$ECHO"
fi

Log() {
   msg="$1"
   ${LOGGER} -p local7.notice -t "NET" "customize-guest : ${msg}"
   time=`${DATE} "+%b %d %T"`
   ${ECHO} "${time} customize-guest: ${msg}" >> ${LOG_FILE}
   # NOTE: any additional logging output should not be sent to stderr, since it will be treated as customization error later
   # DEBUG: uncomment the next line if you want to have merged log in toolsDeployPkg.log
   # ${ECHO} "${time} customize-guest: ${msg}"
}

AnalyzeReturnCode() {
   returnCode=$1
   msg=$2
   if [ $returnCode != 0 ]; then
      Log "WARNING: '$msg' returned with error code $returnCode"
   else
      Log "INFO: '$msg' returned successfully (error code 0)"
   fi
}

Log "Post-reboot agent started"

Log "The argument is '$1'"

case "$1" in
   "")
      Log "Running as non-service"
      ;;
   start)
      Log "Starting as a service"
      ;;
   stop)
      Log "Stopping as a service. Exiting to avoid running before reboot"
      exit 0
      ;;
esac

Log "Execution continues..."

# Suse may trigger this several times (for instance on service stop), but that's not a problem
if [ ! -f $POST_REBOOT_PENDING_MARKER ]; then
   Log "No post-reboot marker detected. Skipping"
else
   currentDir=$(dirname $0)
   # After post script is scheduled, GOS still need about 5 sec to reboot.
   # So ensure this script won't be executed within guard time (10 sec)
   # Be noted: This script is shared with cloud-init which doesn't need
   # guard time since no reboot for cloud-init.
   guardTime=`${DATE} "+%s" -r ${POST_REBOOT_PENDING_MARKER}`
   case "$currentDir" in
      *per-instance*)
         Log "cloud-init doesn't need guard time"
         ;;
      *)
         guardTime=$((guardTime+10))
         ;;
   esac
   now=`${DATE} "+%s"`
   if [ $now -lt $guardTime ]; then
      Log "Waiting the GOS to reboot. Skipping"
      exit 0
   fi

   ${RM} $POST_REBOOT_PENDING_MARKER
   Log "Calling post-reboot customization script"
   #Do not specify shell interpreter, because it may bring in syntactic error
   ($POST_CUSTOMIZATION_TMP_SCRIPT_NAME "postcustomization" \
      > /tmp/stdout.log 2>&1)
   AnalyzeReturnCode $? "Post-customization"
   out=`${CAT} /tmp/stdout.log`
   if [ x"$out" != x"" ]; then
      Log "Post-reboot customization output:"
      Log "$out"
   else
      Log "Post-reboot customization output is empty"
   fi
fi

Log "Post-reboot agent finished"
