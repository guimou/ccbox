# CCBox Update Plan — July 2026

## Context

This document captures all findings from a full review of Claude Code CLI evolution since the ccbox project was originally built. It is designed to be self-contained so work can resume from a fresh session.

### Timeline

- **ccbox script created**: February 2026 (targeting Claude Code ~v2.1.37)
- **Last significant ccbox update**: May 8, 2026 (commit `dc4a0d6`)
- **Last Dockerfile update**: June 17, 2026 (commit `966538d`, added cargo-watch)
- **Current Claude Code version**: v2.1.212 (July 17, 2026)
- **Pinned CLAUDE_VERSION file**: 2.1.201
- **Gap**: ~175 Claude Code releases since initial design

### Project Goal Reminder

CCBox runs Claude Code in a Podman rootless container with:
- Full tool access inside the container
- Limited host access (workspace mount, read-only configs)
- Project isolation (separate session data per project directory)
- Shared global config (settings, credentials, hooks, skills, agents)
- Optional network firewall
- Optional agent teams with tmux split-pane mode

### Reference: Anthropic's Official `.devcontainer`

The claude-code GitHub repo ships its own `.devcontainer/` with:
- Base: `node:20` (Debian), user `node`
- Installs Claude Code via `npm install -g @anthropic-ai/claude-code` (npm is now deprecated but still works)
- Sets `CLAUDE_CONFIG_DIR=/home/node/.claude`
- Sets `NODE_OPTIONS=--max-old-space-size=4096`
- Uses Docker volumes for config and bash history
- Includes firewall script with similar domain allowlist
- Additional VS Code marketplace domains in firewall

---

## Changes Needed

### P0: Generic Environment Variable Passthrough

**Files**: `ccbox` (lines ~580-592)

**Problem**: The script explicitly passes only `CLAUDE_CODE_USE_VERTEX`, `ANTHROPIC_VERTEX_PROJECT_ID`, and `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`. Claude Code now reads 60+ env vars. Users on Bedrock, Foundry, custom API gateways, or wanting to tune behavior cannot pass their configuration through.

**Key missing variables by category**:

Authentication/Provider:
- `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`
- `ANTHROPIC_CUSTOM_HEADERS`, `ANTHROPIC_BETAS`
- Bedrock: `CLAUDE_CODE_USE_BEDROCK`, `AWS_REGION`, `AWS_PROFILE`, `ANTHROPIC_BEDROCK_BASE_URL`, `ANTHROPIC_BEDROCK_SERVICE_TIER`, `AWS_BEARER_TOKEN_BEDROCK`
- Foundry: `ANTHROPIC_FOUNDRY_BASE_URL`, `ANTHROPIC_FOUNDRY_RESOURCE`, `ANTHROPIC_FOUNDRY_API_KEY`, `ANTHROPIC_FOUNDRY_AUTH_TOKEN`
- Claude Platform on AWS: `ANTHROPIC_AWS_API_KEY`, `ANTHROPIC_AWS_BASE_URL`, `ANTHROPIC_AWS_WORKSPACE_ID`
- Federation: `ANTHROPIC_WORKSPACE_ID`

Feature Control:
- `CLAUDE_CODE_EFFORT_LEVEL`, `CLAUDE_CODE_SAFE_MODE`
- `CLAUDE_CODE_DISABLE_AUTO_MEMORY`, `CLAUDE_CODE_DISABLE_WORKFLOWS`, `CLAUDE_CODE_DISABLE_AGENT_VIEW`
- `CLAUDE_CODE_DISABLE_BUNDLED_SKILLS`, `CLAUDE_CODE_DISABLE_ARTIFACT`
- `CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION` (default 200, new in v2.1.212)
- `CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION` (default 200, new in v2.1.212)
- `CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS` (new in v2.1.212)
- `CLAUDE_CODE_SUBAGENT_MODEL`, `CLAUDE_CODE_FORWARD_SUBAGENT_TEXT`
- `CLAUDE_CODE_RETRY_WATCHDOG`, `CLAUDE_CODE_MAX_RETRIES`
- `MAX_THINKING_TOKENS`, `DISABLE_AUTO_COMPACT`
- `CLAUDE_CODE_PROCESS_WRAPPER` (corporate launcher wrapper)

Model Overrides:
- `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`
- `ANTHROPIC_DEFAULT_FABLE_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL`
- `ANTHROPIC_CUSTOM_MODEL_OPTION` (and `_NAME`, `_DESCRIPTION`, `_SUPPORTED_CAPABILITIES`)

