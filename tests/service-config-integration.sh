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
export WP_SHELL_TEST_ROOT_WRITES=yes
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
set_site_policy example.com object-cache enabled
SITE_ADMIN_USERS[1]="wpadmin"
SITE_ADMIN_EMAILS[1]="admin@example.com"
SITE_TITLES[1]="Example"
SITE_PATHS[1]="/var/www/example.com/public"

systemctl() { printf '%s\n' "$*" >> "$CONFIG_DIR/systemctl-calls"; }
mariadb_health_check() { return 0; }
mariadb_runtime_snapshot() {
    mariadb_config_effective_snapshot
    cat <<'EOF'
max_used_connections|0
threads_connected|0
threads_running|0
created_tmp_tables|0
created_tmp_disk_tables|0
EOF
}
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

# Model an upgrade from v10.0.3. The old managed 99-wp-shell.conf sorts
# before the distribution www.conf on Ubuntu, so its apparent max_children=2
# is not necessarily the effective merged value. Prove the real precedence
# through php-fpm -tt, then prove migration rollback when an administrator's
# later override prevents the new target from becoming effective.
legacy_default_pool_file="$(php_legacy_default_pool_override_file 8.3)"
default_pool_file="$(php_default_pool_override_file 8.3)"
cat > "$legacy_default_pool_file" <<'EOF'
; Managed by wp-shell. Keep the distribution pool available with minimal idle use.
[www]
pm = ondemand
pm.max_children = 2
pm.process_idle_timeout = 20s
pm.max_requests = 300
EOF
legacy_default_hash="$(sha256sum "$legacy_default_pool_file")"
legacy_effective_default="$(read_effective_pool_settings 8.3 www)"
printf 'Ubuntu effective [www] with legacy 99-wp-shell.conf: %s\n' "$legacy_effective_default"
[[ "$legacy_effective_default" =~ ^(ondemand|dynamic|static)\|[1-9][0-9]*$ ]]
[[ "$legacy_effective_default" != 'ondemand|2' ]]

PHP_CHILD_OVERRIDES[example.com]=4
late_default_override=/etc/php/8.3/fpm/pool.d/zzz-test-default.conf
cat > "$late_default_override" <<'EOF'
[www]
pm = ondemand
pm.max_children = 3
EOF
systemctl_calls_before="$(wc -l < "$CONFIG_DIR/systemctl-calls")"
if (TRANSACTION_CONTEXT=yes; configure_php) > "$CONFIG_DIR/default-pool-conflict.log" 2>&1; then
    printf 'A later administrator default-pool override was not rejected.\n' >&2
    exit 1
fi
grep -Fq 'effective [www] pool is not pm=ondemand with pm.max_children=1' "$CONFIG_DIR/default-pool-conflict.log"
[[ "$(sha256sum "$legacy_default_pool_file")" == "$legacy_default_hash" ]]
[[ ! -e "$default_pool_file" ]]
[[ "$(wc -l < "$CONFIG_DIR/systemctl-calls")" == "$systemctl_calls_before" ]]
rm -f "$late_default_override"

# A later administrator fragment can also override an individual site pool
# while remaining syntactically valid. configure_php must detect the merged
# semantic mismatch, restore every managed candidate, and leave the
# administrator file untouched without reloading PHP.
managed_site_pool_file="/etc/php/8.3/fpm/pool.d/wp-shell-$(site_pool_id example.com).conf"
late_site_override=/etc/php/8.3/fpm/pool.d/zzz-test-site.conf
cat > "$late_site_override" <<EOF
[$(site_pool_id example.com)]
pm.max_children = 8
EOF
late_site_override_hash="$(sha256sum "$late_site_override")"
systemctl_calls_before="$(wc -l < "$CONFIG_DIR/systemctl-calls")"
if (TRANSACTION_CONTEXT=yes; configure_php) > "$CONFIG_DIR/site-pool-conflict.log" 2>&1; then
    printf 'A later administrator site-pool override was not rejected.\n' >&2
    exit 1
fi
grep -Fq 'effective pool for example.com does not have pm.max_children=4' "$CONFIG_DIR/site-pool-conflict.log"
[[ "$(sha256sum "$legacy_default_pool_file")" == "$legacy_default_hash" ]]
[[ ! -e "$default_pool_file" && ! -e "$managed_site_pool_file" ]]
[[ "$(sha256sum "$late_site_override")" == "$late_site_override_hash" ]]
[[ "$(wc -l < "$CONFIG_DIR/systemctl-calls")" == "$systemctl_calls_before" ]]
rm -f "$late_site_override"

