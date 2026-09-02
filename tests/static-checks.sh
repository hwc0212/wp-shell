#!/usr/bin/env bash

# shellcheck disable=SC2016

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scripts=(
    "$repo_root/wp-shell.sh"
    "$repo_root/wp-vps-manager.sh"
    "$repo_root/deploy-single-wordpress.sh"
)

for script in "${scripts[@]}"; do
    bash -n "$script"
    [[ "$(head -n 1 "$script")" == '#!/usr/bin/env bash' ]]
    grep -q '^set -Eeuo pipefail$' "$script"
    bash "$script" --version >/dev/null
    bash "$script" --help >/dev/null
done

bash -c 'source "$1"; check_platform' _ "$repo_root/wp-shell.sh"

if grep -nE 'ufw[[:space:]]+--force[[:space:]]+reset|/tmp/wp-(single-)?deploy\.state|FLUSHDB|fastcgi_cache_path[[:space:]]+/var/cache/nginx' "${scripts[@]}"; then
    printf 'A prohibited high-risk pattern was found.\n' >&2
    exit 1
fi

grep -Fq "readonly METRICS_DB=\"\$STATE_DIR/metrics.sqlite3\"" "$repo_root/wp-shell.sh"
grep -Fq 'readonly WP_SHELL_VERSION="10.0.3"' "$repo_root/wp-shell.sh"
grep -Fq 'PRAGMA wal_checkpoint(PASSIVE);" >/dev/null' "$repo_root/wp-shell.sh"
grep -Fq 'core download "$download_url" --force --skip-content --locale="$locale"' "$repo_root/wp-shell.sh"
grep -Fq 'verify_wordpress_core_strict "$domain"' "$repo_root/wp-shell.sh"
grep -Fq 'core-repair) repair_wordpress_core "$index"' "$repo_root/wp-shell.sh"
grep -Fq "} > \"\$TERMINAL_DEVICE\"" "$repo_root/wp-shell.sh"
grep -Fq 'END {printf "%d %d\n", rx, tx}' "$repo_root/wp-shell.sh"
grep -Fq 'php_pss_mb REAL NOT NULL DEFAULT 0' "$repo_root/wp-shell.sh"
grep -Fq 'Load {float(system.get('"'"'load1'"'"', 0)):.2f} / {cores} cores' "$repo_root/wp-shell.sh"
grep -Fq 'adopt_object_cache_policy "$domain"' "$repo_root/wp-shell.sh"
grep -Fq 'try_files \$uri =404;' "$repo_root/wp-shell.sh"
grep -Fq 'ssl_reject_handshake on;' "$repo_root/wp-shell.sh"
grep -Fq 'Permissions-Policy' "$repo_root/wp-shell.sh"
grep -Fq 'real_ip_header CF-Connecting-IP;' "$repo_root/wp-shell.sh"
grep -Fq 'real_ip_recursive on;' "$repo_root/wp-shell.sh"
grep -Fq 'WP_ENVIRONMENT_TYPE staging' "$repo_root/wp-shell.sh"
grep -Fq '*/5 * * * *' "$repo_root/wp-shell.sh"
grep -Fq 'timeout 30m nice -n 19 ionice -c3 aide --check' "$repo_root/wp-shell.sh"
grep -Fq 'rollback [ID] --confirm' "$repo_root/wp-shell.sh"
grep -Fq 'site_wp_config_set_redis_secret "$domain" "$redis_password"' "$repo_root/wp-shell.sh"
grep -Fq 'site_wp_config_path_is_safe "$wp_path"' "$repo_root/wp-shell.sh"
grep -Fq 'chmod 0660 -- "$wp_config"' "$repo_root/wp-shell.sh"
grep -Fq 'chmod 0640 -- "$wp_config"' "$repo_root/wp-shell.sh"
grep -Fq 'php_version="$DEFAULT_PHP_VERSION"' "$repo_root/wp-shell.sh"
grep -Fq 'wp_debug_value_is_false "$value"' "$repo_root/wp-shell.sh"
grep -Fq 'wp_debug_probe "$domain"' "$repo_root/wp-shell.sh"
grep -Fq 'WP_DEBUG could not be verified because the WP-CLI probe failed.' "$repo_root/wp-shell.sh"
grep -Fq 'has an enabled or invalid WP_DEBUG value.' "$repo_root/wp-shell.sh"
grep -Fq 'rotate-redis-secret) rotate_redis_secret ;;' "$repo_root/wp-shell.sh"
grep -Fq 'REDISCLI_AUTH="$(<"$REDIS_SECRET_FILE")" timeout 4s redis-cli --no-auth-warning' "$repo_root/wp-shell.sh"
grep -Fq 'config set WP_REDIS_PASSWORD "$placeholder" --quiet' "$repo_root/wp-shell.sh"
if grep -Fq 'config set WP_REDIS_PASSWORD "$redis_password"' "$repo_root/wp-shell.sh"; then
    printf 'The Redis credential must not be passed as a WP-CLI argument.\n' >&2
    exit 1
