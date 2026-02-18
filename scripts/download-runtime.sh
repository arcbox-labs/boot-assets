#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
export LANG=C

ARCH="arm64"
DOCKER_VERSION="28.0.3"
DOCKER_SHA256="6a5fe587e1224871a87ef46dede1dd65cfb69a2c61e1368556f59c2e78d67d7f"
CONTAINERD_VERSION="1.7.26"
CONTAINERD_SHA256="f35d8eb8467b7875ab768b4b869c9905616d998549e1e0ed993a52eec319dc51"
YOUKI_VERSION="0.5.7"
YOUKI_SHA256="b3002d9d39b04f797e783745f92cffec9e0caa464254be98aa0b4dfc184f0233"
OUT_DIR=""

usage() {
  cat <<'EOF'
Usage: download-runtime.sh [options]

Options:
  --arch <arch>                 Target architecture (only: arm64)
  --docker-version <version>    Docker static bundle version (default: 28.0.3)
  --docker-sha256 <sha256>      Docker static bundle sha256
  --containerd-version <ver>    containerd static bundle version (default: 1.7.26)
  --containerd-sha256 <sha256>  containerd static bundle sha256
  --youki-version <version>     youki version (default: 0.5.7)
  --youki-sha256 <sha256>       youki tarball sha256
  --out-dir <dir>               Output runtime directory (contains bin/)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      ARCH="$2"
      shift 2
      ;;
    --docker-version)
      DOCKER_VERSION="$2"
      shift 2
      ;;
    --docker-sha256)
      DOCKER_SHA256="$2"
      shift 2
      ;;
    --containerd-version)
      CONTAINERD_VERSION="$2"
      shift 2
      ;;
    --containerd-sha256)
      CONTAINERD_SHA256="$2"
      shift 2
      ;;
    --youki-version)
      YOUKI_VERSION="$2"
      shift 2
      ;;
    --youki-sha256)
      YOUKI_SHA256="$2"
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
  OUT_DIR="$(pwd)/build/${ARCH}/base/runtime"
fi

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

verify_checksum() {
  local file="$1"
  local expected="$2"
  local actual
  actual="$(sha256_file "$file")"
  if [[ "$actual" != "$expected" ]]; then
    echo "checksum mismatch for $file: expected $expected, got $actual" >&2
    exit 1
  fi
}

DOCKER_URL="https://download.docker.com/linux/static/stable/aarch64/docker-${DOCKER_VERSION}.tgz"
CONTAINERD_URL="https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-static-${CONTAINERD_VERSION}-linux-arm64.tar.gz"
YOUKI_URL="https://github.com/youki-dev/youki/releases/download/v${YOUKI_VERSION}/youki-${YOUKI_VERSION}-aarch64-musl.tar.gz"

RUNTIME_DIR="$OUT_DIR"
BIN_DIR="$RUNTIME_DIR/bin"
mkdir -p "$BIN_DIR"

WORK_DIR="$(mktemp -d /tmp/boot-assets-runtime.XXXXXX)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

DOCKER_TARBALL="$WORK_DIR/docker-${DOCKER_VERSION}.tgz"
CONTAINERD_TARBALL="$WORK_DIR/containerd-static-${CONTAINERD_VERSION}.tar.gz"
YOUKI_TARBALL="$WORK_DIR/youki-${YOUKI_VERSION}.tar.gz"

download_file "$DOCKER_URL" "$DOCKER_TARBALL"
verify_checksum "$DOCKER_TARBALL" "$DOCKER_SHA256"

download_file "$CONTAINERD_URL" "$CONTAINERD_TARBALL"
verify_checksum "$CONTAINERD_TARBALL" "$CONTAINERD_SHA256"

download_file "$YOUKI_URL" "$YOUKI_TARBALL"
verify_checksum "$YOUKI_TARBALL" "$YOUKI_SHA256"

echo "extract docker static bundle"
mkdir -p "$WORK_DIR/docker-extract"
tar -xzf "$DOCKER_TARBALL" -C "$WORK_DIR/docker-extract"
cp -f "$WORK_DIR/docker-extract/docker/"* "$BIN_DIR/"

echo "extract containerd static bundle"
mkdir -p "$WORK_DIR/containerd-extract"
tar -xzf "$CONTAINERD_TARBALL" -C "$WORK_DIR/containerd-extract"
for bin in containerd containerd-shim-runc-v2 ctr; do
  src="$WORK_DIR/containerd-extract/bin/$bin"
  if [[ ! -f "$src" ]]; then
    echo "required containerd binary missing: $src" >&2
    exit 1
  fi
  cp -f "$src" "$BIN_DIR/$bin"
done

echo "extract youki"
mkdir -p "$WORK_DIR/youki-extract"
tar -xzf "$YOUKI_TARBALL" -C "$WORK_DIR/youki-extract"
if [[ ! -f "$WORK_DIR/youki-extract/youki" ]]; then
  echo "required youki binary missing after extract" >&2
  exit 1
fi
cp -f "$WORK_DIR/youki-extract/youki" "$BIN_DIR/youki"

chmod 755 "$BIN_DIR/"*

RUNTIME_DOCKERD_SHA256="$(sha256_file "$BIN_DIR/dockerd")"
RUNTIME_CONTAINERD_SHA256="$(sha256_file "$BIN_DIR/containerd")"
RUNTIME_YOUKI_SHA256="$(sha256_file "$BIN_DIR/youki")"

cat > "$RUNTIME_DIR/runtime-metadata.env" <<EOF
RUNTIME_DOCKER_VERSION=${DOCKER_VERSION}
RUNTIME_CONTAINERD_VERSION=${CONTAINERD_VERSION}
RUNTIME_YOUKI_VERSION=${YOUKI_VERSION}
RUNTIME_DOCKER_SOURCE_URL=${DOCKER_URL}
RUNTIME_CONTAINERD_SOURCE_URL=${CONTAINERD_URL}
RUNTIME_YOUKI_SOURCE_URL=${YOUKI_URL}
RUNTIME_DOCKER_ARCHIVE_SHA256=${DOCKER_SHA256}
RUNTIME_CONTAINERD_ARCHIVE_SHA256=${CONTAINERD_SHA256}
RUNTIME_YOUKI_ARCHIVE_SHA256=${YOUKI_SHA256}
RUNTIME_DOCKERD_SHA256=${RUNTIME_DOCKERD_SHA256}
RUNTIME_CONTAINERD_SHA256=${RUNTIME_CONTAINERD_SHA256}
RUNTIME_YOUKI_SHA256=${RUNTIME_YOUKI_SHA256}
EOF

echo "runtime bin directory: $BIN_DIR"
echo "metadata:              $RUNTIME_DIR/runtime-metadata.env"
echo "dockerd sha256:        $RUNTIME_DOCKERD_SHA256"
echo "containerd sha256:     $RUNTIME_CONTAINERD_SHA256"
echo "youki sha256:          $RUNTIME_YOUKI_SHA256"
