# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Containerized AI coding harness development environments for Fedora. Runs in Podman rootless mode with SELinux support and optional network firewall restrictions.

One repo produces three images/launchers from a shared Dockerfile and launcher engine:

| Launcher | Harness | Image | Version pin file | Firewall overlay |
|----------|---------|-------|------------------|------------------|
| `ccbox` | Claude Code | `quay.io/guimou/ccbox` | `CLAUDE_VERSION` | `firewall-domains-claude.txt` |
| `ocbox` | OpenCode | `quay.io/guimou/ocbox` | `OPENCODE_VERSION` | `firewall-domains-opencode.txt` |
| `qcbox` | Qwen Code | `quay.io/guimou/qcbox` | `QWENCODE_VERSION` | `firewall-domains-qwencode.txt` |

The Dockerfile selects the harness via the `HARNESS` build arg (`claude` / `opencode` / `qwencode`) and its version via `HARNESS_VERSION`. Common layers never reference `HARNESS` so the build cache is shared across the three images.

## Run

By default, the container image is pulled from `quay.io/guimou/ccbox` (or `ocbox`/`qcbox`).

```bash
# Launch with latest image from registry
./ccbox

# Launch with specific version from registry
./ccbox --claude-version <version>

# Launch with locally-built image
./ccbox --local

# Launch with network firewall
./ccbox --with-firewall

# Start with all customizations disabled (troubleshooting)
./ccbox --safe-mode

# Disable clipboard access (for extra security)
./ccbox --no-clipboard

# Mount ~/.claude/.credentials.json (API key or OAuth, shared across projects)
./ccbox --with-credentials

# Enable agent teams (experimental)
./ccbox --with-teams

# Agent teams with split-pane mode (tmux)
./ccbox --with-teams --with-tmux

# Pass arguments directly to claude
./ccbox -- --version

# List active sessions for current project
./ccbox --list-sessions

# OpenCode and Qwen Code work the same way (same common flags)
./ocbox
./ocbox --opencode-version <version>
./qcbox
./qcbox --qwen-version <version>
```

`--with-teams`, `--with-tmux`, and `--safe-mode` are Claude Code specific (ccbox only).

Multiple sessions can run simultaneously in the same project. Each session gets a unique container name with a session ID suffix, while sharing project data (history, todos, plans, tasks).

## Build (Development)

For local development, you can build the image locally:

```bash
# Build locally (for development)
./ccbox --build

# Build specific version locally
./ccbox --build --claude-version <version>
```

## File Structure

- `Dockerfile` - Container image definition (Fedora 44 base), parameterized by `HARNESS`/`HARNESS_VERSION` build args
- `os-packages.txt` - DNF packages to install (one per line)
- `firewall-domains.txt` - Allowed network domains common to all harnesses (one per line)
- `firewall-domains-{claude,opencode,qwencode}.txt` - Harness-specific allowed domains, concatenated with the common file at build time into `/etc/codebox/firewall-domains.txt`
- `init-firewall.sh` - Firewall initialization script (iptables/ipset)
- `lib/box-common.sh` - Shared launcher engine (sourced by all three launchers)
- `ccbox` / `ocbox` / `qcbox` - Host launch scripts (thin wrappers defining harness identity, mounts, and env passthrough)
- `CLAUDE_VERSION` / `OPENCODE_VERSION` / `QWENCODE_VERSION` - Version pin files (overridden by `--claude-version` / `--opencode-version` / `--qwen-version`)
- `docs/` - User-facing documentation: `usage.md`, `architecture.md`, `development.md` (README holds only the minimum and links here — keep them in sync when changing behavior)

## What's Included

The container comes pre-installed with tools commonly used by Claude Code plugins and skills.

### Editors & Terminal
- **vim**, **nano** - Text editors
- **tmux** - Terminal multiplexer (for agent teams split-pane mode)

### Search & Navigation
- **ripgrep** (`rg`) - Fast recursive grep
- **fd** (`fd-find`) - User-friendly find alternative
- **tree** - Directory structure visualization

### Languages & Runtimes
- **Node.js** with npm, pnpm, and yarn
- **Python 3** with pip and virtualenv
- **uv** (`uv`, `uvx`) - Fast Python package/project manager

### LSP Servers (for Claude Code LSP plugins)
- **typescript-language-server** + **typescript** - TypeScript/JavaScript/React code intelligence
- **pyright** - Python code intelligence and type checking

### TypeScript/JavaScript Tools
- **prettier** - Code formatter
- **tsx** - Run TypeScript files directly

### Python Tools
- **pytest** with pytest-asyncio and pytest-cov - Test runner, async support, and coverage
- **mypy** - Static type checker
- **httpx** - Modern HTTP client
- **ruff** - Fast Python linter (also available as `python3 -m ruff`)

### Build Tools
- **make**, **cmake** - Build systems
- **gcc**, **g++** - C/C++ compilers
- **pkg-config** - Library configuration

