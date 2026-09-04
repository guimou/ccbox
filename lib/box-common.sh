#!/bin/bash
# Shared launcher engine for the harness containers (ccbox / ocbox / qcbox / cxbox).
#
# This file is sourced by the thin per-harness wrappers, which must define
# the following variables before sourcing:
#   BOX_NAME        - launcher/image name (ccbox, ocbox, qcbox, cxbox)
#   HARNESS_TITLE   - human-readable harness name (e.g. "Claude Code")
#   HARNESS_CLI     - CLI binary to run inside the container
#   REGISTRY_IMAGE  - registry repository (e.g. "guimou/ccbox")
#   VERSION_FLAG    - CLI flag to select the harness version (e.g. "--claude-version")
#   VERSION_FILE    - version pin file in the repo (e.g. "CLAUDE_VERSION")
#   ENV_PASSTHROUGH_REGEX - grep -E regex of env var prefixes to forward
#   ENV_PASSTHROUGH_VARS  - array of specific env var names to forward
#
# And the following hook functions (all optional, defaults are no-ops):
#   harness_parse_arg "$@"  - consume harness-specific CLI args; set ARG_SHIFT
#                             to the number of consumed args and return 0,
#                             or return 1 if the arg is not recognized
#   harness_extra_help      - print harness-specific options for --help
#   harness_ensure_config   - create host-side global config files/dirs
#   harness_setup_project   - create host-side per-project dirs (PROJECT_KEY
#                             and WORKSPACE_DIR are set when this is called)
#   harness_mounts          - declare harness mounts/env with add_mount,
#                             add_optional_mount and add_env
#   harness_pre_run         - last-minute adjustments before launch; may call
#                             add_env, edit EXTRA_ARGS, and set LAUNCH_CMD
#                             (shell command string) plus NEEDS_SHELL=true to
#                             run via bash -c
#   harness_log_status      - print extra harness-specific status lines
#
# The wrapper must call box_main "$@" after sourcing this file.
#
# Runtime backends
# ----------------
# The engine collects what a session needs in a runtime-neutral form: an
# ordered list of bind mounts and environment variables (BOX_SPEC, filled by
# add_mount / add_env), the image tag, and the command to run. A runtime
# backend turns that into the actual command line. Two backends exist:
#   podman     - rootless Podman on a workstation (the default when present)
#   apptainer  - Apptainer running a SIF converted from the same OCI image,
#                for a long-lived pod on Kubernetes/OpenShift where the pod
#                plays the role of the host (see docs/kubernetes.md)
# Selection: --runtime NAME, else $CODEBOX_RUNTIME, else podman if installed,
# else apptainer if installed. The backend interface:
#   rt_check          - the runtime is usable on this host (exit otherwise)
#   rt_list_sessions  - implement --list-sessions
#   rt_build_image    - implement --build / --build-base
#   rt_resolve_image  - set IMAGE_REF for the requested tag (pull if needed)
#   rt_render         - build RUN_ARGS (argv after the runtime binary)
#                       from BOX_SPEC, the launch command and the flags
#   rt_exec           - exec the runtime with RUN_ARGS
# plus two capability flags set by select_runtime: RT_HOST_FEATURES (the
# host has a desktop: clipboard, audio, npm-global are wired) and
# RT_FIREWALL (the in-container firewall can be used).

set -e

# Detect OS
detect_os() {
    case "$(uname -s)" in
        Linux*)     echo "linux";;
        Darwin*)    echo "macos";;
        *)          echo "unknown";;
    esac
}

OS_TYPE=$(detect_os)

# --- Runtime-neutral session spec ------------------------------------------

# Ordered list of "mount|HOST|CONTAINER|OPTS" and "env|NAME|VALUE" entries.
# Order is preserved so that later entries override earlier ones the way the
# runtime would apply them (a file mounted over a directory mount, an env var
# set twice).
BOX_SPEC=()

# Bind-mount $1 (host path) at $2 (container path). $3 is a comma-separated
# list of options, empty (or omitted) for a plain read-write mount:
#   ro       read-only
#   nolabel  shared system path (socket, /etc file): the backend must not
#            SELinux-relabel it, since that would affect the host
add_mount() {
    BOX_SPEC+=("mount|$1|$2|${3:-}")
}

# Set environment variable $1 to $2 inside the container.
add_env() {
    BOX_SPEC+=("env|$1|$2")
}

# Status lines for opt-in mounts added via add_optional_mount, printed by
# box_main after harness_log_status.
OPTIONAL_MOUNT_STATUS=()

