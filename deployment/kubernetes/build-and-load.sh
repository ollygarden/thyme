#!/usr/bin/env bash
set -euo pipefail

# Build and load Thyme image into k3d cluster
# Usage: ./build-and-load.sh [cluster-name]

CLUSTER_NAME="${1:-k3s-default}"
IMAGE_NAME="ghcr.io/ollygarden/thyme"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

echo "Building Thyme container image..."
docker build -t "${FULL_IMAGE}" ../../

echo "Loading image into k3d cluster '${CLUSTER_NAME}'..."
k3d image import "${FULL_IMAGE}" -c "${CLUSTER_NAME}"

echo "✓ Image ${FULL_IMAGE} built and loaded into k3d cluster ${CLUSTER_NAME}"
echo ""
echo "To verify the image is available:"
echo "  docker exec k3d-${CLUSTER_NAME}-server-0 crictl images | grep thyme"
echo ""
echo "To deploy:"
echo "  kubectl apply -k deployment/kubernetes/"
