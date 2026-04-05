#!/usr/bin/env bash
set -e

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POD_NAME="plexpod"
PLEX_IMAGE="docker.io/linuxserver/plex:latest"
EXPORTER_IMAGE="ghcr.io/jsclayton/prometheus-plex-exporter:latest"
PLEX_CLAIM="claim-2BQkSUa1DqtngkUbBigR" # optional
PLEX_CONFIG_DIR="$HOME/plex/config"
PLEX_TRANSCODE_DIR="$HOME/plex/transcode"
PLEX_MEDIA_DIR="/mnt/data/videos"
PLEX_SEAGATE_DIR="/var/mnt/seagate"

# --- GPU Configuration ---
# Options: "vaapi" (Intel/AMD), "nvidia", "none"
# Auto-detect if GPU_TYPE is not set explicitly
VAAPI_DEVICE=""

detect_gpu() {
  if [[ -e /dev/nvidia0 ]]; then
    GPU_TYPE="nvidia"
    echo "Auto-detected GPU_TYPE='nvidia'"
    return
  fi

  GPU_TYPE="none"
  local best_vram=0
  for card_path in /sys/class/drm/card*/device; do
    local vram_file="$card_path/mem_info_vram_total"
    [[ -f "$vram_file" ]] || continue
    local vram
    vram=$(< "$vram_file")
    if (( vram > best_vram )); then
      best_vram=$vram
      local render
      render=$(ls "$card_path/drm/" 2>/dev/null | grep '^renderD' | head -1)
      [[ -n "$render" ]] && VAAPI_DEVICE="/dev/dri/$render"
      GPU_TYPE="vaapi"
    fi
  done

  if [[ "$GPU_TYPE" == "vaapi" ]]; then
    echo "Auto-detected GPU_TYPE='vaapi' (VRAM: $((best_vram / 1073741824)) GB, device: ${VAAPI_DEVICE:-/dev/dri})"
    return
  fi

  if [[ -d /dev/dri ]]; then
    local render_node
    render_node=$(find /dev/dri -maxdepth 1 -type c -name 'renderD*' 2>/dev/null | sort | head -n1)
    if [[ -n "$render_node" ]]; then
      VAAPI_DEVICE="$render_node"
      GPU_TYPE="vaapi"
      echo "Auto-detected GPU_TYPE='vaapi' (fallback, device: $VAAPI_DEVICE)"
      return
    fi
  fi

  echo "Auto-detected GPU_TYPE='none'"
}

if [[ -z "${GPU_TYPE:-}" ]]; then
  detect_gpu
fi
GPU_TYPE="${GPU_TYPE:-none}"

GPU_FLAGS=()
case "$GPU_TYPE" in
  vaapi)
    GPU_FLAGS=(--device "${VAAPI_DEVICE:-/dev/dri}")
    ;;
  nvidia)
    GPU_FLAGS=(
      --device /dev/nvidia0
      --device /dev/nvidiactl
      --device /dev/nvidia-uvm
      --security-opt label=disable
    )
    ;;
  none)
    ;;
  *)
    echo "Unknown GPU_TYPE='$GPU_TYPE'. Use vaapi, nvidia, or none." >&2
    exit 1
    ;;
esac

# --- Helpers ---
pod_exists()       { podman pod exists "$POD_NAME" 2>/dev/null; }
pod_running()      { [ "$(podman pod inspect "$POD_NAME" --format '{{.State}}' 2>/dev/null)" = "Running" ]; }
container_exists() { podman container exists "$1" 2>/dev/null; }

print_status() {
  local HOST_IP
  HOST_IP=$(hostname -I | awk '{print $1}')
  echo
  echo "--- Plex Pod Status ---"
  echo "  Plex UI:   http://${HOST_IP}:32400/web"
  echo "  Exporter:  http://${HOST_IP}:9000/metrics"
  echo
  podman pod ps --filter "name=${POD_NAME}"
}

# --- Already running? ---
if pod_exists && pod_running; then
  echo "Plex pod '${POD_NAME}' is already running."
  print_status
  exit 0
fi

# --- Create directories if missing ---
mkdir -p "$PLEX_CONFIG_DIR" "$PLEX_TRANSCODE_DIR" "$PLEX_MEDIA_DIR"

# --- Create Pod if missing ---
if ! pod_exists; then
  echo "Creating Podman pod '${POD_NAME}'..."
  podman pod create \
    --name "$POD_NAME" \
    --network host
else
  echo "Pod '${POD_NAME}' already exists, skipping creation."
fi

# --- Create Plex container if missing ---
if ! container_exists plex; then
  echo "Creating Plex container (image: ${PLEX_IMAGE})..."
  podman create \
    --name plex \
    --network host \
    --pod "$POD_NAME" \
    -e TZ="Europe/Prague" \
    -e PLEX_CLAIM="$PLEX_CLAIM" \
    -e PUID="$(id -u)" \
    -e PGID="$(id -g)" \
    -v "$PLEX_CONFIG_DIR:/config:Z" \
    -v "$PLEX_TRANSCODE_DIR:/transcode:Z" \
    -v "$PLEX_MEDIA_DIR:/data:Z" \
    -v "$PLEX_SEAGATE_DIR:/seagate" \
    "${GPU_FLAGS[@]}" \
    "$PLEX_IMAGE"
else
  echo "Container 'plex' already exists, skipping creation."
fi

# --- Create Plex Exporter container if missing ---
if ! container_exists plex_exporter; then
  echo "Creating Plex Exporter container..."
  podman create \
    --name plex_exporter \
    --network host \
    --pod "$POD_NAME" \
    --restart=on-failure \
    -e PLEX_SERVER=http://localhost:32400 \
    -e PLEX_TOKEN="$PLEX_TOKEN" \
    "$EXPORTER_IMAGE"
else
  echo "Container 'plex_exporter' already exists, skipping creation."
fi

# --- Start Pod ---
echo "Starting pod '${POD_NAME}'..."
podman pod start "$POD_NAME"

# --- Done ---
echo
echo "Plex pod started successfully!"
print_status

# --- Ensure minikube is running and check monitoring stack (opt-in via START_MINIKUBE=true) ---
if [[ "${START_MINIKUBE:-true}" == "true" ]]; then
  echo "--- Minikube ---"
  bash "${SCRIPT_DIR}/start-minikube.sh"

  echo "--- Monitoring Stack ---"
  NOT_READY=()

  check_deployment() {
    local label="$1" name="$2"
    local ready total
    ready=$(kubectl get pods -n monitoring -l "$label" --no-headers 2>/dev/null \
      | grep -c "Running" || true)
    total=$(kubectl get pods -n monitoring -l "$label" --no-headers 2>/dev/null \
      | wc -l | tr -d ' ')
    if [[ "$total" -eq 0 ]]; then
      NOT_READY+=("$name (no pods found)")
    elif [[ "$ready" -lt "$total" ]]; then
      NOT_READY+=("$name ($ready/$total pods running)")
    else
      echo "  [OK] $name ($ready/$total pods running)"
    fi
  }

  check_deployment "app.kubernetes.io/name=prometheus"  "Prometheus"
  check_deployment "app.kubernetes.io/name=grafana"     "Grafana"

  if [[ ${#NOT_READY[@]} -gt 0 ]]; then
    echo
    echo "WARNING: The following monitoring components are not ready:"
    for item in "${NOT_READY[@]}"; do
      echo "  - $item"
    done
    echo "  Run: bash ${SCRIPT_DIR}/k8s/deploy.sh --env local"
    echo
  fi
fi
