#!/usr/bin/env bash
# build-rootfs.sh — Build rootfs.squashfs for the ArcBox guest VM.
#
# This is the Stage 2 root filesystem image. Stage 1 (the minimal initramfs)
# mounts this squashfs image via an overlay and switches root to it. Because
# the root is a proper tmpfs-backed overlay (not the initramfs ramfs), kernel
# constraints on pivot_root are satisfied and container OCI runtimes work
# correctly.
#
# Contents:
#   - Alpine Linux minirootfs as the base userspace (busybox, sh, etc.)
#   - arcbox-agent binary
#   - Stage 2 /init script (network, NTP, cgroups, Docker storage, agent)
#   - All required mount points
#
# Note: kernel modules are NOT included here. Stage 1 loads all needed
# modules before switch_root; they remain loaded in the kernel after the
# root switch.
set -euo pipefail

AGENT_BIN=""
ALPINE_MINIROOTFS=""
OUTPUT=""

usage() {
  cat <<'EOF'
Usage: build-rootfs.sh [options]

Required options:
  --agent-bin <path>          Path to arcbox-agent binary (aarch64-linux-musl)
  --alpine-minirootfs <path>  Path to Alpine minirootfs tarball
  --output <path>             Output path for rootfs.squashfs
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent-bin)
      AGENT_BIN="$2"
      shift 2
      ;;
    --alpine-minirootfs)
      ALPINE_MINIROOTFS="$2"
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

if [[ -z "$AGENT_BIN" || -z "$ALPINE_MINIROOTFS" || -z "$OUTPUT" ]]; then
  usage >&2
  exit 1
fi

for file in "$AGENT_BIN" "$ALPINE_MINIROOTFS"; do
  if [[ ! -f "$file" ]]; then
    echo "required file not found: $file" >&2
    exit 1
  fi
done

if ! command -v mksquashfs >/dev/null 2>&1; then
  echo "mksquashfs is required but not found in PATH (install: brew install squashfs)" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d /tmp/arcbox-rootfs.XXXXXX)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Extract Alpine minirootfs as the base userspace.
# ---------------------------------------------------------------------------
echo "extract Alpine minirootfs: $ALPINE_MINIROOTFS"
tar -xzf "$ALPINE_MINIROOTFS" -C "$WORK_DIR" 2>/dev/null

# ---------------------------------------------------------------------------
# Install iptables into the rootfs.
# Required for dockerd to install POSTROUTING MASQUERADE rules that allow
# container traffic (172.17.0.0/16) to reach the internet via eth0.
#
# Primary path: docker run alpine apk add iptables (Linux runners with Docker).
# Fallback path: Python APK extraction (macOS runners / local dev without Docker).
# ---------------------------------------------------------------------------
echo "install iptables into rootfs"
_ALPINE_VER="${ALPINE_VERSION:-3.21}"
_REPO_URL="https://dl-cdn.alpinelinux.org/alpine/v${_ALPINE_VER}/main/aarch64"

if command -v docker >/dev/null 2>&1; then
  echo "  using Docker to install iptables (libmnl libnftnl iptables)"
  # Run apk add inside an Alpine container with the rootfs mounted.
  # On the ARM64 CI runner (ubuntu-24.04-arm) this runs natively; on macOS
  # with Docker Desktop / colima, Docker handles the platform transparently.
  # Run as the current user so extracted files are host-user-owned and the
  # cleanup trap (rm -rf "$WORK_DIR") can remove them without sudo.
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    -v "${WORK_DIR}:/rootfs" \
    "alpine:${_ALPINE_VER}" \
    apk add --no-cache \
      --root /rootfs \
      --no-scripts \
      --allow-untrusted \
      --initdb \
      -X "${_REPO_URL}" \
      libmnl libnftnl iptables || {
    echo "docker apk add failed" >&2
    exit 1
  }
else
  echo "  Docker not available; using Python APK extraction (fallback)"
  python3 - "$WORK_DIR" "$_REPO_URL" <<'PYEOF'
import sys, io, gzip, tarfile, zlib, struct, urllib.request, urllib.error

