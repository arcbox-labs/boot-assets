#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
export LANG=C

ARCH="arm64"
ALPINE_VERSION="3.21"
FLAVOR="lts"
OUT_DIR=""

usage() {
  cat <<'EOF'
Usage: download-kernel.sh [options]

Options:
  --arch <arch>               Target architecture (only: arm64)
  --alpine-version <version>  Alpine release version (default: 3.21)
  --flavor <flavor>           Netboot flavor suffix (default: lts)
  --out-dir <dir>             Output directory
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      ARCH="$2"
      shift 2
      ;;
    --alpine-version)
      ALPINE_VERSION="$2"
      shift 2
      ;;
    --flavor)
      FLAVOR="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
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

if [[ "$ARCH" != "arm64" ]]; then
  echo "unsupported arch: $ARCH (expected: arm64)" >&2
  exit 1
fi

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$(pwd)/build/${ARCH}/base"
fi

ALPINE_ARCH="aarch64"
RELEASE_BASE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}"
NETBOOT_BASE_URL="${RELEASE_BASE_URL}/netboot"
LATEST_RELEASES_URL="${RELEASE_BASE_URL}/latest-releases.yaml"

mkdir -p "$OUT_DIR"

download_file() {
  local url="$1"
  local output="$2"
  echo "download: $url"
  curl -fL --retry 3 --retry-delay 2 --retry-connrefused -o "$output" "$url"
}

sha256_file() {
  local file="$1"
  shasum -a 256 "$file" | awk '{print $1}'
}

NETBOOT_METADATA_FILE="$(mktemp /tmp/boot-assets-netboot-metadata.XXXXXX)"
cleanup() {
  rm -f "$NETBOOT_METADATA_FILE"
}
trap cleanup EXIT

download_file "$LATEST_RELEASES_URL" "$NETBOOT_METADATA_FILE"

NETBOOT_VERSION=""
NETBOOT_FILE=""
NETBOOT_SHA256=""

while IFS='=' read -r key value; do
  case "$key" in
    version) NETBOOT_VERSION="$value" ;;
    file) NETBOOT_FILE="$value" ;;
    sha256) NETBOOT_SHA256="$value" ;;
  esac
done < <(
  awk '
function emit() {
  if (flavor == "alpine-netboot") {
    print "version=" version;
    print "file=" file;
    print "sha256=" sha256;
  }
}
/^-/ {
  emit();
  flavor = "";
  version = "";
  file = "";
  sha256 = "";
  next;
}
/^[[:space:]]+flavor:/ { flavor = $2; next }
/^[[:space:]]+version:/ { version = $2; next }
/^[[:space:]]+file:/ { file = $2; next }
/^[[:space:]]+sha256:/ { sha256 = $2; next }
END { emit() }
' "$NETBOOT_METADATA_FILE"
)

if [[ -z "$NETBOOT_VERSION" || -z "$NETBOOT_FILE" || -z "$NETBOOT_SHA256" ]]; then
  echo "failed to resolve alpine-netboot metadata from: $LATEST_RELEASES_URL" >&2
  exit 1
fi

NETBOOT_URL="${RELEASE_BASE_URL}/${NETBOOT_FILE}"
NETBOOT_TARBALL="$OUT_DIR/$NETBOOT_FILE"

if [[ -f "$NETBOOT_TARBALL" ]]; then
  CURRENT_SHA256="$(sha256_file "$NETBOOT_TARBALL")"
  if [[ "$CURRENT_SHA256" == "$NETBOOT_SHA256" ]]; then
    echo "skip (cached netboot bundle): $NETBOOT_TARBALL"
  else
    echo "cached netboot bundle checksum mismatch, re-downloading"
    rm -f "$NETBOOT_TARBALL"
    download_file "$NETBOOT_URL" "$NETBOOT_TARBALL"
  fi
else
  download_file "$NETBOOT_URL" "$NETBOOT_TARBALL"
fi

CURRENT_SHA256="$(sha256_file "$NETBOOT_TARBALL")"
if [[ "$CURRENT_SHA256" != "$NETBOOT_SHA256" ]]; then
  echo "netboot bundle checksum mismatch: expected $NETBOOT_SHA256, got $CURRENT_SHA256" >&2
  exit 1
fi
echo "verified netboot bundle sha256: $CURRENT_SHA256"

extract_member() {
  local member="$1"
  local output="$2"
  echo "extract: $member -> $output"
  if ! tar -xzf "$NETBOOT_TARBALL" -O "$member" > "$output"; then
    rm -f "$output"
    echo "failed to extract $member from $NETBOOT_TARBALL" >&2
    exit 1
  fi
}

extract_member "boot/vmlinuz-${FLAVOR}" "$OUT_DIR/vmlinuz-${ARCH}"
extract_member "boot/initramfs-${FLAVOR}" "$OUT_DIR/initramfs-${ARCH}"
extract_member "boot/modloop-${FLAVOR}" "$OUT_DIR/modloop-${FLAVOR}"

KERNEL_URL="${NETBOOT_BASE_URL}/vmlinuz-${FLAVOR}"
INITRAMFS_URL="${NETBOOT_BASE_URL}/initramfs-${FLAVOR}"
MODLOOP_URL="${NETBOOT_BASE_URL}/modloop-${FLAVOR}"

cat > "$OUT_DIR/netboot-metadata.env" <<EOF
NETBOOT_BRANCH_VERSION=${ALPINE_VERSION}
NETBOOT_RELEASE_VERSION=${NETBOOT_VERSION}
NETBOOT_FILE=${NETBOOT_FILE}
NETBOOT_URL=${NETBOOT_URL}
NETBOOT_SHA256=${NETBOOT_SHA256}
NETBOOT_FLAVOR=${FLAVOR}
KERNEL_URL=${KERNEL_URL}
INITRAMFS_URL=${INITRAMFS_URL}
MODLOOP_URL=${MODLOOP_URL}
EOF

echo "kernel:    $OUT_DIR/vmlinuz-${ARCH}"
echo "initramfs: $OUT_DIR/initramfs-${ARCH}"
echo "modloop:   $OUT_DIR/modloop-${FLAVOR}"
echo "metadata:  $OUT_DIR/netboot-metadata.env"
