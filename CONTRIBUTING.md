# Contributing

Contributions are welcome — issues and pull requests alike.

Everything you need to work on this project lives in the documentation:

- [docs/development.md](docs/development.md) — building images locally, adding OS packages and firewall domains, debug mode, linting, CI/CD and the release process
- [docs/architecture.md](docs/architecture.md) — how the shared Dockerfile, launcher engine, and per-harness mounts fit together

## Guidelines

- Keep common image layers free of any reference to the `HARNESS` build arg so the build cache stays shared across the three images.
- Put launcher behavior common to all harnesses in `lib/box-common.sh`; keep the `ccbox`/`ocbox`/`qcbox` wrappers limited to harness identity and hooks.
- Run `shellcheck ccbox ocbox qcbox lib/box-common.sh init-firewall.sh` before submitting.
- Update the relevant file under `docs/` when your change affects usage, architecture, or the development workflow.
