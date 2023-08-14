#!/bin/bash
set -eE

# Variables
CLIENT_IP=${1}
HOST_IP=${2}
WHITE='\033[1;37m'
NC='\033[0m'
scriptdir="$(dirname "$0")"

help() {
    local WHITE RESET
    WHITE=$(tput bold)
    RESET=$(tput sgr0)
    cat <<EOF >&2

  Execute ngc_rdma_test.sh for each MLNX device on the hosts.
  Run as root and make sure the hosts are passwordless.
  Assume they are connected b2b and the PCIe devices are identical.
  ${WHITE}Usage:
  $0 host client${RESET}

EOF
    exit 1
}

# Show the help menu unless 2 arguments provided (Host & Client IP/Hostname)
(( $# == 2 )) || help

# Get MLNX devices (PCIe & RDMA):
readarray -t HOST_MLNX <<< "$(ssh "${HOST_IP}" mst status -v  | awk '/mlx/{print $3 " " $4}' | sort -k2n)"


# Function to loop over each MLNX device without CUDA
ngc_rdma_test() {
    local use_cuda
    local element
    [ "${1}" = "use_cuda" ] && use_cuda="use_cuda" || use_cuda=""
    # Loop over the Host devices
    for i in "${!HOST_MLNX[@]}"; do
        # Store the current element's value in a variable
        element="${HOST_MLNX[i]}"

        # Seperate the element to PCI_DEVICE and MLX
        PCI_DEVICE=$(echo "${element}" | cut -d ' ' -f 1)
        MLX=$(echo "${element}" | cut -d ' ' -f 2)

        # If the current element ends in .1, skip to next iteration
        [[ ${PCI_DEVICE} != *.1 ]] || continue

        # Store PCI Prefix & Set dual_port to false
        PCI_PREFIX="${element%.*}"
        dual_port=false

        # Loop and check if the current device is Dual Port
        for device in "${HOST_MLNX[@]}"; do
            if [[ ${device} == "${PCI_PREFIX}"*".1 "* ]]; then
                dual_port=true
                break
            fi
        done

        # Store  the next index in the HOST_MLNX
        next_index=$((i + 1))
        # Determine whether there is another element in the HOST_MLNX to skip to
        if [ ${next_index} -lt ${#HOST_MLNX[@]} ]; then
            # Store the next element's value in a variable
            next_element="${HOST_MLNX[next_index]}"
            PCI_DEVICE2=$(echo "${next_element}" | cut -d ' ' -f 1)
            MLX2=$(echo "${next_element}" | cut -d ' ' -f 2)
            i=${next_index}  # Skip the next element
        fi

        # If the device is Dual Port
        if [[ $dual_port == true ]]; then
            echo -e "${WHITE}Dual Port -  1st Port: ${MLX} PCI: ${PCI_DEVICE} | 2nd Port: ${MLX2} PCI: ${PCI_DEVICE2}${NC}"
            "${scriptdir}/ngc_rdma_test.sh" "${HOST_IP}" "${MLX}","${MLX2}" "${CLIENT_IP}" "${MLX}","${MLX2}" ${use_cuda}

            # If the device is Single Port:
        else
            echo -e "${WHITE}Single Port - ${MLX} Located on PCI: ${PCI_DEVICE}${NC}"
            "${scriptdir}/ngc_rdma_test.sh" "${HOST_IP}" "${MLX}" "${CLIENT_IP}" "${MLX}" ${use_cuda}
        fi
    done
}


### Call the RDMA test function (Without CUDA)
ngc_rdma_test

### Call the RDMa test function (with CUDA)
ngc_rdma_test "use_cuda"
