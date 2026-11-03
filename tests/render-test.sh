#!/bin/bash
# Golden test for the launcher engine: runs every launcher against a stub
# container runtime in a fixed, self-contained environment and compares the
# rendered command line (`podman run ...` or `apptainer exec ...`) with the
# recorded expectation.
#
#   tests/render-test.sh            # check against tests/golden/*.txt
#   tests/render-test.sh record     # (re)record the golden files
#
# No real container runtime, gh, or npm is needed: stubs on PATH answer the
# few calls the launchers make, and the `run` stub writes its arguments one
# per line to a file instead of starting anything.
#
# Normalization (so the output is stable across machines and runs):
#   - the temporary root directory is replaced by ROOT
#   - the per-run session id and the per-path project hash are replaced by
#     SESSION / HASH, and the image tag (from the version pin files) by TAG
#   - flag/value pairs before the image reference are sorted (the runtime
#     does not care about their order); the tail (image + command) is kept
#     verbatim, in order. For apptainer, the APPTAINERENV_* exports are
#     listed as `--env NAME=VALUE` pairs.
#   - when a scenario generates the shared memory budget slice unit, its
#     content and the systemctl calls made are appended after the command
# A scenario name starting with "!" is expected to fail before launching.

set -euo pipefail

TESTS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
GOLDEN_DIR="${TESTS_DIR}/golden"
MODE="${1:-check}"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codebox-render.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

FAKE_HOME="${ROOT}/home"
WORKSPACE="${ROOT}/repos/demo"
NPM_PREFIX="${ROOT}/npm-global"
STUBS="${ROOT}/stubs"
OUT="${ROOT}/out"
mkdir -p "$FAKE_HOME" "$WORKSPACE" "$NPM_PREFIX" "$STUBS" "$OUT" "${ROOT}/repos/demo-worktrees"

# Files the launchers detect on the host
touch "${FAKE_HOME}/.gitconfig" "${FAKE_HOME}/.claude.json"
mkdir -p "${FAKE_HOME}/.config/gcloud" "${FAKE_HOME}/.claude" "${FAKE_HOME}/.qwen"
touch "${FAKE_HOME}/.claude/status-line.sh" "${FAKE_HOME}/.claude/RULES.md" "${FAKE_HOME}/.qwen/.env"
echo '{}' > "${FAKE_HOME}/.claude/settings-redhat.json"
mkdir -p "${FAKE_HOME}/.omp/agent" && touch "${FAKE_HOME}/.omp/agent/AGENTS.md"

# cgroup v2 tree with the memory controller delegated to the user session,
# so the shared memory budget applies (CODEBOX_CGROUP_ROOT points here)
CGROUP_ROOT="${ROOT}/cgroup"
USER_CG="${CGROUP_ROOT}/user.slice/user-$(id -u).slice/user@$(id -u).service"
mkdir -p "$USER_CG"
echo "cpuset cpu io memory hugetlb pids misc" > "${CGROUP_ROOT}/cgroup.controllers"
echo "cpu memory pids" > "${USER_CG}/cgroup.controllers"
SLICE_DIR="${FAKE_HOME}/.config/systemd/user"

# --- stubs ---------------------------------------------------------------

cat > "${STUBS}/podman" <<'EOF'
#!/bin/bash
case "$1" in
    pull)    exit 0 ;;
    image)   [[ "$3" == codebox-base:* ]] && exit 1; exit 0 ;;   # local harness image exists, no local base
    ps)      exit 0 ;;
    info)    echo "${STUB_CGROUP_MANAGER:-systemd}"; exit 0 ;;
    unshare) shift; exec "$@" ;;
    run)     shift; printf '%s\n' "$@" > "${RENDER_OUT}"; exit 0 ;;
    *)       echo "stub podman: unexpected '$1'" >&2; exit 99 ;;
esac
EOF

cat > "${STUBS}/apptainer" <<'EOF'
#!/bin/bash
case "$1" in
    pull)    touch "$3"; exit 0 ;;          # apptainer pull --force <file> <uri>
    exec)    shift
             { env | grep '^APPTAINERENV_' | sed 's/^APPTAINERENV_/--env\n/'
               printf '%s\n' "$@"; } > "${RENDER_OUT}"
             exit 0 ;;
    *)       echo "stub apptainer: unexpected '$1'" >&2; exit 99 ;;
esac
EOF

cat > "${STUBS}/systemctl" <<'EOF'
#!/bin/bash
[[ "$1" == --user ]] && shift
case "$1" in
    show-environment) exit 0 ;;
    is-active)        exit "${STUB_SLICE_ACTIVE:-3}" ;;
    daemon-reload|set-property) echo "systemctl --user $*" >> "${SYSTEMCTL_LOG}"; exit 0 ;;
    *) echo "stub systemctl: unexpected '$1'" >&2; exit 99 ;;
esac
EOF

cat > "${STUBS}/gh" <<'EOF'
#!/bin/bash
case "$1 $2" in
    "auth status") exit 0 ;;
    "auth token")  echo ghp_stubtoken ;;
    *) exit 1 ;;
esac
EOF

