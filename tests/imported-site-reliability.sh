#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2317,SC2329

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export WP_SHELL_CONFIG_DIR="$test_root/config"
export WP_SHELL_STATE_DIR="$test_root/state"
source "$repo_root/wp-shell.sh"

# detect_ssh_port must consume all sshd output under pipefail.  Exiting from
# awk after the first line used to close the pipe and could turn success into
# SIGPIPE (141) when sshd emitted a large configuration dump.
unset SSH_CONNECTION
sshd() {
    printf 'port 2222\n'
    awk 'BEGIN {for (i=0; i<10000; i++) print "fixture value"}'
}
[[ "$(detect_ssh_port)" == 2222 ]]

# Missing, symlinked and empty backup roots are observations, not collector
# failures.  A populated directory must select the newest completed backup
# without an early-reader pipeline.
[[ "$(backup_age_hours "$test_root/missing")" == -1 ]]
mkdir -p "$test_root/backups"
[[ "$(backup_age_hours "$test_root/backups")" == -1 ]]
ln -s "$test_root/backups" "$test_root/backup-link"
[[ "$(backup_age_hours "$test_root/backup-link")" == -1 ]]
mkdir "$test_root/backups/20260901-010101" "$test_root/backups/20260902-010101"
touch -d '4 hours ago' "$test_root/backups/20260901-010101"
touch -d '1 hour ago' "$test_root/backups/20260902-010101"
backup_age="$(backup_age_hours "$test_root/backups")"
awk -v age="$backup_age" 'BEGIN {exit !(age >= 0.9 && age <= 1.1)}'

# WordPress may print boolean false as an empty string, 0 or false.  Nothing
# else is accepted as a disabled WP_DEBUG value.
wp_debug_value_is_false ""
wp_debug_value_is_false 0
wp_debug_value_is_false false
for unsafe_value in 1 true FALSE off no arbitrary; do
    if wp_debug_value_is_false "$unsafe_value"; then
        printf 'Unsafe WP_DEBUG value was accepted: %s\n' "$unsafe_value" >&2
        exit 1
    fi
done

printf 'Imported-site helper, pipefail and WP_DEBUG regressions passed.\n'