MCP:
- `MCP_TIMEOUT` (server startup, default 30s)
- `MCP_TOOL_TIMEOUT` (per-tool, default ~28h)
- `MAX_MCP_OUTPUT_TOKENS` (default 25,000)
- `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT`
- `ENABLE_TOOL_SEARCH`

Timeouts:
- `API_TIMEOUT_MS` (default 600s), `BASH_DEFAULT_TIMEOUT_MS` (default 120s)
- `BASH_MAX_TIMEOUT_MS` (default 600s), `BASH_MAX_OUTPUT_LENGTH`

OTEL (telemetry):
- `OTEL_METRICS_EXPORTER`, `OTEL_LOG_ASSISTANT_RESPONSES`
- `OTEL_LOG_USER_PROMPTS`, `OTEL_LOG_TOOL_DETAILS`
- `OTEL_RESOURCE_ATTRIBUTES`, `CLAUDE_CODE_ENABLE_TELEMETRY`

Other:
- `CLAUDE_AX_SCREEN_READER` (screen reader mode)
- `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN` (disable fullscreen)
- `CLAUDE_CODE_DISABLE_MOUSE_CLICKS`
- `CLAUDE_CODE_AUTO_COMPACT_WINDOW`
- `CLAUDE_CODE_DEBUG_LOG_LEVEL`, `CLAUDE_CODE_DEBUG_LOGS_DIR`
- `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`
- `CLAUDE_CODE_SKIP_PROMPT_HISTORY`
- `API_FORCE_IDLE_TIMEOUT`
- `CLAUDE_ENABLE_STREAM_WATCHDOG` (default on, set 0 to disable)

**Solution**: Replace individual forwarding with a generic passthrough block. Add this after the existing explicit env var handling (around line 592):

```bash
# Generic passthrough: forward all ANTHROPIC_* and CLAUDE_CODE_* env vars from host
while IFS='=' read -r name value; do
    PODMAN_ARGS+=(-e "${name}=${value}")
done < <(env | grep -E '^(ANTHROPIC_|CLAUDE_CODE_|CLAUDE_AX_|CLAUDE_ENABLE_|CLAUDE_AUTOCOMPACT_)')

# Also pass through specific non-prefixed vars if set
for var in DISABLE_AUTOUPDATER DISABLE_AUTO_COMPACT MAX_THINKING_TOKENS \
           MCP_TIMEOUT MCP_TOOL_TIMEOUT MAX_MCP_OUTPUT_TOKENS \
           API_TIMEOUT_MS API_FORCE_IDLE_TIMEOUT BASH_DEFAULT_TIMEOUT_MS \
           BASH_MAX_TIMEOUT_MS BASH_MAX_OUTPUT_LENGTH \
           ENABLE_TOOL_SEARCH NODE_OPTIONS \
           NO_COLOR FORCE_COLOR; do
    if [[ -n "${!var}" ]]; then
        PODMAN_ARGS+=(-e "${var}=${!var}")
    fi
done
```

**Note**: Keep the existing explicit `CLAUDE_CODE_USE_VERTEX` and `ANTHROPIC_VERTEX_PROJECT_ID` blocks — they won't conflict (duplicate `-e` flags are harmless; last wins) — or remove them since the generic passthrough covers them. Removing them is cleaner.

Also keep the explicit `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` block for `--with-teams` since that's driven by a ccbox flag, not a host env var.

---

### P0: Disable Auto-Updater in Container

**Files**: `Dockerfile`

**Problem**: Claude Code's auto-updater downloads new binaries to `~/.local/bin/claude` at startup. In a container this is wasted work — the binary is ephemeral and the update disappears on restart. It adds latency to every container launch and wastes bandwidth.

Since v2.1.207, the updater also detects "externally managed" launchers and avoids overwriting them, but the detection logic may not work correctly in the container context.

**Solution**: Add to the Dockerfile, after Claude Code installation:

```dockerfile
# Disable auto-updater in container (version controlled via image build)
ENV DISABLE_AUTOUPDATER=1
```

Alternatively, add it to the `ccbox` script as a default env var (allows override):
```bash
# Disable auto-updater by default (version is pinned via image)
PODMAN_ARGS+=(-e "DISABLE_AUTOUPDATER=${DISABLE_AUTOUPDATER:-1}")
```

The Dockerfile approach is simpler and more correct — the version should be controlled by the image build.

---

### P1: Add Missing Directory Mounts

**Files**: `ccbox` (lines ~96-106 for project dirs, lines ~119-131 for global dirs), `Dockerfile` (lines ~28-51)

