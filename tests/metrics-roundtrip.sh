#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2034

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export WP_SHELL_CONFIG_DIR="$test_root/config"
export WP_SHELL_STATE_DIR="$test_root/state"
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
ts="$(date +%s)"
sqlite3 "$METRICS_DB" "INSERT INTO system_samples VALUES($ts,12.5,0.42,2048,1024,0,35,1000,2000);"
sqlite3 "$METRICS_DB" "INSERT INTO site_samples VALUES($ts,'example.com',120,118,1,1,4096,45,120,80,20,20,2,3,0,5,0,160,200,80,12,512,8,4,1024);"
sqlite3 "$METRICS_DB" "INSERT INTO service_samples VALUES($ts,4,1000,1,32,900,100,0);"
report="$(metrics_report 1h)"
grep -q 'example.com' <<< "$report"
grep -q '120' <<< "$report"
grep -q '12.5%' <<< "$report"

printf 'Metrics database and report round-trip tests passed.\n'
