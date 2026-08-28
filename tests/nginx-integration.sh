#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2016,SC2034,SC2317,SC2329

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
grep -Fq 'location ^~ /wp-admin/includes/' /etc/nginx/sites-available/example.com
grep -Fq 'location ~* ^/wp-includes/[^/]+\.php$' /etc/nginx/sites-available/example.com
grep -Fq 'fastcgi_cache wp_example_com;' /etc/nginx/sites-available/example.com
grep -Fq 'fastcgi_cache wp_single_example_com;' /etc/nginx/sites-available/single.example.com
[[ "$(site_pool_socket example.com)" != "$(site_pool_socket single.example.com)" ]]

# Exercise actual requests, not only nginx -t / template text matching.
cat > /etc/php/8.3/fpm/pool.d/wp-shell-test.conf <<EOF
[wp_shell_test]
user = www-data
group = www-data
listen = $(site_pool_socket example.com)
listen.owner = www-data
listen.group = www-data
pm = ondemand
pm.max_children = 2
EOF
cat > /var/www/example.com/public/index.php <<'PHP'
<?php
if ($_SERVER['REQUEST_URI'] === '/private/') { header('Cache-Control: private, no-store'); }
if ($_SERVER['REQUEST_URI'] === '/cookie/') { setcookie('private_test', 'yes'); }
header('Content-Type: text/html');
echo microtime(true), str_repeat(' cache test body ', 1024);
PHP
chmod 0644 /var/www/example.com/public/index.php
install -d -m 0755 /var/www/example.com/public/staging/wp-admin /var/www/example.com/public/wp-content/wpvividbackups
cp /var/www/example.com/public/index.php /var/www/example.com/public/staging/wp-admin/index.php
cp /var/www/example.com/public/index.php /var/www/example.com/public/wp-login.php
printf 'private backup\n' > /var/www/example.com/public/wp-content/wpvividbackups/test.zip
printf 'body { color: blue; }\n' > /var/www/example.com/public/style.css
chmod -R a+rX /var/www/example.com/public
php-fpm8.3 -D
nginx
trap 'nginx -s quit >/dev/null 2>&1 || true; if [[ -f /run/php/php8.3-fpm.pid ]]; then kill "$(< /run/php/php8.3-fpm.pid)" 2>/dev/null || true; fi' EXIT
request_headers() {
    local path="$1"
    shift
    curl --noproxy '*' -ksS --resolve example.com:443:127.0.0.1 --max-time 10 -D - -o /dev/null "$@" "https://example.com$path" | tr -d '\r'
}
request_headers / | grep -qi 'x-fastcgi-cache: MISS'
request_headers / | grep -qi 'x-fastcgi-cache: HIT'
request_headers / -H 'Authorization: Bearer fixture' | grep -qi 'x-fastcgi-cache: BYPASS'
request_headers / -H 'Cookie: wordpress_logged_in_fixture=1' | grep -qi 'x-fastcgi-cache: BYPASS'
headers="$(request_headers / -X POST)"
grep -q '200' <<< "$headers"
if grep -qi 'x-fastcgi-cache: HIT' <<< "$headers"; then exit 1; fi
request_headers /wp-json/fixture | grep -qi 'x-fastcgi-cache: BYPASS'
request_headers /staging/wp-admin/index.php | grep -qi 'x-fastcgi-cache: BYPASS'
request_headers / -H 'Accept-Encoding: gzip' | grep -qi 'content-encoding: gzip'
for uncached in /private/ /cookie/; do
    request_headers "$uncached" >/dev/null
    if request_headers "$uncached" | grep -qi 'x-fastcgi-cache: HIT'; then exit 1; fi
done
request_headers /wp-content/wpvividbackups/test.zip | grep -q '403'
headers="$(request_headers /style.css)"
grep -qi 'max-age=2592000' <<< "$headers"
if grep -qi immutable <<< "$headers"; then exit 1; fi
printf '# operator customization\n' > /etc/nginx/wp-shell-custom/example.com/90-local.conf
configure_https_site 1
grep -q 'operator customization' /etc/nginx/wp-shell-custom/example.com/90-local.conf
touch /var/www/example.com/.wp-shell-maintenance
request_headers / | grep -q '503'
rm -f /var/www/example.com/.wp-shell-maintenance
site_login_limit example.com direct
nginx -s reload
sleep 0.2
limited=no
for ((attempt=0; attempt<16; attempt++)); do
    if request_headers /wp-login.php -X POST | grep -q '429'; then limited=yes; break; fi
done
[[ "$limited" == yes ]]
printf 'Real Nginx cache HIT/BYPASS, privacy headers, gzip, static TTL and maintenance tests passed.\n'
