# Development

## File Structure

| File | Description |
|------|-------------|
| `Dockerfile.base` | Harness-independent base image (Fedora 44, OS packages, runtimes, tools), published as `quay.io/guimou/codebox-base` |
| `Dockerfile` | Harness image built `FROM ${BASE_IMAGE}`, parameterized by `HARNESS`/`HARNESS_VERSION` build args |
| `lib/box-common.sh` | Shared launcher engine (sourced by all four launchers) |
| `ccbox` / `ocbox` / `qcbox` / `cxbox` | Host launch scripts (thin wrappers defining harness identity, mounts, and env passthrough) |
| `CLAUDE_VERSION` / `OPENCODE_VERSION` / `QWENCODE_VERSION` / `CODEX_VERSION` | Harness version pin files |
| `os-packages.txt` | DNF packages to install (one per line) |
| `firewall-domains.txt` | Allowed network domains common to all harnesses |
| `firewall-domains-{claude,opencode,qwencode,codex}.txt` | Harness-specific allowed domains, concatenated with the common file at build time |
| `init-firewall.sh` | Firewall initialization script (iptables/ipset) |
| `.github/workflows/release.yml` | Release workflow (detects which harnesses to build, builds the base once, then one job per harness) |
| `.github/workflows/build-base.yml` | Reusable base image build (content-tagged, skipped when the tag exists) |
| `.github/workflows/build-and-push.yml` | Reusable per-harness image build, tag and GitHub Release |

See [architecture.md](architecture.md) for how the base image, harness Dockerfile, engine, and wrappers fit together.

## Building Locally

```bash
# Build with the version from the pin file
./ccbox --build

# Build a specific version
./ccbox --build --claude-version <version>

# Use the locally-built image
./ccbox --local

# Same for the other harnesses (each builds its own image from the shared harness Dockerfile)
./ocbox --build
./qcbox --build
./cxbox --build

# Also build the base image locally (after editing Dockerfile.base / os-packages.txt)
./ccbox --build-base
```

`--build` only builds the harness layer (`Dockerfile`). The base it starts from is resolved in this order:

1. A local `codebox-base:latest` if one exists (built earlier with `--build-base`).
2. On arm64 hosts (Apple Silicon), the base is built natively, since the published base is x86_64 only.
3. Otherwise the published `quay.io/guimou/codebox-base:latest` is pulled.

So a harness-only change rebuilds in seconds, and a base change is built once and reused by every harness (`--build-base` for one harness, then plain `--build` for the others).

## Adding OS Packages

Edit `os-packages.txt` (one package per line) and rebuild:

```bash
echo "package-name" >> os-packages.txt
./ccbox --build-base
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
shellcheck ccbox ocbox qcbox cxbox lib/box-common.sh init-firewall.sh
```

## CI/CD

### Release workflow (`release.yml`)

Runs on pushes to `main` touching image/launcher files, and detects which harnesses are affected:

| Change | Effect | Git tag | Image tag |
|--------|--------|---------|-----------|
| Version pin file bump (e.g. `OPENCODE_VERSION`) | Release that harness | `{box}-v{version}` (e.g. `ocbox-v1.19.0`) | `{version}` |
| Base input (`Dockerfile.base`, `os-packages.txt`, `init-firewall.sh`) | Rebuild the base, then **all** harnesses | `{box}-v{version}-N` | `{version}-N` |
| Shared harness file (`Dockerfile`, `firewall-domains.txt`, `lib/`) | Rebuild **all** harnesses (base reused) | `{box}-v{version}-N` | `{version}-N` |
| Harness-specific file (launcher script, firewall overlay) | Rebuild **only** that harness | `{box}-v{version}-N` | `{version}-N` |
| Weekly schedule / manual "rebuild all" dispatch | Force-rebuild the base (Fedora updates), then **all** harnesses | `{box}-v{version}-N` | `{version}-N` |

The `-N` suffix increments from existing `{box}-v{version}-*` tags. If the computed tag already exists, that harness is skipped.

The run is structured as three jobs:

1. **detect** — computes the harness matrix above.
2. **base** — runs only if at least one harness needs a build. Calls `build-base.yml`, which computes the base content tag and skips the build when that tag already exists in `quay.io/guimou/codebox-base` (a forced refresh overwrites it).
3. **build** — one job per harness in the matrix, `fail-fast: false`, each calling `build-and-push.yml` with the base tag from step 2 and its git tag. Every harness job builds, pushes, tags and creates its GitHub Release on its own, so a failure in one harness never blocks the others. Changelog ranges use the previous `{box}-v*` tag (with a fallback to legacy unprefixed `v*` tags for ccbox).

### Base workflow (`build-base.yml`)

Reusable workflow (also manually dispatchable with a `force` input). The base tag is the short SHA of the last commit touching `Dockerfile.base`, `os-packages.txt` or `init-firewall.sh`; the image is pushed as `quay.io/guimou/codebox-base:{tag}` and `latest`. Build cache scope: `type=gha,scope=base`.

### Build workflow (`build-and-push.yml`)

Reusable workflow called once per harness by the release matrix, also manually dispatchable from the Actions UI with a `harness` input (`claude` / `opencode` / `qwencode` / `codex`) and optional version/tag/base overrides. It resolves the harness to its image repository and version file, verifies the base tag exists (derived from the commit when not given), builds `Dockerfile` with `BASE_IMAGE`, `HARNESS` and `HARNESS_VERSION` build args, pushes, and, when called with a `git_tag`, creates the git tag and GitHub Release. Build caches are scoped per harness (`type=gha,scope={harness}`).

### Image tags

Each harness pushes to its own repository (`quay.io/guimou/ccbox`, `quay.io/guimou/ocbox`, `quay.io/guimou/qcbox`, `quay.io/guimou/cxbox`) with tags:

| Tag | Description |
|-----|-------------|
| `latest` | Most recent build |
| `X.Y.Z` (or `X.Y.Z-N`) | Harness version (with rebuild suffix) |
| `abc1234` | Git commit SHA (short) |

### Releasing a new harness version

```bash
echo "2.1.37" > CLAUDE_VERSION      # or OPENCODE_VERSION / QWENCODE_VERSION / CODEX_VERSION
git add CLAUDE_VERSION
git commit -m "chore: bump Claude Code version to 2.1.37"
git push origin main
```

### Setting up Quay.io credentials

To enable CI/CD pushes, configure GitHub repository secrets:

1. **Create a Quay.io robot account:**
   - Log in to [quay.io](https://quay.io) → Account Settings → Robot Accounts
   - Create a robot account (e.g., `github_actions`)
   - Grant **Write** permission to the `guimou/codebox-base`, `guimou/ccbox`, `guimou/ocbox`, `guimou/qcbox`, and `guimou/cxbox` repositories
2. **Add GitHub secrets** (repository Settings → Secrets and variables → Actions):

   | Secret | Value |
   |--------|-------|
   | `QUAY_USERNAME` | Robot account name (e.g., `guimou+github_actions`) |
   | `QUAY_PASSWORD` | Robot account token |

### Pulling pre-built images manually

```bash
podman pull quay.io/guimou/ccbox:latest
podman pull quay.io/guimou/ocbox:<version>
podman pull quay.io/guimou/cxbox:<version>
```