# Opt-in mount helper: if the flag named by $1 is set, mount $2 (host path)
# at $3 (container path) with $4 as mount opts (e.g. "ro"). If the host path
# is missing, warn and reset the flag to false (the summary then reports the
# mount as not mounted). A host path ending in "/" is expected to be a
# directory, any other path a file.
# Pass "force_mount" as $5 for paths that are guaranteed to exist (created
# earlier, e.g. by harness_ensure_config). When the flag was set, records a
# status line in OPTIONAL_MOUNT_STATUS for the launch summary:
# "<label>: mounted" plus an optional suffix ($7, e.g. " (shared across
# projects)"), or "<label>: not mounted (use --with-<opt>)", where <label>
# is $6 and <opt> defaults to the flag name with a leading "WITH_" stripped
# and lowercased (so WITH_GCLOUD -> "gcloud", matching --with-gcloud).
# Pass "no_status" as $8 to record no status line (the caller prints its own
# summary line, e.g. from harness_log_status).
add_optional_mount() {
    local flag_var="$1" host_path="$2" container_path="$3" opts="${4:-}" force_mount="${5:-}"
    local no_status="${8:-}"
    local flag_opt="${flag_var#WITH_}"
    flag_opt="${flag_opt,,}"
    local status_label="${6:-$flag_opt}" mounted_suffix="${7:-}"
    if ! declare -p "$flag_var" >/dev/null 2>&1; then
        log_error "add_optional_mount: unknown flag variable '$flag_var'"
        return 1
    fi
    # Read the flag's current value; a falsy flag means the opt-in mount
    # was not requested, so there is nothing to do.
    local flag_value=${!flag_var:-}
    [[ "$flag_value" == true ]] || return 0

    # A trailing "/" only marks the expected type; the mount and warning use
    # the stripped path.
    local path="${host_path%/}" exists=false
    if [[ "$force_mount" == force_mount ]]; then
        exists=true
    elif [[ "$host_path" == */ && -d "$host_path" ]]; then
        exists=true
    elif [[ -f "$path" ]]; then
        exists=true
    fi

    if $exists; then
        add_mount "$path" "$container_path" "$opts"
        if [[ "$no_status" != no_status ]]; then
            OPTIONAL_MOUNT_STATUS+=("${status_label}: mounted${mounted_suffix}")
        fi
    else
        log_warn "$path not found on host, --with-${flag_opt} ignored"
        eval "$flag_var=false"
        if [[ "$no_status" != no_status ]]; then
            OPTIONAL_MOUNT_STATUS+=("${status_label}: not mounted (use --with-${flag_opt})")
        fi
    fi
}

# Registry configuration
REGISTRY="quay.io"
FULL_REGISTRY_IMAGE="${REGISTRY}/${REGISTRY_IMAGE}"
LOCAL_IMAGE_NAME="${BOX_NAME}"
# Harness-independent base image (Dockerfile.base). Local builds start FROM a
# locally built codebox-base when one exists (or --build-base was given),
# otherwise from the published one.
LOCAL_BASE_IMAGE="codebox-base:latest"
REGISTRY_BASE_IMAGE="quay.io/guimou/codebox-base:latest"

# Generate a unique session identifier
generate_session_id() {
    if [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid | cut -c1-8
    else
        # macOS fallback
        uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8
    fi
}

# Compute the project key ({name}_{hash}) for a workspace directory.
# Used to key per-project host-side state directories.
project_key() {
    local workspace_dir="$1"
    local project_name
    project_name=$(basename "$workspace_dir")
    # Sanitize: lowercase, replace invalid chars with dashes
    project_name=$(echo "$project_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
    local path_hash
    if command -v md5sum &> /dev/null; then
        path_hash=$(echo -n "$workspace_dir" | md5sum | cut -c1-8)
    else
        # macOS fallback
        path_hash=$(echo -n "$workspace_dir" | md5 | cut -c1-8)
    fi
    echo "${project_name}_${path_hash}"
}

# Generate a unique container name based on workspace directory
# If session_id is provided, appends it for multi-session support
generate_container_name() {
    local workspace_dir="$1"
    local session_id="$2"
    local key
    key=$(project_key "$workspace_dir")
    # Container names use dashes rather than underscores
    key="${key/_/-}"

    if [[ -n "$session_id" ]]; then
        echo "${BOX_NAME}-${key}-${session_id}"
    else
        echo "${BOX_NAME}-${key}"
    fi
}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Default no-op implementations of the harness hooks
if ! declare -F harness_parse_arg >/dev/null;    then harness_parse_arg() { return 1; }; fi
if ! declare -F harness_extra_help >/dev/null;   then harness_extra_help() { :; }; fi
if ! declare -F harness_ensure_config >/dev/null; then harness_ensure_config() { :; }; fi
if ! declare -F harness_setup_project >/dev/null; then harness_setup_project() { :; }; fi
if ! declare -F harness_mounts >/dev/null;       then harness_mounts() { :; }; fi
if ! declare -F harness_pre_run >/dev/null;      then harness_pre_run() { :; }; fi
if ! declare -F harness_log_status >/dev/null;   then harness_log_status() { :; }; fi

# Show installation instructions for the current OS and shell
show_install_instructions() {
    local install_dir="${HOME}/.local/bin"
    local script_path="${WRAPPER_PATH}"
    local engine_path="${SCRIPT_DIR}/lib/box-common.sh"
    [[ -f "$engine_path" ]] || engine_path="${SCRIPT_DIR}/box-common.sh"

    echo "Installation Instructions"
    echo "========================="
    echo ""
    echo "1. Create the bin directory (if needed):"
    echo "   mkdir -p ${install_dir}"
    echo ""
    echo "2. Install the launcher and the shared engine. Either symlink from"
    echo "   this clone (picks up updates and version pin files automatically):"
    echo "   ln -sf ${script_path} ${install_dir}/${BOX_NAME}"
    echo ""
    echo "   Or copy the two files directly (no clone needed):"
    echo "   cp ${script_path} ${install_dir}/${BOX_NAME}"
    echo "   cp ${engine_path} ${install_dir}/box-common.sh"
    echo ""
    echo "3. Add to your PATH (if not already):"

    local shell_name
    shell_name=$(basename "$SHELL")
    case "$shell_name" in
        zsh)
            echo "   echo 'export PATH=\"\${HOME}/.local/bin:\${PATH}\"' >> ~/.zshrc"
            echo "   source ~/.zshrc"
            ;;
        bash)
            if [[ "$OS_TYPE" == "macos" ]]; then
                echo "   echo 'export PATH=\"\${HOME}/.local/bin:\${PATH}\"' >> ~/.bash_profile"
                echo "   source ~/.bash_profile"
            else
                echo "   echo 'export PATH=\"\${HOME}/.local/bin:\${PATH}\"' >> ~/.bashrc"
                echo "   source ~/.bashrc"
            fi
            ;;
        *)
            echo "   Add ${install_dir} to your shell's PATH"
            ;;
    esac

    echo ""
    echo "4. Verify installation:"
    echo "   ${BOX_NAME} --help"

    if [[ "$OS_TYPE" == "macos" ]]; then
        echo ""
        echo "macOS Notes:"
        echo "  - Install Podman Desktop: https://podman-desktop.io/downloads"
        echo "  - Or via Homebrew: brew install podman"
        echo "  - Start the Podman machine: podman machine start"
        echo "  - For Apple Silicon, build a local ARM64 image: ${BOX_NAME} --build"
    fi
}

