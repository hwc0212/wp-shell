#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2016,SC2034,SC2317,SC2329

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d /tmp/wp-shell-nginx-test.XXXXXX)"
export WP_SHELL_CONFIG_DIR="$test_root/config"
export WP_SHELL_STATE_DIR="$test_root/state"
export WP_SHELL_TEST_ROOT_WRITES=yes
install -d -m 0700 "$WP_SHELL_CONFIG_DIR" "$WP_SHELL_STATE_DIR"
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
set_site_policy example.com page-cache enabled
set_site_policy example.com xmlrpc disabled
set_site_policy example.com header-profile strict
set_site_policy single.example.com page-cache disabled
set_site_policy single.example.com xmlrpc enabled
set_site_policy single.example.com header-profile compatible
configure_https_site 1
configure_https_site 2
curl() {
    if [[ "$*" == *"$CLOUDFLARE_IPV4_URL"* ]]; then
        printf '173.245.48.0/20\n'
    elif [[ "$*" == *"$CLOUDFLARE_IPV6_URL"* ]]; then
        printf '2400:cb00::/32\n'
    else
        return 22
    fi
}
cloudflare_update
unset -f curl
grep -Fq 'set_real_ip_from 173.245.48.0/20;' /etc/nginx/conf.d/wp-shell-cloudflare-realip.conf
[[ ! -e /etc/nginx/wp-shell-custom/example.com/30-login-limit.conf ]]
[[ ! -e /etc/nginx/wp-shell-custom/single.example.com/30-login-limit.conf ]]
cloudflare_hash="$(sha256sum /etc/nginx/conf.d/wp-shell-cloudflare-realip.conf)"
if (
    curl() { printf 'not-a-cidr\n'; }
    cloudflare_update
) >/dev/null 2>&1; then
    printf 'Invalid Cloudflare data unexpectedly replaced the trusted ranges.\n' >&2
    exit 1
fi
[[ "$(sha256sum /etc/nginx/conf.d/wp-shell-cloudflare-realip.conf)" == "$cloudflare_hash" ]]
staging_candidate="$(mktemp /tmp/wp-shell-staging-test.XXXXXX)"
render_staging_nginx /staging/ "$(site_pool_socket example.com)" "$staging_candidate"
install -D -o root -g root -m 0644 "$staging_candidate" /etc/nginx/wp-shell-custom/example.com/10-staging.conf
rm -f -- "$staging_candidate"

nginx -t
grep -Fq 'try_files $uri =404;' /etc/nginx/sites-available/example.com
grep -Fq 'add_header Permissions-Policy' /etc/nginx/sites-available/example.com
grep -Fq 'location ^~ /wp-admin/includes/' /etc/nginx/sites-available/example.com
grep -Fq 'location ~* ^/wp-includes/[^/]+\.php$' /etc/nginx/sites-available/example.com
grep -Fq 'fastcgi_cache wp_example_com;' /etc/nginx/sites-available/example.com
if grep -Fq 'fastcgi_cache ' /etc/nginx/sites-available/single.example.com || \
   [[ -e /etc/nginx/conf.d/wp-cache-single.example.com.conf ]]; then
    printf 'The compatibility-mode site unexpectedly enabled FastCGI page caching.\n' >&2
    exit 1
fi
grep -Fq 'location = /xmlrpc.php' /etc/nginx/sites-available/example.com
if grep -Eq 'location = /xmlrpc[.]php|X-Frame-Options|Permissions-Policy' /etc/nginx/sites-available/single.example.com; then
    printf 'The compatibility-mode site received an opt-in security policy.\n' >&2
    exit 1
fi
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
install -d -m 0755 /var/www/example.com/public/staging/wp-admin \
    /var/www/example.com/public/wp-content/wpvividbackups \
    /var/www/example.com/public/wp-content/uploads
