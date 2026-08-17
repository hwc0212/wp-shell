#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2034,SC2317,SC2329

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $EUID -eq 0 ]] || { printf '此测试必须在隔离容器内以 root 运行。\n' >&2; exit 1; }
for command in mariadbd redis-server php-fpm8.3 openssl; do
    command -v "$command" >/dev/null 2>&1 || { printf '缺少 %s。\n' "$command" >&2; exit 1; }
done

mode="${1:-all}"
if [[ "$mode" == "all" ]]; then
    bash "$0" multi
    bash "$0" single
    printf '多站点与单站点服务配置验证通过。\n'
    exit 0
fi

case "$mode" in
    multi)
        export WP_VPS_CONFIG_DIR=/tmp/wp-vps-manager-test
        source "$repo_root/wp-vps-manager.sh"
        install -d -m 0700 "$CONFIG_DIR" "$DATABASE_CONFIG_DIR"
        SITE_COUNT=1
        SITE_DOMAINS[1]="example.com"
        SITE_PHP_VERSIONS[1]="8.3"
        SITE_WOOCOMMERCE[1]="no"
        SITE_WWW[1]="no"
        SITE_REDIS_DATABASES[1]="0"
        SITE_ADMIN_USERS[1]="wpadmin"
        SITE_ADMIN_EMAILS[1]="admin@example.com"
        SITE_TITLES[1]="Example"
        SITE_PATHS[1]="/var/www/example.com/public"
        redis_config=/etc/redis/wp-shell.conf
        ;;
    single)
        export WP_SINGLE_CONFIG_DIR=/tmp/wp-single-test
        source "$repo_root/deploy-single-wordpress.sh"
        install -d -m 0700 "$CONFIG_DIR"
        DOMAIN="single.example.com"
        PRIMARY_DOMAIN="$DOMAIN"
        INCLUDE_WWW="no"
        PHP_VERSION="8.3"
        USE_WOOCOMMERCE="no"
        SITE_TITLE="Example"
        ADMIN_EMAIL="admin@example.com"
        ADMIN_USER="wpadmin"
        redis_config=/etc/redis/wp-single.conf
        ;;
    *)
        printf '未知测试模式：%s\n' "$mode" >&2
        exit 1
        ;;
esac

systemctl() { return 0; }

configure_mariadb
mariadbd --defaults-file=/etc/mysql/my.cnf --verbose --help >/dev/null

configure_redis
if timeout 2s redis-server "$redis_config" --port 16379 --supervised no --daemonize no --logfile '' >/dev/null 2>&1; then
    redis_exit=0
else
    redis_exit=$?
fi
[[ "$redis_exit" -eq 124 ]]

configure_php
php-fpm8.3 -t

printf '%s 的 MariaDB、Redis 和 PHP-FPM 配置验证通过。\n' "$mode"
