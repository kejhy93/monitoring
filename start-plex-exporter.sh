#!/usr/bin/env bash
set -e

# --- Configuration ---
POD_NAME="plexpod"
PLEX_IMAGE="docker.io/linuxserver/plex:latest"
EXPORTER_IMAGE="ghcr.io/jsclayton/prometheus-plex-exporter:latest"
PLEX_CLAIM="claim-2BQkSUa1DqtngkUbBigR" # optional
PLEX_CONFIG_DIR="$HOME/plex/config"
PLEX_TRANSCODE_DIR="$HOME/plex/transcode"
PLEX_MEDIA_DIR="/mnt/data/videos"

# --- Create directories if missing ---
mkdir -p "$PLEX_CONFIG_DIR" "$PLEX_TRANSCODE_DIR" "$PLEX_MEDIA_DIR"

# --- Create Pod ---
echo "Creating Podman pod '$POD_NAME'..."
podman pod create \
  --name "$POD_NAME" \
  --network host \

# --- Run Plex Media Server ---
echo "Starting Plex container..."
echo "PLEX_IMAGE: ${PLEX_IMAGE}"
podman run -d \
  --name plex \
  --network host \
  --pod "$POD_NAME" \
  -e TZ="Europe/Prague" \
  -e PLEX_CLAIM="$PLEX_CLAIM" \
  -e PUID=$(id -u) \
  -e PGID=$(id -g) \
  -v "$PLEX_CONFIG_DIR:/config:Z" \
  -v "$PLEX_TRANSCODE_DIR:/transcode:Z" \
  -v "$PLEX_MEDIA_DIR:/data:Z" \
  "$PLEX_IMAGE"

# --- Run Plex Exporter ---
echo "Starting Plex Exporter..."
podman run -d \
  --name plex_exporter \
  --network host \
  --pod "$POD_NAME" \
  --restart=on-failure \
  -e PLEX_SERVER=http://localhost:32400 \
  -e PLEX_TOKEN="$PLEX_TOKEN" \
  "$EXPORTER_IMAGE"

# --- Verify ---
echo
echo "✅ Plex Pod created successfully!"
echo "Plex UI:     http://<your-host-ip>:32400/web"
echo "Exporter:    http://<your-host-ip>:9000/metrics"
echo
podman pod ps

