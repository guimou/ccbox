# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Containerized Claude Code development environment for Fedora. Runs in Podman rootless mode with SELinux support and optional network firewall restrictions.

## Run

By default, the container image is pulled from `quay.io/guimou/ccbox`.

```bash
# Launch with latest image from registry
./ccbox

# Launch with specific version from registry
./ccbox --claude-version 2.1.31

# Launch with locally-built image
./ccbox --local

# Launch with network firewall
./ccbox --with-firewall

# Disable clipboard access (for extra security)
./ccbox --no-clipboard

# Pass arguments directly to claude
./ccbox -- --version

# List active sessions for current project
./ccbox --list-sessions
```

Multiple sessions can run simultaneously in the same project. Each session gets a unique container name with a session ID suffix, while sharing project data (history, todos, plans, tasks).

## Build (Development)

For local development, you can build the image locally:

```bash
# Build locally (for development)
./ccbox --build

# Build specific version locally
./ccbox --build --claude-version 2.1.31
```

## File Structure

- `Dockerfile` - Container image definition (Fedora 43 base)
- `os-packages.txt` - DNF packages to install (one per line)
- `firewall-domains.txt` - Allowed network domains (one per line)
- `init-firewall.sh` - Firewall initialization script (iptables/ipset)
- `ccbox` - Host launch script
- `CLAUDE_VERSION` - Optional file to pin Claude Code version (overridden by `--claude-version`)

## What's Included

The container comes pre-installed with tools commonly used by Claude Code plugins and skills.

### Editors
- **vim**, **nano** - Text editors

### Search & Navigation
- **ripgrep** (`rg`) - Fast recursive grep
- **fd** (`fd-find`) - User-friendly find alternative
- **tree** - Directory structure visualization

### Languages & Runtimes
- **Node.js** with npm and pnpm
- **Python 3** with pip and virtualenv

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

### DevOps
- **kubectl** - Kubernetes CLI
- **ansible** - Configuration management

### Code Quality
- **ruff** - Fast Python linter
- **ShellCheck** - Shell script analyzer

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
Edit `firewall-domains.txt` and rebuild:
```bash
echo "example.com" >> firewall-domains.txt
./ccbox --build
```

### Pinning Claude Code Version
Create a `CLAUDE_VERSION` file to pin the version (useful for teams):
```bash
echo "2.1.31" > CLAUDE_VERSION
./ccbox  # Will use version 2.1.31
```
The `--claude-version` CLI flag takes precedence over the file.

### Vertex AI Support
Set environment variables before launching to use Vertex AI:
```bash
export CLAUDE_CODE_USE_VERTEX=1
export ANTHROPIC_VERTEX_PROJECT_ID="your-project-id"
./ccbox
```
Google Cloud credentials are mounted read-only from `~/.config/gcloud`.

## Architecture

- **Registry**: `quay.io/guimou/ccbox` (CI/CD published)
- **Base**: `quay.io/fedora/fedora:43`
- **User**: `claude` (UID 1000) for `--userns=keep-id` compatibility
- **Mounts**:
  - Current directory → `/workspace`
  - Global settings (shared): `~/.claude/{settings.json,settings.local.json,.credentials.json,keybindings.json,CLAUDE.md,statsig,hooks,commands,skills,agents,rules}`
  - Project data (isolated): `~/.claude/ccbox-projects/{project}_{hash}/` → session data, history, todos, plugins
  - `~/.claude.json` → `/home/claude/.claude.json`
  - `~/.config/gcloud` → `/home/claude/.config/gcloud` (read-only)
  - npm global prefix → `/home/claude/.npm-global` (read-only, auto-detected)
  - PulseAudio socket (for audio support)
  - `/etc/localtime` (for timezone sync)
- **SELinux**: Uses `:z` volume labels for shared relabeling (supports multi-session)
- **Firewall**: Optional, requires `NET_ADMIN` and `NET_RAW` capabilities
- **Project Isolation**: Each project gets its own history and session data in `~/.claude/ccbox-projects/`
- **Multi-Session**: Multiple sessions can run simultaneously per project, each with a unique container name (`ccbox-{project}-{hash}-{session-id}`)

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

## License

Apache License 2.0
