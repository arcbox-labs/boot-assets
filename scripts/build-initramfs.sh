#!/usr/bin/env bash
set -euo pipefail

AGENT_BIN=""
BASE_INITRAMFS=""
MODLOOP=""
OUTPUT=""

usage() {
  cat <<'EOF'
Usage: build-initramfs.sh [options]

Required options:
  --agent-bin <path>       Path to arcbox-agent binary
  --base-initramfs <path>  Path to base Alpine initramfs
  --modloop <path>         Path to Alpine modloop image
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

if [[ -z "$AGENT_BIN" || -z "$BASE_INITRAMFS" || -z "$MODLOOP" || -z "$OUTPUT" ]]; then
  usage >&2
  exit 1
fi

for file in "$AGENT_BIN" "$BASE_INITRAMFS" "$MODLOOP"; do
  if [[ ! -f "$file" ]]; then
    echo "required file not found: $file" >&2
    exit 1
  fi
done

if ! command -v unsquashfs >/dev/null 2>&1; then
  echo "unsquashfs is required but not found in PATH" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d /tmp/boot-assets-initramfs.XXXXXX)"
MODLOOP_EXTRACT="$(mktemp -d /tmp/boot-assets-modloop.XXXXXX)"

cleanup() {
  rm -rf "$WORK_DIR" "$MODLOOP_EXTRACT"
}
trap cleanup EXIT

echo "extract base initramfs: $BASE_INITRAMFS"
(
  cd "$WORK_DIR"
  if ! gunzip -c "$BASE_INITRAMFS" | cpio -idm 2>/dev/null; then
    cpio -idm < "$BASE_INITRAMFS" 2>/dev/null
  fi
)

echo "inject arcbox-agent: $AGENT_BIN"
mkdir -p "$WORK_DIR/sbin"
cp "$AGENT_BIN" "$WORK_DIR/sbin/arcbox-agent"
chmod 755 "$WORK_DIR/sbin/arcbox-agent"

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

mkdir -p "$WORK_DIR/lib/modules/$KERNEL_VERSION/kernel/drivers/virtio"
mkdir -p "$WORK_DIR/lib/modules/$KERNEL_VERSION/kernel/drivers/char"
mkdir -p "$WORK_DIR/lib/modules/$KERNEL_VERSION/kernel/net/vmw_vsock"
mkdir -p "$WORK_DIR/lib/modules/$KERNEL_VERSION/kernel/fs/fuse"

VIRTIO_SRC="$MODLOOP_EXTRACT/modules/$KERNEL_VERSION/kernel/drivers/virtio"
if [[ -d "$VIRTIO_SRC" ]]; then
  for mod in virtio.ko virtio_ring.ko virtio_pci.ko virtio_pci_modern_dev.ko virtio_pci_legacy_dev.ko virtio_balloon.ko virtio_mmio.ko; do
    cp "$VIRTIO_SRC/$mod" "$WORK_DIR/lib/modules/$KERNEL_VERSION/kernel/drivers/virtio/" 2>/dev/null || true
  done
fi

CONSOLE_SRC="$MODLOOP_EXTRACT/modules/$KERNEL_VERSION/kernel/drivers/char"
if [[ -d "$CONSOLE_SRC" ]]; then
  cp "$CONSOLE_SRC/virtio_console.ko" "$WORK_DIR/lib/modules/$KERNEL_VERSION/kernel/drivers/char/" 2>/dev/null || true
fi

VSOCK_SRC="$MODLOOP_EXTRACT/modules/$KERNEL_VERSION/kernel/net/vmw_vsock"
if [[ -d "$VSOCK_SRC" ]]; then
  cp "$VSOCK_SRC/vsock.ko" "$WORK_DIR/lib/modules/$KERNEL_VERSION/kernel/net/vmw_vsock/" 2>/dev/null || true
  cp "$VSOCK_SRC/vmw_vsock_virtio_transport_common.ko" "$WORK_DIR/lib/modules/$KERNEL_VERSION/kernel/net/vmw_vsock/" 2>/dev/null || true
  cp "$VSOCK_SRC/vmw_vsock_virtio_transport.ko" "$WORK_DIR/lib/modules/$KERNEL_VERSION/kernel/net/vmw_vsock/" 2>/dev/null || true
fi

