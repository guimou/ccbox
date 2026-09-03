# Usage

All four launchers (`ccbox`, `ocbox`, `qcbox`, `cxbox`) share the same common flags; only the version flag and a few harness-specific options differ.

## Basics

```bash
# Run the harness in the current directory
ccbox            # Claude Code
ocbox            # OpenCode
qcbox            # Qwen Code
cxbox            # Codex CLI

# Use a specific harness version (if a container build exists for it)
ccbox --claude-version <version>
ocbox --opencode-version <version>
qcbox --qwen-version <version>
cxbox --codex-version <version>

# Pass arguments directly to the harness CLI
ccbox -- --help
ccbox -- --version
ocbox -- run "explain this repo"
```

The container image is automatically pulled from `quay.io/guimou/{ccbox,ocbox,qcbox,cxbox}` on first run. Unknown flags are passed through to the harness CLI.

## Common Flags

| Flag | Description |
|------|-------------|
| `--build` | Build the harness image locally on top of the base image (development, or Apple Silicon) |
| `--build-base` | Also build the base image locally from `Dockerfile.base` (implies `--build`) |
| `--local` | Use the locally-built image instead of pulling |
| `--with-firewall` | Restrict outbound network to an allowlist (Linux only) |
| `--no-clipboard` | Disable host clipboard/display access |
| `--no-github` / `--with-github` / `--github-token <t>` | Control GitHub token injection |
| `--npm-global <dir>` | Explicit npm global prefix to mount (auto-detected otherwise) |
| `--with-gcloud` | Mount `~/.config/gcloud` read-only (Vertex AI, opt-in) |
| `--with-gitconfig` | Mount `~/.gitconfig` read-only (git identity, opt-in) |
| `--with-credentials` | Mount the harness credential file read-write (opt-in; see [Credentials](#credentials)) |
| `--list-sessions` | List active sessions for the current project |
| `--install` | Show OS/shell-specific installation instructions |
| `--` | Everything after is passed to the harness CLI |

ccbox-only flags: `--with-teams`, `--with-tmux`, `--safe-mode`. `--with-credentials` is available on all four launchers (see below).

## Sessions and Isolation

- Each project directory gets isolated history/session data, keyed by a hash of its path — two projects with the same name in different locations don't collide.
- You can run **multiple sessions simultaneously** in the same project. Each session gets a unique container name; project data is shared between them.
- Chat transcripts persist in the per-project data dir, so you can resume past conversations after a container exits: `ccbox -- --resume`, `ocbox -- --continue` (or `-c`), `qcbox -- --resume`, `cxbox -- resume`.
- See [architecture.md](architecture.md) for exactly what is mounted, shared, and isolated per harness.

## API Provider Configuration

### What is passed into the container

Every launcher always forwards the host environment variables matching its harness's prefix list (plus a few specific variables), and the shared harness config is always mounted — even without `--with-credentials`. What this means in practice:

| Launcher | Env var prefixes forwarded (from host) | Specific vars also forwarded | Always-mounted config that can carry credentials |
|----------|----------------------------------------|------------------------------|---------------------------------------------------|
| `ccbox` | `ANTHROPIC_*`, `CLAUDE_CODE_*`, `CLAUDE_AX_*`, `CLAUDE_ENABLE_*`, `CLAUDE_AUTOCOMPACT_*` | `AWS_REGION`, `AWS_PROFILE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_BEARER_TOKEN_BEDROCK`, `OTEL_METRICS_EXPORTER`, `OTEL_LOG_*`, `OTEL_RESOURCE_ATTRIBUTES`, plus non-credential Claude-specific vars (`MAX_THINKING_TOKENS`, `MCP_TIMEOUT`, `NODE_OPTIONS`, `NO_COLOR`, …) | `~/.claude/settings.json`, `~/.claude/settings.local.json`, `~/.claude.json` |
| `ocbox` | `OPENCODE_*`, `ANTHROPIC_*`, `OPENAI_*`, `OPENROUTER_*`, `GEMINI_*`, `GOOGLE_*`, `AZURE_*`, `DEEPSEEK_*`, `MISTRAL_*`, `XAI_*`, `GROQ_*` | `AWS_REGION`, `AWS_PROFILE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_BEARER_TOKEN_BEDROCK`, plus `NODE_OPTIONS`, `NO_COLOR`, `FORCE_COLOR` | the whole `~/.config/opencode/` directory (incl. `opencode.json`) |
| `qcbox` | `QWEN_*`, `OPENAI_*`, `DASHSCOPE_*`, `BAILIAN_*`, `MODELSCOPE_*`, `OPENROUTER_*`, `ANTHROPIC_*`, `GEMINI_*`, `GOOGLE_*` | `NODE_OPTIONS`, `NO_COLOR`, `FORCE_COLOR`, `NODE_EXTRA_CA_CERTS` (non-credential) | `~/.qwen/settings.json` (a home-level `~/.qwen/.env` is also mounted read-only if present) |
| `cxbox` | `CODEX_*`, `OPENAI_*`, `OPENROUTER_*`, `ANTHROPIC_*`, `GEMINI_*`, `GOOGLE_*`, `AZURE_*`, `DEEPSEEK_*`, `MISTRAL_*`, `XAI_*`, `GROQ_*` | `AWS_REGION`, `AWS_PROFILE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_BEARER_TOKEN_BEDROCK`, plus `NODE_OPTIONS`, `NO_COLOR`, `FORCE_COLOR` | `~/.codex/config.toml` |

GitHub token injection (`GH_TOKEN`) is separate and works the same for all four (see [GitHub Authentication](#github-authentication)).

> **Consequence:** if your harness's main config file contains API keys (a `"env"` block or a provider definition with an `apiKey`/`envKey`), those files are mounted into the container **regardless of `--with-credentials`** — that flag only controls the separate OAuth/credential store file (see [Credentials](#credentials)). If that is not what you want, don't keep keys in the shared config: use a shell export (or per-project override below), or a file that is *not* mounted.

Set the appropriate variables on the host before launching — they are forwarded automatically:

**Direct Anthropic API:**

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
ccbox
```

**Google Cloud Vertex AI:**

```bash
export CLAUDE_CODE_USE_VERTEX=1
export ANTHROPIC_VERTEX_PROJECT_ID="your-project-id"
ccbox --with-gcloud
```

The `--with-gcloud` flag mounts your gcloud credentials (`~/.config/gcloud`) read-only.

**AWS Bedrock:**

```bash
export CLAUDE_CODE_USE_BEDROCK=1
export AWS_REGION="us-east-1"
ccbox
```

**Per-project provider selection** — use shell aliases, inline variables, or [direnv](https://direnv.net/):

```bash
# Shell aliases in ~/.bashrc
alias ccbox-vertex='CLAUDE_CODE_USE_VERTEX=1 ANTHROPIC_VERTEX_PROJECT_ID="my-project" ccbox --with-gcloud'
alias ccbox-anthropic='ANTHROPIC_API_KEY="sk-ant-..." ccbox'

# Inline (no persistent state)
ANTHROPIC_API_KEY="sk-ant-..." ccbox

# direnv (.envrc in project directory — auto-sets vars on cd)
# echo 'export ANTHROPIC_API_KEY="sk-ant-..."' > .envrc && direnv allow
```

### How each harness reads the key

The forwarding above gets variables *into* the container; how the harness picks them up differs:

- **ccbox (Claude Code)** — reads standard env vars directly (`ANTHROPIC_API_KEY`, `CLAUDE_CODE_USE_VERTEX` + `ANTHROPIC_VERTEX_PROJECT_ID`, `CLAUDE_CODE_USE_BEDROCK` + `AWS_*`, …). The `"env"` block in any settings file is an ordinary settings level (see precedence below). Claude Code does **not** auto-load `.env` files.
- **ocbox (OpenCode)** — for built-in providers, the key comes from `auth.json` (via `/connect` — that's the file `--with-credentials` shares) *or* from the standard env var the provider declares, e.g. `ANTHROPIC_API_KEY` (Anthropic), `OPENAI_API_KEY` (OpenAI), `OPENROUTER_API_KEY`, `GEMINI_API_KEY`, `MISTRAL_API_KEY`, `GROQ_API_KEY`, `DEEPSEEK_API_KEY`, `XAI_API_KEY`, `AZURE_API_KEY` + `AZURE_RESOURCE_NAME` (Azure), `AWS_*` (Bedrock) — all covered by the forwarded prefixes. For **custom** providers, use substitution in the config instead: `"apiKey": "{env:MY_KEY}"`. OpenCode does **not** auto-load `.env` files.
- **qcbox (Qwen Code)** — reads the API key from the env var named by `envKey` in your `modelProviders` entry (or the auth type's default, e.g. `OPENAI_API_KEY`, `DASHSCOPE_API_KEY`). Priority: shell environment > auto-loaded `.env` file > `"env"` block in settings. Qwen Code auto-loads the **first** `.env` it finds walking up from the project root: `.qwen/.env`, then `.env` (fallback: `~/.qwen/.env`, `~/.env`) — only the first file is used, and it never overrides already-set variables.
- **cxbox (Codex CLI)** — with a ChatGPT account, sign in via `codex login` (the OAuth session lands in `auth.json`, the file `--with-credentials` shares). With an API key, set `OPENAI_API_KEY` (forwarded from the host) or put a `model_providers` entry in `~/.codex/config.toml`. Codex does **not** auto-load `.env` files; it reads env vars directly.

### Per-project overrides (keep the shared config key-free)

Each project is mounted at `/workspace`, so a project-local config file lives inside the project and **overrides the shared global config** for sessions started there — without touching your `~/.claude/`, `~/.config/opencode/`, `~/.qwen/`, or `~/.codex/` files:

| Launcher | Project-local override (lives in the project, read-write) |
|----------|-----------------------------------------------------------|
| `ccbox` | `.claude/settings.local.json` (you, this project) and `.claude/settings.json` (team-shared). Precedence: project local > project > user `~/.claude/settings.json`. |
| `ocbox` | `opencode.json` / `opencode.jsonc` in the project root (or nearest git root). Project config overrides global `~/.config/opencode/opencode.json` for conflicting keys. |
| `qcbox` | `.qwen/settings.json` in the project root (project settings override user settings), and/or a project `.qwen/.env` / `.env` for keys. |
| `cxbox` | `AGENTS.md` in the project root (or nearest git root) for per-project instructions; `codex.md` for memory. (The `model_providers`/key config itself is global `~/.codex/config.toml` — use a forwarded env var for per-project keys.) |

Example — per-project key, shared config stays clean (ccbox, shown for the others by analogy):

```json
// .claude/settings.local.json in the project (gitignore it if it holds secrets)
{
  "env": { "ANTHROPIC_API_KEY": "sk-ant-..." }
}
```

```jsonc
// ocbox: opencode.json in the project
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "openai": {
      "options": { "apiKey": "{env:OPENAI_API_KEY}" }  // resolve from the forwarded env var
    }
  }
}
```

```bash
# qcbox: .qwen/.env in the project
export OPENAI_API_KEY="sk-..."
```

Note: because project-local files sit in the workspace, they are visible to whatever else works in the project — treat them accordingly (gitignore them if they hold secrets, or prefer the env-var route, which leaves no file behind).

## Pin a Version (for teams)

Each harness has its own version pin file in the repo directory: `CLAUDE_VERSION` (ccbox), `OPENCODE_VERSION` (ocbox), `QWENCODE_VERSION` (qcbox), `CODEX_VERSION` (cxbox):

```bash
echo "<version>" > ~/path/to/ccbox/CLAUDE_VERSION
```

This ensures everyone uses the same version. The `--claude-version` / `--opencode-version` / `--qwen-version` / `--codex-version` flags override the respective file.

Version pin files only exist in clone-based installs (the launcher looks for them next to its resolved location). With a flat install (scripts copied to `~/.local/bin`), the image tag defaults to `latest` — use the version flag to pin.

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

## Credentials

There are **two different things** that can hold credentials, and only one of them is gated by a flag:

1. **The harness credential store file** — a dedicated file each harness writes for OAuth sessions / API keys. This is **not** mounted by default. This is the only thing `--with-credentials` controls.
2. **The shared config file(s)** — the main settings/config each launcher always mounts (ccbox `~/.claude/settings.json`, ocbox `~/.config/opencode/opencode.json`, qcbox `~/.qwen/settings.json`, cxbox `~/.codex/config.toml`). If *you* put an API key inside one of these (an `"env"` block, or a provider's `apiKey`/`envKey`), that file travels into the container **with or without `--with-credentials`**, because the config must be mounted for the harness to behave correctly. This is a deliberate design trade-off: the config is always available, so any secret you store in it is always available too.

So: omitting `--with-credentials` does **not** guarantee a credential-free container — it only keeps the dedicated credential store file private. If you store keys in your main config, they are passed regardless. To keep the container free of a given key, don't put it in the shared config; use a forwarded environment variable (see [API Provider Configuration](#api-provider-configuration)) or a project-local override file that lives in the project, not in the shared home dir. Without any of these, plain API-key auth still needs nothing extra — provider keys are forwarded from the host environment automatically.

To share the harness's credential store file (API key or OAuth session, shared across projects), pass `--with-credentials` to any launcher:

```bash
ccbox --with-credentials   # mount ~/.claude/.credentials.json (API key or OAuth)
ocbox --with-credentials   # mount ~/.local/share/opencode/auth.json (provider credentials)
qcbox --with-credentials   # mount ~/.qwen/oauth_creds.json (Qwen OAuth)
cxbox --with-credentials   # mount ~/.codex/auth.json (API key or ChatGPT OAuth)
```

The file is mounted read-write, created (empty) on the host if it does not exist yet. Without the flag, the container uses its own empty credential file — so `claude /login` (ccbox), `opencode auth login` (ocbox), the `/auth` flow (qcbox), or `codex login` (cxbox) inside the container does not persist to the host.

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
      "--config", "/home/coder/.playwright-mcp-config.json"
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
ccbox --build          # Build native ARM64 images (the base is built natively too, since the published base is x86_64 only)
ccbox                  # Auto-detects and uses local image
```

Once a local `codebox-base:latest` exists, later `--build` runs of any harness reuse it; run `--build-base` to refresh it.

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
