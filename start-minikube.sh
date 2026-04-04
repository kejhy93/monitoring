#!/usr/bin/env bash
set -e

DRIVER="podman"
CONTAINER_RUNTIME="containerd"

# --- Check if already running ---
if minikube status 2>/dev/null | grep -q "host: Running"; then
  echo "minikube is already running."
  minikube status
  exit 0
fi

echo "minikube is not running. Attempting to start..."

# --- Try a normal start first ---
if minikube start --driver="$DRIVER" --container-runtime="$CONTAINER_RUNTIME" 2>/dev/null; then
  echo "minikube started successfully."
  minikube status
  exit 0
fi

echo "Normal start failed. Running recovery..."

# --- Recovery: purge broken profile ---
echo "Step 1: Deleting broken minikube profile..."
minikube delete --purge 2>/dev/null || true

# --- Recovery: remove orphaned podman volume ---
echo "Step 2: Removing orphaned podman volume..."
podman volume rm minikube 2>/dev/null || true

# --- Recovery: ensure rootless is configured ---
echo "Step 3: Configuring rootless mode..."
minikube config set rootless true

# --- Recovery: start fresh ---
echo "Step 4: Starting minikube fresh..."
minikube start --driver="$DRIVER" --container-runtime="$CONTAINER_RUNTIME"

echo
echo "minikube started successfully!"
minikube status
