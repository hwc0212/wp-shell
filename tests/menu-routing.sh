#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2034,SC2317,SC2329

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export WP_SHELL_CONFIG_DIR="$test_root/config"
export WP_SHELL_STATE_DIR="$test_root/state"
source "$repo_root/wp-shell.sh"
install -d -m 0700 "$CONFIG_DIR"

detect_public_ipv4() { printf '203.0.113.10'; }
detect_private_ipv4() { printf '10.0.0.10'; }
memory_mb() { printf '4096'; }
service_state() { printf 'active'; }
ufw() { printf 'Status: active\n'; }
ENVIRONMENT_MODE="multi"
DEFAULT_PHP_VERSION="8.4"
ENVIRONMENT_UFW="yes"
SITE_COUNT=0
output="$(show_environment_summary)"
grep -q 'Environment installation complete' <<< "$output"
grep -q 'Mode           multi' <<< "$output"
grep -q 'PHP            8.4' <<< "$output"
grep -q 'Public IPv4    203.0.113.10' <<< "$output"
grep -q 'Private IPv4   10.0.0.10 (do not use for public DNS)' <<< "$output"
grep -q 'Root domain: A -> 203.0.113.10' <<< "$output"
grep -q "sudo wp-shell -> 'Add a new website'" <<< "$output"

bootstrap_server() { printf 'ENVIRONMENT_BOOTSTRAP_CALLED\n'; }
output="$(new_server_wizard <<< $'1\n2\nn')"
grep -q 'Deployment mode:' <<< "$output"
grep -q 'PHP version:' <<< "$output"
grep -q 'ENVIRONMENT_BOOTSTRAP_CALLED' <<< "$output"
[[ ! -e "$SITES_CONFIG_FILE" ]]
load_environment_config
[[ "$ENVIRONMENT_MODE" == "single" ]]
[[ "$DEFAULT_PHP_VERSION" == "8.3" ]]
[[ "$ENVIRONMENT_UFW" == "no" ]]
rm -f "$ENVIRONMENT_CONFIG_FILE"

wp_shell_environment_managed() { return 1; }
wordpress_environment_detected() { return 1; }
new_server_wizard() { printf 'INSTALL_CALLED\n'; }
output="$(installation_menu <<< '1')"
grep -q 'WordPress stack not detected' <<< "$output"
grep -q 'Install WordPress environment' <<< "$output"
grep -q 'INSTALL_CALLED' <<< "$output"

bootstrap_server() { printf 'REPAIR_CALLED\n'; }
ENVIRONMENT_MODE="multi"
DEFAULT_PHP_VERSION="8.3"
ENVIRONMENT_UFW="no"
save_environment_config
output="$(install_or_repair_environment)"
grep -q 'REPAIR_CALLED' <<< "$output"

wordpress_environment_detected() { return 0; }
show_detected_environment() { printf 'DETECTION_CALLED\n'; }
output="$(interactive_menu <<< '4')"
grep -q 'not managed by wp-shell' <<< "$output"
grep -q 'Import existing websites only' <<< "$output"
grep -q 'DETECTION_CALLED' <<< "$output"

wp_shell_environment_managed() { return 0; }
SITE_COUNT=0
install_self() { printf 'INSTALL_SELF_CALLED\n'; }
list_sites() { printf 'LIST_CALLED\n'; }
output="$(interactive_menu <<< '3')"
grep -q 'Dashboard' <<< "$output"
grep -q 'Mode: multi | PHP: 8.3 | Sites: 0' <<< "$output"
grep -q 'Back up all websites' <<< "$output"
grep -q 'INSTALL_SELF_CALLED' <<< "$output"
grep -q 'LIST_CALLED' <<< "$output"

printf 'Context-aware menu routing tests passed.\n'
