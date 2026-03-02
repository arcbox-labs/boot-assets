# ArcBox Boot Assets

`boot-assets` is the single source of truth for ArcBox VM boot artifacts.

Each release publishes:

1. `boot-assets-{arch}-v{version}.tar.gz`
2. `boot-assets-{arch}-v{version}.tar.gz.sha256`
3. `manifest.json`

The tarball contains:

1. `kernel`
2. `initramfs.cpio.gz`
3. `rootfs.ext4`
4. `runtime/bin/` (`dockerd`, `containerd`, `youki`, and helper binaries)
5. `bin/arcbox-agent`
6. `manifest.json`

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
2. `protoc` (`protobuf`) for compiling `arcbox-protocol`
3. Docker (used for kernel/rootfs build steps)
4. `cpio`, `curl`, `shasum`, `tar`
5. ArcBox source checkout (for building `arcbox-agent`)

Version selection:

1. `--version` is required.
2. `build-release.sh` does not infer version from ArcBox defaults.
3. Pass the exact boot-asset version you want emitted into tarball/manifest names.

Architecture note:

1. `build-release.sh` accepts `--arch arm64|amd64`.
2. Current `download-runtime.sh` supports only `arm64`, so the default end-to-end flow is arm64.

Example:

```bash
VERSION="$(git -C ../container describe --tags --always --dirty | sed 's/^v//')"

./scripts/build-release.sh \
  --version "$VERSION" \
  --arch arm64 \
  --arcbox-dir ../container \
  --arcbox-repo arcbox-labs/arcbox \
  --arcbox-ref "$(git -C ../container rev-parse --abbrev-ref HEAD)"
```

Output files are written to `dist/`.

Optional runtime version overrides:

```bash
./scripts/build-release.sh \
  --version 0.0.1-alpha.3 \
  --arcbox-dir ../container \
  --docker-version 28.0.3 \
  --containerd-version 1.7.26 \
  --youki-version 0.5.7
```

## Notes

1. Base initramfs is fetched from Alpine `netboot/initramfs-{flavor}` and validated via `latest-releases.yaml`.
2. `initramfs.cpio.gz` is rebuilt.
3. `rootfs.ext4` is built from Alpine in Docker and included in the bundle.
4. `manifest.json` (schema version 4) records source repo/ref/sha, artifact checksums, and `runtime_assets` metadata.
