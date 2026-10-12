#!/usr/bin/env bash
# deepin-port: verify that `uu-x11-input --clip WxH+X+Y` maps absolute pointer
# coordinates into the clipped monitor instead of the whole root window.
#
# Run: bash scripts/test-x11-input-clip.sh

set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/uurb-x11-clip.XXXXXX")"
ready_file="$temporary_dir/x11-input.port"
helper_pid=""
xvfb_pid=""

cleanup() {
    local pid

    for pid in "$helper_pid" "$xvfb_pid"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    wait 2>/dev/null || true
    rm -rf -- "$temporary_dir"
}
trap cleanup EXIT

for command in Xvfb xdpyinfo xdotool python3; do
    command -v "$command" >/dev/null 2>&1 || {
        printf 'missing command: %s\n' "$command" >&2
        exit 1
    }
done

"$repo_dir/scripts/build-compat.sh" "$temporary_dir/compat" >/dev/null

display=""
for number in {88..99}; do
    if [[ ! -S "/tmp/.X11-unix/X$number" ]]; then
        display=":$number"
        break
    fi
done
[[ -n "$display" ]] || {
    printf 'no free isolated X display in :88..:99\n' >&2
    exit 1
}

Xvfb "$display" -screen 0 800x600x24 -ac -nolisten tcp \
    >"$temporary_dir/xvfb.log" 2>&1 &
xvfb_pid=$!
for _ in {1..50}; do
    if DISPLAY="$display" timeout 0.5 xdpyinfo >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

token="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
DISPLAY="$display" UURB_X11_INPUT_TOKEN="$token" \
    "$temporary_dir/compat/uu-x11-input" --ready-file "$ready_file" \
    --min-hold-ms 0 --clip 500x400+200+150 \
    >"$temporary_dir/x11-input.log" 2>&1 &
helper_pid=$!
for _ in {1..50}; do
    [[ -s "$ready_file" ]] && break
    sleep 0.1
done
[[ -s "$ready_file" ]] || {
    printf 'isolated X11 helper did not become ready\n' >&2
    exit 1
}
port="$(tr -d '[:space:]' < "$ready_file")"

python3 - "$display" "$port" "$token" <<'PY'
import socket
import struct
import subprocess
import sys
import time

display, port, token = sys.argv[1], int(sys.argv[2]), sys.argv[3]
MAGIC = 0x58315255
VERSION = 3
MOUSE = 2
MOVE = 0x0001
ABSOLUTE = 0x8000

sock = socket.create_connection(("127.0.0.1", port), timeout=5)
sock.sendall(struct.pack("<II64s", MAGIC, VERSION, token.encode()))
magic, _sequence, result, error = struct.unpack("<IIII", sock.recv(16))
if magic != MAGIC or result != 1 or error != 0:
    raise SystemExit(f"handshake failed: {magic:#x} {result} {error}")


def pointer():
    out = subprocess.check_output(
        ["xdotool", "getmouselocation", "--shell"],
        env={"DISPLAY": display}, text=True)
    values = dict(line.split("=", 1) for line in out.splitlines())
    return int(values["X"]), int(values["Y"])


# clip 500x400+200+150 over an 800x600 root window
cases = [((0, 0), (200, 150)),
         ((32767, 32767), (449, 349)),
         ((65535, 65535), (699, 549))]
for sequence, ((nx, ny), expected) in enumerate(cases, start=1):
    event = struct.pack("<IIiiIHH", MOUSE, MOVE | ABSOLUTE, nx, ny, 0, 0, 0)
    sock.sendall(struct.pack("<IIII", MAGIC, sequence, 1, 0) + event)
    magic, echoed, result, error = struct.unpack("<IIII", sock.recv(16))
    if magic != MAGIC or echoed != sequence or result != 1 or error != 0:
        raise SystemExit(f"injection failed for {nx},{ny}: {result} {error}")
    time.sleep(0.15)
    observed = pointer()
    if observed != expected:
        raise SystemExit(f"clipped pointer mismatch for {nx},{ny}: "
                         f"observed {observed}, expected {expected}")
    print(f"ok  normalized {nx},{ny} -> pointer {observed}")
sock.close()
PY

printf 'uu-x11-input clip mapping test passed\n'