destdir  = sys.argv[1]
repo_url = sys.argv[2]
# Packages required for iptables to run inside the ArcBox guest VM.
# iptables: firewall tool used by dockerd for MASQUERADE/NAT rules.
# libmnl:   lightweight netlink library (runtime dep of iptables).
# libnftnl: netfilter nftables library  (runtime dep of iptables).
packages = ["libmnl", "libnftnl", "iptables"]

def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "arcbox-build/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.read()
    except urllib.error.URLError as e:
        print(f"ERROR: cannot fetch {url}: {e}", file=sys.stderr)
        sys.exit(1)

def parse_apkindex(raw):
    """Parse Alpine APKINDEX text into {package_name: version} dict."""
    versions, entry = {}, {}
    for line in raw.decode("utf-8").splitlines():
        if not line:
            if "P" in entry and "V" in entry:
                versions[entry["P"]] = entry["V"]
            entry = {}
        elif ":" in line:
            k, _, v = line.partition(":")
            entry[k] = v
    if "P" in entry and "V" in entry:
        versions[entry["P"]] = entry["V"]
    return versions

def apk_data_offset(apk_bytes):
    """
    Return byte offset of the data tar.gz stream within an Alpine APK file.
    Alpine APK = concatenated gzip streams: [sig.gz?] + control.tar.gz + data.tar.gz.
    Uses raw-deflate decompressobj (wbits=-15) to track exact stream boundaries
    without the read-ahead buffering that affects the high-level gzip module.
    """
    last, pos = 0, 0
    while pos + 10 <= len(apk_bytes):
        if apk_bytes[pos:pos+2] != b'\x1f\x8b':
            break
        flg, p = apk_bytes[pos + 3], pos + 10
        if flg & 4:   # FEXTRA: skip extra field
            p += 2 + struct.unpack_from('<H', apk_bytes, p)[0]
        if flg & 8:   # FNAME: skip null-terminated filename
            while p < len(apk_bytes) and apk_bytes[p]: p += 1
            p += 1
        if flg & 16:  # FCOMMENT: skip null-terminated comment
            while p < len(apk_bytes) and apk_bytes[p]: p += 1
            p += 1
        if flg & 2:   # FHCRC: skip header CRC16
            p += 2
        d = zlib.decompressobj(wbits=-15)
        try:
            d.decompress(apk_bytes[p:])
            # d.unused_data = 8-byte gzip footer (CRC32+ISIZE) + remaining streams.
            footer_start = len(apk_bytes) - len(d.unused_data)
            last, pos = pos, footer_start + 8
        except zlib.error:
            break
    return last

def extract_apk(apk_bytes, destdir):
    """Extract package data files from an Alpine APK into destdir."""
    off = apk_data_offset(apk_bytes)
    with gzip.open(io.BytesIO(apk_bytes[off:])) as gz:
        with tarfile.open(fileobj=gz) as tar:
            members = [m for m in tar.getmembers() if not m.name.startswith(".")]
            try:
                # Python 3.12+: filter="fully_trusted" suppresses DeprecationWarning.
                tar.extractall(destdir, members=members, filter="fully_trusted")
            except TypeError:
                # Python < 3.12 does not accept the filter parameter.
                tar.extractall(destdir, members=members)

print("  downloading Alpine package index...")
idx_gz = fetch(f"{repo_url}/APKINDEX.tar.gz")
with gzip.open(io.BytesIO(idx_gz)) as gz:
    with tarfile.open(fileobj=gz) as t:
        idx_member = next((m for m in t.getmembers() if m.name == "APKINDEX"), None)
        if not idx_member:
            print("ERROR: APKINDEX not found in APKINDEX.tar.gz", file=sys.stderr)
            sys.exit(1)
        versions = parse_apkindex(t.extractfile(idx_member).read())

for pkg in packages:
    ver = versions.get(pkg)
    if not ver:
        print(f"ERROR: package '{pkg}' not found in Alpine index", file=sys.stderr)
        sys.exit(1)
    url = f"{repo_url}/{pkg}-{ver}.apk"
    print(f"  installing: {pkg}-{ver}")
    extract_apk(fetch(url), destdir)

print("  iptables packages installed")
PYEOF
fi
unset _ALPINE_VER _REPO_URL

