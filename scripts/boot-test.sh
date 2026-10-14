#!/usr/bin/env bash
# Boots a kernel in a specific Firecracker binary and checks that the guest sees
# what a RenderOps sandbox needs. Linux with /dev/kvm only (GitHub's Ubuntu
# runners have KVM).
#
#   scripts/boot-test.sh <vmlinux> <firecracker binary>
#
# The guest is a tiny busybox initramfs, not the RenderOps rootfs: it checks for
# a virtio disk, virtio network, vsock, overlayfs, cgroup2 and both of its 2 vCPUs,
# prints one line
# per check, then reboots, which makes Firecracker exit. Template builds test the
# full guest (rootfs, guest agent) on top of a runtime that passed this.
#
# Env: BUSYBOX (static busybox binary, default: busybox on PATH),
#      BOOT_TIMEOUT (seconds, default 60)
set -euo pipefail

KERNEL="${1:?usage: boot-test.sh <vmlinux> <firecracker>}"
FIRECRACKER="${2:?usage: boot-test.sh <vmlinux> <firecracker>}"
BUSYBOX="${BUSYBOX:-$(command -v busybox || true)}"
TIMEOUT="${BOOT_TIMEOUT:-60}"
TAP="fcboot$$"

die() {
	echo "error: $*" >&2
	exit 1
}

test -f "$KERNEL" || die "kernel not found: $KERNEL"
test -x "$FIRECRACKER" || die "firecracker not executable: $FIRECRACKER"
[ -n "$BUSYBOX" ] && test -f "$BUSYBOX" || die "static busybox required (apt install busybox-static)"
test -w /dev/kvm || die "/dev/kvm is not writable by $(id -un)"
for tool in cpio gzip ip timeout; do
	command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done
SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

WORK="$(mktemp -d)"
cleanup() {
	$SUDO ip link del "$TAP" 2>/dev/null || true # absent when setup failed early
	rm -rf "$WORK"
}
trap cleanup EXIT

# --- guest: busybox initramfs whose /init runs the checks ---------------------
ROOT="$WORK/initramfs"
mkdir -p "$ROOT/bin" "$ROOT/dev" "$ROOT/proc" "$ROOT/sys" "$ROOT/mnt"
cp "$BUSYBOX" "$ROOT/bin/busybox"
for applet in sh mount mkdir cat grep test echo reboot; do
	ln -s busybox "$ROOT/bin/$applet"
done
cat >"$ROOT/init" <<'INIT'
#!/bin/busybox sh
export PATH=/bin
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
failed=0
check() {
	name="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		echo "BOOT_CHECK ok   $name"
	else
		echo "BOOT_CHECK FAIL $name"
		failed=1
	fi
}
# Virtio device ids: 0x0001 net, 0x0002 block, 0x0013 vsock. These only appear
# if the kernel understood how Firecracker announced the devices.
has_virtio() { grep -qx "$1" /sys/bus/virtio/devices/*/device; }
check virtio-net has_virtio 0x0001
check virtio-blk has_virtio 0x0002
check virtio-vsock has_virtio 0x0013
check disk-vda test -b /dev/vda
check eth0 test -e /sys/class/net/eth0
mkdir -p /mnt/t
mount -t tmpfs t /mnt/t
mkdir -p /mnt/t/lower /mnt/t/upper /mnt/t/work /mnt/t/merged
check overlay mount -t overlay o -o lowerdir=/mnt/t/lower,upperdir=/mnt/t/upper,workdir=/mnt/t/work /mnt/t/merged
mkdir -p /mnt/cgroup
check cgroup2 mount -t cgroup2 none /mnt/cgroup
# The VM is started with 2 vCPUs; the guest must bring both up.
check cpus-2 test "$(grep -c '^processor' /proc/cpuinfo)" -eq 2
echo "BOOT_KERNEL $(cat /proc/sys/kernel/osrelease)"
if [ "$failed" -eq 0 ]; then echo BOOT_TEST_PASS; else echo BOOT_TEST_FAIL; fi
reboot -f
INIT
chmod 0755 "$ROOT/init"
(cd "$ROOT" && find . | cpio -o -H newc --quiet) | gzip -9 >"$WORK/initramfs.cpio.gz"

# --- devices the guest must find ----------------------------------------------
truncate -s 16M "$WORK/disk.img"
$SUDO ip tuntap add dev "$TAP" mode tap user "$(id -un)"
$SUDO ip link set "$TAP" up

cat >"$WORK/config.json" <<CONFIG
{
  "boot-source": {
    "kernel_image_path": "$KERNEL",
    "initrd_path": "$WORK/initramfs.cpio.gz",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off"
  },
  "drives": [
    { "drive_id": "data", "path_on_host": "$WORK/disk.img", "is_root_device": false, "is_read_only": false }
  ],
  "network-interfaces": [
    { "iface_id": "eth0", "guest_mac": "06:00:AC:10:00:02", "host_dev_name": "$TAP" }
  ],
  "vsock": { "guest_cid": 3, "uds_path": "$WORK/vsock.sock" },
  "machine-config": { "vcpu_count": 2, "mem_size_mib": 256 }
}
CONFIG

# --- boot -------------------------------------------------------------------
echo "==> booting $(basename "$KERNEL") with $("$FIRECRACKER" --version | head -1)"
status=0
timeout "$TIMEOUT" "$FIRECRACKER" --no-api --config-file "$WORK/config.json" >"$WORK/console.log" 2>&1 || status=$?

grep -E '^(BOOT_CHECK|BOOT_KERNEL)' "$WORK/console.log" || true
if grep -qx 'BOOT_TEST_PASS' <(tr -d '\r' <"$WORK/console.log"); then
	echo "boot test passed"
	exit 0
fi
if [ "$status" -eq 124 ]; then
	echo "boot test failed: no result within ${TIMEOUT}s" >&2
else
	echo "boot test failed (firecracker exit $status)" >&2
fi
echo "--- last console lines ---" >&2
tail -40 "$WORK/console.log" >&2
exit 1
