#!/bin/bash
# Functional test of the clipboard image bridge (lib/box-common.sh): starts
# the host helper against a stub `wl-paste` and drives it with the container
# shim, both running here. No container runtime or display is needed.

set -euo pipefail

TESTS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codebox-clip.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

mkdir -p "${ROOT}/stubs" "${ROOT}/run"
cat > "${ROOT}/stubs/wl-paste" <<'EOF'
#!/bin/bash
case "$*" in
    --list-types)      printf 'text/plain\nimage/png\nTARGETS\n' ;;
    "--type image/png") printf 'PNGDATA' ;;
    "--primary --no-newline") cat "${STATE}/primary" 2> /dev/null ;;
    *)                 echo "secret text"; exit 0 ;;
esac
EOF
cat > "${ROOT}/stubs/wl-copy" <<'EOF'
#!/bin/bash
if [[ "$*" == --primary ]]; then cat > "${STATE}/primary"; else cat > "${STATE}/clipboard"; fi
EOF
chmod +x "${ROOT}/stubs/wl-paste" "${ROOT}/stubs/wl-copy"
export STATE="${ROOT}/state"
mkdir -p "$STATE"
export PATH="${ROOT}/stubs:${PATH}"
export XDG_RUNTIME_DIR="${ROOT}/run"

# The engine is normally sourced by a launcher, which defines these
set +u
BOX_NAME="ccbox"
REGISTRY_IMAGE="guimou/ccbox"
SCRIPT_DIR="${TESTS_DIR}/.."
# shellcheck source=lib/box-common.sh
source "${TESTS_DIR}/../lib/box-common.sh"
set +e
CONTAINER_NAME="bridge-test"
clipboard_bridge_setup wayland-0 "" || { echo "FAIL setup"; exit 1; }

BASE="${XDG_RUNTIME_DIR}/codebox-clipboard/${CONTAINER_NAME}"
export CODEBOX_CLIPBOARD_DIR="${BASE}/shared"
SHIM="${BASE}/shim/wl-paste"
ln -s "$SHIM" "${ROOT}/wl-copy"
COPY="${ROOT}/wl-copy"
status=0
check() {  # description, expected, actual
    if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; status=1; fi
}

check "mounts the shared dir and the shim" \
    "mount|${BASE}/shared|/run/codebox-clipboard| mount|${BASE}/shim/wl-paste|/usr/local/bin/wl-paste|ro mount|${BASE}/shim/wl-paste|/usr/local/bin/wl-copy|ro env|WAYLAND_DISPLAY|codebox-clipboard-bridge" \
    "${BOX_SPEC[*]}"
check "lists image types only" "image/png" "$("$SHIM" -l)"
check "returns the image" "PNGDATA" "$("$SHIM" --type image/png)"
check "image by short option" "PNGDATA" "$("$SHIM" -t image/png)"
check "refuses text by type" "rc=1:" "$(out=$("$SHIM" --type text/plain); echo "rc=$?:${out}")"
check "refuses plain text paste" "rc=1:" "$(out=$("$SHIM" --no-newline); echo "rc=$?:${out}")"
check "refuses the clipboard text even as primary type" "rc=1:" "$(out=$("$SHIM" --primary --type image/png); echo "rc=$?:${out}")"

# Selection: written to the host clipboard and primary, primary read back
check "nothing selected yet" "rc=1:" "$(out=$("$SHIM" --primary --no-newline); echo "rc=$?:${out}")"
printf 'picked text' | "$COPY"
printf 'picked text' | "$COPY" --primary
check "copy reaches the host clipboard" "picked text" "$(cat "${STATE}/clipboard" 2> /dev/null)"
check "copy reaches the host primary selection" "picked text" "$(cat "${STATE}/primary" 2> /dev/null)"
check "middle-click reads the primary selection" "picked text" "$("$SHIM" --primary --no-newline)"
echo -n "selected in another window" > "${STATE}/primary"
check "the host primary selection wins" "selected in another window" "$("$SHIM" --primary --no-newline)"
rm -f "${STATE}/primary"
check "falls back to the last selection of the session" "picked text" "$("$SHIM" --primary --no-newline)"