show_help() {
    echo "Usage: ${BOX_NAME} [OPTIONS] [-- ${HARNESS_CLI^^}_ARGS...]"
    echo ""
    echo "Run ${HARNESS_TITLE} in a container. By default, pulls from ${FULL_REGISTRY_IMAGE}."
    echo ""
    echo "Options:"
    echo "  --build                  Build image locally (harness layer on top of the base image)"
    echo "  --build-base             Also build the base image locally from Dockerfile.base (implies --build)"
    echo "  --local                  Use locally-built image instead of pulling"
    printf "  %-24s %s\n" "${VERSION_FLAG} VERSION" "Use specific ${HARNESS_TITLE} version"
    echo "  --with-firewall          Enable network firewall restrictions"
    echo "  --no-clipboard           Disable clipboard access (for extra security)"
    echo "  --npm-global PATH        Mount npm global prefix (auto-detected if not set)"
    echo "  --with-github            Explicitly enable GitHub token injection (auto by default)"
    echo "  --no-github              Disable GitHub token injection"
    echo "  --github-token TOKEN     Use specific GitHub token instead of auto-detecting"
    echo "  --with-gcloud            Mount ~/.config/gcloud read-only (for Vertex AI)"
    echo "  --with-gitconfig         Mount ~/.gitconfig read-only (git identity and config)"
    echo "  --list-sessions          List active sessions for this project"
    echo "  --shell                  Start an interactive bash shell instead of ${HARNESS_CLI} (same mounts; for troubleshooting)"
    echo "  --install                Show installation instructions"
    echo "  --runtime NAME           Container runtime: podman (default when installed) or apptainer"
    echo "  --pull                   apptainer: re-pull the SIF even if one exists for this version"
    harness_extra_help
    echo "  -h, --help               Show this help message"
    echo ""
    echo "Examples:"
    echo "  ${BOX_NAME}                              # Pull latest and run"
    echo "  ${BOX_NAME} ${VERSION_FLAG} 1.2.3        # Pull specific version"
    echo "  ${BOX_NAME} --local                      # Use local image"
    echo "  ${BOX_NAME} --build                      # Build locally"
    echo "  ${BOX_NAME} --build-base                 # Rebuild the base image too (Apple Silicon, base changes)"
    echo "  ${BOX_NAME} --with-firewall              # Run with network restrictions"
    echo "  ${BOX_NAME} --no-github                  # Run without GitHub token"
    echo "  ${BOX_NAME} -- --version                 # Pass args to ${HARNESS_CLI}"
    echo "  ${BOX_NAME} --shell                      # Open a shell in the container instead of ${HARNESS_CLI}"
}

# Read version from the harness version file if not specified via command line
read_version_file() {
    # shellcheck disable=SC2153  # VERSION_FILE is set by the harness wrapper
    local version_file="${SCRIPT_DIR}/${VERSION_FILE}"
    if [[ -f "$version_file" ]]; then
        local version
        version=$(tr -d '[:space:]' < "$version_file")
        if [[ -n "$version" && "$version" != "latest" ]]; then
            echo "$version"
        fi
    fi
}

# Determine image tag based on CLI arg, version file, or default to latest
determine_image_tag() {
    local tag="${HARNESS_VERSION}"
    if [[ -z "$tag" ]]; then
        tag=$(read_version_file)
    fi
    if [[ -z "$tag" ]]; then
        tag="latest"
    fi
    echo "$tag"
}

# --- Runtime backend: podman ------------------------------------------------
# Rootless Podman on a workstation (Linux or macOS with a Podman machine).

# Volume flag helper - adds :z for SELinux relabeling on Linux
# On macOS, Podman VM uses virtiofs which doesn't support SELinux labels
vol_flag() {
    local opts="$1"
    # shellcheck disable=SC2015
    [[ "$OS_TYPE" == "linux" ]] && local label="z" || local label=""

    if [[ -n "$opts" && -n "$label" ]]; then
        echo ":${opts},${label}"
    elif [[ -n "$label" ]]; then
        echo ":${label}"
    elif [[ -n "$opts" ]]; then
        echo ":${opts}"
    fi
}

podman_rt_check() {
    if ! command -v podman &> /dev/null; then
        log_error "podman is not installed or not in PATH"
        if [[ "$OS_TYPE" == "macos" ]]; then
            log_error "Install Podman Desktop from: https://podman-desktop.io/downloads"
            log_error "Or install via Homebrew: brew install podman"
        fi
        exit 1
    fi

    # On macOS, check if podman machine is running
    if [[ "$OS_TYPE" == "macos" ]]; then
        if ! podman machine list 2>/dev/null | grep -q "Currently running"; then
            log_warn "Podman machine might not be running"
            log_info "Start it with: podman machine start"
        fi
    fi
}

podman_rt_list_sessions() {
    local base_name
    base_name=$(generate_container_name "$WORKSPACE_DIR")
    podman ps --filter "name=^${base_name}" --format "table {{.Names}}\t{{.Status}}\t{{.CreatedAt}}"
}

