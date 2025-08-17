#!/bin/bash

# Validate docker network monitoring exists

NETWORK_NAME="monitoring"

if docker network ls --format '{{.Name}}' | grep -wq "$NETWORK_NAME"; then
  echo "Docker network '$NETWORK_NAME' already exists."
else
  echo "Docker network '$NETWORK_NAME' does not exist. Creating it..."
  docker network create "$NETWORK_NAME"

  if [ $? -eq 0 ]; then
    echo "Docker network '$NETWORK_NAME' created successfully."
  else
    echo "Failed to create Docker network '$NETWORK_NAME'."
    exit 1
  fi
fi


PROMETHEUS_CONTAINER_NAME="prometheus"
# Check if container is already running
if docker ps --format '{{.Names}}' | grep -wq "$PROMETHEUS_CONTAINER_NAME"; then
  echo "Container '$PROMETHEUS_CONTAINER_NAME' is already running."
else
  # Check if container exists (but is stopped)
  if docker ps -a --format '{{.Names}}' | grep -wq "$PROMETHEUS_CONTAINER_NAME"; then
    echo "Starting existing container '$PROMETHEUS_CONTAINER_NAME'..."
    docker start "$PROMETHEUS_CONTAINER_NAME"
  else
    echo "Running new container '$PROMETHEUS_CONTAINER_NAME'..."
    docker run -d -p 9090:9090 --name=prometheus -v ~/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml prom/prometheus
    docker run -d \
	    -p 9090:9090 \
	    -v ~/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml \
	    --name "$PROMETHEUS_CONTAINER_NAME" \
	    --network "$NETWORK_NAME" \
	    prom/prometheus
  fi
fi

GRAFANA_CONTAINER_NAME="grafana"
# Check if container is already running
if docker ps --format '{{.Names}}' | grep -wq "$GRAFANA_CONTAINER_NAME"; then
  echo "Container '$GRAFANA_CONTAINER_NAME' is already running."
else
  # Check if container exists (but is stopped)
  if docker ps -a --format '{{.Names}}' | grep -wq "$GRAFANA_CONTAINER_NAME"; then
    echo "Starting existing container '$GRAFANA_CONTAINER_NAME'..."
    docker start "$GRAFANA_CONTAINER_NAME"
  else
    echo "Running new container '$GRAFANA_CONTAINER_NAME'..."
    docker run -d \
	    -p 3000:3000 \
	    --name "$GRAFANA_CONTAINER_NAME" \
	    --network "$NETWORK_NAME" \
	    grafana/grafana
  fi
fi

# Verify prometheus container is connected to monitoring network
if docker inspect -f '{{json .NetworkSettings.Networks}}' "$PROMETHEUS_CONTAINER_NAME" | grep -q "\"$NETWORK_NAME\""; then
  echo "Container '$PROMETHEUS_CONTAINER_NAME' is connected to network '$NETWORK_NAME'."
else
  echo "Connecting container '$PROMETHEUS_CONTAINER_NAME' to network '$NETWORK_NAME'..."
  docker network connect "$NETWORK_NAME" "$PROMETHEUS_CONTAINER_NAME"
fi

if docker inspect -f '{{json .NetworkSettings.Networks}}' "$GRAFANA_CONTAINER_NAME" | grep -q "\"$NETWORK_NAME\""; then
  echo "Container '$GRAFANA_CONTAINER_NAME' is connected to network '$NETWORK_NAME'."
else
	echo "Connecting container '$GRAFANA_CONTAINER_NAME' to network '$NETWORK_NAME'..."
  docker network connect "$NETWORK_NAME" "$GRAFANA_CONTAINER_NAME"
fi

