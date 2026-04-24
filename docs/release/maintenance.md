# Release Maintenance Guide

This page collects release commands and Homebrew maintenance notes so the root README can stay focused on installation and first use.

## Package Release Artifacts

```bash
./scripts/package_source_release.sh v0.2.2
./scripts/package_release.sh v0.2.2
```

`package_release.sh` creates the binary release archive layout used by Homebrew:

```text
ashex-<version>-macos-<arch>/
  bin/ashex
  bin/esh                    # optional, when ASHEX_BUNDLED_ESH_PATH is provided
  share/doc/ashex/README.md
  share/doc/ashex/LICENSE
```

If you already have a prebuilt `esh` binary and want the release to work out of the box without a separate `esh` install, package it into the archive:

```bash
ASHEX_BUNDLED_ESH_PATH=/absolute/path/to/esh ./scripts/package_release.sh v0.2.2
```

For tag `v0.2.2`, the binary archive name is:

```text
ashex-0.2.2-macos-arm64.tar.gz
```

The archive uses the version without the leading `v`.

## Homebrew Formula Rendering

Render the Homebrew formula for a published binary release asset:

```bash
./scripts/render_homebrew_formula.sh \
  --version v0.2.2 \
  --binary-url https://github.com/fil-technology/Ashex/releases/download/v0.2.2/ashex-0.2.2-macos-arm64.tar.gz \
  --sha256 <binary-release-sha256> \
  --arch arm64 \
  --homepage https://github.com/fil-technology/Ashex
```

The formula should install from the prebuilt release archive. It should not:

- depend on Homebrew Swift as a build dependency
- run `swift build`
- point Homebrew users at a source tarball as the install artifact

## Release Workflow Expectations

The release workflow should:

- build and test before publishing
- keep source archive publishing available
- package the binary archive with `package_release.sh`
- smoke-test the packaged binary by extracting it and running `--help`
- publish the binary archive and `.sha256`
- generate the Homebrew formula against the binary release asset URL
- update the tap formula with the matching SHA-256

## Local Smoke Checks

After a release and tap update:

```bash
brew update
brew fetch fil-technology/tap/ashex
brew reinstall fil-technology/tap/ashex
ashex --help
```

The fetch/install output should show the small binary archive, not a large Swift toolchain/source-build path.

## Real-Model Smoke Test

For a disposable real-model end-to-end test:

```bash
export OPENAI_API_KEY=your_key_here
./scripts/smoke_real_model_project_flow.sh /tmp/ashex-smoke DemoApp openai gpt-5.4
```
