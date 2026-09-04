# Contributing

Contributions are welcome — issues and pull requests alike.

Everything you need to work on this project lives in the documentation:

- [docs/development.md](docs/development.md) — building images locally, adding OS packages and firewall domains, debug mode, linting, CI/CD and the release process
- [docs/architecture.md](docs/architecture.md) — how the base image, harness Dockerfile, launcher engine, and per-harness mounts fit together

## Guidelines

- Keep `Dockerfile.base` free of any reference to a harness: it is built once and shared by the four harness images. Harness-specific layers go in `Dockerfile`.
- Put launcher behavior common to all harnesses in `lib/box-common.sh`; keep the `ccbox`/`ocbox`/`qcbox`/`cxbox` wrappers limited to harness identity and hooks.
- Declare mounts and environment with `add_mount` / `add_optional_mount` / `add_env`, never by appending runtime flags directly: the runtime backend renders them.
- Run `shellcheck ccbox ocbox qcbox cxbox lib/box-common.sh init-firewall.sh tests/render-test.sh` and `tests/render-test.sh` before submitting; re-record the golden files (`tests/render-test.sh record`) when a change to the rendered command line is intended, and include that diff in the PR.
- Update the relevant file under `docs/` when your change affects usage, architecture, or the development workflow.
