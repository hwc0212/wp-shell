#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2034,SC2317,SC2329

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $EUID -eq 0 ]] || { printf 'This test must run as root in an isolated container.\n' >&2; exit 1; }
command -v nginx >/dev/null 2>&1 || { printf 'nginx is missing.\n' >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { printf 'openssl is missing.\n' >&2; exit 1; }

rm -f /etc/nginx/sites-enabled/default
install -d -m 0755 /var/www/example.com/public /var/www/example.com/logs
install -d -m 0755 /var/www/single.example.com/public /var/www/single.example.com/logs

make_certificate() {
    local domain="$1" cert_dir="/etc/letsencrypt/live/$1"
    install -d -m 0755 "$cert_dir"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -subj "/CN=$domain" -keyout "$cert_dir/privkey.pem" \
        -out "$cert_dir/fullchain.pem" >/dev/null 2>&1
}

make_certificate example.com
make_certificate single.example.com

source "$repo_root/wp-shell.sh"
systemctl() { return 0; }
SITE_COUNT=2
SITE_DOMAINS[1]="example.com"
SITE_PRIMARY_DOMAINS[1]="example.com"
SITE_PHP_VERSIONS[1]="8.3"
SITE_WOOCOMMERCE[1]="no"
SITE_WWW[1]="yes"
SITE_PATHS[1]="/var/www/example.com/public"
SITE_MODES[1]="managed"
SITE_DOMAINS[2]="single.example.com"
SITE_PRIMARY_DOMAINS[2]="www.single.example.com"
SITE_PHP_VERSIONS[2]="8.3"
SITE_WOOCOMMERCE[2]="no"
SITE_WWW[2]="yes"
SITE_PATHS[2]="/var/www/single.example.com/public"
SITE_MODES[2]="managed"
configure_https_site 1
configure_https_site 2

nginx -t
grep -Fq 'fastcgi_hide_header Strict-Transport-Security;' /etc/nginx/sites-available/example.com
grep -Fq 'fastcgi_cache wp_example_com;' /etc/nginx/sites-available/example.com
grep -Fq 'fastcgi_cache wp_single_example_com;' /etc/nginx/sites-available/single.example.com
[[ "$(site_pool_socket example.com)" != "$(site_pool_socket single.example.com)" ]]
printf 'Real Nginx configuration validation passed.\n'
