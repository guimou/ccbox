# Development

## File Structure

| File | Description |
|------|-------------|
| `Dockerfile` | Container image definition (Fedora 44 base), parameterized by `HARNESS`/`HARNESS_VERSION` build args |
| `lib/box-common.sh` | Shared launcher engine (sourced by all three launchers) |
| `ccbox` / `ocbox` / `qcbox` | Host launch scripts (thin wrappers defining harness identity, mounts, and env passthrough) |
| `CLAUDE_VERSION` / `OPENCODE_VERSION` / `QWENCODE_VERSION` | Harness version pin files |
| `os-packages.txt` | DNF packages to install (one per line) |
| `firewall-domains.txt` | Allowed network domains common to all harnesses |
| `firewall-domains-{claude,opencode,qwencode}.txt` | Harness-specific allowed domains, concatenated with the common file at build time |
| `init-firewall.sh` | Firewall initialization script (iptables/ipset) |
| `.github/workflows/release.yml` | Release workflow (detects which harnesses to build) |
| `.github/workflows/build-and-push.yml` | Reusable per-harness image build |

See [architecture.md](architecture.md) for how the Dockerfile, engine, and wrappers fit together.

## Building Locally

```bash
# Build with the version from the pin file
./ccbox --build

# Build a specific version
./ccbox --build --claude-version <version>

# Use the locally-built image
./ccbox --local

# Same for the other harnesses (each builds its own image from the shared Dockerfile)
./ocbox --build
./qcbox --build
```

Common image layers never reference the `HARNESS` build arg, so building a second harness locally reuses the shared layer cache.

## Adding OS Packages

Edit `os-packages.txt` (one package per line) and rebuild:

```bash
echo "package-name" >> os-packages.txt
./ccbox --build
./ccbox --local
```

## Adding Firewall Domains

Edit `firewall-domains.txt` (all harnesses) or the harness-specific overlay (e.g. `firewall-domains-opencode.txt`) and rebuild:

```bash
echo "example.com" >> firewall-domains.txt
./ccbox --build
./ccbox --local --with-firewall
```

## Debug Mode

Set `DEBUG=1` to print the full podman command before execution:

```bash
DEBUG=1 ccbox
```

## Linting

Launchers and the engine are shellcheck-clean:

```bash
shellcheck ccbox ocbox qcbox lib/box-common.sh init-firewall.sh
```

## CI/CD

### Release workflow (`release.yml`)

Runs on pushes to `main` touching image/launcher files, and detects which harnesses are affected:

| Change | Effect | Git tag | Image tag |
|--------|--------|---------|-----------|
| Version pin file bump (e.g. `OPENCODE_VERSION`) | Release that harness | `{box}-v{version}` (e.g. `ocbox-v1.19.0`) | `{version}` |
| Shared file (`Dockerfile`, `os-packages.txt`, `firewall-domains.txt`, `init-firewall.sh`, `lib/`) | Rebuild **all** harnesses | `{box}-v{version}-N` | `{version}-N` |
| Harness-specific file (launcher script, firewall overlay) | Rebuild **only** that harness | `{box}-v{version}-N` | `{version}-N` |

The `-N` suffix increments from existing `{box}-v{version}-*` tags. If the computed tag already exists, that harness is skipped. Multiple simultaneous changes (e.g. two version bumps in one push) release multiple harnesses via a build matrix. A GitHub Release is created per released harness; changelog ranges use the previous `{box}-v*` tag (with a fallback to legacy unprefixed `v*` tags for ccbox).

### Build workflow (`build-and-push.yml`)

Reusable workflow called by the release matrix, also manually dispatchable from the Actions UI with a `harness` input (`claude` / `opencode` / `qwencode`) and optional version/tag overrides. It resolves the harness to its image repository and version file, then builds with `HARNESS` and `HARNESS_VERSION` build args. Build caches are scoped per harness (`type=gha,scope={harness}`).

### Image tags

Each harness pushes to its own repository (`quay.io/guimou/ccbox`, `quay.io/guimou/ocbox`, `quay.io/guimou/qcbox`) with tags:

| Tag | Description |
|-----|-------------|
| `latest` | Most recent build |
| `X.Y.Z` (or `X.Y.Z-N`) | Harness version (with rebuild suffix) |
| `abc1234` | Git commit SHA (short) |

### Releasing a new harness version

```bash
echo "2.1.37" > CLAUDE_VERSION      # or OPENCODE_VERSION / QWENCODE_VERSION
git add CLAUDE_VERSION
git commit -m "chore: bump Claude Code version to 2.1.37"
git push origin main
```

### Setting up Quay.io credentials

To enable CI/CD pushes, configure GitHub repository secrets:

1. **Create a Quay.io robot account:**
   - Log in to [quay.io](https://quay.io) → Account Settings → Robot Accounts
   - Create a robot account (e.g., `github_actions`)
   - Grant **Write** permission to the `guimou/ccbox`, `guimou/ocbox`, and `guimou/qcbox` repositories
2. **Add GitHub secrets** (repository Settings → Secrets and variables → Actions):

   | Secret | Value |
   |--------|-------|
   | `QUAY_USERNAME` | Robot account name (e.g., `guimou+github_actions`) |
   | `QUAY_PASSWORD` | Robot account token |

### Pulling pre-built images manually

```bash
podman pull quay.io/guimou/ccbox:latest
podman pull quay.io/guimou/ocbox:<version>
```
