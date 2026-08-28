#!/bin/bash
# Shared launcher engine for the harness containers (ccbox / ocbox / qcbox).
#
# This file is sourced by the thin per-harness wrappers, which must define
# the following variables before sourcing:
#   BOX_NAME        - launcher/image name (ccbox, ocbox, qcbox)
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
#   harness_mounts          - append harness mounts/env to PODMAN_ARGS
#   harness_pre_run         - last-minute adjustments before launch; may set
#                             LAUNCH_CMD (shell command string) and
#                             NEEDS_SHELL=true to run via bash -c
#   harness_log_status      - print extra harness-specific status lines
#
# The wrapper must call box_main "$@" after sourcing this file.

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

# Registry configuration
REGISTRY="quay.io"
FULL_REGISTRY_IMAGE="${REGISTRY}/${REGISTRY_IMAGE}"
LOCAL_IMAGE_NAME="${BOX_NAME}"

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
    echo "  --build                  Build image locally (for development)"
    echo "  --local                  Use locally-built image instead of pulling"
    printf "  %-24s %s\n" "${VERSION_FLAG} VERSION" "Use specific ${HARNESS_TITLE} version"
    echo "  --with-firewall          Enable network firewall restrictions"
    echo "  --no-clipboard           Disable clipboard access (for extra security)"
    echo "  --npm-global PATH        Mount npm global prefix (auto-detected if not set)"
    echo "  --with-github            Explicitly enable GitHub token injection (auto by default)"
    echo "  --no-github              Disable GitHub token injection"
    echo "  --github-token TOKEN     Use specific GitHub token instead of auto-detecting"
    echo "  --list-sessions          List active sessions for this project"
    echo "  --install                Show installation instructions"
    harness_extra_help
    echo "  -h, --help               Show this help message"
    echo ""
    echo "Examples:"
    echo "  ${BOX_NAME}                              # Pull latest and run"
    echo "  ${BOX_NAME} ${VERSION_FLAG} 1.2.3        # Pull specific version"
    echo "  ${BOX_NAME} --local                      # Use local image"
    echo "  ${BOX_NAME} --build                      # Build locally"
    echo "  ${BOX_NAME} --with-firewall              # Run with network restrictions"
    echo "  ${BOX_NAME} --no-github                  # Run without GitHub token"
    echo "  ${BOX_NAME} -- --version                 # Pass args to ${HARNESS_CLI}"
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

# Build image locally
build_image() {
    if [[ ! -f "${SCRIPT_DIR}/Dockerfile" ]]; then
        log_error "No Dockerfile found in ${SCRIPT_DIR}"
        log_error "Building locally requires a clone of the repository:"
        log_error "  git clone https://github.com/guimou/ccbox.git"
        exit 1
    fi

    local tag
    tag=$(determine_image_tag)
    local full_tag="${LOCAL_IMAGE_NAME}:${tag}"

    log_info "Building container image: $full_tag"
    BUILD_ARGS=(--build-arg "HARNESS=${HARNESS}")

    if [[ "$tag" != "latest" ]]; then
        log_info "Using ${HARNESS_TITLE} version: $tag"
        BUILD_ARGS+=(--build-arg "HARNESS_VERSION=${tag}")
    else
        log_info "Using latest ${HARNESS_TITLE} version"
    fi

    podman build "${BUILD_ARGS[@]}" -t "$full_tag" "$SCRIPT_DIR"

    # Also tag as latest for convenience
    if [[ "$tag" != "latest" ]]; then
        podman tag "$full_tag" "${LOCAL_IMAGE_NAME}:latest"
    fi

    log_info "Image built successfully: $full_tag"
}