**Problem**: Claude Code now uses several directories that ccbox doesn't create or mount.

#### Global directories to add (shared across projects)

| Directory | Purpose | Since |
|-----------|---------|-------|
| `workflows/` | User/saved workflow scripts (`/workflows`) | ~v2.1.154 |
| `daemon/` | Background agent daemon state, socket files | ~v2.1.139 |

#### Handling

In `ensure_global_config()`:
```bash
[[ -d "${config_dir}/workflows" ]] || mkdir -p "${config_dir}/workflows"
[[ -d "${config_dir}/daemon" ]] || mkdir -p "${config_dir}/daemon"
```

In the PODMAN_ARGS global mounts section:
```bash
-v "${CLAUDE_CONFIG_DIR}/workflows:/home/claude/.claude/workflows$(vol_flag "")"
-v "${CLAUDE_CONFIG_DIR}/daemon:/home/claude/.claude/daemon$(vol_flag "")"
```

In the Dockerfile, add to the `mkdir -p` list:
```dockerfile
/home/claude/.claude/workflows \
/home/claude/.claude/daemon \
```

**Note on daemon**: The daemon manages background agent worker processes. Within a container session, the daemon starts and works normally. Background sessions won't persist across container restarts, which is acceptable. The daemon directory should be **project-scoped** since daemon state is session-specific. Actually, on reflection, the daemon is a singleton per user — it should be **global** to avoid conflicts if Claude Code expects exactly one daemon.

**Decision needed**: Should daemon be global or project-scoped? Testing is needed. For now, mount it as global (shared) since Claude Code manages one daemon per user, not per project.

---

### P1: Update Firewall Domains

**File**: `firewall-domains.txt`

**Problem**: Missing domains that Claude Code now communicates with.

**Current list**:
```
api.anthropic.com
sentry.io
statsig.anthropic.com
statsig.com
github.com
api.github.com
registry.npmjs.org
```

**Add these**:
```
# Claude.ai (OAuth login, install script, Remote Control)
claude.ai

# Documentation (docs.anthropic.com redirects here)
code.claude.com

# Python packages (pip/uv installs)
pypi.org
files.pythonhosted.org

# Rust packages (cargo installs)
crates.io
static.crates.io
```

**Optional additions** (for specific use cases):
```
# VS Code marketplace (if using IDE integration)
# marketplace.visualstudio.com
# vscode.blob.core.windows.net

# Astral (uv/ruff updates)
# astral.sh
```

**Documentation note**: Add a comment in the file explaining that web search, web fetch, and HTTP-based MCP servers will NOT work with the firewall enabled.

**Known limitation**: The firewall resolves domains to IPs only at init time. CDN-backed services may rotate IPs during long sessions. This is the same limitation as Anthropic's official devcontainer.

---

### P1: Update CLAUDE_VERSION

**File**: `CLAUDE_VERSION`

**Current**: `2.1.201`
**Should be**: `2.1.212` (or whatever is latest at implementation time)

This is a simple file update. The CI workflow automatically creates a release when this file changes.

---

### P2: Add NODE_OPTIONS for Memory Management

**File**: `Dockerfile` or `ccbox`

**Problem**: The official devcontainer sets `NODE_OPTIONS=--max-old-space-size=4096`. Claude Code can use significant memory during long sessions, especially with many subagents, large files, or dynamic workflows.

**Solution**: Add to the Dockerfile:
```dockerfile
ENV NODE_OPTIONS="--max-old-space-size=4096"
```

Or include in the generic env passthrough (allows host override).

---

### P2: Add Managed Settings Mount

**File**: `ccbox` (optional mounts section, around line 544)

**Problem**: Enterprise deployments use managed settings at `/etc/claude-code/managed-settings.json` (Linux). These won't apply inside the container.

**Solution**:
```bash
# Enterprise managed settings (read-only)
if [[ -d /etc/claude-code ]]; then
    PODMAN_ARGS+=(-v "/etc/claude-code:/etc/claude-code$(vol_flag "ro")")
fi
```

---

### P2: Check tmux Version for Agent Teams

**Problem**: Claude Code's synchronized output for tmux (eliminates flicker) requires tmux 3.7+. The version in Fedora 43 should be verified.

**Action**: Run `dnf info tmux` in a Fedora 43 container to check. If < 3.7, consider installing from source or documenting the limitation.

Fedora 43 ships tmux 3.5a as of early 2026. Claude Code auto-detects the version and falls back gracefully, but split-pane agent teams may flicker on older tmux.

