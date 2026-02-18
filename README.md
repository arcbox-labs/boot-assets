# ArcBox Boot Assets

`boot-assets` is the single source of truth for ArcBox VM boot artifacts.

Each release publishes:

1. `boot-assets-arm64-v{version}.tar.gz`
2. `boot-assets-arm64-v{version}.tar.gz.sha256`
3. `manifest.json`

The tarball contains:

1. `kernel`
2. `initramfs.cpio.gz`
3. `manifest.json`

## Runtime Consumption

ArcBox downloads boot assets from GitHub Releases:

1. Repository: `arcbox-labs/boot-assets`
2. Tag format: `v{version}`
3. Version is selected by `ARCBOX_BOOT_ASSET_VERSION` or ArcBox default

## Build And Release

### CI release workflow

Workflow file: `.github/workflows/release.yml`

Trigger:

1. Push tag: `v*`
2. Manual dispatch with explicit version

### Local build

Prerequisites:

1. Rust toolchain with `aarch64-unknown-linux-musl`
2. `unsquashfs`, `cpio`, `curl`, `shasum`, `tar`
3. ArcBox source checkout (for building `arcbox-agent`)

Example:

```bash
# In boot-assets repo
chmod +x scripts/*.sh

./scripts/build-release.sh \
  --version 0.0.1-alpha.3 \
  --arcbox-dir ../arcbox \
  --arcbox-repo AprilNEA/ArcBox \
  --arcbox-ref master
```

Output files are written to `dist/`.

## Notes

1. Base assets are fetched from Alpine `alpine-netboot` tarball.
2. Download step validates tarball SHA256 from Alpine `latest-releases.yaml`.
3. `initramfs.cpio.gz` is rebuilt with `arcbox-agent` injected.
4. `manifest.json` records source repository/ref/sha and artifact checksums.