# The text to copy is not read through a link planted by the container
echo "host secret" > "${ROOT}/secret"
ln -s "${ROOT}/secret" "${BASE}/shared/5.5.in"
echo "5.5 copy primary" > "${BASE}/shared/req"
for (( i = 0; i < 100; i++ )); do [[ -f "${BASE}/shared/5.5.rc" ]] && break; sleep 0.05; done
check "does not copy a host file through a planted symlink" "1:picked text" "$(cat "${BASE}/shared/5.5.rc"):$("$SHIM" --primary --no-newline)"
rm -f "${BASE}/shared"/5.5.*

# A symlink planted by the container where the answer goes is replaced,
# never written through
echo untouched > "${ROOT}/victim"
ln -s "${ROOT}/victim" "${BASE}/shared/7.7.out"
echo "7.7 get image/png" > "${BASE}/shared/req"
for (( i = 0; i < 100; i++ )); do [[ -f "${BASE}/shared/7.7.rc" ]] && break; sleep 0.05; done
check "does not write through a planted symlink" "untouched" "$(< "${ROOT}/victim")"
check "replaces the planted symlink with the answer" "regular:PNGDATA" \
    "$([[ ! -L "${BASE}/shared/7.7.out" ]] && echo "regular:$(< "${BASE}/shared/7.7.out")")"

# Malformed requests are ignored and do not stop the helper
printf '%s\n' "../../x get image/png" "8.8 exec image/png" "9.9 get image/png;id" > "${BASE}/shared/req"
check "survives malformed requests" "PNGDATA" "$("$SHIM" --type image/png)"
check "answers nothing for malformed requests" "" "$(find "${BASE}/shared" -mindepth 1 ! -name req ! -name '7.7.*' -printf '%f ')"

# --- SSH-forwarded clipboard ------------------------------------------------
# The laptop-side server (integrations/clipboard-ssh) behind a unix socket,
# standing for the socket ssh forwards; its clipboard holds another image.
mkdir -p "${ROOT}/laptop"
cat > "${ROOT}/laptop/wl-paste" <<'EOF'
#!/bin/bash
case "$*" in
    --list-types)        printf 'text/plain\nimage/jpeg\n' ;;
    "--type image/jpeg") printf 'LAPTOPJPEG' ;;
    *)                   exit 1 ;;
esac
EOF
chmod +x "${ROOT}/laptop/wl-paste"
SOCK="${XDG_RUNTIME_DIR}/codebox-clipboard-ssh.sock"
PATH="${ROOT}/laptop:${PATH}" WAYLAND_DISPLAY=wayland-0 python3 -c '
import socket, subprocess, sys
srv = socket.socket(socket.AF_UNIX); srv.bind(sys.argv[1]); srv.listen(8)
while True:
    conn, _ = srv.accept()
    subprocess.run([sys.argv[2]], stdin=conn, stdout=conn)
    conn.close()
' "$SOCK" "${TESTS_DIR}/../integrations/clipboard-ssh/codebox-clipboard-serve" &
SERVER_PID=$!
for (( i = 0; i < 100; i++ )); do [[ -S "$SOCK" ]] && break; sleep 0.05; done

check "ssh: lists the remote user's image types" "image/jpeg" "$("$SHIM" -l)"
check "ssh: returns the remote user's image" "LAPTOPJPEG" "$("$SHIM" --type image/jpeg)"
check "ssh: a type the laptop lacks is not taken from this host" "rc=1:" "$(out=$("$SHIM" --type image/png); echo "rc=$?:${out}")"
check "ssh: the server refuses text" "no" "$(clipboard_ssh_query get text/plain > /dev/null; [[ $? -eq 1 ]] && echo no)"

# Connection gone (socket file left behind, as after an SSH disconnect):
# back to this host's clipboard
kill "$SERVER_PID"; wait "$SERVER_PID" 2> /dev/null
check "ssh: falls back to the host clipboard when disconnected" "PNGDATA" "$("$SHIM" --type image/png)"

exit "$status"
