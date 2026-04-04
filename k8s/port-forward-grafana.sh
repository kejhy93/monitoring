#!/usr/bin/env bash
set -euo pipefail

LOCAL_PORT="${1:-3001}"

echo "==> Port-forwarding Grafana on http://localhost:${LOCAL_PORT}"
echo "    Login: admin / admin"
echo "    Press Ctrl+C to stop."
echo ""

kubectl port-forward -n monitoring svc/prometheus-grafana "${LOCAL_PORT}:80"
