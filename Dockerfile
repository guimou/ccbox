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
        chown -R coder:coder /home/coder/.claude && \
        # Install Claude Code to a system path, not /home/coder: an
        # OpenShell sandbox runs as an arbitrary, non-coder uid with no
        # writable /home, so the CLI must be reachable from any uid's
        # PATH. Build under a throwaway HOME so the installer's staging
        # files never land under /home/coder.
        if [ -z "${HARNESS_VERSION}" ]; then \
            HOME=/tmp/claude-build bash -c "curl -fsSL https://claude.ai/install.sh | bash"; \
        else \
            HOME=/tmp/claude-build bash -c "curl -fsSL https://claude.ai/install.sh | bash -s -- '${HARNESS_VERSION}'"; \
        fi && \
        install -m 0755 "$(readlink -f /tmp/claude-build/.local/bin/claude)" /usr/local/bin/claude && \
        rm -rf /tmp/claude-build && \
        # Build guard: when a version is pinned, the installed binary must
        # report it. Capture --version into a variable first rather than
        # piping to grep, so a failing claude --version is not masked by
        # grep's exit status (this case arm runs without pipefail).
        v=$(HOME=/tmp/cv /usr/local/bin/claude --version) && \
        case "${HARNESS_VERSION}" in \
            "") ;; \
            *) case "$v" in \
                   *"${HARNESS_VERSION}"*) ;; \
                   *) echo "claude version mismatch: got '$v', expected '${HARNESS_VERSION}'" >&2; exit 1 ;; \
               esac ;; \
        esac && \
        rm -rf /tmp/cv && \
        printf '%s\n' '/sandbox/.claude' > /etc/codebox/sandbox-state-dirs ;; \
    opencode) \
        npm install -g "opencode-ai@${HARNESS_VERSION:-latest}" && \
        mkdir -p /home/coder/.config/opencode \
                 /home/coder/.local/share/opencode \
                 /home/coder/.local/state/opencode \
                 /home/coder/.cache/opencode && \
        # Empty credentials store (host auth.json is opt-in via --with-credentials)
        echo '{}' > /home/coder/.local/share/opencode/auth.json && \
        chown -R coder:coder /home/coder/.config /home/coder/.local /home/coder/.cache && \
        printf '%s\n' /sandbox/.config/opencode /sandbox/.local/share/opencode \
            /sandbox/.local/state/opencode /sandbox/.cache/opencode \
            > /etc/codebox/sandbox-state-dirs ;; \
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
            > /etc/qwen-code/settings.json && \
        printf '%s\n' /sandbox/.qwen > /etc/codebox/sandbox-state-dirs ;; \
    codex) \
        npm install -g "@openai/codex@${HARNESS_VERSION:-latest}" && \
        # Mount target only: the launcher mounts the per-project data dir
        # as the whole ~/.codex (config.toml / auth.json are mounted on top)
        mkdir -p /home/coder/.codex && \
        chown -R coder:coder /home/coder/.codex && \
        printf '%s\n' /sandbox/.codex > /etc/codebox/sandbox-state-dirs ;; \
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
        mkdir -p /etc/codebox && printf 'startup:\n  checkUpdate: false\n' > /etc/codebox/omp-config.yml && \
        # Extract native addons (~340 MB) to a system path readable by any
        # uid, not ~/.omp/natives: an OpenShell sandbox has no writable
        # /home, and the extraction only needs to happen once at build
        # time. Build under a throwaway HOME so staging files never land
        # under /home/coder.
        HOME=/tmp/omp-build PI_NATIVES_DIR=/usr/local/lib/omp/natives \
            PI_CONFIG_FILES=/etc/codebox/omp-config.yml /usr/local/bin/omp config path && \
        rm -rf /tmp/omp-build && \
        chmod -R a+rX,go-w /usr/local/lib/omp && \
        # omp >= 19.1.1 sets explicit timestamps on natives/<version> at
        # every start (utimes), which only the owner may do: a root-owned
        # dir aborts with "EPERM ... utime". Hand it to coder (uid 1000 =
        # the session user under podman keep-id and in the k8s pod).
        # ponytail: an OpenShell sandbox uid still hits EPERM; drop this
        # chown once can1357/oh-my-pi#20267 (use a present addon without
        # the touch) ships.
        chown -R coder:coder /usr/local/lib/omp && \
        # Build guard: the native addon for this arch must have extracted
        find /usr/local/lib/omp/natives -name 'pi_natives.*.node' | grep -q . && \
        printf '%s\n' /sandbox/.omp > /etc/codebox/sandbox-state-dirs ;; \
    *) echo "Unknown HARNESS: ${HARNESS}" >&2; exit 1 ;; \
    esac

