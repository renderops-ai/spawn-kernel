# spawn-kernel

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

Output: `dist/vmlinux-<version>-renderops.<build>/` with `vmlinux` (stripped, what workers boot), `vmlinux.debug` (debug info for crash analysis), `config`, `SHA256SUMS`. The build fails if the stripped kernel is over 128 MB.

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

## Runtimes (kernel + Firecracker)

Workers do not consume kernel releases directly. They use a **runtime**: a
kernel release plus the Firecracker version it is proven to work with.

| File | Purpose |
|---|---|
| `runtimes.txt` | `<runtime> <kernel release> <firecracker version>`, e.g. `v1 vmlinux-6.1.182-renderops.3 v1.7.0` |
| `firecracker.lock` | Allowed Firecracker versions and the sha256 of their release tarballs |
| `scripts/check-runtime.sh` | Kernel config rules that depend on the Firecracker version (e.g. before v1.8, devices are announced on the kernel command line and need `CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES=y`) |
| `scripts/boot-test.sh` | Boots the pair in real Firecracker (KVM) with a busybox guest that checks virtio disk, network, vsock, overlay and cgroup2 |
| `scripts/publish-runtime.sh` | Uploads `runtime-releases/<runtime>/{vmlinux,firecracker,config,manifest.json,SHA256SUMS}` to Azure Blob, never overwriting; optionally points `runtime-releases/default.json` at it |

GitHub Actions → **Runtime** → `runtime`, `publish`, `make_default`. Publishing
requires the rules check and the boot test to pass. The `kernel` / `firecracker`
inputs test any other pair without publishing it.

Firecracker's own support table is `docs/kernel-policy.md` in its repository
(per version); its CI kernels per version are a reference config. The boot test
is what decides for us.
