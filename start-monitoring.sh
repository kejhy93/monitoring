#!/bin/bash

# Validate docker network monitoring exists

NETWORK_NAME="monitoring"

if podman network ls --format '{{.Name}}' | grep -wq "$NETWORK_NAME"; then
  echo "Docker network '$NETWORK_NAME' already exists."
else
  echo "Docker network '$NETWORK_NAME' does not exist. Creating it..."
  podman network create "$NETWORK_NAME"

  if [ $? -eq 0 ]; then
    echo "Docker network '$NETWORK_NAME' created successfully."
  else
    echo "Failed to create Docker network '$NETWORK_NAME'."
    exit 1
  fi
fi

# Detect OS type
OS="$(uname -s)"
ADD_HOST_FLAG=""

if [ "$OS" = "Linux" ]; then
  echo "Running on Linux → resolving Docker host gateway IP"
  # Try to detect the default gateway IP used by docker0
  if [[ "$OS" == "Linux" ]]; then
    # Try Docker bridge gateway
    HOST_IP=$(ip route | grep docker0 | awk '{print $9}' || true)

    # Fallback to default gateway
    if [[ -z "$HOST_IP" ]]; then
        HOST_IP=$(ip route | grep '^default' | awk '{print $3}')
    fi
  ADD_HOST_FLAG="--add-host=host.docker.internal:$HOST_IP"
  echo "Adding host mapping: host.docker.internal -> $HOST_IP"
  fi
else
  echo "Running on $OS → no extra host mapping needed"
fi

PROMETHEUS_CONTAINER_NAME="prometheus"
# Check if container is already running
if podman ps --format '{{.Names}}' | grep -wq "$PROMETHEUS_CONTAINER_NAME"; then
  echo "Container '$PROMETHEUS_CONTAINER_NAME' is already running."
else
  # Check if container exists (but is stopped)
  if podman ps -a --format '{{.Names}}' | grep -wq "$PROMETHEUS_CONTAINER_NAME"; then
    echo "Starting existing container '$PROMETHEUS_CONTAINER_NAME'..."
    podman start "$PROMETHEUS_CONTAINER_NAME"
  else
    echo "Running new container '$PROMETHEUS_CONTAINER_NAME'..."
    # docker run -d -p 9090:9090 --name=prometheus -v ~/monitoring/prometheus.yml:/etc/prometheus/prometheus.yml prom/prometheus
    podman run -d \
	    -v ~/monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:Z \
	    --name "$PROMETHEUS_CONTAINER_NAME" \
	    --network host \
	    prom/prometheus
  fi
fi

GRAFANA_CONTAINER_NAME="grafana"
# Check if container is already running
if podman ps --format '{{.Names}}' | grep -wq "$GRAFANA_CONTAINER_NAME"; then
  echo "Container '$GRAFANA_CONTAINER_NAME' is already running."
else
  # Check if container exists (but is stopped)
  if podman ps -a --format '{{.Names}}' | grep -wq "$GRAFANA_CONTAINER_NAME"; then
    echo "Starting existing container '$GRAFANA_CONTAINER_NAME'..."
    podman start "$GRAFANA_CONTAINER_NAME"
  else
    echo "Running new container '$GRAFANA_CONTAINER_NAME'..."
    podman run -d \
	    --name "$GRAFANA_CONTAINER_NAME" \
	    --network host \
	    grafana/grafana
  fi
fi
