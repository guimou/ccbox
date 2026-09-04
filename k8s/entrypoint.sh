#!/bin/bash
# codebox-pod entrypoint: prepare the home directory on the RWX volume, then
# idle. Sessions are started by the user from a shell in the pod:
#
#   oc rsh deploy/codebox tmux new -A -s main     # attach (or create) tmux
#   cd ~/repos/<repo> && ccbox                    # as on a workstation
#
# Running inside tmux is what lets a session survive a dropped rsh.

set -euo pipefail

# Home skeleton (the PVC hides whatever the image had in /home/coder).
# repos/ is where repositories go; the launchers create their own state
# directories on first use.
mkdir -p "${HOME}/repos" \
         "${CODEBOX_SIF_DIR:-${HOME}/.codebox/sifs}" \
         "${CODEBOX_STATE_DIR:-${HOME}/.codebox}/sessions"

# Node-local scratch: SIF conversion workspace and per-session /tmp dirs.
# A fresh emptyDir is root-owned 755 on some setups; only create the
# subdirectories when the volume is writable, the launcher checks again.
if [[ -w /scratch ]]; then
    mkdir -p "${APPTAINER_TMPDIR:-/scratch/apptainer/tmp}" \
             "${APPTAINER_CACHEDIR:-/scratch/apptainer/cache}" \
             "${CODEBOX_SCRATCH_DIR:-/scratch/sessions}"
else
    echo "[WARN] /scratch is not writable: SIF conversion and per-session /tmp will fail" >&2
fi

# Minimal shell config on first start (the PVC starts empty)
if [[ ! -f "${HOME}/.bashrc" ]]; then
    cat > "${HOME}/.bashrc" <<'EOF'
# codebox-pod
[ -f /etc/bashrc ] && . /etc/bashrc
export PS1='[\u@codebox \W]\$ '
cd "${HOME}/repos" 2>/dev/null || true
EOF
fi

echo "codebox-pod ready: $(hostname) as $(id -un) (uid $(id -u)), home ${HOME}, SIF store ${CODEBOX_SIF_DIR:-${HOME}/.codebox/sifs}"
echo "Attach with: oc rsh deploy/<name> tmux new -A -s main"

# Idle until the pod is deleted. The launchers run as children of the
# user's shell, not of this process.
exec sleep infinity
