# Contributing to ccbox

## Local Development

### Building the image

```bash
# Build locally (creates ccbox:latest)
./ccbox --build

# Build a specific version
./ccbox --build --claude-version 2.1.31

# Use locally-built image instead of pulling from registry
./ccbox --local
```

### Adding OS packages

Edit `os-packages.txt` (one package per line) and rebuild:

```bash
echo "package-name" >> os-packages.txt
./ccbox --build
```

### Adding firewall domains

Edit `firewall-domains.txt` and rebuild:

```bash
echo "example.com" >> firewall-domains.txt
./ccbox --build
```

## File Structure

| File | Description |
|------|-------------|
| `ccbox` | Host launch script |
| `Dockerfile` | Container image definition (Fedora 43 base) |
| `CLAUDE_VERSION` | Claude Code version for builds |
| `os-packages.txt` | DNF packages to install |
| `firewall-domains.txt` | Allowed domains when firewall is enabled |
| `init-firewall.sh` | Firewall initialization script (iptables/ipset) |
| `CLAUDE.md` | Claude Code project instructions |

## CI/CD

The container image is automatically built and pushed to `quay.io/guimou/ccbox` when changes are pushed to the `main` branch.

### Automatic Build Triggers

The workflow triggers on changes to:

- `CLAUDE_VERSION` - Claude Code version file
- `Dockerfile` - Container definition
- `os-packages.txt` - OS package list
- `firewall-domains.txt` - Firewall allowed domains
- `init-firewall.sh` - Firewall script

### Image Tags

| Tag | Description |
|-----|-------------|
| `latest` | Most recent build |
| `2.1.31` | Specific Claude Code version |
| `abc1234` | Git commit SHA (short) |

### Pulling Pre-built Images

```bash
# Pull the latest image
podman pull quay.io/guimou/ccbox:latest

# Pull a specific version
podman pull quay.io/guimou/ccbox:2.1.31
```

### Manual Workflow Dispatch

You can manually trigger a build from the GitHub Actions UI with an optional version override.

### Setting Up Quay.io Credentials

To enable CI/CD pushes to Quay.io, configure the following GitHub repository secrets:

1. **Create a Quay.io Robot Account:**
   - Log in to [quay.io](https://quay.io)
   - Go to Account Settings → Robot Accounts
   - Create a new robot account (e.g., `github_actions`)
   - Grant **Write** permission to the `guimou/ccbox` repository
   - Copy the robot account credentials

2. **Add GitHub Secrets:**
   - Go to your repository Settings → Secrets and variables → Actions
   - Add the following secrets:

   | Secret | Value |
   |--------|-------|
   | `QUAY_USERNAME` | Robot account name (e.g., `guimou+github_actions`) |
   | `QUAY_PASSWORD` | Robot account token |

### Updating Claude Code Version

To release a new version:

```bash
# Update the version file
echo "2.1.32" > CLAUDE_VERSION

# Commit and push
git add CLAUDE_VERSION
git commit -m "chore: bump Claude Code version to 2.1.32"
git push origin main
```
