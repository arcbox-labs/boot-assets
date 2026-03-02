#!/usr/bin/env bash
# build-alpine-initramfs.sh — Build a minimal Alpine-standard initramfs for ArcBox.
# chmod +x boot-assets/scripts/build-alpine-initramfs.sh
#
# Phase 0 of the boot-assets refactor: ext4 block device rootfs.
#
# This initramfs is intentionally minimal. Its only job is:
#   1. Mount /proc, /sys, /dev.
#   2. Mount /dev/vda (ext4 rootfs) at /newroot.
#   3. exec switch_root /newroot /sbin/init  → standard Alpine OpenRC.
#
# Everything else (VirtioFS shares, networking, cgroups, Docker, arcbox-agent)
# is handled by OpenRC services inside the rootfs.
set -euo pipefail

BASE_INITRAMFS=""
OUTPUT=""

usage() {
  cat <<'USAGE_EOF'
Usage: build-alpine-initramfs.sh [options]

Required options:
  --base-initramfs <path>  Path to base Alpine initramfs (provides busybox)
  --output <path>          Output initramfs path
USAGE_EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-initramfs)
      BASE_INITRAMFS="$2"
      shift 2
      ;;
    --output)
      OUTPUT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$BASE_INITRAMFS" || -z "$OUTPUT" ]]; then
  usage >&2
  exit 1
fi

for file in "$BASE_INITRAMFS"; do
  if [[ ! -f "$file" ]]; then
    echo "required file not found: $file" >&2
    exit 1
  fi
done

WORK_DIR="$(mktemp -d /tmp/arcbox-initramfs.XXXXXX)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Extract the Alpine base initramfs (provides /bin/busybox).
# ---------------------------------------------------------------------------
echo "extract base initramfs: $BASE_INITRAMFS"
(
  cd "$WORK_DIR"
  if ! gunzip -c "$BASE_INITRAMFS" | cpio -idm 2>/dev/null; then
    cpio -idm < "$BASE_INITRAMFS" 2>/dev/null
  fi
)

# ---------------------------------------------------------------------------
# Write the /init script.
# Minimal: mount virtio block device → switch_root to Alpine OpenRC.
# ---------------------------------------------------------------------------
cat > "$WORK_DIR/init" <<'INIT_EOF'
#!/bin/sh
# ArcBox initramfs init — mount ext4 rootfs from /dev/vda, switch_root to OpenRC.

/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev
/bin/busybox mkdir -p /dev/pts
/bin/busybox mount -t devpts devpts /dev/pts 2>/dev/null || true

# Wait for /dev/hvc0 and redirect console.
i=0
while [ "$i" -lt 20 ]; do
  [ -c /dev/hvc0 ] && break
  i=$((i + 1))
  /bin/busybox sleep 0.1
done
[ -c /dev/hvc0 ] && exec </dev/hvc0 >/dev/hvc0 2>&1

log() { echo "initramfs: $*"; }

# Wait for /dev/vda to appear (up to 2 seconds).
log "Waiting for /dev/vda..."
i=0
while [ "$i" -lt 20 ]; do
  [ -b /dev/vda ] && break
  i=$((i + 1))
  /bin/busybox sleep 0.1
done
if [ ! -b /dev/vda ]; then
  log "FATAL: /dev/vda not found after 2s"
  exec /bin/busybox sh
fi

# Mount ext4 rootfs.
log "Mounting /dev/vda as ext4..."
/bin/busybox mkdir -p /newroot
if ! /bin/busybox mount -t ext4 -o rw /dev/vda /newroot; then
  log "FATAL: cannot mount /dev/vda"
  exec /bin/busybox sh
fi

# Move already-mounted filesystems into the new root.
/bin/busybox mkdir -p /newroot/proc /newroot/sys /newroot/dev
/bin/busybox mount --move /proc /newroot/proc
/bin/busybox mount --move /sys  /newroot/sys
/bin/busybox mount --move /dev  /newroot/dev

# Pre-mount cgroup2 unified hierarchy so dockerd finds it immediately.
# OpenRC's cgroups service (sysinit) will detect this and skip re-mounting.
/bin/busybox mkdir -p /newroot/sys/fs/cgroup
/bin/busybox mount -t cgroup2 cgroup2 /newroot/sys/fs/cgroup 2>/dev/null || true

# Mount VirtioFS arcbox share early so we can read the host timestamp.
# The share is re-mounted by OpenRC's local service after switch_root.
/bin/busybox mkdir -p /newroot/arcbox
/bin/busybox mount -t virtiofs arcbox /newroot/arcbox 2>/dev/null || true

# Set system clock from host timestamp written to the VirtioFS share.
# Without this, the VM boots at epoch (1970) because ARM VMs have no RTC,
# causing TLS certificate validation failures in dockerd and chronyd.
if [ -f /newroot/arcbox/.host_time ]; then
  HOST_TS=$(/bin/busybox cat /newroot/arcbox/.host_time)
  if [ -n "$HOST_TS" ]; then
    # busybox date -s expects @epoch format
    /bin/busybox date -s "@${HOST_TS}" >/dev/null 2>&1 && \
      log "System clock set from host: $(/bin/busybox date -Iseconds)" || \
      log "WARNING: failed to set system clock from host"
  fi
fi

# Write fallback DNS resolvers so dockerd can resolve registries.
# DHCP may update this later, but dockerd needs DNS at startup.
if [ ! -f /newroot/etc/resolv.conf ] || ! /bin/busybox grep -q '^nameserver' /newroot/etc/resolv.conf 2>/dev/null; then
  echo 'nameserver 8.8.8.8' > /newroot/etc/resolv.conf
  echo 'nameserver 1.1.1.1' >> /newroot/etc/resolv.conf
fi

log "Switching root to /dev/vda (OpenRC)..."
exec /bin/busybox switch_root /newroot /sbin/init
INIT_EOF
chmod 755 "$WORK_DIR/init"

# ---------------------------------------------------------------------------
# Package the initramfs.
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$OUTPUT")"
(
  cd "$WORK_DIR"
  find . | cpio -o -H newc 2>/dev/null | gzip > "$OUTPUT"
)

echo "initramfs ready: $OUTPUT"
ls -lh "$OUTPUT"
