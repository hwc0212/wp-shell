#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2034,SC2154,SC2317,SC2329

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $EUID -eq 0 ]] || { printf 'Run this integration test as root in an isolated Ubuntu container.\n' >&2; exit 1; }
command -v php-fpm8.3 >/dev/null

TEST_ROOT="$(mktemp -d /tmp/wp-shell-v11-fpm.XXXXXXXX)"
export WP_SHELL_TEST_ROOT_WRITES=yes
export WP_SHELL_CONFIG_DIR="$TEST_ROOT/etc/wp-shell"
export WP_SHELL_STATE_DIR="$TEST_ROOT/var/lib/wp-shell"
mkdir -p "$WP_SHELL_CONFIG_DIR/transactions" "$WP_SHELL_STATE_DIR"

# shellcheck source=../wp-shell-v11.sh
source "$ROOT_DIR/wp-shell-v11.sh"

SITE_COUNT=1
ENVIRONMENT_MODE=multi
DEFAULT_PHP_VERSION=8.3
SITE_DOMAINS[1]=integration.example.com
SITE_PRIMARY_DOMAINS[1]=integration.example.com
SITE_PHP_VERSIONS[1]=8.3
SITE_WOOCOMMERCE[1]=no
SITE_MODES[1]=managed

pool_file="$(site_php_pool_file integration.example.com 8.3)"
override_file=/etc/php/8.3/fpm/pool.d/zzz-wp-shell-v11-integration.conf
cleanup() {
    rm -f -- "$pool_file" "$override_file"
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

cat > "$pool_file" <<EOF
; Managed by wp-shell for integration.example.com.
[$(site_pool_id integration.example.com)]
user = www-data
group = www-data
listen = /tmp/wp-shell-v11-integration.sock
pm = ondemand
pm.max_children = 2
pm.process_idle_timeout = 20s
pm.max_requests = 300
EOF
chmod 0644 "$pool_file"

php-fpm8.3 -t
[[ "$(read_effective_site_pool_limit integration.example.com 8.3)" == 2 ]]
[[ "$(read_effective_default_pool_limit 8.3)" =~ ^[1-9][0-9]*$ ]]
[[ "$(opcache_effective_values 8.3)" =~ ^[1-9][0-9]*\ [1-9][0-9]*$ ]]

reload_log="$TEST_ROOT/reloads"
php_fpm_service_action() {
    [[ "$1" == reload && "$2" == 8.3 ]]
    printf '%s %s\n' "$1" "$2" >> "$reload_log"
}

# Real php-fpm -t/-tt candidate semantics plus the v11 transaction path.
TRANSACTION_CONTEXT=yes
site_workers_command integration.example.com 3 --confirm >/dev/null
transaction_commit >/dev/null
[[ "$(read_effective_site_pool_limit integration.example.com 8.3)" == 3 ]]
grep -Fxq 'php|integration.example.com|3' "$TUNING_CONFIG_FILE"
[[ "$(wc -l < "$reload_log")" == 1 ]]

# A later administrator fragment is detected from real merged -tt output and remains untouched.
cat > "$override_file" <<EOF
[$(site_pool_id integration.example.com)]
pm.max_children = 8
EOF
override_hash="$(sha256sum "$override_file")"
pool_hash="$(sha256sum "$pool_file")"
tuning_hash="$(sha256sum "$TUNING_CONFIG_FILE")"
if blocked_output="$(site_workers_command integration.example.com 2 --confirm 2>&1)"; then blocked_status=0; else blocked_status=$?; fi
[[ "$blocked_status" -ne 0 ]]
grep -Fq 'administrator override owns the effective value' <<< "$blocked_output"
[[ "$override_hash" == "$(sha256sum "$override_file")" ]]
[[ "$pool_hash" == "$(sha256sum "$pool_file")" ]]
[[ "$tuning_hash" == "$(sha256sum "$TUNING_CONFIG_FILE")" ]]
[[ "$(wc -l < "$reload_log")" == 1 ]]

printf 'v11 real php-fpm effective-config integration tests passed.\n'