FUSE_SRC="$MODLOOP_EXTRACT/modules/$KERNEL_VERSION/kernel/fs/fuse"
if [[ -d "$FUSE_SRC" ]]; then
  cp "$FUSE_SRC/fuse.ko" "$WORK_DIR/lib/modules/$KERNEL_VERSION/kernel/fs/fuse/" 2>/dev/null || true
  cp "$FUSE_SRC/virtiofs.ko" "$WORK_DIR/lib/modules/$KERNEL_VERSION/kernel/fs/fuse/" 2>/dev/null || true
fi

# Copy virtio_net.ko for guest network access via VZ framework NAT.
mkdir -p "$WORK_DIR/lib/modules/$KERNEL_VERSION/kernel/drivers/net"
NET_SRC="$MODLOOP_EXTRACT/modules/$KERNEL_VERSION/kernel/drivers/net"
if [[ -d "$NET_SRC" ]]; then
  # net_failover is an optional dependency of virtio_net on newer kernels.
  cp "$NET_SRC/net_failover.ko" \
     "$WORK_DIR/lib/modules/$KERNEL_VERSION/kernel/drivers/net/" 2>/dev/null || true
  cp "$NET_SRC/virtio_net.ko" \
     "$WORK_DIR/lib/modules/$KERNEL_VERSION/kernel/drivers/net/" 2>/dev/null || true
fi

# Install udhcpc DHCP lease handler script.
# udhcpc calls this on bound/renew events to configure the interface and DNS.
mkdir -p "$WORK_DIR/usr/share/udhcpc"
cat > "$WORK_DIR/usr/share/udhcpc/default.script" <<'UDHCPC_EOF'
#!/bin/sh
# udhcpc lease handler: configure interface on DHCP bound/renew events.
# Alpine initramfs does not have /sbin/ifconfig or /sbin/route; use
# /bin/busybox applets which are always available at that fixed path.
case "$1" in
  bound|renew)
    /bin/busybox ifconfig "$interface" "$ip" netmask "${subnet:-255.255.255.0}"
    [ -n "$router" ] && /bin/busybox route add default gw "$router" dev "$interface" 2>/dev/null || true
    { for ns in $dns; do printf 'nameserver %s\n' "$ns"; done; } > /etc/resolv.conf
    ;;
  deconfig)
    /bin/busybox ifconfig "$interface" 0.0.0.0
    ;;
esac
UDHCPC_EOF
chmod +x "$WORK_DIR/usr/share/udhcpc/default.script"

cat > "$WORK_DIR/init" <<'INIT_EOF'
#!/bin/sh
# ArcBox init script

/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev
/bin/busybox mkdir -p /dev/pts /var/log /tmp
/bin/busybox mount -t devpts devpts /dev/pts
/bin/busybox hostname arcbox-vm

INIT_LOG="/var/log/arcbox-init.log"
/bin/busybox touch "$INIT_LOG"

log_line() {
  msg="$*"
  echo "$msg"
  echo "$msg" >> "$INIT_LOG"
}

run_cmd() {
  out="/tmp/arcbox-cmd.$$.log"
  "$@" > "$out" 2>&1
  rc=$?
  if [ -s "$out" ]; then
    /bin/busybox cat "$out" >> "$INIT_LOG"
    if [ "$rc" -ne 0 ]; then
      /bin/busybox cat "$out"
    fi
  fi
  /bin/busybox rm -f "$out"
  return "$rc"
}

MODULE_DIR="/lib/modules/$(/bin/busybox uname -r)"

load_module() {
  name="$1"
  relpath="$2"
  modpath="$MODULE_DIR/$relpath"

  if run_cmd /sbin/modprobe "$name"; then
    log_line "  Loaded: $name"
    return 0
  fi

  if [ -f "$modpath" ] && run_cmd /bin/busybox insmod "$modpath"; then
    log_line "  Loaded: $name (insmod)"
    return 0
  fi

  log_line "  Failed: $name"
  return 1
}

# Bind-mount / over itself so pivot_root has a valid mnt_parent.
# The Alpine initramfs rootfs type has mnt->mnt_parent == mnt (self-referential),
# causing pivot_root(2) to fail with EINVAL because mnt_has_parent() returns false.
# A bind mount creates a new mount entry at the same path whose mnt_parent points
# to the original rootfs (a distinct object), satisfying the kernel check.
# Container OCI runtimes (youki, runc) require this to set up the container rootfs.
if /bin/busybox mount -o bind / /; then
  log_line "Root bind-mount: ok"
else
  log_line "Root bind-mount: failed (rc=$?), pivot_root may fail in containers"
