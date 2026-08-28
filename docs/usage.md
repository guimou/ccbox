# Usage

All three launchers (`ccbox`, `ocbox`, `qcbox`) share the same common flags; only the version flag and a few harness-specific options differ.

## Basics

```bash
# Run the harness in the current directory
ccbox            # Claude Code
ocbox            # OpenCode
qcbox            # Qwen Code

# Use a specific harness version (if a container build exists for it)
ccbox --claude-version <version>
ocbox --opencode-version <version>
qcbox --qwen-version <version>

# Pass arguments directly to the harness CLI
ccbox -- --help
ccbox -- --version
ocbox -- run "explain this repo"
```

The container image is automatically pulled from `quay.io/guimou/{ccbox,ocbox,qcbox}` on first run. Unknown flags are passed through to the harness CLI.

## Common Flags

| Flag | Description |
|------|-------------|
| `--build` | Build the image locally (development, or Apple Silicon) |
| `--local` | Use the locally-built image instead of pulling |
| `--with-firewall` | Restrict outbound network to an allowlist (Linux only) |
| `--no-clipboard` | Disable host clipboard/display access |
| `--no-github` / `--with-github` / `--github-token <t>` | Control GitHub token injection |
| `--npm-global <dir>` | Explicit npm global prefix to mount (auto-detected otherwise) |
| `--list-sessions` | List active sessions for the current project |
| `--install` | Show OS/shell-specific installation instructions |
| `--` | Everything after is passed to the harness CLI |

ccbox-only flags: `--with-teams`, `--with-tmux`, `--safe-mode` (see below).

## Sessions and Isolation

- Each project directory gets isolated history/session data, keyed by a hash of its path — two projects with the same name in different locations don't collide.
- You can run **multiple sessions simultaneously** in the same project. Each session gets a unique container name; project data is shared between them.
- See [architecture.md](architecture.md) for exactly what is mounted, shared, and isolated per harness.

## API Provider Configuration

Each launcher forwards the environment variables its harness understands from the host into the container:

- **ccbox**: all `ANTHROPIC_*` and `CLAUDE_CODE_*` variables, plus AWS credential variables
- **ocbox**: `OPENCODE_*` plus common provider keys (`ANTHROPIC_*`, `OPENAI_*`, `OPENROUTER_*`, `GEMINI_*`, `GOOGLE_*`, `AZURE_*`, AWS credentials)
- **qcbox**: `QWEN_*`, `OPENAI_*` (API key/base URL/model), `DASHSCOPE_*`, `BAILIAN_*`, `MODELSCOPE_*`, `OPENROUTER_*`

Set the appropriate variables before launching.

**Direct Anthropic API:**

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
ccbox
```

**Google Cloud Vertex AI:**

```bash
export CLAUDE_CODE_USE_VERTEX=1
export ANTHROPIC_VERTEX_PROJECT_ID="your-project-id"
ccbox
```

Your gcloud credentials (`~/.config/gcloud`) are mounted read-only.

**AWS Bedrock:**

```bash
export CLAUDE_CODE_USE_BEDROCK=1
export AWS_REGION="us-east-1"
ccbox
```

**Per-project provider selection** — use shell aliases, inline variables, or [direnv](https://direnv.net/):

```bash
# Shell aliases in ~/.bashrc
alias ccbox-vertex='CLAUDE_CODE_USE_VERTEX=1 ANTHROPIC_VERTEX_PROJECT_ID="my-project" ccbox'
alias ccbox-anthropic='ANTHROPIC_API_KEY="sk-ant-..." ccbox'

# Inline (no persistent state)
ANTHROPIC_API_KEY="sk-ant-..." ccbox

