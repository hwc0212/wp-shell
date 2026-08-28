#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2034,SC2317,SC2329

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $EUID -eq 0 ]] || { printf 'This test must run as root in an isolated container.\n' >&2; exit 1; }
for required in mariadbd redis-server php-fpm8.3 openssl cgi-fcgi jq; do
    command -v "$required" >/dev/null 2>&1 || { printf '%s is missing.\n' "$required" >&2; exit 1; }
done

export WP_SHELL_CONFIG_DIR=/tmp/wp-shell-test
export WP_SHELL_STATE_DIR=/tmp/wp-shell-state-test
source "$repo_root/wp-shell.sh"
install -d -m 0700 "$CONFIG_DIR" "$DATABASE_CONFIG_DIR"
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

systemctl() { printf '%s\n' "$*" >> "$CONFIG_DIR/systemctl-calls"; }
configure_mariadb
mariadbd --defaults-file=/etc/mysql/my.cnf --verbose --help >/dev/null

configure_redis
if timeout 2s redis-server /etc/redis/wp-shell.conf --port 16379 --supervised no --daemonize no --logfile '' >/dev/null 2>&1; then
    redis_exit=0
else
    redis_exit=$?
fi
[[ "$redis_exit" -eq 124 ]]

install -d -m 0750 "$LOG_DIR"
old_redis_secret="$(<"$REDIS_SECRET_FILE")"
redis_log="$LOG_DIR/wp-shell-rotation-test.log"
printf 'Accidental credential output: %s\n' "$old_redis_secret" > "$redis_log"
install -d -o www-data -g www-data -m 0755 "${SITE_PATHS[1]}"
wp_config="${SITE_PATHS[1]}/wp-config.php"
printf "<?php\ndefine( 'DB_NAME', 'wp_test' );\ndefine( 'WP_REDIS_PASSWORD', '%s' );\n" \
    "$old_redis_secret" > "$wp_config"
chown www-data:www-data "$wp_config"
chmod 0640 "$wp_config"
site_wp_cli() {
    local _domain="$1"
    shift
    case "$*" in
        'config get DB_NAME') printf 'wp_test\n' ;;
        'config set WP_REDIS_PASSWORD __WP_SHELL_REDIS_SECRET_PLACEHOLDER__ --quiet')
            printf "<?php\ndefine( 'DB_NAME', 'wp_test' );\ndefine( 'WP_REDIS_PASSWORD', '__WP_SHELL_REDIS_SECRET_PLACEHOLDER__' );\n" > "$wp_config"
            ;;
        'cache flush') return 0 ;;
        *) return 1 ;;
    esac
}
redis-server /etc/redis/wp-shell.conf --supervised no --daemonize yes \
    --pidfile /tmp/wp-shell-test-redis.pid --logfile /tmp/wp-shell-test-redis.log
for ((attempt = 0; attempt < 50; attempt++)); do
    if [[ "$(REDISCLI_AUTH="$old_redis_secret" redis-cli --no-auth-warning ping 2>/dev/null || true)" == PONG ]]; then break; fi
    sleep 0.1
done
[[ "$(REDISCLI_AUTH="$old_redis_secret" redis-cli --no-auth-warning ping)" == "PONG" ]]
rotate_redis_secret
new_redis_secret="$(<"$REDIS_SECRET_FILE")"
[[ "$new_redis_secret" != "$old_redis_secret" ]]
[[ "$(REDISCLI_AUTH="$new_redis_secret" redis-cli --no-auth-warning ping)" == "PONG" ]]
wp_config_content="$(<"$wp_config")"
[[ "$wp_config_content" == *"$new_redis_secret"* ]]
[[ "$wp_config_content" != *"$old_redis_secret"* ]]
[[ "$wp_config_content" != *'__WP_SHELL_REDIS_SECRET_PLACEHOLDER__'* ]]
[[ "$(<"$redis_log")" == 'Accidental credential output: [REDACTED]' ]]
[[ "$(stat -c '%a' "$redis_log")" == "600" ]]
REDISCLI_AUTH="$new_redis_secret" redis-cli --no-auth-warning shutdown nosave

