#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2016,SC2034

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

(
    export WP_VPS_CONFIG_DIR="$test_root/multi"
    # shellcheck source=../wp-vps-manager.sh
    source "$repo_root/wp-vps-manager.sh"
    install -d -m 0700 "$CONFIG_DIR" "$DATABASE_CONFIG_DIR"

    dangerous_title='"; touch /tmp/wp-shell-must-not-execute; #'
    SITE_COUNT=1
    SITE_DOMAINS[1]="example.com"
    SITE_PHP_VERSIONS[1]="8.3"
    SITE_WOOCOMMERCE[1]="no"
    SITE_WWW[1]="yes"
    SITE_REDIS_DATABASES[1]="0"
    SITE_ADMIN_USERS[1]="wpadmin"
    SITE_ADMIN_EMAILS[1]="admin@example.com"
    SITE_TITLES[1]="$dangerous_title"
    SITE_PATHS[1]="/var/www/example.com/public"
    save_sites_config

    reset_sites
    load_sites_config
    [[ "$SITE_COUNT" -eq 1 ]]
    [[ "${SITE_DOMAINS[1]}" == "example.com" ]]
    [[ "${SITE_TITLES[1]}" == "$dangerous_title" ]]
    [[ "${SITE_PATHS[1]}" == "/var/www/example.com/public" ]]
    [[ ! -e /tmp/wp-shell-must-not-execute ]]
)

(
    export WP_SINGLE_CONFIG_DIR="$test_root/single"
    # shellcheck source=../deploy-single-wordpress.sh
    source "$repo_root/deploy-single-wordpress.sh"
    install -d -m 0700 "$CONFIG_DIR"

    dangerous_title='$(touch /tmp/wp-single-must-not-execute)'
    DOMAIN="single.example.com"
    PRIMARY_DOMAIN="single.example.com"
    INCLUDE_WWW="no"
    PHP_VERSION="8.4"
    USE_WOOCOMMERCE="no"
    SITE_TITLE="$dangerous_title"
    ADMIN_EMAIL="admin@example.com"
    ADMIN_USER="wpadmin"
    save_site_config

    DOMAIN=""
    SITE_TITLE=""
    load_site_config
    [[ "$DOMAIN" == "single.example.com" ]]
    [[ "$SITE_TITLE" == "$dangerous_title" ]]
    [[ ! -e /tmp/wp-single-must-not-execute ]]
)

printf '配置往返与非执行性测试通过。\n'
