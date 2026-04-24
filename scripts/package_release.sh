#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"

if [[ -z "$VERSION" ]]; then
  echo "usage: $0 <version>" >&2
  echo "example: $0 v0.1.0" >&2
  exit 1
fi

ARCH="$(uname -m)"
VERSION_TAG="${VERSION#v}"
DIST_DIR="$ROOT_DIR/.dist"
STAGE_DIR="$DIST_DIR/ashex-$VERSION_TAG-macos-$ARCH"
ARCHIVE_PATH="$DIST_DIR/ashex-$VERSION_TAG-macos-$ARCH.tar.gz"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

rm -rf "$STAGE_DIR" "$ARCHIVE_PATH" "$CHECKSUM_PATH"
mkdir -p "$STAGE_DIR/bin" "$STAGE_DIR/share/doc/ashex"

cd "$ROOT_DIR"
echo "Building ashex $VERSION in release mode..."
swift build -c release --product ashex

BIN_DIR="$(swift build -c release --product ashex --show-bin-path)"
BINARY_PATH="$BIN_DIR/ashex"
RESOURCE_BUNDLE_PATH="$BIN_DIR/Ashex_AshexCore.bundle"

if [[ ! -x "$BINARY_PATH" ]]; then
  echo "error: expected binary not found at $BINARY_PATH" >&2
  exit 1
fi

if [[ ! -d "$RESOURCE_BUNDLE_PATH" ]]; then
  echo "error: expected resource bundle not found at $RESOURCE_BUNDLE_PATH" >&2
  exit 1
fi

install -m 755 "$BINARY_PATH" "$STAGE_DIR/bin/ashex"
if [[ -n "${ASHEX_BUNDLED_ESH_PATH:-}" ]]; then
  if [[ ! -x "$ASHEX_BUNDLED_ESH_PATH" ]]; then
    echo "error: ASHEX_BUNDLED_ESH_PATH is set but not executable: $ASHEX_BUNDLED_ESH_PATH" >&2
    exit 1
  fi
  install -m 755 "$ASHEX_BUNDLED_ESH_PATH" "$STAGE_DIR/bin/esh"
fi
COMMIT="${ASHEX_COMMIT:-$(git rev-parse --short HEAD 2>/dev/null || true)}"
{
  echo "version=$VERSION"
  echo "commit=$COMMIT"
} > "$STAGE_DIR/bin/ashex.version"
cp -R "$RESOURCE_BUNDLE_PATH" "$STAGE_DIR/bin/Ashex_AshexCore.bundle"
install -m 644 "$ROOT_DIR/README.md" "$STAGE_DIR/share/doc/ashex/README.md"
install -m 644 "$ROOT_DIR/LICENSE" "$STAGE_DIR/share/doc/ashex/LICENSE"

(
  cd "$DIST_DIR"
  tar -czf "$(basename "$ARCHIVE_PATH")" "$(basename "$STAGE_DIR")"
)

shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}' > "$CHECKSUM_PATH"

echo "Created archive: $ARCHIVE_PATH"
echo "SHA256: $(cat "$CHECKSUM_PATH")"
