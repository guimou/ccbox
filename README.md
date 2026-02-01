# ccbox

An opinionated, containerized Claude Code environment for Fedora.

[![Build and Push Container Image](https://github.com/guimou/ccbox/actions/workflows/build-and-push.yml/badge.svg)](https://github.com/guimou/ccbox/actions/workflows/build-and-push.yml)

## What is ccbox?

ccbox is my personal take on running [Claude Code](https://claude.com/product/claude-code) inside a container. It provides:

- **Isolation** - Each project gets its own history, todos, and session data
- **Consistency** - Same Fedora-based environment everywhere, with common dev tools pre-installed
- **Rootless Podman** - Runs without root privileges using user namespaces
- **SELinux support** - Works out of the box on Fedora with proper volume labeling

## Installation

### Prerequisites

- [Podman](https://podman.io/docs/installation) installed and configured for rootless operation
- Fedora Linux (or compatible distribution)

### Option 1: Clone the repository

```bash
git clone https://github.com/guimou/ccbox.git
cp ccbox/ccbox ~/.local/bin/
```

### Option 2: Download the script directly

```bash
curl -fsSL https://raw.githubusercontent.com/guimou/ccbox/main/ccbox -o ~/.local/bin/ccbox
chmod +x ~/.local/bin/ccbox
```

Make sure `~/.local/bin` is in your PATH.

## Usage

```bash
# Run Claude Code in the current directory
ccbox

# Use a specific Claude Code version (if a container build exists for this version)
ccbox --claude-version 2.1.29

# Pass arguments directly to Claude Code
ccbox -- --help
ccbox -- --version

# Run with network firewall (restricts outbound connections)
ccbox --with-firewall
```

The container image is automatically pulled from `quay.io/guimou/ccbox` on first run.

## Configuration

### Vertex AI

To use Claude via Google Cloud Vertex AI:

```bash
export CLAUDE_CODE_USE_VERTEX=1
export ANTHROPIC_VERTEX_PROJECT_ID="your-project-id"
ccbox
```

Your gcloud credentials (`~/.config/gcloud`) are mounted read-only.

### Pin a version (for teams)

Create a `CLAUDE_VERSION` file in the ccbox directory:

```bash
echo "2.1.29" > ~/path/to/ccbox/CLAUDE_VERSION
```

This ensures everyone uses the same version. The `--claude-version` flag overrides this file.

## Architecture

```mermaid
flowchart TB
    subgraph Host["Host Machine"]
        CWD["Current Directory"]
        GlobalConfig["~/.claude/"]
        ProjectData["~/.claude/ccbox-projects/"]
        GCloud["~/.config/gcloud/"]
    end

    subgraph Container["ccbox Container"]
        Workspace["/workspace"]
        ClaudeHome["/home/claude/.claude/"]
        ClaudeCode["Claude Code"]
    end

    subgraph GlobalMounts["Global Mounts (shared)"]
        direction LR
        Settings["settings.json<br/>settings.local.json<br/>keybindings.json"]
        Auth[".credentials.json"]
        Extensions["plugins/ hooks/<br/>commands/ skills/<br/>agents/"]
        Memory["CLAUDE.md<br/>rules/"]
        Cache["statsig/"]
    end

    CWD -->|"mount (rw)"| Workspace
    GlobalConfig --> GlobalMounts
    GlobalMounts --> ClaudeHome
    ProjectData -->|"history, todos,<br/>plans, tasks (per-project)"| ClaudeHome
    GCloud -->|"mount (ro)"| Container

    ClaudeCode --> Workspace
```

## Where Data Lives

| Location | Purpose | Scope |
|----------|---------|-------|
| **Settings** | | |
| `~/.claude/settings.json` | Global settings | Shared |
| `~/.claude/settings.local.json` | Local settings (not synced) | Shared |
| `~/.claude/keybindings.json` | Keyboard shortcuts | Shared |
| **Authentication** | | |
| `~/.claude/.credentials.json` | API credentials | Shared |
| `~/.claude.json` | Claude config | Shared |
| **Extensions** | | |
| `~/.claude/plugins/` | Installed plugins | Shared |
| `~/.claude/hooks/` | Custom hooks | Shared |
| `~/.claude/commands/` | Global slash commands | Shared |
| `~/.claude/skills/` | Global skills | Shared |
| `~/.claude/agents/` | Global subagents | Shared |
| **Memory & Rules** | | |
| `~/.claude/CLAUDE.md` | Global memory/instructions | Shared |
| `~/.claude/rules/` | Global rules | Shared |
| **Project Data** | | |
| `~/.claude/ccbox-projects/{name}_{hash}/` | History, todos, plans, tasks | Per-project |

Each project directory gets isolated session data based on a hash of the workspace path, so you can have multiple projects with the same name in different locations.

## Firewall

<details>
<summary>Network restriction details</summary>

When launched with `--with-firewall`, outbound connections are restricted to:

- Anthropic APIs (`api.anthropic.com`, `statsig.anthropic.com`)
- GitHub (`github.com`, `api.github.com`, plus their IP ranges)
- npm registry (`registry.npmjs.org`)
- Sentry (`sentry.io`)

The firewall uses iptables/ipset and requires `NET_ADMIN` and `NET_RAW` capabilities (added automatically).

To add allowed domains, clone the repo and edit `firewall-domains.txt`, then use `--local` mode:

```bash
echo "example.com" >> firewall-domains.txt
ccbox --build
ccbox --local --with-firewall
```

</details>

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for:

- Building the image locally
- Adding OS packages
- CI/CD setup and Quay.io configuration

## License

[Apache License 2.0](LICENSE.md)
