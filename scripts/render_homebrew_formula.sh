#!/usr/bin/env bash
set -euo pipefail

VERSION=""
SOURCE_URL=""
SOURCE_SHA256=""
HOMEPAGE="https://github.com/fil-technology/ashex"
OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --source-url)
      SOURCE_URL="${2:-}"
      shift 2
      ;;
    --sha256)
      SOURCE_SHA256="${2:-}"
      shift 2
      ;;
    --homepage)
      HOMEPAGE="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT="${2:-}"
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$VERSION" || -z "$SOURCE_URL" || -z "$SOURCE_SHA256" ]]; then
  echo "usage: $0 --version v0.1.0 --source-url <tarball-url> --sha256 <sha256> [--homepage <url>] [--output <path>]" >&2
  exit 1
fi

FORMULA=$(cat <<EOF
class Ashex < Formula
  desc "Local-first Swift coding agent for macOS with a TUI, daemon, and typed tools"
  homepage "$HOMEPAGE"
  url "$SOURCE_URL"
  sha256 "$SOURCE_SHA256"
  license "MIT"
  version "${VERSION#v}"

  depends_on :macos
  depends_on "swift" => :build

  def install
    bin_path = shell_output("swift build -c release --product ashex --show-bin-path").strip
    bin.install "#{bin_path}/ashex" => "ashex"
    pkgshare.install "README.md", "LICENSE"
  end

  test do
    output = shell_output("#{bin}/ashex --help")
    assert_match "ashex", output
  end
end
EOF
)

if [[ -n "$OUTPUT" ]]; then
  printf "%s\n" "$FORMULA" > "$OUTPUT"
  echo "Wrote formula to $OUTPUT"
else
  printf "%s\n" "$FORMULA"
fi