fi
log_line ""

log_line "Loading virtio core modules..."
load_module virtio "kernel/drivers/virtio/virtio.ko"
load_module virtio_ring "kernel/drivers/virtio/virtio_ring.ko"
load_module virtio_pci_legacy_dev "kernel/drivers/virtio/virtio_pci_legacy_dev.ko"
load_module virtio_pci_modern_dev "kernel/drivers/virtio/virtio_pci_modern_dev.ko"
load_module virtio_pci "kernel/drivers/virtio/virtio_pci.ko"
load_module virtio_mmio "kernel/drivers/virtio/virtio_mmio.ko"
load_module virtio_console "kernel/drivers/char/virtio_console.ko"
load_module virtio_balloon "kernel/drivers/virtio/virtio_balloon.ko"
# net_failover is an optional soft-dependency of virtio_net on newer kernels;
# load it first so insmod virtio_net succeeds even without modprobe dep resolution.
load_module net_failover "kernel/drivers/net/net_failover.ko"
load_module virtio_net "kernel/drivers/net/virtio_net.ko"
log_line ""

# Rebind stdio to hvc0 when available (Virtualization.framework virtio console).
i=0
while [ "$i" -lt 20 ]; do
  if [ -c /dev/hvc0 ]; then
    break
  fi
  i=$((i + 1))
  /bin/busybox sleep 0.1
done
if [ -c /dev/hvc0 ]; then
  exec </dev/hvc0 >/dev/hvc0 2>&1
fi

# Bring up loopback first; required for processes that bind to 127.0.0.1
# (e.g. containerd CRI streaming server).
/bin/busybox ip link set lo up 2>/dev/null || true

# Configure eth0 via DHCP (VZ framework NAT provides a DHCP server at 192.168.64.1).
log_line "Configuring network..."
/bin/busybox ip link set eth0 up 2>/dev/null
/bin/busybox ifconfig eth0 up 2>/dev/null
if /bin/busybox udhcpc -i eth0 -t 5 -T 2 -n -s /usr/share/udhcpc/default.script 2>/dev/null; then
  log_line "  Network: DHCP ok on eth0"
else
  log_line "  Network: DHCP failed, using static fallback (192.168.64.2/24)"
  /bin/busybox ifconfig eth0 192.168.64.2 netmask 255.255.255.0 2>/dev/null || true
  /bin/busybox route add default gw 192.168.64.1 2>/dev/null || true
  printf 'nameserver 192.168.64.1\n' > /etc/resolv.conf
fi
log_line ""

# Sync system clock via NTP. The VZ framework virtualised RTC is not
# automatically read by the Alpine kernel, so the guest clock starts at
# epoch (1970-01-01). Without a correct clock, TLS cert verification fails.
# busybox ntpd -q performs a one-shot adjustment and exits.
# Use numeric IPs first to avoid DNS resolution timeout: busybox ntpd sends a
# single NTP query and waits for SIGALRM (default 64 s) if the server is
# unreachable. DNS lookup for pool.ntp.org can itself timeout, causing the
# script to stall for minutes. Numeric IPs bypass that bottleneck.
#   162.159.200.123  Cloudflare NTP (time.cloudflare.com)
#   17.253.14.251    Apple NTP     (time.apple.com)
log_line "Syncing time via NTP..."
if /bin/busybox ntpd -q -n -p 162.159.200.123 2>/dev/null \
   || /bin/busybox ntpd -q -n -p 17.253.14.251 2>/dev/null \
   || /bin/busybox ntpd -q -n -p pool.ntp.org 2>/dev/null; then
  log_line "  Time: NTP sync ok ($(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown))"
else
  log_line "  Time: NTP sync failed (TLS cert verification may fail)"
fi
log_line ""

log_line "ArcBox Guest VM starting (kernel: $(/bin/busybox uname -r))"
log_line "Kernel cmdline: $(/bin/busybox cat /proc/cmdline)"

log_line "Loading fuse/virtiofs modules..."
load_module fuse "kernel/fs/fuse/fuse.ko"
load_module virtiofs "kernel/fs/fuse/virtiofs.ko"
log_line ""

log_line "Mounting VirtioFS..."
/bin/busybox mkdir -p /arcbox
if run_cmd /bin/busybox mount -t virtiofs arcbox /arcbox; then
  log_line "  VirtioFS mounted at /arcbox"
  if /bin/busybox touch /arcbox/init.log 2>/dev/null; then
    /bin/busybox cat "$INIT_LOG" >> /arcbox/init.log 2>/dev/null || true
    INIT_LOG="/arcbox/init.log"
    log_line "  Init logs: $INIT_LOG"
  fi
