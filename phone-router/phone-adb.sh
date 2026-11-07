#!/usr/bin/env bash
# Run adb against the phone over USB using the same key the exporter uses.
#
#   ./phone-adb.sh setup     # one-time (and after every phone reboot):
#                            # plug phone in via USB, accept the prompt, enables adb over TCP 5555
#   ./phone-adb.sh devices   # any other adb command
set -euo pipefail
cd "$(dirname "$0")"
ENGINE=$(command -v podman || command -v docker)
IMAGE=localhost/phone-exporter:latest
mkdir -p data/adb

"$ENGINE" image exists "$IMAGE" 2>/dev/null || "$ENGINE" build -t "$IMAGE" exporter

# Find Android devices (Motorola 22b8 and other common vendors) and make sure
# we can open their USB node; rootless containers inherit host permissions.
for dev in /sys/bus/usb/devices/*; do
  [ -f "$dev/idVendor" ] || continue
  case "$(cat "$dev/idVendor")" in 22b8|18d1|04e8|2717|05c6|0e8d) ;; *) continue ;; esac
  node=$(printf '/dev/bus/usb/%03d/%03d' "$(cat "$dev/busnum")" "$(cat "$dev/devnum")")
  if [ ! -w "$node" ]; then
    echo "Granting $USER access to $node ($(cat "$dev/product" 2>/dev/null || echo phone)) - needs sudo"
    sudo setfacl -m "u:$(id -u):rw" "$node"
  fi
done

adb() {
  "$ENGINE" run --rm -i --privileged --entrypoint adb \
    -v /dev/bus/usb:/dev/bus/usb \
    -v "$PWD/data/adb:/root/.android:z" \
    "$IMAGE" "$@"
}

if [ "${1:-}" = "setup" ]; then
  echo "Waiting for the phone on USB. Unlock it and tap 'Allow' (tick 'Always allow from this computer')..."
  "$ENGINE" run --rm -i --privileged --entrypoint sh \
    -v /dev/bus/usb:/dev/bus/usb -v "$PWD/data/adb:/root/.android:z" "$IMAGE" -c '
      adb start-server >/dev/null 2>&1
      timeout 120 adb wait-for-usb-device || { echo "No authorised phone found"; adb devices -l; exit 1; }
      adb devices -l
      echo "Model: $(adb shell getprop ro.product.model)  Android $(adb shell getprop ro.build.version.release)"
      adb tcpip 5555
      echo "Done. You can unplug the cable; the exporter will connect over the network."
      echo "(Repeat after every phone reboot.)"'
else
  adb "$@"
fi
