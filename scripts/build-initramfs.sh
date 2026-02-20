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
case "$1" in
  bound|renew)
    /sbin/ifconfig "$interface" "$ip" netmask "${subnet:-255.255.255.0}"
    [ -n "$router" ] && /sbin/route add default gw "$router" dev "$interface" 2>/dev/null || true
    { for ns in $dns; do printf 'nameserver %s\n' "$ns"; done; } > /etc/resolv.conf
    ;;
  deconfig)
    /sbin/ifconfig "$interface" 0.0.0.0
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