# Pull image from registry
pull_image() {
    local image_ref="$1"
    log_info "Pulling image: $image_ref"
    if ! podman pull "$image_ref"; then
        log_error "Failed to pull image: $image_ref"
        log_error "To build locally instead: ${BOX_NAME} --build"
        return 1
    fi
}

# Build the base image locally (Dockerfile.base -> codebox-base:latest)
build_base_image() {
    if [[ ! -f "${SCRIPT_DIR}/Dockerfile.base" ]]; then
        log_error "No Dockerfile.base found in ${SCRIPT_DIR}"
        exit 1
    fi
    log_info "Building base image: ${LOCAL_BASE_IMAGE}"
    podman build -f "${SCRIPT_DIR}/Dockerfile.base" -t "$LOCAL_BASE_IMAGE" "$SCRIPT_DIR"
    log_info "Base image built successfully: ${LOCAL_BASE_IMAGE}"
}

# Pick the base image for a local harness build; sets BASE_IMAGE_REF
resolve_base_image() {
    if $BUILD_BASE; then
        build_base_image
        BASE_IMAGE_REF="$LOCAL_BASE_IMAGE"
        return
    fi
    if podman image exists "$LOCAL_BASE_IMAGE"; then
        log_info "Using local base image: ${LOCAL_BASE_IMAGE} (rebuild with --build-base)"
        BASE_IMAGE_REF="$LOCAL_BASE_IMAGE"
        return
    fi
    case "$(uname -m)" in
        arm64|aarch64)
            # The published base is x86_64 only; build a native one
            log_info "No local base image and the registry base is x86_64 only, building it natively"
            build_base_image
            BASE_IMAGE_REF="$LOCAL_BASE_IMAGE"
            ;;
        *)
            log_info "Using published base image: ${REGISTRY_BASE_IMAGE} (or --build-base to build it locally)"
            BASE_IMAGE_REF="$REGISTRY_BASE_IMAGE"
            ;;
    esac
}

# Build image locally
podman_rt_build_image() {
    if [[ ! -f "${SCRIPT_DIR}/Dockerfile" ]]; then
        log_error "No Dockerfile found in ${SCRIPT_DIR}"
        log_error "Building locally requires a clone of the repository:"
        log_error "  git clone https://github.com/guimou/ccbox.git"
        exit 1
    fi

    resolve_base_image
    local base_image="$BASE_IMAGE_REF"

    local tag
    tag=$(determine_image_tag)
    local full_tag="${LOCAL_IMAGE_NAME}:${tag}"

    log_info "Building container image: $full_tag (from ${base_image})"
    BUILD_ARGS=(--build-arg "BASE_IMAGE=${base_image}" --build-arg "HARNESS=${HARNESS}")

    if [[ "$tag" != "latest" ]]; then
        log_info "Using ${HARNESS_TITLE} version: $tag"
        BUILD_ARGS+=(--build-arg "HARNESS_VERSION=${tag}")
    else
        log_info "Using latest ${HARNESS_TITLE} version"
    fi

    podman build "${BUILD_ARGS[@]}" -f "${SCRIPT_DIR}/Dockerfile" -t "$full_tag" "$SCRIPT_DIR"

    # Also tag as latest for convenience
    if [[ "$tag" != "latest" ]]; then
        podman tag "$full_tag" "${LOCAL_IMAGE_NAME}:latest"
    fi

    log_info "Image built successfully: $full_tag"
}

# Set IMAGE_REF for IMAGE_TAG: a locally built image (--local, or an ARM64
# one found on macOS) or the registry image, pulled now.
podman_rt_resolve_image() {
    # On macOS, auto-detect and prefer local ARM64 image to avoid x86 emulation
    if [[ "$OS_TYPE" == "macos" ]] && ! $USE_LOCAL && podman image exists "${LOCAL_IMAGE_NAME}:${IMAGE_TAG}"; then
        log_info "Found local ARM64 image, using it to avoid emulation"
        USE_LOCAL=true
    fi

    if $USE_LOCAL; then
        # Local mode: use locally-built image
        IMAGE_REF="${LOCAL_IMAGE_NAME}:${IMAGE_TAG}"
        if ! podman image exists "$IMAGE_REF"; then
            log_error "Local image '$IMAGE_REF' not found"
            log_error "Build it with: ${BOX_NAME} --build"
            exit 1
        fi
        log_info "Using local image: $IMAGE_REF"
    else
        # Registry mode: pull from quay.io
        IMAGE_REF="${FULL_REGISTRY_IMAGE}:${IMAGE_TAG}"
        if ! pull_image "$IMAGE_REF"; then
            exit 1
        fi
    fi
}

