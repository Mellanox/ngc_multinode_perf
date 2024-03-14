#!/bin/bash
set -eE

# Variables
scriptdir="$(dirname "$0")"
LOGFILE="/tmp/ngc-internal-loopback-test_$(date +%H:%M:%S__%d-%m-%Y).log"
tests="--tests=ib_write_bw,ib_read_bw,ib_send_bw"
source "${scriptdir}/common.sh"

# Parse command line options
while [ $# -gt 0 ]; do
    case "${1}" in
        --vm)
            RUN_AS_VM=true
            shift
            ;;
        --aff)
            if [ -f "${2}" ]; then
                AFFINITY_FILE="${2}"
                RUN_AS_VM=true
                shift 2
            else
                fatal "--aff parameter requires a file"
            fi
            ;;
        --with_cuda)
            RUN_WITH_CUDA=true
            shift
            ;;
        --cuda_only)
            ONLY_CUDA=true
            RUN_WITH_CUDA=true
            shift
            ;;
        --write)
            tests="--tests=ib_write_bw"
            shift
            ;;
        --read)
            tests="--tests=ib_read_bw"
            shift
            ;;
        -h|--help)
            help
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
SERVER_IP=${1}


# Check if --aff is provided without --with_cuda or --cuda_only
if [ -n "${AFFINITY_FILE}" ] && [ -z "${RUN_WITH_CUDA}" ] && [ -z "${ONLY_CUDA}" ]; then
    fatal "If --aff is provided, either --with_cuda or --cuda_only must also be provided."
fi


help() {
    local WHITE RESET
    WHITE=$(tput bold)
    RESET=$(tput sgr0)
    cat <<EOF >&2
  Internal Loopback wrapper for ngc_rdma_test.sh.
  A Logfile is created under /tmp/.
  RDMA devices are obtained from 'ibdev2netdev' command.
  Criteria for Pass/Fail - 90% line rate of the port speed.

  * Passwordless SSH access to the participating nodes is required.
  * Passwordless sudo root access is required from the SSH'ing user.
  * Dependencies which need to be installed: numctl, perftest.

  * For Virtual Machines, you can change the NIC<->GPU affinity by
  providing the affinity in a file.
  The file should consist two lines, one for GPUs and the other for NICs.
  Example:
  echo "mlx5_0 mlx5_1 mlx5_2 mlx5_3 mlx5_4 mlx5_5 mlx5_6 mlx5_7" > gpuaff.txt
  echo "GPU6 GPU3 GPU1 GPU7 GPU4 GPU2 GPU0 GPU5" >> gpuaff.txt

  Options:
  --vm        # Use this flag when running on a VM
  --aff       # Used with the --vm flag to provide a different NIC<->GPU affinity
  --write     # Run write tests only
  --read      # Run read tests only
  --with_cuda # Run both RDMA and GPUDirect
  --cuda_only # Run only GPUDirect

  ${WHITE}Usage:
  Run RDMA & GPUDirect:
  $0 Server --with_cuda

  Run RDMA only:
  $0 Server

  Hosts with different NIC<->GPU affinity:
  $0 Server --vm --aff \$FILE --with_cuda${RESET}

EOF
    exit 1
}


# Internal loopback function for Hosts
ngc_rdma_internal_lb() {
    local use_cuda
    # Determine the current test being run (CUDA on/off)
    if [[ "${1}" == "use_cuda" ]]; then
        use_cuda="--use_cuda"
        echo -e "\nNGC BW RDMA Test (Internal Loopback) in progress... (CUDA on)" | tee -a "${LOGFILE}"
        echo "With CUDA:"
    else
        if [ "${ONLY_CUDA}" = "true" ]; then
            return
        fi
        use_cuda=""
        echo "NGC BW RDMA Test (Internal Loopback) in progress... (CUDA off)" | tee -a "${LOGFILE}"
        echo "Without CUDA:"
    fi

     # Loop over the Host devices
    for i in "${SERVER_MLNX[@]}"; do
        # Store the current element's value in a variable
        echo -e "${WHITE}=== Device: ${i} ===${NC}" &>> "${LOGFILE}"
        if ! "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "${i}" "${SERVER_IP}" "${i}" "${tests}" ${use_cuda} "--unidir" &>> "${LOGFILE}" ; then
            echo "${RED}Issue with device ${SERVER_MLNX[i]} <-> ${SERVER_MLNX[i]}${NC}" | tee -a "${LOGFILE}"
        fi
        wrapper_results
    done
}


