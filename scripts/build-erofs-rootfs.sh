#!/usr/bin/env bash
# Build minimal EROFS rootfs for ArcBox VMs.
#
# Contents: busybox (static) + mkfs.btrfs (static) + iptables-legacy (static)
#           + CA certificate bundle + busybox trampoline /sbin/init.
#
# No Alpine packages, no agent, no runtime binaries, no package manager.
#
# Usage:
#   ./scripts/build-erofs-rootfs.sh --output rootfs.erofs [--arch arm64]
#
# Prerequisites:
#   - Docker (uses Alpine container to extract static binaries)
#   - mkfs.erofs (erofs-utils)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

OUTPUT=""
ARCH="arm64"
EROFS_COMPRESSION="lz4hc"

usage() {
  cat <<'EOF'
Usage: build-erofs-rootfs.sh [options]

Required:
  --output <path>     Output EROFS image path

Optional:
  --arch <arch>       Target architecture (default: arm64)
  --compression <alg> EROFS compression algorithm (default: lz4hc)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)     OUTPUT="$2";            shift 2 ;;
    --arch)       ARCH="$2";              shift 2 ;;
    --compression) EROFS_COMPRESSION="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$OUTPUT" ]]; then
  usage >&2
  exit 1
fi

# Map arch to Docker platform and Alpine arch.
case "$ARCH" in
  arm64)   DOCKER_PLATFORM="linux/arm64"; ALPINE_ARCH="aarch64" ;;
  x86_64)  DOCKER_PLATFORM="linux/amd64"; ALPINE_ARCH="x86_64"  ;;
  *)       echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "==> Extracting static binaries via Docker (${DOCKER_PLATFORM})"

# Use a Docker container to install Alpine packages and copy out static binaries.
# This avoids host-architecture issues when building for ARM64 on x86_64 or vice versa.
docker run --rm --platform "$DOCKER_PLATFORM" \
  -v "$STAGING:/out" \
  alpine:latest sh -c '
set -e

apk add --no-cache \
  busybox-static \
  btrfs-progs \
  iptables \
  ca-certificates

# Static busybox
cp /bin/busybox.static /out/busybox

# mkfs.btrfs — not fully static in Alpine, but we copy it with its deps.
# The agent calls it via Command::new("/sbin/mkfs.btrfs"), so we need the
# binary itself plus musl libc.
cp /sbin/mkfs.btrfs /out/mkfs.btrfs

# iptables-legacy multi-call binary (Docker bridge networking needs it).
# Alpine ships iptables-legacy as a separate binary.
if [ -f /sbin/iptables-legacy ]; then
  cp /sbin/iptables-legacy /out/iptables
else
  cp /sbin/iptables /out/iptables
fi

# musl libc (needed by mkfs.btrfs and iptables)
cp /lib/ld-musl-*.so.1 /out/

# CA certificate bundle
cp /etc/ssl/certs/ca-certificates.crt /out/ca-certificates.crt
'

echo "==> Building EROFS rootfs staging directory"

ROOTFS="$STAGING/rootfs"
mkdir -p "$ROOTFS"

# /bin — busybox only, create essential symlinks
mkdir -p "$ROOTFS/bin"
cp "$STAGING/busybox" "$ROOTFS/bin/busybox"
chmod 755 "$ROOTFS/bin/busybox"
# Create essential busybox symlinks (sh, mount, mkdir, etc.)
for cmd in sh mount umount mkdir cat echo sleep ln chmod chown \
           cp mv rm ls ip hostname sysctl; do
  ln -s busybox "$ROOTFS/bin/$cmd"
done

# /sbin — system binaries
mkdir -p "$ROOTFS/sbin"
cp "$STAGING/mkfs.btrfs" "$ROOTFS/sbin/mkfs.btrfs"
chmod 755 "$ROOTFS/sbin/mkfs.btrfs"

# iptables-legacy and symlinks
cp "$STAGING/iptables" "$ROOTFS/sbin/iptables"
chmod 755 "$ROOTFS/sbin/iptables"
for link in iptables-save iptables-restore ip6tables ip6tables-save ip6tables-restore; do
  ln -s iptables "$ROOTFS/sbin/$link"
done

# /lib — musl libc
mkdir -p "$ROOTFS/lib"
cp "$STAGING"/ld-musl-*.so.1 "$ROOTFS/lib/"
chmod 755 "$ROOTFS"/lib/ld-musl-*.so.1

# /cacerts — CA certificate bundle (read-only in EROFS; agent symlinks to /etc/ssl/)
mkdir -p "$ROOTFS/cacerts"
cp "$STAGING/ca-certificates.crt" "$ROOTFS/cacerts/ca-certificates.crt"

# Mount point directories (empty)
for dir in tmp run proc sys dev mnt arcbox Users etc var; do
  mkdir -p "$ROOTFS/$dir"
done

# /sbin/init — busybox trampoline (6 lines)
cat > "$ROOTFS/sbin/init" <<'INIT'
#!/bin/busybox sh
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev
/bin/busybox mkdir -p /arcbox
/bin/busybox mount -t virtiofs arcbox /arcbox
exec /arcbox/bin/arcbox-agent
INIT
chmod 755 "$ROOTFS/sbin/init"

echo "==> Creating EROFS image"

# Ensure mkfs.erofs is available.
if ! command -v mkfs.erofs >/dev/null 2>&1; then
  echo "mkfs.erofs not found. Install erofs-utils:" >&2
  echo "  macOS:  brew install erofs-utils" >&2
  echo "  Ubuntu: apt install erofs-utils" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
mkfs.erofs -z"$EROFS_COMPRESSION" "$OUTPUT" "$ROOTFS"

IMAGE_SIZE="$(ls -lh "$OUTPUT" | awk '{print $5}')"
echo ""
echo "==> EROFS rootfs built: $OUTPUT ($IMAGE_SIZE)"
echo "    Compression: $EROFS_COMPRESSION"
echo "    Contents: busybox + mkfs.btrfs + iptables-legacy + CA certs + trampoline"
