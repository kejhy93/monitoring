# Monitoring

Prometheus + Grafana deployed in minikube (kube-prometheus-stack Helm chart), Plex running in a Podman pod on the host.

## Stack

| Component | Where | How |
|---|---|---|
| Prometheus | minikube, `monitoring` namespace | kube-prometheus-stack Helm chart |
| Grafana | minikube, `monitoring` namespace | bundled with kube-prometheus-stack |
| Plex | Podman pod `plexpod` | `start-plex-exporter.sh` (GPU passthrough via `GPU_TYPE`) |
| plex-exporter | Podman pod `plexpod` (sidecar) | `ghcr.io/jsclayton/prometheus-plex-exporter` |
| Seagate (media) | Host at `/var/mnt/seagate` | `fix-seagate-mount.sh` (NTFS, mounted into Plex at `/seagate`) |
| Plex | Podman pod `plexpod` | `start-plex-exporter.sh` |
| plex-exporter | Podman pod `plexpod` (sidecar) | `ghcr.io/jsclayton/prometheus-plex-exporter` |
| Seagate (media) | Host at `/var/mnt/seagate` | `fix-seagate-mount.sh` (NTFS, mounted into Plex at `/seagate`) |

## Accessing UIs

```bash
# Grafana (local)
bash k8s/port-forward-grafana.sh
# then open http://localhost:3000  login: admin / admin

# Prometheus
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090

# plex-exporter raw metrics
curl http://localhost:9000/metrics
```

## Deploying / redeploying

```bash
bash k8s/deploy.sh --env local   # minikube
bash k8s/deploy.sh --env prod    # k3s at hejnaluk.dev/grafana
```

`deploy.sh` runs in order:
1. Adds prometheus-community Helm repo and installs kube-prometheus-stack (using `k8s/prometheus-values.yaml`)
2. Waits for pods to be ready
3. Applies `k8s/plex-dashboard.yaml` (Grafana dashboard ConfigMap)
4. Applies `k8s/grafana-ingress.yaml` (prod only)
5. For `--env local`: automatically starts `kubectl port-forward` on `http://localhost:3000` (loops on disconnect)

## Helper scripts

### `start-plex-exporter.sh`

Starts the `plexpod` Podman pod (Plex + plex-exporter). Idempotent — skips creation of any pod or container that already exists.

```bash
bash start-plex-exporter.sh
```

GPU passthrough is controlled by `GPU_TYPE` (default: `vaapi`):

```bash
GPU_TYPE=vaapi   bash start-plex-exporter.sh   # Intel/AMD via /dev/dri
GPU_TYPE=nvidia  bash start-plex-exporter.sh   # NVIDIA devices
GPU_TYPE=none    bash start-plex-exporter.sh   # no GPU
```

The Seagate external drive is mounted into the Plex container at `/seagate` (host path: `/var/mnt/seagate`).

After starting the pod, the script optionally starts minikube and checks that Prometheus and Grafana pods are ready. This is on by default; disable with:

```bash
START_MINIKUBE=false bash start-plex-exporter.sh
```

### `start-minikube.sh`

Starts minikube with the Podman driver and containerd runtime. If the normal start fails, it automatically recovers by deleting the broken profile, removing orphaned Podman volumes, and starting fresh.

```bash
bash start-minikube.sh
```

### `fix-seagate-mount.sh`

Fixes a dirty/stale NTFS Seagate mount and restarts Plex so it picks up the volume.

```bash
bash fix-seagate-mount.sh
```

Defaults: `MOUNT_POINT=/var/mnt/seagate`, `UUID=A260323360320E93`, `PLEX_CONTAINER=plex`. Override any via environment variables.

Steps: lazy-unmounts stale mount → `ntfsfix` → systemd remount → restart/start the Plex container.
=======
1. Adds prometheus-community Helm repo and installs kube-prometheus-stack
2. Waits for pods to be ready
3. Applies `k8s/plex-dashboard.yaml` (Grafana dashboard ConfigMap)
4. Applies `k8s/grafana-ingress.yaml` (prod only)
5. For `--env local`: automatically starts `kubectl port-forward` on `http://localhost:3000` (loops on disconnect)

## Helper scripts

### `start-plex-exporter.sh`

Starts the `plexpod` Podman pod (Plex + plex-exporter). Idempotent — skips creation of any pod or container that already exists.

```bash
bash start-plex-exporter.sh
```

GPU passthrough is controlled by `GPU_TYPE` (default: `vaapi`):

```bash
GPU_TYPE=vaapi   bash start-plex-exporter.sh   # Intel/AMD via /dev/dri
GPU_TYPE=nvidia  bash start-plex-exporter.sh   # NVIDIA devices
GPU_TYPE=none    bash start-plex-exporter.sh   # no GPU
```

The Seagate external drive is mounted into the Plex container at `/seagate` (host path: `/var/mnt/seagate`).

After starting the pod, the script optionally starts minikube and checks that Prometheus and Grafana pods are ready. This is on by default; disable with:

```bash
START_MINIKUBE=false bash start-plex-exporter.sh
```

