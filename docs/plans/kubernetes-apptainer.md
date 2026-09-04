# Plan: running the boxes on Kubernetes / OpenShift with Apptainer

Status: draft, not started. Branch `feat/kubernetes-apptainer`.

## Decisions (2026-09-04)

- Cluster-admin is available, so the custom SCC is not a blocker.
- The RWX storage class is a parameter. Targets include AWS EFS and CephFS;
  the only requirement is RWX. Nothing may depend on one backend's behavior.
- The pod image is UBI9. All development tooling lives in the Fedora-based
  harness images, hence in the SIFs; the pod only runs tmux and Apptainer.
- The pod is the equivalent of today's host, credentials included: harness
  credential and settings files live on the PVC under `/home/coder`, exactly
  as they live in the host home today. Harnesses write to those files and to
  their directories, so read-only Secret mounts do not work. Runtime
  credential injection without the pod knowing (OpenShell) is a later
  extension, not part of this plan.
- Repositories live under `/home/coder/repos/<repo-name>`.

## Goal

Keep the exact ccbox experience (cd into a project, run `ccbox`, get an isolated
harness that can only see that project plus explicitly shared config), but with a
long-lived pod as the "host" instead of a workstation.

- The pod is the host. You `oc rsh` into it (or attach to tmux in it), navigate
  the shared filesystem, and run `ccbox` / `ocbox` / `qcbox` / `cxbox` as today.
- Harness containers become Apptainer runs of a SIF built from the existing OCI
  images. No new harness image pipeline.
- One RWX PVC holds everything: home directory, projects, per-project harness
  data, and the shared SIF store. Several coding pods can share it.
- The isolation invariant is unchanged: a session sees `/workspace` (its
  project), its own per-project data dir, and the shared config files the
  launcher chooses. Nothing else.

This builds on the findings of the school-of-sardeenz Apptainer spike (rootless
Apptainer in a pod on a network RWX volume): custom seccomp SCC allowing
`Unconfined`, `/dev/fuse` via the CRI-O annotation, no `hostUsers: false`,
SIF conversion scratch on a node-local emptyDir, SIF executed in place from the
RWX volume through squashfuse.

## Non-goals (for now)

- Multi-user control plane, web UI, operator, pod-per-session orchestration.
- Replacing the Podman path. Host usage stays the primary, unchanged path.
- Firewall inside the harness. Egress control moves to the namespace.

## Design

### 1. Runtime backends in the launcher engine

Today `lib/box-common.sh` and the four wrappers build a single `PODMAN_ARGS`
array by appending raw `-v host:container:opts` and `-e NAME=VALUE` flags, then
`exec podman run`. The Apptainer path needs the same mounts and environment,
rendered as `--bind` / `--env` for `apptainer exec`.

Introduce a runtime-neutral model:

- `add_mount HOST CONTAINER [OPTS]` appends a mount entry to the ordered
  `BOX_SPEC` array. `OPTS` is a comma list of `ro` and `nolabel`, or empty.
- `add_env NAME VALUE` appends an env entry to the same array.
- `add_optional_mount` keeps its signature and calls `add_mount`.
- Wrappers replace every `PODMAN_ARGS+=(-v ...)` / `PODMAN_ARGS+=(-e ...)`
  with `add_mount` / `add_env`. Nothing else in the wrappers changes.
- Runtime-specific flags that have no neutral meaning (`--userns`,
  `--cap-add`, `--hostname`, `-it`) move into the backend.

Two backends, selected once in `box_main`:

