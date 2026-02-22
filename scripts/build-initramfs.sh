#!/usr/bin/env bash
# build-initramfs.sh — Build the Stage 1 bootstrap initramfs for ArcBox.
#
# Stage 1 responsibilities (minimal bootstrap only):
#   1. Load all required kernel modules from embedded .ko files.
#   2. Mount the VirtioFS share (tag "arcbox") to access rootfs.squashfs.
#   3. Mount rootfs.squashfs as the read-only lower layer of an overlay.
#   4. Mount a tmpfs as the read-write upper layer of the overlay.
#   5. Assemble the overlay at /newroot (squashfs lower + tmpfs upper).
#   6. Move /proc, /sys, /dev, and /arcbox into /newroot.
#   7. exec switch_root /newroot /init  → hands off to Stage 2.
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
  cat <<'EOF'
Usage: build-initramfs.sh [options]

Required options:
  --agent-bin <path>       Path to arcbox-agent binary (unused in stage1, kept
                           for build-release.sh compatibility)
  --base-initramfs <path>  Path to base Alpine initramfs (provides busybox)
  --modloop <path>         Path to Alpine modloop image (provides kernel .ko files)
  --output <path>          Output initramfs path
EOF
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
# Extract kernel modules from Alpine modloop.
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

# VirtIO core: required for any virtio device to work.
copy_module "$MODS_SRC/drivers/virtio" "$MODS_DST/drivers/virtio" virtio.ko
copy_module "$MODS_SRC/drivers/virtio" "$MODS_DST/drivers/virtio" virtio_ring.ko
copy_module "$MODS_SRC/drivers/virtio" "$MODS_DST/drivers/virtio" virtio_pci.ko
copy_module "$MODS_SRC/drivers/virtio" "$MODS_DST/drivers/virtio" virtio_pci_modern_dev.ko
copy_module "$MODS_SRC/drivers/virtio" "$MODS_DST/drivers/virtio" virtio_pci_legacy_dev.ko
copy_module "$MODS_SRC/drivers/virtio" "$MODS_DST/drivers/virtio" virtio_balloon.ko
copy_module "$MODS_SRC/drivers/virtio" "$MODS_DST/drivers/virtio" virtio_mmio.ko

# VirtIO console: enables /dev/hvc0 serial console.
copy_module "$MODS_SRC/drivers/char" "$MODS_DST/drivers/char" virtio_console.ko

# VirtIO network: required for DHCP/NAT in Stage 2 (module loaded in Stage 1).
copy_module "$MODS_SRC/drivers/net" "$MODS_DST/drivers/net" net_failover.ko
copy_module "$MODS_SRC/drivers/net" "$MODS_DST/drivers/net" virtio_net.ko

# FUSE / VirtioFS: required to mount the VirtioFS share in Stage 1.
copy_module "$MODS_SRC/fs/fuse" "$MODS_DST/fs/fuse" fuse.ko
copy_module "$MODS_SRC/fs/fuse" "$MODS_DST/fs/fuse" virtiofs.ko

# Loop device: required to mount rootfs.squashfs as a loop block device.
copy_module "$MODS_SRC/drivers/block" "$MODS_DST/drivers/block" loop.ko

# Squashfs: filesystem driver for rootfs.squashfs.
copy_module "$MODS_SRC/fs/squashfs" "$MODS_DST/fs/squashfs" squashfs.ko

# Overlay filesystem: required for the squashfs(ro)+tmpfs(rw) overlay in Stage 1.
copy_module "$MODS_SRC/fs/overlayfs" "$MODS_DST/fs/overlayfs" overlay.ko

# vsock: required for arcbox-agent ↔ host communication (loaded here so it
# is available immediately when the agent starts in Stage 2).
copy_module "$MODS_SRC/net/vmw_vsock" "$MODS_DST/net/vmw_vsock" vsock.ko
copy_module "$MODS_SRC/net/vmw_vsock" "$MODS_DST/net/vmw_vsock" vmw_vsock_virtio_transport_common.ko
copy_module "$MODS_SRC/net/vmw_vsock" "$MODS_DST/net/vmw_vsock" vmw_vsock_virtio_transport.ko

# ---------------------------------------------------------------------------
# Write the Stage 1 /init script.
# This script is intentionally minimal: it only bootstraps to rootfs.squashfs.
# All complex initialisation (network, NTP, agent) is in Stage 2.
# ---------------------------------------------------------------------------
cat > "$WORK_DIR/init" <<'INIT_EOF'
#!/bin/sh
# ArcBox Stage 1 init — minimal bootstrap to squashfs rootfs.
#
# This runs directly from the initramfs ramfs. Its only job is to load
# kernel modules, mount VirtioFS, set up the squashfs+overlay rootfs,
# and exec switch_root. All guest OS logic is in Stage 2 (/init inside
# rootfs.squashfs).

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

MODULE_DIR="/lib/modules/$(/bin/busybox uname -r)"

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

log "Loading kernel modules..."

