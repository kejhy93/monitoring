#!/usr/bin/env bash
set -euo pipefail

K8S_DIR="$(dirname "$0")"
ENV=""

usage() {
  echo "Usage: $0 --env local|prod"
  echo "  --env local  Deploy to minikube; access Grafana via port-forward"
  echo "  --env prod   Deploy to k3s with TLS ingress at https://hejnaluk.dev/grafana"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      if [[ $# -lt 2 ]]; then
        echo "Error: --env requires a value (local|prod)"
        usage
      fi
      ENV="$2"; shift 2 ;;
    *) usage ;;
  esac
done

case "$ENV" in
  local|prod) ;;
  *) echo "Error: --env local|prod is required"; usage ;;
esac

# k3s stores its kubeconfig outside the default location
if [[ "$ENV" == "prod" && -f /etc/rancher/k3s/k3s.yaml && -z "${KUBECONFIG:-}" ]]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

echo "==> Adding prometheus-community helm repo..."
if ! helm repo list | awk 'NR>1 {print $1}' | grep -qx "prometheus-community"; then
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
fi
helm repo update

echo "==> Installing kube-prometheus-stack..."
if [[ "$ENV" == "prod" ]]; then
  GRAFANA_ROOT_URL="https://hejnaluk.dev/grafana"
  SERVE_FROM_SUBPATH="true"
else
  GRAFANA_ROOT_URL="http://localhost:3000"
  SERVE_FROM_SUBPATH="false"
fi

helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --values "$K8S_DIR/prometheus-values.yaml" \
  --set "grafana.grafana\.ini.server.root_url=${GRAFANA_ROOT_URL}" \
  --set "grafana.grafana\.ini.server.serve_from_sub_path=${SERVE_FROM_SUBPATH}"

echo "==> Adding grafana helm repo..."
if ! helm repo list | awk 'NR>1 {print $1}' | grep -qx "grafana"; then
  helm repo add grafana https://grafana.github.io/helm-charts
fi
helm repo update

echo "==> Installing Loki..."
if [[ "$ENV" == "prod" ]]; then
  helm upgrade --install loki grafana/loki \
    --namespace monitoring \
    --set deploymentMode=SingleBinary \
    --set loki.auth_enabled=false \
    --set singleBinary.replicas=1 \
    --set read.replicas=0 \
    --set write.replicas=0 \
    --set backend.replicas=0 \
    --set loki.storage.type=filesystem \
    --set loki.commonConfig.replication_factor=1 \
    --set singleBinary.persistence.enabled=true \
    --set singleBinary.persistence.size=10Gi \
    --set loki.limits_config.retention_period=720h \
    --set loki.compactor.retention_enabled=true \
    --set loki.compactor.delete_request_store=filesystem \
    --set loki.schemaConfig.configs[0].from=2024-01-01 \
    --set loki.schemaConfig.configs[0].store=tsdb \
    --set loki.schemaConfig.configs[0].object_store=filesystem \
    --set loki.schemaConfig.configs[0].schema=v13 \
    --set loki.schemaConfig.configs[0].index.prefix=loki_ \
    --set loki.schemaConfig.configs[0].index.period=24h \
    --set chunksCache.enabled=false \
    --set resultsCache.enabled=false
else
  helm upgrade --install loki grafana/loki \
    --namespace monitoring \
    --set deploymentMode=SingleBinary \
    --set loki.auth_enabled=false \
    --set singleBinary.replicas=1 \
    --set read.replicas=0 \
    --set write.replicas=0 \
    --set backend.replicas=0 \
    --set loki.storage.type=filesystem \
    --set loki.commonConfig.replication_factor=1 \
    --set singleBinary.persistence.enabled=false \
    --set loki.useTestSchema=true \
    --set chunksCache.enabled=false \
    --set resultsCache.enabled=false \
    --set-json 'singleBinary.extraVolumes=[{"name":"loki-data","emptyDir":{}}]' \
    --set-json 'singleBinary.extraVolumeMounts=[{"name":"loki-data","mountPath":"/var/loki"}]'
fi

echo "==> Installing Promtail..."
helm upgrade --install promtail grafana/promtail \
  --namespace monitoring \
  --set config.clients[0].url=http://loki:3100/loki/api/v1/push

echo "==> Waiting for monitoring pods to be ready..."
kubectl --namespace monitoring wait --for=condition=ready pod \
  -l "release=prometheus" \
  --timeout=120s

echo "==> Generating Grafana dashboard ConfigMaps from JSON sources..."
bash "$K8S_DIR/dashboard-to-configmap.sh" "$K8S_DIR/dashboards/plex.json"
bash "$K8S_DIR/dashboard-to-configmap.sh" "$K8S_DIR/dashboards/metro-timetable.json"

echo "==> Applying Grafana dashboards..."
kubectl apply -f "$K8S_DIR/plex-dashboard.yaml"
kubectl apply -f "$K8S_DIR/metro-timetable-dashboard.yaml"

echo "==> Restarting Grafana to pick up updated ConfigMaps..."
kubectl rollout restart deployment/prometheus-grafana -n monitoring
kubectl rollout status deployment/prometheus-grafana -n monitoring --timeout=120s

if [[ "$ENV" == "prod" ]]; then
  echo "==> Applying Grafana Ingress..."
  kubectl apply -f "$K8S_DIR/grafana-ingress.yaml"
fi

echo ""
echo "==> Done."
echo ""
echo "    Each project should apply its own ServiceMonitor pointing to this stack."
echo "    Example: kubectl apply -f <project>/k8s/base/servicemonitor.yaml"
echo ""
echo "==> Access the UIs with:"
echo "    Prometheus: kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090"
if [[ "$ENV" == "prod" ]]; then
  echo "    Grafana:    https://hejnaluk.dev/grafana"
  echo "    Grafana login: admin / admin"
else
  echo "    Grafana login: admin / admin"
  echo ""
  echo "==> Port-forwarding Grafana on http://localhost:3000 (Ctrl+C to stop)..."
  until kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80; do
    echo "    Port-forward lost, retrying in 2s..."
    sleep 2
  done
fi
