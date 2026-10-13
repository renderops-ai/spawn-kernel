#!/usr/bin/env bash
# Publishes a tested runtime to Azure Blob:
#
#   <container>/runtime-releases/<runtime>/{vmlinux,firecracker,config,manifest.json,SHA256SUMS}
#   <container>/runtime-releases/default.json   (only with --default)
#
#   scripts/publish-runtime.sh <runtime> <dir> [--default]
#
# <dir> holds vmlinux, firecracker, config and manifest.json. Runtime folders are
# never overwritten (identical re-publish is a no-op); default.json is a pointer
# and is replaced. Env: BLOB_STORAGE_ACCOUNT, BLOB_SECRET_KEY, BLOB_CONTAINER_NAME.
set -euo pipefail

RUNTIME="${1:?usage: publish-runtime.sh <runtime> <dir> [--default]}"
DIR="${2:?usage: publish-runtime.sh <runtime> <dir> [--default]}"
MAKE_DEFAULT="${3:-}"
: "${BLOB_STORAGE_ACCOUNT:?BLOB_STORAGE_ACCOUNT required}"
: "${BLOB_SECRET_KEY:?BLOB_SECRET_KEY required}"
: "${BLOB_CONTAINER_NAME:?BLOB_CONTAINER_NAME required}"
[[ "$RUNTIME" =~ ^v[0-9]+$ ]] || { echo "runtime must look like v1, got $RUNTIME" >&2; exit 1; }
PREFIX="runtime-releases/$RUNTIME"

export AZURE_STORAGE_ACCOUNT="$BLOB_STORAGE_ACCOUNT"
export AZURE_STORAGE_KEY="$BLOB_SECRET_KEY"
blob() { az storage blob "$@" --container-name "$BLOB_CONTAINER_NAME" --only-show-errors; }

cd "$DIR"
jq empty manifest.json || { echo "manifest.json is not valid JSON" >&2; exit 1; }
sha256sum vmlinux firecracker config manifest.json >SHA256SUMS

if [ "$(blob exists --name "$PREFIX/SHA256SUMS" --query exists -o tsv)" = "true" ]; then
	blob download --name "$PREFIX/SHA256SUMS" --file SHA256SUMS.remote >/dev/null
	# manifest.json carries the test time, so compare only the runtime's binaries.
	if diff <(grep -v manifest.json SHA256SUMS) <(grep -v manifest.json SHA256SUMS.remote) >/dev/null; then
		blob download --name "$PREFIX/manifest.json" --file manifest.remote.json >/dev/null
		if jq empty manifest.remote.json 2>/dev/null; then
			echo "already published: $PREFIX"
		else
			# Same binaries, unreadable metadata (runtime v1 shipped a \r in it):
			# replace only the manifest and the checksum list.
			blob upload --name "$PREFIX/manifest.json" --file manifest.json --overwrite true >/dev/null
			blob upload --name "$PREFIX/SHA256SUMS" --file SHA256SUMS --overwrite true >/dev/null
			echo "repaired invalid manifest.json in $PREFIX"
		fi
	else
		echo "$PREFIX already exists with different binaries; add a new runtime instead" >&2
		exit 1
	fi
else
	for file in vmlinux firecracker config manifest.json; do
		blob upload --name "$PREFIX/$file" --file "$file" --overwrite false >/dev/null
	done
	# Uploaded last: its presence marks a complete runtime.
	blob upload --name "$PREFIX/SHA256SUMS" --file SHA256SUMS --overwrite false >/dev/null
	echo "published $RUNTIME to $BLOB_CONTAINER_NAME/$PREFIX/"
fi
blob list --prefix "$PREFIX/" --query '[].{name:name, bytes:properties.contentLength}' -o table

if [ "$MAKE_DEFAULT" = "--default" ]; then
	printf '{"runtime":"%s","updated_at":"%s"}\n' "$RUNTIME" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >default.json
	blob upload --name runtime-releases/default.json --file default.json --overwrite true >/dev/null
	echo "runtime-releases/default.json -> $RUNTIME"
fi