else
  log_line "  VirtioFS mount FAILED"
fi
log_line ""

log_line "Network state:"
/bin/busybox ip addr show >> "$INIT_LOG" 2>&1 || true
/bin/busybox ip route show >> "$INIT_LOG" 2>&1 || true
log_line "DNS config:"
/bin/busybox cat /etc/resolv.conf >> "$INIT_LOG" 2>&1 || true
log_line ""

# Enable IPv4 forwarding so Docker can route traffic between docker0 and eth0.
echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
log_line "IPv4 forwarding: $(/bin/busybox cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo unknown)"
log_line ""

log_line "Setting up container prerequisites..."
/bin/busybox mkdir -p /sys/fs/cgroup
if /bin/busybox mount -t cgroup2 cgroup2 /sys/fs/cgroup 2>/dev/null; then
  log_line "  cgroup2 mounted at /sys/fs/cgroup"
else
  log_line "  cgroup2 mount failed (may already be mounted)"
fi

# Load overlay filesystem module required by Docker's overlay2 storage driver.
# Without overlay, pivot_root fails with EINVAL when creating containers.
load_module overlay "kernel/fs/overlayfs/overlay.ko"

# Mount tmpfs on /var/lib/docker so overlay2 storage driver can create overlay
# mounts. The initramfs rootfs (ramfs) does not support xattrs or overlayfs
# upper layers; tmpfs does. Without this, dockerd overlay2 mounts fail and
# pivot_root returns EINVAL because the merged directory is not a mount point.
/bin/busybox mkdir -p /var/lib/docker
if /bin/busybox mount -t tmpfs tmpfs /var/lib/docker -o size=10g; then
  log_line "  tmpfs mounted at /var/lib/docker (overlay2 backing store)"
else
  log_line "  tmpfs mount on /var/lib/docker failed (overlay2 may not work)"
fi
log_line ""

log_line "Loading vsock modules..."
load_module vsock "kernel/net/vmw_vsock/vsock.ko"
load_module vmw_vsock_virtio_transport_common "kernel/net/vmw_vsock/vmw_vsock_virtio_transport_common.ko"
load_module vmw_vsock_virtio_transport "kernel/net/vmw_vsock/vmw_vsock_virtio_transport.ko"

if [ -e /dev/vsock ]; then
  log_line "  vsock device ready: /dev/vsock"
else
  log_line "  vsock device missing: /dev/vsock"
fi

if [ -f /proc/modules ]; then
  log_line "Loaded vsock-related modules:"
  /bin/busybox grep -E 'vsock|virtio' /proc/modules >> "$INIT_LOG" 2>&1 || true
fi

/bin/busybox sleep 1

# Make the entire mount tree recursively private.
# pivot_root (used by container OCI runtimes) fails with EINVAL when any mount
# in the parent namespace has shared propagation. Without this, IS_MNT_SHARED
# checks in the kernel reject pivot_root even if the container rootfs is a
# proper mount point. This is the standard container-host initialisation step.
/bin/busybox mount --make-rprivate / 2>/dev/null && log_line "Mount tree: rprivate" || log_line "Mount tree: make-rprivate failed (pivot_root may fail)"

AGENT_LOG="/var/log/arcbox-agent.log"
if /bin/busybox grep -q " /arcbox " /proc/mounts; then
  AGENT_LOG="/arcbox/agent.log"
fi

log_line "Starting arcbox-agent on vsock port 1024..."
log_line "Agent logs: $AGENT_LOG"
if /bin/busybox touch "$AGENT_LOG" 2>/dev/null; then
  :
else
  log_line "Agent log path not writable, falling back to init log"
  AGENT_LOG="$INIT_LOG"
fi

while true; do
  /sbin/arcbox-agent >> "$AGENT_LOG" 2>&1
  rc=$?
  log_line "arcbox-agent exited (code=$rc), restarting in 1s"
  /bin/busybox sleep 1
done
INIT_EOF
chmod 755 "$WORK_DIR/init"

mkdir -p "$(dirname "$OUTPUT")"
(
  cd "$WORK_DIR"
  find . | cpio -o -H newc 2>/dev/null | gzip > "$OUTPUT"
)

echo "initramfs ready: $OUTPUT"
ls -lh "$OUTPUT"
