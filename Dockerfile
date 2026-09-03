# Containerized AI coding harness development environment - HARNESS image
#
# One Dockerfile builds four images, selected via the HARNESS build arg:
#   HARNESS=claude   -> ccbox (Claude Code)
#   HARNESS=opencode -> ocbox (OpenCode)
#   HARNESS=qwencode -> qcbox (Qwen Code)
#   HARNESS=codex    -> cxbox (Codex CLI)
#
# Everything harness-independent lives in Dockerfile.base and is consumed
# here through BASE_IMAGE (a published quay.io/guimou/codebox-base tag, or a
# locally built codebox-base when using `<box> --build-base`). This file only
# bakes the firewall allowlist and installs the single harness CLI, so each
# harness build is small, fast and independent of the others.

# Base image (harness-independent layers). CI pins this to the content tag of
# the base inputs; the launcher passes its own value for local builds.
ARG BASE_IMAGE=quay.io/guimou/codebox-base:latest
FROM ${BASE_IMAGE}

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
        # Mount target only: the launcher mounts the per-project data dir
        # as the whole ~/.codex (config.toml / auth.json are mounted on top)
        mkdir -p /home/coder/.codex && \
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