box_main() {
    # Parse arguments
    BUILD_ONLY=false
    USE_LOCAL=false
    NO_FIREWALL=true
    NO_CLIPBOARD=false
    NO_GITHUB=false
    WITH_GITHUB=false
    GITHUB_TOKEN=""
    LIST_SESSIONS=false
    SHOW_INSTALL=false
    HARNESS_VERSION=""
    NPM_GLOBAL=""
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

    # Handle --install early (doesn't need podman)
    if $SHOW_INSTALL; then
        show_install_instructions
        exit 0
    fi

    # Check if podman is available
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

    # Handle --list-sessions early (doesn't need image)
    if $LIST_SESSIONS; then
        WORKSPACE_DIR="$(pwd -P)"
        BASE_NAME=$(generate_container_name "$WORKSPACE_DIR")
        log_info "Active sessions for: $(basename "$WORKSPACE_DIR")"
        podman ps --filter "name=^${BASE_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.CreatedAt}}"
        exit 0
    fi

    if $BUILD_ONLY; then
        build_image
        exit 0
    fi

    # Determine image tag and reference
    IMAGE_TAG=$(determine_image_tag)

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

    # Prepare mount points
    WORKSPACE_DIR="$(pwd -P)"
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

    # Build podman run arguments
    # shellcheck disable=SC2054  # commas are part of the --userns option value
    PODMAN_ARGS=(
        --rm
        -it
        --name "$CONTAINER_NAME"
        --hostname "$BOX_NAME"
        --userns=keep-id:uid=1000,gid=1000
        -e PROJECT_NAME="$(basename "$WORKSPACE_DIR")"
        -v "${WORKSPACE_DIR}:/workspace$(vol_flag "")"
        -e "TERM=${TERM:-xterm-256color}"
        -e "LANG=${LANG:-C.UTF-8}"
        -w /workspace
    )

    # Harness-specific mounts and environment
    harness_mounts

    # Add optional mounts that may not exist on all systems
    if [[ -d "$GOOGLE_CONFIG_DIR" ]]; then
        PODMAN_ARGS+=(-v "${GOOGLE_CONFIG_DIR}:/home/claude/.config/gcloud$(vol_flag "ro")")
    fi

    if [[ -f "${HOME}/.gitconfig" ]]; then
        PODMAN_ARGS+=(-v "${HOME}/.gitconfig:/home/claude/.gitconfig$(vol_flag "ro")")
    fi

    # Linux-specific mounts and environment variables
    if [[ "$OS_TYPE" == "linux" ]]; then
        # Timezone
        if [[ -f /etc/localtime ]]; then
            PODMAN_ARGS+=(-v /etc/localtime:/etc/localtime:ro)
        fi
        PODMAN_ARGS+=(-e TZ="${TZ:-$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null || echo UTC)}")

        # PulseAudio socket for audio support
        if [[ -n "$XDG_RUNTIME_DIR" && -S "${XDG_RUNTIME_DIR}/pulse/native" ]]; then
            PODMAN_ARGS+=(
                -v "${XDG_RUNTIME_DIR}/pulse/native:${XDG_RUNTIME_DIR}/pulse/native$(vol_flag "")"
                -e PULSE_SERVER="unix:${XDG_RUNTIME_DIR}/pulse/native"
            )
        fi
    fi

    # Generic passthrough: forward harness-relevant env vars from host
    if [[ -n "$ENV_PASSTHROUGH_REGEX" ]]; then
        while IFS='=' read -r name value; do
            PODMAN_ARGS+=(-e "${name}=${value}")
        done < <(env | grep -E "$ENV_PASSTHROUGH_REGEX")
    fi

    # Also pass through specific non-prefixed vars if set
    for var in "${ENV_PASSTHROUGH_VARS[@]}"; do
        if [[ -n "${!var}" ]]; then
            PODMAN_ARGS+=(-e "${var}=${!var}")
        fi
    done

    # Clipboard/display access for image pasting (CTRL+V)
    if ! $NO_CLIPBOARD; then
        if [[ "$OS_TYPE" == "linux" ]]; then
            if [[ -n "$WAYLAND_DISPLAY" && -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ]]; then
                # Wayland clipboard access
                PODMAN_ARGS+=(
                    -v "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}:${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}:ro"
                    -e "WAYLAND_DISPLAY=${WAYLAND_DISPLAY}"
                    -e "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR}"
                )
            elif [[ -n "$DISPLAY" && -d /tmp/.X11-unix ]]; then
                # X11 clipboard access
                PODMAN_ARGS+=(
                    -v "/tmp/.X11-unix:/tmp/.X11-unix:ro"
                    -e "DISPLAY=${DISPLAY}"
                )
                if [[ -f "${HOME}/.Xauthority" ]]; then
                    PODMAN_ARGS+=(-v "${HOME}/.Xauthority:/home/claude/.Xauthority$(vol_flag "ro")")
                fi
            fi
        elif [[ "$OS_TYPE" == "macos" ]]; then
            # macOS: basic X11 support via XQuartz (if available)
            if [[ -n "$DISPLAY" && -d /tmp/.X11-unix ]]; then
                PODMAN_ARGS+=(
                    -v "/tmp/.X11-unix:/tmp/.X11-unix:ro"
                    -e "DISPLAY=${DISPLAY}"
                )
            fi
        fi
    fi

    # Mount npm global packages (read-only) if available and not a system directory
    if [[ -n "$NPM_GLOBAL" && "$NPM_GLOBAL" != "/usr" && "$NPM_GLOBAL" != "/usr/local" && -d "$NPM_GLOBAL" ]]; then
        # On macOS, only /Users/* or /private/* paths work with Podman VM
        if [[ "$OS_TYPE" == "macos" ]]; then
            if [[ "$NPM_GLOBAL" == /Users/* || "$NPM_GLOBAL" == /private/* ]]; then
                PODMAN_ARGS+=(-v "${NPM_GLOBAL}:/home/claude/.npm-global$(vol_flag "ro")")
            else
                log_warn "npm global prefix '$NPM_GLOBAL' not accessible in Podman VM, skipping"
            fi
        else
            PODMAN_ARGS+=(-v "${NPM_GLOBAL}:/home/claude/.npm-global$(vol_flag "ro")")
        fi
    fi

    # GitHub token injection for authentication
    # Token is auto-detected from host's gh CLI unless --no-github is specified
    GH_TOKEN_VALUE=""
    GH_TOKEN_SOURCE=""

    if ! $NO_GITHUB; then
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
            PODMAN_ARGS+=(-e "GH_TOKEN=${GH_TOKEN_VALUE}")
            PODMAN_ARGS+=(-e "GITHUB_TOKEN=${GH_TOKEN_VALUE}")
        elif $WITH_GITHUB; then
            log_warn "GitHub token requested but not available"
            log_warn "Run 'gh auth login' on host to authenticate with GitHub"
        fi
    fi

    # Add firewall capabilities if firewall is enabled (Linux only)
    if ! $NO_FIREWALL; then
        if [[ "$OS_TYPE" == "linux" ]]; then
            PODMAN_ARGS+=(
                --cap-add=NET_ADMIN
                --cap-add=NET_RAW
            )
        else
            log_warn "Firewall feature is only supported on Linux, ignoring --with-firewall flag"
            NO_FIREWALL=true
        fi
    fi

    # Build the launch command; the harness hook may override LAUNCH_CMD
    # (e.g. to wrap in tmux) and set NEEDS_SHELL=true
    LAUNCH_CMD="${HARNESS_CLI} ${EXTRA_ARGS[*]}"
    NEEDS_SHELL=false
    harness_pre_run

    if $NO_FIREWALL && ! $NEEDS_SHELL; then
        PODMAN_ARGS+=("$IMAGE_REF" "$HARNESS_CLI" "${EXTRA_ARGS[@]}")
    elif $NO_FIREWALL; then
        PODMAN_ARGS+=("$IMAGE_REF" /bin/bash -c "${LAUNCH_CMD}")
    else
        # Start with firewall initialization, then run the harness
        PODMAN_ARGS+=("$IMAGE_REF" /bin/bash -c "sudo /usr/local/bin/init-firewall.sh && ${LAUNCH_CMD}")
    fi

    log_info "Starting ${HARNESS_TITLE} container..."
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

    # Debug mode: print the podman command
    if [[ -n "${DEBUG}" ]]; then
        echo "DEBUG: podman run command:" >&2
        printf '%q ' podman run "${PODMAN_ARGS[@]}" >&2
        echo >&2
    fi

    # Run the container
    exec podman run "${PODMAN_ARGS[@]}"
}
