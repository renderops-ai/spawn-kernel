#!/usr/bin/env bash
# Builds a Firecracker guest kernel (vmlinux) for RenderOps sandboxes.
#
#   ./build.sh                  build every version in kernel_versions.txt
#   ./build.sh 6.1.182          build one version
#   CONFIG_ONLY=1 ./build.sh    stop after the resolved .config passes the checks
#
# Inputs:
#   kernel_versions.txt               version -> pinned amazonlinux/linux tag
#   configs/x86_64/<version>.config   base config (from E2B, see NOTICE)
#   fragments/*.config                RenderOps changes, applied in name order
# Output (in dist/):
#   vmlinux-<version>-renderops.<RENDEROPS_BUILD>/{vmlinux,config,SHA256SUMS}
#
# Linux only: Kconfig probes the host compiler, so build on an x86_64 Linux host.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCH=x86_64
BUILD="${RENDEROPS_BUILD:-1}"
SRC_REPO="${KERNEL_SRC_REPO:-https://github.com/amazonlinux/linux}"
WORK_DIR="$SCRIPT_DIR/work"
DIST_DIR="$SCRIPT_DIR/dist"

die() {
	echo "error: $*" >&2
	exit 1
}

require_tools() {
	local tool
	for tool in git make gcc bc bison flex sha256sum; do
		command -v "$tool" >/dev/null 2>&1 || die "missing build tool: $tool"
	done
}

tag_for() {
	awk -v version="$1" '$1 == version { print $2 }' "$SCRIPT_DIR/kernel_versions.txt"
}

all_versions() {
	awk '!/^#/ && NF { print $1 }' "$SCRIPT_DIR/kernel_versions.txt"
}

# fetch_source clones the pinned tag once and confirms the checkout is that tag.
fetch_source() {
	local tag="$1" src="$2"
	if [ ! -d "$src/.git" ]; then
		echo "==> fetching $tag"
		git clone --quiet --depth 1 --branch "$tag" "$SRC_REPO" "$src"
	fi
	local checked_out
	checked_out="$(git -C "$src" describe --tags --exact-match 2>/dev/null || true)"
	[ "$checked_out" = "$tag" ] || die "$src is at '${checked_out:-unknown}', expected $tag"
}

# verify_fragments fails if olddefconfig dropped or changed a fragment line
# (e.g. an option whose dependencies are not enabled).
verify_fragments() {
	local config="$1"
	shift
	local fragment line failed=0
	for fragment in "$@"; do
		while IFS= read -r line; do
			case "$line" in
			CONFIG_* | "# CONFIG_"*" is not set") ;;
			*) continue ;;
			esac
			if ! grep -qxF "$line" "$config"; then
				echo "fragment line not in final config ($(basename "$fragment")): $line" >&2
				failed=1
			fi
		done <"$fragment"
	done
	[ "$failed" -eq 0 ] || die "fragments were not applied cleanly"
}

build_version() {
	local version="$1"
	local tag base src name out
	tag="$(tag_for "$version")"
	[ -n "$tag" ] || die "version $version is not in kernel_versions.txt"
	base="$SCRIPT_DIR/configs/$ARCH/$version.config"
	[ -f "$base" ] || die "missing base config $base"
	src="$WORK_DIR/src-$tag"
	name="vmlinux-${version}-renderops.${BUILD}"

	fetch_source "$tag" "$src"

	local fragments=("$SCRIPT_DIR"/fragments/*.config)
	echo "==> resolving config: $(basename "$base") + ${#fragments[@]} fragment(s)"
	(cd "$src" && ARCH="$ARCH" scripts/kconfig/merge_config.sh -m "$base" "${fragments[@]}" >/dev/null)
	make -C "$src" ARCH="$ARCH" olddefconfig >/dev/null
	verify_fragments "$src/.config" "${fragments[@]}"
	"$SCRIPT_DIR/scripts/check-config.sh" "$src/.config"

	if [ -n "${CONFIG_ONLY:-}" ]; then
		mkdir -p "$DIST_DIR"
		cp "$src/.config" "$DIST_DIR/$name.config"
		echo "==> resolved config written to dist/$name.config (CONFIG_ONLY)"
		return
	fi

	echo "==> compiling $name"
	make -C "$src" ARCH="$ARCH" vmlinux -j "$(nproc)"

	out="$DIST_DIR/$name"
	rm -rf "$out"
	mkdir -p "$out"
	cp "$src/vmlinux" "$out/vmlinux"
	cp "$src/.config" "$out/config"
	(cd "$out" && sha256sum vmlinux config >SHA256SUMS)
	echo "==> built dist/$name"
	cat "$out/SHA256SUMS"
}

main() {
	[[ "$BUILD" =~ ^[0-9]+$ ]] || die "RENDEROPS_BUILD must be a number, got '$BUILD'"
	require_tools
	mkdir -p "$WORK_DIR"
	local versions=("$@")
	if [ "${#versions[@]}" -eq 0 ]; then
		# Word splitting is intended: one version per line, no spaces.
		# shellcheck disable=SC2207
		versions=($(all_versions))
	fi
	local version
	for version in "${versions[@]}"; do
		build_version "$version"
	done
}

main "$@"