# VirtIO core.
load_ko virtio             "kernel/drivers/virtio/virtio.ko"
load_ko virtio_ring        "kernel/drivers/virtio/virtio_ring.ko"
load_ko virtio_pci_legacy_dev "kernel/drivers/virtio/virtio_pci_legacy_dev.ko"
load_ko virtio_pci_modern_dev "kernel/drivers/virtio/virtio_pci_modern_dev.ko"
load_ko virtio_pci         "kernel/drivers/virtio/virtio_pci.ko"
load_ko virtio_mmio        "kernel/drivers/virtio/virtio_mmio.ko"
load_ko virtio_console     "kernel/drivers/char/virtio_console.ko"
load_ko virtio_balloon     "kernel/drivers/virtio/virtio_balloon.ko"
load_ko net_failover       "kernel/drivers/net/net_failover.ko"
load_ko virtio_net         "kernel/drivers/net/virtio_net.ko"

# VirtioFS (to mount the arcbox share and access rootfs.squashfs).
load_ko fuse               "kernel/fs/fuse/fuse.ko"
load_ko virtiofs           "kernel/fs/fuse/virtiofs.ko"

# Loop device + squashfs (to mount rootfs.squashfs).
load_ko loop               "kernel/drivers/block/loop.ko"
load_ko squashfs           "kernel/fs/squashfs/squashfs.ko"

# Overlay filesystem (for the squashfs-lower + tmpfs-upper rootfs).
load_ko overlay            "kernel/fs/overlayfs/overlay.ko"

# vsock (for arcbox-agent ↔ host communication after switch_root).
load_ko vsock              "kernel/net/vmw_vsock/vsock.ko"
load_ko vmw_vsock_virtio_transport_common \
                           "kernel/net/vmw_vsock/vmw_vsock_virtio_transport_common.ko"
load_ko vmw_vsock_virtio_transport \
                           "kernel/net/vmw_vsock/vmw_vsock_virtio_transport.ko"

# ---------------------------------------------------------------------------
# Mount VirtioFS to access rootfs.squashfs.
# The host daemon mounts ~/.arcbox into the VM as the "arcbox" VirtioFS tag.
# rootfs.squashfs lives at /arcbox/boot/<version>/rootfs.squashfs inside it.
# ---------------------------------------------------------------------------
log "Mounting VirtioFS..."
/bin/busybox mkdir -p /mnt/arcbox
if ! /bin/busybox mount -t virtiofs arcbox /mnt/arcbox; then
  log "FATAL: cannot mount VirtioFS share 'arcbox'"
  exec /bin/busybox sh
fi

# Extract boot-asset version from kernel command line.
# The daemon appends arcbox.boot_asset_version=<ver> to the cmdline.
BOOT_VERSION=$(/bin/busybox grep -o 'arcbox.boot_asset_version=[^ ]*' /proc/cmdline \
  | /bin/busybox cut -d= -f2)

SQUASHFS="/mnt/arcbox/boot/${BOOT_VERSION}/rootfs.squashfs"
log "Using rootfs: $SQUASHFS (version: $BOOT_VERSION)"

if [ ! -f "$SQUASHFS" ]; then
  log "FATAL: rootfs.squashfs not found: $SQUASHFS"
  exec /bin/busybox sh
fi

# ---------------------------------------------------------------------------
# Set up the overlay: squashfs (read-only lower) + tmpfs (read-write upper).
# This gives a fully writable root filesystem. The tmpfs upper layer is what
# makes pivot_root work: it has a proper mnt_parent (unlike the initramfs
# ramfs whose root mount is self-referential).
# ---------------------------------------------------------------------------
/bin/busybox mkdir -p /mnt/lower /mnt/upper/upper /mnt/upper/work /newroot

# Mount squashfs as the read-only lower layer via a loop device.
if ! /bin/busybox mount -t squashfs -o loop "$SQUASHFS" /mnt/lower; then
  log "FATAL: cannot mount rootfs.squashfs"
  exec /bin/busybox sh
fi

# Mount tmpfs as the read-write upper layer.
/bin/busybox mount -t tmpfs tmpfs /mnt/upper

# Assemble overlay: lower=squashfs, upper=tmpfs, merged=newroot.
if ! /bin/busybox mount -t overlay overlay \
    -o "lowerdir=/mnt/lower,upperdir=/mnt/upper/upper,workdir=/mnt/upper/work" \
    /newroot; then
  log "FATAL: cannot create overlay filesystem"
  exec /bin/busybox sh
fi

# Create mount points in new root if they don't already exist in the squashfs.
/bin/busybox mkdir -p /newroot/proc /newroot/sys /newroot/dev /newroot/arcbox

# ---------------------------------------------------------------------------
# Move already-mounted filesystems into the new root so they are available
# immediately when Stage 2 /init starts.
# ---------------------------------------------------------------------------
/bin/busybox mount --move /proc    /newroot/proc
/bin/busybox mount --move /sys     /newroot/sys
/bin/busybox mount --move /dev     /newroot/dev
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
