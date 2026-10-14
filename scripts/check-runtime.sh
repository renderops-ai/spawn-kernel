#!/usr/bin/env bash
# Fails unless a kernel .config fits the Firecracker version it will run under.
#
#   scripts/check-runtime.sh path/to/.config <firecracker version, e.g. v1.7.0>
#
# Runs the general guest checks (check-config.sh) plus rules that depend on the
# Firecracker version. Add a rule here whenever a pairing problem is found.
set -euo pipefail

config="${1:?usage: check-runtime.sh <path to .config> <firecracker version>}"
fc_version="${2:?usage: check-runtime.sh <path to .config> <firecracker version>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ "$fc_version" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] ||
	{ echo "firecracker version must look like v1.7.0, got $fc_version" >&2; exit 1; }
major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"

"$SCRIPT_DIR/check-config.sh" "$config"

require() {
	if ! grep -qx "CONFIG_$1=y" "$config"; then
		echo "missing for firecracker $fc_version: CONFIG_$1=y ($2)" >&2
		exit 1
	fi
}

# Boot style: before v1.8 Firecracker announces virtio devices on the kernel
# command line and describes vCPUs in an MP table; from v1.8 it describes both
# in ACPI tables.
if [ "$major" -eq 1 ] && [ "$minor" -lt 8 ]; then
	require VIRTIO_MMIO_CMDLINE_DEVICES "devices are announced on the kernel command line"
	require X86_MPPARSE "vCPUs are described in an MP table"
else
	if ! grep -qx "CONFIG_ACPI=y" "$config" && ! grep -qx "CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES=y" "$config"; then
		echo "missing for firecracker $fc_version: CONFIG_ACPI=y or CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES=y" >&2
		exit 1
	fi
fi

echo "runtime check passed: $config with firecracker $fc_version"