# Internal loopback function for VMs
ngc_rdma_vm_internal_lb() {
    local use_cuda
    # Determine the current test being run (CUDA on/off)
    if [[ "${1}" == "use_cuda" ]]; then
        use_cuda="--use_cuda"
        echo -e "\nNGC BW RDMA Test (Internal Loopback) in progress... (CUDA on)" | tee -a "${LOGFILE}"
        echo "With CUDA:" | tee -a "${LOGFILE}"

        # Loop over the Host devices
        for ((i=0; i<${#SERVER_MLNX[@]}; i++)); do
            gpu_index="${GPU_ARR[i]//[!0-9]/}"
            echo -e "${WHITE}=== Devices: ${SERVER_MLNX[i]} <-> ${GPU_ARR[i]} ===${NC}" &>> "${LOGFILE}"
            if ! "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "${SERVER_MLNX[i]}" "${SERVER_IP}" "${SERVER_MLNX[i]}" "${tests}" ${use_cuda} --server_cuda="${gpu_index}" --client_cuda="${gpu_index}" "--unidir" &>> "${LOGFILE}" ; then
                echo -e "${RED}Issue with device ${SERVER_MLNX[i]} <-> ${GPU_ARR[i]}${NC}" | tee -a "${LOGFILE}"
            fi
            wrapper_results
        done

    else
        if [ "${ONLY_CUDA}" = "true" ]; then
            return
        fi
        use_cuda=""
        echo "NGC BW RDMA Test (Internal Loopback) in progress... (CUDA off)" | tee -a "${LOGFILE}"
        echo "Without CUDA:" | tee -a "${LOGFILE}"

          # Loop over the Host devices
        for ((i=0; i<${#SERVER_MLNX[@]}; i++)); do
            echo -e "${WHITE}=== Device: ${SERVER_MLNX[i]} ===${NC}" &>> "${LOGFILE}"
            if ! "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "${SERVER_MLNX[i]}" "${SERVER_IP}" "${SERVER_MLNX[i]}" "${tests}" ${use_cuda} "--unidir" &>> "${LOGFILE}" ; then
                echo -e "${RED}Issue with device ${SERVER_MLNX[i]} <-> ${SERVER_MLNX[i]}${NC}"  | tee -a "${LOGFILE}"
            fi
            wrapper_results
        done
    fi
}


# Determine nic <-> gpu affinity
nic_to_gpu_affinity() {
    # Display NIC & GPU affinity according to file
    if [ -n "${AFFINITY_FILE}" ]; then
        if [ -f "${AFFINITY_FILE}" ]; then
            echo "NIC to GPU affinity according to ${AFFINITY_FILE} file:" | tee -a "${LOGFILE}"
            GPU_LINE=$(grep -ni "gpu" "${AFFINITY_FILE}" | cut -d ':' -f1)
            NIC_LINE=$(grep -ni "mlx" "${AFFINITY_FILE}" | cut -d ':' -f1)
            if [[ -z "${NIC_LINE}" || -z "${GPU_LINE}" ]]; then
                fatal "Error with file ${AFFINITY_FILE}"
            fi
            SERVER_MLNX=($(awk "NR==${NIC_LINE}" "${AFFINITY_FILE}"))
            GPU_ARR=($(awk "NR==${GPU_LINE}" "${AFFINITY_FILE}"))
            for ((i=0; i<${#SERVER_MLNX[@]}; i++)); do
                echo "${SERVER_MLNX[i]} <-> ${GPU_ARR[i]}" | tee -a "${LOGFILE}"
            done
        else
            fatal "Error with file ${AFFINITY_FILE}."
        fi
    else
        # Display default NIC & GPU affinity
        # Find CUDA & RDMA devices
        readarray -t GPU_ARR <<< "$(ssh "${SERVER_IP}" nvidia-smi -L | awk '{print $1 $2}' | tr -d ':')" ||
        fatal "Couldn't get CUDA devices"
        readarray -t SERVER_MLNX <<< "$(ssh "${SERVER_IP}" ibdev2netdev  | awk '{print $1}')"  ||
        fatal "Couldn't get NICs from ibdev2netdev"
        echo "NIC to GPU affinity:" | tee -a "${LOGFILE}"
        for ((i=0; i<${#SERVER_MLNX[@]}; i++)); do
            echo "${SERVER_MLNX[i]} <-> ${GPU_ARR[i]}" | tee -a "${LOGFILE}"
        done
    fi

    # Ask the user to confirm
    tries=0
    while true; do
        read -r -p "Is the affinity correct? [yY]/[nN]: " user_confirm
        case "${user_confirm}" in
        [yY])
            break
            ;;
        [nN])
            echo "Please provide affinity file (see README)"
            exit 0
            ;;
        *)
            tries=$(( tries + 1 ))
            if (( tries == 3 )); then
                fatal "Reached maximum attempts. Exiting.."
            fi
            ;;
        esac
    done
}


# Check for SSH connectivity
check_ssh() {
    if ! ssh -q "${SERVER_IP}" exit; then
        fatal "SSH connection failed for: ${SERVER_IP}."
    fi
}


if (( $# == 1 )); then
    check_ssh "${SERVER_IP}"
    # Get device's BIOS info
    ssh "${SERVER_IP}" sudo dmidecode -t 0,1 &> "${LOGFILE}"
    echo "=== Server: ${SERVER_IP} ===" &>> "${LOGFILE}"
    log "Created log file: ${LOGFILE}"

    # Determine if running as VM
    if [ "${RUN_AS_VM}" = "true" ]; then
        # Check GPU affinity if cuda is required
        if [ "${RUN_WITH_CUDA}" = "true" ]; then
            nic_to_gpu_affinity
        else
            readarray -t SERVER_MLNX <<< "$(ssh "${SERVER_IP}" ibdev2netdev | awk '{print $1}')" ||
                fatal "Couldn't get NICs from ibdev2netdev"
        fi
        # VM Loopback without CUDA
        ngc_rdma_vm_internal_lb
        # VM Loopback with CUDA
        if [ "${RUN_WITH_CUDA}" = "true" ]; then
            ngc_rdma_vm_internal_lb "use_cuda"
        fi
    else
        # Get MLNX devices
        readarray -t SERVER_MLNX <<< "$(ssh "${SERVER_IP}" ibdev2netdev | awk '{print $1}')" ||
            fatal "Couldn't get NICs from ibdev2netdev"
        # Without CUDA
        ngc_rdma_internal_lb
        # With CUDA
        if [ "${RUN_WITH_CUDA}" = "true" ]; then
            ngc_rdma_internal_lb "use_cuda"
        fi
    fi
else
    help
fi
