#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2016,SC2034,SC2317,SC2329

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root" /tmp/wp-shell-must-not-execute' EXIT

export WP_SHELL_CONFIG_DIR="$test_root/current"
export WP_SHELL_STATE_DIR="$test_root/state"
export WP_SHELL_LEGACY_VPS_CONFIG_DIR="$test_root/legacy-vps"
export WP_SHELL_LEGACY_SINGLE_CONFIG_DIR="$test_root/legacy-single"
source "$repo_root/wp-shell.sh"
install -d -m 0700 "$CONFIG_DIR" "$DATABASE_CONFIG_DIR"

dangerous_title='"; touch /tmp/wp-shell-must-not-execute; #'
SITE_COUNT=1
SITE_DOMAINS[1]="example.com"
SITE_PRIMARY_DOMAINS[1]="www.example.com"
SITE_PHP_VERSIONS[1]="8.3"
SITE_WOOCOMMERCE[1]="no"
SITE_WWW[1]="yes"
SITE_REDIS_DATABASES[1]="0"
SITE_MODES[1]="managed"
SITE_ADMIN_USERS[1]="wpadmin"
SITE_ADMIN_EMAILS[1]="admin@example.com"
SITE_TITLES[1]="$dangerous_title"
SITE_PATHS[1]="/var/www/example.com/public"
save_sites_config

reset_sites
load_sites_config
[[ "$SITE_COUNT" -eq 1 ]]
[[ "${SITE_DOMAINS[1]}" == "example.com" ]]
[[ "${SITE_PRIMARY_DOMAINS[1]}" == "www.example.com" ]]
[[ "${SITE_MODES[1]}" == "managed" ]]
[[ "${SITE_TITLES[1]}" == "$dangerous_title" ]]
[[ ! -e /tmp/wp-shell-must-not-execute ]]
[[ "$(site_domain_from_selector 1)" == "example.com" ]]
[[ "$(site_domain_from_selector EXAMPLE.COM)" == "example.com" ]]
if site_domain_from_selector 0 >/dev/null 2>&1 || site_domain_from_selector 2 >/dev/null 2>&1; then
    printf 'An invalid site selector was accepted.\n' >&2
    exit 1
fi
[[ "$(first_available_redis_database)" == "1" ]]
[[ "$(site_pool_socket example.com)" != "$(site_pool_socket second.example.com)" ]]
[[ "$(database_config_path example.com)" != "$(database_config_path second.example.com)" ]]
[[ "$(site_cache_dir example.com)" != "$(site_cache_dir second.example.com)" ]]
[[ "$(site_backup_dir example.com)" != "$(site_backup_dir second.example.com)" ]]

rm -f "$SITES_CONFIG_FILE"
reset_sites
install -d -m 0700 "$LEGACY_VPS_CONFIG_DIR/databases"
printf 'version|2\nsite|legacy.example.com|8.3|no|no|0|%s|%s|%s|%s\n' \
    "$(b64_encode wpadmin)" "$(b64_encode admin@legacy.example.com)" \
    "$(b64_encode Legacy)" "$(b64_encode /var/www/legacy.example.com/public)" \
    > "$LEGACY_VPS_CONFIG_DIR/sites.v2"
printf 'database|wp_0123456789ab|wp_0123456789ab|%s\n' "$(b64_encode secret)" \
    > "$LEGACY_VPS_CONFIG_DIR/databases/legacy.example.com.v1"
migrate_legacy_configs
reset_sites
load_sites_config
[[ "$SITE_COUNT" -eq 1 ]]
[[ "${SITE_DOMAINS[1]}" == "legacy.example.com" ]]
[[ -f "$DATABASE_CONFIG_DIR/legacy.example.com.v1" ]]
find "$CONFIG_DIR/migration-backup" -type f -name sites.v2 | grep -q .

ensure_environment_config
[[ "$ENVIRONMENT_MODE" == "multi" ]]
[[ "$DEFAULT_PHP_VERSION" == "8.3" ]]
[[ "$ENVIRONMENT_UFW" == "no" ]]