**Possible fix**: Install a newer tmux from source in the Dockerfile if Fedora's version is too old. But since Claude Code handles this gracefully, it may not be worth the added build complexity.

---

### P2: Add `--safe-mode` Flag

**File**: `ccbox` (argument parsing)

**Problem**: Since v2.1.169, `--safe-mode` starts Claude Code with all customizations disabled (CLAUDE.md, plugins, skills, hooks, MCP servers). This is useful for troubleshooting issues inside the container.

**Solution**: Add to argument parsing:
```bash
--safe-mode)
    SAFE_MODE=true
    shift
    ;;
```

And pass through to Claude:
```bash
if $SAFE_MODE; then
    EXTRA_ARGS+=(--safe-mode)
fi
```

Or users can already do `./ccbox -- --safe-mode`. A first-class flag is a nice-to-have, not essential.

---

### P3: Documentation Updates

**File**: `CLAUDE.md`, `README.md`

Items to document:

1. **Auto mode**: `./ccbox -- --permission-mode auto` (no longer needs opt-in as of v2.1.207 for Bedrock/Vertex/Foundry; doesn't require consent as of v2.1.152)

2. **Background agents**: Work within a session but don't persist across container restarts. `claude agents` view is available inside the container.

3. **Dynamic workflows**: Available inside the container. Spawn hundreds of background agents for complex tasks. Use `/workflows` to monitor.

4. **Firewall limitations**: When `--with-firewall` is enabled:
   - Web search (`WebSearch` tool) will NOT work (requires access to arbitrary domains)
   - Web fetch (`WebFetch` tool) will NOT work
   - HTTP-based MCP servers (remote servers) will NOT work
   - Only stdio MCP servers (local processes) work behind the firewall

5. **MCP servers**: Project `.mcp.json` files work out of the box. MCP servers requiring binaries not in the container will fail — install them in the Dockerfile or use `npx` (available in container).

6. **Agent teams simplified**: Since v2.1.178, `TeamCreate`/`TeamDelete` tools were removed. Every session has one implicit team. Teammates spawn via the Agent tool's `name` parameter. `--with-teams` still needed to enable the feature.

7. **Teammate display modes**: Default is now `in-process` (since v2.1.179). `--with-tmux` enables split-pane mode. Also available: `iterm2` mode (v2.1.186+, not relevant in container).

8. **Voice mode**: Not supported (requires SoX audio tool and microphone access).

9. **Remote Control**: Requires `claude.ai` domain access. Works inside container if `claude.ai` is in the firewall allowlist (or firewall is disabled).

10. **Permission modes**: Default mode is now called "manual" (renamed from "default" in v2.1.200).

11. **Environment variables**: All `ANTHROPIC_*` and `CLAUDE_CODE_*` env vars from the host are automatically passed through.

12. **Model selection**: Pass `--model` via `./ccbox -- --model opus` or set `ANTHROPIC_MODEL` in the environment.

13. **Effort levels**: `./ccbox -- --effort high` or set `CLAUDE_CODE_EFFORT_LEVEL` in the environment.

14. **Resume sessions**: Within a container session, use `claude --resume` or `/resume` to resume previous conversations. These don't persist across container restarts.

---

### P3: Misc Dockerfile Improvements

**git-delta**: Consider adding for better diff rendering:
```dockerfile
ARG GIT_DELTA_VERSION=0.18.2
RUN curl -sSL "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/delta-${GIT_DELTA_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
    | tar xzf - --strip-components=1 -C /usr/local/bin "delta-${GIT_DELTA_VERSION}-x86_64-unknown-linux-musl/delta"
```

**kubernetes package**: `kubernetes1.33-client` is version-pinned in the package name and will need updating when Fedora ships k8s 1.34+. Consider using `kubernetes-client` if available as an unversioned package.

**OpenShift CLI**: Currently uses `ocp/stable` (floating URL). Consider pinning to a specific version for build reproducibility.

---

## What NOT to Change

1. **Installation method**: The Dockerfile already uses `curl -fsSL https://claude.ai/install.sh | bash` which is the recommended method. npm install is deprecated but ccbox never used it.

2. **Base image**: Fedora 43 is a deliberate choice for host compatibility (SELinux, Podman, etc.). The official devcontainer uses Debian/node:20 which has different tradeoffs.

3. **User UID 1000**: Required for `--userns=keep-id` compatibility. No change needed.

4. **SELinux `:z` labels**: Still correct for shared relabeling across multi-session containers.

5. **Project isolation model**: The `ccbox-projects/` structure with path-hash directories still works well.

6. **Session ID generation**: UUID-based session IDs are still appropriate.

7. **Clipboard/display mounts**: Wayland and X11 socket mounts are still correct.

8. **Git credential helper**: The `GH_TOKEN`-based credential helper still works fine.

9. **Playwright MCP config**: System Chromium approach still works. The env vars and config file are correct.

10. **PulseAudio socket mount**: Still correct for audio support on Linux.

---

## Implementation Order

When implementing, follow this sequence to minimize conflicts:

1. **Update `CLAUDE_VERSION`** to current version (trivial, good smoke test)
2. **Update `firewall-domains.txt`** (trivial, no code changes)
3. **Update `Dockerfile`**:
   - Add `DISABLE_AUTOUPDATER=1`
   - Add `NODE_OPTIONS=--max-old-space-size=4096`
   - Add missing directories to the `mkdir -p` list (`workflows/`, `daemon/`)
   - Optionally add `git-delta`
4. **Update `ccbox` script**:
   - Add generic env var passthrough
   - Add missing directory creation in `ensure_global_config()`
   - Add missing directory creation in `setup_project_dirs()`
   - Add missing volume mounts (global and project-scoped)
   - Add managed settings mount (optional)
   - Optionally add `--safe-mode` flag
   - Clean up now-redundant explicit Vertex AI env var forwarding
5. **Update `CLAUDE.md`** and **`README.md`** with new features and limitations
6. **Test**: Build image, launch with various flags, verify functionality

---

## Testing Checklist

After implementing changes, verify:

- [ ] `./ccbox --build` succeeds
- [ ] `./ccbox --local` launches successfully
- [ ] `ANTHROPIC_API_KEY=xxx ./ccbox --local` passes the key to the container
- [ ] `CLAUDE_CODE_USE_BEDROCK=1 AWS_REGION=us-east-1 ./ccbox --local` passes Bedrock vars
- [ ] Auto-updater does not run at startup (check for update download messages)
- [ ] `./ccbox --local --with-firewall` works; verify `claude.ai` is reachable
- [ ] `./ccbox --local --with-teams` enables agent teams
- [ ] `./ccbox --local --with-teams --with-tmux` launches tmux with claude
- [ ] Background agents work within a session (spawn a subagent, check `claude agents`)
- [ ] Dynamic workflows work (ask Claude to "run a workflow")
- [ ] `/resume` shows previous conversations within the same container session
- [ ] MCP servers defined in `.mcp.json` are loaded
- [ ] Firewall blocks `example.com` but allows `api.anthropic.com` and `claude.ai`
- [ ] Settings persist between sessions (same project directory)
- [ ] Multiple sessions can run simultaneously (different terminal windows)

---

## Reference: Key Claude Code Versions & Their Changes

| Version | Date | Key Changes Relevant to CCBox |
|---------|------|-------------------------------|
| 2.1.139 | ~Apr 2026 | Agent view (`claude agents`), `/goal` command, background daemon |
| 2.1.152 | ~May 2026 | Auto mode no longer requires consent; `/code-review` replaces `/simplify` |
| 2.1.154 | ~May 2026 | Dynamic workflows (tens to hundreds of background agents) |
| 2.1.169 | ~Jun 2026 | `--safe-mode`, `/cd` command, `CLAUDE_CODE_DISABLE_BUNDLED_SKILLS` |
| 2.1.170 | ~Jun 2026 | Fable 5 model; `fallbackModel` setting |
| 2.1.178 | ~Jun 2026 | Agent teams simplified: `TeamCreate`/`TeamDelete` removed, implicit team |
| 2.1.196 | ~Jul 2026 | Sonnet 5 default model (1M context); org default models |
| 2.1.198 | ~Jul 2026 | `--bg` flag; subagents run in background by default |
| 2.1.200 | ~Jul 2026 | Permission mode renamed "manual"; `AskUserQuestion` no longer auto-continues |
| 2.1.207 | ~Jul 2026 | Auto mode without opt-in on Bedrock/Vertex/Foundry; `autoMode` in `settings.local.json` ignored |
| 2.1.208 | ~Jul 2026 | Screen reader mode; `CLAUDE_CODE_PROCESS_WRAPPER`; vim insert remaps |
| 2.1.210 | ~Jul 2026 | `isolation: 'worktree'` subagent fix; auto-mode classifier defaults to Sonnet 5 |
| 2.1.212 | Jul 17, 2026 | `/fork` → background session; session caps for web searches and subagents; MCP auto-background |
