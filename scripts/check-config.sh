#!/usr/bin/env bash
# Fails unless a kernel .config has everything a RenderOps sandbox needs.
#
#   scripts/check-config.sh path/to/.config
#
# Every option must be built in (=y): the guest rootfs ships no kernel modules.
set -euo pipefail

config="${1:?usage: check-config.sh <path to .config>}"
test -f "$config" || { echo "config not found: $config" >&2; exit 1; }

# Booting the guest: initramfs that mounts the overlay root, virtio disks and
# network, vsock to the guest agent, terminals, cgroups.
boot=(
	BLK_DEV_INITRD RD_GZIP
	VIRTIO_MMIO VIRTIO_BLK VIRTIO_NET
	VSOCKETS VIRTIO_VSOCKETS
	EXT4_FS OVERLAY_FS DEVTMPFS TMPFS UNIX98_PTYS
	CGROUPS MEMCG
)

# Docker inside the sandbox ("Generally Necessary" in moby's
# contrib/check-config.sh, plus seccomp for the default container profile).
# NETFILTER_XT_MATCH_IPVS is left out on purpose: it is only used by Swarm.
docker=(
	NAMESPACES NET_NS PID_NS IPC_NS UTS_NS USER_NS
	CGROUP_CPUACCT CGROUP_DEVICE CGROUP_FREEZER CGROUP_SCHED CGROUP_PIDS CPUSETS
	KEYS POSIX_MQUEUE SECCOMP SECCOMP_FILTER
	VETH BRIDGE BRIDGE_NETFILTER
	NF_CONNTRACK NF_NAT NF_TABLES NFT_COMPAT NFT_NAT NFT_MASQ
	IP_NF_FILTER IP_NF_MANGLE IP_NF_NAT IP_NF_RAW IP_NF_TARGET_MASQUERADE
	IP6_NF_FILTER IP6_NF_MANGLE IP6_NF_NAT IP6_NF_TARGET_MASQUERADE
	NETFILTER_XT_MATCH_ADDRTYPE NETFILTER_XT_MATCH_CONNTRACK NETFILTER_XT_MARK
)

missing=0
check_group() {
	local group="$1"
	shift
	local option
	for option in "$@"; do
		if ! grep -qx "CONFIG_${option}=y" "$config"; then
			echo "missing ($group): CONFIG_${option}=y" >&2
			missing=$((missing + 1))
		fi
	done
}

check_group boot "${boot[@]}"
check_group docker "${docker[@]}"

if grep -q '=m$' "$config"; then
	echo "loadable modules are not allowed (the rootfs has none):" >&2
	grep '=m$' "$config" | head -20 >&2
	missing=$((missing + 1))
fi

if [ "$missing" -gt 0 ]; then
	echo "config check failed: $config ($missing problem(s))" >&2
	exit 1
fi
echo "config check passed: $config"