| | `podman` (default) | `apptainer` |
|---|---|---|
| Selection | podman on PATH, or `--runtime podman` | `CODEBOX_RUNTIME=apptainer` (set in the pod image), or `--runtime apptainer`, or apptainer present and podman absent |
| Image ref | `quay.io/guimou/<box>:<tag>` | `${CODEBOX_SIF_DIR}/<box>-<tag>.sif` |
| Fetch | `podman pull` | `apptainer pull <sif> docker://quay.io/guimou/<box>:<tag>` if the SIF is missing; `--pull` forces a refresh (needed for `latest`) |
| Build | `podman build` | not supported, clear error (build on a host or in CI) |
| Mounts | `-v h:c[:ro],z` | `--bind h:c[:ro]` |
| Env | `-e` | `--cleanenv` + `APPTAINERENV_*` exports (`--env` splits values on commas) |
| Isolation flags | `--userns=keep-id`, `--rm -it`, `--hostname` | `--userns --no-home --no-mount tmp,cwd --pid --ipc --writable-tmpfs --pwd /workspace`, plus `--bind $CODEBOX_SCRATCH_DIR/<session>:/tmp` when set |
| Session listing | `podman ps --filter name=` | marker file per session under `$CODEBOX_STATE_DIR/sessions` (host + PID + start time; pruned when the PID is gone). Apptainer rewrites its own command line, so `pgrep` is not usable; `apptainer instance` remains the alternative |
| Firewall | `--cap-add NET_ADMIN,NET_RAW` + init script | unsupported: `--with-firewall` errors and points to the namespace egress policy |
| Clipboard, audio, npm-global | as today | skipped (no host) |
| Timezone | bind `/etc/localtime` | bind `/etc/localtime` |
| GitHub token | host `gh auth token` | same code path: `GH_TOKEN` env in the pod (from a Secret) makes `gh auth status` succeed |

Backend functions. Both backends live in `lib/box-common.sh` as marked
sections (not separate files), so the documented two-file flat install
(launcher + `box-common.sh`) stays valid. `select_runtime` binds the `rt_*`
names to one backend's implementation:

- `rt_check` — the runtime binary exists, print install hints.
- `rt_build_image` — `--build` / `--build-base` (Podman only).
- `rt_resolve_image` — sets `IMAGE_REF` for `IMAGE_TAG`, pulls or converts
  as needed.
- `rt_list_sessions` — for `--list-sessions`.
- `rt_render` — turns `BOX_SPEC`, `LAUNCH_CMD`, `NEEDS_SHELL` and the flags
  into `RUN_ARGS`.
- `rt_exec` — `exec podman run ...` or `exec apptainer exec ...`.

Phase 1 implemented this with a single ordered `BOX_SPEC` array of
`mount|HOST|CONTAINER|OPTS` and `env|NAME|VALUE` entries (instead of two
arrays) so relative order is preserved, plus a `nolabel` mount option for
system paths that must not be SELinux-relabeled (sockets, `/etc/localtime`).

`DEBUG=1` keeps printing the final command. That is also the test hook: a
stub `podman`/`apptainer` on PATH plus `DEBUG=1` lets CI assert the rendered
command line without a container runtime.

### 2. Apptainer specifics to get right

These are the details that differ from Podman and each needs a check on a
real cluster (see the gate list below).

- **Home handling.** Plain `apptainer exec` binds `$HOME`, cwd and `/tmp`
  from the outside. That is exactly the leak we must avoid. Use `--no-home`
  and `--no-mount tmp,cwd`, then bind explicitly. Do not use `--contain` /
  `--containall`: they replace `/home/coder` with an empty session dir and
  hide what the image ships there (`.bashrc`, `.cargo`, `.local/bin`,
  `.playwright-mcp-config.json`, the tmux monitor).
- **Writable paths.** The SIF root is read-only. Everything the harness writes
  under `/home/coder` that is not a bound path goes to `--writable-tmpfs`.
  The default Apptainer session dir cap is 64 MB (`sessiondir max size` in
  `apptainer.conf`), which is too small for `~/.cache`, `~/.npm`, plugin
  installs. Two measures: raise the cap in the pod image's `apptainer.conf`,
  and bind a per-session scratch directory (node-local emptyDir) onto `/tmp`
  and onto the known heavy cache paths.
- **UID.** The pod runs as UID 1000 (`coder`), granted by the custom SCC
  (`runAsUser: MustRunAsNonRoot`). Apptainer injects the running user into
  the container's `/etc/passwd`, so the pod image must define `coder` with
  UID 1000 and home `/home/coder`. All files on the PVC end up owned by 1000.
- **SIF conversion.** `apptainer pull` unpacks the OCI layers into
  `APPTAINER_TMPDIR`; that must be node-local (EMLINK on NFS-class
  filesystems). The finished SIF lands on the RWX store. Write to a temp
  name and `mv` into place so two pods pulling the same tag do not race.
  Our images are large (Fedora + Chromium + toolchains), so budget a
  multi-GB scratch and a few minutes for the first pull of each tag.
