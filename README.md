# ArcBox Boot Assets

`boot-assets` is the single source of truth for ArcBox VM boot artifacts (schema v6).

Each release publishes:

1. `boot-assets-arm64-v{version}.tar.gz`
2. `boot-assets-arm64-v{version}.tar.gz.sha256`
3. `manifest.json`

The tarball contains:

1. `kernel` — pre-built Linux kernel from [`arcbox-labs/kernel`](https://github.com/arcbox-labs/kernel) (all drivers built-in, `CONFIG_MODULES=n`)
2. `rootfs.erofs` — minimal read-only rootfs (busybox + mkfs.btrfs + iptables-legacy + CA certs)
3. `manifest.json` — schema version 6

No agent binary, no runtime binaries, no initramfs.
Agent and runtime are distributed via VirtioFS from the host.

## Runtime Consumption

ArcBox downloads boot assets from GitHub Releases:

1. Repository: `arcbox-labs/boot-assets`
2. Tag format: `v{version}`
3. Version is selected by `BOOT_ASSET_VERSION` in `arcbox-core`

## Build And Release

### CI release workflow

Workflow file: `.github/workflows/release.yml`

Trigger:

1. Push tag: `v*`
2. Manual dispatch with explicit version

Pipeline stages:

1. **Download kernel** — downloads pre-built ARM64 kernel from [`arcbox-labs/kernel`](https://github.com/arcbox-labs/kernel) release
2. **Build EROFS rootfs** — creates minimal rootfs from Alpine static binaries
3. **Assemble** — packages kernel + rootfs.erofs + manifest.json into tarball
4. **Release** — publishes to GitHub Releases and Cloudflare R2

### Local build

Prerequisites:

1. Docker (for extracting static Alpine binaries)
2. `mkfs.erofs` (`erofs-utils`)
3. Kernel binary from [`arcbox-labs/kernel`](https://github.com/arcbox-labs/kernel) release

```bash
# Download kernel from arcbox-labs/kernel release
gh release download v0.1.0 --repo arcbox-labs/kernel --pattern "kernel-arm64" --dir build/

# Build EROFS rootfs only
./scripts/build-erofs-rootfs.sh --output build/rootfs.erofs

# Full release build
./scripts/build-release.sh \
  --version 0.1.0 \
  --kernel build/kernel-arm64
```

Output files are written to `dist/`.

## EROFS Rootfs Contents

```
/ (EROFS, read-only, LZ4HC compressed)
├── bin/
│   └── busybox          # Static busybox (+ symlinks: sh, mount, mkdir, ...)
├── sbin/
│   ├── init             # Trampoline: mount /proc /sys /dev → mount VirtioFS → exec agent
│   ├── mkfs.btrfs       # Btrfs formatter (first-boot data disk)
│   ├── iptables         # iptables-legacy (Docker bridge networking)
│   └── (symlinks)       # iptables-save, iptables-restore, ip6tables, ...
├── lib/
│   └── ld-musl-*.so.1   # musl libc
├── cacerts/
│   └── ca-certificates.crt
└── (mount points)       # tmp/ run/ proc/ sys/ dev/ mnt/ arcbox/ Users/ etc/ var/
```

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/build-erofs-rootfs.sh` | Build minimal EROFS rootfs from Alpine static binaries |
| `scripts/build-release.sh` | Assemble release tarball (kernel + rootfs.erofs + manifest) |