cat > "${STUBS}/npm" <<'EOF'
#!/bin/bash
[[ "$*" == "config get prefix" ]] && echo "${NPM_PREFIX}"
EOF

chmod +x "${STUBS}"/*

# Wrappers are invoked through symlinks in a bin dir, like a real install
BIN="${ROOT}/bin"
mkdir -p "$BIN"
for box in ccbox ocbox qcbox cxbox ompbox; do
    ln -s "${REPO_DIR}/${box}" "${BIN}/${box}"
done

# --- scenarios -------------------------------------------------------------
# name|launcher|args...

SCENARIOS=(
    "ccbox-default|ccbox|"
    "ccbox-all-opts|ccbox|--with-firewall --with-credentials --with-gcloud --with-gitconfig --no-clipboard --with-teams"
    "ccbox-tmux|ccbox|--with-teams --with-tmux"
    "ccbox-shell|ccbox|--shell --with-credentials"
    "ccbox-safe-mode-args|ccbox|--safe-mode -- --version"
    "ccbox-no-github|ccbox|--no-github --claude-version 1.2.3"
    "ccbox-explicit|ccbox|--github-token ghp_explicit --npm-global ROOT/npm-global --local"
    "ccbox-mount|ccbox|--mount ROOT/repos/demo-worktrees:/worktrees --mount=ROOT/npm-global:/extra:ro"
    "!ccbox-mount-missing|ccbox|--mount ROOT/repos/nope:/worktrees"
    "!ccbox-mount-relative|ccbox|--mount ROOT/repos/demo-worktrees:worktrees"
    # settings variant: ~/.claude/settings-redhat.json mounted as settings.json
    "ccbox-settings|ccbox|--settings redhat"
    "ccbox-settings-env|ccbox|"
    "!ccbox-settings-missing|ccbox|--settings nope"
    "!ccbox-settings-invalid|ccbox|--settings=../x"
    "ocbox-default|ocbox|"
    "ocbox-all-opts|ocbox|--with-firewall --with-credentials --with-gcloud --with-gitconfig"
    "ocbox-args|ocbox|-- --version"
    "qcbox-default|qcbox|"
    "qcbox-all-opts|qcbox|--with-firewall --with-credentials --with-gcloud --with-gitconfig --shell"
    "cxbox-default|cxbox|"
    "cxbox-all-opts|cxbox|--with-firewall --with-credentials --with-gcloud --with-gitconfig"
    "cxbox-args|cxbox|-- --version"
    "ompbox-default|ompbox|"
    "ompbox-all-opts|ompbox|--with-firewall --with-credentials --with-gcloud --with-gitconfig"
    "ompbox-args|ompbox|-- --version"
    # apptainer runtime (the pod-as-host case): no clipboard/npm-global, SIF image
    "apptainer-ccbox-default|ccbox|--runtime apptainer"
    "apptainer-ccbox-all-opts|ccbox|--runtime apptainer --with-credentials --with-gcloud --with-gitconfig --with-teams --with-tmux"
    "apptainer-ccbox-shell|ccbox|--runtime=apptainer --shell"
    "apptainer-ocbox-default|ocbox|--runtime apptainer --with-credentials"
    "apptainer-qcbox-default|qcbox|--runtime apptainer"
    "apptainer-cxbox-args|cxbox|--runtime apptainer -- --version"
    "apptainer-ompbox-args|ompbox|--runtime apptainer -- --version"
    # runtime chosen by CODEBOX_RUNTIME, per-session scratch bound at /tmp
    "apptainer-env-var|ccbox|"
    "!apptainer-firewall|ccbox|--runtime apptainer --with-firewall"
    "!apptainer-build|ccbox|--runtime apptainer --build"
    "!unknown-runtime|ccbox|--runtime docker"
    # shared memory budget (podman): defaults are covered by every podman
    # scenario above; these set the CODEBOX_MEMORY_* variables (see below)
    "memory-absolute-live|ccbox|"
    "memory-percent|ompbox|"
    "memory-env-off|cxbox|"
    "memory-flag-off|ccbox|--no-memory-limit"
    "memory-unavailable|qcbox|"
    "!memory-invalid-max|ccbox|"
    "!memory-invalid-swap|ccbox|"
    "!memory-invalid-slice|ccbox|"
)

# Fixed environment for every run. Provider keys exercise env passthrough.
run_launcher() {  # uses the caller's name (scenario) and EXTRA_ENV
    local box="$1"; shift
    local -a stub_keys=(
        ANTHROPIC_API_KEY=anthropic-stub  # notsecret
        OPENAI_API_KEY=openai-stub  # notsecret
    )
    (
        cd "$WORKSPACE"
        env -i \
            PATH="${STUBS}:/usr/bin:/bin" \
            HOME="$FAKE_HOME" \
            TERM=xterm-256color \
            LANG=C.UTF-8 \
            TZ=UTC \
            NPM_PREFIX="$NPM_PREFIX" \
            RENDER_OUT="${OUT}/${name}.argv" \
            "${stub_keys[@]}" \
            AWS_REGION=eu-west-1 \
            NO_COLOR=1 \
            CODEBOX_CGROUP_ROOT="$CGROUP_ROOT" \
            SYSTEMCTL_LOG="${OUT}/${name}.systemctl" \
            "${EXTRA_ENV[@]}" \
            "${BIN}/${box}" "$@" > "${OUT}/${name}.log" 2>&1
    )
}

# Sort flag/value pairs, keep the image + command tail in order
normalize() {
    local -a tokens=() pairs=() tail=()
    mapfile -t tokens
    local i=0 n=${#tokens[@]}
    while (( i < n )); do
        local t="${tokens[$i]}"
        if [[ "$t" == -* ]]; then
            case "$t" in
                --rm|-it|-i|-t|*=*) pairs+=("$t"); i=$((i+1)) ;;
                --userns|--no-home|--pid|--ipc|--cleanenv|--writable-tmpfs) pairs+=("$t"); i=$((i+1)) ;;
                *) pairs+=("$t ${tokens[$((i+1))]}"); i=$((i+2)) ;;
            esac
        else
            tail=("${tokens[@]:$i}")
            break
        fi
    done
    printf '%s\n' "${pairs[@]}" | LC_ALL=C sort
    echo "--"
    printf '%s\n' "${tail[@]}"
}

scrub() {
    sed -e "s#${ROOT}#ROOT#g" \
        -e 's#demo_[0-9a-f]\{8\}#demo_HASH#g' \
        -e 's#^\(quay.io/guimou/[a-z]*\|[a-z]*box\):[^ ]*$#\1:TAG#' \
        -e 's#/sifs/\([a-z]*box\)-[^ /]*\.sif$#/sifs/\1-TAG.sif#' \
        -e 's/\(demo\)-[0-9a-f]\{8\}-[0-9a-f]\{8\}\(.*\)$/\1-HASH-SESSION\2/'
}

status=0
mkdir -p "$GOLDEN_DIR"
for entry in "${SCENARIOS[@]}"; do
    IFS='|' read -r name box args <<< "$entry"
    args="${args//ROOT/$ROOT}"
    EXTRA_ENV=(NOOP=1)
    if [[ "$name" == apptainer-env-var ]]; then
        EXTRA_ENV=(CODEBOX_RUNTIME=apptainer "CODEBOX_SCRATCH_DIR=${ROOT}/scratch")
    elif [[ "$name" == ccbox-settings-env ]]; then
        EXTRA_ENV=(CCBOX_SETTINGS=redhat)
    fi
    case "${name#!}" in
        memory-absolute-live) EXTRA_ENV=(CODEBOX_MEMORY_MAX=48G CODEBOX_MEMORY_SWAP_MAX=0 STUB_SLICE_ACTIVE=0) ;;
        memory-percent)       EXTRA_ENV=(CODEBOX_MEMORY_MAX=60% CODEBOX_MEMORY_HIGH=50% CODEBOX_SLICE=agents.slice) ;;
        memory-env-off)       EXTRA_ENV=(CODEBOX_MEMORY_MAX=off) ;;
        memory-unavailable)   EXTRA_ENV=(STUB_CGROUP_MANAGER=cgroupfs) ;;
        memory-invalid-max)   EXTRA_ENV=(CODEBOX_MEMORY_MAX=lots) ;;
        memory-invalid-swap)  EXTRA_ENV=(CODEBOX_MEMORY_SWAP_MAX=50%) ;;
        memory-invalid-slice) EXTRA_ENV=(CODEBOX_SLICE=../evil) ;;
    esac
    rm -rf "$SLICE_DIR"
    if [[ "$name" == !* ]]; then
        # Expected to be refused before anything is launched
        name="${name#!}"
        # shellcheck disable=SC2086
        if run_launcher "$box" $args; then
            echo "FAIL ${name}: expected the launcher to refuse this"
            status=1
        elif [[ -e "${OUT}/${name}.argv" ]]; then
            echo "FAIL ${name}: launcher failed but still launched a container"
            status=1
        else
            echo "ok   ${name} (refused)"
        fi
        continue
    fi
    # shellcheck disable=SC2086  # args are intentionally word-split
    run_launcher "$box" $args || {
        echo "FAIL ${name}: launcher exited with an error"
        cat "${OUT}/${name}.log"
        status=1
        continue
    }
    scrub < "${OUT}/${name}.argv" | normalize > "${OUT}/${name}.txt"
    for unit in "$SLICE_DIR"/*.slice; do
        [[ -f "$unit" ]] || continue
        { echo "## ${unit#"${FAKE_HOME}/"}"; cat "$unit"; } >> "${OUT}/${name}.txt"
    done
    if [[ -f "${OUT}/${name}.systemctl" ]]; then
        { echo "## systemctl calls"; cat "${OUT}/${name}.systemctl"; } >> "${OUT}/${name}.txt"
    fi
    if [[ "$MODE" == record ]]; then
        cp "${OUT}/${name}.txt" "${GOLDEN_DIR}/${name}.txt"
        echo "recorded ${name}"
    elif diff -u "${GOLDEN_DIR}/${name}.txt" "${OUT}/${name}.txt"; then
        echo "ok   ${name}"
    else
        echo "FAIL ${name}"
        status=1
    fi
done
exit $status
