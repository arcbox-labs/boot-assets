#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
export LANG=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION=""
ARCH="arm64"
ALPINE_VERSION="3.21"
ALPINE_FLAVOR="lts"
ARCBOX_DIR=""
ARCBOX_REPO="unknown"
ARCBOX_REF="unknown"
OUTPUT_DIR="$ROOT_DIR/dist"

usage() {
  cat <<'EOF'
Usage: build-release.sh [options]

Required options:
  --version <version>      Asset version (for example: 0.0.1-alpha.3)
  --arcbox-dir <path>      Path to arcbox source tree

Optional:
  --arch <arch>            Target architecture (default: arm64)
  --alpine-version <ver>   Alpine release version (default: 3.21)
  --alpine-flavor <name>   Alpine netboot flavor (default: lts)
  --arcbox-repo <repo>     ArcBox source repository (for manifest)
  --arcbox-ref <ref>       ArcBox source ref (for manifest)
  --output-dir <dir>       Output directory (default: dist/)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --arcbox-dir)
      ARCBOX_DIR="$2"
      shift 2
      ;;
    --arch)
      ARCH="$2"
      shift 2
      ;;
    --alpine-version)
      ALPINE_VERSION="$2"
      shift 2
      ;;
    --alpine-flavor)
      ALPINE_FLAVOR="$2"
      shift 2
      ;;
    --arcbox-repo)
      ARCBOX_REPO="$2"
      shift 2
      ;;
    --arcbox-ref)
      ARCBOX_REF="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
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

if [[ -z "$VERSION" || -z "$ARCBOX_DIR" ]]; then
  usage >&2
  exit 1
fi

if [[ "$ARCH" != "arm64" ]]; then
  echo "unsupported arch: $ARCH (expected: arm64)" >&2
  exit 1
fi

if [[ ! -f "$ARCBOX_DIR/Cargo.toml" ]]; then
  echo "invalid arcbox directory: $ARCBOX_DIR" >&2
  exit 1
fi

TARGET_TRIPLE="aarch64-unknown-linux-musl"
ALPINE_ARCH="aarch64"
RELEASE_BASE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}"
NETBOOT_BASE_URL="${RELEASE_BASE_URL}/netboot"
KERNEL_URL="${NETBOOT_BASE_URL}/vmlinuz-${ALPINE_FLAVOR}"
INITRAMFS_URL="${NETBOOT_BASE_URL}/initramfs-${ALPINE_FLAVOR}"
MODLOOP_URL="${NETBOOT_BASE_URL}/modloop-${ALPINE_FLAVOR}"
NETBOOT_RELEASE_VERSION="unknown"
NETBOOT_FILE="unknown"
NETBOOT_URL="unknown"
NETBOOT_SHA256="unknown"

BUILD_ROOT="$ROOT_DIR/build/$ARCH"
BASE_DIR="$BUILD_ROOT/base"
WORK_DIR="$BUILD_ROOT/work"
mkdir -p "$BASE_DIR" "$WORK_DIR" "$OUTPUT_DIR"

echo "==> download base kernel/initramfs/modloop"
"$SCRIPT_DIR/download-kernel.sh" \
  --arch "$ARCH" \
  --alpine-version "$ALPINE_VERSION" \
  --flavor "$ALPINE_FLAVOR" \
  --out-dir "$BASE_DIR"

if [[ -f "$BASE_DIR/netboot-metadata.env" ]]; then
  # shellcheck disable=SC1090
  source "$BASE_DIR/netboot-metadata.env"
fi

echo "==> build arcbox-agent"
cargo build \
  --manifest-path "$ARCBOX_DIR/Cargo.toml" \
  -p arcbox-agent \
  --target "$TARGET_TRIPLE" \
  --release

AGENT_BIN="$ARCBOX_DIR/target/$TARGET_TRIPLE/release/arcbox-agent"
if [[ ! -f "$AGENT_BIN" ]]; then
  echo "agent binary not found: $AGENT_BIN" >&2
  exit 1
fi

echo "==> build initramfs"
"$SCRIPT_DIR/build-initramfs.sh" \
  --agent-bin "$AGENT_BIN" \
  --base-initramfs "$BASE_DIR/initramfs-${ARCH}" \
  --modloop "$BASE_DIR/modloop-${ALPINE_FLAVOR}" \
  --output "$WORK_DIR/initramfs.cpio.gz"

cp "$BASE_DIR/vmlinuz-${ARCH}" "$WORK_DIR/kernel"

KERNEL_SHA256="$(shasum -a 256 "$WORK_DIR/kernel" | awk '{print $1}')"
INITRAMFS_SHA256="$(shasum -a 256 "$WORK_DIR/initramfs.cpio.gz" | awk '{print $1}')"
ARCBOX_SHA="$(git -C "$ARCBOX_DIR" rev-parse HEAD)"
BUILT_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

cat > "$WORK_DIR/manifest.json" <<EOF
{
  "schema_version": 1,
  "asset_version": "${VERSION}",
  "arch": "${ARCH}",
  "alpine_branch_version": "${ALPINE_VERSION}",
  "alpine_netboot_version": "${NETBOOT_RELEASE_VERSION}",
  "netboot_bundle_file": "${NETBOOT_FILE}",
  "netboot_bundle_url": "${NETBOOT_URL}",
  "netboot_bundle_sha256": "${NETBOOT_SHA256}",
  "kernel_sha256": "${KERNEL_SHA256}",
  "initramfs_sha256": "${INITRAMFS_SHA256}",
  "kernel_source_url": "${KERNEL_URL}",
  "initramfs_source_url": "${INITRAMFS_URL}",
  "modloop_source_url": "${MODLOOP_URL}",
  "kernel_commit": null,
  "agent_commit": "${ARCBOX_SHA}",
  "built_at": "${BUILT_AT}",
  "kernel_cmdline": "console=hvc0 rdinit=/init quiet",
  "source_repo": "${ARCBOX_REPO}",
  "source_ref": "${ARCBOX_REF}",
  "source_sha": "${ARCBOX_SHA}"
}
EOF

TARBALL="boot-assets-${ARCH}-v${VERSION}.tar.gz"

echo "==> package tarball"
tar -czf "$OUTPUT_DIR/$TARBALL" -C "$WORK_DIR" kernel initramfs.cpio.gz manifest.json
shasum -a 256 "$OUTPUT_DIR/$TARBALL" > "$OUTPUT_DIR/$TARBALL.sha256"
cp "$WORK_DIR/manifest.json" "$OUTPUT_DIR/manifest.json"

echo "build complete"
echo "tarball:   $OUTPUT_DIR/$TARBALL"
echo "checksum:  $OUTPUT_DIR/$TARBALL.sha256"
echo "manifest:  $OUTPUT_DIR/manifest.json"
