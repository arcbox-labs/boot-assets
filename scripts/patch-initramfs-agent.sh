#!/usr/bin/env bash
# patch-initramfs-agent.sh — hot-patch an existing initramfs with a new agent binary.
#
# Instead of rebuilding the full initramfs from Alpine sources (which requires
# downloading the base initramfs + modloop and takes several minutes via CI),
# this script:
#   1. Extracts an existing initramfs
#   2. Replaces /sbin/arcbox-agent with a locally built binary
#   3. Repacks the initramfs
#
# Typical local dev loop (~20 s with warm Rust cache):
#   cargo build -p arcbox-agent --target aarch64-unknown-linux-musl
#   ./scripts/patch-initramfs-agent.sh \
#       --agent-bin ../../arcbox/target/aarch64-unknown-linux-musl/debug/arcbox-agent \
#       --base ~/.arcbox/boot/0.0.1-alpha.22/initramfs.cpio.gz \
#       --output /tmp/arcbox-initramfs-local.cpio.gz
#   arcbox daemon --initramfs /tmp/arcbox-initramfs-local.cpio.gz --foreground

set -euo pipefail

AGENT_BIN=""
BASE_INITRAMFS=""
OUTPUT=""

usage() {
  cat <<'EOF'
Usage: patch-initramfs-agent.sh [options]

Required options:
  --agent-bin <path>       Path to locally built arcbox-agent binary
  --base <path>            Path to existing initramfs.cpio.gz to patch
  --output <path>          Output path for patched initramfs
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent-bin) AGENT_BIN="$2"; shift 2 ;;
    --base)      BASE_INITRAMFS="$2"; shift 2 ;;
    --output)    OUTPUT="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$AGENT_BIN" || -z "$BASE_INITRAMFS" || -z "$OUTPUT" ]]; then
  usage >&2
  exit 1
fi

for f in "$AGENT_BIN" "$BASE_INITRAMFS"; do
  if [[ ! -f "$f" ]]; then
    echo "file not found: $f" >&2
    exit 1
  fi
done

WORK_DIR="$(mktemp -d /tmp/patch-initramfs.XXXXXX)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

echo "extracting base initramfs: $BASE_INITRAMFS"
(
  cd "$WORK_DIR"
  if ! gunzip -c "$BASE_INITRAMFS" | cpio -idm 2>/dev/null; then
    cpio -idm < "$BASE_INITRAMFS" 2>/dev/null
  fi
)

echo "replacing arcbox-agent: $AGENT_BIN"
cp "$AGENT_BIN" "$WORK_DIR/sbin/arcbox-agent"
chmod 755 "$WORK_DIR/sbin/arcbox-agent"

# Show agent binary info for verification.
file "$WORK_DIR/sbin/arcbox-agent" 2>/dev/null || true

mkdir -p "$(dirname "$OUTPUT")"
echo "repacking initramfs: $OUTPUT"
(
  cd "$WORK_DIR"
  find . | cpio -o -H newc 2>/dev/null | gzip > "$OUTPUT"
)

echo "done: $OUTPUT"
ls -lh "$OUTPUT"
