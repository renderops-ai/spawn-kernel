#!/usr/bin/env bash
# Copies a published kernel to Azure Blob so workers can fetch it by release
# name without GitHub:
#
#   <container>/kernel-release/<release>/{vmlinux,config,SHA256SUMS}
#
#   scripts/mirror-to-blob.sh <release> <dir with vmlinux, config, SHA256SUMS>
#
# Env: BLOB_STORAGE_ACCOUNT, BLOB_SECRET_KEY, BLOB_CONTAINER_NAME.
# Blobs are never overwritten: re-mirroring identical files is a no-op, and a
# release whose files differ from what is already stored fails.
set -euo pipefail

RELEASE="${1:?usage: mirror-to-blob.sh <release> <dir>}"
DIR="${2:?usage: mirror-to-blob.sh <release> <dir>}"
: "${BLOB_STORAGE_ACCOUNT:?BLOB_STORAGE_ACCOUNT required}"
: "${BLOB_SECRET_KEY:?BLOB_SECRET_KEY required}"
: "${BLOB_CONTAINER_NAME:?BLOB_CONTAINER_NAME required}"
PREFIX="kernel-release/$RELEASE"

case "$RELEASE" in
*[!A-Za-z0-9._-]* | .*)
	echo "invalid release name: $RELEASE" >&2
	exit 1
	;;
esac

# az reads the account from the environment, keeping the key off the command line.
export AZURE_STORAGE_ACCOUNT="$BLOB_STORAGE_ACCOUNT"
export AZURE_STORAGE_KEY="$BLOB_SECRET_KEY"
blob() { az storage blob "$@" --container-name "$BLOB_CONTAINER_NAME" --only-show-errors; }

cd "$DIR"
# The release's SHA256SUMS also lists vmlinux.debug, which workers never need.
grep -E '  (vmlinux|config)$' SHA256SUMS >SHA256SUMS.blob
[ "$(wc -l <SHA256SUMS.blob)" -eq 2 ] || { echo "SHA256SUMS must list vmlinux and config" >&2; exit 1; }
sha256sum -c SHA256SUMS.blob

if [ "$(blob exists --name "$PREFIX/SHA256SUMS" --query exists -o tsv)" = "true" ]; then
	blob download --name "$PREFIX/SHA256SUMS" --file SHA256SUMS.remote >/dev/null
	if cmp -s SHA256SUMS.blob SHA256SUMS.remote; then
		echo "already mirrored: $PREFIX"
		exit 0
	fi
	echo "$PREFIX already exists with different contents; publish a new build number instead" >&2
	exit 1
fi

blob upload --name "$PREFIX/vmlinux" --file vmlinux --overwrite false >/dev/null
blob upload --name "$PREFIX/config" --file config --overwrite false >/dev/null
# Uploaded last: its presence marks a complete mirror.
blob upload --name "$PREFIX/SHA256SUMS" --file SHA256SUMS.blob --overwrite false >/dev/null
echo "mirrored $RELEASE to $BLOB_CONTAINER_NAME/$PREFIX/"
blob list --prefix "$PREFIX/" --query '[].{name:name, bytes:properties.contentLength}' -o table
