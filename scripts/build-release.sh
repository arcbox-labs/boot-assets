#!/usr/bin/env bash
# Build ArcBox boot-assets release tarball (schema v6).
#
# Output: kernel + rootfs.erofs + manifest.json
# No agent, no runtime binaries, no initramfs.
#
# Usage:
#   ./scripts/build-release.sh --version 0.1.0 --kernel /path/to/kernel
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION=""
ARCH="arm64"
KERNEL_PATH=""
ROOTFS_EROFS_PATH=""
OUTPUT_DIR="$ROOT_DIR/dist"
EROFS_COMPRESSION="lz4hc"

# Optional metadata for manifest.
SOURCE_REPO="${KERNEL_REPO:-unknown}"
SOURCE_REF="${KERNEL_REF:-unknown}"
SOURCE_SHA="${KERNEL_SHA:-unknown}"
KERNEL_VERSION="${KERNEL_VERSION:-unknown}"

usage() {
  cat <<'EOF'
Usage: build-release.sh [options]

Required:
  --version <version>   Asset version (e.g. 0.1.0)
  --kernel <path>       Path to pre-built kernel binary

Optional:
  --arch <arch>         Target architecture (default: arm64)
  --rootfs <path>       Path to pre-built rootfs.erofs (skip build)
  --output-dir <dir>    Output directory (default: dist/)
  --compression <alg>   EROFS compression (default: lz4hc)
  --source-repo <repo>  Source repository for manifest
  --source-ref <ref>    Source ref for manifest
  --source-sha <sha>    Source SHA for manifest
  --kernel-version <v>  Kernel version for manifest
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)        VERSION="$2";              shift 2 ;;
    --kernel)         KERNEL_PATH="$2";          shift 2 ;;
    --arch)           ARCH="$2";                 shift 2 ;;
    --rootfs)         ROOTFS_EROFS_PATH="$2";    shift 2 ;;
    --output-dir)     OUTPUT_DIR="$2";           shift 2 ;;
    --compression)    EROFS_COMPRESSION="$2";    shift 2 ;;
    --source-repo)    SOURCE_REPO="$2";          shift 2 ;;
    --source-ref)     SOURCE_REF="$2";           shift 2 ;;
    --source-sha)     SOURCE_SHA="$2";           shift 2 ;;
    --kernel-version) KERNEL_VERSION="$2";       shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *)                echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$VERSION" || -z "$KERNEL_PATH" ]]; then
  usage >&2
  exit 1
fi

if [[ ! -f "$KERNEL_PATH" ]]; then
  echo "kernel not found: $KERNEL_PATH" >&2
  exit 1
fi

BUILD_DIR="$ROOT_DIR/build/$ARCH"
WORK_DIR="$BUILD_DIR/work"
mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

# --- Step 1: Build or copy EROFS rootfs ---

if [[ -n "$ROOTFS_EROFS_PATH" ]]; then
  echo "==> Using pre-built rootfs.erofs: $ROOTFS_EROFS_PATH"
  if [[ ! -f "$ROOTFS_EROFS_PATH" ]]; then
    echo "rootfs.erofs not found: $ROOTFS_EROFS_PATH" >&2
    exit 1
  fi
  cp "$ROOTFS_EROFS_PATH" "$WORK_DIR/rootfs.erofs"
else
  echo "==> Building EROFS rootfs"
  "$SCRIPT_DIR/build-erofs-rootfs.sh" \
    --output "$WORK_DIR/rootfs.erofs" \
    --arch "$ARCH" \
    --compression "$EROFS_COMPRESSION"
fi

# --- Step 2: Copy kernel ---

echo "==> Copying kernel"
cp "$KERNEL_PATH" "$WORK_DIR/kernel"

# --- Step 3: Generate manifest (schema v6) ---

KERNEL_SHA256="$(shasum -a 256 "$WORK_DIR/kernel" | awk '{print $1}')"
ROOTFS_EROFS_SHA256="$(shasum -a 256 "$WORK_DIR/rootfs.erofs" | awk '{print $1}')"
BUILT_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo "==> Generating manifest.json (schema v6)"
cat > "$WORK_DIR/manifest.json" <<EOF
{
  "schema_version": 6,
  "asset_version": "${VERSION}",
  "arch": "${ARCH}",
  "kernel_version": "${KERNEL_VERSION}",
  "kernel_sha256": "${KERNEL_SHA256}",
  "rootfs_erofs_sha256": "${ROOTFS_EROFS_SHA256}",
  "kernel_cmdline": "console=hvc0 root=/dev/vda ro rootfstype=erofs earlycon",
  "built_at": "${BUILT_AT}",
  "source_repo": "${SOURCE_REPO}",
  "source_ref": "${SOURCE_REF}",
  "source_sha": "${SOURCE_SHA}"
}
EOF

# --- Step 4: Package tarball ---

TARBALL="boot-assets-${ARCH}-v${VERSION}.tar.gz"

echo "==> Packaging tarball"
tar -czf "$OUTPUT_DIR/$TARBALL" -C "$WORK_DIR" \
  kernel rootfs.erofs manifest.json
shasum -a 256 "$OUTPUT_DIR/$TARBALL" > "$OUTPUT_DIR/$TARBALL.sha256"
cp "$WORK_DIR/manifest.json" "$OUTPUT_DIR/manifest.json"

TARBALL_SIZE="$(ls -lh "$OUTPUT_DIR/$TARBALL" | awk '{print $5}')"
KERNEL_SIZE="$(ls -lh "$WORK_DIR/kernel" | awk '{print $5}')"
ROOTFS_SIZE="$(ls -lh "$WORK_DIR/rootfs.erofs" | awk '{print $5}')"

echo ""
echo "========================================"
echo "  Boot Assets v${VERSION} (schema v6)"
echo "========================================"
echo ""
echo "  Tarball:  $OUTPUT_DIR/$TARBALL ($TARBALL_SIZE)"
echo "  Kernel:   $KERNEL_SIZE"
echo "  Rootfs:   $ROOTFS_SIZE (EROFS, $EROFS_COMPRESSION)"
echo "  Manifest: schema_version 6"
echo ""
echo "  Checksum: $OUTPUT_DIR/$TARBALL.sha256"
echo "  Manifest: $OUTPUT_DIR/manifest.json"
echo ""
