# ccbox / ocbox / qcbox

Opinionated, containerized AI coding harness environments for Fedora.

[![Build and Push Container Image](https://github.com/guimou/ccbox/actions/workflows/build-and-push.yml/badge.svg)](https://github.com/guimou/ccbox/actions/workflows/build-and-push.yml)

## What is this?

This project is my personal take on running AI coding harnesses inside a container. One repo produces three images and three launchers, sharing the same base environment:

| Launcher | Harness | Image |
|----------|---------|-------|
| `ccbox` | [Claude Code](https://claude.com/product/claude-code) | `quay.io/guimou/ccbox` |
| `ocbox` | [OpenCode](https://opencode.ai) | `quay.io/guimou/ocbox` |
| `qcbox` | [Qwen Code](https://github.com/QwenLM/qwen-code) | `quay.io/guimou/qcbox` |

All three provide:

- **Isolation** - Only the current project directory is mounted; each project gets its own history and session data
- **Multi-session** - Run multiple sessions simultaneously in the same project
- **Consistency** - Same Fedora-based environment everywhere, with common dev tools pre-installed
- **Multi-platform** - Supports both x86_64/amd64 and ARM64 (Apple Silicon)
- **Rootless Podman** - Runs without root privileges using user namespaces
- **SELinux support** - Works out of the box on Fedora with proper volume labeling
- **Optional firewall** - Restrict outbound network to an allowlist (Linux only)

## Installation

### Prerequisites

- [Podman](https://podman.io/docs/installation) installed and configured for rootless operation
- Fedora Linux (or compatible distribution) or macOS with [Podman Desktop](https://podman-desktop.io/downloads)

### Install

The launchers share a common engine (`lib/box-common.sh`), so symlink them from a clone (symlinks are resolved to the repo, where the engine and version files live):

```bash
git clone https://github.com/guimou/ccbox.git
ln -sf "$(pwd)/ccbox/ccbox" ~/.local/bin/ccbox
ln -sf "$(pwd)/ccbox/ocbox" ~/.local/bin/ocbox
ln -sf "$(pwd)/ccbox/qcbox" ~/.local/bin/qcbox
```

Only link the launchers you actually use, and make sure `~/.local/bin` is in your PATH. Run `ccbox --install` for OS and shell-specific instructions.

## Quick Start

```bash
cd your-project

ccbox            # Run Claude Code in the current directory
ocbox            # Run OpenCode
qcbox            # Run Qwen Code
```

The container image is pulled automatically on first run. A few common flags:

```bash
ccbox --with-firewall     # Restrict outbound network (Linux only)
ccbox --build             # Build the image locally (development, Apple Silicon)
ccbox --local             # Use the locally-built image
ccbox -- --version        # Pass arguments to the harness CLI
ccbox --help              # All options
```

API keys and provider settings are forwarded from host environment variables (e.g. `ANTHROPIC_API_KEY`, Vertex AI, Bedrock) — see the [usage guide](docs/usage.md#api-provider-configuration).

## Documentation

| Document | Contents |
|----------|----------|
| [docs/usage.md](docs/usage.md) | All flags, provider configuration, GitHub auth, version pinning, firewall, clipboard, agent teams, platform notes, included tools |
| [docs/architecture.md](docs/architecture.md) | How images, launchers, mounts, and per-project isolation work; what data lives where for each harness |
| [docs/development.md](docs/development.md) | Building locally, adding packages/domains, CI/CD and release process |

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines.

## License

[Apache License 2.0](LICENSE.md)
