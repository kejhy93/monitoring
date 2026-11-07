#!/usr/bin/env bash
# Start (or update) the stack. Extra args are passed to compose before `up`,
# e.g. ./up.sh --profile speedtest
set -euo pipefail
cd "$(dirname "$0")"

if command -v podman >/dev/null && podman compose version >/dev/null 2>&1; then
  COMPOSE=(podman compose)
elif docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
else
  echo "Need 'podman compose' or 'docker compose'" >&2; exit 1
fi

mkdir -p data/adb data/sd
[ -s data/sd/gateway.json ] || echo '[]' > data/sd/gateway.json

"${COMPOSE[@]}" "$@" up -d --build
echo
echo "Grafana:    http://localhost:${GRAFANA_PORT:-3030}  (admin / ${GRAFANA_PASSWORD:-admin})"
echo "Exporter:   curl -s localhost:9200/metrics | grep -v '^#'"
