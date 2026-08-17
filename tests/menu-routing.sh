#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2034,SC2317,SC2329

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/wp-shell.sh"

wp_shell_environment_managed() { return 1; }
wordpress_environment_detected() { return 1; }
new_server_wizard() { printf 'INSTALL_CALLED\n'; }
output="$(installation_menu <<< '1')"
grep -q 'WordPress stack not detected' <<< "$output"
grep -q 'Install WordPress environment' <<< "$output"
grep -q 'INSTALL_CALLED' <<< "$output"

SITE_COUNT=1
bootstrap_server() { printf 'REPAIR_CALLED\n'; }
output="$(install_or_repair_environment)"
grep -q 'REPAIR_CALLED' <<< "$output"
SITE_COUNT=0

wordpress_environment_detected() { return 0; }
show_detected_environment() { printf 'DETECTION_CALLED\n'; }
output="$(interactive_menu <<< '4')"
grep -q 'not managed by wp-shell' <<< "$output"
grep -q 'Import existing websites only' <<< "$output"
grep -q 'DETECTION_CALLED' <<< "$output"

wp_shell_environment_managed() { return 0; }
SITE_COUNT=1
install_self() { printf 'INSTALL_SELF_CALLED\n'; }
list_sites() { printf 'LIST_CALLED\n'; }
output="$(interactive_menu <<< '3')"
grep -q 'Dashboard' <<< "$output"
grep -q 'Back up all websites' <<< "$output"
grep -q 'INSTALL_SELF_CALLED' <<< "$output"
grep -q 'LIST_CALLED' <<< "$output"

printf 'Context-aware menu routing tests passed.\n'