- **Chromium.** Already runs with `--no-sandbox` in the base image, so the
  nested user namespace should not matter. Verify Playwright MCP once.
- **PID namespace.** `--pid` so the harness cannot see other sessions'
  processes. Rootless-safe.
- **Hostname.** Cosmetic; needs `--uts`. Skip unless free.
- **Env hygiene.** `--cleanenv` always, then forward only the passthrough
  lists plus `TERM`, `LANG`, `TZ`, `HOME=/home/coder`. Kubernetes injects
  `KUBERNETES_*` and service env vars into every pod; they must not leak in.
  The pod also sets `automountServiceAccountToken: false`.

### 3. Pod image (`k8s/Containerfile`)

Published as `quay.io/guimou/codebox-pod` (name to confirm). A thin UBI9
image, in the spirit of the Sardeenz `worker-base`: every development tool
is in the SIFs, the pod only hosts tmux and Apptainer. Contents:

- `registry.access.redhat.com/ubi9/ubi`, user `coder` UID 1000, home
  `/home/coder`.
- From EPEL: `apptainer` (rootless package, not `apptainer-suid`),
  `squashfuse`, `fuse-overlayfs`, `fuse3`. `tzdata` with `/etc/localtime`
  set (Apptainer bind-mounts it by default and stock UBI9 has neither it nor
  `/etc/hosts` handling; the spike hit this).
- `tmux`, `git`, `jq`, `vim-minimal`, `openssh-clients`, `bind-utils` from
  UBI/EPEL; `gh` from the GitHub CLI RPM repository.
- The four launchers and `lib/*.sh` copied to `/usr/local/bin` (flat layout).
- `/etc/apptainer/apptainer.conf` with a raised `sessiondir max size`.
- Env: `CODEBOX_RUNTIME=apptainer`, `CODEBOX_SIF_DIR=/home/coder/.codebox/sifs`,
  `APPTAINER_TMPDIR=/scratch`, `APPTAINER_CACHEDIR=/scratch/cache`,
  `HOME=/home/coder`.
- Entrypoint: create the home skeleton on first start (the PVC is mounted
  over `/home/coder`, so nothing baked there survives), then run a tmux
  server or `sleep infinity`. tmux in the pod is what makes sessions survive
  a dropped `oc rsh`.

### 4. Manifests (`k8s/`)

Plain YAML with a kustomization, one namespace per user:

- `scc.yaml` — cluster-admin, applied once: the spike SCC (`restricted-v2`
  plus `seccompProfiles: [runtime/default, unconfined]`) with
  `runAsUser: MustRunAsNonRoot`.
- `pvc.yaml` — one RWX claim, `storageClassName` left as a kustomize
  parameter with no default (EFS, CephFS, NFS all valid). Mounted at
  `/home/coder`. Repositories live under `/home/coder/repos/<repo-name>`,
  harness data in the usual per-launcher dirs (`~/.claude/ccbox-projects/...`),
  credential and settings files where the harness expects them in the home
  directory, SIFs under `~/.codebox/sifs`.
- `deployment.yaml` — replicas 1, `/dev/fuse` annotation
  (`io.kubernetes.cri-o.Devices: /dev/fuse`), `seccompProfile: Unconfined`,
  `allowPrivilegeEscalation: false`, `runAsUser: 1000`,
  `automountServiceAccountToken: false`, node-local `emptyDir` at `/scratch`,
  `envFrom` a Secret.
- `secret.example.yaml` — optional `GH_TOKEN` and env-var based provider
  keys (`ANTHROPIC_API_KEY`, ...). The launcher's env passthrough forwards
  them exactly as on a host. File-based credentials (`--with-credentials`,
  OAuth stores, settings files holding keys) stay on the PVC, as on a host.
- `egressfirewall.example.yaml` — OVN-Kubernetes `EgressFirewall` with
  `dnsName` rules generated from `firewall-domains*.txt` by a small script
  (`k8s/gen-egress-firewall.sh`). This is the replacement for
  `--with-firewall`; it applies to the whole namespace.

### 5. CI

- New job in `release.yml`: build and push the pod image when `k8s/`,
  `lib/`, or a launcher changes.
