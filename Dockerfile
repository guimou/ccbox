# Containerized AI coding harness development environment
# Based on Fedora 44
#
# One Dockerfile builds four images, selected via the HARNESS build arg:
#   HARNESS=claude   -> ccbox (Claude Code)
#   HARNESS=opencode -> ocbox (OpenCode)
#   HARNESS=qwencode -> qcbox (Qwen Code)
#   HARNESS=codex    -> cxbox (Codex CLI)
#
# All common layers come first and never reference HARNESS, so the build
# cache is shared across the four images. Harness-specific layers are
# grouped at the end.

FROM quay.io/fedora/fedora:44

LABEL maintainer="guimou"
LABEL description="Containerized AI coding harness development environment"

# Set timezone (can be overridden at build time)
ARG TZ=UTC
ENV TZ=${TZ}

# Copy package list and install OS packages
COPY os-packages.txt /tmp/os-packages.txt
RUN dnf upgrade -y && \
    # Filter out comments and empty lines, then install packages
    grep -v '^#' /tmp/os-packages.txt | grep -v '^$' | xargs dnf install -y && \
    dnf clean all && \
    rm -rf /var/cache/dnf /tmp/os-packages.txt

# Install OpenShift CLI (oc) - not available in Fedora repos
RUN curl -sSL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz \
    | tar xzf - -C /usr/local/bin oc

# Create non-root user 'coder' with UID 1000
# Using UID 1000 for compatibility with --userns=keep-id
RUN useradd -m -u 1000 -s /bin/bash coder && \
    mkdir -p /workspace /home/coder/.config && \
    chown -R coder:coder /workspace /home/coder/.config

# Firewall initialization script (domains file baked per harness below)
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/init-firewall.sh

# Allow coder user to run firewall init as root without password
RUN echo "coder ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" >> /etc/sudoers.d/coder && \
    chmod 0440 /etc/sudoers.d/coder

# Install uv (fast Python package manager, includes uvx)
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh

# Pre-install common Python dev tools (repeatedly needed across projects)
RUN pip install --break-system-packages pytest pytest-asyncio mypy httpx ruff pyright pytest-cov

# Pre-install common Node.js dev tools
# LSP servers (required by LSP plugins), formatter, TS runner
RUN npm install -g typescript typescript-language-server prettier tsx yarn

# Switch to coder user for user-level tooling and config
USER coder
WORKDIR /home/coder

# Install Rust toolchain
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    --default-toolchain stable --profile default --component rust-analyzer
ENV PATH="/home/coder/.cargo/bin:${PATH}"
RUN cargo install cargo-watch

# Configure git to use GH_TOKEN for HTTPS authentication when available
# This credential helper returns the token from the environment variable
RUN git config --global credential.helper '!f() { test -n "$GH_TOKEN" && echo "password=$GH_TOKEN"; }; f'

# tmux config for agent teams split-pane mode
RUN printf '%s\n' \
    'set -g mouse on' \
    'set -g exit-empty on' \
    > /home/coder/.tmux.conf

# Background monitor script for auto-closing orphaned tmux teammate panes.
# Polls every 3 seconds, kills non-lead panes where the harness has exited
# (pane is running just bash) and the pane is older than 10 seconds
# (avoids race with pane startup before the harness launches).
RUN cat > /home/coder/.ccbox-tmux-monitor.sh << 'MONITOR'
#!/bin/bash
while tmux has-session -t coder 2>/dev/null; do
    sleep 3
    now=$(date +%s)
    tmux list-panes -s -t coder -F '#{pane_id} #{pane_current_command} #{pane_created}' 2>/dev/null | \
    while read -r pane_id cmd created; do
        [ "$pane_id" = "%0" ] && continue
        if [ "$cmd" = "bash" ]; then
            age=$((now - created))
            [ "$age" -gt 10 ] && tmux kill-pane -t "$pane_id" 2>/dev/null
        fi
    done
done
MONITOR
RUN chmod +x /home/coder/.ccbox-tmux-monitor.sh

# Container-friendly Chrome flags (rootless container, limited /dev/shm)
ENV CHROME_PATH="/usr/lib64/chromium-browser/chromium-browser"
ENV CHROME_FLAGS="--no-sandbox --disable-dev-shm-usage"

# Playwright MCP: use system Chromium, skip bundled browser download
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH="/usr/lib64/chromium-browser/chromium-browser"
ENV PLAYWRIGHT_MCP_EXECUTABLE_PATH="/usr/lib64/chromium-browser/chromium-browser"

# Playwright MCP config file for reliable system browser usage
# (works around known --executable-path CLI bugs in some @playwright/mcp versions)
RUN cat > /home/coder/.playwright-mcp-config.json << 'PWCONFIG'
{
  "browser": {
    "browserName": "chromium",
    "launchOptions": {
      "executablePath": "/usr/lib64/chromium-browser/chromium-browser",
      "args": ["--no-sandbox", "--disable-dev-shm-usage"]
    }
  }
}
PWCONFIG

