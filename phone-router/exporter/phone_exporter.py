#!/usr/bin/env python3
"""Prometheus exporter for an Android phone used as a 5G hotspot/router.

Talks to the phone over ADB (USB or `adb tcpip`), runs a handful of dumpsys /
procfs commands in a single shell round-trip and exposes the parsed values on
/metrics. Collection happens in a background loop so scrapes are instant.

Env:
  PHONE_ADB_TARGET   host:port, "auto" (default gateway:5555) or "usb"
  COLLECT_INTERVAL   seconds between collections (default 15)
  LISTEN_ADDR        default 127.0.0.1
  LISTEN_PORT        default 9200
  SD_FILE            optional path; the detected phone IP is written there as a
                     Prometheus file_sd target list (used for the gateway ping)
"""

import json
import os
import re
import socket
import struct
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TARGET = os.environ.get("PHONE_ADB_TARGET", "auto")
INTERVAL = float(os.environ.get("COLLECT_INTERVAL", "15"))
LISTEN_ADDR = os.environ.get("LISTEN_ADDR", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9200"))
SD_FILE = os.environ.get("SD_FILE", "")

UNAVAILABLE = {2147483647, -2147483648, 0x7FFFFFFF}
CELLULAR_IF = re.compile(r"^(rmnet|ccmni|seth|v4-rmnet|wwan)")
IGNORED_IF = re.compile(r"^(lo|dummy|sit|ip6tnl|ip_vti|ip6_vti|tunl|gre|erspan|ifb|p2p|bond|r_rmnet|rmnet_ipa|rmnet_mhi)")
THERMAL_TYPES = {
    -1: "unknown", 0: "cpu", 1: "gpu", 2: "battery", 3: "skin", 4: "usb_port",
    5: "power_amplifier", 9: "npu", 10: "tpu", 11: "display", 12: "modem", 13: "soc",
}
BATTERY_STATUS = {1: "unknown", 2: "charging", 3: "discharging", 4: "not_charging", 5: "full"}

SHELL_SCRIPT = "; ".join([
    "echo @@telephony", "dumpsys telephony.registry",
    "echo @@battery", "dumpsys battery",
    "echo @@netdev", "cat /proc/net/dev",
    "echo @@thermal", "dumpsys thermalservice",
    "echo @@uptime", "cat /proc/uptime",
    "echo @@neigh", "ip neigh 2>/dev/null",
    "echo @@props", "getprop",
])


# ---------------------------------------------------------------- metrics model

class Metrics:
    def __init__(self):
        self._families = {}  # name -> (type, help, [(labels, value)])

    def add(self, name, value, labels=None, help_="", type_="gauge"):
        if value is None:
            return
        fam = self._families.setdefault(name, (type_, help_, []))
        fam[2].append((labels or {}, float(value)))

    def render(self):
        out = []
        for name, (type_, help_, samples) in self._families.items():
            if help_:
                out.append(f"# HELP {name} {help_}")
            out.append(f"# TYPE {name} {type_}")
            for labels, value in samples:
                if labels:
                    lbl = ",".join(f'{k}="{_esc(v)}"' for k, v in labels.items())
                    out.append(f"{name}{{{lbl}}} {_fmt(value)}")
                else:
                    out.append(f"{name} {_fmt(value)}")
        return "\n".join(out) + "\n"


def _esc(v):
    return str(v).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def _fmt(v):
    return str(int(v)) if v.is_integer() and abs(v) < 1e15 else repr(v)


def _int(s):
    try:
        v = int(s)
    except (TypeError, ValueError):
        return None
    return None if v in UNAVAILABLE else v


# ---------------------------------------------------------------- adb plumbing

def default_gateway():
    try:
        with open("/proc/net/route") as f:
            for line in f.readlines()[1:]:
                fields = line.split()
                if fields[1] == "00000000" and int(fields[3], 16) & 2:
                    return socket.inet_ntoa(struct.pack("<L", int(fields[2], 16)))
    except OSError:
        pass
    return None


def resolve_target():
    if TARGET == "usb":
        return None
    if TARGET == "auto":
        gw = default_gateway()
        return f"{gw}:5555" if gw else None
    return TARGET


def adb(*args, serial=None, timeout=20):
    cmd = ["adb"] + (["-s", serial] if serial else []) + list(args)
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def ensure_connected(target):
    """Return the serial to use, or None if the phone is unreachable."""
    devices = adb("devices").stdout
    online = [l.split()[0] for l in devices.splitlines()[1:] if l.strip().endswith("\tdevice")]
    if target is None:
        usb = [d for d in online if ":" not in d]
        return usb[0] if usb else None
    if target in online:
        return target
    # stale "offline" entries block reconnects
    adb("disconnect", target, timeout=5)
    adb("connect", target, timeout=10)
    online = [l.split()[0] for l in adb("devices").stdout.splitlines()[1:] if l.strip().endswith("\tdevice")]
    return target if target in online else None


def split_sections(text):
    sections, current = {}, None
    for line in text.splitlines():
        if line.startswith("@@"):
            current = line[2:].strip()
            sections[current] = []
        elif current:
            sections[current].append(line)
    return {k: "\n".join(v) for k, v in sections.items()}


# ---------------------------------------------------------------- parsers

def phone_blocks(text):
    """Yield (phone_id, block_text) for each 'Phone Id=N' block of telephony.registry."""
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m = re.match(r"^(\s*)Phone Id=(\d+)", lines[i])
        if not m:
            i += 1
            continue
        indent, pid = len(m.group(1)), m.group(2)
        body = []
        i += 1
        while i < len(lines) and (not lines[i].strip() or len(lines[i]) - len(lines[i].lstrip()) > indent):
            body.append(lines[i])
            i += 1
        yield pid, "\n".join(body)


def kv_pairs(s):
    """Parse 'a=1 b = -2, c=3' style into {a: '1', b: '-2', c: '3'}."""
    return {k: v for k, v in re.findall(r"(\w+)\s*=\s*([^\s,}\]]+)", s)}


def field(block, name):
    m = re.search(rf"^\s*{name}=(.*)$", block, re.M)
    return m.group(1).strip() if m else None


def parse_telephony(text, m):
    blocks = list(phone_blocks(text))
    if not blocks:
        return
    # Prefer the SIM slot that currently carries mobile data.
    active = next((b for b in blocks if field(b[1], "mDataConnectionState") == "2"), blocks[0])
    slot, block = active
    base = {"slot": slot}

    m.add("phone_data_connection_state", _int(field(block, "mDataConnectionState")), base,
          "Mobile data connection state (0=disconnected,1=connecting,2=connected,3=suspended)")

    ss = field(block, "mSignalStrength") or ""
    lte = re.search(r"CellSignalStrengthLte:(.*?)(?:mNr=|primary=|$)", ss)
    if lte:
        kv = kv_pairs(lte.group(1))
        m.add("phone_lte_rsrp_dbm", _int(kv.get("rsrp")), base, "LTE reference signal received power")
        m.add("phone_lte_rsrq_db", _int(kv.get("rsrq")), base, "LTE reference signal received quality")
        m.add("phone_lte_rssi_dbm", _int(kv.get("rssi")), base, "LTE received signal strength indicator")
        m.add("phone_lte_snr_db", _int(kv.get("rssnr")), base, "LTE reference signal SNR")
        m.add("phone_lte_cqi", _int(kv.get("cqi")), base, "LTE channel quality indicator")
        m.add("phone_signal_level", _int(kv.get("level")), {**base, "rat": "lte"}, "Android signal bars 0-4")
    nr = re.search(r"CellSignalStrengthNr:\{(.*?)\}", ss)
    if nr:
        kv = kv_pairs(nr.group(1))
        m.add("phone_nr_ss_rsrp_dbm", _int(kv.get("ssRsrp")), base, "5G NR SS reference signal received power")
        m.add("phone_nr_ss_rsrq_db", _int(kv.get("ssRsrq")), base, "5G NR SS reference signal received quality")
        m.add("phone_nr_ss_sinr_db", _int(kv.get("ssSinr")), base, "5G NR SS signal to interference+noise ratio")
        m.add("phone_nr_csi_rsrp_dbm", _int(kv.get("csiRsrp")), base, "5G NR CSI reference signal received power")
        m.add("phone_nr_csi_sinr_db", _int(kv.get("csiSinr")), base, "5G NR CSI SINR")
        m.add("phone_signal_level", _int(kv.get("level")), {**base, "rat": "nr"}, "Android signal bars 0-4")

    disp = field(block, "mTelephonyDisplayInfo") or ""
    dkv = kv_pairs(disp)
    sstate = field(block, "mServiceState") or ""
    operator = re.search(r"mOperatorAlphaLong=([^,]*)", sstate)
    rat = re.search(r"getRilDataRadioTechnology=\d+\((\w+)\)", sstate)
    network = dkv.get("network") or (rat.group(1) if rat else "unknown")
    override = dkv.get("overrideNetwork", "NONE")
    display = {"NR_NSA": "5G NSA", "NR_NSA_MMWAVE": "5G mmWave", "NR_ADVANCED": "5G+",
               "LTE_CA": "LTE+", "LTE_ADVANCED_PRO": "LTE-A Pro"}.get(override)
    if not display:
        display = {"NR": "5G SA", "LTE": "LTE", "HSPAP": "3G", "UMTS": "3G", "EDGE": "2G"}.get(network, network)
    m.add("phone_network_info", 1, {**base, "network": network, "override": override, "display": display,
          "operator": operator.group(1).strip() if operator else "",
          "roaming": dkv.get("isRoaming", "false")},
          "Current radio access technology as shown in the status bar")

    configs = re.findall(r"\{(mConnectionStatus=[^}]*)\}", field(block, "mPhysicalChannelConfigs") or "")
    for idx, cfg in enumerate(configs):
        kv = kv_pairs(cfg)
        labels = {**base, "index": str(idx), "status": kv.get("mConnectionStatus", ""),
                  "rat": kv.get("mNetworkType", ""), "band": kv.get("mBand", ""),
                  "pci": kv.get("mPhysicalCellId", "")}
        m.add("phone_carrier_downlink_bandwidth_khz", _int(kv.get("mCellBandwidthDownlinkKhz")), labels,
              "Bandwidth of each aggregated carrier (one series per component carrier)")
    if configs:
        m.add("phone_carrier_count", len(configs), base, "Number of aggregated component carriers")

    ci = field(block, "mCellIdentity") or ""
    cm = re.match(r"CellIdentity(\w+):\{(.*)\}", ci)
    if cm:
        kv = kv_pairs(cm.group(2))
        bands = re.search(r"mBands\s*=\s*\[([^\]]*)\]", cm.group(2))
        m.add("phone_cell_info", 1, {**base, "rat": cm.group(1).lower(),
              "pci": kv.get("mPci", ""), "tac": kv.get("mTac", ""),
              "cell_id": kv.get("mCi") or kv.get("mNci", ""),
              "arfcn": kv.get("mEarfcn") or kv.get("mNrArfcn", ""),
              "band": bands.group(1).replace(" ", "") if bands else ""},
              "Serving cell identity (changes on handover)")


def parse_battery(text, m):
    kv = dict(re.findall(r"^\s*([\w ]+):\s*(\S+)\s*$", text, re.M))
    m.add("phone_battery_level_percent", _int(kv.get("level")), help_="Battery charge level")
    t = _int(kv.get("temperature"))
    m.add("phone_battery_temperature_celsius", t / 10 if t is not None else None, help_="Battery temperature")
    v = _int(kv.get("voltage"))
    m.add("phone_battery_voltage_volts", v / 1000 if v is not None else None, help_="Battery voltage")
    status = _int(kv.get("status"))
    if status is not None:
        m.add("phone_battery_status", 1, {"status": BATTERY_STATUS.get(status, str(status))}, "Battery charging status")
    for src, key in (("ac", "AC powered"), ("usb", "USB powered"), ("wireless", "Wireless powered")):
        if key in kv:
            m.add("phone_battery_powered", 1 if kv[key] == "true" else 0, {"source": src}, "Charger connected")


def parse_netdev(text, m):
    for line in text.splitlines():
        if ":" not in line or "|" in line:
            continue
        iface, data = line.split(":", 1)
        iface = iface.strip()
        if IGNORED_IF.match(iface):
            continue
        f = data.split()
        if len(f) < 16:
            continue
        rx, tx = int(f[0]), int(f[8])
        if rx == 0 and tx == 0:
            continue
        kind = "cellular" if CELLULAR_IF.match(iface) else \
               "usb" if re.match(r"^(rndis|ncm|usb)", iface) else \
               "ethernet" if iface.startswith("eth") else \
               "wifi" if re.match(r"^(wlan|swlan|ap|softap)", iface) else "other"
        labels = {"interface": iface, "kind": kind}
        m.add("phone_net_receive_bytes_total", rx, labels, "Bytes received by the phone per interface", "counter")
        m.add("phone_net_transmit_bytes_total", tx, labels, "Bytes transmitted by the phone per interface", "counter")
        m.add("phone_net_receive_errors_total", int(f[2]), labels, "Receive errors", "counter")
        m.add("phone_net_receive_drops_total", int(f[3]), labels, "Receive drops", "counter")


def parse_thermal(text, m):
    temps = {}
    for v, t, name in re.findall(r"Temperature\{mValue=([-\d.]+), mType=(-?\d+), mName=([^,]+),", text):
        t = int(t)
        if t in THERMAL_TYPES:
            temps[name] = (float(v), THERMAL_TYPES[t])
    for name, (v, t) in temps.items():
        if -40 < v < 150:
            m.add("phone_thermal_celsius", v, {"sensor": name, "type": t}, "Thermal HAL sensor temperatures")
    status = re.search(r"Thermal Status:\s*(\d+)", text)
    if status:
        m.add("phone_thermal_status", int(status.group(1)), help_="Thermal throttling status (0=none .. 6=shutdown)")


def parse_neigh(text, m, cellular_ifaces):
    clients = {}
    for line in text.splitlines():
        p = line.split()
        if "dev" not in p or "lladdr" not in p or p[-1] in ("FAILED", "INCOMPLETE"):
            continue
        iface = p[p.index("dev") + 1]
        if CELLULAR_IF.match(iface) or iface in cellular_ifaces:
            continue
        clients.setdefault(iface, set()).add(p[p.index("lladdr") + 1])
    for iface, macs in clients.items():
        m.add("phone_tether_clients", len(macs), {"interface": iface},
              "Devices seen in the neighbour table per tethering interface")


def parse_props(text, m):
    props = dict(re.findall(r"^\[([^\]]+)\]: \[([^\]]*)\]", text, re.M))
    m.add("phone_info", 1, {
        "model": props.get("ro.product.model", ""),
        "manufacturer": props.get("ro.product.manufacturer", ""),
        "android": props.get("ro.build.version.release", ""),
        "network_type_prop": props.get("gsm.network.type", ""),
        "sim_operator": props.get("gsm.sim.operator.alpha", ""),
    }, "Static phone information")


# ---------------------------------------------------------------- collector

class Collector:
    def __init__(self):
        self.text = "# no data collected yet\n"
        self.lock = threading.Lock()

    def collect_once(self):
        m = Metrics()
        start = time.time()
        target = resolve_target()
        if target and SD_FILE:
            write_sd(target.split(":")[0])
        serial = None
        try:
            serial = ensure_connected(target)
            if serial:
                res = adb("shell", SHELL_SCRIPT, serial=serial, timeout=30)
                if res.returncode != 0 and "@@telephony" not in res.stdout:
                    raise RuntimeError(res.stderr.strip() or "adb shell failed")
                sec = split_sections(res.stdout)
                for name, fn in (("telephony", parse_telephony), ("battery", parse_battery),
                                 ("netdev", parse_netdev), ("thermal", parse_thermal), ("props", parse_props)):
                    try:
                        fn(sec.get(name, ""), m)
                    except Exception as e:  # one broken section must not hide the rest
                        m.add("phone_parse_errors", 1, {"section": name}, "Sections that failed to parse")
                        print(f"parse error in {name}: {e!r}", flush=True)
                cell_ifaces = {l["interface"] for l, _ in m._families.get("phone_net_receive_bytes_total", ("", "", []))[2]
                               if l["kind"] == "cellular"}
                parse_neigh(sec.get("neigh", ""), m, cell_ifaces)
                up = sec.get("uptime", "").split()
                if up:
                    m.add("phone_uptime_seconds", float(up[0]), help_="Seconds since the phone booted")
        except Exception as e:
            print(f"collection failed: {e!r}", flush=True)
            serial = None
        m.add("phone_adb_up", 1 if serial else 0, {"target": target or "usb"},
              "1 if the phone answered over ADB during the last collection")
        m.add("phone_collect_duration_seconds", time.time() - start, help_="Time spent collecting")
        with self.lock:
            self.text = m.render()

    def loop(self):
        adb("start-server", timeout=30)
        while True:
            self.collect_once()
            time.sleep(INTERVAL)


def write_sd(ip):
    data = [{"targets": [ip], "labels": {"target_name": "phone"}}]
    tmp = SD_FILE + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, SD_FILE)
    except OSError as e:
        print(f"cannot write {SD_FILE}: {e}", flush=True)


collector = Collector()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/metrics"):
            with collector.lock:
                body = collector.text.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
        else:
            body = b"phone exporter - see /metrics\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    threading.Thread(target=collector.loop, daemon=True).start()
    print(f"phone exporter on {LISTEN_ADDR}:{LISTEN_PORT}, target={TARGET}", flush=True)
    ThreadingHTTPServer((LISTEN_ADDR, LISTEN_PORT), Handler).serve_forever()
