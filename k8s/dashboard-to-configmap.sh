#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"

usage() {
  echo "Usage: $0 <dashboard.json>"
  echo "  Creates a Kubernetes ConfigMap YAML from a Grafana dashboard JSON file."
  echo "  Output is written next to this script as <name>-dashboard.yaml"
  echo ""
  echo "  Example: $0 dashboards/plex.json  →  plex-dashboard.yaml"
  exit 1
}

[[ $# -ne 1 ]] && usage

INPUT="$1"
[[ ! -f "$INPUT" ]] && { echo "Error: file not found: $INPUT"; exit 1; }

BASENAME="$(basename "$INPUT" .json)"
OUTPUT="$SCRIPT_DIR/${BASENAME}-dashboard.yaml"

if ! command -v python3 &>/dev/null; then
  echo "Error: python3 is required to minify JSON"
  exit 1
fi

MINIFIED="$(python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1])), separators=(',',':')))" "$INPUT")"

cat > "$OUTPUT" << YAML
# Grafana dashboard ConfigMap — generated from $(basename "$INPUT") by $(basename "$0").
# Applied by deploy.sh — do not apply in isolation (namespace must exist first).
#
# The grafana-sc-dashboard sidecar watches ConfigMaps with grafana_dashboard=1
# and loads them automatically into Grafana without a pod restart.
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${BASENAME}-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  ${BASENAME}.json: |-
    ${MINIFIED}
YAML

echo "==> Written: $OUTPUT"