ENVIRONMENT_MODE="single"
DEFAULT_PHP_VERSION="8.4"
ENVIRONMENT_UFW="yes"
save_environment_config
ENVIRONMENT_MODE=""
DEFAULT_PHP_VERSION="8.2"
ENVIRONMENT_UFW="no"
load_environment_config
[[ "$ENVIRONMENT_MODE" == "single" ]]
[[ "$DEFAULT_PHP_VERSION" == "8.4" ]]
[[ "$ENVIRONMENT_UFW" == "yes" ]]

SITE_PATHS[1]="$test_root/site/public"
mkdir -p "${SITE_PATHS[1]}"
mock_bin="$test_root/mock-bin"
mkdir -p "$mock_bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$mock_bin/install"
printf '#!/usr/bin/env bash\nprintf "cwd=%%s\\n" "$PWD"\nprintf "arg=%%s\\n" "$@"\n' > "$mock_bin/sudo"
chmod 0755 "$mock_bin/install" "$mock_bin/sudo"
wp_cli_context="$(PATH="$mock_bin:$PATH" site_wp_cli legacy.example.com core version)"
grep -Fq "cwd=${SITE_PATHS[1]}" <<< "$wp_cli_context"
grep -Fq 'arg=HOME=/var/www/legacy.example.com' <<< "$wp_cli_context"
grep -Fq 'arg=WP_CLI_CACHE_DIR=/var/www/legacy.example.com/.wp-cli/cache' <<< "$wp_cli_context"
grep -Fq "arg=--path=${SITE_PATHS[1]}" <<< "$wp_cli_context"

secret_output="$(printf "wp config create --dbpass='database-secret' --admin_password='admin-secret'\n" | redact_wp_cli_output)"
grep -Fq -- "--dbpass='[REDACTED]'" <<< "$secret_output"
grep -Fq -- "--admin_password='[REDACTED]'" <<< "$secret_output"
if grep -Eq 'database-secret|admin-secret' <<< "$secret_output"; then
    printf 'A prompted WP-CLI secret was not redacted.\n' >&2
    exit 1
fi

headers_have_managed_hsts $'HTTP/2 200\nstrict-transport-security: max-age=15552000; includeSubDomains'
if headers_have_managed_hsts $'HTTP/2 200\nstrict-transport-security: max-age=0'; then
    printf 'A disabled HSTS policy was accepted.\n' >&2
    exit 1
fi

wp_config="${SITE_PATHS[1]}/wp-config.php"
redis_test_secret="$(printf 'a%.0s' {1..48})"
redis_second_secret="$(printf 'b%.0s' {1..48})"
printf "<?php\ndefine( 'WP_REDIS_PASSWORD', 'old-value' );\n" > "$wp_config"
mock_wp_cli_failure="no"
site_wp_cli() {
    local _domain="$1"
    shift
    [[ "$*" == 'config set WP_REDIS_PASSWORD __WP_SHELL_REDIS_SECRET_PLACEHOLDER__ --quiet' ]] || return 2
    [[ "$*" != *"$redis_test_secret"* && "$*" != *"$redis_second_secret"* ]] || return 3
    printf "<?php\ndefine( 'WP_REDIS_PASSWORD', '__WP_SHELL_REDIS_SECRET_PLACEHOLDER__' );\n" > "$wp_config"
    [[ "$mock_wp_cli_failure" != "yes" ]]
}
site_wp_config_set_redis_secret legacy.example.com "$redis_test_secret"
wp_config_content="$(<"$wp_config")"
[[ "$wp_config_content" == *"$redis_test_secret"* ]]
[[ "$wp_config_content" != *'__WP_SHELL_REDIS_SECRET_PLACEHOLDER__'* ]]
[[ "$(stat -c '%a' "$wp_config")" == "600" ]]

wp_config_before_failure="$wp_config_content"
mock_wp_cli_failure="yes"
if site_wp_config_set_redis_secret legacy.example.com "$redis_second_secret"; then
    printf 'The failing atomic wp-config update unexpectedly succeeded.\n' >&2
    exit 1
fi
[[ "$(<"$wp_config")" == "$wp_config_before_failure" ]]
[[ "$(stat -c '%a' "$wp_config")" == "600" ]]

printf 'Site/environment configuration and legacy migration tests passed.\n'
