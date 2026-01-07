# ArcBox Boot Assets

Pre-built kernel and initramfs for ArcBox VM.

## Contents

| Architecture | Kernel | Initramfs | Total |
|--------------|--------|-----------|-------|
| arm64 | 15 MB | 763 KB | ~16 MB |
| x86_64 | TBD | TBD | TBD |

## Download

Boot assets are distributed via GitHub Releases. ArcBox automatically downloads them on first use.

### Manual Download

```bash
# Using arcbox CLI
arcbox boot prefetch

# Or direct download
curl -LO https://github.com/arcboxd/boot-assets/releases/download/v0.0.1-alpha.2/boot-assets-arm64-v0.0.1-alpha.2.tar.gz
```

## Version Compatibility

| Boot Assets Version | ArcBox Version |
|---------------------|----------------|
| v0.0.1-alpha.2 | 0.0.1-alpha.2+ |

## Building from Source

See [arcbox/tests/resources](https://github.com/arcboxd/arcbox) for build scripts:

```bash
# Download kernel
./download-kernel.sh

# Build agent
cargo build -p arcbox-agent --target aarch64-unknown-linux-musl --release

# Build initramfs
./build-initramfs-minimal.sh
```

## License

- Kernel: GPL-2.0 (Alpine Linux)
- Initramfs: MIT OR Apache-2.0 (ArcBox)
