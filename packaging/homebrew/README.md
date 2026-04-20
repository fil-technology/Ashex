# Homebrew Packaging

This folder holds the Homebrew packaging assets that are generated or copied into the separate tap repository.

## Goal

The intended user-facing install command is:

```bash
brew install fil-technology/tap/ashex
```

That command becomes real once two things exist:

1. a tagged GitHub release in this repository
2. a `fil-technology/homebrew-tap` repository containing `Formula/ashex.rb`

## Generate A Formula For A Tagged Release

Use the helper script from this repository root:

```bash
./scripts/render_homebrew_formula.sh \
  --version v0.2.0 \
  --source-url https://github.com/fil-technology/homebrew-tap/releases/download/ashex-v0.2.0/ashex-v0.2.0-source.tar.gz \
  --sha256 <source-tarball-sha256> \
  --output packaging/homebrew/ashex.rb
```

Then copy the generated formula into the tap repository at:

```text
Formula/ashex.rb
```

## Release Artifacts

For convenience, this repo also supports a packaged release binary:

```bash
./scripts/package_source_release.sh v0.2.0
./scripts/package_release.sh v0.2.0
```

That creates release tarballs under `.dist/`. The source archive is what the Homebrew formula uses; the binary archive is for direct release downloads.

The binary archive contains:

- `bin/ashex`
- `share/doc/ashex/README.md`
- `share/doc/ashex/LICENSE`

The Homebrew formula installs from the published source release asset, not the packaged binary tarball. That keeps the tap simple while the project is still evolving.