# direnv (.envrc in project directory — auto-sets vars on cd)
# echo 'export ANTHROPIC_API_KEY="sk-ant-..."' > .envrc && direnv allow
```

## Pin a Version (for teams)

Each harness has its own version pin file in the repo directory: `CLAUDE_VERSION` (ccbox), `OPENCODE_VERSION` (ocbox), `QWENCODE_VERSION` (qcbox):

```bash
echo "<version>" > ~/path/to/ccbox/CLAUDE_VERSION
```

This ensures everyone uses the same version. The `--claude-version` / `--opencode-version` / `--qwen-version` flags override the respective file.

## GitHub Authentication

To interact with GitHub from inside the container (clone private repos, push, create PRs), authenticate on the host **before** launching:

```bash
# One-time setup on host
gh auth login
```

The OAuth token is automatically detected from the host's `gh` CLI and injected into the container as `GH_TOKEN`. Git HTTPS operations and `gh` commands then work inside the container. No sensitive files are mounted (no `~/.ssh`, no `~/.config/gh`).

```bash
ccbox                              # Auto-detect and inject token (default)
ccbox --no-github                  # Launch without GitHub token
ccbox --with-github                # Explicitly request token (warn if unavailable)
ccbox --github-token "ghp_xxx"     # Use specific token instead of auto-detecting
```

**Security notes:**

- The token is a revocable OAuth token, not your SSH key — revoke anytime in GitHub Settings → Developer settings → Personal access tokens
- Use fine-grained PATs for minimal scope
- For extra security, combine with `--with-firewall`

## Firewall

```bash
ccbox --with-firewall
```

Restricts outbound connections to an allowlist baked into the image (GitHub, package registries, and the harness's own API endpoints). Linux only.

**Limitations:** web search, web fetch, and HTTP-based MCP servers do not work behind the firewall; stdio MCP servers do. See [architecture.md](architecture.md#firewall) for the allowlist details and [development.md](development.md) for adding domains.

## Clipboard Support

Image pasting (CTRL+V) requires display server access:

- **Linux/Wayland**: automatically detected via `$WAYLAND_DISPLAY`
- **Linux/X11**: automatically detected via `$DISPLAY` and `/tmp/.X11-unix`
- **macOS**: requires [XQuartz](https://www.xquartz.org/) with "Allow connections from network clients" enabled

To disable clipboard access: `ccbox --no-clipboard`

**Note:** clipboard image pasting in containers has known limitations. If CTRL+V doesn't work, use file paths instead (e.g., paste `/path/to/image.png`).

## Agent Teams (ccbox only, experimental)

Agent teams let you coordinate multiple Claude Code instances working in parallel:

```bash
# In-process mode (works in any terminal; cycle teammates with Shift+Down)
ccbox --with-teams

# Split-pane mode (each teammate gets a tmux pane)
ccbox --with-teams --with-tmux
```

- `--with-teams` sets `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` inside the container
- `--with-tmux` starts claude inside a tmux session (pre-installed in the image). This is required for split panes because some terminals (e.g. Ghostty) don't support tmux auto-detection.
- Teammates can use git worktrees under `/workspace/.claude/worktrees/`, fully contained within the mounted workspace.
- Agent teams use significantly more tokens than a single session. Start with 3-5 teammates. See the [Claude Code docs](https://code.claude.com/docs/en/agent-teams).

## Troubleshooting

```bash
# Start with all customizations disabled (ccbox only)
ccbox --safe-mode

# Print the full podman command before execution
DEBUG=1 ccbox
```

## Playwright MCP Plugin (ccbox)

The container is pre-configured for the official [Playwright MCP plugin](https://github.com/anthropics/claude-plugins-official/tree/main/external_plugins/playwright): system Chromium is used instead of Playwright's bundled browser download, via environment variables (`PLAYWRIGHT_MCP_EXECUTABLE_PATH`, `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH`).

If browser detection fails, pass the config file explicitly in your project's MCP config:

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

## Platform Notes

### Linux (x86_64)

Primary supported platform, full feature support: SELinux volume labeling, firewall restrictions, Wayland/X11 clipboard, PulseAudio.

### macOS (Apple Silicon)

Build a local ARM64 image to avoid x86 emulation:

```bash
ccbox --build          # Build native ARM64 image
ccbox                  # Auto-detects and uses local image
```

Differences from Linux:

- Firewall is not supported (requires Linux iptables)
- Clipboard access requires XQuartz
- SELinux labels are automatically omitted (not needed with virtiofs)
- Podman machine must be running (`podman machine start`)

**Memory:** Linux, 4GB RAM minimum; macOS, allocate at least 6GB RAM to the Podman VM.

## What's Included in the Images

Common development tools the harness can use directly or through skills and hooks:

| Category | Tools |
|----------|-------|
| **Editors & Terminal** | vim, nano, tmux |
| **Search** | ripgrep (`rg`), fd-find (`fd`), tree |
| **Languages** | Node.js (npm, pnpm, yarn), Python 3 (pip, virtualenv), uv/uvx |
| **LSP Servers** | typescript-language-server + typescript, pyright |
| **TS/JS Tools** | prettier, tsx |
| **Python Tools** | pytest (asyncio, cov), mypy, ruff, httpx |
| **Build** | make, cmake, gcc, g++, pkg-config |
| **Version Control** | git, gh (GitHub CLI) |
| **Code Quality** | ruff, ShellCheck, prettier |
| **Database Clients** | sqlite, psql, mysql, redis-cli |
| **DevOps** | helm, kubectl, ansible |
| **Browser** | chromium (headless, for Playwright MCP) |
| **Networking** | curl, openssh-clients, bind-utils |
| **Other** | graphviz, jq, yq, lsof, xclip, wl-clipboard |

### npm Global Packages

Global npm packages installed on the **host** are auto-detected and mounted read-only into the container:

```bash
# On host (one-time setup)
npm config set prefix ~/.npm-global
export PATH="$HOME/.npm-global/bin:$PATH"  # Add to ~/.bashrc

npm install -g some-tool
ccbox                          # Auto-detects ~/.npm-global
ccbox --npm-global /custom/dir # Or specify explicitly
```

Mounted read-only (`npm install -g` inside the container will fail); system directories (`/usr`, `/usr/local`) are never mounted.
