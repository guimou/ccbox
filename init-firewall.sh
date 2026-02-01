#!/bin/bash
# Firewall initialization script for Claude Code container
# Restricts network access to allowed domains only

set -e

DOMAINS_FILE="/etc/ccbox/firewall-domains.txt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root"
    exit 1
fi

# Check if domains file exists
if [[ ! -f "$DOMAINS_FILE" ]]; then
    log_error "Domains file not found: $DOMAINS_FILE"
    exit 1
fi

log_info "Initializing firewall..."

# Get the host network (for Podman networking)
HOST_NETWORK=$(ip route | grep default | awk '{print $3}' | head -1)
if [[ -n "$HOST_NETWORK" ]]; then
    HOST_CIDR="${HOST_NETWORK%.*}.0/24"
    log_info "Detected host network: $HOST_CIDR"
fi

# Flush existing rules
log_info "Flushing existing iptables rules..."
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

# Create ipset for allowed IPs
log_info "Creating ipset for allowed domains..."
ipset destroy allowed-domains 2>/dev/null || true
ipset create allowed-domains hash:net

# Function to resolve domain and add IPs to ipset
resolve_and_add() {
    local domain="$1"
    local ips

    # Resolve domain to IPs
    ips=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)

    if [[ -z "$ips" ]]; then
        log_warn "Could not resolve: $domain"
        return
    fi

    for ip in $ips; do
        ipset add allowed-domains "$ip/32" 2>/dev/null || true
        log_info "  Added $ip ($domain)"
    done
}

# Read domains from file and resolve them
log_info "Resolving allowed domains..."
while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip empty lines and comments
    line=$(echo "$line" | sed 's/#.*//' | xargs)
    [[ -z "$line" ]] && continue

    resolve_and_add "$line"
done < "$DOMAINS_FILE"

# Add GitHub CIDRs via API (they publish their IP ranges)
log_info "Fetching GitHub IP ranges..."
GITHUB_META=$(curl -s https://api.github.com/meta 2>/dev/null || true)
if [[ -n "$GITHUB_META" ]]; then
    for cidr in $(echo "$GITHUB_META" | jq -r '.web[], .api[], .git[]' 2>/dev/null | grep -v null || true); do
        ipset add allowed-domains "$cidr" 2>/dev/null || true
    done
    log_info "  Added GitHub IP ranges"
fi

# Set default policies to DROP
log_info "Setting default policies to DROP..."
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Allow loopback
log_info "Allowing loopback traffic..."
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established connections
log_info "Allowing established connections..."
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow DNS (needed for domain resolution)
log_info "Allowing DNS traffic..."
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# Allow host network (for Podman networking)
if [[ -n "$HOST_CIDR" ]]; then
    log_info "Allowing host network: $HOST_CIDR"
    iptables -A OUTPUT -d "$HOST_CIDR" -j ACCEPT
fi

# Allow traffic to allowed domains
log_info "Allowing traffic to allowed domains..."
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Reject everything else with ICMP feedback
log_info "Setting up reject rules for other traffic..."
iptables -A OUTPUT -j REJECT --reject-with icmp-net-unreachable

# Verify firewall is working
log_info "Verifying firewall configuration..."

# Test that blocked domain fails
if curl -s --connect-timeout 2 https://example.com >/dev/null 2>&1; then
    log_warn "Firewall verification: example.com should be blocked but is accessible"
else
    log_info "Firewall verification: example.com correctly blocked"
fi

# Test that allowed domain works
if curl -s --connect-timeout 5 https://api.anthropic.com >/dev/null 2>&1; then
    log_info "Firewall verification: api.anthropic.com accessible"
else
    log_warn "Firewall verification: api.anthropic.com not accessible (may be normal if no API key)"
fi

log_info "Firewall initialization complete!"
log_info "Allowed domains: $(ipset list allowed-domains 2>/dev/null | tail -n +9 | wc -l) entries"
