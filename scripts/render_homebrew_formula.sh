#!/usr/bin/env bash
set -euo pipefail

VERSION=""
BINARY_URL=""
BINARY_SHA256=""
HOMEPAGE="https://github.com/fil-technology/ashex"
OUTPUT=""
ARCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --binary-url)
      BINARY_URL="${2:-}"
      shift 2
      ;;
    --sha256)
      BINARY_SHA256="${2:-}"
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
    --arch)
      ARCH="${2:-}"
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$VERSION" || -z "$BINARY_URL" || -z "$BINARY_SHA256" || -z "$ARCH" ]]; then
  echo "usage: $0 --version v0.1.0 --binary-url <tarball-url> --sha256 <sha256> --arch <arm64|x86_64> [--homepage <url>] [--output <path>]" >&2
  exit 1
fi

VERSION_NO_V="${VERSION#v}"

case "$ARCH" in
  arm64)
FORMULA=$(cat <<EOF
class Ashex < Formula
  desc "Local-first Swift coding agent for macOS with a TUI, daemon, and typed tools"
  homepage "$HOMEPAGE"
  license "MIT"
  version "$VERSION_NO_V"

  depends_on :macos

  on_arm do
    url "$BINARY_URL"
    sha256 "$BINARY_SHA256"
  end

  on_intel do
    odie "Intel is not yet supported by this formula release. Install a matching x86_64 artifact or publish an Intel archive."
  end

  def install
    dir = Dir["ashex-*"].first || "."
    libexec.install "#{dir}/bin/ashex"
    esh_path = "#{dir}/bin/esh"
    libexec.install esh_path if File.exist?(esh_path)
    libexec.install "#{dir}/bin/Ashex_AshexCore.bundle"
    bin.write_exec_script libexec/"ashex"
    pkgshare.install "#{dir}/share/doc/ashex/README.md", "#{dir}/share/doc/ashex/LICENSE"
  end

  test do
    output = shell_output("#{bin}/ashex --help")
    assert_match "ashex", output
  end
end
EOF
)
    ;;
  x86_64)
FORMULA=$(cat <<EOF
class Ashex < Formula
  desc "Local-first Swift coding agent for macOS with a TUI, daemon, and typed tools"
  homepage "$HOMEPAGE"
  license "MIT"
  version "$VERSION_NO_V"

  depends_on :macos

  on_arm do
    odie "Apple Silicon is not yet supported by this formula release. Install a matching arm64 artifact or publish an Apple Silicon archive."
  end

  on_intel do
    url "$BINARY_URL"
    sha256 "$BINARY_SHA256"
  end

  def install
    dir = Dir["ashex-*"].first || "."
    libexec.install "#{dir}/bin/ashex"
    esh_path = "#{dir}/bin/esh"
    libexec.install esh_path if File.exist?(esh_path)
    libexec.install "#{dir}/bin/Ashex_AshexCore.bundle"
    bin.write_exec_script libexec/"ashex"
    pkgshare.install "#{dir}/share/doc/ashex/README.md", "#{dir}/share/doc/ashex/LICENSE"
  end

  test do
    output = shell_output("#{bin}/ashex --help")
    assert_match "ashex", output
  end
end
EOF
)
    ;;
  *)
    echo "error: unsupported arch: $ARCH" >&2
    exit 1
    ;;
esac

if [[ -n "$OUTPUT" ]]; then
  printf "%s\n" "$FORMULA" > "$OUTPUT"
  echo "Wrote formula to $OUTPUT"
else
  printf "%s\n" "$FORMULA"
fi