fi
if grep -q 'site_wp_cli_prompt_secret_quiet' "$repo_root/wp-shell.sh"; then
    printf 'WP-CLI positional values must not be populated through --prompt=value.\n' >&2
    exit 1
fi
if grep -nE 'redis-cli([^[:space:]]|[[:space:]])*[[:space:]]-a[[:space:]]' "$repo_root/wp-shell.sh"; then
    printf 'Redis credentials must not be passed through redis-cli -a.\n' >&2
    exit 1
fi
if grep -q '^readonly VERSION=' "$repo_root/wp-shell.sh"; then
    printf 'The generic VERSION variable conflicts with /etc/os-release.\n' >&2
    exit 1
fi
grep -Fq "readonly ENVIRONMENT_CONFIG_FILE=\"\$CONFIG_DIR/environment.v1\"" "$repo_root/wp-shell.sh"
grep -Fq "readonly WORDPRESS_LOCALE=\"\${WORDPRESS_LOCALE:-en_US}\"" "$repo_root/wp-shell.sh"
grep -Fq 'readonly WORDPRESS_VERSION_API="https://api.wordpress.org/core/version-check/1.7/"' "$repo_root/wp-shell.sh"
grep -Fq "fastcgi_pass unix:\$pool_socket;" "$repo_root/wp-shell.sh"
grep -Fq 'Cookies, query strings, referrers and user agents are excluded.' "$repo_root/wp-shell.sh"
if grep -q 'image_filter' "$repo_root/wp-shell.sh"; then
    printf 'Global Nginx image filtering must not be introduced.\n' >&2
    exit 1
fi
if grep -q 'install_site_wrapper' "$repo_root/wp-shell.sh"; then
    printf 'Per-domain command generation must not be reintroduced.\n' >&2
    exit 1
fi
if grep -Eq 'config set WP_CACHE|rewrite structure|plugin delete hello|enable_cloudflare_login_limits' "$repo_root/wp-shell.sh"; then
    printf 'A compatibility-sensitive default was reintroduced.\n' >&2
    exit 1
fi
grep -Fq 'site_policy_value "$domain" xmlrpc enabled' "$repo_root/wp-shell.sh"
grep -Fq 'site_policy_value "$domain" page-cache disabled' "$repo_root/wp-shell.sh"
grep -Fq 'site_policy_value "$domain" object-cache disabled' "$repo_root/wp-shell.sh"
grep -Fq 'expires 7d;' "$repo_root/wp-shell.sh"
if grep -q 'sudo -u www-data wp' "$repo_root/wp-shell.sh"; then
    printf 'Site WP-CLI calls must use the controlled site_wp_cli context.\n' >&2
    exit 1
fi
if grep -E 'wp rewrite structure .*--hard' "$repo_root/wp-shell.sh"; then
    printf 'Nginx sites must not request an Apache .htaccess rewrite flush.\n' >&2
    exit 1
fi
grep -Fq "WP_CLI_CACHE_DIR=\"\$wp_cli_home/cache\"" "$repo_root/wp-shell.sh"
grep -Fq 'WP_CLI_CACHE_DIR=/dev/null' "$repo_root/wp-shell.sh"
grep -Fq '/usr/local/bin/wp --no-color --skip-plugins --skip-themes' "$repo_root/wp-shell.sh"
grep -Fq 'due="$(site_wp_cli_readonly "$domain" cron event list' "$repo_root/wp-shell.sh"
if grep -nEi 'wflogs|wordfence|wpvivid staging' "$repo_root/wp-shell.sh"; then
    printf 'Plugin-specific policy must not be hard-coded into the generic control plane.\n' >&2
    exit 1
fi
if LC_ALL=C grep -nP '[^\x00-\x7F]' "${scripts[@]}"; then
    printf 'Non-ASCII text was found in terminal scripts.\n' >&2
    exit 1
fi

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "${scripts[@]}"
fi

printf 'Static checks passed.\n'
