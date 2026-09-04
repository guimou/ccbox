#!/bin/bash
# Golden test for the launcher engine: runs every launcher against a stub
# container runtime in a fixed, self-contained environment and compares the
# rendered `podman run` command line with the recorded expectation.
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
#     verbatim, in order.

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
mkdir -p "$FAKE_HOME" "$WORKSPACE" "$NPM_PREFIX" "$STUBS" "$OUT"

# Files the launchers detect on the host
touch "${FAKE_HOME}/.gitconfig" "${FAKE_HOME}/.claude.json"
mkdir -p "${FAKE_HOME}/.config/gcloud"

# --- stubs ---------------------------------------------------------------

cat > "${STUBS}/podman" <<'EOF'
#!/bin/bash
case "$1" in
    pull)    exit 0 ;;
    image)   exit 1 ;;                      # "image exists" -> not found
    ps)      exit 0 ;;
    unshare) shift; exec "$@" ;;
    run)     shift; printf '%s\n' "$@" > "${RENDER_OUT}"; exit 0 ;;
    *)       echo "stub podman: unexpected '$1'" >&2; exit 99 ;;
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
for box in ccbox ocbox qcbox cxbox; do
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
    "ocbox-default|ocbox|"
    "ocbox-all-opts|ocbox|--with-firewall --with-credentials --with-gcloud --with-gitconfig"
    "ocbox-args|ocbox|-- --version"
    "qcbox-default|qcbox|"
    "qcbox-all-opts|qcbox|--with-firewall --with-credentials --with-gcloud --with-gitconfig --shell"
    "cxbox-default|cxbox|"
    "cxbox-all-opts|cxbox|--with-firewall --with-credentials --with-gcloud --with-gitconfig"
    "cxbox-args|cxbox|-- --version"
)

# Fixed environment for every run. Provider keys exercise env passthrough.
run_launcher() {  # needs: name (scenario), box, args
    local box="$1"; shift
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
            ANTHROPIC_API_KEY=anthropic-stub \
            OPENAI_API_KEY=openai-stub \
            AWS_REGION=eu-west-1 \
            NO_COLOR=1 \
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
        -e 's/demo-[0-9a-f]\{8\}-[0-9a-f]\{8\}$/demo-HASH-SESSION/' \
        -e 's#demo_[0-9a-f]\{8\}#demo_HASH#g' \
        -e 's#^\(quay.io/guimou/[a-z]*\|[a-z]*box\):[^ ]*$#\1:TAG#'
}

status=0
mkdir -p "$GOLDEN_DIR"
for entry in "${SCENARIOS[@]}"; do
    IFS='|' read -r name box args <<< "$entry"
    # shellcheck disable=SC2086  # args are intentionally word-split
    name="$name" run_launcher "$box" $args || {
        echo "FAIL ${name}: launcher exited with an error"
        cat "${OUT}/${name}.log"
        status=1
        continue
    }
    scrub < "${OUT}/${name}.argv" | normalize > "${OUT}/${name}.txt"
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
