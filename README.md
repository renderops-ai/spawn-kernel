# renderops-kernels

Builds the Linux guest kernel (`vmlinux`) that RenderOps sandboxes boot in
Firecracker. The sandbox platform repo pins one published kernel by version and
sha256; this repo is where those kernels come from.

## What goes into a kernel

| Piece | Where | What |
|---|---|---|
| Source | `kernel_versions.txt` | Pinned [amazonlinux/linux](https://github.com/amazonlinux/linux) `microvm-kernel-*` tag (the source Firecracker's and E2B's kernels use) |
| Base config | `configs/x86_64/<version>.config` | Full config from E2B (see `NOTICE`). Already includes Docker support |
| Our changes | `fragments/*.config` | Short list of RenderOps-specific options on top of the base |

`build.sh` merges base + fragments, runs `olddefconfig`, fails if a fragment
line was dropped, runs `scripts/check-config.sh`, then compiles `vmlinux`.

`scripts/check-config.sh` requires, as built-in (`=y`, no modules):

- **Guest boot:** initramfs (gzip), virtio mmio/blk/net, vsock, ext4, overlay, devtmpfs, tmpfs, ptys, cgroups.
- **Docker:** namespaces, cgroup controllers, keys, seccomp, veth, bridge + br_netfilter, conntrack/NAT, nftables and iptables tables.

## Build

On an x86_64 Linux host (Ubuntu: `apt install bc bison build-essential dwarves flex libelf-dev libssl-dev`):

```sh
make check                      # check stored configs (any OS)
CONFIG_ONLY=1 ./build.sh        # fetch source, resolve + check config, no compile
RENDEROPS_BUILD=1 ./build.sh    # full build -> dist/vmlinux-6.1.182-renderops.1/
```

Output: `dist/vmlinux-<version>-renderops.<build>/` with `vmlinux`, `config`, `SHA256SUMS`.

## Release

GitHub Actions → **Build kernel** → run with `version`, `build`, `publish: true`.
It publishes release `vmlinux-<version>-renderops.<build>` with the binary,
its `.config` and `SHA256SUMS`. Releases are never replaced; to change a kernel,
bump the build number. Pull requests that touch configs only resolve and check
the config.

## Changing the kernel

- **Turn an option on or off:** add it to `fragments/renderops.config`, bump the build number.
- **New patch release** (e.g. 6.1.188): add the version + tag to `kernel_versions.txt`,
  seed `configs/x86_64/<new>.config` from the previous version (or E2B's matching config),
  run `CONFIG_ONLY=1 ./build.sh <new>` and review the resolved config in `dist/`.

After publishing, the platform repo updates its pinned kernel version + sha256;
workers rebuild their snapshot templates because the kernel digest changes.
