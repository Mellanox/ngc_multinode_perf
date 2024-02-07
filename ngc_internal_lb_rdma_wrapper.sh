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
        --with_cuda)
            RUN_WITH_CUDA=true
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
AFFINITY_FILE=${2}


help() {
    local WHITE RESET
    WHITE=$(tput bold)
    RESET=$(tput sgr0)
    cat <<EOF >&2
  Internal Loopback wrapper for ngc_rdma_test.sh
  A Logfile is created under /tmp/
  RDMA devices are obtained from 'ibdev2netdev' command.
  Criteria for Pass/Fail - 90% line rate of the port speed.

  * Passwordless SSH access to the participating nodes is required.
  * Passwordless sudo root access is required from the SSH'ing user.
  * Dependencies which need to be installed: numctl, perftest.

  ** For Virtual Machines, you can change the NIC<->GPU affinity by
  creating an providing the affinity in a file.should consist a two lines,
  The file should consist two lines, one for GPUs and the other for NICs.
  Example:
  echo "mlx5_0 mlx5_1 mlx5_2 mlx5_3 mlx5_4 mlx5_5 mlx5_6 mlx5_7" > gpuaff.txt
  echo "GPU6 GPU3 GPU1 GPU7 GPU4 GPU2 GPU0 GPU5" >> gpuaff.txt


  ${WHITE}Usage:
  $0 Server --with_cuda

  Run without CUDA:
  $0 Server

  Hosts with different NIC<->GPU affinity:
  $0 Server \$FILE --with_cuda${RESET}

EOF
    exit 1
}


# Internal loopback function for Hosts
ngc_rdma_internal_lp() {
    local use_cuda
    # Determine the current test being run (CUDA on/off)
    if [[ "${1}" == "use_cuda" ]]; then
        use_cuda="--use_cuda"
        echo -e "\nNGC BW RDMA Test (Internal Loopback) in progress... (CUDA on)" | tee -a "${LOGFILE}"
        echo "With CUDA:"
    else
        use_cuda=""
        echo "NGC BW RDMA Test (Internal Loopback) in progress... (CUDA off)" | tee -a "${LOGFILE}"
        echo -e "${WHITE}--- Results ---${NC}"
        echo "Without CUDA:"
    fi

     # Loop over the Host devices
    for i in "${SERVER_MLNX[@]}"; do
        # Store the current element's value in a variable
        echo -e "${WHITE}=== Device: ${i} ===${NC}" &>> "${LOGFILE}"
        if ! "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "${i}" "${SERVER_IP}" "${i}" "${tests}" ${use_cuda} "--unidir" &>> "${LOGFILE}" ; then
            echo "${RED}Issue with device ${SERVER_MLNX[i]} <-> ${GPU_ARR[i]}" | tee -a "${LOGFILE}${NC}"
        fi
        wrapper_results
    done
}


# Internal loopback function for VMs
ngc_rdma_vm_internal_lp() {
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
                echo -e "${RED}Issue with device ${SERVER_MLNX[i]} <-> ${GPU_ARR[i]}" | tee -a "${LOGFILE}${NC}"
            fi
            wrapper_results
        done
    else
        use_cuda=""
        echo "NGC BW RDMA Test (Internal Loopback) in progress... (CUDA off)" | tee -a "${LOGFILE}"
        echo -e "${WHITE}--- Results ---${NC}" | tee -a "${LOGFILE}"
        echo "Without CUDA:" | tee -a "${LOGFILE}"
          # Loop over the Host devices
        for ((i=0; i<${#SERVER_MLNX[@]}; i++)); do
            echo -e "${WHITE}=== Device: ${SERVER_MLNX[i]} ===${NC}" &>> "${LOGFILE}"
            if ! "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "${SERVER_MLNX[i]}" "${SERVER_IP}" "${SERVER_MLNX[i]}" "${tests}" ${use_cuda} "--unidir" &>> "${LOGFILE}" ; then
                echo -e "${RED}Issue with device ${SERVER_MLNX[i]} <-> ${GPU_ARR[i]}${NC}"  | tee -a "${LOGFILE}"
            fi
            wrapper_results
        done
    fi
}


# Determine nic <-> gpu affinity function
nic_to_gpu_affinity() {
    echo -e "${WHITE}Hostname provided detected as a Virtual Machine${NC}"| tee -a "${LOGFILE}"
    # Display NIC & GPU affinity according to file
    if [ -n "${AFFINITY_FILE}" ]; then
        if [ -f "${AFFINITY_FILE}" ]; then
            echo "NIC to GPU affinity according to ${AFFINITY_FILE} file:" | tee -a "${LOGFILE}"
            GPU_LINE=$(grep -ni "gpu" "${AFFINITY_FILE}" | cut -d ':' -f1)
            NIC_LINE=$(grep -ni "mlx" "${AFFINITY_FILE}" | cut -d ':' -f1)
            SERVER_MLNX=($(awk "NR==${NIC_LINE}" "${AFFINITY_FILE}"))
            GPU_ARR=($(awk "NR==${GPU_LINE}" "${AFFINITY_FILE}"))
            for ((i=0; i<${#SERVER_MLNX[@]}; i++)); do
                echo "${SERVER_MLNX[i]} <-> ${GPU_ARR[i]}" | tee -a "${LOGFILE}"
            done
        else
            echo "Error with file ${AFFINITY_FILE}."
            exit 1
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
        fatal "SSH connection failed for: ${SERVER_IP}. Exiting.."
    fi
}


if (( $# == 1  ||  $# == 2 )); then
    check_ssh "${SERVER_IP}"
    # Get device's BIOS info
    ssh "${SERVER_IP}" sudo dmidecode -t 0,1 &> "${LOGFILE}"
    log "Created log file: ${LOGFILE}"

    # Determine if host is a VM
    if grep -iqE "qemu|virtual" "${LOGFILE}"; then
        # Check GPU affinity
        if [ "${RUN_WITH_CUDA}" = "true" ]; then
            nic_to_gpu_affinity
        else
            readarray -t SERVER_MLNX <<< "$(ssh "${SERVER_IP}" ibdev2netdev | awk '{print $1}')" ||
                fatal "Couldn't get NICs from ibdev2netdev"
        fi
        # Loopback without CUDA
        ngc_rdma_vm_internal_lp
        # Loopback with CUDA
        if [ "${RUN_WITH_CUDA}" = "true" ]; then
            ngc_rdma_vm_internal_lp "use_cuda"
        fi
    else
        # Loopback without CUDA
        ngc_rdma_internal_lp
        # Loopback test with CUDA
        if [ "${RUN_WITH_CUDA}" = "true" ]; then
            ngc_rdma_internal_lp "use_cuda"
        fi
    fi
else
    help
fi
