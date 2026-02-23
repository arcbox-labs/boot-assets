#!/usr/bin/env bash
# build-initramfs.sh — Build the Stage 1 bootstrap initramfs for ArcBox.
#
# Stage 1 responsibilities (minimal bootstrap only):
#   1. Load bootstrap kernel modules needed to mount VirtioFS/squashfs/overlay.
#   2. Mount the VirtioFS share (tag "arcbox") to access boot assets.
#   3. Mount modloop and bind /newroot/lib/modules before switch_root.
#   4. Mount rootfs.squashfs as the read-only lower layer of an overlay.
#   5. Mount a tmpfs as the read-write upper layer of the overlay.
#   6. Assemble the overlay at /newroot (squashfs lower + tmpfs upper).
#   7. Move /proc, /sys, /dev, and /arcbox into /newroot.
#   8. exec switch_root /newroot /init  → hands off to Stage 2.
#
# Stage 2 (/init inside rootfs.squashfs) handles everything else:
#   network, NTP, cgroups, Docker storage, arcbox-agent.
#
# Why a squashfs rootfs?
#   The Alpine initramfs uses a ramfs whose root mount has
#   mnt->mnt_parent == mnt (self-referential). This causes pivot_root(2) to
#   return EINVAL via the mnt_has_parent() kernel check, breaking all
#   container OCI runtimes (runc, youki, crun). By switching to a proper
#   overlay (tmpfs upper) backed rootfs the constraint is satisfied.
set -euo pipefail

AGENT_BIN=""
BASE_INITRAMFS=""
MODLOOP=""
OUTPUT=""

usage() {
  cat <<'USAGE_EOF'
Usage: build-initramfs.sh [options]

Required options:
  --agent-bin <path>       Path to arcbox-agent binary (unused in stage1, kept
                           for build-release.sh compatibility)
  --base-initramfs <path>  Path to base Alpine initramfs (provides busybox)
  --modloop <path>         Path to Alpine modloop image (provides kernel .ko files)
  --output <path>          Output initramfs path
USAGE_EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent-bin)
      AGENT_BIN="$2"
      shift 2
      ;;
    --base-initramfs)
      BASE_INITRAMFS="$2"
      shift 2
      ;;
    --modloop)
      MODLOOP="$2"
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

if [[ -z "$BASE_INITRAMFS" || -z "$MODLOOP" || -z "$OUTPUT" ]]; then
  usage >&2
  exit 1
fi

for file in "$BASE_INITRAMFS" "$MODLOOP"; do
  if [[ ! -f "$file" ]]; then
    echo "required file not found: $file" >&2
    exit 1
  fi
done

if ! command -v unsquashfs >/dev/null 2>&1; then
  echo "unsquashfs is required but not found in PATH" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d /tmp/arcbox-initramfs.XXXXXX)"
MODLOOP_EXTRACT="$(mktemp -d /tmp/arcbox-modloop.XXXXXX)"

