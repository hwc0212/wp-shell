#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2034,SC2317,SC2329

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $EUID -eq 0 ]] || { printf 'This test must run as root in an isolated container.\n' >&2; exit 1; }
for required in mariadbd redis-server php-fpm8.3 openssl; do
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

systemctl() { return 0; }
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
redis-server /etc/redis/wp-shell.conf --supervised no --daemonize yes \
    --pidfile /tmp/wp-shell-test-redis.pid --logfile /tmp/wp-shell-test-redis.log
[[ "$(REDISCLI_AUTH="$old_redis_secret" redis-cli --no-auth-warning ping)" == "PONG" ]]
rotate_redis_secret
new_redis_secret="$(<"$REDIS_SECRET_FILE")"
[[ "$new_redis_secret" != "$old_redis_secret" ]]
[[ "$(REDISCLI_AUTH="$new_redis_secret" redis-cli --no-auth-warning ping)" == "PONG" ]]
[[ "$(<"$redis_log")" == 'Accidental credential output: [REDACTED]' ]]
[[ "$(stat -c '%a' "$redis_log")" == "600" ]]
REDISCLI_AUTH="$new_redis_secret" redis-cli --no-auth-warning shutdown nosave

configure_php
php-fpm8.3 -t
pool_file="/etc/php/8.3/fpm/pool.d/wp-shell-$(site_pool_id example.com).conf"
grep -Fq "listen = $(site_pool_socket example.com)" "$pool_file"
grep -q '^pm = ondemand$' "$pool_file"

printf 'MariaDB, Redis, and per-site PHP-FPM configuration validation passed.\n'
