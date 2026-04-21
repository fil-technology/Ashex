# Ashex

[![Release](https://img.shields.io/github/v/release/fil-technology/Ashex?display_name=tag)](https://github.com/fil-technology/Ashex/releases)
[![Homebrew Tap](https://img.shields.io/badge/Homebrew-fil--technology%2Ftap%2Fashex-8a6d3b)](https://github.com/fil-technology/homebrew-tap)
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)](https://www.swift.org/)

Ashex is a local-first coding agent runtime for macOS, built as a Swift package with a terminal TUI, typed tools, persistent chat/run history, guarded execution, and daemon-ready connectors.

## Quick Start

```bash
brew install fil-technology/tap/ashex
ashex
```

The Homebrew formula installs the published prebuilt binary archive, not a source build on your machine.

If you already opened Ashex and want to run setup again:

```bash
ashex onboard
```

## Install

### Homebrew

```bash
brew update
brew install fil-technology/tap/ashex
```

Upgrade later:

```bash
brew update
brew upgrade ashex
```

### From Source

```bash
swift build
swift run ashex
```

To install the current checkout as a normal shell command:

```bash
./scripts/install.sh
~/.local/bin/ashex
```

## Use Ashex

Start the interactive TUI:

```bash
ashex
```

Run a one-shot prompt:

```bash
ashex "summarize this repository"
ashex "list files"
ashex "read README.md"
ashex "swift build"
ashex 'shell: ls -la'
```

Useful options:

- `onboard`: open the setup wizard even if saved settings already exist
- Default workspace: `~/Ashex/DefaultWorkspace`, created on first run so accidental file operations do not target the Ashex source tree
- `--workspace PATH`: run against a specific project root instead of the default workspace
- `--storage PATH`: use a specific persistence directory, default `WORKSPACE/.ashex`
- `--provider mock|openai|anthropic|ollama|dflash`: choose the model provider
- `--model MODEL`: choose the provider model
- `--approval-mode trusted|guarded`: choose execution policy, default `trusted`
- `--onboarding`: alias for `onboard`

## TUI Basics

- Use `Chat` to send messages and continue the active thread.
- Use `Assistant Setup` to choose provider/model, save API keys, configure Telegram, and start or stop the daemon.
- Use `Workspaces` to switch between recent project roots.
- Use `Threads` to browse saved conversations.
- Press `Tab` to move focus, `Enter` to select or send, `Esc` to back out, and `t` to open the side terminal.

## Providers

Ashex supports `mock`, `openai`, `anthropic`, `ollama`, and experimental `dflash`.

The fastest setup path is inside the TUI:

```bash
ashex onboard
```

For CLI examples, environment variables, local Ollama/DFlash setup, and provider limitations, see [Provider Guide](docs/usage/providers.md).

## More Documentation

- [Documentation map](docs/README.md)
- [Provider guide](docs/usage/providers.md)
- [Daemon and Telegram guide](docs/usage/daemon-telegram.md)
- [Configuration and safety guide](docs/usage/configuration.md)
- [Runtime and tools guide](docs/architecture/runtime-and-tools.md)
- [Release maintenance guide](docs/release/maintenance.md)
- [Roadmap](docs/roadmap/implementation-phases.md)
