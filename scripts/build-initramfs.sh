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

mkdir -p "$WORK_DIR/lib/modules/$KERNEL_VERSION/kernel/net/vmw_vsock"
mkdir -p "$WORK_DIR/lib/modules/$KERNEL_VERSION/kernel/fs/fuse"

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

touch "$WORK_DIR/lib/modules/$KERNEL_VERSION/modules.dep"
cat >> "$WORK_DIR/lib/modules/$KERNEL_VERSION/modules.dep" <<'EOF'
kernel/net/vmw_vsock/vsock.ko:
kernel/net/vmw_vsock/vmw_vsock_virtio_transport_common.ko: kernel/net/vmw_vsock/vsock.ko
kernel/net/vmw_vsock/vmw_vsock_virtio_transport.ko: kernel/net/vmw_vsock/vmw_vsock_virtio_transport_common.ko
kernel/fs/fuse/fuse.ko:
kernel/fs/fuse/virtiofs.ko: kernel/fs/fuse/fuse.ko
EOF

cat > "$WORK_DIR/init" <<'INIT_EOF'
#!/bin/sh
# ArcBox init script

/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev
/bin/busybox mkdir -p /dev/pts
/bin/busybox mount -t devpts devpts /dev/pts
/bin/busybox hostname arcbox-vm

echo "=================================="
echo "  ArcBox Guest VM Starting..."
echo "=================================="
echo "Kernel: $(/bin/busybox uname -r)"
echo ""

echo "Loading fuse/virtiofs modules..."
/sbin/modprobe fuse 2>/dev/null && echo "  Loaded: fuse" || echo "  Failed: fuse"
/sbin/modprobe virtiofs 2>/dev/null && echo "  Loaded: virtiofs" || echo "  Failed: virtiofs"
echo ""

echo "Mounting VirtioFS..."
/bin/busybox mkdir -p /arcbox
if /bin/busybox mount -t virtiofs arcbox /arcbox; then
  echo "  VirtioFS mounted at /arcbox"
else
  echo "  VirtioFS mount FAILED"
fi
echo ""

echo "Loading vsock modules..."
/sbin/modprobe vsock 2>/dev/null && echo "  Loaded: vsock" || echo "  Failed: vsock"
/sbin/modprobe vmw_vsock_virtio_transport_common 2>/dev/null && echo "  Loaded: vmw_vsock_virtio_transport_common" || echo "  Failed: vmw_vsock_virtio_transport_common"
/sbin/modprobe vmw_vsock_virtio_transport 2>/dev/null && echo "  Loaded: vmw_vsock_virtio_transport" || echo "  Failed: vmw_vsock_virtio_transport"

/bin/busybox sleep 1

echo "Starting arcbox-agent on vsock port 1024..."
echo "Agent logs: /arcbox/agent.log"
exec /sbin/arcbox-agent >> /arcbox/agent.log 2>&1
INIT_EOF
chmod 755 "$WORK_DIR/init"

mkdir -p "$(dirname "$OUTPUT")"
(
  cd "$WORK_DIR"
  find . | cpio -o -H newc 2>/dev/null | gzip > "$OUTPUT"
)

echo "initramfs ready: $OUTPUT"
ls -lh "$OUTPUT"
