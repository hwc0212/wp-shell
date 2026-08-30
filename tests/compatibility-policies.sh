#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2034,SC2317,SC2329
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
export WP_SHELL_CONFIG_DIR="$test_root/config"
export WP_SHELL_STATE_DIR="$test_root/state"
source "$repo_root/wp-shell.sh"
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$test_root/site"
printf '<?php\n' > "$test_root/site/wp-load.php"
printf '<?php\n' > "$test_root/site/wp-config.php"

SITE_COUNT=1
SITE_DOMAINS[1]=example.com
SITE_PRIMARY_DOMAINS[1]=example.com
SITE_PHP_VERSIONS[1]=8.3
SITE_WOOCOMMERCE[1]=no
SITE_WWW[1]=no
SITE_REDIS_DATABASES[1]=0
SITE_ADMIN_USERS[1]=wpadmin
SITE_ADMIN_EMAILS[1]=admin@example.com
SITE_TITLES[1]=Example
SITE_PATHS[1]="$test_root/site"
SITE_MODES[1]=managed

wp_calls="$test_root/wp-calls"
site_wp_cli() {
    printf '%s\n' "$*" >> "$wp_calls"
    [[ "$*" != *'plugin is-active redis-cache'* ]]
}
site_wp_config_set_redis_secret() { printf 'redis-secret-write\n' >> "$wp_calls"; }
load_or_create_redis_secret() { REDIS_PASSWORD="$(printf 'a%.0s' {1..48})"; }
memory_mb() { printf '2048'; }
transaction_begin() { :; }
transaction_backup_file() { :; }
set_site_permissions() { :; }

# A site with no opt-in policy must not receive plugin/content/cache changes.
install_wordpress_site 1
grep -Fq 'config set WP_DEBUG false --raw' "$wp_calls"
if grep -Eq 'plugin install redis-cache|redis enable|config set WP_CACHE|rewrite structure|plugin delete' "$wp_calls"; then
    printf 'A compatibility-sensitive WordPress change ran without opt-in.\n' >&2
    exit 1
fi
[[ "$(site_policy_value example.com object-cache missing)" == disabled ]]

# Explicit object-cache opt-in enables only that integration.
: > "$wp_calls"
set_site_policy example.com object-cache enabled
install_wordpress_site 1
grep -Fq 'plugin install redis-cache --activate' "$wp_calls"
grep -Fq 'redis enable' "$wp_calls"
grep -Fq 'redis-secret-write' "$wp_calls"
if grep -Eq 'config set WP_CACHE|rewrite structure|plugin delete' "$wp_calls"; then
    printf 'An unrelated WordPress preference was changed during object-cache opt-in.\n' >&2
    exit 1
fi

if grep -q 'enable_cloudflare_login_limits' "$repo_root/wp-shell.sh"; then
    printf 'Cloudflare host trust must not change per-site login policy.\n' >&2
    exit 1
fi

printf 'Conservative WordPress, cache and Cloudflare policy tests passed.\n'
