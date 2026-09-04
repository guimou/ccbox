# Running on Kubernetes / OpenShift

The launchers can run inside a long-lived pod instead of on your workstation. The pod plays the role of the host: you open a shell in it, `cd` into a repository under `~/repos`, and run `ccbox` / `ocbox` / `qcbox` / `cxbox` exactly as on a laptop. The harness then runs in an [Apptainer](https://apptainer.org/) container started from a SIF converted from the same `quay.io/guimou/<box>` image you use with Podman.

What you keep from the workstation setup:

- **Project isolation.** A session sees its repository at `/workspace`, its own per-project harness state, and the shared config files the launcher chooses. It cannot see the rest of the home directory, other repositories, or the pod's environment. This is enforced by the Apptainer invocation (`--no-home --no-mount tmp,cwd --cleanenv` plus explicit binds), not by convention.
- **Per-project history, memories, todos and plans**, in the same directories as on a host (`~/.claude/ccbox-projects/<project>/`, ...), so switching repositories switches context completely.
- **Long-lived sessions.** Run the launcher inside tmux in the pod and a dropped connection does not end the session.

What is different:

| | Workstation (Podman) | Pod (Apptainer) |
|---|---|---|
| Image | `podman pull` per launch | Converted once to `~/.codebox/sifs/<box>-<version>.sif`, reused; `--pull` re-converts |
| `--with-firewall` | iptables inside the container | Refused. Use the namespace EgressFirewall generated from the same domain lists (below) |
| Clipboard, audio, host npm packages | Wired | Not applicable |
| `--build` | Local build | Not available (build with Podman or CI; the pod converts the published image) |
| Credentials | Host files and env vars | Files in the pod's home on the PVC (`--with-credentials` works as on a host); env vars from a Secret |
| Sessions | Podman containers | Marker files; `--list-sessions` still works |

## Prerequisites

- OpenShift 4.15 or later with OVN-Kubernetes and CRI-O (the defaults). `/dev/fuse` is exposed by a pod annotation on these versions, no device plugin needed. Plain Kubernetes works too if you can give the pod `seccompProfile: Unconfined` and `/dev/fuse` by other means.
- A **cluster-admin** to create the SecurityContextConstraints once (`k8s/cluster/`). It is `restricted-v2` plus `seccompProfiles: [unconfined]`, `runAsUser: MustRunAsNonRoot` and `fsGroup: RunAsAny`. No capability, no privileged container, no host namespaces.
- An **RWX storage class**: CephFS/ODF, AWS EFS, NFS, ... The design does not depend on the backend. Two backend notes:
  - EFS does not apply `fsGroup`. Create the access point (or the dynamic provisioning parameters) with uid/gid 1000 so the volume root is writable by the `coder` user.
  - The OCI-to-SIF conversion never runs on the RWX volume (it unpacks on a node-local emptyDir), so the hardlink limits of NFS-class filesystems do not matter.
- Do **not** set `hostUsers: false` or use the `nested-container` SCC. Pod-level user namespaces require idmapped volume mounts, which network filesystems cannot provide, and the pod fails to start.

## Deploy

Once per cluster, as cluster-admin:

```bash
oc apply -k k8s/cluster
```

Per user, in their own namespace:

```bash
cp -r k8s/overlays/example k8s/overlays/mine
# Set: namespace, storageClassName (your RWX class), size, image tag
$EDITOR k8s/overlays/mine/kustomization.yaml

# Optional: env-var secrets (GH_TOKEN, ANTHROPIC_API_KEY, ...) forwarded into
# every session. Fill in, then uncomment the secretGenerator in the overlay.
cp k8s/overlays/example/codebox.env.example k8s/overlays/mine/codebox.env

oc new-project codebox-me
oc apply -k k8s/overlays/mine
oc rollout status deploy/codebox
```

The pod's home directory is the PVC. The first start creates `~/repos`, `~/.codebox/sifs` and a minimal `.bashrc`.

Optional egress restriction (the pod-level replacement for `--with-firewall`), generated from `firewall-domains.txt` and the harness overlays:

```bash
k8s/gen-egress-firewall.sh > egressfirewall.yaml     # all harnesses
k8s/gen-egress-firewall.sh claude > egressfirewall.yaml   # ccbox only
oc apply -n codebox-me -f egressfirewall.yaml
```

Regenerate and re-apply when the domain lists change. The registry hosting the harness images is included so the SIF conversion keeps working.

## Daily use

```bash
# Attach to (or create) a tmux session in the pod
oc rsh deploy/codebox tmux new -A -s main

# Inside the pod
cd ~/repos
git clone https://github.com/you/project      # gh auth works if GH_TOKEN is set
cd project
ccbox                                         # first run of a version converts the image (a few minutes)
```

Detach with `Ctrl-b d`; the session keeps running. Reattach with the same `oc rsh` command. Stop the pod with `oc scale deploy/codebox --replicas=0` and bring it back with `--replicas=1`; everything is on the PVC.

Useful commands in the pod:

```bash
ccbox --list-sessions          # sessions for this repo (this pod or another one sharing the PVC)
ccbox --pull                   # refresh the SIF for the current version (needed for "latest")
ccbox --shell                  # bash in the harness container, same mounts (troubleshooting)
DEBUG=1 ccbox                  # print the apptainer command line before launching
ls ~/.codebox/sifs             # SIF store, one file per box and version
```

The launchers inside the pod have no version pin files, so they use `latest` unless you pass `--claude-version` (and friends). Pin a version by setting an alias in `~/.bashrc` on the PVC.

## Layout on the PVC

| Path | Purpose |
|---|---|
| `~/repos/<repo>` | Repositories. One session sees exactly one of them |
| `~/.claude/`, `~/.config/opencode/`, `~/.qwen/`, `~/.codex/` | Shared harness config and per-project state, as on a host (see [architecture.md](architecture.md)) |
| `~/.claude/.credentials.json` and the other credential files | Credentials, opt-in per launch with `--with-credentials`, as on a host |
| `~/.codebox/sifs/` | SIF store, shared by every pod using this PVC |
| `~/.codebox/sessions/` | Session markers for `--list-sessions` |

Node-local (`/scratch`, an emptyDir, wiped with the pod): the conversion workspace (`APPTAINER_TMPDIR`, `APPTAINER_CACHEDIR`) and per-session `/tmp` directories (`CODEBOX_SCRATCH_DIR`).

## Security posture

Compared with rootless Podman on a workstation:

- **Same:** what a session can see is decided by the launcher's bind list. A harness in project A has no path to project B, to the credential files it was not given, or to the pod's environment.
- **Thinner:** rootless Apptainer is a user and mount namespace (plus PID and IPC namespaces here). The pod runs with seccomp unconfined so it can create them, every process in the pod is UID 1000, and there is no separate network namespace. Escaping the Apptainer container would land in the pod, not on the node. The pod itself remains an ordinary restricted pod from the cluster's point of view: no capabilities, no privilege escalation, no host namespaces, no service account token.
- **Network:** the harness shares the pod's network. Restrict egress with the EgressFirewall above, or a NetworkPolicy.
- **Multiple pods on one PVC** are the same user by design; they share everything, including credentials.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Pod stuck creating with `mount_setattr ... idmap mounts` | `hostUsers: false` is set. Remove it |
| Pod not admitted, seccomp or UID error | The service account is not bound to the `codebox-apptainer` SCC (check `oc get pod -o yaml \| grep scc`), or `k8s/cluster` was not applied |
| `apptainer exec` fails on `/etc/localtime` | Image built from a base without tzdata; use the published pod image |
| `too many links` during `apptainer pull` | `APPTAINER_TMPDIR` is on the network volume; it must be on `/scratch` |
| `no space left` during conversion | The `/scratch` emptyDir is too small for the unpacked image; raise `sizeLimit` and the ephemeral-storage limit in the Deployment |
| Writes inside the harness fail with `no space` outside bound paths | The writable overlay hit `sessiondir max size` (4 GB in the pod image); put the heavy path on a bind or raise the limit |
| `ls /home/coder/repos` from inside a session shows files | It must not. Check that the launcher ran with the apptainer runtime (`Runtime: apptainer` in the startup summary) |
| Home directory not writable | The PVC root is root-owned: the storage class ignores `fsGroup` (EFS). Provision with uid/gid 1000 |