# OpenShell runtime contract (all harnesses): bridge the image's state dirs
# into a sandbox that mounts nothing but the repo under /sandbox/repos.
#   - /sandbox itself stays root 0755: the sandbox uid has no gid 0 (the
#     OpenShift "chgrp 0 / g=u" pattern does not apply), so sharing it
#     writable would make every harness's state world-writable too.
#   - Each state dir from /etc/codebox/sandbox-state-dirs (written by the
#     case arm above) is pre-created at 0777: Landlock grants the sandbox
#     policy only paths that already exist at sandbox start, and 0777 (not
#     1777) is deliberate — the sticky bit only matters when other uids
#     share a dir, and some harnesses save by renaming over existing files.
#   - /etc/profile.d is sourced by the sandbox's login shell even though
#     image ENV itself is not; zz-codebox-openshell.sh carries the
#     per-image env there, guarded by OPENSHELL_SANDBOX so it is a no-op on
#     the workstation. The `:=` defaults mean spec.env or provider env
#     always wins.
RUN set -e; \
    mkdir -p /sandbox && chmod 0755 /sandbox && \
    while read -r d; do mkdir -p "$d" && chmod 0777 "$d" || exit 1; done < /etc/codebox/sandbox-state-dirs && \
    install -m 0644 /dev/stdin /etc/profile.d/zz-codebox-openshell.sh << 'EOF'
if [ -n "${OPENSHELL_SANDBOX:-}" ]; then
  : "${DISABLE_AUTOUPDATER:=1}"; export DISABLE_AUTOUPDATER
  : "${OPENCODE_DISABLE_AUTOUPDATE:=1}"; export OPENCODE_DISABLE_AUTOUPDATE
  : "${PI_CONFIG_FILES:=/etc/codebox/omp-config.yml}"; export PI_CONFIG_FILES
  : "${PI_NATIVES_DIR:=/usr/local/lib/omp/natives}"; export PI_NATIVES_DIR
  : "${CLAUDE_CONFIG_DIR:=${HOME}/.claude}"; export CLAUDE_CONFIG_DIR
fi
EOF

USER coder

# Workstation compatibility: claude now installs to /usr/local/bin (claude
# harness only), already on every PATH, but Dockerfile.base also puts
# ~/.local/bin on PATH for the native installer's usual location. Keep that
# path working with a symlink rather than a second copy of the binary.
RUN if [ "${HARNESS}" = "claude" ]; then \
        mkdir -p ~/.local/bin && ln -sfn /usr/local/bin/claude ~/.local/bin/claude; \
    fi

# System defaults overlay for Oh My Pi (pins startup.checkUpdate off); other
# harnesses ignore this env var. Set unconditionally since ENV cannot be
# scoped to one arm of the case above.
ENV PI_CONFIG_FILES=/etc/codebox/omp-config.yml

# Natives now extract at build time into a system path (see the omp arm
# above), readable by any uid; other harnesses ignore this env var. Set
# unconditionally for the same reason as PI_CONFIG_FILES above.
ENV PI_NATIVES_DIR=/usr/local/lib/omp/natives

# Set working directory to workspace
WORKDIR /workspace

# Default command - start bash shell
CMD ["/bin/bash"]
