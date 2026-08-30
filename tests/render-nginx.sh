#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2016,SC2034,SC2317,SC2329

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export WP_SHELL_CONFIG_DIR="$test_root/config"
export WP_SHELL_STATE_DIR="$test_root/state"
mkdir -p "$WP_SHELL_CONFIG_DIR" "$WP_SHELL_STATE_DIR"

source "$repo_root/wp-shell.sh"
SITE_COUNT=1
SITE_DOMAINS[1]="example.com"
SITE_PRIMARY_DOMAINS[1]="www.example.com"
SITE_PHP_VERSIONS[1]="8.3"
SITE_WOOCOMMERCE[1]="no"
SITE_WWW[1]="yes"
SITE_PATHS[1]="/var/www/example.com/public"
SITE_MODES[1]="managed"

install() {
    if [[ "${1:-}" == "-d" ]]; then
        return
    fi
    command install "$@"
}
install_nginx_log_format() { :; }
install_nginx_files() {
    cp "$2" "$test_root/site.conf"
    if [[ -n "${3:-}" ]]; then cp "$3" "$test_root/cache.conf"; else rm -f "$test_root/cache.conf"; fi
}

mkdir -p "$SITE_POLICY_DIR/example.com"
printf 'enabled\n' > "$SITE_POLICY_DIR/example.com/page-cache"
printf 'disabled\n' > "$SITE_POLICY_DIR/example.com/xmlrpc"
printf 'strict\n' > "$SITE_POLICY_DIR/example.com/header-profile"
configure_https_site 1
pool_socket="$(site_pool_socket example.com)"
grep -q 'fastcgi_cache_path /var/www/example.com/cache ' "$test_root/cache.conf"
grep -q 'keys_zone=wp_example_com:16m' "$test_root/cache.conf"
grep -q 'fastcgi_cache wp_example_com;' "$test_root/site.conf"
grep -q 'fastcgi_hide_header Strict-Transport-Security;' "$test_root/site.conf"
grep -Fq 'location ^~ /wp-admin/includes/' "$test_root/site.conf"
grep -Fq 'location ~* ^/wp-includes/[^/]+\.php$' "$test_root/site.conf"
grep -Fq 'wp-config(?:-sample)?\.php' "$test_root/site.conf"
grep -Fq 'log|sql|ini|conf|bak|old|orig|save|swp' "$test_root/site.conf"
grep -Fq "fastcgi_pass unix:$pool_socket;" "$test_root/site.conf"
grep -Fq 'return 301 https://www.example.com$request_uri;' "$test_root/site.conf"
grep -q 'access_log /var/www/example.com/logs/nginx-access.log wp_shell;' "$test_root/site.conf"
[[ "$(grep -c 'add_header Strict-Transport-Security' "$test_root/site.conf" || true)" -eq 0 ]]
grep -Fq 'add_header Permissions-Policy' "$test_root/site.conf"
grep -Fq 'try_files $uri =404;' "$test_root/site.conf"
grep -Fq 'location = /xmlrpc.php' "$test_root/site.conf"
grep -Fq 'uploads|cache|files' "$test_root/site.conf"
grep -Fq 'phtml|phar|cgi|pl|py|sh' "$test_root/site.conf"
grep -Fq 'upgrade-temp-backup' "$test_root/site.conf"
grep -Fq 'woff2?|ttf|eot' "$test_root/site.conf"
grep -Fq 'request-a-quote' "$test_root/site.conf"
if grep -Eq 'php-status|php-ping|/var/cache/nginx' "$test_root/site.conf" "$test_root/cache.conf"; then
    printf 'An unsafe or legacy Nginx path was rendered.\n' >&2
    exit 1
fi

# Compatibility-sensitive behavior is opt-in for a new/missing-policy site.
printf 'disabled\n' > "$SITE_POLICY_DIR/example.com/page-cache"
printf 'enabled\n' > "$SITE_POLICY_DIR/example.com/xmlrpc"
printf 'compatible\n' > "$SITE_POLICY_DIR/example.com/header-profile"
configure_https_site 1
[[ ! -e "$test_root/cache.conf" ]]
if grep -Eq 'fastcgi_cache |location = /xmlrpc[.]php|X-Frame-Options|Permissions-Policy' "$test_root/site.conf"; then
    printf 'A compatibility-sensitive Nginx feature was rendered without opt-in.\n' >&2
    exit 1
fi
grep -Fq 'add_header X-Content-Type-Options "nosniff" always;' "$test_root/site.conf"
grep -Fq 'expires 7d;' "$test_root/site.conf"

printf 'Nginx template rendering tests passed.\n'