- Shell tests: stub runtime + `DEBUG=1`, assert the rendered `podman run`
  and `apptainer exec` command lines for each launcher with a fixed HOME.
  Also proves the refactor in phase 1 changed nothing.
- `shellcheck` list extended with the new `lib/` files and `k8s/*.sh`.
- Optional later: publish SIFs from CI via ORAS so pods never need to
  convert. Not needed for v1 since `apptainer pull docker://` in the pod
  works.

### 6. Docs

- `docs/kubernetes.md` — new: prerequisites (OpenShift 4.15+, RWX class,
  cluster-admin for the SCC), deploy steps, daily use (`oc rsh`, tmux,
  `ccbox` from a project dir), what differs from the host (no firewall
  flag, no clipboard, SIF pull on first use), storage layout, security
  posture (mount visibility preserved, thinner escape boundary than rootless
  Podman, unconfined seccomp, same UID for everything in the pod).
- `README.md` — a second "Run" section linking to it.
- `docs/architecture.md` — runtime backends section and the pod diagram.
- `docs/usage.md` — `--runtime`, `--pull`, and the `CODEBOX_*` env vars.
- `AGENTS.md` — file structure and the runtime backend note.

## Gates to run on a live cluster (next step, after phases 1-3)

1. Pod admitted under the custom SCC as UID 1000 with `/dev/fuse` present and
   `Seccomp: 0`; `unshare --user --map-root-user id` works (spike Gate 1).
2. `apptainer pull` of `quay.io/guimou/ccbox:latest` into the RWX store with
   node-local scratch: time, scratch size, resulting SIF size.
3. `apptainer exec --no-home --no-mount tmp,cwd --pid --writable-tmpfs` with
   the ccbox bind list: `claude --version` runs, `/home/coder` shows the
   image content, `/workspace` is the project, nothing else from the PVC is
   visible inside (`ls /home/coder/repos` must fail).
4. Writes outside bound paths succeed and do not hit the session dir cap
   after raising it; a plugin install and an `npm install` in the project
   work.
5. A full interactive session with history and todos persisting across two
   launches in the same project, and a second project not seeing the first.
6. Playwright MCP can start Chromium inside the SIF.
7. Two pods sharing the PVC run sessions concurrently from the same SIF.

## Phases / pull requests

1. **Refactor the launcher engine to the runtime-neutral model** (no behavior
   change). `add_mount` / `add_env`, `BOX_SPEC`, Podman backend section,
   wrappers migrated, golden test (`tests/render-test.sh`) asserting the
   rendered `podman run` line is identical before and after for all four
   launchers, CI job for shellcheck + the test. Done on this branch.
2. **Apptainer backend.** Apptainer section in `lib/box-common.sh`,
   `--runtime`, `--pull`, `CODEBOX_RUNTIME` / `CODEBOX_STATE_DIR` /
   `CODEBOX_SIF_DIR` / `CODEBOX_SCRATCH_DIR`, SIF fetch with atomic move,
   session markers, firewall/clipboard/npm-global behavior, golden
   scenarios for the rendered `apptainer exec` line, `docs/usage.md`
   Runtimes section. Done on this branch; the gates below still have to be
   run on a cluster once phase 3 provides the pod.
3. **Pod image and manifests.** `k8s/Containerfile` (UBI9), `k8s/entrypoint.sh`,
   `apptainer.conf` tweaks baked in the image, `k8s/cluster/` (SCC +
   ClusterRole), `k8s/base/` + `k8s/overlays/example/` (kustomize),
   `k8s/gen-egress-firewall.sh`, `build-pod.yml` CI job, `docs/kubernetes.md`,
   README and AGENTS.md updates. Done on this branch, unverified on a
   cluster: run the gates above next and fold the findings back into the
   backend and the docs.
4. **Optional follow-ups.** Egress firewall generator, SIF publishing via
   ORAS, `apptainer instance` based session listing, Secret-mounted
   credential files instead of files on the PVC.

## Open questions

- Pod image name: `codebox-pod`?
- Minimum OpenShift version to document. The `/dev/fuse` CRI-O annotation
  needs 4.15+; the spike ran on 4.21.
- Per-backend re-checks: the spike validated EFS; CephFS still needs the SIF
  conversion (EMLINK) and squashfuse-in-place gates re-run.
