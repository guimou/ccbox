# Claude Code Development Container
# Based on Fedora 43 for compatibility with host environment

FROM quay.io/fedora/fedora:43

LABEL maintainer="guimou"
LABEL description="Containerized Claude Code development environment"

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

# Create non-root user 'claude' with UID 1000
# Using UID 1000 for compatibility with --userns=keep-id
RUN useradd -m -u 1000 -s /bin/bash claude && \
    mkdir -p /workspace \
             /home/claude/.claude/projects/-workspace \
             /home/claude/.claude/plugins \
             /home/claude/.claude/hooks \
             /home/claude/.claude/statsig \
             /home/claude/.claude/todos \
             /home/claude/.claude/plans \
             /home/claude/.claude/tasks \
             /home/claude/.claude/teams && \
    chown -R claude:claude /workspace /home/claude/.claude

# Copy firewall configuration
COPY firewall-domains.txt /etc/ccbox/firewall-domains.txt
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/init-firewall.sh

# Allow claude user to run firewall init as root without password
RUN echo "claude ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" >> /etc/sudoers.d/claude && \
    chmod 0440 /etc/sudoers.d/claude

# Install Claude Code using native installer
# Switch to claude user for installation
USER claude
WORKDIR /home/claude

# Claude Code version (empty = latest, or specific version like "1.0.0")
ARG CLAUDE_VERSION=""

# Install Claude Code
RUN if [ -z "${CLAUDE_VERSION}" ]; then \
        curl -fsSL https://claude.ai/install.sh | bash; \
    else \
        curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_VERSION}"; \
    fi

# Add Claude to PATH (native installer puts it in ~/.local/bin)
# Also add npm-global/bin for host-mounted npm packages
ENV PATH="/home/claude/.npm-global/bin:/home/claude/.local/bin:${PATH}"

# Configure git to use GH_TOKEN for HTTPS authentication when available
# This credential helper returns the token from the environment variable
RUN git config --global credential.helper '!f() { test -n "$GH_TOKEN" && echo "password=$GH_TOKEN"; }; f'

# tmux config for agent teams split-pane mode
RUN printf '%s\n' \
    'set -g mouse on' \
    'set -g exit-empty on' \
    > /home/claude/.tmux.conf

# Background monitor script for auto-closing orphaned tmux teammate panes.
# Polls every 3 seconds, kills non-lead panes where claude has exited
# (pane is running just bash) and the pane is older than 10 seconds
# (avoids race with pane startup before claude launches).
RUN cat > /home/claude/.ccbox-tmux-monitor.sh << 'MONITOR'
#!/bin/bash
while tmux has-session -t claude 2>/dev/null; do
    sleep 3
    now=$(date +%s)
    tmux list-panes -s -t claude -F '#{pane_id} #{pane_current_command} #{pane_created}' 2>/dev/null | \
    while read -r pane_id cmd created; do
        [ "$pane_id" = "%0" ] && continue
        if [ "$cmd" = "bash" ]; then
            age=$((now - created))
            [ "$age" -gt 10 ] && tmux kill-pane -t "$pane_id" 2>/dev/null
        fi
    done
done
MONITOR
RUN chmod +x /home/claude/.ccbox-tmux-monitor.sh

# Container-friendly Chrome flags (rootless container, limited /dev/shm)
ENV CHROME_PATH="/usr/lib64/chromium-browser/chromium-browser"
ENV CHROME_FLAGS="--no-sandbox --disable-dev-shm-usage"

# Playwright MCP: use system Chromium, skip bundled browser download
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH="/usr/lib64/chromium-browser/chromium-browser"
ENV PLAYWRIGHT_MCP_EXECUTABLE_PATH="/usr/lib64/chromium-browser/chromium-browser"

# Playwright MCP config file for reliable system browser usage
# (works around known --executable-path CLI bugs in some @playwright/mcp versions)
RUN cat > /home/claude/.playwright-mcp-config.json << 'PWCONFIG'
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

# Set working directory to workspace
WORKDIR /workspace

# Default command - start bash shell
CMD ["/bin/bash"]