# Force iptables symlinks to use the legacy (xtables) backend.
# Alpine 3.21+ defaults /sbin/iptables → xtables-nft-multi (nftables backend),
# but the ArcBox guest kernel loads xtables modules (ip_tables, iptable_nat) in
# Stage 1 initramfs — not nf_tables. Override the symlinks so dockerd's iptables
# calls use the xtables kernel API directly.
_legacy_bin="$(find "$WORK_DIR" -name "xtables-legacy-multi" -type f 2>/dev/null | head -1)"
if [[ -n "$_legacy_bin" ]]; then
  _bin_dir="$(dirname "$_legacy_bin")"
  for _cmd in iptables iptables-restore iptables-save ip6tables ip6tables-restore ip6tables-save; do
    ln -sfn xtables-legacy-multi "$_bin_dir/$_cmd"
  done
  echo "iptables → xtables-legacy-multi (legacy xtables backend)"
else
  echo "warning: xtables-legacy-multi not found; container networking may fail" >&2
fi
unset _legacy_bin _bin_dir _cmd

# ---------------------------------------------------------------------------
# Install arcbox-agent.
# ---------------------------------------------------------------------------
echo "inject arcbox-agent: $AGENT_BIN"
mkdir -p "$WORK_DIR/usr/bin"
cp "$AGENT_BIN" "$WORK_DIR/usr/bin/arcbox-agent"
chmod 755 "$WORK_DIR/usr/bin/arcbox-agent"

# ---------------------------------------------------------------------------
# Create required mount points.
# ---------------------------------------------------------------------------
# /proc, /sys, /dev are moved from Stage 1 into the new root by switch_root,
# so they are already mounted when Stage 2 /init runs.
# The remaining mount points are created here as empty directories.
mkdir -p "$WORK_DIR"/{run,tmp}
mkdir -p "$WORK_DIR/dev/pts"
mkdir -p "$WORK_DIR/arcbox"       # VirtioFS mount (moved from Stage 1)
mkdir -p "$WORK_DIR/host-home"    # VirtioFS home share (mounted in Stage 2)
mkdir -p "$WORK_DIR/var/lib/docker"  # tmpfs for Docker overlay2 storage
mkdir -p "$WORK_DIR/sys/fs/cgroup"   # cgroup2 mount point

# ---------------------------------------------------------------------------
# Install udhcpc DHCP lease handler.
# udhcpc calls this script on bound/renew events to configure the interface.
# ---------------------------------------------------------------------------
mkdir -p "$WORK_DIR/usr/share/udhcpc"
cat > "$WORK_DIR/usr/share/udhcpc/default.script" <<'UDHCPC_EOF'
#!/bin/sh
# udhcpc lease handler: configure interface on DHCP bound/renew events.
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

# ---------------------------------------------------------------------------
# Write the Stage 2 /init script.
# This runs after switch_root and handles all guest OS initialisation.
# At entry point, the following are already available:
#   - /proc, /sys, /dev  (moved from Stage 1 via mount --move)
#   - /arcbox            (VirtioFS mount moved from Stage 1)
#   - All kernel modules already loaded by Stage 1
# ---------------------------------------------------------------------------
cat > "$WORK_DIR/init" <<'INIT_EOF'
#!/bin/sh
# ArcBox Stage 2 init — running inside squashfs+overlay rootfs.
#
# All kernel modules have been loaded by Stage 1 before switch_root.
# /proc, /sys, /dev, and /arcbox are already mounted (moved from Stage 1).

/bin/busybox mount -t devpts devpts /dev/pts 2>/dev/null || true
/bin/busybox mkdir -p /var/log /run /tmp
/bin/busybox hostname arcbox-vm

INIT_LOG="/arcbox/init.log"
/bin/busybox touch "$INIT_LOG" 2>/dev/null || INIT_LOG="/var/log/arcbox-init.log"

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

# Mount run/tmp as tmpfs so they have proper write semantics.
/bin/busybox mount -t tmpfs tmpfs /run  2>/dev/null || true
/bin/busybox mount -t tmpfs tmpfs /tmp  2>/dev/null || true

# Mount VirtioFS home share.
if run_cmd /bin/busybox mount -t virtiofs home /host-home; then
  log_line "Home VirtioFS mounted at /host-home"
else
  log_line "Home VirtioFS mount failed (continuing)"
fi

# Bring up loopback; required for processes binding to 127.0.0.1.
/bin/busybox ip link set lo up 2>/dev/null || true

