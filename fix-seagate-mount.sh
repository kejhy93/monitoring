#!/usr/bin/env bash
set -e

MOUNT_POINT="/var/mnt/seagate"
UUID="A260323360320E93"
PLEX_CONTAINER="plex"

echo "=== Fixing Seagate mount ==="

# Find the device by UUID
DEVICE=$(blkid -U "$UUID" 2>/dev/null || true)

if [ -z "$DEVICE" ]; then
  echo "ERROR: Seagate disk not found (UUID $UUID). Is it plugged in?"
  exit 1
fi

echo "Found device: $DEVICE"

# Lazy unmount if stale mount exists
if mountpoint -q "$MOUNT_POINT" 2>/dev/null || grep -q "$MOUNT_POINT" /proc/mounts 2>/dev/null; then
  echo "Unmounting stale mount at $MOUNT_POINT..."
  sudo umount -l "$MOUNT_POINT"
fi

# Fix dirty NTFS volume
echo "Running ntfsfix on $DEVICE..."
sudo ntfsfix "$DEVICE"

# Reload systemd and mount
echo "Reloading systemd and mounting..."
sudo systemctl daemon-reload
sudo systemctl start var-mnt-seagate.mount

# Verify mount
if ! mountpoint -q "$MOUNT_POINT"; then
  echo "ERROR: Mount failed. Check: journalctl -u var-mnt-seagate.mount"
  exit 1
fi

echo "✓ Seagate mounted at $MOUNT_POINT"

# Restart Plex so it picks up the newly mounted volume
if podman ps --format '{{.Names}}' | grep -wq "$PLEX_CONTAINER"; then
  echo "Restarting Plex container to pick up new mount..."
  podman restart "$PLEX_CONTAINER"
  echo "✓ Plex restarted"
elif podman ps -a --format '{{.Names}}' | grep -wq "$PLEX_CONTAINER"; then
  echo "Starting stopped Plex container..."
  podman start "$PLEX_CONTAINER"
  echo "✓ Plex started"
else
  echo "Plex container not found — start it manually with start-plex-exporter.sh"
fi
