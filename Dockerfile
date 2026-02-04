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
             /home/claude/.claude/tasks && \
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

# Set working directory to workspace
WORKDIR /workspace

# Default command - start bash shell
CMD ["/bin/bash"]
