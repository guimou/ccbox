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
./ccbox --claude-version 2.1.29

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
./ccbox --build --claude-version 2.1.29
```

## File Structure

- `Dockerfile` - Container image definition (Fedora 43 base)
- `os-packages.txt` - DNF packages to install (one per line)
- `firewall-domains.txt` - Allowed network domains (one per line)
- `init-firewall.sh` - Firewall initialization script (iptables/ipset)
- `ccbox` - Host launch script
- `CLAUDE_VERSION` - Optional file to pin Claude Code version (overridden by `--claude-version`)

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
echo "2.1.29" > CLAUDE_VERSION
./ccbox  # Will use version 2.1.29
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
  - Global settings (shared): `~/.claude/{settings.json,settings.local.json,.credentials.json,keybindings.json,CLAUDE.md,plugins,statsig,hooks,commands,skills,agents,rules}`
  - Project data (isolated): `~/.claude/ccbox-projects/{project}_{hash}/` → session data, history, todos
  - `~/.claude.json` → `/home/claude/.claude.json`
  - `~/.config/gcloud` → `/home/claude/.config/gcloud` (read-only)
  - PulseAudio socket (for audio support)
  - `/etc/localtime` (for timezone sync)
- **SELinux**: Uses `:Z` volume labels for private relabeling
- **Firewall**: Optional, requires `NET_ADMIN` and `NET_RAW` capabilities
- **Project Isolation**: Each project gets its own history and session data in `~/.claude/ccbox-projects/`
- **Multi-Session**: Multiple sessions can run simultaneously per project, each with a unique container name (`ccbox-{project}-{hash}-{session-id}`)

## Clipboard Support

Image pasting (CTRL+V) is enabled by default. The container mounts display sockets to access the host clipboard:
- **Wayland**: Mounts `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY` (read-only)
- **X11**: Mounts `/tmp/.X11-unix` and `~/.Xauthority` (read-only)

To disable clipboard access: `./ccbox --no-clipboard`

**Note**: Clipboard image pasting in containers has known limitations. If CTRL+V doesn't work, use file paths instead (e.g., paste `/path/to/image.png`).

## License

Apache License 2.0