### Version Control
- **git**, **gh** (GitHub CLI)

### Diagram Generation
- **graphviz** (`dot`) - Diagram generation

### Database Clients
- **sqlite**, **psql** (PostgreSQL), **mysql**, **redis-cli**

### Browser (Headless)
- **chromium** - System Chromium for Playwright MCP and browser automation (auto-configured via environment variables and config file)

### DevOps
- **helm** - Kubernetes package manager (Helm 4; install `helm3` if you need Helm 3 compatibility)
- **kubectl** - Kubernetes CLI
- **ansible** - Configuration management

### Code Quality
- **ruff** - Fast Python linter
- **ShellCheck** - Shell script analyzer
- **prettier** - TypeScript/JavaScript formatter

### Process & Data Tools
- **lsof** - Process/port inspection
- **jq** - JSON processing
- **yq** - YAML processing

### Networking
- **curl** - HTTP client
- **openssh-clients** - SSH/SCP
- **bind-utils** - DNS tools (dig, nslookup)

## Configuration

### Adding OS Packages
Edit `os-packages.txt` and rebuild:
```bash
echo "package-name" >> os-packages.txt
./ccbox --build
```

### Adding Allowed Domains
Edit `firewall-domains.txt` (all harnesses) or the harness-specific overlay (e.g. `firewall-domains-opencode.txt`) and rebuild:
```bash
echo "example.com" >> firewall-domains.txt
./ccbox --build
```

### Pinning Claude Code Version
Create a `CLAUDE_VERSION` file to pin the version (useful for teams):
```bash
echo "<version>" > CLAUDE_VERSION
./ccbox  # Will use the specified version
```
The `--claude-version` CLI flag takes precedence over the file.