# Render BOX_SPEC + launch command into RUN_ARGS for `podman run`
podman_rt_render() {
    # shellcheck disable=SC2054  # commas are part of the --userns option value
    RUN_ARGS=(
        --rm
        -it
        --name "$CONTAINER_NAME"
        --hostname "$BOX_NAME"
        --userns=keep-id:uid=1000,gid=1000
        -w /workspace
    )

    local entry kind a b c
    for entry in "${BOX_SPEC[@]}"; do
        IFS='|' read -r kind a b c <<< "$entry"
        case "$kind" in
            mount)
                if [[ ",${c}," == *,nolabel,* ]]; then
                    c="${c//nolabel/}"; c="${c#,}"; c="${c%,}"
                    RUN_ARGS+=(-v "${a}:${b}${c:+:$c}")
                else
                    RUN_ARGS+=(-v "${a}:${b}$(vol_flag "$c")")
                fi
                ;;
            env)
                RUN_ARGS+=(-e "${a}=${b}")
                ;;
        esac
    done

    # Firewall needs the netfilter capabilities (Linux only)
    if ! $NO_FIREWALL; then
        RUN_ARGS+=(
            --cap-add=NET_ADMIN
            --cap-add=NET_RAW
        )
    fi

    if $NO_FIREWALL && ! $NEEDS_SHELL; then
        RUN_ARGS+=("$IMAGE_REF" "$HARNESS_CLI" "${EXTRA_ARGS[@]}")
    elif $NO_FIREWALL; then
        RUN_ARGS+=("$IMAGE_REF" /bin/bash -c "${LAUNCH_CMD}")
    else
        # Start with firewall initialization, then run the harness
        RUN_ARGS+=("$IMAGE_REF" /bin/bash -c "sudo /usr/local/bin/init-firewall.sh && ${LAUNCH_CMD}")
    fi
}

podman_rt_exec() {
    # Debug mode: print the podman command
    if [[ -n "${DEBUG}" ]]; then
        echo "DEBUG: podman run command:" >&2
        printf '%q ' podman run "${RUN_ARGS[@]}" >&2
        echo >&2
    fi
    exec podman run "${RUN_ARGS[@]}"
}

# --- Runtime backend: apptainer ---------------------------------------------
# Rootless Apptainer, typically inside a long-lived pod (the pod is the
# "host": its filesystem holds the repos, the harness config and state, and
# a shared store of SIF files converted from the registry images).
#
#   CODEBOX_STATE_DIR    launcher state (default ~/.codebox)
#   CODEBOX_SIF_DIR      SIF store, may be shared by several pods
#                        (default $CODEBOX_STATE_DIR/sifs)
#   CODEBOX_SCRATCH_DIR  optional: when set, a per-session directory under it
#                        is bound at /tmp inside the container, so heavy
#                        writes land on disk instead of the RAM-backed
#                        writable overlay (point it at a node-local volume)
#
# Isolation: Apptainer binds the caller's home, cwd and /tmp by default,
# which is exactly what must not happen here (a session may only see its
# repo and the state the launcher chooses). The backend therefore always
# runs with --no-home, --no-mount tmp,cwd, --cleanenv and its own PID/IPC
# namespaces, then binds the session spec explicitly. --contain is NOT used:
# it would hide what the image ships in /home/coder. Environment variables
# are passed as APPTAINERENV_* exports (survive --cleanenv, and unlike
# --env are not split on commas).

apptainer_rt_check() {
    if ! command -v apptainer &> /dev/null; then
        log_error "apptainer is not installed or not in PATH"
        log_error "Install it (rootless package, not apptainer-suid) or use --runtime podman"
        exit 1
    fi
    CODEBOX_STATE_DIR="${CODEBOX_STATE_DIR:-${HOME}/.codebox}"
    CODEBOX_SIF_DIR="${CODEBOX_SIF_DIR:-${CODEBOX_STATE_DIR}/sifs}"
    CODEBOX_SESSIONS_DIR="${CODEBOX_STATE_DIR}/sessions"
    mkdir -p "$CODEBOX_SIF_DIR" "$CODEBOX_SESSIONS_DIR"
}

# Sessions are tracked with a marker file per launch (Apptainer rewrites its
# own command line, so there is nothing to grep for). A marker names the
# host and PID; it is stale once that PID is gone on this host. Markers from
# another host (a second pod sharing the state dir) cannot be checked and
# are listed as such.
apptainer_rt_list_sessions() {
    local base_name marker name host pid started
    base_name=$(generate_container_name "$WORKSPACE_DIR")
    printf '%-48s %-10s %s\n' "NAME" "STATUS" "STARTED"
    for marker in "${CODEBOX_SESSIONS_DIR}/${base_name}"-*; do
        [[ -f "$marker" ]] || continue
        name=$(basename "$marker")
        IFS=' ' read -r host pid started < "$marker"
        if [[ "$host" != "$(hostname)" ]]; then
            printf '%-48s %-10s %s\n' "$name" "other host" "$started ($host)"
        elif [[ -d "/proc/${pid}" ]]; then
            printf '%-48s %-10s %s\n' "$name" "running" "$started"
        else
            rm -f "$marker"
        fi
    done
}

apptainer_rt_build_image() {
    log_error "--build is not available with the apptainer runtime"
    log_error "Build and push the OCI image with podman (or let CI do it); the SIF is converted from it on first use"
    exit 1
}

# The SIF for a tag lives at $CODEBOX_SIF_DIR/<box>-<tag>.sif. It is
# converted from the registry image when missing (or with --pull), written
# to a temporary name and moved into place so concurrent launchers never
# see a partial file. The conversion unpacks the OCI layers under
# APPTAINER_TMPDIR, which must be a node-local disk (network filesystems
# fail on the hardlink-heavy unpack); only the finished SIF goes to the
# (possibly shared) store.
apptainer_rt_resolve_image() {
    IMAGE_REF="${CODEBOX_SIF_DIR}/${BOX_NAME}-${IMAGE_TAG}.sif"
    local source="docker://${FULL_REGISTRY_IMAGE}:${IMAGE_TAG}"

    if [[ -f "$IMAGE_REF" ]] && ! $FORCE_PULL; then
        log_info "Using SIF: ${IMAGE_REF}"
        return
    fi
    if $USE_LOCAL; then
        log_error "SIF not found: ${IMAGE_REF} (--local given, not pulling)"
        exit 1
    fi

    local tmp="${IMAGE_REF}.$$.tmp"
    log_info "Converting ${source} to ${IMAGE_REF} (first use of this version; this can take a few minutes)"
    if ! apptainer pull --force "$tmp" "$source"; then
        rm -f "$tmp"
        log_error "Failed to pull ${source}"
        exit 1
    fi
    mv -f "$tmp" "$IMAGE_REF"
    log_info "SIF ready: ${IMAGE_REF}"
}