local_opcache_ini=/etc/php/8.3/fpm/conf.d/99-zz-local-opcache.ini
printf 'opcache.memory_consumption = 256\nopcache.interned_strings_buffer = 32\n' > "$local_opcache_ini"
local_opcache_hash="$(sha256sum "$local_opcache_ini")"
configure_php
php-fpm8.3 -t
pool_file="/etc/php/8.3/fpm/pool.d/wp-shell-$(site_pool_id example.com).conf"
grep -Fq "listen = $(site_pool_socket example.com)" "$pool_file"
grep -q '^pm = ondemand$' "$pool_file"
[[ "$(opcache_effective_values 8.3)" == '256 32' ]]
load_opcache_config
[[ "${OPCACHE_MEMORY_OVERRIDES[8.3]} ${OPCACHE_STRINGS_OVERRIDES[8.3]}" == '256 32' ]]
[[ "$(tail -n 2 "$CONFIG_DIR/systemctl-calls")" == $'daemon-reload\nreload php8.3-fpm' ]]

memory_mb() { printf '3832'; }
available_memory_mb() { printf '2080'; }
pool_hash="$(sha256sum "$pool_file")"
set_opcache 8.3 384 48
[[ "$(opcache_effective_values 8.3)" == '384 48' ]]
[[ "$(sha256sum "$pool_file")" == "$pool_hash" ]]
[[ "$(sha256sum "$local_opcache_ini")" == "$local_opcache_hash" ]]
load_opcache_config
configure_php
[[ "$(opcache_effective_values 8.3)" == '384 48' ]]

# A real late INI override must reject the transaction and restore both files.
managed_hash="$(sha256sum "$(opcache_managed_ini 8.3)")"
state_hash="$(sha256sum "$OPCACHE_CONFIG_FILE")"
printf 'opcache.memory_consumption = 128\n' > /etc/php/8.3/fpm/conf.d/zzz-test-override.ini
if (set_opcache 8.3 256 32); then
    printf 'Late INI conflict was not rejected.\n' >&2
    exit 1
fi
[[ "$(sha256sum "$(opcache_managed_ini 8.3)")" == "$managed_hash" ]]
[[ "$(sha256sum "$OPCACHE_CONFIG_FILE")" == "$state_hash" ]]
rm /etc/php/8.3/fpm/conf.d/zzz-test-override.ini

# Exercise the private runtime probe through a real FPM Unix socket.
install -d -m 0755 /run/php
php-fpm8.3 -F --pid "$CONFIG_DIR/fpm.pid" > "$CONFIG_DIR/fpm-test.log" 2>&1 &
fpm_test_pid=$!
trap 'kill "$fpm_test_pid" 2>/dev/null || true; wait "$fpm_test_pid" 2>/dev/null || true' EXIT
for ((attempt = 0; attempt < 50; attempt++)); do
    [[ -S "$(site_pool_socket example.com)" ]] && break
    sleep 0.1
done
runtime="$(opcache_runtime_json 8.3)"
jq -e '.available and .enabled and (.memory_mb == 384) and (.strings_mb == 48) and (.full == false)' <<< "$runtime" >/dev/null
output="$(show_opcache_status 8.3)"
grep -q 'Runtime (memory/strings MB): 384 48' <<< "$output"
# Match the distribution FPM unit's graceful-reload signal without requiring systemd in Docker.
systemctl() {
    printf '%s\n' "$*" >> "$CONFIG_DIR/systemctl-calls"
    if [[ "$*" == 'reload php8.3-fpm' ]]; then kill -USR2 "$fpm_test_pid"; fi
}
set_opcache 8.3 256 32
runtime='{}'
for ((attempt = 0; attempt < 50; attempt++)); do
    runtime="$(opcache_runtime_json 8.3)" || runtime='{}'
    if jq -e '(.memory_mb == 256) and (.strings_mb == 32)' <<< "$runtime" >/dev/null; then break; fi
    sleep 0.1
done
jq -e '.available and .enabled and (.memory_mb == 256) and (.strings_mb == 32)' <<< "$runtime" >/dev/null
if find /run -maxdepth 1 -type d -name 'wp-shell-opcache.*' | grep -q .; then
    printf 'The runtime probe left a temporary directory behind.\n' >&2
    exit 1
fi
kill "$fpm_test_pid"
wait "$fpm_test_pid"
trap - EXIT

printf 'MariaDB, Redis, per-site PHP-FPM, OPcache adoption/rollback and live runtime validation passed.\n'