# Configure eth0 via DHCP (VZ framework NAT provides DHCP at 192.168.64.1).
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

# Sync clock via NTP. The guest RTC starts at epoch; without a correct clock
# TLS certificate validation fails. Use numeric IPs to avoid DNS timeout:
# busybox ntpd -q waits for SIGALRM (64s) per server if unreachable; DNS
# lookup for pool.ntp.org can itself timeout causing a multi-minute stall.
#   162.159.200.123  Cloudflare NTP (time.cloudflare.com)
#   17.253.14.251    Apple NTP     (time.apple.com)
log_line "Syncing time via NTP..."
if /bin/busybox ntpd -q -n -p 162.159.200.123 2>/dev/null \
   || /bin/busybox ntpd -q -n -p 17.253.14.251 2>/dev/null \
   || /bin/busybox ntpd -q -n -p pool.ntp.org 2>/dev/null; then
  log_line "  Time: NTP sync ok ($(/bin/busybox date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown))"
else
  log_line "  Time: NTP sync failed (TLS cert verification may fail)"
fi
log_line ""

log_line "ArcBox Guest VM starting (kernel: $(/bin/busybox uname -r))"
log_line "Kernel cmdline: $(/bin/busybox cat /proc/cmdline)"
log_line ""

# Set up cgroup2.
log_line "Setting up container prerequisites..."
if /bin/busybox mount -t cgroup2 cgroup2 /sys/fs/cgroup 2>/dev/null; then
  log_line "  cgroup2 mounted at /sys/fs/cgroup"
else
  log_line "  cgroup2 mount failed (may already be mounted)"
fi

# Mount tmpfs on /var/lib/docker for Docker overlay2 storage.
# Overlay2 requires an upper layer that supports xattrs and d_type; tmpfs
# satisfies both requirements. The squashfs lower layer (read-only) cannot
# serve as an upper layer for Docker's overlay mounts.
if /bin/busybox mount -t tmpfs tmpfs /var/lib/docker -o size=10g; then
  log_line "  tmpfs mounted at /var/lib/docker (overlay2 backing store)"
else
  log_line "  tmpfs mount on /var/lib/docker failed (overlay2 may not work)"
fi
log_line ""

# Log network state for diagnostics.
log_line "Network state:"
/bin/busybox ip addr show >> "$INIT_LOG" 2>&1 || true
/bin/busybox ip route show >> "$INIT_LOG" 2>&1 || true
log_line "DNS config:"
/bin/busybox cat /etc/resolv.conf >> "$INIT_LOG" 2>&1 || true
log_line ""

# Enable IPv4 forwarding so Docker can route between docker0 and eth0.
echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
log_line "IPv4 forwarding: $(/bin/busybox cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo unknown)"
log_line ""

# Make the entire mount tree recursively private.
# pivot_root (used by container OCI runtimes: runc, youki) requires that no
# mount in the parent namespace is shared. This is the standard container-host
# initialisation step (see runc/libcontainer and Docker documentation).
/bin/busybox mount --make-rprivate / 2>/dev/null \
  && log_line "Mount tree: rprivate" \
  || log_line "Mount tree: make-rprivate failed (pivot_root may fail)"

AGENT_LOG="/arcbox/agent.log"
log_line "Starting arcbox-agent..."
log_line "Agent logs: $AGENT_LOG"
/bin/busybox touch "$AGENT_LOG" 2>/dev/null || AGENT_LOG="$INIT_LOG"

while true; do
  /usr/bin/arcbox-agent >> "$AGENT_LOG" 2>&1
  rc=$?
  log_line "arcbox-agent exited (code=$rc), restarting in 1s"
  /bin/busybox sleep 1
done
INIT_EOF
chmod 755 "$WORK_DIR/init"

# ---------------------------------------------------------------------------
# Build squashfs image.
# Use gzip compression: universally supported by Linux kernels and available
# in all Alpine LTS kernel configurations.
# ---------------------------------------------------------------------------
echo "build squashfs: $OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
mksquashfs "$WORK_DIR" "$OUTPUT" \
  -comp gzip \
  -noappend \
  -no-xattrs \
  -info \
  -quiet

echo "rootfs.squashfs ready: $OUTPUT"
ls -lh "$OUTPUT"