cp /var/www/example.com/public/index.php /var/www/example.com/public/staging/wp-admin/index.php
cp /var/www/example.com/public/index.php /var/www/example.com/public/wp-login.php
printf 'private backup\n' > /var/www/example.com/public/wp-content/wpvividbackups/test.zip
printf '<?php echo "unsafe";\n' > /var/www/example.com/public/wp-content/uploads/unsafe.phtml
printf '<?php echo "missing protection";\n' > /var/www/example.com/public/debug.log
printf '<?php echo "secret";\n' > /var/www/example.com/public/wp-config.php
printf 'body { color: blue; }\n' > /var/www/example.com/public/style.css
chmod -R a+rX /var/www/example.com/public
php-fpm8.3 -D
nginx
trap 'nginx -s quit >/dev/null 2>&1 || true; if [[ -f /run/php/php8.3-fpm.pid ]]; then kill "$(< /run/php/php8.3-fpm.pid)" 2>/dev/null || true; fi; rm -rf -- "$test_root"' EXIT
request_headers() {
    local path="$1"
    shift
    curl --noproxy '*' -ksS --resolve example.com:443:127.0.0.1 --max-time 10 -D - -o /dev/null "$@" "https://example.com$path" | tr -d '\r'
}
request_headers / | grep -qi 'x-fastcgi-cache: MISS'
request_headers / | grep -qi 'x-fastcgi-cache: HIT'
request_headers / | grep -q '200'
request_headers /product/fixture/ | grep -qi 'x-fastcgi-cache: MISS'
request_headers /product/fixture/ | grep -qi 'x-fastcgi-cache: HIT'
request_headers /wp-login.php | grep -q '200'
request_headers / -H 'Authorization: Bearer fixture' | grep -qi 'x-fastcgi-cache: BYPASS'
request_headers / -H 'Cookie: wordpress_logged_in_fixture=1' | grep -qi 'x-fastcgi-cache: BYPASS'
headers="$(request_headers / -X POST)"
grep -q '200' <<< "$headers"
if grep -qi 'x-fastcgi-cache: HIT' <<< "$headers"; then exit 1; fi
request_headers /wp-json/fixture | grep -qi 'x-fastcgi-cache: BYPASS'
headers="$(request_headers /staging/wp-admin/index.php)"
grep -q '200' <<< "$headers"
grep -qi 'x-robots-tag: noindex, nofollow, noarchive' <<< "$headers"
if grep -qi 'x-fastcgi-cache: HIT' <<< "$headers"; then exit 1; fi
for dynamic_path in /cart/ /checkout/ /my-account/ /quote/ /feed/ /wp-sitemap.xml; do
    request_headers "$dynamic_path" >/dev/null
    if request_headers "$dynamic_path" | grep -qi 'x-fastcgi-cache: HIT'; then exit 1; fi
done
request_headers / -H 'Accept-Encoding: gzip' | grep -qi 'content-encoding: gzip'
for uncached in /private/ /cookie/; do
    request_headers "$uncached" >/dev/null
    if request_headers "$uncached" | grep -qi 'x-fastcgi-cache: HIT'; then exit 1; fi
done
request_headers /wp-content/wpvividbackups/test.zip | grep -q '403'
request_headers /wp-content/uploads/unsafe.phtml | grep -q '403'
request_headers /debug.log | grep -q '403'
request_headers /wp-config.php | grep -q '403'
request_headers /not-created.php | grep -q '404'
headers="$(request_headers /style.css)"
grep -qi 'max-age=604800' <<< "$headers"
if grep -qi immutable <<< "$headers"; then exit 1; fi
printf '# operator customization\n' > /etc/nginx/wp-shell-custom/example.com/90-local.conf
configure_https_site 1
grep -q 'operator customization' /etc/nginx/wp-shell-custom/example.com/90-local.conf
touch /var/www/example.com/.wp-shell-maintenance
restore_maintenance_configuration_ready example.com
restore_verify_maintenance_barrier example.com
request_headers / | grep -q '503'
rm -f /var/www/example.com/.wp-shell-maintenance
site_login_limit example.com direct
nginx -s reload
sleep 0.2
limited=no
for ((attempt=0; attempt<36; attempt++)); do
    if request_headers /wp-login.php -X POST | grep -q '429'; then limited=yes; break; fi
done
[[ "$limited" == yes ]]

# A forged Cloudflare header from an untrusted peer must not change client_ip.
request_headers /real-ip-untrusted/ -H 'CF-Connecting-IP: 203.0.113.25' >/dev/null
tail -n 1 /var/www/example.com/logs/nginx-access.log | grep -q '"client_ip":"127.0.0.1"'
cat > /etc/nginx/conf.d/wp-shell-cloudflare-realip.conf <<'EOF'
# Disposable integration fixture: loopback stands in for an official Cloudflare edge.
set_real_ip_from 127.0.0.1;
real_ip_header CF-Connecting-IP;
real_ip_recursive on;
EOF
nginx -t
nginx -s reload
sleep 0.2
request_headers /real-ip-trusted/ -H 'CF-Connecting-IP: 203.0.113.25' >/dev/null
tail -n 1 /var/www/example.com/logs/nginx-access.log | grep -q '"client_ip":"203.0.113.25"'
tail -n 1 /var/www/example.com/logs/nginx-access.log | grep -q '"edge_ip":"127.0.0.1"'
cloudflare_command disable --confirm
[[ ! -e /etc/nginx/conf.d/wp-shell-cloudflare-realip.conf ]]
[[ -e /etc/nginx/wp-shell-custom/example.com/30-login-limit.conf ]]
[[ "$(host_policy_value cloudflare enabled)" == disabled ]]
unknown_code="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' -H 'Host: forged.example' http://127.0.0.1/ 2>/dev/null || true)"
[[ "$unknown_code" == 000 || "$unknown_code" == 444 ]]
printf 'Real Nginx cache, dynamic bypass, staging noindex, hardening, real-IP trust and default Host tests passed.\n'