# Match official devcontainer memory settings
ENV NODE_OPTIONS="--max-old-space-size=4096"

# Add user-level install locations to PATH:
# - ~/.local/bin (Claude Code native installer)
# - ~/.npm-global/bin (host-mounted npm packages)
ENV PATH="/home/coder/.npm-global/bin:/home/coder/.local/bin:${PATH}"

# Disable auto-updaters in container (version controlled via image build).
# Each harness only reads its own variable; setting all is harmless.
ENV DISABLE_AUTOUPDATER=1
ENV OPENCODE_DISABLE_AUTOUPDATE=1
ENV CODEX_DISABLE_AUTOUPDATE=1

# ---------------------------------------------------------------------------
# Harness-specific layers start here
# ---------------------------------------------------------------------------

# Which harness to install: claude | opencode | qwencode | codex
ARG HARNESS=claude
# Harness version (empty = latest, or a specific version like "2.1.226")
ARG HARNESS_VERSION=""

USER root

# Bake the firewall allowlist: common domains + harness-specific overlay
COPY firewall-domains.txt firewall-domains-${HARNESS}.txt /tmp/firewall/
RUN mkdir -p /etc/codebox && \
    cat /tmp/firewall/firewall-domains.txt "/tmp/firewall/firewall-domains-${HARNESS}.txt" \
        > /etc/codebox/firewall-domains.txt && \
    rm -rf /tmp/firewall

# Pre-create harness state directories (mount targets for the launcher),
# install npm-based harnesses (binary lands in /usr/local/bin), and bake
# harness system defaults
RUN set -eu; \
    case "${HARNESS}" in \
    claude) \
        mkdir -p /home/coder/.claude/projects/-workspace \
                 /home/coder/.claude/plugins \
                 /home/coder/.claude/hooks \
                 /home/coder/.claude/commands \
                 /home/coder/.claude/skills \
                 /home/coder/.claude/agents \
                 /home/coder/.claude/rules \
                 /home/coder/.claude/themes \
                 /home/coder/.claude/statsig \
                 /home/coder/.claude/todos \
                 /home/coder/.claude/plans \
                 /home/coder/.claude/tasks \
                 /home/coder/.claude/teams \
                 /home/coder/.claude/file-history \
                 /home/coder/.claude/paste-cache \
                 /home/coder/.claude/cache \
                 /home/coder/.claude/backups \
                 /home/coder/.claude/shell-snapshots \
                 /home/coder/.claude/session-env \
                 /home/coder/.claude/logs \
                 /home/coder/.claude/debug \
                 /home/coder/.claude/workflows \
                 /home/coder/.claude/daemon && \
        echo '{}' > /home/coder/.claude/.credentials.json && \
        chown -R coder:coder /home/coder/.claude ;; \
    opencode) \
        npm install -g "opencode-ai@${HARNESS_VERSION:-latest}" && \
        mkdir -p /home/coder/.config/opencode \
                 /home/coder/.local/share/opencode \
                 /home/coder/.local/state/opencode \
                 /home/coder/.cache/opencode && \
        # Empty credentials store (host auth.json is opt-in via --with-credentials)
        echo '{}' > /home/coder/.local/share/opencode/auth.json && \
        chown -R coder:coder /home/coder/.config /home/coder/.local /home/coder/.cache ;; \
    qwencode) \
        npm install -g "@qwen-code/qwen-code@${HARNESS_VERSION:-latest}" && \
        mkdir -p /home/coder/.qwen/tmp \
                 /home/coder/.qwen/file-history && \
        # Empty credentials store (host oauth_creds.json is opt-in via --with-credentials)
        echo '{}' > /home/coder/.qwen/oauth_creds.json && \
        chown -R coder:coder /home/coder/.qwen && \
        # System defaults: pin version (no auto-update) and never nest the
        # Qwen sandbox inside this container
        mkdir -p /etc/qwen-code && \
        printf '%s\n' '{ "general": { "enableAutoUpdate": false }, "tools": { "sandbox": false } }' \
            > /etc/qwen-code/settings.json ;; \
    codex) \
        npm install -g "@openai/codex@${HARNESS_VERSION:-latest}" && \
        mkdir -p /home/coder/.codex && \
        # Empty credentials store (host auth.json is opt-in via --with-credentials)
        echo '{}' > /home/coder/.codex/auth.json && \
        chown -R coder:coder /home/coder/.codex ;; \
    *) echo "Unknown HARNESS: ${HARNESS}" >&2; exit 1 ;; \
    esac

USER coder

# Install Claude Code using native installer (claude harness only)
RUN if [ "${HARNESS}" = "claude" ]; then \
        if [ -z "${HARNESS_VERSION}" ]; then \
            curl -fsSL https://claude.ai/install.sh | bash; \
        else \
            curl -fsSL https://claude.ai/install.sh | bash -s -- "${HARNESS_VERSION}"; \
        fi; \
    fi

# Set working directory to workspace
WORKDIR /workspace

# Default command - start bash shell
CMD ["/bin/bash"]
