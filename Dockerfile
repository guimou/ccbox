# Containerized AI coding harness development environment - HARNESS image
#
# One Dockerfile builds five images, selected via the HARNESS build arg:
#   HARNESS=claude   -> ccbox (Claude Code)
#   HARNESS=opencode -> ocbox (OpenCode)
#   HARNESS=qwencode -> qcbox (Qwen Code)
#   HARNESS=codex    -> cxbox (Codex CLI)
#   HARNESS=omp      -> ompbox (Oh My Pi)
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

# Provided by podman/buildah on multi-arch builds; falls back to `uname -m`
# below for engines that do not set it (e.g. a plain `docker build`).
ARG TARGETARCH

# Which harness to install: claude | opencode | qwencode | codex | omp
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
    omp) \
        arch="${TARGETARCH:-$(uname -m)}"; \
        case "$arch" in amd64|x86_64) asset=omp-linux-x64 ;; arm64|aarch64) asset=omp-linux-arm64 ;; *) echo "Unsupported arch: $arch" >&2; exit 1 ;; esac; \
        if [ -n "${HARNESS_VERSION}" ]; then base="https://github.com/can1357/oh-my-pi/releases/download/v${HARNESS_VERSION}"; \
        else base="https://github.com/can1357/oh-my-pi/releases/latest/download"; fi; \
        curl -fsSL "${base}/${asset}" -o /usr/local/bin/omp && \
        curl -fsSL "${base}/SHA256SUMS.txt" -o /tmp/omp.sums && \
        awk -v a="$asset" '{sub(/^\*/,"",$2)} $2==a{print $1"  /usr/local/bin/omp"}' /tmp/omp.sums | sha256sum -c - && rm -f /tmp/omp.sums && \
        chmod 0755 /usr/local/bin/omp && \
        # Mount targets: per-project agent dir + the two opt-in dotenv files (empty placeholders)
        mkdir -p /home/coder/.omp/agent && touch /home/coder/.omp/.env /home/coder/.omp/agent/.env && \
        chown -R coder:coder /home/coder/.omp && \
        # System defaults: pin version (no startup update check); loaded via PI_CONFIG_FILES
        mkdir -p /etc/codebox && printf 'startup:\n  checkUpdate: false\n' > /etc/codebox/omp-config.yml ;; \
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

# System defaults overlay for Oh My Pi (pins startup.checkUpdate off); other
# harnesses ignore this env var. Set unconditionally since ENV cannot be
# scoped to one arm of the case above.
ENV PI_CONFIG_FILES=/etc/codebox/omp-config.yml

# Oh My Pi extracts its native addons (~340 MB) into ~/.omp/natives on first
# run; do it at build time (omp harness only). `omp config path` also creates
# ~/.omp/agent/agent.db* and ~/.omp/logs; wipe the agent dir afterwards so the
# launcher's per-project mount target starts clean.
RUN if [ "${HARNESS}" = "omp" ]; then \
        set -e; \
        omp config path >/dev/null; \
        rm -rf /home/coder/.omp/agent/* && touch /home/coder/.omp/agent/.env; \
    fi

# Set working directory to workspace
WORKDIR /workspace

# Default command - start bash shell
CMD ["/bin/bash"]