# Render BOX_SPEC + launch command into RUN_ARGS for `apptainer`, and export
# the environment as APPTAINERENV_* variables
apptainer_rt_render() {
    # shellcheck disable=SC2054  # the comma is part of the --no-mount value
    RUN_ARGS=(
        exec
        --userns
        --no-home
        --no-mount tmp,cwd
        --pid
        --ipc
        --cleanenv
        --writable-tmpfs
        --pwd /workspace
    )

    # Per-session scratch bound at /tmp (optional, see the section comment)
    if [[ -n "${CODEBOX_SCRATCH_DIR:-}" ]]; then
        local scratch="${CODEBOX_SCRATCH_DIR}/${CONTAINER_NAME}"
        mkdir -p "$scratch"
        RUN_ARGS+=(--bind "${scratch}:/tmp")
    fi

    local entry kind a b c
    for entry in "${BOX_SPEC[@]}"; do
        IFS='|' read -r kind a b c <<< "$entry"
        case "$kind" in
            mount)
                # nolabel is a Podman/SELinux concern; only "ro" matters here
                if [[ ",${c}," == *,ro,* ]]; then
                    RUN_ARGS+=(--bind "${a}:${b}:ro")
                else
                    RUN_ARGS+=(--bind "${a}:${b}")
                fi
                ;;
            env)
                export "APPTAINERENV_${a}=${b}"
                ;;
        esac
    done
    export "APPTAINERENV_CODEBOX_SESSION=${CONTAINER_NAME}"

    if ! $NEEDS_SHELL; then
        RUN_ARGS+=("$IMAGE_REF" "$HARNESS_CLI" "${EXTRA_ARGS[@]}")
    else
        RUN_ARGS+=("$IMAGE_REF" /bin/bash -c "${LAUNCH_CMD}")
    fi
}

apptainer_rt_exec() {
    # Session marker (see apptainer_rt_list_sessions). exec keeps our PID.
    echo "$(hostname) $$ $(date '+%Y-%m-%d %H:%M:%S')" > "${CODEBOX_SESSIONS_DIR}/${CONTAINER_NAME}"

    if [[ -n "${DEBUG}" ]]; then
        echo "DEBUG: apptainer command:" >&2
        env | grep '^APPTAINERENV_' | sort >&2
        printf '%q ' apptainer "${RUN_ARGS[@]}" >&2
        echo >&2
    fi
    exec apptainer "${RUN_ARGS[@]}"
}

# Pick the backend (see the header) and bind the rt_* interface to it
select_runtime() {
    local runtime="${RUNTIME_OPT:-${CODEBOX_RUNTIME:-}}"
    if [[ -z "$runtime" ]]; then
        if command -v podman &> /dev/null; then
            runtime="podman"
        elif command -v apptainer &> /dev/null; then
            runtime="apptainer"
        else
            runtime="podman"   # rt_check prints the install hints
        fi
    fi

    case "$runtime" in
        podman)
            RT_HOST_FEATURES=true
            RT_FIREWALL=true
            rt_check()         { podman_rt_check; }
            rt_list_sessions() { podman_rt_list_sessions; }
            rt_build_image()   { podman_rt_build_image; }
            rt_resolve_image() { podman_rt_resolve_image; }
            rt_render()        { podman_rt_render; }
            rt_exec()          { podman_rt_exec; }
            ;;
        apptainer)
            RT_HOST_FEATURES=false
            RT_FIREWALL=false
            rt_check()         { apptainer_rt_check; }
            rt_list_sessions() { apptainer_rt_list_sessions; }
            rt_build_image()   { apptainer_rt_build_image; }
            rt_resolve_image() { apptainer_rt_resolve_image; }
            rt_render()        { apptainer_rt_render; }
            rt_exec()          { apptainer_rt_exec; }
            ;;
        *)
            log_error "Unknown runtime '${runtime}' (expected podman or apptainer)"
            exit 1
            ;;
    esac
    BOX_RUNTIME="$runtime"
}

# --- Host-side features (clipboard, audio, npm-global, GitHub token) --------

# Clipboard/display access for image pasting (CTRL+V)
add_clipboard_mounts() {
    if [[ "$OS_TYPE" == "linux" ]]; then
        if [[ -n "$WAYLAND_DISPLAY" && -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ]]; then
            # Wayland clipboard access
            add_mount "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" "ro,nolabel"
            add_env WAYLAND_DISPLAY "$WAYLAND_DISPLAY"
            add_env XDG_RUNTIME_DIR "$XDG_RUNTIME_DIR"
        elif [[ -n "$DISPLAY" && -d /tmp/.X11-unix ]]; then
            # X11 clipboard access
            add_mount /tmp/.X11-unix /tmp/.X11-unix "ro,nolabel"
            add_env DISPLAY "$DISPLAY"
            if [[ -f "${HOME}/.Xauthority" ]]; then
                add_mount "${HOME}/.Xauthority" /home/coder/.Xauthority "ro"
            fi
        fi
    elif [[ "$OS_TYPE" == "macos" ]]; then
        # macOS: basic X11 support via XQuartz (if available)
        if [[ -n "$DISPLAY" && -d /tmp/.X11-unix ]]; then
            add_mount /tmp/.X11-unix /tmp/.X11-unix "ro,nolabel"
            add_env DISPLAY "$DISPLAY"
        fi
    fi
}