cleanup() {
  rm -rf "$WORK_DIR" "$MODLOOP_EXTRACT"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Extract the Alpine base initramfs. This provides /bin/busybox and the
# base directory structure. Stage 1 only needs busybox; all other userspace
# tools are in rootfs.squashfs (Stage 2).
# ---------------------------------------------------------------------------
echo "extract base initramfs: $BASE_INITRAMFS"
(
  cd "$WORK_DIR"
  if ! gunzip -c "$BASE_INITRAMFS" | cpio -idm 2>/dev/null; then
    cpio -idm < "$BASE_INITRAMFS" 2>/dev/null
  fi
)

# ---------------------------------------------------------------------------
# Extract Alpine modloop and copy only bootstrap modules into initramfs.
# Full module availability for Stage 2 comes from bind-mounting modloop.
# ---------------------------------------------------------------------------
echo "extract modloop: $MODLOOP"
unsquashfs -f -d "$MODLOOP_EXTRACT" "$MODLOOP" >/dev/null 2>&1

KERNEL_VERSION="$(ls "$WORK_DIR/lib/modules/" 2>/dev/null | head -1 || true)"
if [[ -z "$KERNEL_VERSION" ]]; then
  KERNEL_VERSION="$(ls "$MODLOOP_EXTRACT/modules/" 2>/dev/null | head -1 || true)"
fi
if [[ -z "$KERNEL_VERSION" ]]; then
  echo "unable to detect kernel version from initramfs/modloop" >&2
  exit 1
fi
echo "kernel version: $KERNEL_VERSION"

copy_module() {
  local src_dir="$1"
  local dest_dir="$2"
  local mod_file="$3"
  local src="$src_dir/$mod_file"
  if [[ -f "$src" ]]; then
    mkdir -p "$dest_dir"
    cp "$src" "$dest_dir/"
  fi
}

MODS_SRC="$MODLOOP_EXTRACT/modules/$KERNEL_VERSION/kernel"
MODS_DST="$WORK_DIR/lib/modules/$KERNEL_VERSION/kernel"

# Bootstrap modules required before modloop can be mounted.
# VirtIO core + console + network.
copy_module "$MODS_SRC/drivers/virtio" "$MODS_DST/drivers/virtio" virtio.ko
copy_module "$MODS_SRC/drivers/virtio" "$MODS_DST/drivers/virtio" virtio_ring.ko
copy_module "$MODS_SRC/drivers/virtio" "$MODS_DST/drivers/virtio" virtio_pci.ko
copy_module "$MODS_SRC/drivers/virtio" "$MODS_DST/drivers/virtio" virtio_pci_modern_dev.ko
copy_module "$MODS_SRC/drivers/virtio" "$MODS_DST/drivers/virtio" virtio_pci_legacy_dev.ko
copy_module "$MODS_SRC/drivers/virtio" "$MODS_DST/drivers/virtio" virtio_balloon.ko
copy_module "$MODS_SRC/drivers/virtio" "$MODS_DST/drivers/virtio" virtio_mmio.ko
copy_module "$MODS_SRC/drivers/char" "$MODS_DST/drivers/char" virtio_console.ko
copy_module "$MODS_SRC/drivers/net" "$MODS_DST/drivers/net" net_failover.ko
copy_module "$MODS_SRC/drivers/net" "$MODS_DST/drivers/net" virtio_net.ko

# VirtioFS + squashfs/overlay stack used by Stage 1 bootstrap.
copy_module "$MODS_SRC/fs/fuse" "$MODS_DST/fs/fuse" fuse.ko
copy_module "$MODS_SRC/fs/fuse" "$MODS_DST/fs/fuse" virtiofs.ko
copy_module "$MODS_SRC/drivers/block" "$MODS_DST/drivers/block" loop.ko
copy_module "$MODS_SRC/fs/squashfs" "$MODS_DST/fs/squashfs" squashfs.ko
copy_module "$MODS_SRC/fs/overlayfs" "$MODS_DST/fs/overlayfs" overlay.ko

# Copy module metadata so modprobe can resolve bootstrap dependencies.
mkdir -p "$WORK_DIR/lib/modules/$KERNEL_VERSION"
cp "$MODLOOP_EXTRACT/modules/$KERNEL_VERSION/modules.dep" \
   "$WORK_DIR/lib/modules/$KERNEL_VERSION/modules.dep" 2>/dev/null \
   || echo "warning: modules.dep not found in modloop" >&2
cp "$MODLOOP_EXTRACT/modules/$KERNEL_VERSION/modules.alias" \
   "$WORK_DIR/lib/modules/$KERNEL_VERSION/modules.alias" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Write the Stage 1 /init script.
# This script is intentionally minimal: it only bootstraps to rootfs.squashfs
# and ensures Stage 2 has full /lib/modules by bind-mounting modloop/modules.
# ---------------------------------------------------------------------------
cat > "$WORK_DIR/init" <<'INIT_EOF'
#!/bin/sh
# ArcBox Stage 1 init — minimal bootstrap to squashfs rootfs.

/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev
/bin/busybox mkdir -p /dev/pts
/bin/busybox mount -t devpts devpts /dev/pts 2>/dev/null || true

# Redirect stdout/stderr to hvc0 console when available.
i=0
while [ "$i" -lt 20 ]; do
  [ -c /dev/hvc0 ] && break
  i=$((i + 1))
  /bin/busybox sleep 0.1
done
[ -c /dev/hvc0 ] && exec </dev/hvc0 >/dev/hvc0 2>&1

log() { echo "stage1: $*"; }

KERNEL_VERSION="$(/bin/busybox uname -r)"
MODULE_DIR="/lib/modules/$KERNEL_VERSION"

# Load a kernel module: try modprobe first, fall back to insmod, ignore
# failures (the module may be compiled into the kernel).
load_ko() {
  local name="$1"
  local relpath="$2"
  /sbin/modprobe "$name" 2>/dev/null && return 0
  local full_path="$MODULE_DIR/$relpath"
  [ -f "$full_path" ] && /bin/busybox insmod "$full_path" 2>/dev/null && return 0
  return 0  # Not fatal: may be built-in.
}

log "Loading bootstrap kernel modules..."

# VirtIO core + console + network.
load_ko virtio                 "kernel/drivers/virtio/virtio.ko"
load_ko virtio_ring            "kernel/drivers/virtio/virtio_ring.ko"
load_ko virtio_pci_legacy_dev  "kernel/drivers/virtio/virtio_pci_legacy_dev.ko"
load_ko virtio_pci_modern_dev  "kernel/drivers/virtio/virtio_pci_modern_dev.ko"
load_ko virtio_pci             "kernel/drivers/virtio/virtio_pci.ko"
load_ko virtio_mmio            "kernel/drivers/virtio/virtio_mmio.ko"
load_ko virtio_console         "kernel/drivers/char/virtio_console.ko"
load_ko virtio_balloon         "kernel/drivers/virtio/virtio_balloon.ko"
load_ko net_failover           "kernel/drivers/net/net_failover.ko"
load_ko virtio_net             "kernel/drivers/net/virtio_net.ko"

# Filesystems needed by Stage 1.
load_ko fuse                   "kernel/fs/fuse/fuse.ko"
load_ko virtiofs               "kernel/fs/fuse/virtiofs.ko"
load_ko loop                   "kernel/drivers/block/loop.ko"
load_ko squashfs               "kernel/fs/squashfs/squashfs.ko"
load_ko overlay                "kernel/fs/overlayfs/overlay.ko"

# ---------------------------------------------------------------------------
# Mount VirtioFS to access boot assets.
# The host daemon mounts ~/.arcbox into the VM as the "arcbox" tag.
# ---------------------------------------------------------------------------
log "Mounting VirtioFS..."
/bin/busybox mkdir -p /mnt/arcbox
if ! /bin/busybox mount -t virtiofs arcbox /mnt/arcbox; then
  log "FATAL: cannot mount VirtioFS share 'arcbox'"
  exec /bin/busybox sh
fi

# Extract boot-asset version from kernel command line.
BOOT_VERSION=$(/bin/busybox grep -o 'arcbox.boot_asset_version=[^ ]*' /proc/cmdline \
  | /bin/busybox cut -d= -f2)
if [ -z "$BOOT_VERSION" ]; then
  log "FATAL: arcbox.boot_asset_version missing in /proc/cmdline"
  exec /bin/busybox sh
fi

SQUASHFS="/mnt/arcbox/boot/${BOOT_VERSION}/rootfs.squashfs"
MODLOOP="/mnt/arcbox/boot/${BOOT_VERSION}/modloop"
log "Using boot assets (version: $BOOT_VERSION)"
log "  rootfs:  $SQUASHFS"
log "  modloop: $MODLOOP"

if [ ! -f "$SQUASHFS" ]; then
  log "FATAL: rootfs.squashfs not found: $SQUASHFS"
  exec /bin/busybox sh
fi
if [ ! -f "$MODLOOP" ]; then
  log "FATAL: modloop not found: $MODLOOP"
  exec /bin/busybox sh
fi

# ---------------------------------------------------------------------------
# Mount modloop and expose full module tree to Stage 2.
# This is the key fix: Stage 2 will have /lib/modules and modprobe works.
# ---------------------------------------------------------------------------
/bin/busybox mkdir -p /mnt/modloop
if ! /bin/busybox mount -t squashfs -o loop "$MODLOOP" /mnt/modloop; then
  log "FATAL: cannot mount modloop: $MODLOOP"
  exec /bin/busybox sh
fi

if [ ! -d "/mnt/modloop/modules/$KERNEL_VERSION" ]; then
  log "FATAL: modloop missing modules for kernel $KERNEL_VERSION"
  exec /bin/busybox sh
fi

# ---------------------------------------------------------------------------
# Set up overlay root: squashfs (ro lower) + tmpfs (rw upper).
# ---------------------------------------------------------------------------
/bin/busybox mkdir -p /mnt/lower /mnt/upper /newroot

if ! /bin/busybox mount -t squashfs -o loop "$SQUASHFS" /mnt/lower; then
  log "FATAL: cannot mount rootfs.squashfs"
  exec /bin/busybox sh
fi

/bin/busybox mount -t tmpfs tmpfs /mnt/upper
/bin/busybox mkdir -p /mnt/upper/upper /mnt/upper/work

if ! /bin/busybox mount -t overlay overlay \
    -o "lowerdir=/mnt/lower,upperdir=/mnt/upper/upper,workdir=/mnt/upper/work" \
    /newroot; then
  log "FATAL: cannot create overlay filesystem"
  exec /bin/busybox sh
fi

/bin/busybox mkdir -p /newroot/proc /newroot/sys /newroot/dev /newroot/arcbox /newroot/lib/modules
if ! /bin/busybox mount --bind /mnt/modloop/modules /newroot/lib/modules; then
  log "FATAL: cannot bind /mnt/modloop/modules into /newroot/lib/modules"
  exec /bin/busybox sh
fi

# ---------------------------------------------------------------------------
# Move already-mounted filesystems into the new root so they are available
# immediately when Stage 2 /init starts.
# ---------------------------------------------------------------------------
/bin/busybox mount --move /proc       /newroot/proc
/bin/busybox mount --move /sys        /newroot/sys
/bin/busybox mount --move /dev        /newroot/dev
/bin/busybox mount --move /mnt/arcbox /newroot/arcbox

log "Switching root to squashfs overlay..."
exec /bin/busybox switch_root /newroot /init
INIT_EOF
chmod 755 "$WORK_DIR/init"

# ---------------------------------------------------------------------------
# Package the Stage 1 initramfs.
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$OUTPUT")"
(
  cd "$WORK_DIR"
  find . | cpio -o -H newc 2>/dev/null | gzip > "$OUTPUT"
)

echo "stage1 initramfs ready: $OUTPUT"
ls -lh "$OUTPUT"
