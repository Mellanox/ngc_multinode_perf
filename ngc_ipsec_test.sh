#!/bin/bash
# NGC Certification IPsec full offload test v0.0
#Owner: dorko@nvidia.com
#
LOCAL_BF=$1
REMOTE_BF=$2
TEST=$3 #should be: rdma/tcp/both
CLIENT_IP=$4
CLIENT_DEVICE=$5
SERVER_IP=$6
SERVER_DEVICE=$7
scriptdir="$(dirname "$0")"
cd "$scriptdir"

#Setup IPsec full offload
bash ./ipsec_full_offload_setup.sh ${LOCAL_BF} ${REMOTE_BF}

#Run Tests
if [ ${TEST} == rdma ] || [ ${TEST} == both ]; 
then
    bash ./ngc_rdma_test.sh ${CLIENT_IP} ${CLIENT_DEVICE} ${SERVER_IP} ${SERVER_DEVICE}
fi

if [ ${TEST} == tcp ] || [ ${TEST} == both ]; 
then
    bash ./ngc_tcp_test.sh ${CLIENT_IP} ${CLIENT_DEVICE} ${SERVER_IP} ${SERVER_DEVICE} 1500
fi

if [ ${TEST} != rdma ] && [ ${TEST} != tcp ] && [ ${TEST} != both ]; 
then
    echo no such test option!
fi