# Mount npm global packages (read-only) if available and not a system directory
add_npm_global_mount() {
    if [[ -n "$NPM_GLOBAL" && "$NPM_GLOBAL" != "/usr" && "$NPM_GLOBAL" != "/usr/local" && -d "$NPM_GLOBAL" ]]; then
        # On macOS, only /Users/* or /private/* paths work with Podman VM
        if [[ "$OS_TYPE" == "macos" ]]; then
            if [[ "$NPM_GLOBAL" == /Users/* || "$NPM_GLOBAL" == /private/* ]]; then
                add_mount "$NPM_GLOBAL" /home/coder/.npm-global "ro"
            else
                log_warn "npm global prefix '$NPM_GLOBAL' not accessible in Podman VM, skipping"
            fi
        else
            add_mount "$NPM_GLOBAL" /home/coder/.npm-global "ro"
        fi
    fi
}

# GitHub token injection for authentication. Sets GH_TOKEN_VALUE and
# GH_TOKEN_SOURCE for the launch summary.
add_github_token() {
    GH_TOKEN_VALUE=""
    GH_TOKEN_SOURCE=""

    $NO_GITHUB && return 0

    if [[ -n "$GITHUB_TOKEN" ]]; then
        # Use explicitly provided token
        GH_TOKEN_VALUE="$GITHUB_TOKEN"
        GH_TOKEN_SOURCE="provided"
    elif command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
        # Auto-detect from host's gh CLI
        GH_TOKEN_VALUE=$(gh auth token 2>/dev/null || true)
        GH_TOKEN_SOURCE="auto-detected"
    fi

    # Pass token to container if available
    if [[ -n "$GH_TOKEN_VALUE" ]]; then
        add_env GH_TOKEN "$GH_TOKEN_VALUE"
        add_env GITHUB_TOKEN "$GH_TOKEN_VALUE"
    elif $WITH_GITHUB; then
        log_warn "GitHub token requested but not available"
        log_warn "Run 'gh auth login' on host to authenticate with GitHub"
    fi
}

# --- Main -------------------------------------------------------------------

box_main() {
    # Parse arguments
    BUILD_ONLY=false
    BUILD_BASE=false
    USE_LOCAL=false
    NO_FIREWALL=true
    NO_CLIPBOARD=false
    NO_GITHUB=false
    WITH_GITHUB=false
    GITHUB_TOKEN=""
    WITH_GCLOUD=false
    WITH_GITCONFIG=false
    LIST_SESSIONS=false
    OPEN_SHELL=false
    SHOW_INSTALL=false
    HARNESS_VERSION=""
    NPM_GLOBAL=""
    RUNTIME_OPT=""
    FORCE_PULL=false
    EXTRA_ARGS=()

    while [[ $# -gt 0 ]]; do
        # Give the harness wrapper first chance at harness-specific flags
        ARG_SHIFT=0
        if harness_parse_arg "$@"; then
            shift "$ARG_SHIFT"
            continue
        fi

        case $1 in
            --build)
                BUILD_ONLY=true
                shift
                ;;
            --build-base)
                BUILD_ONLY=true
                BUILD_BASE=true
                shift
                ;;
            --local)
                USE_LOCAL=true
                shift
                ;;
            "${VERSION_FLAG}")
                HARNESS_VERSION="$2"
                shift 2
                ;;
            "${VERSION_FLAG}"=*)
                HARNESS_VERSION="${1#*=}"
                shift
                ;;
            --with-firewall)
                NO_FIREWALL=false
                shift
                ;;
            --shell)
                OPEN_SHELL=true
                shift
                ;;
            --list-sessions)
                LIST_SESSIONS=true
                shift
                ;;
            --no-clipboard)
                NO_CLIPBOARD=true
                shift
                ;;
            --install)
                SHOW_INSTALL=true
                shift
                ;;
            --npm-global)
                NPM_GLOBAL="$2"
                shift 2
                ;;
            --npm-global=*)
                NPM_GLOBAL="${1#*=}"
                shift
                ;;
            --with-github)
                WITH_GITHUB=true
                shift
                ;;
            --no-github)
                NO_GITHUB=true
                shift
                ;;
            --github-token)
                GITHUB_TOKEN="$2"
                shift 2
                ;;
            --github-token=*)
                GITHUB_TOKEN="${1#*=}"
                shift
                ;;
            --with-gcloud)
                # shellcheck disable=SC2034  # read via add_optional_mount indirection
                WITH_GCLOUD=true
                shift
                ;;
            --with-gitconfig)
                # shellcheck disable=SC2034  # read via add_optional_mount indirection
                WITH_GITCONFIG=true
                shift
                ;;
            --runtime)
                RUNTIME_OPT="$2"
                shift 2
                ;;
            --runtime=*)
                RUNTIME_OPT="${1#*=}"
                shift
                ;;
            --pull)
                # shellcheck disable=SC2034  # read by the apptainer backend
                FORCE_PULL=true
                shift
                ;;
            --)
                shift
                EXTRA_ARGS=("$@")
                break
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                EXTRA_ARGS+=("$1")
                shift
                ;;
        esac
    done

    # Handle --install early (doesn't need a container runtime)
    if $SHOW_INSTALL; then
        show_install_instructions
        exit 0
    fi

    select_runtime
    rt_check

    WORKSPACE_DIR="$(pwd -P)"

    # Handle --list-sessions early (doesn't need image)
    if $LIST_SESSIONS; then
        log_info "Active sessions for: $(basename "$WORKSPACE_DIR")"
        rt_list_sessions
        exit 0
    fi

    if $BUILD_ONLY; then
        rt_build_image
        exit 0
    fi

    # Determine image tag and reference (pulls if needed)
    IMAGE_TAG=$(determine_image_tag)
    rt_resolve_image

    # Prepare mount points
    SESSION_ID=$(generate_session_id)
    CONTAINER_NAME=$(generate_container_name "$WORKSPACE_DIR" "$SESSION_ID")
    # shellcheck disable=SC2034  # PROJECT_KEY is used by the harness hooks
    PROJECT_KEY=$(project_key "$WORKSPACE_DIR")
    GOOGLE_CONFIG_DIR="${HOME}/.config/gcloud"

    # Host-side global config and per-project state (harness-specific)
    harness_ensure_config
    harness_setup_project

    # Auto-detect npm global prefix if not explicitly set
    if [[ -z "$NPM_GLOBAL" ]]; then
        NPM_GLOBAL=$(npm config get prefix 2>/dev/null || echo "")
    fi

    # Session spec: workspace and basic environment
    add_env PROJECT_NAME "$(basename "$WORKSPACE_DIR")"
    add_mount "$WORKSPACE_DIR" /workspace
    add_env TERM "${TERM:-xterm-256color}"
    add_env LANG "${LANG:-C.UTF-8}"

    # Harness-specific mounts and environment
    harness_mounts
    if [[ -n "${PODMAN_ARGS[*]:-}" ]]; then
        log_error "This ${BOX_NAME} launcher is older than the shared engine (it appends to PODMAN_ARGS)"
        log_error "Update the launcher and box-common.sh together"
        exit 1
    fi

    # Add optional mounts that may not exist on all systems
    add_optional_mount WITH_GCLOUD "${GOOGLE_CONFIG_DIR}/" "/home/coder/.config/gcloud" "ro"
    add_optional_mount WITH_GITCONFIG "${HOME}/.gitconfig" "/home/coder/.gitconfig" "ro"

    # Linux-specific mounts and environment variables
    if [[ "$OS_TYPE" == "linux" ]]; then
        # Timezone
        if [[ -f /etc/localtime ]]; then
            add_mount /etc/localtime /etc/localtime "ro,nolabel"
        fi
        add_env TZ "${TZ:-$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null || echo UTC)}"

        # PulseAudio socket for audio support
        if $RT_HOST_FEATURES && [[ -n "$XDG_RUNTIME_DIR" && -S "${XDG_RUNTIME_DIR}/pulse/native" ]]; then
            add_mount "${XDG_RUNTIME_DIR}/pulse/native" "${XDG_RUNTIME_DIR}/pulse/native"
            add_env PULSE_SERVER "unix:${XDG_RUNTIME_DIR}/pulse/native"
        fi
    fi

    # Generic passthrough: forward harness-relevant env vars from host
    if [[ -n "$ENV_PASSTHROUGH_REGEX" ]]; then
        while IFS='=' read -r name value; do
            add_env "$name" "$value"
        done < <(env | grep -E "$ENV_PASSTHROUGH_REGEX")
    fi

    # Also pass through specific non-prefixed vars if set
    for var in "${ENV_PASSTHROUGH_VARS[@]}"; do
        if [[ -n "${!var}" ]]; then
            add_env "$var" "${!var}"
        fi
    done

    # Desktop-host features: none of these exist when the "host" is a pod
    if $RT_HOST_FEATURES; then
        if ! $NO_CLIPBOARD; then
            add_clipboard_mounts
        fi
        add_npm_global_mount
    else
        NO_CLIPBOARD=true
    fi
    add_github_token

    # Firewall is Linux only, and needs a runtime that can grant NET_ADMIN
    if ! $NO_FIREWALL && ! $RT_FIREWALL; then
        log_error "--with-firewall is not available with the ${BOX_RUNTIME} runtime"
        log_error "Restrict egress at the pod/namespace level instead (see docs/kubernetes.md)"
        exit 1
    fi
    if ! $NO_FIREWALL && [[ "$OS_TYPE" != "linux" ]]; then
        log_warn "Firewall feature is only supported on Linux, ignoring --with-firewall flag"
        NO_FIREWALL=true
    fi

    # Build the launch command; the harness hook may override LAUNCH_CMD
    # (e.g. to wrap in tmux) and set NEEDS_SHELL=true
    LAUNCH_CMD="${HARNESS_CLI} ${EXTRA_ARGS[*]}"
    NEEDS_SHELL=false
    harness_pre_run

    # --shell: drop the harness command (and anything the hook added to it)
    # and start an interactive bash with the exact same container setup
    if $OPEN_SHELL; then
        HARNESS_CLI="/bin/bash"
        EXTRA_ARGS=()
        LAUNCH_CMD="/bin/bash"
        NEEDS_SHELL=false
    fi

    rt_render

    log_info "Starting ${HARNESS_TITLE} container..."
    log_info "Runtime: ${BOX_RUNTIME}"
    log_info "Workspace: $WORKSPACE_DIR"
    log_info "Session: $SESSION_ID"
    log_info "Firewall: $(if $NO_FIREWALL; then echo 'disabled'; else echo 'enabled'; fi)"
    log_info "Clipboard: $(if $NO_CLIPBOARD; then echo 'disabled'; else echo 'enabled'; fi)"
    harness_log_status
    if $NO_GITHUB; then
        log_info "GitHub: disabled"
    elif [[ -n "$GH_TOKEN_VALUE" ]]; then
        log_info "GitHub: enabled ($GH_TOKEN_SOURCE)"
    else
        log_info "GitHub: not available (run 'gh auth login' to enable)"
    fi
    for status in "${OPTIONAL_MOUNT_STATUS[@]}"; do
        log_info "$status"
    done

    rt_exec
}
