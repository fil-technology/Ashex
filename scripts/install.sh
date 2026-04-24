#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${1:-${INSTALL_DIR:-$HOME/.local/bin}}"
TARGET_NAME="ashex"

mkdir -p "$INSTALL_DIR"

echo "Building Ashex in release mode..."
cd "$ROOT_DIR"
swift build -c release

BINARY_PATH="$ROOT_DIR/.build/release/$TARGET_NAME"
if [[ ! -x "$BINARY_PATH" ]]; then
  echo "error: expected binary not found at $BINARY_PATH" >&2
  exit 1
fi

install -m 755 "$BINARY_PATH" "$INSTALL_DIR/$TARGET_NAME"
if [[ -n "${ASHEX_BUNDLED_ESH_PATH:-}" ]]; then
  if [[ ! -x "$ASHEX_BUNDLED_ESH_PATH" ]]; then
    echo "error: ASHEX_BUNDLED_ESH_PATH is set but not executable: $ASHEX_BUNDLED_ESH_PATH" >&2
    exit 1
  fi
  install -m 755 "$ASHEX_BUNDLED_ESH_PATH" "$INSTALL_DIR/esh"
fi
VERSION="${ASHEX_VERSION:-dev}"
COMMIT="${ASHEX_COMMIT:-$(git rev-parse --short HEAD 2>/dev/null || true)}"
{
  echo "version=$VERSION"
  echo "commit=$COMMIT"
} > "$INSTALL_DIR/$TARGET_NAME.version"

echo "Installed $TARGET_NAME to $INSTALL_DIR/$TARGET_NAME"
case ":$PATH:" in
  *":$INSTALL_DIR:"*)
    echo "Run it with: $TARGET_NAME"
    ;;
  *)
    echo "Run it with: $INSTALL_DIR/$TARGET_NAME"
    echo "Optional: add $INSTALL_DIR to your PATH"
    ;;
esac