configure_php
php-fpm8.3 -t
pool_file="/etc/php/8.3/fpm/pool.d/wp-shell-$(site_pool_id example.com).conf"
[[ ! -e "$legacy_default_pool_file" ]]
php_default_pool_file_is_managed "$default_pool_file"
[[ "$(read_effective_pool_settings 8.3 www)" == 'ondemand|1' ]]
[[ "$(read_effective_site_pool_limit example.com 8.3)" == 4 ]]
php_refresh_current_aggregate_workers
[[ "$PHP_CURRENT_AGGREGATE_WORKERS" == 5 ]]
grep -Fq "listen = $(site_pool_socket example.com)" "$pool_file"
grep -q '^pm = ondemand$' "$pool_file"
[[ "$(opcache_effective_values 8.3)" == '256 32' ]]
load_opcache_config
[[ "${OPCACHE_MEMORY_OVERRIDES[8.3]} ${OPCACHE_STRINGS_OVERRIDES[8.3]}" == '256 32' ]]
[[ "$(tail -n 2 "$CONFIG_DIR/systemctl-calls")" == $'daemon-reload\nreload php8.3-fpm' ]]

memory_mb() { printf '3832'; }
available_memory_mb() { printf '2080'; }

# A later site fragment that currently agrees with the managed value passes
# the pre-tuning ownership check, but prevents a proposed increase from
# becoming effective. The semantic check must restore the pool and tuning
# state without reloading the unverified candidate. Removing the override
# then exercises the normal successful tuning path.
init_metrics_database
metrics_now="$(date +%s)"
sqlite3 "$METRICS_DB" <<SQL
WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM n WHERE i<1000)
INSERT INTO system_samples(ts,cpu_pct,load1,mem_total_mb,mem_available_mb,swap_used_mb,disk_pct,rx_bytes,tx_bytes)
SELECT $metrics_now-(1000-i)*90,10,1,3832,2000,0,20,0,0 FROM n;
INSERT INTO site_samples(ts,domain,php_active,php_idle,php_queue,php_max_children,php_pss_mb)
SELECT ts,'example.com',4,0,1,4,300 FROM system_samples;
INSERT INTO sample_health SELECT ts,'','system',1 FROM system_samples;
INSERT INTO sample_health SELECT ts,domain,'php',1 FROM site_samples;
SQL
cat > "$late_site_override" <<EOF
[$(site_pool_id example.com)]
pm.max_children = 4
EOF
late_site_override_hash="$(sha256sum "$late_site_override")"
pool_hash="$(sha256sum "$pool_file")"
reload_calls_before="$(awk '$1 == "reload" {count++} END {print count+0}' "$CONFIG_DIR/systemctl-calls")"
if (apply_tuning --yes --range 7d) > "$CONFIG_DIR/tuning-override.log" 2>&1; then
    printf 'Tuning succeeded even though its proposed pool value was overridden.\n' >&2
    tail -80 "$CONFIG_DIR/tuning-override.log" >&2
    exit 1
fi
grep -Fq 'not the proposed 5' "$CONFIG_DIR/tuning-override.log"
if grep -Fq '[SUCCESS] PHP-FPM tuning overrides' "$CONFIG_DIR/tuning-override.log"; then
    printf 'Tuning reported success after the semantic override rollback.\n' >&2
    exit 1
fi
grep -Fq 'previous pool files and tuning policy restored' "$CONFIG_DIR/tuning-override.log"
[[ "$(sha256sum "$pool_file")" == "$pool_hash" ]]
[[ ! -e "$TUNING_CONFIG_FILE" ]]
[[ "$(sha256sum "$late_site_override")" == "$late_site_override_hash" ]]
[[ "$(awk '$1 == "reload" {count++} END {print count+0}' "$CONFIG_DIR/systemctl-calls")" == "$reload_calls_before" ]]
rm -f "$late_site_override"
apply_tuning --yes --range 7d
[[ "$(read_effective_site_pool_limit example.com 8.3)" == 5 ]]
grep -Fxq 'php|example.com|5' "$TUNING_CONFIG_FILE"
load_tuning_config

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