### `start-minikube.sh`

Starts minikube with the Podman driver and containerd runtime. If the normal start fails, it automatically recovers by deleting the broken profile, removing orphaned Podman volumes, and starting fresh.

```bash
bash start-minikube.sh
```

### `fix-seagate-mount.sh`

Fixes a dirty/stale NTFS Seagate mount and restarts Plex so it picks up the volume.

```bash
bash fix-seagate-mount.sh
```

Defaults: `MOUNT_POINT=/var/mnt/seagate`, `UUID=A260323360320E93`, `PLEX_CONTAINER=plex`. Override any via environment variables.

Steps: lazy-unmounts stale mount → `ntfsfix` → systemd remount → restart/start the Plex container.

## Plex scrape config

Prometheus scrapes the plex-exporter via an additional scrape config secret:

```bash
kubectl apply -f k8s/plex-scrape.yaml
kubectl patch prometheus prometheus-kube-prometheus-prometheus -n monitoring \
  --type=merge -p '{"spec":{"additionalScrapeConfigs":{"name":"plex-additional-scrape","key":"scrape.yaml"}}}'
```

Target: `169.254.1.2:9000` — this is `host.containers.internal`, the Podman gateway inside minikube.
To re-resolve: `minikube ssh "getent hosts host.containers.internal"`

## Plex exporter metrics

The exporter (`jsclayton/prometheus-plex-exporter`) exposes these Plex-specific metrics:

| Metric | Type | Description |
|---|---|---|
| `server_info` | gauge | Always 1; labels carry `version`, `platform`, `platform_version` |
| `library_storage_total` | gauge | Library size in bytes; labels: `library`, `library_type` |
| `library_duration_total` | gauge | Total content duration in ms; labels: `library`, `library_type` |
| `estimated_transmit_bytes_total` | counter | Bytes streamed out |
| `plays_total` | counter | One series per active session; labels: `title`, `child_title`, `user`, `stream_type`, `stream_resolution`, `stream_bitrate`, `media_type`, `device_type`, `session` |
| `play_seconds_total` | counter | Seconds watched per session; same labels as `plays_total` |

**Important:** There is no `session_count` metric. Active session counts are derived as:
- Total streams: `count(plays_total{job="plex"})`
- By stream type: `count(plays_total{job="plex", stream_type="directplay|transcode|directstream"})`

`stream_type` label values are lowercase: `directplay`, `transcode`, `directstream` (not camelCase).

## Plex Grafana dashboard

Source: `k8s/dashboards/plex.json`
Deployed as: ConfigMap `plex-dashboard` in `monitoring` namespace with label `grafana_dashboard=1`

The Grafana sidecar (`grafana-sc-dashboard`) watches for ConfigMaps with this label and loads them automatically. After `kubectl apply`, the dashboard appears within ~60s without restarting Grafana.

To update the dashboard after editing `plex.json`, regenerate the ConfigMap YAML and apply:

```bash
python3 - <<'EOF'
import json
with open('k8s/dashboards/plex.json') as f:
    data = json.load(f)
compact = json.dumps(data, separators=(',', ':'))
yaml_content = f"""apiVersion: v1
kind: ConfigMap
metadata:
  name: plex-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  plex.json: |-
    {compact}
"""
with open('k8s/plex-dashboard.yaml', 'w') as f:
    f.write(yaml_content)
EOF
kubectl apply -f k8s/plex-dashboard.yaml
```

### Dashboard panels

**Server row**
- Plex Status (UP/DOWN from `server_info`)
- Plex Version (from `server_info` labels)
- Total Library Storage (`sum(library_storage_total)`)
- Total Content Duration (`sum(library_duration_total)`)

**Active Sessions row**
- Total / Transcode / Direct Play / Direct Stream stream counts
- Active Sessions over Time — stacked timeseries by stream type
- Sessions by Media Type — timeseries
- Now Playing — table with Title, Episode, User, Type, Stream, Resolution, Bitrate, Device, Watched
  - Uses `play_seconds_total` as base query; "Watched" column is current session elapsed time in seconds

**Watch History row**
- Watch Activity — `rate(play_seconds_total[2m])` per title+user; ~1.0 = playing, ~0 = paused/stopped
- Watch Time by User — `sum by(user)(increase(play_seconds_total[$__range]))`; respects dashboard time range

**Libraries row**
- Library Storage bar gauge (`library_storage_total` per library)
- Library Content Duration bar gauge (`library_duration_total` per library)

**Bandwidth row**
- Estimated Transmit Bandwidth — `rate(estimated_transmit_bytes_total[2m])`

### Known issue: sidecar 401 on reload

The sidecar logs a `401 Unauthorized` when calling Grafana's `/api/admin/provisioning/dashboards/reload`. This is a credential mismatch between the sidecar and Grafana's auth. The dashboard file is still written to disk and picked up from the provisioned directory — the dashboard works despite the error. If it doesn't appear, restart Grafana:

```bash
kubectl rollout restart deployment prometheus-grafana -n monitoring
```
