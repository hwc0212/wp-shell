#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2034

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" == "child" ]]; then
    source "$repo_root/wp-shell.sh"
    dashboard
    exit 0
fi

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export WP_SHELL_CONFIG_DIR="$test_root/config"
export WP_SHELL_STATE_DIR="$test_root/state"
export TERM=xterm
source "$repo_root/wp-shell.sh"
install -d -m 0700 "$CONFIG_DIR" "$DATABASE_CONFIG_DIR" "$STATE_DIR"

SITE_COUNT=1
SITE_DOMAINS[1]="example.com"
SITE_PRIMARY_DOMAINS[1]="example.com"
SITE_PHP_VERSIONS[1]="8.3"
SITE_WOOCOMMERCE[1]="no"
SITE_WWW[1]="no"
SITE_REDIS_DATABASES[1]="0"
SITE_MODES[1]="managed"
SITE_ADMIN_USERS[1]="wpadmin"
SITE_ADMIN_EMAILS[1]="admin@example.com"
SITE_TITLES[1]="Example"
SITE_PATHS[1]="/var/www/example.com/public"
save_sites_config
init_metrics_database >/dev/null

python3 - "$0" <<'PY'
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time

pid, descriptor = pty.fork()
if pid == 0:
    os.execv("/bin/bash", ["bash", sys.argv[1], "child"])

fcntl.ioctl(descriptor, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
deadline = time.monotonic() + 8
next_quit = time.monotonic() + 1
status = None
captured = bytearray()
while time.monotonic() < deadline:
    if time.monotonic() >= next_quit:
        os.write(descriptor, b"q")
        next_quit += 0.5
    ready, _, _ = select.select([descriptor], [], [], 0.1)
    if ready:
        try:
            captured.extend(os.read(descriptor, 65536))
        except OSError:
            pass
    result, status = os.waitpid(pid, os.WNOHANG)
    if result == pid:
        break
else:
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    raise SystemExit("dashboard did not exit after the q key: " + captured[-500:].decode(errors="replace"))

if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
    raise SystemExit("dashboard child failed")
screen = captured.decode(errors="replace")
if "example.com" not in screen or "NO DATA" not in screen:
    raise SystemExit("dashboard did not show the registered site without samples: " + screen[-1000:])
PY
printf 'Dashboard interactive smoke test passed.\n'
