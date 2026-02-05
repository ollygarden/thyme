#!/bin/bash
set -o xtrace

# Bootstrap the node with EKS
/etc/eks/bootstrap.sh ${cluster_name} \
  --b64-cluster-ca '${cluster_ca}' \
  --apiserver-endpoint '${cluster_endpoint}' \
  --kubelet-extra-args '--max-pods=110'
