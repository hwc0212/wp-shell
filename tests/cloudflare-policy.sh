#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2016,SC2034
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
export WP_SHELL_CONFIG_DIR="$test_root/config"
export WP_SHELL_STATE_DIR="$test_root/state"
source "$repo_root/wp-shell.sh"
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$CONFIG_DIR" "$STATE_DIR"

printf '173.245.48.0/20\n103.21.244.0/22\n' > "$test_root/ips-v4"
printf '2400:cb00::/32\n2606:4700::/32\n' > "$test_root/ips-v6"
render_cloudflare_realip "$test_root/ips-v4" "$test_root/ips-v6" "$test_root/realip.conf"
grep -Fxq 'set_real_ip_from 173.245.48.0/20;' "$test_root/realip.conf"
grep -Fxq 'set_real_ip_from 2400:cb00::/32;' "$test_root/realip.conf"
grep -Fxq 'real_ip_header CF-Connecting-IP;' "$test_root/realip.conf"
grep -Fxq 'real_ip_recursive on;' "$test_root/realip.conf"

printf '0.0.0.0/0\nnot-a-cidr\n' > "$test_root/bad-v4"
if validate_cloudflare_ranges "$test_root/bad-v4" 4 2>/dev/null; then
    printf 'Invalid Cloudflare data was accepted.\n' >&2
    exit 1
fi

render_staging_nginx /preview/ /run/php/wp_fixture.sock "$test_root/staging.conf"
grep -Fq 'X-Robots-Tag "noindex, nofollow, noarchive"' "$test_root/staging.conf"
grep -Fq 'fastcgi_no_cache 1;' "$test_root/staging.conf"
grep -Fq 'try_files $uri =404;' "$test_root/staging.conf"
grep -Fq 'uploads|cache' "$test_root/staging.conf"
if render_staging_nginx /../ /run/php/wp_fixture.sock "$test_root/invalid.conf"; then
    printf 'A traversal-like staging route was accepted.\n' >&2
    exit 1
fi

printf 'Cloudflare CIDR validation/rendering and staging noindex/bypass tests passed.\n'
