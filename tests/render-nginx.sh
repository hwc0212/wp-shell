#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2016,SC2034

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

(
    source "$repo_root/wp-vps-manager.sh"
    SITE_COUNT=1
    SITE_DOMAINS[1]="example.com"
    SITE_PHP_VERSIONS[1]="8.3"
    SITE_WWW[1]="yes"
    SITE_PATHS[1]="/var/www/example.com/public"

    install() {
        if [[ "${1:-}" == "-d" ]]; then
            mkdir -p "$test_root/cache-placeholder"
            return
        fi
        command install "$@"
    }
    install_nginx_files() {
        cp "$2" "$test_root/multi-site.conf"
        cp "$3" "$test_root/multi-cache.conf"
    }

    configure_https_site 1
    grep -q 'keys_zone=wp_example_com:16m' "$test_root/multi-cache.conf"
    grep -q 'fastcgi_cache wp_example_com;' "$test_root/multi-site.conf"
    grep -q 'fastcgi_pass unix:/run/php/php8.3-fpm.sock;' "$test_root/multi-site.conf"
    grep -q 'root /var/www/example.com/public;' "$test_root/multi-site.conf"
    [[ "$(grep -c 'add_header Strict-Transport-Security' "$test_root/multi-site.conf")" -eq 3 ]]
    ! grep -Eq 'php-status|php-ping' "$test_root/multi-site.conf"
)

(
    source "$repo_root/deploy-single-wordpress.sh"
    DOMAIN="single.example.com"
    PRIMARY_DOMAIN="www.single.example.com"
    INCLUDE_WWW="yes"
    PHP_VERSION="8.4"

    install() {
        if [[ "${1:-}" == "-d" ]]; then
            mkdir -p "$test_root/cache-placeholder"
            return
        fi
        command install "$@"
    }
    install_nginx_files() {
        cp "$1" "$test_root/single-site.conf"
        cp "$2" "$test_root/single-cache.conf"
    }

    configure_https_site
    grep -q 'keys_zone=wp_single_example_com:16m' "$test_root/single-cache.conf"
    grep -q 'fastcgi_cache wp_single_example_com;' "$test_root/single-site.conf"
    grep -q 'fastcgi_pass unix:/run/php/php8.4-fpm.sock;' "$test_root/single-site.conf"
    grep -q 'return 301 https://www.single.example.com$request_uri;' "$test_root/single-site.conf"
    [[ "$(grep -c 'add_header Strict-Transport-Security' "$test_root/single-site.conf")" -eq 3 ]]
    ! grep -Eq 'php-status|php-ping' "$test_root/single-site.conf"
)

printf 'Nginx 模板渲染测试通过。\n'
