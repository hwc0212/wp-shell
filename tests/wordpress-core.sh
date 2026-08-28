#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2034,SC2317,SC2329

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export WP_SHELL_CONFIG_DIR="$test_root/config"
export WP_SHELL_STATE_DIR="$test_root/state"
source "$repo_root/wp-shell.sh"

SITE_COUNT=1
SITE_DOMAINS[1]="example.com"
SITE_PRIMARY_DOMAINS[1]="example.com"
SITE_PHP_VERSIONS[1]="8.4"
SITE_PATHS[1]="$test_root/public"
SITE_MODES[1]="managed"
mkdir -p "$test_root/public/wp-admin" \
    "$test_root/public/wp-includes/php-ai-client/third-party/Http/Discovery/Exception"
touch "$test_root/public/wp-load.php" "$test_root/public/wp-config.php"

wordpress_release_zip_url() {
    [[ "$1" == "en_US" && "$2" == "7.1" ]]
    printf 'https://downloads.wordpress.org/release/wordpress-7.1.zip'
}

site_wp_cli() {
    local _domain="$1"
    shift
    case "$*" in
        'core version') printf '7.1' ;;
        'eval echo get_locale();') printf 'en_US' ;;
        'core verify-checksums --version=7.1 --locale=en_US')
            if [[ -f "$test_root/report-missing" ]]; then
                printf "Warning: File doesn't exist: wp-includes/expected-long-file.php\n"
            fi
            if [[ -f "$test_root/public/wp-admin/error_log" ]]; then
                printf 'Warning: File should not exist: wp-admin/error_log\n'
            fi
            if [[ -f "$test_root/public/wp-includes/php-ai-client/third-party/Http/Discovery/Exception/NoCandidateFoundException.p" ]]; then
                printf 'Warning: File should not exist: wp-includes/php-ai-client/third-party/Http/Discovery/Exception/NoCandidateFoundException.p\n'
            fi
            printf 'Success: WordPress installation verifies against checksums.\n'
            ;;
        'core download https://downloads.wordpress.org/release/wordpress-7.1.zip --force --skip-content --locale=en_US')
            touch "$test_root/download-called"
            ;;
        'maintenance-mode activate'|'maintenance-mode deactivate') : ;;
        *) printf 'Unexpected WP-CLI call: %s\n' "$*" >&2; return 2 ;;
    esac
}

backup_site() { touch "$test_root/backup-called"; }
set_site_permissions() { touch "$test_root/permissions-called"; }
configure_https_site() { touch "$test_root/nginx-refresh-called"; }
clear_site_cache() { touch "$test_root/cache-clear-called"; }

touch "$test_root/report-missing"
if verify_wordpress_core_strict example.com en_US >/dev/null 2>&1; then
    printf 'Strict verification accepted a missing WordPress core file.\n' >&2
    exit 1
fi
rm -f "$test_root/report-missing"

touch "$test_root/public/wp-admin/error_log"
touch "$test_root/public/wp-includes/php-ai-client/third-party/Http/Discovery/Exception/NoCandidateFoundException.p"
if verify_wordpress_core_strict example.com en_US >/dev/null 2>&1; then
    printf 'Strict verification accepted unexpected WordPress core files.\n' >&2
    exit 1
fi

output="$(repair_wordpress_core 1)"
grep -q 'strictly verified WordPress 7.1 core' <<< "$output"
[[ -f "$test_root/backup-called" ]]
[[ -f "$test_root/download-called" ]]
[[ -f "$test_root/permissions-called" ]]
[[ ! -f "$test_root/nginx-refresh-called" ]]
[[ -f "$test_root/cache-clear-called" ]]
[[ ! -e "$test_root/public/wp-admin/error_log" ]]
[[ ! -e "$test_root/public/wp-includes/php-ai-client/third-party/Http/Discovery/Exception/NoCandidateFoundException.p" ]]
verify_wordpress_core_strict example.com en_US >/dev/null

printf 'Strict WordPress core verification and repair tests passed.\n'
