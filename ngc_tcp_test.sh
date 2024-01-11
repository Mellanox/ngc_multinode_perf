#!/bin/bash
# NGC Certification TCP test v2.3
# Owner: amira@nvidia.com
#

if (($# < 4)); then
    echo "usage: $0 <client trusted ip> <client ib device>[,client ib device2] <server trusted ip> <server ib device>[,server ib device2] [--duplex=<'HALF','FULL'>] [--change_mtu=<'CHANGE','DONT_CHANGE'>] [--duration=<sec>] [--max_proc=<number>]"
    echo "		   duplex - options: HALF,FULL, default: HALF"
    echo "		   change_mtu - options: CHANGE,DONT_CHANGE, default: CHANGE"
    echo "		   duration - time in seconds, default: 120"
    echo "		   max_proc - use up to max_proc of process for each port"
    echo "		   disable_ro - add this flag as workaround for Sapphire Rapid CPU that missing/disabled the following tuning in BIOS (Socket Configuration > IIO Configuration > Socket# Configuration > PE# Restore RO Write Perf > Enabled)"
    echo "		                You will need to restart the driver and re run again"
    echo "		   allow_core_zero - allow binding process on core 0, default:false"
    echo "		   neighbor_levels - in case there is no enough cores on NIC numa, specify the number of closet neighbor numa to collect cores form it, default:2"
    exit 1
fi
scriptdir="$(dirname "$0")"
source "${scriptdir}/common.sh"

while [ $# -gt 0 ]
do
    case "${1}" in
        --duplex=*)
            DUPLEX="${1#*=}"
            shift
            ;;
        --change_mtu=*)
            CHANGE_MTU="${1#*=}"
            shift
            ;;
        --duration=*)
            TEST_DURATION="${1#*=}"
            shift
            ;;
        --max_proc=*)
            MAX_PROC="${1#*=}"
            shift
            ;;
        --disable_ro)
            DISABLE_RO=true
            shift
            ;;
        --allow_core_zero)
            ALLAOW_CORE_ZERO=true
            shift
            ;;
        --neighbor_levels=*)
            NEIGHBOR_LEVELS="${1#*=}"
            shift
            ;;
        --*)
            fatal "Unknown option ${1}"
            ;;
        *)
            POSITIONAL_ARGS+=("${1}")
            shift
            ;;
    esac
done
set -- "${POSITIONAL_ARGS[@]}"

CLIENT_TRUSTED="${1}"
CLIENT_DEVICES=(${2//,/ })
SERVER_TRUSTED="${3}"
SERVER_DEVICES=(${4//,/ })
IS_CLIENT_SPR=false
IS_SERVER_SPR=false


[[ "$DUPLEX" == "FULL" ]] && DUPLEX=true || DUPLEX=false
[ -n "${CHANGE_MTU}" ] || CHANGE_MTU="CHANGE"
[ -n "${DISABLE_RO}" ] || DISABLE_RO=false
[ -n "${TEST_DURATION}" ] || TEST_DURATION="120"
[ -n "${MAX_PROC}" ] || MAX_PROC="32"
[ -n "${ALLAOW_CORE_ZERO}" ] || ALLAOW_CORE_ZERO=false
[ -n "${NEIGHBOR_LEVELS}" ] || NEIGHBOR_LEVELS=1


CLIENT_CORE_USAGES_FILE="/tmp/ngc_client_core_usages.log"
SERVER_CORE_USAGES_FILE="/tmp/ngc_server_core_usages.log"

if [ "$DISABLE_RO" = true ]
then
    echo -e "${ORANGE}WARN: apply WA for Sapphire system - please apply the following tuning in BIOS - Socket Configuration > IIO Configuration > Socket# Configuration > PE# Restore RO Write Perf > Enabled instead of using this WA${NC}"
    sleep 2
fi

if [ "${#SERVER_DEVICES[@]}" -ne "${#CLIENT_DEVICES[@]}" ]
then
    fatal "The number of server and client devices must be equal."
fi
NUM_DEVS=${#SERVER_DEVICES[@]}

#init the arrays SERVER_IPS,CLIENT_IPS,SERVER_NETDEVS,CLIENT_NETDEVS
get_ips_and_ifs
LINK_TYPE="$(ssh "${CLIENT_TRUSTED}" "cat /sys/class/net/${CLIENT_NETDEVS[0]}/type")"
[ $CHANGE_MTU = "CHANGE" ] && change_mtu
min_l=$(get_min_channels)
opt_proc=$((min_l<MAX_PROC ? min_l : MAX_PROC))

#try collect 2 more cores than needed incase we need to ditch core 0 (this is why we need opt_proc+2)
read -ra CORES_ARRAY <<< $(get_cores_for_devices $1 $2 $3 $4 $((opt_proc+2)))
#NUM_CORES_PER_DEVICE will be the actual cores that need to be used
NUM_CORES_PER_DEVICE=$(( ${#CORES_ARRAY[@]}/(${#CLIENT_DEVICES[@]}*2) ))
log "INFO:number of cores per device to be used is $NUM_CORES_PER_DEVICE, if duplex then half of them will act as servers and half as clients"

log "${CORES_ARRAY[*]}"

if [ "$DUPLEX" = true ]
then
    log "INFO: running Full duplex"
    NUM_INST=$((NUM_CORES_PER_DEVICE/2))
else
    log "INFO: running half duplex"
    NUM_INST=${NUM_CORES_PER_DEVICE}
fi

BASE_TCP_POTR=10000

FORCE_EXIT=false
#Set number of cores to use and apply tuning according to #core and list of cores
#Expected global params :
#CLIENT_TRUSTED,CLIENT_DEVICES,SERVER_TRUSTED,SERVER_DEVICES,NUM_INST,opt_proc,CORES_ARRAY
tune_tcp
#Relaxed ordring was disabled - user need to restart the driver so that the change take affect.
[ $FORCE_EXIT = true ] && echo -e "${RED}Please restart driver after disabling relaxed ordering (RO), and run the script again ${NC}" && exit 1

TIME_STAMP=$(date +%s)
#Run server side
run_iperf_servers
sleep 2
#Run client side
run_iperf_clients

#Post traffic -collect stats
collect_stats

#wait for traffic to finish
wait
sleep 1
#Print statistics
print_stats $SERVER_TRUSTED
print_stats $CLIENT_TRUSTED

#Collect the output
collect_BW
