#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
export LANG=C

ARCH="arm64"
ALPINE_VERSION="3.21"
FLAVOR="lts"
OUT_DIR=""
DOWNLOAD_MINIROOTFS="1"

usage() {
  cat <<'EOF'
Usage: download-kernel.sh [options]

Options:
  --arch <arch>               Target architecture (only: arm64)
  --alpine-version <version>  Alpine release version (default: 3.21)
  --flavor <flavor>           Netboot flavor suffix (default: lts)
  --out-dir <dir>             Output directory
  --no-minirootfs             Skip Alpine minirootfs download
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
    --no-minirootfs)
      DOWNLOAD_MINIROOTFS="0"
      shift
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

convert_vmlinuz_to_raw_image() {
  local input="$1"
  local output="$2"
  local input_type
  local output_type

  input_type="$(file -b "$input" 2>/dev/null || true)"
  if [[ "$input_type" == *"Linux kernel ARM64 boot executable Image"* ]]; then
    cp "$input" "$output"
    return
  fi

  if [[ "$input_type" != *"PE32+ executable (EFI application) Aarch64"* ]]; then
    echo "unsupported kernel format: $input_type" >&2
    echo "expected raw ARM64 Image or Alpine EFI-stub vmlinuz" >&2
    exit 1
  fi

  # Alpine netboot vmlinuz-lts is an EFI stub that embeds a gzip stream.
  # Extract and inflate the first gzip stream to recover the raw ARM64 Image.
  python3 - "$input" "$output" <<'PY'
import pathlib
import sys
import zlib

src = pathlib.Path(sys.argv[1]).read_bytes()
offset = src.find(b"\x1f\x8b\x08")
if offset < 0:
    raise SystemExit("failed to locate gzip payload in EFI-stub kernel")

inflater = zlib.decompressobj(wbits=16 + zlib.MAX_WBITS)
raw = inflater.decompress(src[offset:])
if not raw:
    raise SystemExit("failed to inflate gzip payload from EFI-stub kernel")

pathlib.Path(sys.argv[2]).write_bytes(raw)
PY

  output_type="$(file -b "$output" 2>/dev/null || true)"
  if [[ "$output_type" != *"Linux kernel ARM64 boot executable Image"* ]]; then
    echo "converted kernel is not a raw ARM64 Image: $output_type" >&2
    exit 1
  fi
}

NETBOOT_METADATA_FILE="$(mktemp /tmp/boot-assets-netboot-metadata.XXXXXX)"
cleanup() {
  rm -f "$NETBOOT_METADATA_FILE"
}
trap cleanup EXIT

download_file "$LATEST_RELEASES_URL" "$NETBOOT_METADATA_FILE"

# Parse netboot bundle metadata.
NETBOOT_VERSION=""
NETBOOT_FILE=""
NETBOOT_SHA256=""

# Parse minirootfs metadata (used by build-rootfs.sh for Stage 2 rootfs).
MINIROOTFS_VERSION=""
MINIROOTFS_FILE=""
MINIROOTFS_SHA256=""

parse_releases_yaml() {
  local target_flavor="$1"
  awk -v flavor="$target_flavor" '
function emit() {
  if (cur_flavor == flavor) {
    print "version=" cur_version;
    print "file=" cur_file;
    print "sha256=" cur_sha256;
  }
}
/^-/ {
  emit();
  cur_flavor = ""; cur_version = ""; cur_file = ""; cur_sha256 = "";
  next;
}
/^[[:space:]]+flavor:/ { cur_flavor = $2; next }
/^[[:space:]]+version:/ { cur_version = $2; next }
/^[[:space:]]+file:/ { cur_file = $2; next }
/^[[:space:]]+sha256:/ { cur_sha256 = $2; next }
END { emit() }
' "$NETBOOT_METADATA_FILE"
}

while IFS='=' read -r key value; do
  case "$key" in
    version) NETBOOT_VERSION="$value" ;;
    file) NETBOOT_FILE="$value" ;;
    sha256) NETBOOT_SHA256="$value" ;;
  esac
done < <(parse_releases_yaml "alpine-netboot")

while IFS='=' read -r key value; do
  case "$key" in
    version) MINIROOTFS_VERSION="$value" ;;
    file) MINIROOTFS_FILE="$value" ;;
    sha256) MINIROOTFS_SHA256="$value" ;;
  esac
done < <(parse_releases_yaml "alpine-minirootfs")

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
convert_vmlinuz_to_raw_image "$OUT_DIR/vmlinuz-${ARCH}" "$OUT_DIR/kernel-${ARCH}"

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

# ---------------------------------------------------------------------------
# Download Alpine minirootfs (used by build-rootfs.sh to construct Stage 2
# rootfs.squashfs).
# ---------------------------------------------------------------------------
if [[ "$DOWNLOAD_MINIROOTFS" == "1" ]]; then
  if [[ -z "$MINIROOTFS_FILE" || -z "$MINIROOTFS_SHA256" ]]; then
    echo "warning: could not resolve alpine-minirootfs metadata, skipping" >&2
  else
    MINIROOTFS_URL="${RELEASE_BASE_URL}/${MINIROOTFS_FILE}"
    MINIROOTFS_TARBALL="$OUT_DIR/alpine-minirootfs.tar.gz"

    if [[ -f "$MINIROOTFS_TARBALL" ]]; then
      CURRENT_SHA256="$(sha256_file "$MINIROOTFS_TARBALL")"
      if [[ "$CURRENT_SHA256" == "$MINIROOTFS_SHA256" ]]; then
        echo "skip (cached minirootfs): $MINIROOTFS_TARBALL"
      else
        echo "cached minirootfs checksum mismatch, re-downloading"
        rm -f "$MINIROOTFS_TARBALL"
        download_file "$MINIROOTFS_URL" "$MINIROOTFS_TARBALL"
      fi
    else
      download_file "$MINIROOTFS_URL" "$MINIROOTFS_TARBALL"
    fi

    CURRENT_SHA256="$(sha256_file "$MINIROOTFS_TARBALL")"
    if [[ "$CURRENT_SHA256" != "$MINIROOTFS_SHA256" ]]; then
      echo "minirootfs checksum mismatch: expected $MINIROOTFS_SHA256, got $CURRENT_SHA256" >&2
      exit 1
    fi
    echo "verified minirootfs sha256: $CURRENT_SHA256"

    # Append minirootfs metadata to the env file.
    cat >> "$OUT_DIR/netboot-metadata.env" <<EOF
MINIROOTFS_VERSION=${MINIROOTFS_VERSION}
MINIROOTFS_FILE=${MINIROOTFS_FILE}
MINIROOTFS_URL=${MINIROOTFS_URL}
MINIROOTFS_SHA256=${MINIROOTFS_SHA256}
EOF
    echo "minirootfs: $MINIROOTFS_TARBALL"
  fi
fi

echo "kernel:    $OUT_DIR/kernel-${ARCH}"
echo "vmlinuz:   $OUT_DIR/vmlinuz-${ARCH}"
echo "initramfs: $OUT_DIR/initramfs-${ARCH}"
echo "modloop:   $OUT_DIR/modloop-${FLAVOR}"
echo "metadata:  $OUT_DIR/netboot-metadata.env"