### Playwright MCP Plugin
The container is pre-configured for the official [Playwright MCP plugin](https://github.com/anthropics/claude-plugins-official/tree/main/external_plugins/playwright). System Chromium is used instead of Playwright's bundled browser download.

When enabling the plugin through Claude Code, it works out of the box via environment variables (`PLAYWRIGHT_MCP_EXECUTABLE_PATH`, `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH`).

If you encounter issues with browser detection, pass the config file explicitly in your project's MCP config:
```json
{
  "playwright": {
    "command": "npx",
    "args": [
      "@playwright/mcp@latest",
      "--config", "/home/claude/.playwright-mcp-config.json"
    ]
  }
}
```

### Vertex AI Support
Set environment variables before launching to use Vertex AI:
```bash
export CLAUDE_CODE_USE_VERTEX=1
export ANTHROPIC_VERTEX_PROJECT_ID="your-project-id"
./ccbox --with-gcloud
```
Google Cloud credentials are mounted read-only from `~/.config/gcloud` when `--with-gcloud` is passed.

## CI/CD

- `.github/workflows/release.yml` runs on pushes to main touching image/launcher files. It detects which harnesses are affected: a version-file bump releases that harness as `{box}-v{version}`; a change to shared files (Dockerfile, os-packages.txt, common firewall list, init-firewall.sh, `lib/`) rebuilds all harnesses as `{box}-v{version}-N`; a change to a harness-specific file (launcher, firewall overlay) rebuilds only that harness.
- `.github/workflows/build-and-push.yml` is the reusable per-harness build (also manually dispatchable with a `harness` input). Images are tagged `{version}`, `latest`, and the commit SHA.

## Architecture

- **Registries**: `quay.io/guimou/ccbox`, `quay.io/guimou/ocbox`, `quay.io/guimou/qcbox` (CI/CD published)
- **Base**: `quay.io/fedora/fedora:44`
- **User**: `claude` (UID 1000) for `--userns=keep-id` compatibility
- **Mounts**:
  - Current directory → `/workspace`
  - Global settings (shared): `~/.claude/{settings.json,settings.local.json,keybindings.json,CLAUDE.md,statsig,hooks,commands,skills,agents,rules}`
  - Project data (isolated): `~/.claude/ccbox-projects/{project}_{hash}/` → session data, history, todos, plugins
  - `~/.claude.json` → `/home/claude/.claude.json`
  - `~/.claude/.credentials.json` → `/home/claude/.claude/.credentials.json` (read-write, only with `--with-credentials`)
  - `~/.config/gcloud` → `/home/claude/.config/gcloud` (read-only, only with `--with-gcloud`)
  - `~/.gitconfig` → `/home/claude/.gitconfig` (read-only, only with `--with-gitconfig`)
  - npm global prefix → `/home/claude/.npm-global` (read-only, auto-detected)
  - PulseAudio socket (for audio support)
  - `/etc/localtime` (for timezone sync)
- **SELinux**: Uses `:z` volume labels for shared relabeling (supports multi-session)
- **Firewall**: Optional, requires `NET_ADMIN` and `NET_RAW` capabilities
- **Project Isolation**: Each project gets its own history and session data (`~/.claude/ccbox-projects/` for ccbox, `~/.local/share/ocbox-projects/` for ocbox, `~/.qwen/qcbox-projects/` for qcbox)
- **Multi-Session**: Multiple sessions can run simultaneously per project, each with a unique container name (`{box}-{project}-{hash}-{session-id}`)
- **Per-harness mounts**: the mounts listed above are ccbox's (`.credentials.json` is opt-in via `--with-credentials`). ocbox mounts `~/.config/opencode` (shared config), a per-project data dir as `~/.local/share/opencode` with the shared `auth.json` mounted on top, and a shared `~/.cache/opencode`. qcbox mounts shared `~/.qwen/{settings.json,oauth_creds.json,QWEN.md}` plus per-project `tmp/` and `file-history/` dirs. Workspace, gcloud (opt-in `--with-gcloud`), gitconfig (opt-in `--with-gitconfig`), clipboard, audio, timezone, npm-global, and GitHub token mounts are common to all launchers (handled by `lib/box-common.sh`).

## Clipboard Support

Image pasting (CTRL+V) is enabled by default. The container mounts display sockets to access the host clipboard:
- **Wayland**: Mounts `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY` (read-only)
- **X11**: Mounts `/tmp/.X11-unix` and `~/.Xauthority` (read-only)

To disable clipboard access: `./ccbox --no-clipboard`

**Note**: Clipboard image pasting in containers has known limitations. If CTRL+V doesn't work, use file paths instead (e.g., paste `/path/to/image.png`).

## npm Global Packages

Global npm packages (like `typescript-language-server`) are auto-detected and mounted read-only from the host: **install on host, use in container**.

### Setup
Configure npm to use a user-local prefix (required for non-system installations):
```bash
# On host (one-time setup)
npm config set prefix ~/.npm-global
export PATH="$HOME/.npm-global/bin:$PATH"  # Add to ~/.bashrc

# Install packages globally
npm install -g typescript-language-server
```

### Usage
The container auto-detects `npm config get prefix` and mounts it if it's a user directory:
```bash
./ccbox  # Auto-detects ~/.npm-global

# Or specify explicitly
./ccbox --npm-global /custom/npm/prefix
```

### Security
- Mounted **read-only**: `npm install -g` inside the container will fail
- System directories (`/usr`, `/usr/local`) are never mounted
- Only user-local prefixes (like `~/.npm-global`) are mounted

## GitHub Authentication

For Claude Code to interact with GitHub (clone private repos, push, create PRs), authenticate on the host **before** launching ccbox.

### Setup (one-time)
```bash
# On host - authenticate with GitHub
gh auth login
```

Follow the prompts to authenticate via browser or token. This creates an OAuth token that ccbox automatically detects and injects into the container.

### How it works
- Token is passed via `GH_TOKEN` environment variable
- Git HTTPS operations work automatically
- `gh` CLI commands work inside the container
- Token persists until you revoke it via GitHub settings

### CLI Options
```bash
./ccbox                              # Auto-detect and inject token (default)
./ccbox --no-github                  # Launch without GitHub token
./ccbox --with-github                # Explicitly request token (warn if unavailable)
./ccbox --github-token "ghp_xxx"     # Use specific token
```

### Security Notes
- Token is **not** your SSH key - it's a revocable OAuth token
- No sensitive files are mounted (no `~/.ssh`, no `~/.config/gh`)
- Revoke anytime: GitHub Settings → Developer settings → Personal access tokens
- For extra security, use `--with-firewall` to limit network access
- Use fine-grained PATs or GitHub App tokens for minimal scope

## Agent Teams

Agent teams let you coordinate multiple Claude Code instances working in parallel. This feature is experimental and opt-in.

### Quick Start
```bash
# Enable agent teams with in-process mode (works in any terminal)
./ccbox --with-teams

# Enable agent teams with split-pane mode (each teammate gets a tmux pane)
./ccbox --with-teams --with-tmux
```

### How it works
- `--with-teams` sets `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` inside the container
- `--with-tmux` starts claude inside a tmux session, enabling split-pane display for teammates
- Without `--with-tmux`, teammates run in-process mode (cycle with Shift+Down)
- tmux is pre-installed in the container image

### Git Worktrees
Teammates can use git worktrees to work on separate branches without conflicts. Worktrees are created under `/workspace/.claude/worktrees/` and are fully contained within the mounted workspace volume.

### Notes
- Split-pane mode requires `--with-tmux` because Ghostty (and some other terminals) don't support tmux auto-detection. Running inside tmux within the container bypasses this limitation.
- Agent teams use significantly more tokens than a single session. Start with 3-5 teammates.
- See the [Claude Code docs](https://code.claude.com/docs/en/agent-teams) for full usage details.

## License

Apache License 2.0
