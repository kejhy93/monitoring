# Phone 5G router monitoring

Grafana dashboard for a phone (moto g 5G) used as a 5G router (hotspot / Ethernet tethering into an unmanaged TP-Link switch).
The switch is unmanaged, so all data comes from the phone itself (over ADB) plus internet probes from the monitoring host.

```
 5G ──► phone ──(Wi-Fi hotspot / USB-C Ethernet)──► TP-Link switch ──► devices
          ▲                                               │
          │ adb over TCP :5555                           │
   ┌──────┴───────── monitoring host (laptop now, Pi later) ┐
   │ phone-exporter :9200   blackbox :9116   [speedtest :9798] │
   │            └──────► Prometheus :9095 ──► Grafana :3030 │
   └────────────────────────────────────────────────────────┘
```

| Source | Metrics |
|---|---|
| `phone-exporter` (ADB) | 5G NR SS-RSRP/RSRQ/SINR, LTE RSRP/RSRQ/RSSI/SNR, network mode (LTE / 5G NSA / 5G SA), operator, aggregated carriers + bands + bandwidth, serving cell (PCI/band), per-interface traffic (cellular / Wi-Fi hotspot / Ethernet), tethered client count, battery level/temp/charging, thermal sensors (CPU/skin/modem), uptime |
| `blackbox` | ping RTT + loss to the phone (local hop) and 1.1.1.1 / 8.8.8.8 / 9.9.9.9, DNS lookup time, HTTP response time |
| `speedtest` (opt-in) | Ookla download/upload/ping every 6h |

## Setup

1. **Phone:** Settings → About phone → tap *Build number* 7× → Developer options → enable **USB debugging**.
   (Android "Wireless debugging" can't be used: it needs the phone to be a Wi-Fi *client*, and in hotspot mode it isn't.)
2. **Start the stack:** `./up.sh` (uses `podman compose` or `docker compose`).
3. **Authorise ADB once:** plug the phone in via USB and run `./phone-adb.sh setup`. Accept the prompt on the phone and tick *Always allow*.
   This switches adbd to TCP port 5555. Unplug the cable; the exporter connects over the network.
   **Repeat after every phone reboot.** The *Phone link (ADB)* panel turns red when needed.
4. Open Grafana at http://localhost:3030 (admin/admin). The *Phone 5G Router* dashboard is the home page.

Check the exporter directly: `curl -s localhost:9200/metrics | grep -v '^#'`

### Phone IP

`PHONE_ADB_TARGET=auto` (default) uses the host's default gateway, which is the phone. This matters because Android picks a random hotspot subnet whenever the hotspot restarts.
The exporter also writes that IP to `data/sd/gateway.json`, so the "phone (local hop)" ping follows it.
Override in `.env` (see `.env.example`) with `host:5555`, or `usb` when the phone is plugged in permanently.

### Speedtest

Disabled by default because every run uses a few hundred MB of mobile data (~1–2 GB/day at the 6h interval).
Enable with `./up.sh --profile speedtest`. Change the interval in `prometheus/prometheus.yml` (`job_name: speedtest`).

## Moving to the Raspberry Pi

Copy this folder (without `data/` if you want fresh keys), install Docker + compose plugin, and run `./up.sh`. The images are multi-arch (arm64).

- Set `PROMETHEUS_LISTEN=0.0.0.0:9095` in `.env` if other machines (e.g. the k8s Grafana) should query it.
- **Recommended:** if the phone's USB-C port is free (or you use a USB-C hub with power passthrough + Ethernet), plug the phone into the Pi permanently.
  Set `PHONE_ADB_TARGET=usb` and uncomment the `/dev/bus/usb` + `privileged` lines in `compose.yaml`. ADB then survives phone reboots and the phone stays charged.
  Add a udev rule so the container can open the device:
  `echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="22b8", MODE="0666"' | sudo tee /etc/udev/rules.d/51-android.rules && sudo udevadm control --reload`
- To keep historic data, copy the `prometheus-data` volume, or use remote_write to the main Prometheus.

## Files

| Path | What |
|---|---|
| `exporter/phone_exporter.py` | ADB → Prometheus exporter (one `adb shell` round-trip every 15s; parses `dumpsys telephony.registry`, `battery`, `thermalservice`, `/proc/net/dev`, `ip neigh`, `getprop`) |
| `prometheus/prometheus.yml` | Scrape jobs (phone, pings, DNS, HTTP, speedtest) |
| `blackbox/blackbox.yml` | Probe modules |
| `grafana/dashboards/phone-router.json` | Dashboard (provisioned) |
| `up.sh` / `phone-adb.sh` | Start stack / one-time ADB-over-TCP setup |

## Caveats

- Some values depend on the phone's Android version and modem vendor. Carrier aggregation info needs Android 12+. MediaTek modems may not report LTE SNR. Cell IDs/TAC are redacted (`***`) by Android, but PCI and band are not.
- `/proc/net/dev` counters reset when the phone reboots or the cellular interface is recreated. Prometheus `increase()`/`rate()` handle that.
- The phone keeps working as a router when the exporter is down. Only ADB TCP mode is lost on reboot.
