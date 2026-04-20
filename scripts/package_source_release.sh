#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"

if [[ -z "$VERSION" ]]; then
  echo "usage: $0 <version>" >&2
  echo "example: $0 v0.2.0" >&2
  exit 1
fi

VERSION_TAG="${VERSION#v}"
DIST_DIR="$ROOT_DIR/.dist"
ARCHIVE_PATH="$DIST_DIR/ashex-$VERSION-source.tar.gz"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

rm -rf "$ARCHIVE_PATH" "$CHECKSUM_PATH"
mkdir -p "$DIST_DIR"

cd "$ROOT_DIR"
git archive --format=tar.gz --output "$ARCHIVE_PATH" --prefix="ashex-$VERSION_TAG/" HEAD
shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}' > "$CHECKSUM_PATH"

echo "Created source archive: $ARCHIVE_PATH"
echo "SHA256: $(cat "$CHECKSUM_PATH")"

