#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2016,SC2034,SC2317,SC2329

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root" /tmp/wp-shell-must-not-execute' EXIT

export WP_SHELL_CONFIG_DIR="$test_root/current"
export WP_SHELL_STATE_DIR="$test_root/state"
export WP_SHELL_LEGACY_VPS_CONFIG_DIR="$test_root/legacy-vps"
export WP_SHELL_LEGACY_SINGLE_CONFIG_DIR="$test_root/legacy-single"
source "$repo_root/wp-shell.sh"
install -d -m 0700 "$CONFIG_DIR" "$DATABASE_CONFIG_DIR"

dangerous_title='"; touch /tmp/wp-shell-must-not-execute; #'
SITE_COUNT=1
SITE_DOMAINS[1]="example.com"
SITE_PRIMARY_DOMAINS[1]="www.example.com"
SITE_PHP_VERSIONS[1]="8.3"
SITE_WOOCOMMERCE[1]="no"
SITE_WWW[1]="yes"
SITE_REDIS_DATABASES[1]="0"
SITE_MODES[1]="managed"
SITE_ADMIN_USERS[1]="wpadmin"
SITE_ADMIN_EMAILS[1]="admin@example.com"
SITE_TITLES[1]="$dangerous_title"
SITE_PATHS[1]="/var/www/example.com/public"
save_sites_config

reset_sites
load_sites_config
[[ "$SITE_COUNT" -eq 1 ]]
[[ "${SITE_DOMAINS[1]}" == "example.com" ]]
[[ "${SITE_PRIMARY_DOMAINS[1]}" == "www.example.com" ]]
[[ "${SITE_MODES[1]}" == "managed" ]]
[[ "${SITE_TITLES[1]}" == "$dangerous_title" ]]
[[ ! -e /tmp/wp-shell-must-not-execute ]]

rm -f "$SITES_CONFIG_FILE"
reset_sites
install -d -m 0700 "$LEGACY_VPS_CONFIG_DIR/databases"
printf 'version|2\nsite|legacy.example.com|8.3|no|no|0|%s|%s|%s|%s\n' \
    "$(b64_encode wpadmin)" "$(b64_encode admin@legacy.example.com)" \
    "$(b64_encode Legacy)" "$(b64_encode /var/www/legacy.example.com/public)" \
    > "$LEGACY_VPS_CONFIG_DIR/sites.v2"
printf 'database|wp_0123456789ab|wp_0123456789ab|%s\n' "$(b64_encode secret)" \
    > "$LEGACY_VPS_CONFIG_DIR/databases/legacy.example.com.v1"
migrate_legacy_configs
reset_sites
load_sites_config
[[ "$SITE_COUNT" -eq 1 ]]
[[ "${SITE_DOMAINS[1]}" == "legacy.example.com" ]]
[[ -f "$DATABASE_CONFIG_DIR/legacy.example.com.v1" ]]
find "$CONFIG_DIR/migration-backup" -type f -name sites.v2 | grep -q .

SITE_COUNT=2
SITE_DOMAINS[2]="imported.example.com"
SITE_MODES[2]="imported"
deploy_log="$test_root/deployed"
prepare_stack() { :; }
collect_yes_no() { return 1; }
deploy_site() { printf '%s\n' "${SITE_DOMAINS[$1]}" >> "$deploy_log"; }
install_self() { :; }
install_backup_timer() { :; }
install_metrics_timer() { :; }
collect_metrics() { :; }
bootstrap_server
grep -qx 'legacy.example.com' "$deploy_log"
if grep -q 'imported.example.com' "$deploy_log"; then
    printf 'An imported site was deployed without explicit transfer.\n' >&2
    exit 1
fi

printf 'Configuration round-trip and legacy migration tests passed.\n'
