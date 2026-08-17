#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2034,SC2317,SC2329

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $EUID -eq 0 ]] || { printf '此测试必须在隔离容器内以 root 运行。\n' >&2; exit 1; }
command -v nginx >/dev/null 2>&1 || { printf '缺少 nginx。\n' >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { printf '缺少 openssl。\n' >&2; exit 1; }

rm -f /etc/nginx/sites-enabled/default
install -d -m 0755 /var/www/example.com/public /var/www/example.com/logs
install -d -m 0755 /var/www/single.example.com/public /var/www/single.example.com/logs

make_certificate() {
    local domain="$1" cert_dir="/etc/letsencrypt/live/$1"
    install -d -m 0755 "$cert_dir"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -subj "/CN=$domain" \
        -keyout "$cert_dir/privkey.pem" \
        -out "$cert_dir/fullchain.pem" >/dev/null 2>&1
}

make_certificate example.com
make_certificate single.example.com

(
    source "$repo_root/wp-vps-manager.sh"
    systemctl() { return 0; }
    SITE_COUNT=1
    SITE_DOMAINS[1]="example.com"
    SITE_PHP_VERSIONS[1]="8.3"
    SITE_WWW[1]="yes"
    SITE_PATHS[1]="/var/www/example.com/public"
    configure_https_site 1
)

(
    source "$repo_root/deploy-single-wordpress.sh"
    systemctl() { return 0; }
    DOMAIN="single.example.com"
    PRIMARY_DOMAIN="www.single.example.com"
    INCLUDE_WWW="yes"
    PHP_VERSION="8.4"
    configure_https_site
)

nginx -t
printf '真实 Nginx 配置验证通过。\n'
