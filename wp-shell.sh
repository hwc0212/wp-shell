#!/usr/bin/env bash

# wp-shell - WordPress VPS manager
# Version 10.0.3
# Supported systems: Ubuntu 22.04/24.04 LTS

set -Eeuo pipefail
umask 077

readonly WP_SHELL_VERSION="10.0.3"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH
CONFIG_DIR="${WP_SHELL_CONFIG_DIR:-/etc/wp-shell}"
readonly CONFIG_DIR
readonly SITES_CONFIG_FILE="$CONFIG_DIR/sites.v3"
readonly ENVIRONMENT_CONFIG_FILE="$CONFIG_DIR/environment.v1"
readonly DATABASE_CONFIG_DIR="$CONFIG_DIR/databases"
readonly REDIS_SECRET_FILE="$CONFIG_DIR/redis.secret"
readonly STATE_DIR="${WP_SHELL_STATE_DIR:-/var/lib/wp-shell}"
readonly METRICS_DB="$STATE_DIR/metrics.sqlite3"
readonly TUNING_CONFIG_FILE="$CONFIG_DIR/tuning.v1"
readonly OPCACHE_CONFIG_FILE="$CONFIG_DIR/opcache.v1"
readonly SITE_POLICY_DIR="$CONFIG_DIR/site-policy"
readonly TRANSACTION_DIR="$CONFIG_DIR/transactions"
readonly LAST_TRANSACTION_FILE="$CONFIG_DIR/last-transaction"
readonly HOST_POLICY_FILE="$CONFIG_DIR/host-policy.v1"
readonly MARIADB_CONFIG_ROOT="${WP_SHELL_MARIADB_CONFIG_ROOT:-/etc/mysql}"
readonly MARIADB_MANAGED_CONFIG_FILE="$MARIADB_CONFIG_ROOT/mariadb.conf.d/60-wp-shell.cnf"
readonly CLOUDFLARE_IPV4_URL="https://www.cloudflare.com/ips-v4"
readonly CLOUDFLARE_IPV6_URL="https://www.cloudflare.com/ips-v6"
readonly LEGACY_VPS_CONFIG_DIR="${WP_SHELL_LEGACY_VPS_CONFIG_DIR:-/etc/wp-vps-manager}"
readonly LEGACY_SINGLE_CONFIG_DIR="${WP_SHELL_LEGACY_SINGLE_CONFIG_DIR:-/etc/wp-single-deploy}"
readonly LEGACY_BACKUP_ROOT="${WP_SHELL_LEGACY_BACKUP_ROOT:-/var/backups/wp-shell}"
readonly LEGACY_SINGLE_BACKUP_ROOT="${WP_SHELL_LEGACY_SINGLE_BACKUP_ROOT:-/var/backups/wp-shell-single}"
readonly LEGACY_CACHE_ROOT="${WP_SHELL_LEGACY_CACHE_ROOT:-/var/cache/nginx}"
readonly LOG_DIR="/var/log/wp-shell"
LOG_FILE="$LOG_DIR/wp-shell-$(date +%Y%m%d-%H%M%S).log"
readonly LOG_FILE
readonly MANAGED_SCRIPT="/usr/local/sbin/wp-shell"
readonly WP_CLI_VERSION="${WP_CLI_VERSION:-2.12.0}"
readonly WORDPRESS_LOCALE="${WORDPRESS_LOCALE:-en_US}"
readonly WORDPRESS_VERSION_API="https://api.wordpress.org/core/version-check/1.7/"
# Automatic deletion is opt-in. A zero value keeps every completed backup.
readonly BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-0}"
readonly TERMINAL_DEVICE="${WP_SHELL_TERMINAL_DEVICE:-/dev/tty}"

readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[1;33m'
readonly CYAN=$'\033[0;36m'
readonly NC=$'\033[0m'

AVAILABLE_PHP_VERSIONS=("8.2" "8.3" "8.4")
declare -a SITE_DOMAINS=()
declare -a SITE_PRIMARY_DOMAINS=()
declare -a SITE_PHP_VERSIONS=()
declare -a SITE_WOOCOMMERCE=()
declare -a SITE_WWW=()
declare -a SITE_REDIS_DATABASES=()
declare -a SITE_ADMIN_USERS=()
declare -a SITE_ADMIN_EMAILS=()
declare -a SITE_TITLES=()
declare -a SITE_PATHS=()
declare -a SITE_MODES=()
declare -a SITE_PHP_MAX_CHILDREN=()
declare -A PHP_CHILD_OVERRIDES=()
declare -A OPCACHE_MEMORY_OVERRIDES=()
declare -A OPCACHE_STRINGS_OVERRIDES=()
SITE_COUNT=0
LEGACY_SINGLE_DOMAIN=""
ENVIRONMENT_MODE=""
DEFAULT_PHP_VERSION="8.3"
ENVIRONMENT_UFW="no"
CURRENT_STEP="initialization"
MARIADB_BUFFER_MB=256
REDIS_MAX_MEMORY_MB=64
PHP_TOTAL_BUDGET_MB=256
OPCACHE_TOTAL_BUDGET_MB=128
NEW_SITE_CREDENTIAL_DOMAIN=""
NEW_SITE_ADMIN_PASSWORD=""
DRY_RUN="no"
TRANSACTION_CONTEXT="no"
TRANSACTION_ACTIVE="no"
TRANSACTION_ROLLING_BACK="no"
TRANSACTION_ID=""
TRANSACTION_PATH=""
TRANSACTION_MANIFEST=""
TRANSACTION_FILE_COUNT=0
declare -a REGISTERED_TEMP_PATHS=()

supports_color() {
    [[ -t 1 && "${NO_COLOR:-}" == "" ]]
}

color_for_level() {
    local level="$1"
    if ! supports_color; then
        printf ''
        # A bare return inside an EXIT/ERR trap can inherit the original failure.
        return 0
    fi
    case "$level" in
        ERROR) printf '%s' "$RED" ;;
        SUCCESS) printf '%s' "$GREEN" ;;
        WARNING) printf '%s' "$YELLOW" ;;
        *) printf '%s' "$CYAN" ;;
    esac
}

log_message() {
    local level="$1"
    shift
    local color reset
    color="$(color_for_level "$level")"
    reset=""
    [[ -n "$color" ]] && reset="$NC"
    printf '%s %s[%s]%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$color" "$level" "$reset" "$*"
}

die() {
    log_message ERROR "$*"
    # `exit` does not trigger Bash's ERR trap.  Validation paths deliberately
    # use die(), so restore an active configuration transaction here too.
    if [[ "$TRANSACTION_ACTIVE" == yes && "$TRANSACTION_ROLLING_BACK" == no ]]; then
        transaction_rollback_internal "$TRANSACTION_PATH" automatic || \
            log_message ERROR "Automatic rollback was incomplete. Inspect: $TRANSACTION_PATH"
    fi
    exit 1
}

on_error() {
    local exit_code=$?
    local function_name="${FUNCNAME[1]:-main}" line_number="${BASH_LINENO[0]:-unknown}"
    if [[ "$TRANSACTION_ACTIVE" == yes && "$TRANSACTION_ROLLING_BACK" == no ]]; then
        transaction_rollback_internal "$TRANSACTION_PATH" "automatic" || \
            log_message ERROR "Automatic rollback was incomplete. Inspect: $TRANSACTION_PATH"
    fi
    log_message ERROR "Step '$CURRENT_STEP' failed in $function_name at line $line_number with exit code $exit_code. Log: $LOG_FILE"
    exit "$exit_code"
}
trap on_error ERR

cleanup_registered_temp_paths() {
    local path
    for path in "${REGISTERED_TEMP_PATHS[@]}"; do
        [[ -z "$path" || ! -e "$path" || -L "$path" ]] || rm -rf -- "$path"
    done
}
trap cleanup_registered_temp_paths EXIT

register_temp_path() {
    local path="$1"
    [[ "$path" == /tmp/wp-shell.* || "$path" == "${TMPDIR:-/tmp}"/wp-shell.* ]] || die "Refusing to register an unsafe temporary path: $path"
    REGISTERED_TEMP_PATHS+=("$path")
}

ensure_root() {
    if [[ $EUID -eq 0 ]]; then
        return
    fi
    command -v sudo >/dev/null 2>&1 || die "Root privileges are required and sudo is not installed."
    exec sudo -E bash "$SCRIPT_PATH" "$@"
}

init_paths() {
    install -d -m 0700 "$CONFIG_DIR" "$DATABASE_CONFIG_DIR" "$TRANSACTION_DIR" "$STATE_DIR"
    install -d -m 0755 /var/www
    install -d -m 0750 "$LOG_DIR"
}

safe_temp_dir() {
    local base="${TMPDIR:-/tmp}"
    [[ "$base" == /* && -d "$base" && ! -L "$base" ]] || die "Unsafe temporary directory base: $base"
    mktemp -d "$base/wp-shell.XXXXXXXX"
}

safe_managed_target() {
    local target="$1"
    [[ "$target" == /* && "$target" != *$'\n'* && "$target" != *'/../'* && "$target" != */.. ]] || return 1
    case "$target" in
        "$CONFIG_DIR"/*|"$STATE_DIR"/*|/tmp/*) return 0 ;;
    esac
    if [[ "$CONFIG_DIR" != /etc/wp-shell && ! ( "${WP_SHELL_TEST_ROOT_WRITES:-no}" == yes && $EUID -eq 0 && "$CONFIG_DIR" == /tmp/* ) ]]; then
        return 1
    fi
    case "$target" in
        /etc/*|/usr/local/bin/wp|/usr/local/sbin/wp-*|/usr/local/bin/wp-*|/usr/local/bin/manage-*|/var/lib/wp-shell/*|/var/www/*) return 0 ;;
        *) return 1 ;;
    esac
}

transaction_begin() {
    local label="${1:-configuration change}" slug timestamp
    [[ "$TRANSACTION_CONTEXT" == yes && "$DRY_RUN" == no ]] || return 0
    [[ "$TRANSACTION_ACTIVE" == no ]] || return 0
    if [[ $EUID -eq 0 ]]; then
        install -d -o root -g root -m 0700 "$TRANSACTION_DIR"
    else
        install -d -m 0700 "$TRANSACTION_DIR"
    fi
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    slug="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//' | cut -c1-40)"
    [[ -n "$slug" ]] || slug=operation
    TRANSACTION_PATH="$(mktemp -d "$TRANSACTION_DIR/${timestamp}-${slug}.XXXXXX")"
    chmod 0700 "$TRANSACTION_PATH"
    TRANSACTION_ID="${TRANSACTION_PATH##*/}"
    TRANSACTION_MANIFEST="$TRANSACTION_PATH/manifest.v1"
    {
        printf 'version|1\n'
        printf 'id|%s\n' "$TRANSACTION_ID"
        printf 'label|%s\n' "$(b64_encode "$label")"
        printf 'started|%s\n' "$(date --iso-8601=seconds)"
        printf 'state|pending\n'
    } > "$TRANSACTION_MANIFEST"
    chmod 0600 "$TRANSACTION_MANIFEST"
    install -d -m 0700 "$TRANSACTION_PATH/files"
    TRANSACTION_ACTIVE=yes
}

transaction_backup_file() {
    local target="$1" encoded backup_name exists=no
    [[ "$TRANSACTION_ACTIVE" == yes ]] || return 0
    safe_managed_target "$target" || die "Refusing to transact an unsafe path: $target"
    encoded="$(b64_encode "$target")"
    grep -Fq "|$encoded|" "$TRANSACTION_MANIFEST" && return 0
    TRANSACTION_FILE_COUNT=$((TRANSACTION_FILE_COUNT + 1))
    backup_name="files/$TRANSACTION_FILE_COUNT"
    if [[ -e "$target" || -L "$target" ]]; then
        cp -a -- "$target" "$TRANSACTION_PATH/$backup_name"
        exists=yes
    fi
    printf 'file|%s|%s|%s\n' "$encoded" "$exists" "$backup_name" >> "$TRANSACTION_MANIFEST"
}

transaction_mark_service() {
    local service="$1"
    [[ "$TRANSACTION_ACTIVE" == yes ]] || return 0
    [[ "$service" =~ ^(nginx|sshd|mariadb|redis|fail2ban|postfix|php:[0-9]+\.[0-9]+|systemd)$ ]] || die "Invalid transaction service marker: $service"
    grep -Fxq "service|$service" "$TRANSACTION_MANIFEST" || printf 'service|%s\n' "$service" >> "$TRANSACTION_MANIFEST"
}

timestamp_backup_file() {
    local target="$1" timestamp
    [[ -e "$target" || -L "$target" ]] || return 0
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    cp -a -- "$target" "$target.wp-shell-backup-$timestamp"
}

write_managed_file() {
    local target="$1" mode="${2:-0644}" owner="${3:-root}" group="${4:-root}" directory temp
    safe_managed_target "$target" || die "Refusing to write an unsafe path: $target"
    directory="$(dirname "$target")"
    [[ -d "$directory" && ! -L "$directory" ]] || die "Managed target directory is missing or unsafe: $directory"
    temp="$(mktemp "$directory/.wp-shell-candidate.XXXXXXXX")"
    cat > "$temp"
    if [[ -f "$target" && ! -L "$target" ]] && cmp -s "$temp" "$target" && \
       [[ "$(stat -c '%a:%U:%G' "$target")" == "${mode#0}:$owner:$group" ]]; then
        rm -f -- "$temp"
        return 0
    fi
    if [[ "$DRY_RUN" == yes ]]; then
        printf 'PLAN write %s mode=%s owner=%s:%s\n' "$target" "$mode" "$owner" "$group"
        rm -f -- "$temp"
        return 0
    fi
    transaction_begin "$CURRENT_STEP"
    if [[ "$TRANSACTION_ACTIVE" == yes ]]; then transaction_backup_file "$target"; else timestamp_backup_file "$target"; fi
    chmod "$mode" "$temp"
    if [[ $EUID -eq 0 ]]; then chown "$owner:$group" "$temp"; fi
    mv -T -- "$temp" "$target"
}

remove_managed_file() {
    local target="$1"
    safe_managed_target "$target" || die "Refusing to remove an unsafe path: $target"
    [[ -e "$target" || -L "$target" ]] || return 0
    if [[ "$DRY_RUN" == yes ]]; then printf 'PLAN remove %s\n' "$target"; return 0; fi
    transaction_begin "$CURRENT_STEP"
    if [[ "$TRANSACTION_ACTIVE" == yes ]]; then transaction_backup_file "$target"; else timestamp_backup_file "$target"; fi
    rm -f -- "$target"
}

write_managed_symlink() {
    local link="$1" destination="$2"
    safe_managed_target "$link" || die "Refusing to create an unsafe managed link: $link"
    [[ "$destination" == /* && "$destination" != *$'\n'* ]] || die "Managed link destination must be absolute."
    if [[ -L "$link" && "$(readlink "$link")" == "$destination" ]]; then return 0; fi
    if [[ "$DRY_RUN" == yes ]]; then printf 'PLAN link %s -> %s\n' "$link" "$destination"; return 0; fi
    transaction_begin "$CURRENT_STEP"
    if [[ "$TRANSACTION_ACTIVE" == yes ]]; then transaction_backup_file "$link"; else timestamp_backup_file "$link"; fi
    ln -sfn "$destination" "$link"
}

transaction_rollback_internal() {
    local transaction="$1" reason="${2:-manual}" manifest record encoded existed backup target temp service version
    local -a transaction_records=()
    manifest="$transaction/manifest.v1"
    [[ -f "$manifest" ]] || { log_message ERROR "Transaction manifest is missing: $transaction"; return 1; }
    TRANSACTION_ROLLING_BACK=yes
    if [[ "$reason" == manual ]]; then
        while IFS='|' read -r _record encoded expected; do
            target="$(b64_decode "$encoded")"
            if [[ "$(managed_file_fingerprint "$target")" != "$expected" ]]; then
                log_message ERROR "Refusing rollback because a managed file changed after commit: $target"
                TRANSACTION_ROLLING_BACK=no
                return 1
            fi
        done < <(grep '^after|' "$manifest")
    fi
    mapfile -t transaction_records < <(grep '^file|' "$manifest" | tac)
    for record in "${transaction_records[@]}"; do
        IFS='|' read -r _record encoded existed backup <<< "$record"
        target="$(b64_decode "$encoded")"
        safe_managed_target "$target" || { log_message ERROR "Unsafe rollback target in manifest: $target (config root: $CONFIG_DIR)"; return 1; }
        if [[ "$existed" == yes ]]; then
            [[ -e "$transaction/$backup" || -L "$transaction/$backup" ]] || return 1
            temp="$(mktemp "$(dirname "$target")/.wp-shell-rollback.XXXXXXXX")"
            rm -f -- "$temp"
            cp -a -- "$transaction/$backup" "$temp"
            rm -rf -- "$target"
            mv -T -- "$temp" "$target"
        else
            rm -rf -- "$target"
        fi
    done
    while IFS='|' read -r _record service; do
        case "$service" in
            nginx) nginx -t && systemctl reload nginx || return 1 ;;
            sshd)
                sshd -t || return 1
                systemctl reload ssh 2>/dev/null || systemctl reload sshd || return 1
                ;;
            mariadb) systemctl restart mariadb || return 1 ;;
            redis) systemctl restart redis-server || return 1 ;;
            fail2ban) fail2ban-client -t && systemctl reload-or-restart fail2ban || return 1 ;;
            postfix) postfix check && systemctl reload postfix || return 1 ;;
            php:*) version="${service#php:}"; "php-fpm$version" -t && php_fpm_service_action reload "$version" || return 1 ;;
            systemd) systemctl daemon-reload || return 1 ;;
        esac
    done < <(grep '^service|' "$manifest" | tac)
    printf 'rolled-back|%s|%s\n' "$reason" "$(date --iso-8601=seconds)" >> "$manifest"
    TRANSACTION_ACTIVE=no
    TRANSACTION_ROLLING_BACK=no
    log_message WARNING "Rolled back transaction ${transaction##*/} ($reason)."
}

managed_file_fingerprint() {
    local target="$1"
    if [[ -L "$target" ]]; then
        printf 'symlink:%s' "$(readlink "$target")"
    elif [[ -f "$target" ]]; then
        printf 'file:%s:%s' "$(stat -c '%a:%U:%G' "$target")" "$(sha256sum "$target" | cut -d' ' -f1)"
    elif [[ -e "$target" ]]; then
        printf 'other:%s' "$(stat -c '%F:%a:%U:%G' "$target")"
    else
        printf absent
    fi
}

transaction_commit() {
    local record encoded target temp
    [[ "$TRANSACTION_ACTIVE" == yes ]] || return 0
    while IFS= read -r record; do
        IFS='|' read -r _record encoded _existed _backup <<< "$record"
        target="$(b64_decode "$encoded")"
        printf 'after|%s|%s\n' "$encoded" "$(managed_file_fingerprint "$target")" >> "$TRANSACTION_MANIFEST"
    done < <(grep '^file|' "$TRANSACTION_MANIFEST")
    printf 'committed|%s\n' "$(date --iso-8601=seconds)" >> "$TRANSACTION_MANIFEST"
    temp="$(mktemp "$CONFIG_DIR/.last-transaction.XXXXXXXX")"
    printf '%s\n' "$TRANSACTION_ID" > "$temp"
    chmod 0600 "$temp"
    mv -T -- "$temp" "$LAST_TRANSACTION_FILE"
    TRANSACTION_ACTIVE=no
    log_message SUCCESS "Committed transaction $TRANSACTION_ID. Roll back with: wp-shell rollback $TRANSACTION_ID --confirm"
}

init_runtime() {
    init_paths
    touch "$LOG_FILE"
    chmod 0600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE")
    exec 2> >(tee -a "$LOG_FILE" >&2)
    exec 9>/run/wp-shell.lock
    flock -n 9 || die "Another wp-shell process is already running."
}

check_platform() {
    [[ -r /etc/os-release ]] || die "Cannot identify the operating system."
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || die "Only Ubuntu is supported."
    case "${VERSION_ID:-}" in
        22.04|24.04) ;;
        *) die "Only Ubuntu 22.04 and 24.04 LTS are supported. Current: ${VERSION_ID:-unknown}" ;;
    esac
    [[ "$(uname -m)" == "x86_64" || "$(uname -m)" == "aarch64" ]] || die "Unsupported architecture: $(uname -m)"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

generate_password() {
    openssl rand -hex 24
}

b64_encode() {
    printf '%s' "$1" | base64 -w 0
}

b64_decode() {
    printf '%s' "$1" | base64 --decode
}

validate_domain() {
    local domain="${1,,}"
    [[ ${#domain} -le 253 ]] || return 1
    [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

validate_email() {
    [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

validate_php_version() {
    local candidate="$1" version
    for version in "${AVAILABLE_PHP_VERSIONS[@]}"; do
        [[ "$candidate" == "$version" ]] && return 0
    done
    return 1
}

load_environment_config() {
    ENVIRONMENT_MODE=""
    DEFAULT_PHP_VERSION="8.3"
    ENVIRONMENT_UFW="no"
    [[ -f "$ENVIRONMENT_CONFIG_FILE" ]] || return 0
    local record value version_seen="no"
    while IFS='|' read -r record value _extra; do
        [[ -n "$record" ]] || continue
        case "$record" in
            version)
                [[ "$value" == "1" ]] || die "Unsupported environment configuration version: $value"
                version_seen="yes"
                ;;
            mode)
                [[ "$value" == "single" || "$value" == "multi" ]] || die "Invalid environment mode: $value"
                ENVIRONMENT_MODE="$value"
                ;;
            php)
                validate_php_version "$value" || die "Unsupported environment PHP version: $value"
                DEFAULT_PHP_VERSION="$value"
                ;;
            firewall)
                [[ "$value" == "yes" || "$value" == "no" ]] || die "Invalid firewall setting: $value"
                ENVIRONMENT_UFW="$value"
                ;;
            \#*) ;;
            *) die "Unknown environment configuration record: $record" ;;
        esac
    done < "$ENVIRONMENT_CONFIG_FILE"
    [[ "$version_seen" == "yes" ]] || die "Environment configuration has no version record."
    [[ -n "$ENVIRONMENT_MODE" ]] || die "Environment configuration has no deployment mode."
}

save_environment_config() {
    [[ "$ENVIRONMENT_MODE" == "single" || "$ENVIRONMENT_MODE" == "multi" ]] || die "Cannot save an invalid environment mode."
    validate_php_version "$DEFAULT_PHP_VERSION" || die "Cannot save an invalid environment PHP version."
    [[ "$ENVIRONMENT_UFW" == "yes" || "$ENVIRONMENT_UFW" == "no" ]] || die "Cannot save an invalid firewall setting."
    local temp_file
    temp_file="$(mktemp "$CONFIG_DIR/.environment.XXXXXX")"
    {
        printf 'version|1\n'
        printf 'mode|%s\n' "$ENVIRONMENT_MODE"
        printf 'php|%s\n' "$DEFAULT_PHP_VERSION"
        printf 'firewall|%s\n' "$ENVIRONMENT_UFW"
    } > "$temp_file"
    install_private_file "$temp_file" "$ENVIRONMENT_CONFIG_FILE"
    rm -f "$temp_file"
}

ensure_environment_config() {
    if [[ -f "$ENVIRONMENT_CONFIG_FILE" ]]; then
        load_environment_config
        return
    fi
    if ((SITE_COUNT > 0)); then
        ENVIRONMENT_MODE="multi"
        DEFAULT_PHP_VERSION="${SITE_PHP_VERSIONS[1]}"
        ENVIRONMENT_UFW="no"
        save_environment_config
    fi
}

site_index_by_domain() {
    local domain="${1,,}" i
    for ((i = 1; i <= SITE_COUNT; i++)); do
        if [[ "${SITE_DOMAINS[$i]}" == "$domain" ]]; then
            printf '%s' "$i"
            return 0
        fi
    done
    return 1
}

site_domain_from_selector() {
    local selector="${1,,}" index
    if [[ "$selector" =~ ^[1-9][0-9]*$ ]] && ((10#$selector <= SITE_COUNT)); then
        printf '%s' "${SITE_DOMAINS[$((10#$selector))]}"
        return 0
    fi
    index="$(site_index_by_domain "$selector")" || return 1
    printf '%s' "${SITE_DOMAINS[$index]}"
}

reset_sites() {
    SITE_DOMAINS=()
    SITE_PRIMARY_DOMAINS=()
    SITE_PHP_VERSIONS=()
    SITE_WOOCOMMERCE=()
    SITE_WWW=()
    SITE_REDIS_DATABASES=()
    SITE_ADMIN_USERS=()
    SITE_ADMIN_EMAILS=()
    SITE_TITLES=()
    SITE_PATHS=()
    SITE_MODES=()
    SITE_PHP_MAX_CHILDREN=()
    SITE_COUNT=0
}

load_sites_config() {
    reset_sites
    [[ -f "$SITES_CONFIG_FILE" ]] || return 0

    local record domain primary php woo www redis_db mode admin_b64 email_b64 title_b64 path_b64 i
    while IFS='|' read -r record domain primary php woo www redis_db mode admin_b64 email_b64 title_b64 path_b64; do
        [[ -n "$record" ]] || continue
        case "$record" in
            version)
                [[ "$domain" == "3" ]] || die "Unsupported site configuration version: $domain"
                ;;
            site)
                validate_domain "$domain" || die "Invalid domain in configuration: $domain"
                [[ "$primary" == "$domain" || "$primary" == "www.$domain" ]] || die "Invalid primary domain for $domain"
                validate_php_version "$php" || die "Unsupported PHP version in configuration: $php"
                [[ "$woo" == "yes" || "$woo" == "no" ]] || die "Invalid WooCommerce value for $domain"
                [[ "$www" == "yes" || "$www" == "no" ]] || die "Invalid www value for $domain"
                [[ "$primary" != "www.$domain" || "$www" == "yes" ]] || die "www must be enabled when it is primary for $domain"
                [[ "$redis_db" =~ ^([0-9]|1[0-5])$ ]] || die "Invalid Redis database for $domain"
                [[ "$mode" == "managed" || "$mode" == "imported" ]] || die "Invalid management mode for $domain"
                site_index_by_domain "$domain" >/dev/null 2>&1 && die "Duplicate domain in configuration: $domain"
                for ((i = 1; i <= SITE_COUNT; i++)); do
                    [[ "${SITE_REDIS_DATABASES[$i]}" != "$redis_db" ]] || die "Redis database $redis_db is assigned more than once."
                done
                SITE_COUNT=$((SITE_COUNT + 1))
                SITE_DOMAINS[SITE_COUNT]="$domain"
                SITE_PRIMARY_DOMAINS[SITE_COUNT]="$primary"
                SITE_PHP_VERSIONS[SITE_COUNT]="$php"
                SITE_WOOCOMMERCE[SITE_COUNT]="$woo"
                SITE_WWW[SITE_COUNT]="$www"
                SITE_REDIS_DATABASES[SITE_COUNT]="$redis_db"
                SITE_MODES[SITE_COUNT]="$mode"
                SITE_ADMIN_USERS[SITE_COUNT]="$(b64_decode "$admin_b64")"
                SITE_ADMIN_EMAILS[SITE_COUNT]="$(b64_decode "$email_b64")"
                SITE_TITLES[SITE_COUNT]="$(b64_decode "$title_b64")"
                if [[ -n "$path_b64" ]]; then
                    SITE_PATHS[SITE_COUNT]="$(b64_decode "$path_b64")"
                else
                    SITE_PATHS[SITE_COUNT]="/var/www/$domain/public"
                fi
                [[ "${SITE_PATHS[SITE_COUNT]}" == /* ]] || die "Site path must be absolute: $domain"
                [[ ! "${SITE_PATHS[SITE_COUNT]}" =~ [[:space:]] ]] || die "Site paths cannot contain whitespace: $domain"
                ;;
            \#*) ;;
            *) die "Unknown site configuration record: $record" ;;
        esac
    done < "$SITES_CONFIG_FILE"
}

save_sites_config() {
    local temp_file i
    temp_file="$(mktemp "$CONFIG_DIR/.sites.XXXXXX")"
    {
        printf 'version|3\n'
        for ((i = 1; i <= SITE_COUNT; i++)); do
            printf 'site|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
                "${SITE_DOMAINS[$i]}" \
                "${SITE_PRIMARY_DOMAINS[$i]}" \
                "${SITE_PHP_VERSIONS[$i]}" \
                "${SITE_WOOCOMMERCE[$i]}" \
                "${SITE_WWW[$i]}" \
                "${SITE_REDIS_DATABASES[$i]}" \
                "${SITE_MODES[$i]}" \
                "$(b64_encode "${SITE_ADMIN_USERS[$i]}")" \
                "$(b64_encode "${SITE_ADMIN_EMAILS[$i]}")" \
                "$(b64_encode "${SITE_TITLES[$i]}")" \
                "$(b64_encode "${SITE_PATHS[$i]}")"
        done
    } > "$temp_file"
    write_managed_file "$SITES_CONFIG_FILE" 0600 root root < "$temp_file"
    rm -f "$temp_file"
}

redis_database_in_use() {
    local candidate="$1" i
    for ((i = 1; i <= SITE_COUNT; i++)); do
        [[ "${SITE_REDIS_DATABASES[$i]}" != "$candidate" ]] || return 0
    done
    return 1
}

first_available_redis_database() {
    local candidate
    for candidate in {0..15}; do
        if ! redis_database_in_use "$candidate"; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

load_tuning_config() {
    PHP_CHILD_OVERRIDES=()
    [[ -f "$TUNING_CONFIG_FILE" ]] || return 0
    local record domain value
    while IFS='|' read -r record domain value; do
        [[ -n "$record" ]] || continue
        [[ "$record" == "php" ]] || die "Unknown tuning record: $record"
        validate_domain "$domain" || die "Invalid domain in tuning configuration: $domain"
        if [[ ! "$value" =~ ^[0-9]+$ ]] || ((value < 2 || value > 50)); then
            die "Invalid PHP child limit for $domain"
        fi
        PHP_CHILD_OVERRIDES["$domain"]="$value"
    done < "$TUNING_CONFIG_FILE"
}

save_tuning_config() {
    local temp_file domain
    temp_file="$(mktemp "$CONFIG_DIR/.tuning.XXXXXX")"
    for domain in "${!PHP_CHILD_OVERRIDES[@]}"; do
        printf 'php|%s|%s\n' "$domain" "${PHP_CHILD_OVERRIDES[$domain]}"
    done | sort > "$temp_file"
    install_private_file "$temp_file" "$TUNING_CONFIG_FILE"
    rm -f "$temp_file"
}

install_private_file() {
    local source="$1" target="$2"
    write_managed_file "$target" 0600 root root < "$source"
}

validate_opcache_values() {
    local memory="$1" strings="$2"
    [[ "$memory" =~ ^[1-9][0-9]{1,3}$ && "$strings" =~ ^[1-9][0-9]{0,2}$ ]] || return 1
    ((memory >= 64 && memory <= 2048 && strings >= 4 && strings <= 512 && strings <= memory / 2))
}

opcache_scan_dir() { printf '/etc/php/%s/fpm/conf.d' "$1"; }
opcache_managed_ini() { printf '%s/zz-wp-shell-opcache.ini' "$(opcache_scan_dir "$1")"; }

load_opcache_config() {
    OPCACHE_MEMORY_OVERRIDES=()
    OPCACHE_STRINGS_OVERRIDES=()
    [[ -f "$OPCACHE_CONFIG_FILE" ]] || return 0
    local record version memory strings extra header=""
    while IFS='|' read -r record version memory strings extra || [[ -n "$record" ]]; do
        [[ -n "$record" ]] || continue
        if [[ -z "$header" ]]; then
            [[ "$record|$version" == 'version|1' && -z "$memory$strings$extra" ]] || die "Invalid OPcache configuration header."
            header=1
            continue
        fi
        if [[ "$record" != php || -n "$extra" ]] || ! validate_php_version "$version" ||
            ! validate_opcache_values "$memory" "$strings"; then
            die "Invalid OPcache configuration record."
        fi
        [[ -z "${OPCACHE_MEMORY_OVERRIDES[$version]:-}" ]] || die "Duplicate OPcache version: $version"
        OPCACHE_MEMORY_OVERRIDES[$version]="$memory"
        OPCACHE_STRINGS_OVERRIDES[$version]="$strings"
    done < "$OPCACHE_CONFIG_FILE"
    [[ -n "$header" ]] || die "Empty OPcache configuration."
}

save_opcache_config() {
    local temp_file version
    temp_file="$(mktemp "$CONFIG_DIR/.opcache.XXXXXX")" || return 1
    {
        printf 'version|1\n'
        for version in "${AVAILABLE_PHP_VERSIONS[@]}"; do
            [[ -n "${OPCACHE_MEMORY_OVERRIDES[$version]:-}" ]] || continue
            printf 'php|%s|%s|%s\n' "$version" "${OPCACHE_MEMORY_OVERRIDES[$version]}" "${OPCACHE_STRINGS_OVERRIDES[$version]}"
        done
    } > "$temp_file" || { rm -f "$temp_file"; return 1; }
    install_private_file "$temp_file" "$OPCACHE_CONFIG_FILE"
    rm -f -- "$temp_file"
}

opcache_values() {
    local version="$1" memory=128 strings=16 local_ini key value
    if [[ -n "${OPCACHE_MEMORY_OVERRIDES[$version]:-}" ]]; then
        memory="${OPCACHE_MEMORY_OVERRIDES[$version]}"
        strings="${OPCACHE_STRINGS_OVERRIDES[$version]}"
    else
        local_ini="$(opcache_scan_dir "$version")/99-zz-local-opcache.ini"
        if [[ -f "$local_ini" ]]; then
            # Parse only the two numeric settings; never source an INI file as shell code.
            while IFS='=' read -r key value; do
                case "$key" in
                    opcache.memory_consumption) memory="$value" ;;
                    opcache.interned_strings_buffer) strings="$value" ;;
                esac
            done < <(awk -F= '
                /^[[:space:]]*opcache\.(memory_consumption|interned_strings_buffer)[[:space:]]*=/ {
                    key=$1; value=substr($0,index($0,"=")+1)
                    sub(/[;#].*$/, "", value); gsub(/[[:space:]\042\047]/,"",value)
                    gsub(/[[:space:]]/,"",key); print key "=" value
                }' "$local_ini")
        fi
    fi
    validate_opcache_values "$memory" "$strings" || die "Invalid OPcache settings for PHP $version. Review opcache.v1 and the local INI file."
    printf '%s %s\n' "$memory" "$strings"
}

write_opcache_ini() {
    local version="$1" memory="$2" strings="$3" target temp_file
    target="$(opcache_managed_ini "$version")"
    if [[ -e "$target" || -L "$target" ]]; then
        if [[ ! -f "$target" || -L "$target" ]] || ! grep -Fxq '; Managed by wp-shell OPcache settings.' "$target"; then
            log_message ERROR "Refusing to overwrite an unmanaged OPcache file: $target" >&2
            return 1
        fi
    fi
    temp_file="$(mktemp "$(opcache_scan_dir "$version")/.wp-shell-opcache.XXXXXX")" || return 1
    printf '; Managed by wp-shell OPcache settings.\nopcache.memory_consumption = %s\nopcache.interned_strings_buffer = %s\n' \
        "$memory" "$strings" > "$temp_file" || { rm -f "$temp_file"; return 1; }
    write_managed_file "$target" 0644 root root < "$temp_file"
    rm -f -- "$temp_file"
}

php_fpm_service_action() {
    local action="$1" version="$2"
    systemctl daemon-reload && systemctl "$action" "php${version}-fpm"
}

opcache_effective_values() {
    local info
    info="$("php-fpm$1" -i 2>/dev/null)" || return 1
    awk -F ' => ' '
        $1 == "opcache.memory_consumption" {memory=$2}
        $1 == "opcache.interned_strings_buffer" {strings=$2}
        END {if (memory ~ /^[0-9]+$/ && strings ~ /^[0-9]+$/) print memory " " strings; else exit 1}
    ' <<< "$info"
}

available_memory_mb() { awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo; }

opcache_budget_versions() {
    local version
    local -A seen=()
    while IFS= read -r version; do
        seen[$version]=1
        printf '%s\n' "$version"
    done < <(unique_php_versions)
    for version in "${AVAILABLE_PHP_VERSIONS[@]}"; do
        if [[ -n "${OPCACHE_MEMORY_OVERRIDES[$version]:-}" && -z "${seen[$version]:-}" ]]; then
            printf '%s\n' "$version"
        fi
    done
}

opcache_runtime_socket() {
    local version="$1" i socket
    for ((i = 1; i <= SITE_COUNT; i++)); do
        [[ "${SITE_PHP_VERSIONS[$i]}" == "$version" ]] || continue
        socket="$(site_pool_socket "${SITE_DOMAINS[$i]}")"
        if [[ -S "$socket" ]]; then printf '%s' "$socket"; return 0; fi
    done
    socket="/run/php/php${version}-fpm.sock"
    [[ -S "$socket" ]] || return 1
    printf '%s' "$socket"
}

opcache_runtime_json() {
    local socket probe_dir response result
    command -v cgi-fcgi >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 1
    socket="$(opcache_runtime_socket "$1")" || return 1
    probe_dir="$(mktemp -d /run/wp-shell-opcache.XXXXXX)" || return 1
    # A local FastCGI probe outside every document root, not a public HTTP endpoint.
    if ! {
        chmod 0755 "$probe_dir" &&
        cat > "$probe_dir/status.php" <<'PHP' &&
<?php
header('Content-Type: application/json');
$s = function_exists('opcache_get_status') ? opcache_get_status(false) : false;
if (!is_array($s)) { echo '{"available":false}'; exit; }
$m = $s['memory_usage']; $i = $s['interned_strings_usage']; $t = $s['opcache_statistics'];
echo json_encode([
    'available' => true, 'enabled' => $s['opcache_enabled'], 'full' => $s['cache_full'],
    'memory_mb' => (int)ini_get('opcache.memory_consumption'),
    'strings_mb' => (int)ini_get('opcache.interned_strings_buffer'),
    'used_mb' => round($m['used_memory']/1048576, 1), 'free_mb' => round($m['free_memory']/1048576, 1),
    'wasted_mb' => round($m['wasted_memory']/1048576, 1),
    'strings_used_mb' => round($i['used_memory']/1048576, 1),
    'strings_free_mb' => round($i['free_memory']/1048576, 1),
    'scripts' => $t['num_cached_scripts'], 'keys' => $t['num_cached_keys'], 'max_keys' => $t['max_cached_keys'],
    'hit_rate' => round($t['opcache_hit_rate'], 2), 'oom_restarts' => $t['oom_restarts'],
    'hash_restarts' => $t['hash_restarts'], 'manual_restarts' => $t['manual_restarts'],
    'restart_pending' => $s['restart_pending'], 'restart_in_progress' => $s['restart_in_progress'],
    'start_time' => $t['start_time']
]);
opcache_invalidate(__FILE__, true);
PHP
        chmod 0644 "$probe_dir/status.php"
    }; then
        rm -f "$probe_dir/status.php"; rmdir "$probe_dir"
        return 1
    fi
    if ! response="$(env -i PATH="$PATH" SCRIPT_FILENAME="$probe_dir/status.php" SCRIPT_NAME=/status.php \
        REQUEST_METHOD=GET GATEWAY_INTERFACE=CGI/1.1 SERVER_PROTOCOL=HTTP/1.1 SERVER_NAME=localhost \
        REMOTE_ADDR=127.0.0.1 QUERY_STRING='' REDIRECT_STATUS=200 \
        timeout 10s cgi-fcgi -bind -connect "$socket" 2>/dev/null)"; then
        rm -f "$probe_dir/status.php"; rmdir "$probe_dir"
        return 1
    fi
    rm -f "$probe_dir/status.php"; rmdir "$probe_dir"
    result="$(printf '%s\n' "$response" | sed '1,/^\r\{0,1\}$/d' | jq -ce 'select(.available == true)')" || return 1
    printf '%s\n' "$result"
}

show_opcache_status() {
    local version="$1" desired effective runtime
    validate_php_version "$version" || die "Unsupported PHP version: $version"
    desired="$(opcache_values "$version")"
    printf 'PHP %s OPcache (shared by all pools in this FPM service)\n' "$version"
    printf 'Managed target (memory/strings MB): %s\n' "$desired"
    if effective="$(opcache_effective_values "$version")"; then
        printf 'Configuration on disk (memory/strings MB): %s\n' "$effective"
        [[ "$desired" == "$effective" ]] || log_message WARNING "Disk settings differ from the managed target; check INI precedence before applying."
    else
        printf 'Configuration on disk: unavailable\n'
    fi
    if runtime="$(opcache_runtime_json "$version")"; then
        jq -r '
            "Runtime (memory/strings MB): \(.memory_mb) \(.strings_mb)",
            "Enabled: \(.enabled) | Full: \(.full) | Hit rate: \(.hit_rate)%",
            "Memory: used \(.used_mb)MB | free \(.free_mb)MB | wasted \(.wasted_mb)MB",
            "Strings: used \(.strings_used_mb)MB | free \(.strings_free_mb)MB",
            "Cached scripts: \(.scripts) | Keys: \(.keys)/\(.max_keys)",
            "Restarts: OOM \(.oom_restarts) | hash \(.hash_restarts) | manual \(.manual_restarts)",
            "Restart pending: \(.restart_pending) | in progress: \(.restart_in_progress)",
            "Cache started (UTC): \(.start_time | todateiso8601)"
        ' <<< "$runtime"
        [[ "$(jq -r '[.memory_mb,.strings_mb] | join(" ")' <<< "$runtime")" == "$desired" ]] ||
            log_message WARNING "Running FPM settings differ from the managed target."
        if [[ "$(jq -r '.full or (.free_mb < 1) or (.strings_free_mb < 1)' <<< "$runtime")" == true ]]; then
            log_message WARNING "OPcache is full or nearly full; review memory headroom before increasing it."
        fi
    else
        printf 'Runtime: unavailable (check local FPM socket, libfcgi-bin, jq, or pool restrictions).\n'
    fi
}

set_opcache() {
    local version="$1" memory="$2" strings="$3" old effective total available reserve delta shared=0 candidate values
    local backup target had_ini=no had_config=no failed=no reload_attempted=no
    validate_php_version "$version" || die "Unsupported PHP version: $version"
    validate_opcache_values "$memory" "$strings" || die "Use memory 64-2048MB and strings 4-512MB, at most half of memory; use plain integers."
    [[ -d "$(opcache_scan_dir "$version")" ]] || die "PHP $version FPM is not installed."
    systemctl is-active --quiet "php${version}-fpm" || die "PHP $version FPM must be active before applying settings."
    old="$(opcache_effective_values "$version")" || die "Cannot read PHP $version FPM OPcache settings."
    for candidate in $(opcache_budget_versions); do
        [[ "$candidate" == "$version" ]] && continue
        values="$(opcache_values "$candidate")"
        shared=$((shared + ${values%% *}))
    done
    shared=$((shared + memory))
    total="$(memory_mb)"
    ((shared <= total / 4)) || die "Combined OPcache target ${shared}MB exceeds the safety limit of 25% of RAM."
    available="$(available_memory_mb)"
    reserve=$((total / 10)); ((reserve < 256)) && reserve=256
    delta=$((memory - ${old%% *}))
    if ((delta > 0)) && { [[ ! "$available" =~ ^[0-9]+$ ]] || ((available < delta + reserve)); }; then
        die "Not enough available RAM to increase OPcache while preserving ${reserve}MB headroom."
    fi
    target="$(opcache_managed_ini "$version")"
    if [[ -e "$target" || -L "$target" ]]; then
        if [[ ! -f "$target" || -L "$target" ]] || ! grep -Fxq '; Managed by wp-shell OPcache settings.' "$target"; then
            die "Refusing to replace unmanaged file: $target"
        fi
        had_ini=yes
    fi
    [[ ! -L "$OPCACHE_CONFIG_FILE" ]] || die "Refusing a symlinked OPcache state file."
    install -d -m 0700 "$CONFIG_DIR/opcache-backups"
    backup="$(mktemp -d "$CONFIG_DIR/opcache-backups/$(date +%Y%m%d-%H%M%S).XXXXXX")"
    [[ "$had_ini" == no ]] || cp -p "$target" "$backup/zz-wp-shell-opcache.ini"
    if [[ -f "$OPCACHE_CONFIG_FILE" ]]; then had_config=yes; cp -p "$OPCACHE_CONFIG_FILE" "$backup/opcache.v1"; fi
    printf 'PHP=%s\nPREVIOUS_MANAGED_INI=%s\nPREVIOUS_STATE=%s\n' "$version" "$had_ini" "$had_config" > "$backup/manifest"
    OPCACHE_MEMORY_OVERRIDES[$version]="$memory"
    OPCACHE_STRINGS_OVERRIDES[$version]="$strings"
    if ! write_opcache_ini "$version" "$memory" "$strings" || ! save_opcache_config ||
        ! "php-fpm$version" -t || ! effective="$(opcache_effective_values "$version")" || [[ "$effective" != "$memory $strings" ]]; then
        failed=yes
    else
        reload_attempted=yes
        php_fpm_service_action reload "$version" || failed=yes
    fi
    if [[ "$failed" == yes ]]; then
        if [[ "$had_ini" == yes ]]; then cp -p "$backup/zz-wp-shell-opcache.ini" "$target"; else rm -f "$target"; fi
        if [[ "$had_config" == yes ]]; then cp -p "$backup/opcache.v1" "$OPCACHE_CONFIG_FILE"; else rm -f "$OPCACHE_CONFIG_FILE"; fi
        load_opcache_config
        if [[ "$reload_attempted" == yes ]]; then
            if ! "php-fpm$version" -t || ! php_fpm_service_action reload "$version"; then
                log_message ERROR "Files restored, but FPM recovery needs attention. Backup: $backup"
            fi
        fi
        die "OPcache apply failed; previous files restored. Check FPM and INI overrides. Backup: $backup"
    fi
    log_message SUCCESS "Saved OPcache for PHP $version: ${memory}MB / strings ${strings}MB. FPM reload accepted. Backup: $backup"
    log_message INFO "All PHP $version sites share this cache. No Nginx, database, Redis, or pool limits changed."
    log_message INFO "Run: sudo wp-shell opcache status $version (runtime values may take a moment to switch)."
}

opcache_command() {
    local action="${1:-status}" version
    case "$action" in
        status)
            (($# <= 2)) || die "Usage: wp-shell opcache status [PHP_VERSION]"
            if [[ -n "${2:-}" ]]; then show_opcache_status "$2";
            else while IFS= read -r version; do show_opcache_status "$version"; done < <(opcache_budget_versions); fi
            ;;
        set) (($# == 4)) || die "Usage: wp-shell opcache set PHP_VERSION MEMORY_MB STRINGS_MB"; set_opcache "$2" "$3" "$4" ;;
        *) die "Usage: wp-shell opcache status [PHP_VERSION] | set PHP_VERSION MEMORY_MB STRINGS_MB" ;;
    esac
}

opcache_menu() {
    local version memory strings
    read -r -p "PHP version [$DEFAULT_PHP_VERSION]: " version
    version="${version:-$DEFAULT_PHP_VERSION}"
    show_opcache_status "$version"
    read -r -p "New OPcache memory in MB (leave empty to exit): " memory
    [[ -n "$memory" ]] || return 0
    read -r -p "Interned strings in MB: " strings
    set_opcache "$version" "$memory" "$strings"
}

migrate_legacy_vps_config() {
    local source="$LEGACY_VPS_CONFIG_DIR/sites.v2"
    [[ -f "$source" ]] || return 1
    local record domain php woo www redis_db admin_b64 email_b64 title_b64 path_b64 path mode
    while IFS='|' read -r record domain php woo www redis_db admin_b64 email_b64 title_b64 path_b64; do
        [[ "$record" == "site" ]] || continue
        validate_domain "$domain" || die "Invalid domain in legacy configuration: $domain"
        site_index_by_domain "$domain" >/dev/null 2>&1 && continue
        path="/var/www/$domain/public"
        [[ -n "$path_b64" ]] && path="$(b64_decode "$path_b64")"
        mode="managed"
        [[ "$path" == "/var/www/$domain/public" ]] || mode="imported"
        SITE_COUNT=$((SITE_COUNT + 1))
        SITE_DOMAINS[SITE_COUNT]="$domain"
        SITE_PRIMARY_DOMAINS[SITE_COUNT]="$domain"
        SITE_PHP_VERSIONS[SITE_COUNT]="$php"
        SITE_WOOCOMMERCE[SITE_COUNT]="$woo"
        SITE_WWW[SITE_COUNT]="$www"
        SITE_REDIS_DATABASES[SITE_COUNT]="$redis_db"
        SITE_MODES[SITE_COUNT]="$mode"
        SITE_ADMIN_USERS[SITE_COUNT]="$(b64_decode "$admin_b64")"
        SITE_ADMIN_EMAILS[SITE_COUNT]="$(b64_decode "$email_b64")"
        SITE_TITLES[SITE_COUNT]="$(b64_decode "$title_b64")"
        SITE_PATHS[SITE_COUNT]="$path"
    done < "$source"
    return 0
}

migrate_legacy_single_config() {
    local source="$LEGACY_SINGLE_CONFIG_DIR/site.v2"
    [[ -f "$source" ]] || return 1
    local record version domain primary www php woo title_b64 email_b64 user_b64 redis_db
    IFS='|' read -r record version domain primary www php woo title_b64 email_b64 user_b64 < "$source"
    [[ "$record" == "site" && "$version" == "2" ]] || die "Invalid legacy single-site configuration."
    validate_domain "$domain" || die "Invalid domain in legacy single-site configuration: $domain"
    if site_index_by_domain "$domain" >/dev/null 2>&1; then
        return 0
    fi
    LEGACY_SINGLE_DOMAIN="$domain"
    if [[ "$primary" != "$domain" && "$primary" != "www.$domain" ]]; then
        primary="$domain"
    fi
    [[ "$primary" == "www.$domain" ]] && www=yes
    redis_db="$(first_available_redis_database)" || die "No Redis database is available for $domain"
    SITE_COUNT=$((SITE_COUNT + 1))
    SITE_DOMAINS[SITE_COUNT]="$domain"
    SITE_PRIMARY_DOMAINS[SITE_COUNT]="$primary"
    SITE_PHP_VERSIONS[SITE_COUNT]="$php"
    SITE_WOOCOMMERCE[SITE_COUNT]="$woo"
    SITE_WWW[SITE_COUNT]="$www"
    SITE_REDIS_DATABASES[SITE_COUNT]="$redis_db"
    SITE_MODES[SITE_COUNT]="managed"
    SITE_ADMIN_USERS[SITE_COUNT]="$(b64_decode "$user_b64")"
    SITE_ADMIN_EMAILS[SITE_COUNT]="$(b64_decode "$email_b64")"
    SITE_TITLES[SITE_COUNT]="$(b64_decode "$title_b64")"
    SITE_PATHS[SITE_COUNT]="/var/www/$domain/public"
}

migrate_legacy_configs() {
    [[ -f "$SITES_CONFIG_FILE" ]] && return 0
    reset_sites
    local migrated="no" timestamp backup_dir database_file
    migrate_legacy_vps_config && migrated="yes"
    migrate_legacy_single_config && migrated="yes"
    [[ "$migrated" == "yes" ]] || return 0

    timestamp="$(date +%Y%m%d-%H%M%S)"
    backup_dir="$CONFIG_DIR/migration-backup/$timestamp"
    install -d -m 0700 "$backup_dir"
    [[ -d "$LEGACY_VPS_CONFIG_DIR" ]] && cp -a "$LEGACY_VPS_CONFIG_DIR" "$backup_dir/wp-vps-manager"
    [[ -d "$LEGACY_SINGLE_CONFIG_DIR" ]] && cp -a "$LEGACY_SINGLE_CONFIG_DIR" "$backup_dir/wp-single-deploy"

    for database_file in "$LEGACY_VPS_CONFIG_DIR"/databases/*.v1; do
        [[ -f "$database_file" ]] || continue
        install_private_file "$database_file" "$DATABASE_CONFIG_DIR/$(basename "$database_file")"
    done
    if [[ -f "$LEGACY_SINGLE_CONFIG_DIR/database.v1" ]]; then
        [[ -n "$LEGACY_SINGLE_DOMAIN" && ! -f "$DATABASE_CONFIG_DIR/$LEGACY_SINGLE_DOMAIN.v1" ]] && install_private_file \
            "$LEGACY_SINGLE_CONFIG_DIR/database.v1" \
            "$DATABASE_CONFIG_DIR/$LEGACY_SINGLE_DOMAIN.v1"
    fi
    if [[ ! -f "$REDIS_SECRET_FILE" ]]; then
        if [[ -f "$LEGACY_VPS_CONFIG_DIR/redis.secret" ]]; then
            install_private_file "$LEGACY_VPS_CONFIG_DIR/redis.secret" "$REDIS_SECRET_FILE"
        elif [[ -f "$LEGACY_SINGLE_CONFIG_DIR/redis.secret" ]]; then
            install_private_file "$LEGACY_SINGLE_CONFIG_DIR/redis.secret" "$REDIS_SECRET_FILE"
        fi
    fi
    save_sites_config
    log_message SUCCESS "Migrated $SITE_COUNT site(s) to $SITES_CONFIG_FILE. Legacy files were preserved in $backup_dir."
}

memory_mb() {
    awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo
}

swap_memory_mb() {
    awk '/^SwapTotal:/ {print int($2 / 1024)}' /proc/meminfo
}

cpu_count() {
    nproc
}

max_sites_for_memory() {
    local total_mem="$1"
    if ((total_mem < 2048)); then
        printf '1'
    elif ((total_mem < 4096)); then
        printf '2'
    elif ((total_mem < 8192)); then
        printf '4'
    else
        printf '8'
    fi
}

calculate_resource_budget() {
    local total_mem site_count os_reserve cache_reserve available version opcache redis_override
    total_mem="$(memory_mb)"
    site_count="${SITE_COUNT:-1}"
    ((site_count < 1)) && site_count=1
    ((total_mem >= 1024)) || die "At least 1GB of memory is required. Detected: ${total_mem}MB"

    os_reserve=$((total_mem * 25 / 100))
    ((os_reserve < 384)) && os_reserve=384
    if [[ "$ENVIRONMENT_MODE" == "single" ]]; then
        MARIADB_BUFFER_MB=$((total_mem * 35 / 100))
    else
        MARIADB_BUFFER_MB=$((total_mem * 30 / 100))
    fi
    ((MARIADB_BUFFER_MB < 192)) && MARIADB_BUFFER_MB=192
    ((MARIADB_BUFFER_MB > 4096)) && MARIADB_BUFFER_MB=4096
    REDIS_MAX_MEMORY_MB=$((total_mem * 5 / 100))
    ((REDIS_MAX_MEMORY_MB < 32)) && REDIS_MAX_MEMORY_MB=32
    ((REDIS_MAX_MEMORY_MB > 512)) && REDIS_MAX_MEMORY_MB=512
    redis_override="${WP_SHELL_REDIS_MAX_MEMORY_MB:-$(host_policy_value redis-maxmemory '')}"
    if [[ -n "$redis_override" ]]; then
        if [[ ! "$redis_override" =~ ^[1-9][0-9]{1,3}$ ]] || ((redis_override < 32 || redis_override > 512)); then
            die "Redis maxmemory override must be 32-512MB."
        fi
        REDIS_MAX_MEMORY_MB="$redis_override"
    elif ((total_mem >= 1800 && total_mem <= 2300)); then
        REDIS_MAX_MEMORY_MB=96
    fi
    cache_reserve=$((site_count * 16))
    OPCACHE_TOTAL_BUDGET_MB=0
    while IFS= read -r version; do
        opcache="$(opcache_values "$version")"
        OPCACHE_TOTAL_BUDGET_MB=$((OPCACHE_TOTAL_BUDGET_MB + ${opcache%% *}))
    done < <(opcache_budget_versions)
    available=$((total_mem - os_reserve - MARIADB_BUFFER_MB - REDIS_MAX_MEMORY_MB - cache_reserve - OPCACHE_TOTAL_BUDGET_MB))
    PHP_TOTAL_BUDGET_MB=$available
    ((PHP_TOTAL_BUDGET_MB < 192)) && PHP_TOTAL_BUDGET_MB=192
    if ((PHP_TOTAL_BUDGET_MB > total_mem * 35 / 100)); then
        PHP_TOTAL_BUDGET_MB=$((total_mem * 35 / 100))
    fi
    # With one ondemand pool, a 2GB host that also has at least 1GB swap can use
    # an eight-worker starting ceiling while retaining the normal evidence tuner.
    if ((total_mem >= 1800 && total_mem <= 2300 && site_count == 1 && $(swap_memory_mb) >= 1024 && PHP_TOTAL_BUDGET_MB < 768)); then
        PHP_TOTAL_BUDGET_MB=768
    fi

    calculate_site_php_allocations
    if [[ "${1:-}" != "quiet" ]]; then
        log_message INFO "Resource budget: OS reserve ${os_reserve}MB, MariaDB ${MARIADB_BUFFER_MB}MB, Redis ${REDIS_MAX_MEMORY_MB}MB, shared OPcache ${OPCACHE_TOTAL_BUDGET_MB}MB, PHP-FPM workers ${PHP_TOTAL_BUDGET_MB}MB."
        if ((available < 192)); then
            log_message WARNING "Minimum PHP worker allowance exceeds the remaining budget; reduce services/sites or add RAM."
        fi
    fi
}

calculate_site_php_allocations() {
    local process_memory=96 total_slots total_weight=0 i weight children
    SITE_PHP_MAX_CHILDREN=()
    ((SITE_COUNT > 0)) || return 0
    total_slots=$((PHP_TOTAL_BUDGET_MB / process_memory))
    ((total_slots < SITE_COUNT * 2)) && total_slots=$((SITE_COUNT * 2))
    for ((i = 1; i <= SITE_COUNT; i++)); do
        weight=1
        [[ "${SITE_WOOCOMMERCE[$i]}" == "yes" ]] && weight=2
        total_weight=$((total_weight + weight))
    done
    for ((i = 1; i <= SITE_COUNT; i++)); do
        weight=1
        [[ "${SITE_WOOCOMMERCE[$i]}" == "yes" ]] && weight=2
        children=$((total_slots * weight / total_weight))
        ((children < 2)) && children=2
        ((children > 50)) && children=50
        if [[ -n "${PHP_CHILD_OVERRIDES[${SITE_DOMAINS[$i]}]:-}" ]]; then
            children="${PHP_CHILD_OVERRIDES[${SITE_DOMAINS[$i]}]}"
        fi
        SITE_PHP_MAX_CHILDREN[i]="$children"
    done
}

check_capacity() {
    local total_mem max_sites available_gb
    total_mem="$(memory_mb)"
    max_sites="$(max_sites_for_memory "$total_mem")"
    available_gb="$(df -Pm / | awk 'NR == 2 {print int($4 / 1024)}')"
    ((available_gb >= 8)) || die "At least 8GB of free root disk space is required. Detected: ${available_gb}GB"
    ((SITE_COUNT <= max_sites)) || die "This server is limited to $max_sites managed site(s) by the current memory policy. Configured: $SITE_COUNT"
    log_message INFO "Server: ${total_mem}MB RAM, $(cpu_count) CPU core(s), ${available_gb}GB free disk, site limit $max_sites."
}

apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Use-Pty=0 install -y --no-install-recommends "$@"
}

ensure_php_repository() {
    local version="$1"
    if ! apt-cache show "php${version}-fpm" >/dev/null 2>&1; then
        apt_install software-properties-common ca-certificates gnupg
        add-apt-repository -y ppa:ondrej/php
        apt-get update
    fi
}

unique_php_versions() {
    local -A seen=()
    local i version
    if validate_php_version "$DEFAULT_PHP_VERSION"; then
        seen["$DEFAULT_PHP_VERSION"]=1
        printf '%s\n' "$DEFAULT_PHP_VERSION"
    fi
    for ((i = 1; i <= SITE_COUNT; i++)); do
        version="${SITE_PHP_VERSIONS[$i]}"
        if [[ -z "${seen[$version]:-}" ]]; then
            seen[$version]=1
            printf '%s\n' "$version"
        fi
    done
}

install_wp_cli() {
    local current_version="" temp_dir download_url fingerprint
    if command -v wp >/dev/null 2>&1; then
        current_version="$(wp --allow-root cli version 2>/dev/null | awk '{print $2}' || true)"
    fi
    [[ "$current_version" == "$WP_CLI_VERSION" && "${1:-}" != --verify ]] && return 0

    require_command gpg
    temp_dir="$(mktemp -d /tmp/wp-cli.XXXXXX)"
    download_url="https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar"
    (
        trap 'rm -rf -- "$temp_dir"' EXIT
        install -d -m 0700 "$temp_dir/gnupg"
        curl --fail --location --retry 3 --proto '=https' --tlsv1.2 --output "$temp_dir/wp.phar" "$download_url"
        curl --fail --location --retry 3 --proto '=https' --tlsv1.2 --output "$temp_dir/wp.asc" "$download_url.asc"
        curl --fail --location --retry 3 --proto '=https' --tlsv1.2 --output "$temp_dir/wp.pgp" https://raw.githubusercontent.com/wp-cli/builds/gh-pages/wp-cli.pgp
        fingerprint="$(gpg --homedir "$temp_dir/gnupg" --batch --with-colons --show-keys "$temp_dir/wp.pgp" | awk -F: '$1=="fpr" {print $10; exit}')"
        [[ "$fingerprint" == 63AF7AA15067C05616FDDD88A3A2E8F226F0BC06 ]] || die "WP-CLI signing key fingerprint mismatch; download was not executed."
        gpg --homedir "$temp_dir/gnupg" --batch --import "$temp_dir/wp.pgp"
        gpg --homedir "$temp_dir/gnupg" --batch --verify "$temp_dir/wp.asc" "$temp_dir/wp.phar" || die "WP-CLI signature verification failed; download was not executed."
        php "$temp_dir/wp.phar" --info >/dev/null
        write_managed_file /usr/local/bin/wp 0755 root root < "$temp_dir/wp.phar"
    )
}

install_system_packages() {
    CURRENT_STEP="install system packages"
    apt-get update
    apt_install ca-certificates curl gnupg openssl unzip rsync dnsutils sudo python3 sqlite3 jq libfcgi-bin nginx mariadb-server mariadb-client redis-server certbot fail2ban ufw

    local version
    while IFS= read -r version; do
        [[ -n "$version" ]] || continue
        ensure_php_repository "$version"
        apt_install \
            "php${version}-fpm" "php${version}-cli" "php${version}-mysql" \
            "php${version}-curl" "php${version}-gd" "php${version}-mbstring" \
            "php${version}-xml" "php${version}-zip" "php${version}-intl" \
            "php${version}-bcmath" "php${version}-imagick" "php${version}-redis"
    done < <(unique_php_versions)
    install_wp_cli
}

site_pool_id() {
    printf 'wp_%s' "$(printf '%s' "$1" | sha256sum | cut -c1-12)"
}

site_pool_socket() {
    printf '/run/php/%s.sock' "$(site_pool_id "$1")"
}

site_pool_status_socket() {
    printf '/run/php/%s-status.sock' "$(site_pool_id "$1")"
}

site_run_user() {
    local value uid
    value="$(site_policy_value "$1" user www-data)"
    [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ && "$value" != root ]] || die "Invalid non-root site identity for $1."
    uid="$(id -u "$value" 2>/dev/null)" || die "Missing site account: $value"
    [[ "$uid" =~ ^[1-9][0-9]*$ ]] || die "A site must not run with UID 0."
    printf '%s' "$value"
}

create_site_identity() {
    local domain="$1" user_id
    user_id="$(site_pool_id "$domain")"
    if id "$user_id" >/dev/null 2>&1; then
        [[ "$(getent passwd "$user_id" | cut -d: -f6)" == "/var/www/$domain" ]] || die "Site account name collision: $user_id"
    else
        useradd --system --user-group --home-dir "/var/www/$domain" --shell /usr/sbin/nologin "$user_id"
    fi
    set_site_policy "$domain" user "$user_id"
}

isolate_site() (
    local index="$1" assume_yes="${2:-}" domain wp_path old_user new_user version pool_file stage success=no
    local -a permission_paths=()
    domain="${SITE_DOMAINS[$index]}"
    wp_path="$(site_wp_path "$domain")"
    [[ "${SITE_MODES[$index]}" == managed && "$wp_path" == "/var/www/$domain/public" && ! -L "$wp_path" ]] || die "UID migration only supports the managed public-directory layout."
    old_user="$(site_run_user "$domain")"
    new_user="$(site_pool_id "$domain")"
    [[ "$old_user" != "$new_user" ]] || { log_message INFO "$domain already uses its own PHP user."; return 0; }
    grep -Fq '.wp-shell-maintenance' "/etc/nginx/sites-available/$domain" || die "Apply the new Nginx template before migrating: wp-shell site $domain nginx-apply"
    [[ ! -e "/var/www/$domain/.wp-shell-maintenance" ]] || die "Site is already in maintenance mode; finish that operation first."
    if [[ "$assume_yes" != --yes ]]; then
        collect_yes_no "Back up $domain, briefly enable maintenance and migrate its PHP/filesystem user (Redis remains separate)" no || return 0
    fi
    require_command getfacl
    require_command setfacl
    backup_site "$index" >/dev/null || exit 1
    version="${SITE_PHP_VERSIONS[$index]}"
    pool_file="/etc/php/$version/fpm/pool.d/wp-shell-$(site_pool_id "$domain").conf"
    [[ -f "$pool_file" ]] || die "Managed PHP pool configuration is missing."
    stage="$(mktemp -d "$STATE_DIR/.isolation.XXXXXX")" || exit 1
    cp -a "$pool_file" "$stage/pool.conf" || { rm -rf -- "$stage"; exit 1; }
    permission_paths=("$wp_path" "/var/www/$domain/logs" "$(site_wp_cli_home "$domain")")
    if [[ -d "/var/www/$domain/.wp-shell" ]]; then permission_paths+=("/var/www/$domain/.wp-shell"); fi
    getfacl -R --absolute-names "${permission_paths[@]}" > "$stage/permissions.acl" || { rm -rf -- "$stage"; exit 1; }
    # shellcheck disable=SC2317,SC2329
    cleanup_isolation() {
        local rollback_ok=yes
        if [[ "$success" != yes ]]; then
            set_site_policy "$domain" user "$old_user" || rollback_ok=no
            cp -a "$stage/pool.conf" "$pool_file" || rollback_ok=no
            setfacl --restore="$stage/permissions.acl" || rollback_ok=no
            php_fpm_service_action reload "$version" || rollback_ok=no
            if [[ "$rollback_ok" != yes ]]; then
                log_message ERROR "UID migration rollback is incomplete. Maintenance remains enabled; inspect $stage and the safety backup."
                return 1
            fi
            log_message WARNING "UID migration failed; previous pool/permissions restored. Safety backup retained."
        fi
        rm -f -- "/var/www/$domain/.wp-shell-maintenance"
        rm -rf -- "$stage"
    }
    trap cleanup_isolation EXIT
    install -m 0600 /dev/null "/var/www/$domain/.wp-shell-maintenance" || exit 1
    create_site_identity "$domain" || exit 1
    set_site_permissions "$domain" || exit 1
    chown -R "$new_user":"$(id -gn "$new_user")" "$(site_wp_cli_home "$domain")" || exit 1
    if [[ -d "/var/www/$domain/.wp-shell" ]]; then chown -R "$new_user":"$(id -gn "$new_user")" "/var/www/$domain/.wp-shell" || exit 1; fi
    sed -E "s/^user[[:space:]]*=.*/user = $new_user/; s/^group[[:space:]]*=.*/group = $new_user/" "$stage/pool.conf" > "$stage/new-pool.conf" || exit 1
    install -m 0644 "$stage/new-pool.conf" "$pool_file" || exit 1
    "php-fpm$version" -t || exit 1
    php_fpm_service_action reload "$version" || exit 1
    site_wp_cli "$domain" core is-installed || exit 1
    success=yes
    log_message SUCCESS "$domain now uses $new_user and root-owned wp-config.php mode 640 with its private group. Redis isolation is a separate opt-in."
)

configure_php() {
    CURRENT_STEP="configure PHP-FPM"
    calculate_resource_budget
    local version memory_limit i domain pool_id pool_file max_children opcache_memory opcache_strings values run_user run_group
    local -A before=()
    memory_limit="256M"
    (( $(memory_mb) >= 4096 )) && memory_limit="512M"

    while IFS= read -r version; do
        [[ -n "$version" ]] || continue
        before[$version]="$(php_config_fingerprint "$version")"
        install -d -m 0755 "/etc/php/$version/fpm/pool.d" "/etc/php/$version/fpm/conf.d"
        transaction_begin "$CURRENT_STEP"
        transaction_mark_service "php:$version"
        values="$(opcache_values "$version")"
        read -r opcache_memory opcache_strings <<< "$values"
        OPCACHE_MEMORY_OVERRIDES[$version]="$opcache_memory"
        OPCACHE_STRINGS_OVERRIDES[$version]="$opcache_strings"
        write_opcache_ini "$version" "$opcache_memory" "$opcache_strings"
        write_managed_file "/etc/php/$version/fpm/pool.d/99-wp-shell.conf" 0644 root root <<EOF
; Managed by wp-shell. Keep the distribution pool available with minimal idle use.
[www]
pm = ondemand
pm.max_children = 2
pm.process_idle_timeout = 20s
pm.max_requests = 300
EOF
        write_managed_file "/etc/php/$version/fpm/conf.d/99-wp-shell.ini" 0644 root root <<EOF
; Managed by wp-shell.
memory_limit = $memory_limit
max_execution_time = 120
max_input_time = 120
upload_max_filesize = 16M
post_max_size = 20M
max_file_uploads = 20
display_errors = Off
log_errors = On
expose_php = Off
opcache.enable = 1
opcache.memory_consumption = $opcache_memory
opcache.interned_strings_buffer = $opcache_strings
opcache.max_accelerated_files = 20000
opcache.validate_timestamps = 1
opcache.revalidate_freq = 2
opcache.jit = disable
opcache.jit_buffer_size = 0
EOF
    done < <(unique_php_versions)
    save_opcache_config

    for ((i = 1; i <= SITE_COUNT; i++)); do
        domain="${SITE_DOMAINS[$i]}"
        version="${SITE_PHP_VERSIONS[$i]}"
        pool_id="$(site_pool_id "$domain")"
        pool_file="/etc/php/$version/fpm/pool.d/wp-shell-${pool_id}.conf"
        max_children="${SITE_PHP_MAX_CHILDREN[$i]}"
        run_user="$(site_run_user "$domain")"
        run_group="$(id -gn "$run_user")"
        install -d -o "$run_user" -g www-data -m 0750 "/var/www/$domain/logs"
        write_managed_file "$pool_file" 0644 root root <<EOF
; Managed by wp-shell for $domain.
[$pool_id]
user = $run_user
group = $run_group
listen = $(site_pool_socket "$domain")
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = $max_children
pm.process_idle_timeout = 20s
pm.max_requests = 300
pm.status_path = /status
pm.status_listen = $(site_pool_status_socket "$domain")
ping.path = /ping
request_terminate_timeout = 120s
request_slowlog_timeout = 5s
slowlog = /var/www/$domain/logs/php-fpm-slow.log
catch_workers_output = yes
php_admin_flag[log_errors] = on
php_admin_value[error_log] = /var/www/$domain/logs/php-error.log
EOF
    done

    while IFS= read -r version; do
        [[ -n "$version" ]] || continue
        "php-fpm${version}" -t || return 1
        values="$(opcache_values "$version")"
        [[ "$(opcache_effective_values "$version")" == "$values" ]] || die "PHP $version OPcache settings are overridden by another INI file; FPM was not restarted."
        systemctl enable "php${version}-fpm"
        if systemctl is-active --quiet "php${version}-fpm"; then
            if [[ "${before[$version]}" != "$(php_config_fingerprint "$version")" ]]; then
                php_fpm_service_action reload "$version" || return 1
            fi
        else
            php_fpm_service_action start "$version" || return 1
        fi
    done < <(unique_php_versions)
    if ((SITE_COUNT > 0)); then
        log_message SUCCESS "Configured one PHP-FPM pool per site within a shared ${PHP_TOTAL_BUDGET_MB}MB budget."
    else
        log_message SUCCESS "Configured PHP ${DEFAULT_PHP_VERSION}-FPM. Site pools will be created when websites are added."
    fi
}

php_config_fingerprint() {
    local version="$1"
    find "/etc/php/$version/fpm" -maxdepth 2 -type f \( -name '*wp-shell*' -o -name 'php-fpm.conf' \) -print0 2>/dev/null |
        sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1
}

mariadb_config_root_is_safe() {
    [[ "$MARIADB_CONFIG_ROOT" == /* && "$MARIADB_CONFIG_ROOT" != *$'\n'* && "$MARIADB_CONFIG_ROOT" != *'/../'* && "$MARIADB_CONFIG_ROOT" != */.. ]] || return 1
    [[ "$MARIADB_CONFIG_ROOT" == /etc/mysql ]] ||
        [[ "${WP_SHELL_TEST_ROOT_WRITES:-no}" == yes && "$MARIADB_CONFIG_ROOT" == /tmp/* ]]
}

mariadb_audit_variables() {
    printf '%s\n' \
        innodb_buffer_pool_size max_connections tmp_table_size max_heap_table_size \
        sort_buffer_size join_buffer_size read_buffer_size read_rnd_buffer_size thread_stack
}

mariadb_audit_status_names() {
    printf '%s\n' \
        max_used_connections threads_connected threads_running \
        created_tmp_tables created_tmp_disk_tables
}

mariadb_config_files() {
    local file directory
    mariadb_config_root_is_safe || return 1
    {
        file="$MARIADB_CONFIG_ROOT/my.cnf"
        [[ -r "$file" ]] && printf '%s\n' "$file"
        for directory in "$MARIADB_CONFIG_ROOT/conf.d" "$MARIADB_CONFIG_ROOT/mariadb.conf.d"; do
            [[ -d "$directory" ]] || continue
            find -L "$directory" -maxdepth 1 -type f -name '*.cnf' -print 2>/dev/null | sort
        done
    } | awk '!seen[$0]++'
}

mariadb_definition_class() {
    local file="$1"
    case "$file" in
        "$MARIADB_CONFIG_ROOT"/conf.d/50-wordpress.cnf|"$MARIADB_CONFIG_ROOT"/mariadb.conf.d/50-wordpress.cnf)
            printf 'legacy-wp-shell'
            ;;
        "$MARIADB_MANAGED_CONFIG_FILE") printf 'wp-shell-managed' ;;
        *) printf 'administrator-or-distribution' ;;
    esac
}

mariadb_config_definitions() {
    local file class
    while IFS= read -r file; do
        [[ -r "$file" ]] || continue
        class="$(mariadb_definition_class "$file")"
        awk -v source_file="$file" -v source_class="$class" '
            function trim(value) {
                sub(/^[[:space:]]+/, "", value)
                sub(/[[:space:]]+$/, "", value)
                return value
            }
            /^[[:space:]]*\[/ {
                section=tolower($0)
                gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", section)
                active=(section ~ /^(mysqld|server|mariadb|mariadbd|client-server)([-.][0-9]+([.][0-9]+)*)?$/)
                next
            }
            active {
                line=$0
                sub(/^[[:space:]]+/, "", line)
                if (line ~ /^[#;]/ || index(line, "=") == 0) next
                key=tolower(substr(line, 1, index(line, "=")-1))
                key=trim(key)
                gsub(/-/, "_", key)
                sub(/^loose_/, "", key)
                if (key !~ /^(innodb_buffer_pool_size|max_connections|tmp_table_size|max_heap_table_size|sort_buffer_size|join_buffer_size|read_buffer_size|read_rnd_buffer_size|thread_stack)$/) next
                value=substr(line, index(line, "=")+1)
                sub(/[[:space:]]*[#;].*$/, "", value)
                value=trim(value)
                print key "|" value "|" source_file "|" NR "|" source_class
            }
        ' "$file"
    done < <(mariadb_config_files)
}

mariadb_normalize_value() {
    local variable="$1" raw="$2" upper multiplier=1 number
    raw="${raw#\"}"; raw="${raw%\"}"
    raw="${raw#\'}"; raw="${raw%\'}"
    upper="${raw^^}"
    case "$variable" in
        innodb_buffer_pool_size|tmp_table_size|max_heap_table_size|sort_buffer_size|join_buffer_size|read_buffer_size|read_rnd_buffer_size|thread_stack)
            if [[ "$upper" =~ ^([0-9]+)([KMGT])?B?$ ]]; then
                number="${BASH_REMATCH[1]}"
                case "${BASH_REMATCH[2]:-}" in
                    K) multiplier=1024 ;;
                    M) multiplier=$((1024 * 1024)) ;;
                    G) multiplier=$((1024 * 1024 * 1024)) ;;
                    T) multiplier=$((1024 * 1024 * 1024 * 1024)) ;;
                esac
                printf '%s' "$((number * multiplier))"
                return 0
            fi
            ;;
        max_connections)
            [[ "$upper" =~ ^[0-9]+$ ]] && { printf '%s' "$upper"; return 0; }
            ;;
    esac
    return 1
}

mariadb_snapshot_value() {
    local snapshot="$1" variable="$2"
    awk -F'|' -v wanted="$variable" '$1==wanted {print $2; exit}' <<< "$snapshot"
}

mariadb_config_effective_snapshot() {
    local defaults_file="$MARIADB_CONFIG_ROOT/my.cnf" output snapshot count
    mariadb_config_root_is_safe || return 1
    [[ -r "$defaults_file" ]] || return 1
    output="$(mariadbd --defaults-file="$defaults_file" --verbose --help 2>/dev/null)" || return 1
    snapshot="$(awk '
        {
            key=tolower($1)
            gsub(/-/, "_", key)
            if (key ~ /^(innodb_buffer_pool_size|max_connections|tmp_table_size|max_heap_table_size|sort_buffer_size|join_buffer_size|read_buffer_size|read_rnd_buffer_size|thread_stack)$/) {
                print key "|" $2
            }
        }
    ' <<< "$output")"
    count="$(wc -l <<< "$snapshot")"
    ((count == 9)) || return 1
    printf '%s\n' "$snapshot"
}

mariadb_runtime_snapshot() {
    local output snapshot variable_count status_count
    output="$(timeout 5s mariadb --protocol=socket --connect-timeout=3 --batch --skip-column-names --execute="
SHOW GLOBAL VARIABLES WHERE Variable_name IN ('innodb_buffer_pool_size','max_connections','tmp_table_size','max_heap_table_size','sort_buffer_size','join_buffer_size','read_buffer_size','read_rnd_buffer_size','thread_stack');
SHOW GLOBAL STATUS WHERE Variable_name IN ('Max_used_connections','Threads_connected','Threads_running','Created_tmp_tables','Created_tmp_disk_tables');
" 2>/dev/null)" || return 1
    snapshot="$(awk -F'\t' 'NF >= 2 {key=tolower($1); gsub(/-/, "_", key); print key "|" $2}' <<< "$output")"
    variable_count="$(while IFS= read -r variable; do grep -c "^${variable}|" <<< "$snapshot"; done < <(mariadb_audit_variables) | awk '{sum+=$1} END{print sum+0}')"
    status_count="$(while IFS= read -r variable; do grep -c "^${variable}|" <<< "$snapshot"; done < <(mariadb_audit_status_names) | awk '{sum+=$1} END{print sum+0}')"
    ((variable_count == 9 && status_count == 5)) || return 1
    printf '%s\n' "$snapshot"
}

mariadb_likely_source() {
    local variable="$1" effective="$2" definitions="$3" key raw file line _class normalized likely="server default/runtime"
    while IFS='|' read -r key raw file line _class; do
        [[ "$key" == "$variable" ]] || continue
        normalized="$(mariadb_normalize_value "$variable" "$raw" 2>/dev/null || true)"
        [[ -n "$normalized" && "$normalized" == "$effective" ]] && likely="$file:$line"
    done <<< "$definitions"
    printf '%s' "$likely"
}

mariadb_display_value() {
    local variable="$1" value="$2"
    case "$variable" in
        innodb_buffer_pool_size|tmp_table_size|max_heap_table_size|sort_buffer_size|join_buffer_size|read_buffer_size|read_rnd_buffer_size|thread_stack)
            [[ "$value" =~ ^[0-9]+$ ]] && printf '%s bytes (%s MiB)' "$value" "$((value / 1024 / 1024))" || printf '%s' "$value"
            ;;
        *) printf '%s' "$value" ;;
    esac
}

mariadb_safe_definition_value() {
    local variable="$1" raw="$2"
    if mariadb_normalize_value "$variable" "$raw" >/dev/null 2>&1; then
        printf '%s' "$raw"
    else
        printf '<unparsed>'
    fi
}

mariadb_high_risk_reasons() {
    local snapshot="$1" total_mb total_bytes pool max_connections tmp heap sort join read read_rnd stack tmp_cap per_connection exposure value
    total_mb="$(memory_mb)"
    [[ "$total_mb" =~ ^[0-9]+$ && "$total_mb" -gt 0 ]] || return 0
    total_bytes=$((total_mb * 1024 * 1024))
    pool="$(mariadb_snapshot_value "$snapshot" innodb_buffer_pool_size)"
    max_connections="$(mariadb_snapshot_value "$snapshot" max_connections)"
    tmp="$(mariadb_snapshot_value "$snapshot" tmp_table_size)"
    heap="$(mariadb_snapshot_value "$snapshot" max_heap_table_size)"
    sort="$(mariadb_snapshot_value "$snapshot" sort_buffer_size)"
    join="$(mariadb_snapshot_value "$snapshot" join_buffer_size)"
    read="$(mariadb_snapshot_value "$snapshot" read_buffer_size)"
    read_rnd="$(mariadb_snapshot_value "$snapshot" read_rnd_buffer_size)"
    stack="$(mariadb_snapshot_value "$snapshot" thread_stack)"
    for value in "$pool" "$max_connections" "$tmp" "$heap" "$sort" "$join" "$read" "$read_rnd" "$stack"; do
        [[ "$value" =~ ^[0-9]+$ ]] || return 0
    done
    ((tmp < heap)) && tmp_cap="$tmp" || tmp_cap="$heap"
    per_connection=$((tmp_cap + sort + join + read + read_rnd + stack))
    exposure=$((pool + max_connections * per_connection))
    if ((total_mb <= 4096 && pool * 2 >= total_bytes)); then
        printf 'InnoDB buffer pool is at least 50%% of physical RAM on a %sMiB host.\n' "$total_mb"
    fi
    if ((total_mb <= 4096 && max_connections >= 250 && tmp_cap >= 64 * 1024 * 1024)); then
        printf 'max_connections=%s combines with a per-connection temporary-table ceiling of at least 64MiB on a low-memory host.\n' "$max_connections"
    fi
    if ((total_mb <= 8192 && exposure > total_bytes * 4)); then
        printf 'The conservative connection-memory exposure indicator exceeds four times physical RAM; it is a risk signal, not a usage prediction.\n'
    fi
}

mariadb_definition_is_unsafe_for_migration() {
    local variable="$1" raw="$2" total_mb="${3:-}" normalized total_bytes
    [[ -n "$total_mb" ]] || total_mb="$(memory_mb)"
    [[ "$total_mb" =~ ^[0-9]+$ && "$total_mb" -le 4096 ]] || return 1
    normalized="$(mariadb_normalize_value "$variable" "$raw" 2>/dev/null || true)"
    [[ -n "$normalized" ]] || return 1
    total_bytes=$((total_mb * 1024 * 1024))
    case "$variable" in
        innodb_buffer_pool_size) ((normalized * 2 >= total_bytes)) ;;
        max_connections) ((normalized >= 250)) ;;
        tmp_table_size|max_heap_table_size) ((normalized >= 64 * 1024 * 1024)) ;;
        *) return 1 ;;
    esac
}

mariadb_unsafe_migratable_reasons() {
    local definitions="$1" total_mb key raw file line class
    total_mb="$(memory_mb)"
    [[ "$total_mb" =~ ^[0-9]+$ && "$total_mb" -le 4096 ]] || return 0
    while IFS='|' read -r key raw file line class; do
        [[ "$class" == legacy-wp-shell || "$class" == wp-shell-managed ]] || continue
        mariadb_definition_is_unsafe_for_migration "$key" "$raw" "$total_mb" || continue
        case "$key" in
            innodb_buffer_pool_size)
                printf '%s:%s defines %s=%s (at least 50%% of physical RAM).\n' "$file" "$line" "$key" "$raw"
                ;;
            max_connections)
                printf '%s:%s defines %s=%s on a low-memory host.\n' "$file" "$line" "$key" "$raw"
                ;;
            tmp_table_size|max_heap_table_size)
                printf '%s:%s defines %s=%s on a low-memory host.\n' "$file" "$line" "$key" "$raw"
                ;;
        esac
    done <<< "$definitions"
}

mariadb_apply_block_reason() {
    local definitions config_snapshot high_risk unsafe_legacy
    definitions="$(mariadb_config_definitions 2>/dev/null || true)"
    config_snapshot="$(mariadb_config_effective_snapshot 2>/dev/null || true)"
    [[ -n "$config_snapshot" ]] || { printf 'MariaDB effective configuration could not be determined; refusing a baseline apply that could restart the service.'; return 0; }
    unsafe_legacy="$(mariadb_unsafe_migratable_reasons "$definitions")"
    if [[ -n "$unsafe_legacy" ]]; then
        printf 'Unsafe legacy/wp-shell MariaDB definitions require explicit review:\n%s\nRun: wp-shell mariadb audit, then wp-shell mariadb migrate-legacy --confirm' "$unsafe_legacy"
        return 0
    fi
    high_risk="$(mariadb_high_risk_reasons "$config_snapshot")"
    if [[ -n "$high_risk" ]]; then
        printf 'MariaDB effective configuration has high-risk low-memory indicators:\n%s\nReview administrator-owned MariaDB files manually before apply.' "$high_risk"
    fi
}

mariadb_assert_apply_safe() {
    local reason
    reason="$(mariadb_apply_block_reason)"
    [[ -z "$reason" ]] || die "$reason"
}

mariadb_validate_fragment() {
    local candidate="$1"
    mariadbd --defaults-file="$candidate" --verbose --help >/dev/null 2>&1
}

mariadb_validate_installed_config() {
    mariadb_config_root_is_safe && [[ -r "$MARIADB_CONFIG_ROOT/my.cnf" ]] &&
        mariadbd --defaults-file="$MARIADB_CONFIG_ROOT/my.cnf" --verbose --help >/dev/null 2>&1
}

mariadb_health_check() {
    systemctl is-active --quiet mariadb &&
        timeout 10s mariadb --protocol=socket --connect-timeout=5 --batch --skip-column-names --execute='SELECT 1;' 2>/dev/null | grep -Fxq 1
}

mariadb_snapshots_match() {
    local configured="$1" runtime="$2" variable configured_value runtime_value
    while IFS= read -r variable; do
        configured_value="$(mariadb_snapshot_value "$configured" "$variable")"
        runtime_value="$(mariadb_snapshot_value "$runtime" "$variable")"
        [[ -n "$configured_value" && "$configured_value" == "$runtime_value" ]] || return 1
    done < <(mariadb_audit_variables)
}

mariadb_render_legacy_candidate() {
    local source="$1" destination="$2" class removal_mode unsafe_lines="" key raw file line definition_class
    class="$(mariadb_definition_class "$source")"
    case "$class" in
        legacy-wp-shell) removal_mode=legacy ;;
        wp-shell-managed)
            removal_mode='unsafe-managed'
            while IFS='|' read -r key raw file line definition_class; do
                [[ "$file" == "$source" && "$definition_class" == wp-shell-managed ]] || continue
                mariadb_definition_is_unsafe_for_migration "$key" "$raw" && unsafe_lines+="${line}"$'\n'
            done < <(mariadb_config_definitions)
            ;;
        *) return 1 ;;
    esac
    awk -v removal_mode="$removal_mode" -v unsafe_lines="$unsafe_lines" '
        BEGIN {
            count=split(unsafe_lines, lines, "\n")
            for (item=1; item<=count; item++) if (lines[item] != "") remove_line[lines[item]]=1
        }
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        /^[[:space:]]*\[/ {
            section=tolower($0)
            gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", section)
            active=(section ~ /^(mysqld|server|mariadb|mariadbd|client-server)([-.][0-9]+([.][0-9]+)*)?$/)
        }
        active {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            if (line !~ /^[#;]/ && index(line, "=") > 0) {
                key=tolower(substr(line, 1, index(line, "=")-1))
                key=trim(key)
                gsub(/-/, "_", key)
                sub(/^loose_/, "", key)
                removable=(key ~ /^(innodb_buffer_pool_size|max_connections|tmp_table_size|max_heap_table_size)$/)
                if (removable && (removal_mode == "legacy" || remove_line[NR])) {
                    reason=(removal_mode == "legacy" ? "legacy " : "unsafe managed ")
                    print "# wp-shell migration removed " reason key "; the exact prior file is in the transaction backup."
                    next
                }
            }
        }
        {print}
    ' "$source" > "$destination"
}

mariadb_migration_files() {
    printf '%s\n' \
        "$MARIADB_CONFIG_ROOT/conf.d/50-wordpress.cnf" \
        "$MARIADB_CONFIG_ROOT/mariadb.conf.d/50-wordpress.cnf" \
        "$MARIADB_MANAGED_CONFIG_FILE"
}

mariadb_audit() {
    local runtime_snapshot="" config_snapshot="" definitions variable runtime_value configured_value likely key raw file line class risk
    mariadb_config_root_is_safe || die "Unsafe MariaDB configuration root: $MARIADB_CONFIG_ROOT"
    runtime_snapshot="$(mariadb_runtime_snapshot 2>/dev/null || true)"
    config_snapshot="$(mariadb_config_effective_snapshot 2>/dev/null || true)"
    definitions="$(mariadb_config_definitions 2>/dev/null || true)"
    printf 'MariaDB effective configuration audit (read-only)\n'
    printf 'Physical RAM: %s MiB. Swap is not counted as MariaDB capacity.\n' "$(memory_mb)"
    printf '\n%-31s %-24s %-24s %s\n' Variable Runtime 'Configured next start' 'Likely definition'
    while IFS= read -r variable; do
        runtime_value="$(mariadb_snapshot_value "$runtime_snapshot" "$variable")"
        configured_value="$(mariadb_snapshot_value "$config_snapshot" "$variable")"
        likely="$(mariadb_likely_source "$variable" "${configured_value:-unknown}" "$definitions")"
        printf '%-31s %-24s %-24s %s\n' "$variable" \
            "$(mariadb_display_value "$variable" "${runtime_value:-UNKNOWN}")" \
            "$(mariadb_display_value "$variable" "${configured_value:-UNKNOWN}")" "$likely"
    done < <(mariadb_audit_variables)
    printf '\nLive status counters\n'
    while IFS= read -r variable; do
        runtime_value="$(mariadb_snapshot_value "$runtime_snapshot" "$variable")"
        printf '  %-31s %s\n' "$variable" "${runtime_value:-UNKNOWN}"
    done < <(mariadb_audit_status_names)
    printf '\nRelevant definitions under %s\n' "$MARIADB_CONFIG_ROOT"
    if [[ -n "$definitions" ]]; then
        while IFS='|' read -r key raw file line class; do
            printf '  %-31s %-12s %s:%s [%s]\n' "$key" "$(mariadb_safe_definition_value "$key" "$raw")" "$file" "$line" "$class"
        done <<< "$definitions"
    else
        printf '  No explicit definitions found; distribution/server defaults may be effective.\n'
    fi
    risk="$(mariadb_high_risk_reasons "${config_snapshot:-$runtime_snapshot}")"
    if [[ -n "$risk" ]]; then
        printf '\nHIGH-RISK indicators (admission is blocked; these are conservative indicators, not a memory-use proof):\n%s' "$risk"
    else
        printf '\nNo high-risk low-memory combination was identified by the conservative admission checks.\n'
    fi
    risk="$(mariadb_unsafe_migratable_reasons "$definitions")"
    if [[ -n "$risk" ]]; then
        printf '\nUnsafe legacy/wp-shell definitions detected:\n%s\n' "$risk"
        printf 'Explicit migration: wp-shell mariadb migrate-legacy --confirm\n'
    fi
}

mariadb_migrate_legacy() {
    local confirmation="${1:-}" before_config after_config runtime risk target candidate mode owner group changed=no restart_required=no
    local stage index=0
    local -a targets=() candidates=() modes=() owners=() groups=()
    mariadb_audit
    [[ "$confirmation" == --confirm ]] || die "Impact: remove the four historical memory directives from recognized 50-wordpress.cnf files, remove only individually unsafe definitions from the current wp-shell-managed file, preserve all other content, and restart MariaDB only if effective values change. Re-run with --confirm."
    CURRENT_STEP="migrate legacy MariaDB memory configuration"
    before_config="$(mariadb_config_effective_snapshot)" || die "Cannot determine the current effective MariaDB configuration. No files were changed."
    stage="$(safe_temp_dir)"
    register_temp_path "$stage"
    while IFS= read -r target; do
        [[ -e "$target" || -L "$target" ]] || continue
        [[ -f "$target" && ! -L "$target" ]] || die "Refusing to migrate a non-regular or symlinked MariaDB file: $target"
        index=$((index + 1))
        candidate="$stage/candidate-$index.cnf"
        mariadb_render_legacy_candidate "$target" "$candidate"
        cmp -s "$candidate" "$target" && continue
        mariadb_validate_fragment "$candidate" || die "MariaDB rejected the rendered candidate for $target. No files were changed."
        targets+=("$target")
        candidates+=("$candidate")
        modes+=("$(stat -c '%a' "$target")")
        owners+=("$(stat -c '%U' "$target")")
        groups+=("$(stat -c '%G' "$target")")
    done < <(mariadb_migration_files)
    if ((${#targets[@]} == 0)); then
        rm -rf -- "$stage"
        log_message INFO "No recognized legacy MariaDB memory directives require migration."
        return 0
    fi
    transaction_begin "$CURRENT_STEP"
    for ((index=0; index<${#targets[@]}; index++)); do
        write_managed_file "${targets[$index]}" "${modes[$index]}" "${owners[$index]}" "${groups[$index]}" < "${candidates[$index]}"
        changed=yes
    done
    mariadb_validate_installed_config || die "MariaDB rejected the complete migrated configuration; exact prior files were restored."
    after_config="$(mariadb_config_effective_snapshot)" || die "Cannot determine the migrated effective MariaDB configuration; exact prior files were restored."
    risk="$(mariadb_high_risk_reasons "$after_config")"
    [[ -z "$risk" ]] || die "Migration left high-risk effective values, likely in administrator-owned configuration. Exact prior files were restored. Review manually:\n$risk"
    if ! mariadb_snapshots_match "$before_config" "$after_config"; then restart_required=yes; fi
    if [[ "$restart_required" == yes ]]; then
        transaction_mark_service mariadb
        systemctl restart mariadb || die "MariaDB restart failed; exact prior files were restored and recovery was attempted."
        mariadb_health_check || die "MariaDB failed its post-restart health check; exact prior files were restored and recovery was attempted."
        runtime="$(mariadb_runtime_snapshot)" || die "MariaDB runtime values could not be read after restart; exact prior files were restored and recovery was attempted."
        mariadb_snapshots_match "$after_config" "$runtime" || die "MariaDB runtime values do not match the validated migrated configuration; exact prior files were restored."
    fi
    rm -rf -- "$stage"
    [[ "$changed" == yes ]] && log_message SUCCESS "Legacy MariaDB memory directives were migrated transactionally. Administrator-owned files and unrelated settings were preserved."
    [[ "$restart_required" == yes ]] || log_message INFO "Effective MariaDB values did not change; no restart was required."
}

mariadb_command() {
    case "${1:-audit}" in
        audit) (($# <= 1)) || die "Usage: wp-shell mariadb audit"; mariadb_audit ;;
        migrate-legacy) (($# == 2)) || die "Usage: wp-shell mariadb migrate-legacy --confirm"; mariadb_migrate_legacy "$2" ;;
        *) die "Usage: wp-shell mariadb audit | migrate-legacy --confirm" ;;
    esac
}

configure_mariadb() {
    CURRENT_STEP="configure MariaDB"
    local config_file temp_file preserved_tuning="" after_config runtime risk
    mariadb_assert_apply_safe
    config_file="$MARIADB_MANAGED_CONFIG_FILE"
    [[ -d "$(dirname "$config_file")" && ! -L "$(dirname "$config_file")" ]] || die "MariaDB configuration directory is missing or unsafe: $(dirname "$config_file")"
    temp_file="$(mktemp "$(dirname "$config_file")/.wp-shell.XXXXXX")"
    if [[ -f "$config_file" && ! -L "$config_file" ]]; then
        preserved_tuning="$(awk '
            /^[[:space:]]*(innodb_buffer_pool_size|max_connections|tmp_table_size|max_heap_table_size)[[:space:]]*=/ {
                if ($0 ~ /^[[:space:]]*[a-z_]+[[:space:]]*=[[:space:]]*[0-9]+[KkMmGg]?[Bb]?([[:space:]]*)$/) print
            }' "$config_file")"
    fi
    cat > "$temp_file" <<EOF
[mysqld]
bind-address = 127.0.0.1
innodb_file_per_table = 1
innodb_flush_log_at_trx_commit = 1
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
slow_query_log = 1
slow_query_log_file = /var/log/mysql/wp-shell-slow.log
long_query_time = 2
$preserved_tuning
EOF
    mariadb_validate_fragment "$temp_file" || {
        rm -f -- "$temp_file"
        die "MariaDB rejected the candidate configuration; no file was changed."
    }
    if [[ -f "$config_file" ]] && cmp -s "$temp_file" "$config_file" && systemctl is-active --quiet mariadb; then
        rm -f "$temp_file"
        log_message INFO "MariaDB configuration is unchanged; no restart needed."
        return 0
    fi
    mariadb_config_effective_snapshot >/dev/null || { rm -f -- "$temp_file"; die "Cannot determine the current effective MariaDB configuration. No files were changed."; }
    transaction_begin "$CURRENT_STEP"
    write_managed_file "$config_file" 0644 root root < "$temp_file"
    rm -f "$temp_file"
    mariadb_validate_installed_config || die "MariaDB rejected the complete configuration; the previous file was restored."
    after_config="$(mariadb_config_effective_snapshot)" || die "Cannot determine the candidate effective MariaDB configuration; the previous file was restored."
    risk="$(mariadb_high_risk_reasons "$after_config")"
    [[ -z "$risk" ]] || die "The candidate leaves high-risk MariaDB values; the previous file was restored:\n$risk"
    transaction_mark_service mariadb
    systemctl restart mariadb || die "MariaDB could not restart with the new configuration; the previous configuration was restored and recovery was attempted."
    mariadb_health_check || die "MariaDB failed its post-restart health check; the previous configuration was restored and recovery was attempted."
    runtime="$(mariadb_runtime_snapshot)" || die "MariaDB runtime values could not be read after restart; the previous configuration was restored."
    mariadb_snapshots_match "$after_config" "$runtime" || die "MariaDB runtime values do not match the validated configuration; the previous configuration was restored."
    systemctl enable mariadb
}

load_or_create_redis_secret() {
    local temp
    if [[ ! -s "$REDIS_SECRET_FILE" ]]; then
        temp="$(mktemp "$CONFIG_DIR/.redis-secret.XXXXXX")"
        generate_password > "$temp"
        write_managed_file "$REDIS_SECRET_FILE" 0600 root root < "$temp"
        rm -f -- "$temp"
    fi
    REDIS_PASSWORD="$(<"$REDIS_SECRET_FILE")"
    [[ "$REDIS_PASSWORD" =~ ^[a-f0-9]{48}$ ]] || die "The Redis secret file has an invalid format."
}

install_redis_secret_value() {
    local secret="$1" temp_file
    [[ "$secret" =~ ^[a-f0-9]{48}$ ]] || die "Refusing to install an invalid Redis secret."
    temp_file="$(mktemp "$CONFIG_DIR/.redis-secret.XXXXXX")"
    printf '%s\n' "$secret" > "$temp_file"
    write_managed_file "$REDIS_SECRET_FILE" 0600 root root < "$temp_file"
    rm -f "$temp_file"
    REDIS_PASSWORD="$secret"
}

redact_secret_from_logs() {
    local secret="$1" log_file temp_file line changed
    [[ "$secret" =~ ^[a-f0-9]{48}$ ]] || return 0
    for log_file in "$LOG_DIR"/wp-shell-*.log; do
        [[ -f "$log_file" ]] || continue
        temp_file="$(mktemp "$LOG_DIR/.redacted.XXXXXX")"
        changed="no"
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == *"$secret"* ]]; then
                line="${line//"$secret"/[REDACTED]}"
                changed="yes"
            fi
            printf '%s\n' "$line"
        done < "$log_file" > "$temp_file"
        if [[ "$changed" == "yes" ]]; then
            mv -f "$temp_file" "$log_file"
            chmod 0600 "$log_file"
        else
            rm -f "$temp_file"
        fi
    done
}

secret_exists_in_logs() {
    local secret="$1" log_file line
    [[ -n "$secret" ]] || return 1
    for log_file in "$LOG_DIR"/wp-shell-*.log; do
        [[ -f "$log_file" ]] || continue
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" == *"$secret"* ]] && return 0
        done < "$log_file"
    done
    return 1
}

rotate_redis_secret() {
    CURRENT_STEP="rotate Redis credentials"
    local old_secret new_secret config_file config_backup config_temp output="" i j domain wp_path
    local updated_sites=0
    local requirepass_replaced="no"
    load_or_create_redis_secret
    old_secret="$REDIS_PASSWORD"
    config_file="/etc/redis/wp-shell.conf"
    [[ -f "$config_file" ]] || die "Redis is not managed by wp-shell."
    [[ "$(REDISCLI_AUTH="$old_secret" redis-cli --no-auth-warning ping 2>/dev/null || true)" == "PONG" ]] || \
        die "The current Redis credential could not authenticate."

    for ((i = 1; i <= SITE_COUNT; i++)); do
        domain="${SITE_DOMAINS[$i]}"
        [[ "$(site_policy_value "$domain" object-cache disabled)" == enabled ]] || continue
        wp_path="$(site_wp_path "$domain")"
        [[ ! -f "$wp_path/wp-config.php" ]] || \
            site_wp_cli "$domain" config get DB_NAME >/dev/null 2>&1 || \
            die "WordPress configuration preflight failed for $domain."
    done

    new_secret="$(generate_password)"
    config_backup="$(mktemp /tmp/wp-shell-redis-config.XXXXXX)"
    config_temp="$(mktemp /etc/redis/.wp-shell-rotate.XXXXXX)"
    cp -a "$config_file" "$config_backup"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == requirepass\ * ]]; then
            printf 'requirepass %s\n' "$new_secret"
            requirepass_replaced="yes"
        else
            printf '%s\n' "$line"
        fi
    done < "$config_file" > "$config_temp"
    [[ "$requirepass_replaced" == "yes" ]] || printf 'requirepass %s\n' "$new_secret" >> "$config_temp"
    chown root:redis "$config_temp"
    chmod 0640 "$config_temp"
    mv -f "$config_temp" "$config_file"

    if output="$(printf '%s' "$new_secret" | REDISCLI_AUTH="$old_secret" \
        redis-cli --no-auth-warning -x CONFIG SET requirepass 2>&1)" && [[ "$output" == "OK" ]]; then
        :
    else
        cp -a "$config_backup" "$config_file"
        rm -f "$config_backup"
        die "Redis rejected the credential rotation before any WordPress configuration was changed."
    fi
    install_redis_secret_value "$new_secret"

    for ((i = 1; i <= SITE_COUNT; i++)); do
        domain="${SITE_DOMAINS[$i]}"
        [[ "$(site_policy_value "$domain" object-cache disabled)" == enabled ]] || continue
        wp_path="$(site_wp_path "$domain")"
        [[ -f "$wp_path/wp-config.php" ]] || continue
        [[ "$(site_policy_value "$domain" redis-mode)" != isolated ]] || continue
        if ! site_wp_config_set_redis_secret "$domain" "$new_secret"; then
            for ((j = 1; j <= i; j++)); do
                domain="${SITE_DOMAINS[$j]}"
                [[ "$(site_policy_value "$domain" object-cache disabled)" == enabled ]] || continue
                wp_path="$(site_wp_path "$domain")"
                [[ -f "$wp_path/wp-config.php" ]] || continue
                [[ "$(site_policy_value "$domain" redis-mode)" != isolated ]] || continue
                site_wp_config_set_redis_secret "$domain" "$old_secret" || true
                chmod "$(site_config_mode "$domain")" "$wp_path/wp-config.php"
            done
            printf '%s' "$old_secret" | REDISCLI_AUTH="$new_secret" \
                redis-cli --no-auth-warning -x CONFIG SET requirepass >/dev/null 2>&1 || true
            cp -a "$config_backup" "$config_file"
            install_redis_secret_value "$old_secret"
            rm -f "$config_backup"
            die "Redis credential rotation was rolled back after $domain could not be updated."
        fi
        chmod "$(site_config_mode "$domain")" "$wp_path/wp-config.php"
        updated_sites=$((updated_sites + 1))
    done

    rm -f "$config_backup"
    [[ "$(REDISCLI_AUTH="$new_secret" redis-cli --no-auth-warning ping 2>/dev/null || true)" == "PONG" ]] || \
        die "Redis did not accept the rotated credential."
    redact_secret_from_logs "$old_secret"
    for ((i = 1; i <= SITE_COUNT; i++)); do
        clear_site_cache "$i"
    done
    log_message SUCCESS "Rotated the Redis credential for Redis and $updated_sites WordPress site(s); matching wp-shell logs were redacted."
}

configure_redis() {
    CURRENT_STEP="configure Redis"
    calculate_resource_budget
    load_or_create_redis_secret
    local config_file override_dir override_file previous_config="" previous_override="" shared_memory candidate validation_dir validation_status
    shared_memory="$(shared_redis_memory_budget)" || die "Dedicated Redis allocations exceed the global Redis budget."
    config_file="/etc/redis/wp-shell.conf"
    override_dir="/etc/systemd/system/redis-server.service.d"
    override_file="$override_dir/wp-shell.conf"
    [[ -f "$config_file" ]] && previous_config="$(mktemp /tmp/redis-config.XXXXXX)" && cp -a "$config_file" "$previous_config"
    [[ -f "$override_file" ]] && previous_override="$(mktemp /tmp/redis-override.XXXXXX)" && cp -a "$override_file" "$previous_override"
    candidate="$(mktemp /etc/redis/.wp-shell-candidate.XXXXXX)"
    chmod 0600 "$candidate"
    cat > "$candidate" <<EOF
bind 127.0.0.1 -::1
protected-mode yes
port 6379
tcp-backlog 511
timeout 0
tcp-keepalive 300
supervised systemd
daemonize no
pidfile /run/redis/redis-server.pid
loglevel notice
logfile /var/log/redis/redis-server.log
databases 16
dir /var/lib/redis
dbfilename dump.rdb
requirepass $REDIS_PASSWORD
maxmemory ${shared_memory}mb
maxmemory-policy allkeys-lru
save ""
appendonly no
EOF
    validation_dir="$(safe_temp_dir)"
    chmod 0700 "$validation_dir"
    validation_status=0
    timeout 2s redis-server "$candidate" \
        --port 0 --unixsocket "$validation_dir/redis.sock" --unixsocketperm 600 \
        --supervised no --daemonize no --pidfile "$validation_dir/redis.pid" \
        --logfile "" --dir "$validation_dir" --dbfilename candidate.rdb \
        >/dev/null 2>&1 || validation_status=$?
    rm -rf -- "$validation_dir"
    if [[ "$validation_status" -ne 124 ]]; then
        rm -f -- "$candidate"
        die "Redis rejected the candidate configuration; no file was changed."
    fi
    install -d -m 0755 "$override_dir"
    transaction_begin "$CURRENT_STEP"
    transaction_mark_service redis
    transaction_mark_service systemd
    write_managed_file "$config_file" 0640 root redis < "$candidate"
    rm -f -- "$candidate"
    write_managed_file "$override_file" 0644 root root <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/redis-server $config_file --supervised systemd --daemonize no
EOF
    systemctl daemon-reload
    if [[ -n "$previous_config" && -n "$previous_override" ]] &&
        cmp -s "$previous_config" "$config_file" && cmp -s "$previous_override" "$override_file" &&
        systemctl is-active --quiet redis-server; then
        rm -f "$previous_config" "$previous_override"
        log_message INFO "Redis configuration is unchanged; no restart needed."
        return 0
    fi
    if ! systemctl restart redis-server; then
        if [[ -n "$previous_config" ]]; then
            cp -a "$previous_config" "$config_file"
        else
            rm -f "$config_file"
        fi
        if [[ -n "$previous_override" ]]; then cp -a "$previous_override" "$override_file"; else rm -f "$override_file"; fi
        systemctl daemon-reload
        systemctl restart redis-server || true
        rm -f "$previous_config" "$previous_override"
        die "Redis could not start with the new configuration; rollback was attempted."
    fi
    rm -f "$previous_config" "$previous_override"
    systemctl enable redis-server
}

shared_redis_memory_budget() {
    local i value remaining="$REDIS_MAX_MEMORY_MB"
    for ((i=1; i<=SITE_COUNT; i++)); do
        [[ "$(site_policy_value "${SITE_DOMAINS[$i]}" redis-mode)" == isolated ]] || continue
        value="$(site_policy_value "${SITE_DOMAINS[$i]}" redis-memory)"
        [[ "$value" =~ ^[1-9][0-9]{1,3}$ ]] && ((value >= 32)) || return 1
        remaining=$((remaining-value))
    done
    ((remaining >= 32)) || return 1
    printf '%s' "$remaining"
}

site_redis_socket() { printf '/run/wp-shell-redis-%s/redis.sock' "$(site_pool_id "$1")"; }

apply_site_redis_connection() {
    local domain="$1" index secret
    [[ "$(site_policy_value "$domain" object-cache disabled)" == enabled ]] || return 0
    index="$(site_index_by_domain "$domain")" || return 1
    if [[ "$(site_policy_value "$domain" redis-mode)" == isolated ]]; then
        secret="$(site_policy_value "$domain" redis-secret)"
        site_wp_cli "$domain" config set WP_REDIS_SCHEME unix
        site_wp_cli "$domain" config set WP_REDIS_PATH "$(site_redis_socket "$domain")"
        site_wp_cli "$domain" config set WP_REDIS_DATABASE 0 --raw
    else
        load_or_create_redis_secret
        secret="$REDIS_PASSWORD"
        site_wp_cli "$domain" config set WP_REDIS_SCHEME tcp
        site_wp_cli "$domain" config set WP_REDIS_HOST 127.0.0.1
        site_wp_cli "$domain" config set WP_REDIS_PORT 6379 --raw
        site_wp_cli "$domain" config set WP_REDIS_DATABASE "${SITE_REDIS_DATABASES[$index]}" --raw
    fi
    site_wp_config_set_redis_secret "$domain" "$secret"
    chmod "$(site_config_mode "$domain")" "$(site_wp_path "$domain")/wp-config.php"
}

isolate_site_redis() (
    # This operation has its own application/database rollback boundary.
    TRANSACTION_CONTEXT=no
    local index="$1" memory="${2:-64}" domain run_user redis_user pool unit config stage secret
    local old_memory remaining success=no wp_config redis_status
    domain="${SITE_DOMAINS[$index]}"
    [[ "$(site_policy_value "$domain" object-cache disabled)" == enabled ]] || \
        die "Enable the site's Redis object-cache integration before isolating its Redis instance."
    pool="$(site_pool_id "$domain")"
    run_user="$(site_run_user "$domain")"
    [[ "$run_user" == "$pool" ]] || die "First migrate this site to its own PHP user: wp-shell site $domain isolate"
    [[ "$(site_policy_value "$domain" redis-mode)" != isolated ]] || die "This site already has a dedicated Redis instance. Review its configuration before changing its capacity."
    if [[ ! "$memory" =~ ^[1-9][0-9]{1,3}$ ]] || ((memory < 32)); then die "Specify at least 32MB of the existing global Redis budget."; fi
    calculate_resource_budget
    remaining="$(shared_redis_memory_budget)"
    ((remaining-memory >= 32)) || die "Not enough global Redis budget; at least 32MB must remain for the shared instance."
    [[ -f /etc/redis/wp-shell.conf ]] || die "The shared Redis instance must already be managed by wp-shell."
    site_wp_cli "$domain" plugin is-active redis-cache || die "This operation supports the Redis Object Cache plugin."
    load_or_create_redis_secret
    old_memory="$(REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli --raw CONFIG GET maxmemory | tail -n 1)"
    [[ "$old_memory" =~ ^[0-9]+$ ]] || die "Could not read the shared Redis limit."
    backup_site "$index" >/dev/null
    wp_config="$(site_wp_path "$domain")/wp-config.php"
    stage="$(mktemp -d "$STATE_DIR/.redis-isolation.XXXXXX")"
    cp -a "$wp_config" "$stage/wp-config.php"
    cp -a /etc/redis/wp-shell.conf "$stage/shared.conf"
    redis_user="wr_${pool#wp_}"
    unit="wp-shell-redis-$pool"
    config="/etc/wp-shell-redis/$pool.conf"
    [[ ! -e "$config" && ! -e "/etc/systemd/system/$unit.service" ]] || die "A dedicated Redis configuration already exists; inspect it before retrying."
    # shellcheck disable=SC2317,SC2329
    cleanup_redis_isolation() {
        if [[ "$success" != yes ]]; then
            cp -a "$stage/wp-config.php" "$wp_config"
            cp -a "$stage/shared.conf" /etc/redis/wp-shell.conf
            REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli CONFIG SET maxmemory "$old_memory" >/dev/null 2>&1 || true
            systemctl disable --now "$unit.service" >/dev/null 2>&1 || true
            rm -f -- "$config" "/etc/systemd/system/$unit.service"
            systemctl daemon-reload
            set_site_policy "$domain" redis-mode shared
            set_site_policy "$domain" redis-secret ''
            log_message WARNING "Dedicated Redis migration failed; WordPress and the shared Redis limit restored. Safety backup retained."
        fi
        rm -rf -- "$stage"
    }
    trap cleanup_redis_isolation EXIT
    if ! id "$redis_user" >/dev/null 2>&1; then
        useradd --system --user-group --no-create-home --home-dir "/var/lib/$unit" --shell /usr/sbin/nologin "$redis_user"
    fi
    [[ "$(getent passwd "$redis_user" | cut -d: -f6)" == "/var/lib/$unit" ]] || die "Redis account name collision."
    secret="$(generate_password)"
    install -d -m 0755 /etc/wp-shell-redis
    write_managed_file "$config" 0640 root "$run_user" <<EOF
port 0
protected-mode yes
unixsocket $(site_redis_socket "$domain")
unixsocketperm 660
daemonize no
supervised no
logfile ""
databases 1
dir /var/lib/$unit
requirepass $secret
maxmemory ${memory}mb
maxmemory-policy allkeys-lru
save ""
appendonly no
EOF
    write_managed_file "/etc/systemd/system/$unit.service" 0644 root root <<EOF
[Unit]
Description=Private Redis object cache for $domain
After=local-fs.target
[Service]
User=$redis_user
Group=$run_user
ExecStart=/usr/bin/redis-server $config
Restart=on-failure
RuntimeDirectory=$unit
RuntimeDirectoryMode=0750
StateDirectory=$unit
StateDirectoryMode=0700
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
NoNewPrivileges=true
RestrictAddressFamilies=AF_UNIX
[Install]
WantedBy=multi-user.target
EOF
    remaining=$((remaining-memory))
    sed -E "s/^maxmemory[[:space:]].*/maxmemory ${remaining}mb/" "$stage/shared.conf" > "$stage/shared-new.conf"
    write_managed_file /etc/redis/wp-shell.conf 0640 root redis < "$stage/shared-new.conf"
    [[ "$(REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli CONFIG SET maxmemory "$((remaining*1048576))")" == OK ]] || die "Could not reserve dedicated Redis memory."
    systemctl daemon-reload
    systemctl enable --now "$unit.service"
    [[ "$(REDISCLI_AUTH="$secret" timeout 4s redis-cli -s "$(site_redis_socket "$domain")" ping)" == PONG ]] || die "Dedicated Redis did not start."
    set_site_policy "$domain" redis-mode isolated
    set_site_policy "$domain" redis-memory "$memory"
    set_site_policy "$domain" redis-secret "$secret"
    site_wp_cli "$domain" config set WP_REDIS_SCHEME unix
    site_wp_cli "$domain" config set WP_REDIS_PATH "$(site_redis_socket "$domain")"
    site_wp_cli "$domain" config set WP_REDIS_DATABASE 0 --raw
    site_wp_config_set_redis_secret "$domain" "$secret"
    chown root:"$(id -gn "$(site_run_user "$domain")")" "$wp_config"
    chmod 0640 "$wp_config"
    redis_status="$(site_wp_cli "$domain" redis status)" || die "WordPress could not inspect its private Redis instance."
    grep -Fq 'Status: Connected' <<< "$redis_status" || die "WordPress could not connect to its private Redis instance."
    success=yes
    log_message SUCCESS "$domain: dedicated Unix-socket Redis (${memory}MB), separate Redis UID, no TCP listener. Shared Redis now has ${remaining}MB; its cache may evict old entries."
)

validate_cloudflare_ranges() {
    local file="$1" family="$2"
    [[ -s "$file" && "$family" =~ ^(4|6)$ ]] || return 1
    python3 - "$file" "$family" <<'PY'
import ipaddress
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
family = int(sys.argv[2])
lines = [line.strip() for line in path.read_text(encoding="ascii").splitlines() if line.strip()]
if not lines:
    raise SystemExit(1)
for line in lines:
    if any(ch.isspace() for ch in line):
        raise SystemExit(1)
    network = ipaddress.ip_network(line, strict=True)
    if network.version != family:
        raise SystemExit(1)
PY
}

render_cloudflare_realip() {
    local ipv4="$1" ipv6="$2" output="$3" range
    validate_cloudflare_ranges "$ipv4" 4 || return 1
    validate_cloudflare_ranges "$ipv6" 6 || return 1
    {
        printf '# Managed by wp-shell from Cloudflare official IP lists.\n'
        while IFS= read -r range; do [[ -z "$range" ]] || printf 'set_real_ip_from %s;\n' "$range"; done < "$ipv4"
        while IFS= read -r range; do [[ -z "$range" ]] || printf 'set_real_ip_from %s;\n' "$range"; done < "$ipv6"
        printf 'real_ip_header CF-Connecting-IP;\nreal_ip_recursive on;\n'
    } > "$output"
}

cloudflare_update() {
    CURRENT_STEP="update Cloudflare trusted proxy ranges"
    local stage ipv4 ipv6 candidate validation_config
    require_command curl
    require_command python3
    stage="$(safe_temp_dir)"
    register_temp_path "$stage"
    ipv4="$stage/ips-v4"
    ipv6="$stage/ips-v6"
    candidate="$stage/wp-shell-cloudflare-realip.conf"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --max-time 30 "$CLOUDFLARE_IPV4_URL" > "$ipv4"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --max-time 30 "$CLOUDFLARE_IPV6_URL" > "$ipv6"
    render_cloudflare_realip "$ipv4" "$ipv6" "$candidate" || \
        die "Cloudflare IP data is empty or invalid; the old configuration was kept."
    validation_config="$stage/nginx-fragment.conf"
    cat > "$validation_config" <<EOF
pid $stage/nginx.pid;
error_log stderr emerg;
events {}
http { include $candidate; }
EOF
    nginx -t -q -p /etc/nginx/ -c "$validation_config" || \
        die "Nginx rejected the Cloudflare candidate before installation; the old configuration was kept."
    install -d -m 0755 /etc/nginx/conf.d
    transaction_begin "$CURRENT_STEP"
    transaction_mark_service nginx
    write_managed_file /etc/nginx/conf.d/wp-shell-cloudflare-realip.conf 0644 root root < "$candidate"
    if [[ "$DRY_RUN" == no ]]; then
        nginx -t || die "Nginx rejected the Cloudflare real-IP configuration; the transaction will be rolled back."
        systemctl reload nginx
    fi
    set_host_policy cloudflare enabled
    rm -rf -- "$stage"
    log_message SUCCESS "Cloudflare real-IP ranges were verified and applied. Only listed proxy networks can replace the client IP."
}

install_cloudflare_timer() {
    CURRENT_STEP="install Cloudflare IP update timer"
    install_self
    write_managed_file /etc/systemd/system/wp-shell-cloudflare-ips.service 0644 root root <<EOF
[Unit]
Description=Refresh verified Cloudflare proxy IP ranges
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$MANAGED_SCRIPT cloudflare update
TimeoutStartSec=90s
PrivateTmp=true
NoNewPrivileges=true
EOF
    write_managed_file /etc/systemd/system/wp-shell-cloudflare-ips.timer 0644 root root <<'EOF'
[Unit]
Description=Weekly Cloudflare proxy IP refresh
[Timer]
OnCalendar=weekly
RandomizedDelaySec=6h
Persistent=true
[Install]
WantedBy=timers.target
EOF
    if [[ "$DRY_RUN" == no ]]; then
        systemctl daemon-reload
        systemctl enable --now wp-shell-cloudflare-ips.timer
    fi
}

cloudflare_check_ip() {
    local source_ip="${1:-}" claimed_ip="${2:-}" config=/etc/nginx/conf.d/wp-shell-cloudflare-realip.conf
    [[ -n "$source_ip" && -n "$claimed_ip" ]] || die "Usage: wp-shell cloudflare check SOURCE_IP CF_CONNECTING_IP"
    [[ -s "$config" ]] || die "Cloudflare real-IP configuration is not installed."
    python3 - "$config" "$source_ip" "$claimed_ip" <<'PY'
import ipaddress
import re
import sys

source = ipaddress.ip_address(sys.argv[2])
claimed = ipaddress.ip_address(sys.argv[3])
networks = []
for line in open(sys.argv[1], encoding="ascii"):
    match = re.fullmatch(r"set_real_ip_from\s+([^;]+);\s*", line)
    if match:
        networks.append(ipaddress.ip_network(match.group(1), strict=True))
trusted = any(source in network for network in networks)
effective = claimed if trusted else source
print(f"source={source} trusted={'yes' if trusted else 'no'} claimed={claimed} effective={effective}")
PY
}

cloudflare_command() {
    case "${1:-status}" in
        enable)
            [[ "${2:-}" == --confirm ]] || die "Impact: trust verified Cloudflare proxy ranges for client IPs and install a weekly updater. Re-run with --confirm."
            cloudflare_update
            install_cloudflare_timer
            log_message INFO "No site cache, login-limit, DNS, TLS, or WordPress policy was changed. Configure each proxied site explicitly."
            ;;
        disable)
            [[ "${2:-}" == --confirm ]] || die "Impact: stop trusting Cloudflare client-IP headers and remove its updater. No site/DNS setting changes. Re-run with --confirm."
            CURRENT_STEP="disable Cloudflare trusted proxy ranges"
            transaction_begin "$CURRENT_STEP"
            transaction_mark_service nginx
            transaction_mark_service systemd
            remove_managed_file /etc/nginx/conf.d/wp-shell-cloudflare-realip.conf
            remove_managed_file /etc/systemd/system/wp-shell-cloudflare-ips.timer
            remove_managed_file /etc/systemd/system/wp-shell-cloudflare-ips.service
            nginx -t || die "Nginx rejected Cloudflare removal; configuration will be restored."
            systemctl disable --now wp-shell-cloudflare-ips.timer 2>/dev/null || true
            systemctl daemon-reload
            systemctl reload nginx
            set_host_policy cloudflare disabled
            log_message SUCCESS "Cloudflare trusted proxy handling disabled. Per-site cache and login policies were not changed."
            ;;
        update)
            [[ "$(host_policy_value cloudflare disabled)" == enabled ]] || die "Cloudflare mode is disabled. Use: wp-shell cloudflare enable --confirm"
            cloudflare_update
            ;;
        status)
            printf 'Cloudflare mode: %s\n' "$(host_policy_value cloudflare disabled)"
            printf 'Real-IP config: %s\n' "$(if [[ -s /etc/nginx/conf.d/wp-shell-cloudflare-realip.conf ]]; then printf installed; else printf absent; fi)"
            printf 'Updater: %s\n' "$(systemctl is-active wp-shell-cloudflare-ips.timer 2>/dev/null || true)"
            ;;
        check) cloudflare_check_ip "${2:-}" "${3:-}" ;;
        *) die "Usage: wp-shell cloudflare enable --confirm | disable --confirm | update | status | check SOURCE_IP CF_CONNECTING_IP" ;;
    esac
}

configure_fail2ban() {
    CURRENT_STEP="configure Fail2ban"
    local ssh_port
    ssh_port="$(detect_ssh_port)"
    install -d -m 0755 /etc/fail2ban/jail.d
    transaction_begin "$CURRENT_STEP"
    transaction_mark_service fail2ban
    write_managed_file /etc/fail2ban/jail.d/wp-shell.local 0644 root root <<EOF
[sshd]
enabled = true
port = $ssh_port
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
    fail2ban-client -t
    systemctl enable fail2ban
    systemctl reload-or-restart fail2ban
}

configure_log_rotation() {
    CURRENT_STEP="configure log rotation"
    write_managed_file /etc/logrotate.d/wp-shell-sites 0644 root root <<'EOF'
/var/www/*/logs/*.log {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 0640 www-data adm
}
EOF
    write_managed_file /etc/logrotate.d/wp-shell-operations 0644 root root <<'EOF'
/var/log/wp-shell/*.log {
    daily
    maxage 30
    rotate 4
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su root root
}
EOF
}

detect_ssh_port() {
    local port=""
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        port="${SSH_CONNECTION##* }"
    fi
    if [[ ! "$port" =~ ^[0-9]+$ ]] && command -v sshd >/dev/null 2>&1; then
        port="$(sshd -T 2>/dev/null | awk '$1 == "port" && first == "" {first=$2} END {if (first != "") print first}')"
    fi
    [[ "$port" =~ ^[0-9]+$ ]] || port=22
    printf '%s' "$port"
}

configure_firewall() {
    CURRENT_STEP="configure the UFW firewall"
    local ssh_port
    ssh_port="$(detect_ssh_port)"
    ufw default deny incoming
    ufw default allow outgoing
    ufw_rule_present "^${ssh_port}/tcp[[:space:]]+LIMIT" || ufw limit "${ssh_port}/tcp" comment 'SSH rate limit managed by wp-shell'
    ufw_rule_present '^80/tcp[[:space:]]+ALLOW' || ufw allow 80/tcp comment 'HTTP managed by wp-shell'
    ufw_rule_present '^443/tcp[[:space:]]+ALLOW' || ufw allow 443/tcp comment 'HTTPS managed by wp-shell'
    ufw --force enable
    log_message SUCCESS "UFW rate-limits SSH on port $ssh_port and allows HTTP/HTTPS; existing unrelated rules were preserved."
}

install_certbot_deploy_hook() {
    install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
    write_managed_file /etc/letsencrypt/renewal-hooks/deploy/reload-nginx 0755 root root <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
nginx -t
systemctl reload nginx
EOF
    systemctl enable --now certbot.timer 2>/dev/null || true
}

database_config_path() {
    printf '%s/%s.v1' "$DATABASE_CONFIG_DIR" "$1"
}

load_database_config() {
    local domain="$1" path record pass_b64
    path="$(database_config_path "$domain")"
    [[ -f "$path" ]] || return 1
    IFS='|' read -r record DB_NAME DB_USER pass_b64 < "$path"
    [[ "$record" == "database" ]] || die "Database configuration is corrupt: $path"
    [[ "$DB_NAME" =~ ^wp_[a-f0-9]{12}$ ]] || die "Invalid database name: $DB_NAME"
    [[ "$DB_USER" =~ ^wp_[a-f0-9]{12}$ ]] || die "Invalid database user: $DB_USER"
    DB_PASSWORD="$(b64_decode "$pass_b64")"
}

save_database_config() {
    local domain="$1" path temp_file
    path="$(database_config_path "$domain")"
    temp_file="$(mktemp "$DATABASE_CONFIG_DIR/.database.XXXXXX")"
    printf 'database|%s|%s|%s\n' "$DB_NAME" "$DB_USER" "$(b64_encode "$DB_PASSWORD")" > "$temp_file"
    install_private_file "$temp_file" "$path"
    rm -f "$temp_file"
}

ensure_site_database() {
    CURRENT_STEP="create the site database"
    local domain="$1" hash
    if ! load_database_config "$domain"; then
        hash="$(printf '%s' "$domain" | sha256sum | cut -c1-12)"
        DB_NAME="wp_$hash"
        DB_USER="wp_$hash"
        DB_PASSWORD="$(generate_password)"
        save_database_config "$domain"
    fi
    mariadb --protocol=socket <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
}

site_server_names() {
    local index="$1"
    printf '%s' "${SITE_DOMAINS[$index]}"
    [[ "${SITE_WWW[$index]}" == "yes" ]] && printf ' www.%s' "${SITE_DOMAINS[$index]}"
}

nginx_zone_name() {
    printf 'wp_%s' "${1//[^a-zA-Z0-9]/_}"
}

install_nginx_log_format() {
    transaction_begin "$CURRENT_STEP"
    transaction_mark_service nginx
    install -d -m 0755 /etc/nginx/conf.d
    if [[ -f /etc/nginx/conf.d/wp-shell-login-limit.conf ]] && \
       grep -Fq 'Managed by wp-shell' /etc/nginx/conf.d/wp-shell-login-limit.conf; then
        remove_managed_file /etc/nginx/conf.d/wp-shell-login-limit.conf
    fi
    write_managed_file /etc/nginx/conf.d/wp-shell-log-format.conf 0644 root root <<'EOF'
# Managed by wp-shell. Cookies, query strings, referrers and user agents are excluded.
# client_ip is Nginx's verified remote address; edge_ip keeps the direct peer for proxy audits.
log_format wp_shell escape=json '{"ts":"$time_iso8601","client_ip":"$remote_addr","edge_ip":"$realip_remote_addr","status":$status,"bytes":$body_bytes_sent,"request_time":$request_time,"upstream_time":"$upstream_response_time","cache":"$upstream_cache_status","method":"$request_method","uri":"$uri"}';
EOF

    write_managed_file /etc/nginx/conf.d/wp-shell-global.conf 0644 root root <<'EOF'
# Managed by wp-shell. Shared security and login-throttling primitives.
server_tokens off;
map "$request_method:$uri" $wp_shell_login_key {
    default "";
    ~*^POST:/wp-login\.php$ $binary_remote_addr;
}
limit_req_zone $wp_shell_login_key zone=wp_shell_login:10m rate=10r/m;
EOF

    install -d -m 0755 /etc/nginx/sites-available /etc/nginx/sites-enabled
    write_managed_file /etc/nginx/sites-available/00-wp-shell-default 0644 root root <<'EOF'
# Managed by wp-shell. Never serve a managed WordPress site for an unknown Host.
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}
server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name _;
    ssl_reject_handshake on;
}
EOF
    if [[ "$DRY_RUN" == no ]]; then
        transaction_begin "$CURRENT_STEP"
        [[ "$TRANSACTION_ACTIVE" != yes ]] || transaction_backup_file /etc/nginx/sites-enabled/00-wp-shell-default
        ln -sfn /etc/nginx/sites-available/00-wp-shell-default /etc/nginx/sites-enabled/00-wp-shell-default
    else
        printf 'PLAN link /etc/nginx/sites-enabled/00-wp-shell-default\n'
    fi
}

disable_distribution_nginx_default() {
    local enabled=/etc/nginx/sites-enabled/default target
    [[ -e "$enabled" || -L "$enabled" ]] || return 0
    target="$(readlink -f "$enabled" 2>/dev/null || true)"
    if [[ -L "$enabled" && "$target" == /etc/nginx/sites-available/default ]] && \
       grep -Eq 'Default server configuration|server_name[[:space:]]+_;' "$target"; then
        remove_managed_file "$enabled"
        log_message INFO "Disabled the Ubuntu distribution default Nginx site; its transaction backup is retained."
    else
        die "An unmanaged Nginx default site is enabled. Review it manually before wp-shell can enforce unknown-Host 444 responses: $enabled"
    fi
}

validate_nginx_site_candidates() {
    local site_candidate="$1" cache_candidate="${2:-}" stage validation_config
    [[ -s "$site_candidate" && -s /etc/nginx/conf.d/wp-shell-log-format.conf && -s /etc/nginx/conf.d/wp-shell-global.conf ]] || return 1
    stage="$(safe_temp_dir)"
    validation_config="$stage/nginx.conf"
    {
        printf 'pid %s/nginx.pid;\n' "$stage"
        printf 'error_log stderr emerg;\n'
        printf 'events {}\nhttp {\n'
        printf 'include /etc/nginx/mime.types;\n'
        printf 'include /etc/nginx/conf.d/wp-shell-log-format.conf;\n'
        printf 'include /etc/nginx/conf.d/wp-shell-global.conf;\n'
        [[ -z "$cache_candidate" ]] || printf 'include %s;\n' "$cache_candidate"
        printf 'include %s;\n}\n' "$site_candidate"
    } > "$validation_config"
    if nginx -t -q -p /etc/nginx/ -c "$validation_config"; then
        rm -rf -- "$stage"
        return 0
    fi
    rm -rf -- "$stage"
    return 1
}

install_nginx_files() {
    local domain="$1" site_temp="$2" cache_temp="${3:-}"
    local site_target cache_target site_backup="" cache_backup="" snapshot
    site_target="/etc/nginx/sites-available/$domain"
    cache_target="/etc/nginx/conf.d/wp-cache-$domain.conf"
    validate_nginx_site_candidates "$site_temp" "$cache_temp" || \
        die "Nginx rejected the generated site candidate before installation; no live site file was changed."
    transaction_begin "$CURRENT_STEP"
    transaction_mark_service nginx
    [[ -f "$site_target" ]] && site_backup="$(mktemp /tmp/nginx-site.XXXXXX)" && cp -a "$site_target" "$site_backup"
    [[ -f "$cache_target" ]] && cache_backup="$(mktemp /tmp/nginx-cache.XXXXXX)" && cp -a "$cache_target" "$cache_backup"
    if [[ -f "$site_target" ]]; then
        install -d -m 0700 "$CONFIG_DIR/nginx-backups"
        snapshot="$(mktemp -d "$CONFIG_DIR/nginx-backups/$domain-$(date +%Y%m%d-%H%M%S).XXXXXX")"
        cp -a "$site_target" "$snapshot/site.conf"
        [[ ! -f "$cache_target" ]] || cp -a "$cache_target" "$snapshot/cache.conf"
        [[ ! -d "/etc/nginx/wp-shell-custom/$domain" ]] || cp -a "/etc/nginx/wp-shell-custom/$domain" "$snapshot/custom"
        log_message INFO "Previous Nginx configuration saved in $snapshot"
    fi
    write_managed_file "$site_target" 0644 root root < "$site_temp"
    if [[ -n "$cache_temp" ]]; then
        write_managed_file "$cache_target" 0644 root root < "$cache_temp"
    else
        remove_managed_file "$cache_target"
    fi
    if [[ "$DRY_RUN" == no ]]; then
        [[ "$TRANSACTION_ACTIVE" != yes ]] || transaction_backup_file "/etc/nginx/sites-enabled/$domain"
        ln -sfn "$site_target" "/etc/nginx/sites-enabled/$domain"
    else
        printf 'PLAN link /etc/nginx/sites-enabled/%s -> %s\n' "$domain" "$site_target"
        return 0
    fi
    if ! nginx -t || ! systemctl reload nginx; then
        if [[ -n "$site_backup" ]]; then cp -a "$site_backup" "$site_target"; else rm -f "$site_target" "/etc/nginx/sites-enabled/$domain"; fi
        if [[ -n "$cache_backup" ]]; then cp -a "$cache_backup" "$cache_target"; else rm -f "$cache_target"; fi
        nginx -t || true
        systemctl reload nginx || true
        rm -f "$site_backup" "$cache_backup"
        die "Nginx configuration validation failed; $domain was rolled back."
    fi
    rm -f "$site_backup" "$cache_backup"
    systemctl enable nginx
}

configure_acme_site() {
    CURRENT_STEP="configure the temporary ACME site"
    local index="$1" domain server_names site_temp wp_path
    domain="${SITE_DOMAINS[$index]}"
    wp_path="${SITE_PATHS[$index]}"
    server_names="$(site_server_names "$index")"
    site_temp="$(mktemp /tmp/nginx-acme.XXXXXX)"
    cat > "$site_temp" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $server_names;
    root $wp_path;

    location ^~ /.well-known/acme-challenge/ {
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        return 503;
    }
}
EOF
    install_nginx_log_format
    install_nginx_files "$domain" "$site_temp"
    rm -f "$site_temp"
}

issue_ssl_certificate() {
    CURRENT_STEP="issue the TLS certificate"
    local index="$1" domain email wp_path
    local -a domains certbot_args
    domain="${SITE_DOMAINS[$index]}"
    email="${SITE_ADMIN_EMAILS[$index]}"
    wp_path="${SITE_PATHS[$index]}"
    domains=(-d "$domain")
    [[ "${SITE_WWW[$index]}" == "yes" ]] && domains+=(-d "www.$domain")
    getent ahosts "$domain" >/dev/null 2>&1 || die "$domain does not resolve yet; the certificate cannot be issued."
    if [[ "${SITE_WWW[$index]}" == "yes" ]]; then
        getent ahosts "www.$domain" >/dev/null 2>&1 || die "www.$domain does not resolve; configure DNS or disable www."
    fi
    certbot_args=(certonly --webroot --webroot-path "$wp_path" --cert-name "$domain" --agree-tos --non-interactive --email "$email" --keep-until-expiring)
    if [[ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]]; then
        certbot_args+=(--expand)
    fi
    certbot "${certbot_args[@]}" "${domains[@]}"
    [[ -s "/etc/letsencrypt/live/$domain/fullchain.pem" ]] || die "The certificate was not created for $domain."
}

configure_https_site() {
    CURRENT_STEP="configure the HTTPS site"
    local index="$1" domain primary server_names zone site_temp cache_temp wp_path pool_socket
    local hsts_header="" xmlrpc_location page_cache cache_directives="" strict_server_headers="" strict_location_headers=""
    domain="${SITE_DOMAINS[$index]}"
    primary="${SITE_PRIMARY_DOMAINS[$index]}"
    wp_path="${SITE_PATHS[$index]}"
    pool_socket="$(site_pool_socket "$domain")"
    server_names="$(site_server_names "$index")"
    zone="$(nginx_zone_name "$domain")"
    site_temp="$(mktemp "${TMPDIR:-/tmp}/nginx-site.XXXXXX")"
    cache_temp=""
    if [[ ! -f "$SITE_POLICY_DIR/$domain/hsts" && -f "/etc/nginx/sites-available/$domain" ]] && \
       grep -Fq 'add_header Strict-Transport-Security "max-age=15552000" always;' "/etc/nginx/sites-available/$domain"; then
        set_site_policy "$domain" hsts enabled
        log_message INFO "$domain: adopted the existing managed HSTS setting; it was not silently removed during upgrade."
    fi
    if [[ "$(site_policy_value "$domain" hsts disabled)" == enabled ]]; then
        hsts_header='    add_header Strict-Transport-Security "max-age=15552000" always;'
    fi
    if ! site_policy_is_set "$domain" page-cache; then
        if [[ -f "/etc/nginx/sites-available/$domain" ]] && \
           grep -Fq 'fastcgi_cache ' "/etc/nginx/sites-available/$domain"; then
            set_site_policy "$domain" page-cache enabled
            log_message INFO "$domain: adopted the existing FastCGI page-cache behavior during upgrade."
        else
            set_site_policy "$domain" page-cache disabled
        fi
    fi
    page_cache="$(site_policy_value "$domain" page-cache disabled)"
    if ! site_policy_is_set "$domain" header-profile; then
        if [[ -f "/etc/nginx/sites-available/$domain" ]] && \
           grep -Fq 'add_header Permissions-Policy' "/etc/nginx/sites-available/$domain"; then
            set_site_policy "$domain" header-profile strict
            log_message INFO "$domain: adopted the existing strict response-header profile during upgrade."
        else
            set_site_policy "$domain" header-profile compatible
        fi
    fi
    if [[ "$(site_policy_value "$domain" header-profile compatible)" == strict ]]; then
        strict_server_headers=$'    add_header X-Frame-Options "SAMEORIGIN" always;\n    add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(self)" always;'
        strict_location_headers=$'        add_header X-Frame-Options "SAMEORIGIN" always;\n        add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(self)" always;'
    fi
    if [[ "$(site_policy_value "$domain" xmlrpc enabled)" == enabled ]]; then
        xmlrpc_location='# XML-RPC is explicitly enabled for this site.'
    else
        xmlrpc_location=$'    location = /xmlrpc.php {\n        deny all;\n    }'
    fi
    install -d -m 0755 "/etc/nginx/wp-shell-custom/$domain"
    if [[ "$page_cache" == enabled ]]; then
        cache_temp="$(mktemp "${TMPDIR:-/tmp}/nginx-cache.XXXXXX")"
        cat > "$cache_temp" <<EOF
fastcgi_cache_path $(site_cache_dir "$domain") levels=1:2 keys_zone=${zone}:16m inactive=60m max_size=512m use_temp_path=off;
EOF
        cache_directives="$(cat <<EOF
        fastcgi_cache $zone;
        fastcgi_cache_key \"\$scheme\$request_method\$host\$request_uri\";
        fastcgi_cache_methods GET HEAD;
        fastcgi_cache_valid 200 301 302 30m;
        fastcgi_cache_use_stale error timeout updating http_500 http_503;
        fastcgi_cache_background_update on;
        fastcgi_cache_lock on;
        fastcgi_cache_bypass \$skip_cache;
        fastcgi_no_cache \$skip_cache;
        add_header X-FastCGI-Cache \$upstream_cache_status;
EOF
)"
    fi
    cat > "$site_temp" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $server_names;
    root $wp_path;

    location ^~ /.well-known/acme-challenge/ {
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        return 301 https://$primary\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $server_names;
    root $wp_path;
    index index.php index.html;

    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

$hsts_header
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
$strict_server_headers

    if (\$host != $primary) { return 301 https://$primary\$request_uri; }

    client_max_body_size 128M;
    gzip on;
    gzip_vary on;
    gzip_comp_level 5;
    gzip_min_length 1024;
    gzip_types text/css text/plain text/xml application/javascript application/json application/xml image/svg+xml;
    access_log /var/www/$domain/logs/nginx-access.log wp_shell;
    error_log /var/www/$domain/logs/nginx-error.log warn;

    set \$skip_cache 0;
    if (\$request_method !~ ^(GET|HEAD)$) { set \$skip_cache 1; }
    if (\$http_authorization != "") { set \$skip_cache 1; }
    if (\$query_string != "") { set \$skip_cache 1; }
    if (\$request_uri ~* "(^|/)(wp-admin|wp-login\\.php|wp-cron\\.php|wp-json|xmlrpc\\.php|cart|checkout|my-account|wc-api|feed|(?:wp-)?sitemap[^/?]*|quote|request-a-quote)(/|\\?|$)") { set \$skip_cache 1; }
    if (\$http_cookie ~* "wordpress_logged_in|comment_author|wp-postpass|woocommerce_items_in_cart|woocommerce_cart_hash|wp_woocommerce_session_|woocommerce_recently_viewed|yith_ywraq|rfq") { set \$skip_cache 1; }
    if (-f /var/www/$domain/.wp-shell-maintenance) { return 503; }

    # Root-owned per-site overrides survive template refreshes. Put staging
    # exclusions/custom WooCommerce paths here; never edit the generated file.
    include /etc/nginx/wp-shell-custom/$domain/*.conf;

$xmlrpc_location

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~* /(?:uploads|cache|files)/.*\.(?:php[0-9]?|phtml|phar|cgi|pl|py|sh)$ {
        deny all;
    }

    location ^~ /wp-admin/includes/ {
        deny all;
    }

    location ~* ^/wp-includes/[^/]+\.php$ {
        deny all;
    }

    location ~* ^/wp-includes/(?:js/tinymce/langs/.+\.php|theme-compat/) {
        deny all;
    }

    location ~* /(?:wp-config(?:-sample)?\.php|wp-settings\.php|wp-load\.php|debug\.log|readme\.html|license\.txt)$ {
        deny all;
    }

    location ~* /wp-content/(?:wpvividbackups|updraft|ai1wm-backups|backup-db|backups-dup-pro|dup-installer|duplicator|upgrade|upgrade-temp-backup)(?:/|$) {
        deny all;
    }

    location ~* ^/(?:backups|cache|logs)(?:/|$) {
        deny all;
    }

    location ~ (^|/)\.(?!well-known/) {
        deny all;
    }

    location ~* \.(?:log|sql|ini|conf|bak|old|orig|save|swp)$ {
        deny all;
    }

    location ~* \.(?:log|sql)(?:\.[0-9]+)?\.(?:gz|zip|bz2|xz)$ {
        deny all;
    }

    location ~ \.php$ {
        try_files \$uri =404;
        include /etc/nginx/fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass unix:$pool_socket;
        fastcgi_hide_header Strict-Transport-Security;
$cache_directives
$hsts_header
        add_header X-Content-Type-Options "nosniff" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
$strict_location_headers
    }

    location ~* \.(?:css|js|jpg|jpeg|gif|png|ico|webp|avif|svg|woff2?|ttf|eot)$ {
        expires 7d;
$hsts_header
        add_header X-Content-Type-Options "nosniff" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
$strict_location_headers
        # Same-URL media may be replaced. Do not promise immutability.
        access_log off;
        try_files \$uri =404;
    }
}
EOF
    install -d -o www-data -g www-data -m 0750 "$(site_cache_dir "$domain")"
    install_nginx_log_format
    install_nginx_files "$domain" "$site_temp" "$cache_temp"
    rm -f "$site_temp"
    [[ -z "$cache_temp" ]] || rm -f "$cache_temp"
}

create_site_directories() {
    local domain="$1" wp_path="$2" run_user
    run_user="$(site_run_user "$domain")"
    install -d -o root -g root -m 0755 "/var/www/$domain"
    install -d -o "$run_user" -g www-data -m 0755 "$wp_path"
    install -d -o "$run_user" -g www-data -m 0750 "/var/www/$domain/logs"
    ensure_site_storage "$domain"
}

site_cache_dir() {
    printf '/var/www/%s/cache' "$1"
}

site_backup_dir() {
    printf '/var/www/%s/backups' "$1"
}

site_wp_cli_home() {
    printf '/var/www/%s/.wp-cli' "$1"
}

migrate_legacy_backups() {
    local legacy_dir="$1" destination="$2" marker
    marker="$destination/.legacy-backups-imported-$(printf '%s' "$legacy_dir" | sha256sum | cut -c1-12)"
    [[ -d "$legacy_dir" && ! -e "$marker" ]] || return 0
    rsync -a --ignore-existing --exclude='.incomplete.*' "$legacy_dir/" "$destination/"
    printf 'copied_from=%s\ncopied_at=%s\n' "$legacy_dir" "$(date --iso-8601=seconds)" > "$marker"
    chmod 0600 "$marker"
    log_message INFO "Legacy backups were copied to $destination. Remove $legacy_dir manually after verification."
}

ensure_site_storage() {
    local domain="$1" cache_dir backup_dir wp_cli_home run_user
    run_user="$(site_run_user "$domain")"
    cache_dir="$(site_cache_dir "$domain")"
    backup_dir="$(site_backup_dir "$domain")"
    wp_cli_home="$(site_wp_cli_home "$domain")"
    install -d -o www-data -g www-data -m 0750 "$cache_dir"
    install -d -o "$run_user" -g "$(id -gn "$run_user")" -m 0700 "$wp_cli_home" "$wp_cli_home/cache"
    install -d -o root -g root -m 0700 "$backup_dir"
    migrate_legacy_backups "$LEGACY_BACKUP_ROOT/$domain" "$backup_dir"
    migrate_legacy_backups "$LEGACY_SINGLE_BACKUP_ROOT/$domain" "$backup_dir"
}

site_wp_config_path_is_safe() {
    local wp_path="$1" wp_config canonical_path canonical_config
    wp_config="$wp_path/wp-config.php"
    [[ "$wp_path" == /* && "$wp_path" != / && -d "$wp_path" && ! -L "$wp_path" ]] || return 1
    canonical_path="$(readlink -f -- "$wp_path")" || return 1
    [[ "$canonical_path" == "$wp_path" && -f "$wp_config" && ! -L "$wp_config" ]] || return 1
    canonical_config="$(readlink -f -- "$wp_config")" || return 1
    [[ "$canonical_config" == "$wp_config" ]]
}

site_wp_path_accepts_new_config() {
    local wp_path="$1" wp_config canonical_path
    wp_config="$wp_path/wp-config.php"
    [[ "$wp_path" == /* && "$wp_path" != / && -d "$wp_path" && ! -L "$wp_path" ]] || return 1
    canonical_path="$(readlink -f -- "$wp_path")" || return 1
    [[ "$canonical_path" == "$wp_path" && ! -e "$wp_config" && ! -L "$wp_config" ]]
}

site_wp_cli() (
    local domain="$1" index wp_path wp_config site_home wp_cli_home run_user run_group php_binary
    local status=0 config_write=no config_operation="" config_existed=no restore_status=0
    shift
    index="$(site_index_by_domain "$domain")" || die "Unmanaged site: $domain"
    wp_path="${SITE_PATHS[$index]}"
    wp_config="$wp_path/wp-config.php"
    site_home="/var/www/$domain"
    wp_cli_home="$(site_wp_cli_home "$domain")"
    run_user="$(site_run_user "$domain")"
    run_group="$(id -gn "$run_user")"
    php_binary="/usr/bin/php${SITE_PHP_VERSIONS[$index]}"
    [[ -x "$php_binary" ]] || die "Missing PHP CLI for ${SITE_PHP_VERSIONS[$index]}."
    install -d -o "$run_user" -g "$(id -gn "$run_user")" -m 0700 "$wp_cli_home" "$wp_cli_home/cache"

    if [[ "${1:-}" == config && ("${2:-}" == set || "${2:-}" == delete || "${2:-}" == create) ]]; then
        config_write=yes
        config_operation="${2:-}"
    fi

    # Invoked indirectly by the EXIT trap below.
    # shellcheck disable=SC2317,SC2329
    restore_site_wp_config() {
        local command_status=$?
        trap - EXIT HUP INT TERM
        if [[ "$config_write" == yes && (-e "$wp_config" || -L "$wp_config") ]]; then
            if ! site_wp_config_path_is_safe "$wp_path"; then
                log_message ERROR "Refusing to harden an unsafe wp-config.php path for $domain." >&2
                restore_status=1
            else
                chown root:"$run_group" -- "$wp_config" || restore_status=1
                chmod 0640 -- "$wp_config" || restore_status=1
                if [[ "$(stat -c '%a %U %G' -- "$wp_config" 2>/dev/null || true)" != "640 root $run_group" ]]; then
                    restore_status=1
                fi
            fi
        elif [[ "$config_write" == yes && "$config_existed" == yes ]]; then
            log_message ERROR "wp-config.php disappeared while WP-CLI was running for $domain." >&2
            restore_status=1
        fi
        if ((restore_status != 0)); then
            log_message ERROR "Could not restore secure wp-config.php ownership and mode for $domain." >&2
            exit 1
        fi
        exit "$command_status"
    }

    if [[ "$config_write" == yes ]]; then
        trap restore_site_wp_config EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        if [[ -e "$wp_config" || -L "$wp_config" ]]; then
            config_existed=yes
            site_wp_config_path_is_safe "$wp_path" || \
                die "Refusing a WP-CLI config write through an unsafe WordPress path or wp-config.php symlink."
            chown root:"$run_group" -- "$wp_config"
            chmod 0660 -- "$wp_config"
            [[ "$(stat -c '%a %U %G' -- "$wp_config")" == "660 root $run_group" ]] || \
                die "Could not open the restricted wp-config.php write window for $domain."
        else
            [[ "$config_operation" == create ]] || die "Missing wp-config.php for $domain."
            site_wp_path_accepts_new_config "$wp_path" || \
                die "Refusing to create wp-config.php through an unsafe WordPress path."
        fi
    fi

    cd "$wp_path"
    timeout "${WP_SHELL_WP_TIMEOUT:-600}s" sudo -u "$run_user" env \
        HOME="$site_home" \
        WP_CLI_CACHE_DIR="$wp_cli_home/cache" \
        "$php_binary" /usr/local/bin/wp --path="$wp_path" "$@" || status=$?
    exit "$status"
)

# Read-only WP-CLI queries must not create a per-site cache or repair its
# ownership.  Keep packages and downloads disabled so audit/status paths do
# not leave persistent state behind.  The invoked WordPress command must also
# be observational (for example cron list or db query).
site_wp_cli_readonly() {
    local domain="$1" index wp_path site_home run_user php_binary status=0
    shift
    index="$(site_index_by_domain "$domain")" || return 1
    wp_path="${SITE_PATHS[$index]}"
    site_home="/var/www/$domain"
    run_user="$(site_run_user "$domain")"
    php_binary="/usr/bin/php${SITE_PHP_VERSIONS[$index]}"
    [[ -x "$php_binary" && -d "$wp_path" && -f "$wp_path/wp-config.php" && \
       ! -L "$wp_path" && ! -L "$wp_path/wp-config.php" ]] || return 1
    (
        cd "$wp_path"
        timeout "${WP_SHELL_WP_TIMEOUT:-600}s" sudo -u "$run_user" env \
            HOME="$site_home" \
            WP_CLI_CACHE_DIR=/dev/null \
            WP_CLI_PACKAGES_DIR=/dev/null \
            WP_CLI_CONFIG_PATH=/dev/null \
            WP_CLI_DISABLE_AUTO_CHECK_UPDATE=1 \
            "$php_binary" /usr/local/bin/wp --no-color --skip-plugins --skip-themes \
            --path="$wp_path" "$@"
    ) || status=$?
    return "$status"
}

site_wp_cli_at() {
    local domain="$1" wp_path="$2" index site_home wp_cli_home run_user php_binary
    shift 2
    index="$(site_index_by_domain "$domain")" || die "Unmanaged site: $domain"
    site_home="/var/www/$domain"
    wp_cli_home="$(site_wp_cli_home "$domain")"
    run_user="$(site_run_user "$domain")"
    php_binary="/usr/bin/php${SITE_PHP_VERSIONS[$index]}"
    [[ -x "$php_binary" && -f "$wp_path/wp-config.php" && ! -L "$wp_path" && ! -L "$wp_path/wp-config.php" ]] || \
        die "Unsafe or incomplete WordPress path: $wp_path"
    (
        cd "$wp_path"
        timeout "${WP_SHELL_WP_TIMEOUT:-600}s" sudo -u "$run_user" env \
            HOME="$site_home" WP_CLI_CACHE_DIR="$wp_cli_home/cache" \
            "$php_binary" /usr/local/bin/wp --path="$wp_path" "$@"
    )
}

canonical_staging_path() {
    local domain="$1" requested="$2" root canonical expected
    [[ "$requested" == /* && "$requested" != *$'\n'* && "$requested" != *'/../'* && ! -L "$requested" ]] || return 1
    root="$(readlink -f "$(site_wp_path "$domain")")" || return 1
    canonical="$(readlink -f "$requested")" || return 1
    [[ "$canonical" == "$root"/* && "$canonical" != "$root" && -f "$canonical/wp-config.php" && ! -L "$canonical/wp-config.php" ]] || return 1
    expected="/var/www/$domain/"
    [[ "$canonical" == "$expected"* || "$root" != "/var/www/$domain/public" ]] || return 1
    printf '%s' "$canonical"
}

redact_wp_cli_output() {
    sed -E "s/(--(dbpass|admin_password)=)'[^']*'/\1'[REDACTED]'/g"
}

site_wp_cli_prompt_secret() {
    local domain="$1" secret="$2" output status=0
    shift 2
    if output="$(printf '%s\n' "$secret" | site_wp_cli "$domain" "$@" 2>&1)"; then
        status=0
    else
        status=$?
    fi
    printf '%s\n' "$output" | redact_wp_cli_output
    return "$status"
}

site_wp_config_set_redis_secret() {
    local domain="$1" secret="$2" wp_path wp_config placeholder backup temp_file line original_mode
    local replaced="no" duplicate="no"
    [[ "$secret" =~ ^[a-f0-9]{48}$ ]] || return 1
    wp_path="$(site_wp_path "$domain")"
    wp_config="$wp_path/wp-config.php"
    [[ -f "$wp_config" && ! -L "$wp_config" ]] || return 1
    placeholder="__WP_SHELL_REDIS_SECRET_PLACEHOLDER__"
    original_mode="$(stat -c '%a' "$wp_config")"
    backup="$(mktemp "$wp_path/.wp-config.backup.XXXXXX")"
    temp_file="$(mktemp "$wp_path/.wp-config.secret.XXXXXX")"
    cp --preserve=all "$wp_config" "$backup"
    chmod 0600 "$backup"

    if ! site_wp_cli "$domain" config set WP_REDIS_PASSWORD "$placeholder" --quiet >/dev/null; then
        cp --preserve=all "$backup" "$wp_config"
        chmod "$original_mode" "$wp_config"
        rm -f "$backup" "$temp_file"
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == *"$placeholder"* ]]; then
            [[ "$replaced" == "no" ]] || duplicate="yes"
            line="${line//"$placeholder"/"$secret"}"
            replaced="yes"
        fi
        printf '%s\n' "$line"
    done < "$wp_config" > "$temp_file"
    if [[ "$replaced" != "yes" || "$duplicate" == "yes" ]]; then
        cp --preserve=all "$backup" "$wp_config"
        chmod "$original_mode" "$wp_config"
        rm -f "$backup" "$temp_file"
        return 1
    fi
    chown --reference="$wp_config" "$temp_file"
    chmod "$(site_config_mode "$domain")" "$temp_file"
    mv -f "$temp_file" "$wp_config"
    rm -f "$backup"
}

site_credentials_file() {
    printf '/root/wordpress-credentials-%s.txt' "$1"
}

set_site_permissions() {
    local domain="$1" wp_path site_root run_user dir_mode=0755 file_mode=0644 config_mode=0640 canonical
    wp_path="$(site_wp_path "$domain")"
    canonical="$(readlink -f "$wp_path")" || die "Cannot resolve the WordPress path for $domain."
    [[ "$canonical" == "$wp_path" && "$wp_path" != / && "$wp_path" != /var/www && ! -L "$wp_path" && ! -L "$wp_path/wp-config.php" ]] || \
        die "Refusing to change permissions through an unsafe WordPress path or wp-config.php symlink."
    if [[ "${SITE_MODES[$(site_index_by_domain "$domain")]}" == managed ]]; then
        [[ "$wp_path" == "/var/www/$domain/public" ]] || die "Managed site permissions are confined to /var/www/$domain/public."
    fi
    site_root="/var/www/$domain"
    run_user="$(site_run_user "$domain")"
    if [[ "$run_user" != www-data ]]; then dir_mode=0750; file_mode=0640; fi
    find "$wp_path" -xdev \
        \( -path "$site_root/backups" -o -path "$site_root/cache" -o \
           -path "$site_root/logs" -o -path "$site_root/.wp-cli" \) -prune -o \
        -exec chown -h "$run_user":www-data {} +
    find "$wp_path" -xdev \
        \( -path "$site_root/backups" -o -path "$site_root/cache" -o \
           -path "$site_root/logs" -o -path "$site_root/.wp-cli" \) -prune -o \
        -type d -exec chmod "$dir_mode" {} +
    find "$wp_path" -xdev \
        \( -path "$site_root/backups" -o -path "$site_root/cache" -o \
           -path "$site_root/logs" -o -path "$site_root/.wp-cli" \) -prune -o \
        -type f -exec chmod "$file_mode" {} +
    if [[ -f "$wp_path/wp-config.php" ]]; then
        chown root:"$(id -gn "$run_user")" "$wp_path/wp-config.php"
        chmod "$config_mode" "$wp_path/wp-config.php"
    fi
    chown -R "$run_user":www-data "$site_root/logs"
    chmod 0750 "/var/www/$domain/logs"
    ensure_site_storage "$domain"
    chown -R root:root "$(site_backup_dir "$domain")"
}

wordpress_release_zip_url() {
    local locale="${1:-en_US}" version="${2:-}" response url
    [[ "$locale" =~ ^[A-Za-z0-9_@.-]+$ ]] || die "Invalid WordPress locale: $locale"
    [[ -z "$version" || "$version" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || die "Invalid WordPress version: $version"
    response="$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --get --data-urlencode "locale=$locale" "$WORDPRESS_VERSION_API")" || \
        die "The official WordPress version API could not be reached."
    url="$(jq -r --arg locale "$locale" --arg version "$version" \
        '[.offers[] | select(.locale == $locale and ($version == "" or .current == $version)) | (.packages.full // .download) | select(type == "string" and endswith(".zip"))][0] // empty' \
        <<< "$response")"
    [[ "$url" =~ ^https://downloads[.](wordpress[.]org|w[.]org)/release/[A-Za-z0-9_./@-]+[.]zip$ ]] || \
        die "No official WordPress ZIP release was found for locale $locale${version:+ and version $version}."
    printf '%s' "$url"
}

site_wordpress_locale() {
    local domain="$1" locale
    locale="$(site_wp_cli "$domain" eval 'echo get_locale();' 2>/dev/null || true)"
    [[ "$locale" =~ ^[A-Za-z0-9_@.-]+$ ]] || locale="en_US"
    printf '%s' "$locale"
}

verify_wordpress_core_strict() {
    local domain="$1" locale="${2:-}" version output status=0
    version="$(site_wp_cli "$domain" core version 2>/dev/null || true)"
    [[ "$version" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || return 1
    [[ -n "$locale" ]] || locale="$(site_wordpress_locale "$domain")"
    if output="$(site_wp_cli "$domain" core verify-checksums --version="$version" --locale="$locale" 2>&1)"; then
        status=0
    else
        status=$?
    fi
    printf '%s\n' "$output"
    ((status == 0)) || return 1
    ! grep -Eq "^Warning: File (does not|doesn't|should not) exist:" <<< "$output"
}

repair_wordpress_core() {
    local index="$1" domain wp_path version locale download_url verify_output extra_path target removed=0
    domain="${SITE_DOMAINS[$index]}"
    wp_path="$(site_wp_path "$domain")"
    [[ -f "$wp_path/wp-load.php" && -f "$wp_path/wp-config.php" ]] || die "WordPress core is incomplete for $domain."
    version="$(site_wp_cli "$domain" core version)"
    locale="$(site_wordpress_locale "$domain")"
    download_url="$(wordpress_release_zip_url "$locale" "$version")"
    log_message INFO "Creating a safety backup before repairing WordPress core for $domain."
    backup_site "$index" >/dev/null
    site_wp_cli "$domain" maintenance-mode activate >/dev/null 2>&1 || true
    if ! site_wp_cli "$domain" core download "$download_url" --force --skip-content --locale="$locale"; then
        site_wp_cli "$domain" maintenance-mode deactivate >/dev/null 2>&1 || true
        die "The official WordPress ZIP could not be installed for $domain."
    fi
    verify_output="$(verify_wordpress_core_strict "$domain" "$locale" 2>&1 || true)"
    while IFS= read -r extra_path; do
        extra_path="${extra_path%$'\r'}"
        [[ "$extra_path" =~ ^wp-(admin|includes)/[A-Za-z0-9_./@+-]+$ && "$extra_path" != *'..'* ]] || \
            die "Refusing to remove an unsafe core path reported by WP-CLI: $extra_path"
        target="$wp_path/$extra_path"
        if [[ -f "$target" || -L "$target" ]]; then
            rm -f -- "$target"
            removed=$((removed + 1))
        fi
    done < <(sed -n 's/^Warning: File should not exist: //p' <<< "$verify_output")
    if ! verify_wordpress_core_strict "$domain" "$locale"; then
        site_wp_cli "$domain" maintenance-mode deactivate >/dev/null 2>&1 || true
        die "$domain still fails strict WordPress core verification after repair."
    fi
    set_site_permissions "$domain"
    site_wp_cli "$domain" maintenance-mode deactivate >/dev/null 2>&1 || true
    clear_site_cache "$index"
    log_message SUCCESS "Repaired and strictly verified WordPress $version core for $domain; removed $removed unexpected core file(s)."
}

install_wordpress_site() {
    CURRENT_STEP="install WordPress"
    local index="$1" domain primary wp_path admin_password credentials_file redis_password="" memory_limit download_url db_prefix
    local object_cache
    domain="${SITE_DOMAINS[$index]}"
    primary="${SITE_PRIMARY_DOMAINS[$index]}"
    wp_path="${SITE_PATHS[$index]}"

    if [[ ! -f "$wp_path/wp-load.php" ]]; then
        download_url="$(wordpress_release_zip_url "$WORDPRESS_LOCALE")"
        site_wp_cli "$domain" core download "$download_url" --locale="$WORDPRESS_LOCALE"
        verify_wordpress_core_strict "$domain" "$WORDPRESS_LOCALE" || \
            die "The downloaded WordPress core failed strict checksum verification."
    fi
    transaction_begin "$CURRENT_STEP"
    [[ "$TRANSACTION_ACTIVE" != yes ]] || transaction_backup_file "$wp_path/wp-config.php"
    if [[ ! -f "$wp_path/wp-config.php" ]]; then
        load_database_config "$domain"
        db_prefix="wp_$(printf '%s' "$domain" | sha256sum | cut -c1-8)_"
        site_wp_cli_prompt_secret "$domain" "$DB_PASSWORD" config create \
            --dbname="$DB_NAME" --dbuser="$DB_USER" \
            --dbhost=localhost --dbprefix="$db_prefix" --dbcharset=utf8mb4 --prompt=dbpass
    fi

    site_wp_cli "$domain" config set WP_DEBUG false --raw
    site_wp_cli "$domain" config set FORCE_SSL_ADMIN true --raw
    site_wp_cli "$domain" config set DISALLOW_FILE_EDIT true --raw
    site_wp_cli "$domain" config set WP_ENVIRONMENT_TYPE production
    memory_limit="256M"
    (( $(memory_mb) >= 4096 )) && memory_limit="512M"
    site_wp_cli "$domain" config set WP_MEMORY_LIMIT "$memory_limit"

    if ! site_wp_cli "$domain" core is-installed >/dev/null 2>&1; then
        admin_password="$(generate_password)"
        site_wp_cli_prompt_secret "$domain" "$admin_password" core install \
            --url="https://$primary" \
            --title="${SITE_TITLES[$index]}" \
            --admin_user="${SITE_ADMIN_USERS[$index]}" \
            --admin_email="${SITE_ADMIN_EMAILS[$index]}" --skip-email --prompt=admin_password
        credentials_file="$(site_credentials_file "$domain")"
        {
            printf 'WordPress site credentials\n'
            printf 'Generated: %s\n' "$(date --iso-8601=seconds)"
            printf 'Login URL: https://%s/wp-admin/\n' "$primary"
            printf 'Administrator: %s\n' "${SITE_ADMIN_USERS[$index]}"
            printf 'Administrator password: %s\n' "$admin_password"
            printf 'Administrator email: %s\n' "${SITE_ADMIN_EMAILS[$index]}"
        } > "$credentials_file"
        chmod 0600 "$credentials_file"
        NEW_SITE_CREDENTIAL_DOMAIN="$domain"
        NEW_SITE_ADMIN_PASSWORD="$admin_password"
    fi

    adopt_object_cache_policy "$domain"
    object_cache="$(site_policy_value "$domain" object-cache disabled)"
    if [[ "$object_cache" == enabled ]]; then
        load_or_create_redis_secret
        redis_password="$REDIS_PASSWORD"
        if [[ "$(site_policy_value "$domain" redis-mode)" == isolated ]]; then
            redis_password="$(site_policy_value "$domain" redis-secret)"
            [[ "$redis_password" =~ ^[a-f0-9]{48}$ ]] || die "Invalid private Redis credential."
        fi
        site_wp_cli "$domain" config set WP_REDIS_HOST 127.0.0.1
        site_wp_cli "$domain" config set WP_REDIS_PORT 6379 --raw
        site_wp_config_set_redis_secret "$domain" "$redis_password" || \
            die "The Redis credential could not be written safely for $domain."
        if [[ "$(site_policy_value "$domain" redis-mode)" == isolated ]]; then
            site_wp_cli "$domain" config set WP_REDIS_SCHEME unix
            site_wp_cli "$domain" config set WP_REDIS_PATH "$(site_redis_socket "$domain")"
            site_wp_cli "$domain" config set WP_REDIS_DATABASE 0 --raw
        else
            site_wp_cli "$domain" config set WP_REDIS_DATABASE "${SITE_REDIS_DATABASES[$index]}" --raw
        fi
        site_wp_cli "$domain" config set WP_REDIS_PREFIX "${domain}:"
        site_wp_cli "$domain" plugin install redis-cache --activate
        site_wp_cli "$domain" redis enable
    fi
    if [[ "${SITE_WOOCOMMERCE[$index]}" == "yes" ]]; then
        site_wp_cli "$domain" plugin install woocommerce --activate
    fi
    site_wp_cli "$domain" core is-installed >/dev/null || \
        die "WordPress did not pass the final installation check for $domain."
    set_site_permissions "$domain"
}

install_self() {
    if [[ "$SCRIPT_PATH" != "$MANAGED_SCRIPT" ]] && ! cmp -s "$SCRIPT_PATH" "$MANAGED_SCRIPT" 2>/dev/null; then
        write_managed_file "$MANAGED_SCRIPT" 0755 root root < "$SCRIPT_PATH"
    fi
    write_managed_symlink /usr/local/bin/wp-shell "$MANAGED_SCRIPT"
    write_managed_symlink /usr/local/bin/wp-vps-manager "$MANAGED_SCRIPT"
    write_managed_symlink /usr/local/sbin/wp-vps-manager "$MANAGED_SCRIPT"
    write_managed_symlink /usr/local/sbin/wp-single-manager "$MANAGED_SCRIPT"
    local i legacy_wrapper
    for ((i = 1; i <= SITE_COUNT; i++)); do
        legacy_wrapper="/usr/local/bin/manage-${SITE_DOMAINS[$i]}"
        if [[ -f "$legacy_wrapper" || -L "$legacy_wrapper" ]]; then
            remove_managed_file "$legacy_wrapper"
            log_message INFO "Removed legacy site shortcut: $legacy_wrapper"
        fi
    done
}

deploy_site() {
    local index="$1" domain
    domain="${SITE_DOMAINS[$index]}"
    log_message INFO "Deploying $domain with PHP ${SITE_PHP_VERSIONS[$index]}."
    create_site_directories "$domain" "${SITE_PATHS[$index]}"
    if [[ ! -f "${SITE_PATHS[$index]}/wp-config.php" ]]; then
        ensure_site_database "$domain"
    fi
    if [[ ! -s "/etc/letsencrypt/live/$domain/fullchain.pem" || ! -f "/etc/nginx/sites-available/$domain" ]]; then
        configure_acme_site "$index"
    fi
    issue_ssl_certificate "$index"
    configure_https_site "$index"
    install_wordpress_site "$index"
    clear_site_cache "$index"
    SITE_MODES[index]="managed"
    save_sites_config
    log_message SUCCESS "$domain deployment is complete."
}

collect_yes_no() {
    local prompt="$1" default="${2:-no}" answer
    if [[ "$default" == "yes" ]]; then
        read -r -p "$prompt [Y/n]: " answer
        answer="${answer:-y}"
    else
        read -r -p "$prompt [y/N]: " answer
        answer="${answer:-n}"
    fi
    [[ "$answer" =~ ^[Yy]$ ]]
}

collect_site_input() {
    local next_index=$((SITE_COUNT + 1)) domain email admin title www woo primary redis_db max_sites
    local page_cache object_cache
    max_sites="$(max_sites_for_memory "$(memory_mb)")"
    if [[ "$ENVIRONMENT_MODE" == "single" ]]; then
        max_sites=1
    fi
    ((next_index <= max_sites)) || die "The current memory policy allows at most $max_sites managed site(s)."

    while true; do
        read -r -p "Domain without www: " domain
        domain="${domain,,}"
        validate_domain "$domain" || { log_message WARNING "Invalid domain format."; continue; }
        if site_index_by_domain "$domain" >/dev/null 2>&1; then
            log_message WARNING "That domain is already managed."
            continue
        fi
        break
    done

    while true; do
        read -r -p "Administrator email: " email
        validate_email "$email" && break
        log_message WARNING "Invalid email address."
    done
    read -r -p "Administrator username [wpadmin]: " admin
    admin="${admin:-wpadmin}"
    [[ "$admin" =~ ^[a-zA-Z0-9_.-]{4,60}$ ]] || die "Invalid administrator username."
    read -r -p "Site title [$domain]: " title
    title="${title:-$domain}"
    collect_yes_no "Include www.$domain in the certificate (DNS must resolve)" no && www=yes || www=no
    primary="$domain"
    if [[ "$www" == "yes" ]] && collect_yes_no "Use www.$domain as the canonical domain" no; then
        primary="www.$domain"
    fi
    collect_yes_no "Install WooCommerce" no && woo=yes || woo=no
    collect_yes_no "Enable Nginx FastCGI page cache for anonymous visitors" no && page_cache=enabled || page_cache=disabled
    collect_yes_no "Install and enable the Redis Object Cache integration" no && object_cache=enabled || object_cache=disabled
    redis_db="$(first_available_redis_database)" || die "No Redis database is available."

    SITE_COUNT=$next_index
    SITE_DOMAINS[next_index]="$domain"
    SITE_PRIMARY_DOMAINS[next_index]="$primary"
    SITE_PHP_VERSIONS[next_index]="$DEFAULT_PHP_VERSION"
    SITE_WOOCOMMERCE[next_index]="$woo"
    SITE_WWW[next_index]="$www"
    SITE_REDIS_DATABASES[next_index]="$redis_db"
    SITE_ADMIN_USERS[next_index]="$admin"
    SITE_ADMIN_EMAILS[next_index]="$email"
    SITE_TITLES[next_index]="$title"
    SITE_PATHS[next_index]="/var/www/$domain/public"
    SITE_MODES[next_index]="managed"
    save_sites_config
    set_site_policy "$domain" page-cache "$page_cache"
    set_site_policy "$domain" object-cache "$object_cache"
}

prepare_stack() {
    check_capacity
    install_system_packages
    configure_mariadb
    configure_redis
    configure_php
    configure_fail2ban
    configure_log_rotation
    install_certbot_deploy_hook
    disable_distribution_nginx_default
    systemctl enable --now nginx
    install_self
}

validate_ipv4() {
    local address="$1" octet
    local -a octets=()
    [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
        ((10#$octet <= 255)) || return 1
    done
}

public_ipv4_candidate() {
    local address="$1" first second _rest
    validate_ipv4 "$address" || return 1
    IFS='.' read -r first second _rest <<< "$address"
    ((10#$first > 0 && 10#$first < 224)) || return 1
    case "$first" in
        10|127) return 1 ;;
        100) ((10#$second < 64 || 10#$second > 127)) || return 1 ;;
        169) ((10#$second != 254)) || return 1 ;;
        172) ((10#$second < 16 || 10#$second > 31)) || return 1 ;;
        192) ((10#$second != 168)) || return 1 ;;
    esac
}

detect_private_ipv4() {
    local address
    address="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
    validate_ipv4 "$address" && printf '%s' "$address"
}

detect_public_ipv4() {
    local address token
    if [[ -n "${WP_SHELL_PUBLIC_IPV4:-}" ]]; then
        public_ipv4_candidate "$WP_SHELL_PUBLIC_IPV4" || return 1
        printf '%s' "$WP_SHELL_PUBLIC_IPV4"
        return
    fi

    token="$(curl --silent --fail --connect-timeout 1 --max-time 2 \
        --request PUT --header 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
        http://169.254.169.254/latest/api/token 2>/dev/null || true)"
    if [[ -n "$token" ]]; then
        address="$(curl --silent --fail --connect-timeout 1 --max-time 2 \
            --header "X-aws-ec2-metadata-token: $token" \
            http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
        if public_ipv4_candidate "$address"; then
            printf '%s' "$address"
            return
        fi
    fi

    while IFS= read -r address; do
        if public_ipv4_candidate "$address"; then
            printf '%s' "$address"
            return
        fi
    done < <(ip -4 -o address show scope global 2>/dev/null | awk '{split($4, value, "/"); print value[1]}')
    return 1
}

environment_firewall_state() {
    if [[ "$ENVIRONMENT_UFW" != "yes" ]]; then
        printf 'skipped by user'
        return
    fi
    ufw status 2>/dev/null | awk 'NR == 1 {print tolower($2)}'
}

show_environment_summary() {
    local public_ip private_ip max_sites firewall_state
    public_ip="$(detect_public_ipv4 || true)"
    private_ip="$(detect_private_ipv4 || true)"
    max_sites="$(max_sites_for_memory "$(memory_mb)")"
    [[ "$ENVIRONMENT_MODE" == "single" ]] && max_sites=1
    firewall_state="$(environment_firewall_state)"
    [[ -n "$firewall_state" ]] || firewall_state="unknown"

    printf '\nEnvironment installation complete\n'
    printf '%s\n' '================================='
    printf 'wp-shell       %s\n' "$WP_SHELL_VERSION"
    printf 'Mode           %s\n' "$ENVIRONMENT_MODE"
    printf 'PHP            %s\n' "$DEFAULT_PHP_VERSION"
    printf 'Public IPv4    %s\n' "${public_ip:-not detected - check the VPS provider console}"
    if [[ -n "$private_ip" && "$private_ip" != "$public_ip" ]]; then
        printf 'Private IPv4   %s (do not use for public DNS)\n' "$private_ip"
    fi
    printf 'Firewall       %s\n' "$firewall_state"
    printf 'Site capacity  %s/%s\n' "$SITE_COUNT" "$max_sites"
    printf 'Services       nginx:%s php:%s mariadb:%s redis:%s fail2ban:%s\n' \
        "$(service_state nginx)" "$(service_state "php${DEFAULT_PHP_VERSION}-fpm")" \
        "$(service_state mariadb)" "$(service_state redis-server)" "$(service_state fail2ban)"
    printf 'Automation     backups:%s metrics:%s\n' \
        "$(service_state wp-shell-backup.timer)" "$(service_state wp-shell-metrics.timer)"

    printf '\nDNS required before adding a WordPress website:\n'
    if [[ -n "$public_ip" ]]; then
        printf -- '- Root domain: A -> %s\n' "$public_ip"
    else
        printf -- '- Find or assign the public IPv4 in the VPS provider console.\n'
        printf -- '- Root domain: A -> that public IPv4\n'
    fi
    printf -- '- www: CNAME -> root domain (or A -> the same public IPv4)\n'
    printf -- '- Provider firewall/security group: allow TCP 80 and 443\n'
    printf -- "- After DNS resolves: sudo wp-shell -> 'Add a new website'\n"
    printf 'Verify the public IPv4 in the VPS provider console before changing DNS.\n\n'
}

bootstrap_server() {
    prepare_stack
    if [[ "$ENVIRONMENT_UFW" == "yes" ]]; then
        configure_firewall
    else
        log_message INFO "UFW configuration was skipped."
    fi
    install_self
    install_backup_timer
    install_metrics_timer
    collect_metrics
    show_environment_summary
}

site_wp_path() {
    local index
    index="$(site_index_by_domain "$1")" || return 1
    printf '%s' "${SITE_PATHS[$index]}"
}

site_http_status() {
    local domain="$1" code
    code="$(curl --silent --show-error --output /dev/null --max-time 8 --write-out '%{http_code}' "https://$domain" 2>/dev/null || true)"
    [[ "$code" =~ ^[23][0-9]{2}$ ]] && printf 'healthy (HTTP %s)' "$code" || printf 'unhealthy (HTTP %s)' "${code:-000}"
}

site_status() {
    local index="$1" domain php_version
    domain="${SITE_DOMAINS[$index]}"
    php_version="${SITE_PHP_VERSIONS[$index]}"
    printf 'Site: %s\n' "$domain"
    printf '  HTTPS: %s\n' "$(site_http_status "${SITE_PRIMARY_DOMAINS[$index]}")"
    printf '  Nginx: %s\n' "$(systemctl is-active nginx 2>/dev/null || true)"
    printf '  PHP-FPM: %s\n' "$(systemctl is-active "php${php_version}-fpm" 2>/dev/null || true)"
    printf '  MariaDB: %s\n' "$(systemctl is-active mariadb 2>/dev/null || true)"
    if [[ "$(site_policy_value "$domain" object-cache disabled)" != enabled ]]; then
        printf '  Object cache: disabled\n'
    elif [[ "$(site_policy_value "$domain" redis-mode)" == isolated ]]; then
        printf '  Object cache: %s (private Redis socket)\n' "$(systemctl is-active "wp-shell-redis-$(site_pool_id "$domain")" 2>/dev/null || true)"
    else
        printf '  Object cache: %s (shared Redis)\n' "$(systemctl is-active redis-server 2>/dev/null || true)"
    fi
    printf '  Page cache: %s\n' "$(site_policy_value "$domain" page-cache disabled)"
}

site_tls_expiry() {
    local domain="$1" certificate end_date
    certificate="/etc/letsencrypt/live/$domain/fullchain.pem"
    [[ -s "$certificate" ]] || { printf 'missing'; return; }
    end_date="$(openssl x509 -in "$certificate" -noout -enddate 2>/dev/null | cut -d= -f2- || true)"
    [[ -n "$end_date" ]] || { printf 'unknown'; return; }
    date --utc --date="$end_date" +%F 2>/dev/null || printf 'unknown'
}

show_new_site_credentials_once() {
    local index="$1" domain credentials_file
    domain="${SITE_DOMAINS[$index]}"
    [[ "$NEW_SITE_CREDENTIAL_DOMAIN" == "$domain" && -n "$NEW_SITE_ADMIN_PASSWORD" ]] || return 0
    credentials_file="$(site_credentials_file "$domain")"

    if [[ "$TERMINAL_DEVICE" != "/dev/tty" || -t 0 ]]; then
        if {
            printf '\nNew WordPress administrator credentials (shown once)\n'
            printf '%s\n' '===================================================='
            printf 'Login URL      https://%s/wp-admin/\n' "${SITE_PRIMARY_DOMAINS[$index]}"
            printf 'Administrator  %s\n' "${SITE_ADMIN_USERS[$index]}"
            printf 'Password       %s\n' "$NEW_SITE_ADMIN_PASSWORD"
            printf 'Credentials    %s\n' "$credentials_file"
            printf '\nThis password was written directly to the terminal and not to wp-shell logs.\n'
            printf 'Save it securely, then remove the credentials file.\n\n'
        } > "$TERMINAL_DEVICE"; then
            :
        else
            log_message WARNING "Could not display the generated password on the terminal. Read it with: sudo cat $credentials_file"
        fi
    else
        log_message WARNING "No interactive terminal is available. Read the generated password with: sudo cat $credentials_file"
    fi

    NEW_SITE_ADMIN_PASSWORD=""
    NEW_SITE_CREDENTIAL_DOMAIN=""
}

show_site_deployment_summary() {
    local index="$1" domain primary aliases wordpress_version woo_state credentials_file credentials_state
    domain="${SITE_DOMAINS[$index]}"
    primary="${SITE_PRIMARY_DOMAINS[$index]}"
    aliases="none"
    [[ "${SITE_WWW[$index]}" == "yes" ]] && aliases="www.$domain"
    wordpress_version="$(site_wp_cli "$domain" core version 2>/dev/null || printf 'unknown')"
    if site_wp_cli "$domain" plugin is-active woocommerce >/dev/null 2>&1; then
        woo_state="active"
    else
        woo_state="not installed"
    fi
    credentials_file="$(site_credentials_file "$domain")"
    if [[ -f "$credentials_file" ]]; then
        credentials_state="$credentials_file (root-only)"
    else
        credentials_state="existing WordPress credentials"
    fi

    printf '\nWebsite deployment complete\n'
    printf '%s\n' '==========================='
    printf 'Website        https://%s/\n' "$primary"
    printf 'Admin          https://%s/wp-admin/\n' "$primary"
    printf 'Domain         %s\n' "$domain"
    printf 'Aliases        %s\n' "$aliases"
    printf 'Administrator  %s <%s>\n' "${SITE_ADMIN_USERS[$index]}" "${SITE_ADMIN_EMAILS[$index]}"
    printf 'WordPress      %s (%s)\n' "$wordpress_version" "$WORDPRESS_LOCALE"
    printf 'PHP            %s\n' "${SITE_PHP_VERSIONS[$index]}"
    printf 'WooCommerce    %s\n' "$woo_state"
    if [[ "$(site_policy_value "$domain" object-cache disabled)" != enabled ]]; then
        printf 'Object cache   disabled\n'
    elif [[ "$(site_policy_value "$domain" redis-mode)" == isolated ]]; then
        printf 'Redis cache    enabled (private Unix socket, DB 0)\n'
    else
        printf 'Redis cache    enabled (shared instance, DB %s)\n' "${SITE_REDIS_DATABASES[$index]}"
    fi
    printf 'Page cache     %s\n' "$(site_policy_value "$domain" page-cache disabled)"
    printf 'TLS expires    %s\n' "$(site_tls_expiry "$domain")"
    printf 'Document root  %s\n' "${SITE_PATHS[$index]}"
    printf 'Credentials    %s\n' "$credentials_state"
    printf 'Health         %s | nginx:%s | php:%s\n' \
        "$(site_http_status "$primary")" "$(service_state nginx)" \
        "$(service_state "php${SITE_PHP_VERSIONS[$index]}-fpm")"
    printf '\nNext steps:\n'
    if [[ -f "$credentials_file" ]]; then
        printf -- '- Read credentials: sudo cat %s\n' "$credentials_file"
        printf -- '- Save the password securely, then remove the credentials file.\n'
    fi
    printf -- '- Monitor the website: sudo wp-shell dashboard\n\n'
    show_new_site_credentials_once "$index"
}

create_mysql_defaults_file() {
    local domain="$1" defaults_file db_user db_password db_host escaped_password
    defaults_file="$(mktemp /run/wp-vps-mysql.XXXXXX)" || return 1
    if ! db_user="$(site_wp_cli "$domain" config get DB_USER)" ||
       ! db_password="$(site_wp_cli "$domain" config get DB_PASSWORD)" ||
       ! db_host="$(site_wp_cli "$domain" config get DB_HOST)"; then
        rm -f "$defaults_file"
        log_message ERROR "Could not read database connection settings for $domain." >&2
        return 1
    fi
    if [[ ! "$db_user" =~ ^[a-zA-Z0-9_\$-]{1,64}$ || "$db_user" == root ||
          ! "$db_host" =~ ^[a-zA-Z0-9_.:-]+$ || "$db_password" == *$'\n'* || "$db_password" == *$'\r'* ]]; then
        rm -f "$defaults_file"
        log_message ERROR "Unsafe database connection settings for $domain; use a dedicated database user." >&2
        return 1
    fi
    escaped_password="${db_password//\\/\\\\}"
    escaped_password="${escaped_password//\"/\\\"}"
    {
        printf '[client]\n'
        printf 'user=%s\n' "$db_user"
        printf 'password="%s"\n' "$escaped_password"
        printf 'host=%s\n' "$db_host"
    } > "$defaults_file" || { rm -f "$defaults_file"; return 1; }
    chmod 0600 "$defaults_file" || { rm -f "$defaults_file"; return 1; }
    printf '%s' "$defaults_file"
}

verify_backup_directory() {
    local directory="$1" domain="$2"
    [[ -d "$directory" && ! -L "$directory" && -s "$directory/SHA256SUMS" ]] || return 1
    awk '
        BEGIN {expected["files.tar.gz"]=1; expected["database.sql.gz"]=1; expected["manifest.txt"]=1}
        NF != 2 || length($1) != 64 || $1 !~ /^[[:xdigit:]]+$/ || !($2 in expected) || seen[$2]++ {bad=1}
        END {exit (bad || NR != 3)}' "$directory/SHA256SUMS" || return 1
    (cd "$directory" && sha256sum --strict --check SHA256SUMS >/dev/null) || return 1
    grep -Fxq "domain=$domain" "$directory/manifest.txt" || return 1
    gzip -t "$directory/database.sql.gz" || return 1
    tar -tzf "$directory/files.tar.gz" >/dev/null || return 1
}

site_policy_value() {
    local domain="$1" key="$2" fallback="${3:-}" path
    validate_domain "$domain" && [[ "$key" =~ ^[a-z-]+$ ]] || return 1
    path="$SITE_POLICY_DIR/$domain/$key"
    if [[ -f "$path" && ! -L "$path" ]]; then
        head -n 1 "$path"
    else
        printf '%s' "$fallback"
    fi
}

site_policy_is_set() {
    local domain="$1" key="$2"
    validate_domain "$domain" && [[ "$key" =~ ^[a-z-]+$ ]] || return 1
    [[ -f "$SITE_POLICY_DIR/$domain/$key" && ! -L "$SITE_POLICY_DIR/$domain/$key" ]]
}

set_site_policy() {
    local domain="$1" key="$2" value="$3" target
    validate_domain "$domain" && [[ "$key" =~ ^[a-z-]+$ && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    install -d -m 0700 "$SITE_POLICY_DIR" "$SITE_POLICY_DIR/$domain"
    target="$SITE_POLICY_DIR/$domain/$key"
    write_managed_file "$target" 0600 root root <<EOF
$value
EOF
}

adopt_object_cache_policy() {
    local domain="$1"
    site_policy_is_set "$domain" object-cache && return 0
    if site_wp_cli "$domain" plugin is-active redis-cache >/dev/null 2>&1; then
        set_site_policy "$domain" object-cache enabled
        log_message INFO "$domain: adopted the already-active Redis Object Cache integration."
    else
        set_site_policy "$domain" object-cache disabled
    fi
}

host_policy_value() {
    local key="$1" fallback="${2:-}" value
    [[ "$key" =~ ^[a-z][a-z0-9-]*$ ]] || return 1
    [[ -f "$HOST_POLICY_FILE" && ! -L "$HOST_POLICY_FILE" ]] || { printf '%s' "$fallback"; return 0; }
    value="$(awk -F '|' -v key="$key" '$1==key {print substr($0,length($1)+2); found=1} END{exit !found}' "$HOST_POLICY_FILE" 2>/dev/null || true)"
    printf '%s' "${value:-$fallback}"
}

set_host_policy() {
    local key="$1" value="$2" temp
    [[ "$key" =~ ^[a-z][a-z0-9-]*$ && "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *'|'* ]] || return 1
    temp="$(mktemp "${TMPDIR:-/tmp}/wp-shell-host-policy.XXXXXXXX")"
    if [[ -f "$HOST_POLICY_FILE" && ! -L "$HOST_POLICY_FILE" ]]; then
        awk -F '|' -v key="$key" '$1!=key' "$HOST_POLICY_FILE" > "$temp"
    fi
    printf '%s|%s\n' "$key" "$value" >> "$temp"
    sort -u -o "$temp" "$temp"
    write_managed_file "$HOST_POLICY_FILE" 0600 root root < "$temp"
    rm -f -- "$temp"
}

validate_encrypted_remote() {
    local remote="$1" name
    [[ "$remote" =~ ^[a-zA-Z0-9_-]+:[a-zA-Z0-9_./-]*$ && "$remote" != *..* ]] || return 1
    name="${remote%%:*}"
    # Only the selected remote type is inspected. Never print credentials/config dump.
    rclone config dump 2>/dev/null | jq -e --arg name "$name" '.[$name].type == "crypt"' >/dev/null
}

upload_remote_backup() {
    local domain="$1" directory="$2" remote target
    remote="$(site_policy_value "$domain" backup-remote)"
    [[ -n "$remote" ]] || return 0
    require_command rclone
    validate_encrypted_remote "$remote" || { log_message ERROR "The configured remote must be an existing rclone crypt remote." >&2; return 1; }
    target="${remote%/}/$domain/$(basename "$directory")"
    if ! timeout 2h rclone copy -- "$directory" "$target" ||
        ! timeout 2h rclone check --download -- "$directory" "$target"; then
            log_message ERROR "Remote upload/verification failed. The verified local backup was retained; local retention was skipped." >&2
            return 1
    fi
    log_message SUCCESS "Encrypted remote backup verified for $domain. Remote backups are never deleted automatically." >&2
}

backup_command() {
    local action="${1:-}" domain index remote directory backup_id
    case "$action" in
        remote)
            domain="$(site_domain_from_selector "${2:-}")" || die "Unknown site ID or domain."
            remote="${3:-status}"
            case "$remote" in
                status) printf 'Remote: %s\n' "$(site_policy_value "$domain" backup-remote disabled)" ;;
                off) set_site_policy "$domain" backup-remote ''; log_message INFO "Remote upload disabled; existing remote files were not removed." ;;
                *) require_command rclone; validate_encrypted_remote "$remote" || die "Configure an encrypted rclone crypt remote as root first."
                   set_site_policy "$domain" backup-remote "$remote"
                   log_message SUCCESS "Future backups of $domain will also be uploaded and verified on the encrypted remote."
                   ;;
            esac
            ;;
        verify|drill)
            domain="$(site_domain_from_selector "${2:-}")" || die "Unknown site ID or domain."
            backup_id="${3:-latest}"
            if [[ "$backup_id" == latest ]]; then
                backup_id="$(find "$(site_backup_dir "$domain")" -mindepth 1 -maxdepth 1 -type d -name '20??????-??????' -printf '%f\n' | sort -r | head -n 1)"
            fi
            [[ "$backup_id" =~ ^20[0-9]{6}-[0-9]{6}$ ]] || die "No valid backup ID was selected."
            directory="$(site_backup_dir "$domain")/$backup_id"
            verify_backup_directory "$directory" "$domain" || die "Backup verification failed."
            if [[ "$action" == drill ]]; then backup_restore_drill "$domain" "$directory"; fi
            log_message SUCCESS "$domain $backup_id: $action completed."
            ;;
        '') die "Usage: wp-shell backup DOMAIN|ID, or backup verify|drill|remote DOMAIN|ID [VALUE]" ;;
        *) index="$(site_domain_from_selector "$action")" || die "Unknown site ID or domain."; site_action "$index" backup ;;
    esac
}

validate_restore_archive() {
    python3 - "$1" <<'PY'
import sys, tarfile, posixpath
with tarfile.open(sys.argv[1], "r:gz") as archive:
    for member in archive:
        path = posixpath.normpath(member.name)
        if path.startswith("/") or path == ".." or path.startswith("../") or member.isdev():
            raise SystemExit("Unsafe archive member; restore refused.")
        if member.issym() or member.islnk():
            raise SystemExit("Archive contains links; review them before a privileged restore.")
PY
}

cleanup_restore_drill() {
    local database="$1" directory="$2"
    [[ "$database" =~ ^drill_[a-f0-9]{12}$ && "$directory" == /tmp/wp-shell-drill.* ]] || return 1
    mariadb --protocol=socket -e "DROP DATABASE IF EXISTS \`$database\`; DROP USER IF EXISTS '$database'@'localhost';" >/dev/null 2>&1 || true
    rm -rf -- "$directory"
}

backup_restore_drill() (
    local domain="$1" directory="$2" stage drill_db password defaults tables
    require_command python3
    stage="$(mktemp -d /tmp/wp-shell-drill.XXXXXX)"
    drill_db="drill_$(openssl rand -hex 6)"
    password="$(generate_password)"
    defaults="$stage/mysql.cnf"
    # The dump is untrusted SQL: execute only as a temporary user confined to an empty DB.
    # Capture immutable cleanup arguments before function-local scopes unwind.
    # shellcheck disable=SC2064
    trap "$(printf 'cleanup_restore_drill %q %q' "$drill_db" "$stage")" EXIT
    validate_restore_archive "$directory/files.tar.gz" || exit 1
    mkdir "$stage/files"
    tar --no-same-owner --no-same-permissions -xzf "$directory/files.tar.gz" -C "$stage/files"
    [[ -f "$stage/files/wp-config.php" ]] || die "Backup is missing wp-config.php."
    mariadb --protocol=socket <<SQL
CREATE DATABASE \`$drill_db\`;
CREATE USER '$drill_db'@'localhost' IDENTIFIED BY '$password';
GRANT ALL PRIVILEGES ON \`$drill_db\`.* TO '$drill_db'@'localhost';
SQL
    printf '[client]\nuser=%s\npassword=%s\nhost=localhost\n' "$drill_db" "$password" > "$defaults"
    # shellcheck disable=SC2016
    timeout 30m bash -o pipefail -c 'gzip -dc -- "$1" | mariadb --defaults-extra-file="$2" --binary-mode --local-infile=0 "$3"' _ "$directory/database.sql.gz" "$defaults" "$drill_db" || exit 1
    tables="$(mariadb --defaults-extra-file="$defaults" --batch --skip-column-names -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$drill_db';")"
    ((tables > 0)) || die "The restored database contains no tables."
    log_message SUCCESS "$domain: files extracted and $tables tables restored to a disposable database. No website/PHP code was executed; this is not a full application acceptance test."
    exit 0
)

backup_site() (
    CURRENT_STEP="back up the site"
    local index="$1" domain wp_path timestamp site_backup_root temp_dir final_dir defaults_file db_name
    local required_kb free_kb database_kb
    temp_dir=""; defaults_file=""
    trap '[[ -z "$defaults_file" ]] || rm -f -- "$defaults_file"; [[ -z "$temp_dir" ]] || rm -rf -- "$temp_dir"' EXIT
    domain="${SITE_DOMAINS[$index]}"
    wp_path="$(site_wp_path "$domain")"
    [[ -f "$wp_path/wp-config.php" ]] || { log_message ERROR "WordPress is not installed for $domain." >&2; exit 1; }
    [[ "$BACKUP_RETENTION_DAYS" =~ ^(0|[1-9][0-9]{0,3})$ ]] || exit 1
    timestamp="$(date +%Y%m%d-%H%M%S)"
    ensure_site_storage "$domain" || exit 1
    site_backup_root="$(site_backup_dir "$domain")"
    # Imported layouts can place private storage below the document root.
    # Exclude those exact directories, never recursively back up old backups.
    local storage_path relative_path
    local -a archive_excludes=(--exclude='./wp-content/cache/*' --exclude='./wp-content/uploads/cache/*')
    local -a size_excludes=()
    for storage_path in "$site_backup_root" "$(site_cache_dir "$domain")" "$(site_wp_cli_home "$domain")" "/var/www/$domain/logs"; do
        [[ -e "$storage_path" ]] || continue
        storage_path="$(readlink -f "$storage_path")" || exit 1
        if [[ "$storage_path/" == "$(readlink -f "$wp_path")/"* ]]; then
            relative_path="${storage_path#"$(readlink -f "$wp_path")/"}"
            [[ "$relative_path" != "$storage_path" && -n "$relative_path" ]] || exit 1
            archive_excludes+=("--exclude=./$relative_path")
            size_excludes+=("--exclude=$relative_path")
        fi
    done
    required_kb="$(du -sk "${size_excludes[@]}" -- "$wp_path" | awk '{print $1}')" || exit 1
    free_kb="$(df -Pk "$site_backup_root" | awk 'NR==2 {print $4}')" || exit 1
    if [[ ! "$required_kb" =~ ^[0-9]+$ || ! "$free_kb" =~ ^[0-9]+$ ]] || ((free_kb <= required_kb + 262144)); then
        log_message ERROR "Insufficient free disk for a conservative file backup estimate plus 256MB reserve." >&2; exit 1;
    fi
    temp_dir="$(mktemp -d "$site_backup_root/.incomplete.XXXXXX")" || exit 1
    final_dir="$site_backup_root/$timestamp"
    [[ ! -e "$final_dir" ]] || { log_message ERROR "A backup already exists for this second; retry shortly." >&2; exit 1; }
    defaults_file="$(create_mysql_defaults_file "$domain")" || exit 1
    db_name="$(site_wp_cli "$domain" config get DB_NAME)" || exit 1
    [[ "$db_name" =~ ^[a-zA-Z0-9_\$-]{1,64}$ ]] || exit 1
    database_kb="$(mariadb --defaults-extra-file="$defaults_file" --connect-timeout=5 --batch --skip-column-names -e "SELECT COALESCE(CEIL(SUM(data_length+index_length)/1024),0) FROM information_schema.tables WHERE table_schema='$db_name';")" || exit 1
    [[ "$database_kb" =~ ^[0-9]+$ ]] || exit 1
    if ((free_kb <= required_kb + database_kb*2 + 262144)); then
        log_message ERROR "Insufficient disk for files, a conservative database dump estimate and 256MB reserve." >&2; exit 1
    fi

    if ! tar "${archive_excludes[@]}" -czf "$temp_dir/files.tar.gz" -C "$wp_path" .; then
        log_message ERROR "File backup failed for $domain." >&2; exit 1
    fi
    if ! mariadb-dump --defaults-extra-file="$defaults_file" --single-transaction --quick --routines --triggers --add-drop-table "$db_name" | gzip -9 > "$temp_dir/database.sql.gz"; then
        log_message ERROR "Database backup failed for $domain." >&2; exit 1
    fi
    rm -f "$defaults_file" || exit 1
    defaults_file=""
    local core_version
    core_version="$(site_wp_cli "$domain" core version)" || exit 1
    {
        printf 'domain=%s\n' "$domain"
        printf 'database_name=%s\n' "$db_name"
        printf 'created_at=%s\n' "$(date --iso-8601=seconds)"
        printf 'wordpress_version=%s\n' "$core_version"
    } > "$temp_dir/manifest.txt" || exit 1
    (cd "$temp_dir" && sha256sum files.tar.gz database.sql.gz manifest.txt > SHA256SUMS) || {
        log_message ERROR "Backup checksum generation failed for $domain." >&2; exit 1;
    }
    verify_backup_directory "$temp_dir" "$domain" || { log_message ERROR "Backup verification failed for $domain." >&2; exit 1; }
    mv -T "$temp_dir" "$final_dir" || exit 1
    temp_dir=""
    upload_remote_backup "$domain" "$final_dir" || exit 1
    if ((BACKUP_RETENTION_DAYS > 0)); then
        find "$site_backup_root" -mindepth 1 -maxdepth 1 -type d -name '20??????-??????' \
            -mtime "+$BACKUP_RETENTION_DAYS" -exec rm -rf -- {} + || exit 1
    fi
    log_message SUCCESS "Backup completed: $final_dir"
    printf '%s\n' "$final_dir"
    exit 0
)

restore_site() {
    CURRENT_STEP="restore the site"
    local index="$1" backup_id="$2" domain wp_path backup_dir defaults_file db_name
    domain="${SITE_DOMAINS[$index]}"
    wp_path="$(site_wp_path "$domain")"
    [[ "$backup_id" =~ ^20[0-9]{6}-[0-9]{6}$ ]] || die "Invalid backup ID format."
    ensure_site_storage "$domain"
    backup_dir="$(site_backup_dir "$domain")/$backup_id"
    [[ -d "$backup_dir" ]] || die "Backup not found: $backup_dir"
    verify_backup_directory "$backup_dir" "$domain" || die "Backup verification failed; nothing was restored."
    validate_restore_archive "$backup_dir/files.tar.gz" || die "Unsafe archive; nothing was restored."
    grep -Fq '.wp-shell-maintenance' "/etc/nginx/sites-available/$domain" || die "Apply the maintenance-capable Nginx template before restoring."
    [[ ! -e "/var/www/$domain/.wp-shell-maintenance" ]] || die "Site is already in maintenance mode; resolve that operation first."
    log_message INFO "Creating a safety backup before restore."
    backup_site "$index" >/dev/null
    defaults_file="$(create_mysql_defaults_file "$domain")"
    db_name="$(site_wp_cli "$domain" config get DB_NAME)"

    (
        set -Eeuo pipefail
        local_stage="$(mktemp -d /tmp/wp-restore.XXXXXX)"
        # shellcheck disable=SC2317,SC2329
        cleanup_restore() {
            rm -rf -- "$local_stage"
            rm -f "$defaults_file"
        }
        trap cleanup_restore EXIT
        tar -xzf "$backup_dir/files.tar.gz" -C "$local_stage"
        [[ -f "$local_stage/wp-config.php" ]]
        install -m 0600 /dev/null "/var/www/$domain/.wp-shell-maintenance"
        site_wp_cli "$domain" maintenance-mode activate >/dev/null 2>&1 || true
        local storage_path relative_path
        local -a restore_excludes=()
        for storage_path in "$(site_backup_dir "$domain")" "$(site_cache_dir "$domain")" "$(site_wp_cli_home "$domain")" "/var/www/$domain/logs"; do
            if [[ "$storage_path/" == "$wp_path/"* ]]; then
                relative_path="${storage_path#"$wp_path/"}"
                restore_excludes+=("--exclude=/$relative_path/")
            fi
        done
        rsync -a --delete "${restore_excludes[@]}" "$local_stage/" "$wp_path/"
        gzip -dc "$backup_dir/database.sql.gz" | mariadb --defaults-extra-file="$defaults_file" --binary-mode --local-infile=0 "$db_name"
        set_site_permissions "$domain"
        [[ "${SITE_MODES[$index]}" != managed ]] || apply_site_redis_connection "$domain"
        site_wp_cli "$domain" core is-installed
        site_wp_cli "$domain" maintenance-mode deactivate >/dev/null
    )
    clear_site_cache "$index" all
    rm -f -- "/var/www/$domain/.wp-shell-maintenance"
    log_message SUCCESS "$domain was restored to $backup_id."
}

clear_site_cache() {
    local index="$1" scope="${2:-page}" domain wp_path cache_dir legacy_cache_dir
    domain="${SITE_DOMAINS[$index]}"
    wp_path="$(site_wp_path "$domain")"
    cache_dir="$(site_cache_dir "$domain")"
    legacy_cache_dir="$LEGACY_CACHE_ROOT/$domain"
    case "$scope" in page|object|opcache|all) ;; *) die "Cache scope must be page, object, opcache, or all." ;; esac
    if [[ "$scope" == page || "$scope" == all ]]; then
        if [[ -d "$cache_dir" ]]; then find "$cache_dir" -mindepth 1 -delete || return 1; fi
        if [[ -d "$legacy_cache_dir" ]]; then find "$legacy_cache_dir" -mindepth 1 -delete || return 1; fi
    fi
    if [[ ( "$scope" == object || "$scope" == all ) && \
          "$(site_policy_value "$domain" object-cache disabled)" == enabled && \
          -f "$wp_path/wp-config.php" ]]; then
        site_wp_cli "$domain" cache flush || return 1
    fi
    if [[ "$scope" == opcache || "$scope" == all ]]; then
        php_fpm_service_action reload "${SITE_PHP_VERSIONS[$index]}"
    fi
    return 0
}

update_site() {
    local index="$1" domain wp_path
    domain="${SITE_DOMAINS[$index]}"
    wp_path="$(site_wp_path "$domain")"
    backup_site "$index" >/dev/null
    site_wp_cli "$domain" core update
    site_wp_cli "$domain" core update-db
    site_wp_cli "$domain" plugin update --all
    site_wp_cli "$domain" theme update --all
    clear_site_cache "$index"
}

list_backups() {
    local index="$1" domain backup_dir
    domain="${SITE_DOMAINS[$index]}"
    ensure_site_storage "$domain"
    backup_dir="$(site_backup_dir "$domain")"
    printf 'Available backups for %s:\n' "$domain"
    find "$backup_dir" -mindepth 1 -maxdepth 1 -type d -name '20??????-??????' -printf '  %f\n' 2>/dev/null | sort -r || true
}

run_site_cron() (
    local domain="$1" index
    index="$(site_index_by_domain "$domain")" || die "Unmanaged site."
    [[ -f "${SITE_PATHS[$index]}/wp-config.php" ]] || die "WordPress is not installed."
    exec 7>"$STATE_DIR/cron-$(site_pool_id "$domain").lock"
    flock -n 7 || exit 0
    WP_SHELL_WP_TIMEOUT=240 site_wp_cli "$domain" cron event run --due-now
    date +%s > "$STATE_DIR/cron-$(site_pool_id "$domain").success"
)

site_cron_action() {
    local domain="$1" action="${2:-status}" prior cron_file run_user php_version wp_path site_root
    cron_file="/etc/cron.d/wp-shell-$(site_pool_id "$domain")"
    run_user="$(site_run_user "$domain")"
    php_version="${SITE_PHP_VERSIONS[$(site_index_by_domain "$domain")]}"
    wp_path="$(site_wp_path "$domain")"
    site_root="/var/www/$domain"
    case "$action" in
        enable)
            install_self
            site_wp_cli "$domain" core is-installed >/dev/null || die "WordPress preflight failed; system Cron was not installed."
            prior="$(site_wp_cli "$domain" config get DISABLE_WP_CRON 2>/dev/null || printf 'false')"
            [[ "$(site_policy_value "$domain" cron-mode)" == system ]] || set_site_policy "$domain" cron-prior "$prior"
            install -d -o "$run_user" -g "$(id -gn "$run_user")" -m 0700 "$site_root/.wp-shell"
            install -d -m 0755 /etc/cron.d
            write_managed_file "$cron_file" 0644 root root <<EOF
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * $run_user flock -n $site_root/.wp-shell/cron.lock timeout 240s /usr/bin/php$php_version /usr/local/bin/wp --path=$wp_path cron event run --due-now >>$site_root/logs/wp-cron.log 2>&1
EOF
            site_wp_cli "$domain" config set DISABLE_WP_CRON true --raw
            chmod "$(site_config_mode "$domain")" "$(site_wp_path "$domain")/wp-config.php"
            set_site_policy "$domain" cron-mode system
            log_message SUCCESS "$domain: system WP-Cron scheduled every five minutes as $run_user. No due event was run as a test."
            ;;
        disable)
            prior="$(site_policy_value "$domain" cron-prior false)"
            [[ "$prior" == 1 || "$prior" == true ]] && prior=true || prior=false
            site_wp_cli "$domain" config set DISABLE_WP_CRON "$prior" --raw
            chmod "$(site_config_mode "$domain")" "$(site_wp_path "$domain")/wp-config.php"
            remove_managed_file "$cron_file"
            systemctl disable --now "wp-shell-cron-$(site_pool_id "$domain").timer" 2>/dev/null || true
            set_site_policy "$domain" cron-mode request
            log_message INFO "Restored the previous DISABLE_WP_CRON value ($prior); managed Cron removed."
            ;;
        status)
            printf '%s: mode=%s cron-file=%s\n' "$domain" "$(site_policy_value "$domain" cron-mode request)" "$(if [[ -s "$cron_file" ]]; then printf installed; else printf absent; fi)"
            [[ ! -f "$STATE_DIR/cron-$(site_pool_id "$domain").success" ]] || printf 'Last successful run (epoch): %s\n' "$(<"$STATE_DIR/cron-$(site_pool_id "$domain").success")"
            ;;
        *) die "Use: wp-shell site DOMAIN cron enable|disable|status" ;;
    esac
}

site_config_mode() {
    printf '0640'
}

install_operations_timer() {
    install_self
    transaction_begin "install cache invalidation timer"
    transaction_mark_service systemd
    write_managed_file /etc/systemd/system/wp-shell-operations.service 0644 root root <<EOF
[Unit]
Description=Process WordPress page-cache invalidations
[Service]
Type=oneshot
ExecStart=$MANAGED_SCRIPT ops run
TimeoutStartSec=50s
Nice=10
IOSchedulingClass=idle
EOF
    write_managed_file /etc/systemd/system/wp-shell-operations.timer 0644 root root <<'EOF'
[Unit]
Description=Process page-cache changes every minute
[Timer]
OnBootSec=1m
OnUnitActiveSec=60s
AccuracySec=5s
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now wp-shell-operations.timer
}

run_operations() (
    local i domain marker
    exec 7>"$STATE_DIR/operations.lock"
    flock -n 7 || exit 0
    for ((i=1; i<=SITE_COUNT; i++)); do
        domain="${SITE_DOMAINS[$i]}"
        [[ "$(site_policy_value "$domain" cache-auto)" == enabled ]] || continue
        marker="/var/www/$domain/.wp-shell/cache-dirty"
        if [[ -f "$marker" && ! -L "$marker" ]]; then
            # Remove first: another edit during the purge leaves a marker for the next run.
            rm -f -- "$marker"
            if ! clear_site_cache "$i" page; then
                touch "$marker"
                return 1
            fi
        fi
    done
)

site_cache_auto() {
    local domain="$1" action="${2:-status}" wp_path plugin run_user
    wp_path="$(site_wp_path "$domain")"
    plugin="$wp_path/wp-content/mu-plugins/wp-shell-cache.php"
    run_user="$(site_run_user "$domain")"
    case "$action" in
        enable)
            [[ "$(site_policy_value "$domain" page-cache disabled)" == enabled ]] || \
                die "Enable this site's FastCGI page cache before installing automatic invalidation."
            CURRENT_STEP="configure automatic page-cache invalidation"
            [[ "$wp_path" == "/var/www/$domain/public" ]] || die "Automatic invalidation requires the managed public-directory layout."
            if [[ -e "$plugin" ]] && ! grep -Fq 'Plugin Name: wp-shell Cache Signals' "$plugin"; then die "An unrelated MU plugin already uses $plugin."; fi
            install -d -o "$run_user" -g "$(id -gn "$run_user")" -m 0700 "/var/www/$domain/.wp-shell"
            install -d -o "$run_user" -g www-data -m 0750 "$wp_path/wp-content/mu-plugins"
            write_managed_file "$plugin" 0640 "$run_user" www-data <<'PHP'
<?php
/* Plugin Name: wp-shell Cache Signals */
if (!defined('ABSPATH')) { exit; }
function wp_shell_signal_page_change() {
    $directory = dirname(rtrim(ABSPATH, '/')) . '/.wp-shell';
    if (is_dir($directory) && is_writable($directory)) {
        touch($directory . '/cache-dirty');
    }
}

foreach (array('save_post', 'deleted_post', 'trashed_post', 'untrashed_post',
               'wp_update_nav_menu', 'switch_theme', 'customize_save_after',
               'edited_term', 'delete_term', 'comment_post', 'edit_comment',
               'transition_comment_status', 'upgrader_process_complete') as $event) {
    add_action($event, 'wp_shell_signal_page_change', 100, 0);
}
PHP
            install_operations_timer
            systemctl is-active --quiet wp-shell-operations.timer || die "Cache invalidation timer failed to start."
            set_site_policy "$domain" cache-auto enabled
            touch "/var/www/$domain/.wp-shell/cache-dirty"
            chown "$run_user":"$(id -gn "$run_user")" "/var/www/$domain/.wp-shell/cache-dirty"
            log_message SUCCESS "$domain: page cache purged within about one minute after supported content changes. Custom plugin changes may still need manual clearing."
            ;;
        disable)
            if [[ -f "$plugin" ]] && grep -Fq 'Plugin Name: wp-shell Cache Signals' "$plugin"; then remove_managed_file "$plugin"; fi
            set_site_policy "$domain" cache-auto disabled
            ;;
        status) printf '%s: automatic page invalidation %s\n' "$domain" "$(site_policy_value "$domain" cache-auto disabled)" ;;
        *) die "Use cache-auto enable|disable|status." ;;
    esac
}

site_page_cache_action() {
    local domain="$1" action="${2:-status}" confirmation="${3:-}" index
    index="$(site_index_by_domain "$domain")" || die "Unmanaged site: $domain"
    case "$action" in
        enable)
            [[ "$confirmation" == --confirm ]] || \
                die "Impact: cache anonymous public HTML. Personalized plugin routes/cookies may need explicit exclusions. Re-run with --confirm."
            set_site_policy "$domain" page-cache enabled
            configure_https_site "$index"
            clear_site_cache "$index" page
            log_message SUCCESS "$domain FastCGI page cache enabled. Review every dynamic route used by its theme and plugins."
            ;;
        disable)
            set_site_policy "$domain" page-cache disabled
            configure_https_site "$index"
            clear_site_cache "$index" page
            log_message SUCCESS "$domain FastCGI page cache disabled; static browser caching remains enabled."
            ;;
        status) printf '%s page cache: %s\n' "$domain" "$(site_policy_value "$domain" page-cache disabled)" ;;
        *) die "Use page-cache enable --confirm|disable|status." ;;
    esac
}

site_object_cache_action() {
    local domain="$1" action="${2:-status}" confirmation="${3:-}" index
    index="$(site_index_by_domain "$domain")" || die "Unmanaged site: $domain"
    case "$action" in
        enable)
            [[ "$confirmation" == --confirm ]] || \
                die "Impact: install/activate Redis Object Cache and create its drop-in. Re-run with --confirm."
            backup_site "$index" >/dev/null
            set_site_policy "$domain" object-cache enabled
            apply_site_redis_connection "$domain"
            site_wp_cli "$domain" plugin install redis-cache --activate
            site_wp_cli "$domain" redis enable
            log_message SUCCESS "$domain Redis object-cache integration enabled."
            ;;
        disable)
            [[ "$confirmation" == --confirm ]] || \
                die "Impact: disable the Redis Object Cache drop-in without deleting the plugin or Redis data. Re-run with --confirm."
            backup_site "$index" >/dev/null
            site_wp_cli "$domain" redis disable 2>/dev/null || true
            set_site_policy "$domain" object-cache disabled
            log_message SUCCESS "$domain Redis object-cache integration disabled; plugin files and configuration constants were preserved."
            ;;
        status)
            printf '%s object cache: %s\n' "$domain" "$(site_policy_value "$domain" object-cache disabled)"
            if [[ "$(site_policy_value "$domain" object-cache disabled)" == enabled ]]; then
                site_wp_cli "$domain" redis status || true
            fi
            ;;
        *) die "Use object-cache enable --confirm|disable --confirm|status." ;;
    esac
}

site_cache_exclude() {
    local domain="$1" path="${2:-}" file temp
    CURRENT_STEP="configure a page-cache exclusion"
    file="/etc/nginx/wp-shell-custom/$domain/20-cache-exclusions.conf"
    [[ "$path" =~ ^/[a-zA-Z0-9_/-]+/$ && "$path" != *..* ]] || die "Use an absolute URL path ending with /, for example /staging/ or /basket/."
    install -d -m 0755 "$(dirname "$file")"
    temp="$(mktemp /tmp/wp-cache-exclude.XXXXXX)"
    [[ ! -f "$file" ]] || cp -a "$file" "$temp"
    if ! grep -Fq "~* \"^$path\"" "$temp"; then
        # shellcheck disable=SC2016
        printf 'if ($request_uri ~* "^%s") { set $skip_cache 1; }\n' "$path" >> "$temp"
    fi
    transaction_begin "$CURRENT_STEP"
    transaction_mark_service nginx
    write_managed_file "$file" 0644 root root < "$temp"
    rm -f "$temp"
    if ! nginx -t; then
        die "Invalid Nginx exclusion; previous file restored."
    fi
    systemctl reload nginx
    log_message SUCCESS "Cache exclusion saved for $domain $path. The managed template must include wp-shell-custom; use nginx-apply when upgrading an old template."
}

site_login_limit() {
    local domain="$1" action="${2:-status}" file
    file="/etc/nginx/wp-shell-custom/$domain/30-login-limit.conf"
    case "$action" in
        direct)
            if [[ "$(host_policy_value cloudflare disabled)" != enabled ]]; then
                log_message WARNING "Direct-IP mode is safe only when clients reach Nginx directly. Enable verified Cloudflare real-IP handling first when using its proxy."
            fi
            install -d -m 0755 "$(dirname "$file")"
            transaction_begin "$CURRENT_STEP"
            transaction_mark_service nginx
            install_nginx_log_format
            write_managed_file "$file" 0644 root root <<'EOF'
limit_req zone=wp_shell_login burst=20 nodelay;
limit_req_status 429;
EOF
            if ! nginx -t; then
                die "Login rate-limit validation failed; previous site setting restored."
            fi
            systemctl reload nginx
            set_site_policy "$domain" login-limit direct
            log_message SUCCESS "Login POST rate limit: 10/minute per verified client IP plus burst 20."
            ;;
        off)
            transaction_begin "$CURRENT_STEP"
            transaction_mark_service nginx
            remove_managed_file "$file"
            nginx -t && systemctl reload nginx
            set_site_policy "$domain" login-limit disabled
            ;;
        status) printf '%s: login limiting %s\n' "$domain" "$(site_policy_value "$domain" login-limit disabled)" ;;
        *) die "Use login-limit direct|off|status. CDN/proxy sites need verified real-IP configuration first." ;;
    esac
}

render_staging_nginx() {
    local url_path="$1" pool_socket="$2" output="$3"
    [[ "$url_path" =~ ^/[A-Za-z0-9._/-]+/$ && "$url_path" != *..* ]] || return 1
    [[ "$pool_socket" == /run/php/*.sock ]] || return 1
    cat > "$output" <<EOF
# Managed by wp-shell for staging at $url_path.
location ~* ^${url_path}(?:wp-content/)?(?:uploads|cache)/.*\.(?:php[0-9]?|phtml|phar|cgi|pl|py|sh)$ {
    deny all;
}
location ~ ^${url_path}.*\.php$ {
    try_files \$uri =404;
    include /etc/nginx/fastcgi_params;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    fastcgi_pass unix:$pool_socket;
    fastcgi_no_cache 1;
    fastcgi_cache_bypass 1;
    add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
}
location $url_path {
    try_files \$uri \$uri/ ${url_path}index.php?\$args;
    add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
}
EOF
}

site_staging_action() {
    local domain="$1" action="${2:-status}" requested_path="${3:-}" url_path="${4:-}" redis_prefix="${5:-off}" confirmation="${6:-}"
    local staging_path root expected_path file pool_socket temp run_user
    file="/etc/nginx/wp-shell-custom/$domain/10-staging.conf"
    case "$action" in
        configure)
            [[ "$confirmation" == --confirm ]] || die "Impact: mark the selected nested WordPress as staging, disable its WP-Cron, enforce noindex, and configure an explicit Redis prefix or disable object cache. Re-run with --confirm."
            [[ "$url_path" =~ ^/[A-Za-z0-9._/-]+/$ && "$url_path" != *..* && "$url_path" != '//' ]] || die "Staging URL path must begin and end with one slash, for example /preview/."
            staging_path="$(canonical_staging_path "$domain" "$requested_path")" || die "Staging must be an existing non-symlinked WordPress directory below the registered Web Root."
            root="$(readlink -f "$(site_wp_path "$domain")")"
            expected_path="$(readlink -m "$root/${url_path#/}")"
            [[ "$staging_path" == "${expected_path%/}" ]] || die "The staging filesystem path does not match its URL path below the registered Web Root."
            if [[ "$redis_prefix" != off ]]; then
                [[ "$redis_prefix" =~ ^[A-Za-z0-9._:-]{4,80}$ && "$redis_prefix" != "${domain}:" ]] || \
                    die "Use a unique 4-80 character staging Redis prefix, or 'off'."
            fi
            transaction_begin "$CURRENT_STEP"
            [[ "$TRANSACTION_ACTIVE" != yes ]] || transaction_backup_file "$staging_path/wp-config.php"
            site_wp_cli_at "$domain" "$staging_path" config set WP_DEBUG false --raw
            site_wp_cli_at "$domain" "$staging_path" config set DISALLOW_FILE_EDIT true --raw
            site_wp_cli_at "$domain" "$staging_path" config set FORCE_SSL_ADMIN true --raw
            site_wp_cli_at "$domain" "$staging_path" config set WP_ENVIRONMENT_TYPE staging
            site_wp_cli_at "$domain" "$staging_path" config set DISABLE_WP_CRON true --raw
            if [[ "$redis_prefix" == off ]]; then
                site_wp_cli_at "$domain" "$staging_path" config set WP_REDIS_DISABLED true --raw
            else
                site_wp_cli_at "$domain" "$staging_path" config set WP_REDIS_DISABLED false --raw
                site_wp_cli_at "$domain" "$staging_path" config set WP_REDIS_PREFIX "$redis_prefix"
            fi
            run_user="$(site_run_user "$domain")"
            chown root:"$(id -gn "$run_user")" "$staging_path/wp-config.php"
            chmod "$(site_config_mode "$domain")" "$staging_path/wp-config.php"
            pool_socket="$(site_pool_socket "$domain")"
            install -d -m 0755 "$(dirname "$file")"
            temp="$(mktemp "${TMPDIR:-/tmp}/wp-shell-staging.XXXXXXXX")"
            render_staging_nginx "$url_path" "$pool_socket" "$temp" || die "Could not render the staging Nginx policy."
            transaction_begin "$CURRENT_STEP"
            transaction_mark_service nginx
            write_managed_file "$file" 0644 root root < "$temp"
            rm -f -- "$temp"
            nginx -t || die "Nginx rejected the staging route; configuration and WordPress changes require review."
            systemctl reload nginx
            set_site_policy "$domain" staging-path "$staging_path"
            set_site_policy "$domain" staging-url "$url_path"
            set_site_policy "$domain" staging-redis-prefix "$redis_prefix"
            log_message SUCCESS "$domain staging is noindex, request-cached bypassed, and WP-Cron disabled. No task or email was run."
            ;;
        status)
            printf '%s staging path: %s\n' "$domain" "$(site_policy_value "$domain" staging-path not-configured)"
            printf 'URL: %s | Redis prefix: %s | Nginx: %s\n' \
                "$(site_policy_value "$domain" staging-url n/a)" \
                "$(site_policy_value "$domain" staging-redis-prefix off)" \
                "$(if [[ -s "$file" ]]; then printf installed; else printf absent; fi)"
            ;;
        *) die "Use: wp-shell site DOMAIN staging configure ABS_PATH URL_PATH REDIS_PREFIX|off --confirm | status" ;;
    esac
}

site_header_policy() {
    local domain="$1" policy="$2" action="${3:-status}" value
    [[ "$policy" == hsts || "$policy" == xmlrpc ]] || return 1
    case "$action" in
        enable) value=enabled ;;
        disable) value=disabled ;;
        status)
            if [[ "$policy" == xmlrpc ]]; then value="$(site_policy_value "$domain" "$policy" enabled)"
            else value="$(site_policy_value "$domain" "$policy" disabled)"; fi
            printf '%s %s: %s\n' "$domain" "$policy" "$value"
            return 0
            ;;
        *) die "Use $policy enable|disable|status." ;;
    esac
    set_site_policy "$domain" "$policy" "$value"
    configure_https_site "$(site_index_by_domain "$domain")"
    log_message SUCCESS "$domain $policy policy: $value"
}

site_header_profile() {
    local domain="$1" action="${2:-status}" value index
    index="$(site_index_by_domain "$domain")" || die "Unmanaged site: $domain"
    case "$action" in
        strict) value=strict ;;
        compatible) value=compatible ;;
        status) printf '%s response headers: %s\n' "$domain" "$(site_policy_value "$domain" header-profile compatible)"; return 0 ;;
        *) die "Use headers strict|compatible|status." ;;
    esac
    set_site_policy "$domain" header-profile "$value"
    configure_https_site "$index"
    log_message SUCCESS "$domain response-header profile: $value"
}

site_action() {
    local selector="$1" domain action="${2:-status}" index wp_path
    local arg1="${3:-}" arg2="${4:-}" arg3="${5:-}" arg4="${6:-}"
    domain="$(site_domain_from_selector "$selector")" || die "Unknown site ID or domain: $selector"
    index="$(site_index_by_domain "$domain")" || die "Unmanaged site: $domain"
    wp_path="$(site_wp_path "$domain")"
    case "$action" in
        status) site_status "$index" ;;
        info)
            site_status "$index"
            [[ -f "$wp_path/wp-config.php" ]] && printf '  WordPress: %s\n' "$(site_wp_cli "$domain" core version)"
            ;;
        summary) show_site_deployment_summary "$index" ;;
        core-verify)
            if verify_wordpress_core_strict "$domain"; then
                log_message SUCCESS "$domain WordPress core passed strict checksum verification."
            else
                die "$domain WordPress core failed strict checksum verification. Run: sudo wp-shell site $domain core-repair"
            fi
            ;;
        core-repair) repair_wordpress_core "$index" ;;
        isolate) isolate_site "$index" "$arg1" ;;
        redis-isolate) isolate_site_redis "$index" "${arg1:-64}" ;;
        cron) site_cron_action "$domain" "${arg1:-status}" ;;
        page-cache) site_page_cache_action "$domain" "${arg1:-status}" "$arg2" ;;
        object-cache) site_object_cache_action "$domain" "${arg1:-status}" "$arg2" ;;
        cache-auto) site_cache_auto "$domain" "${arg1:-status}" ;;
        cache-exclude) site_cache_exclude "$domain" "$arg1" ;;
        login-limit) site_login_limit "$domain" "${arg1:-status}" ;;
        staging) site_staging_action "$domain" "${arg1:-status}" "$arg2" "$arg3" "$arg4" "${7:-}" ;;
        hsts|xmlrpc) site_header_policy "$domain" "$action" "${arg1:-status}" ;;
        headers) site_header_profile "$domain" "${arg1:-status}" ;;
        nginx-apply)
            [[ "${SITE_MODES[$index]}" == managed ]] || die "Imported Nginx sites must be reviewed before adopting a managed template."
            configure_https_site "$index"
            clear_site_cache "$index" page
            ;;
        maintenance)
            case "${arg1:-status}" in
                on) install -m 0600 /dev/null "/var/www/$domain/.wp-shell-maintenance" ;;
                off) rm -f -- "/var/www/$domain/.wp-shell-maintenance" ;;
                status) [[ ! -f "/var/www/$domain/.wp-shell-maintenance" ]] || printf 'Maintenance: ON\n' ;;
                *) die "Use maintenance on|off|status." ;;
            esac
            ;;
        cache-clear) clear_site_cache "$index" "${arg1:-page}"; log_message SUCCESS "$domain ${arg1:-page} cache was cleared." ;;
        backup) backup_site "$index" ;;
        backups) list_backups "$index" ;;
        restore) [[ -n "$arg1" ]] || die "Usage: wp-shell restore $domain BACKUP_ID"; restore_site "$index" "$arg1" ;;
        update) [[ "$arg1" == --confirm-updates ]] || die "Impact: update WordPress core, every plugin and every theme after a backup. Re-run with --confirm-updates."; update_site "$index" ;;
        restart)
            php_fpm_service_action restart "${SITE_PHP_VERSIONS[$index]}"
            nginx -t && systemctl reload nginx
            ;;
        *) die "Unknown site action: $action (use status, info, summary, core-verify, core-repair, cache-clear, backup, backups, restore, update, or restart)." ;;
    esac
}

backup_all_sites() {
    local i failures=0
    for ((i = 1; i <= SITE_COUNT; i++)); do
        if ! backup_site "$i"; then
            failures=$((failures + 1))
        fi
    done
    ((failures == 0)) || die "$failures site backup(s) failed."
}

init_metrics_database() {
    install -d -m 0700 "$STATE_DIR"
    sqlite3 "$METRICS_DB" >/dev/null <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
CREATE TABLE IF NOT EXISTS system_samples (
    ts INTEGER NOT NULL,
    cpu_pct REAL NOT NULL DEFAULT 0,
    load1 REAL NOT NULL DEFAULT 0,
    mem_total_mb INTEGER NOT NULL DEFAULT 0,
    mem_available_mb INTEGER NOT NULL DEFAULT 0,
    swap_used_mb INTEGER NOT NULL DEFAULT 0,
    disk_pct REAL NOT NULL DEFAULT 0,
    rx_bytes INTEGER NOT NULL DEFAULT 0,
    tx_bytes INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_system_samples_ts ON system_samples(ts);
CREATE TABLE IF NOT EXISTS site_samples (
    ts INTEGER NOT NULL,
    domain TEXT NOT NULL,
    requests INTEGER NOT NULL DEFAULT 0,
    status_2xx INTEGER NOT NULL DEFAULT 0,
    status_4xx INTEGER NOT NULL DEFAULT 0,
    status_5xx INTEGER NOT NULL DEFAULT 0,
    bytes_sent INTEGER NOT NULL DEFAULT 0,
    avg_ms REAL NOT NULL DEFAULT 0,
    p95_ms REAL NOT NULL DEFAULT 0,
    cache_hits INTEGER NOT NULL DEFAULT 0,
    cache_misses INTEGER NOT NULL DEFAULT 0,
    cache_bypass INTEGER NOT NULL DEFAULT 0,
    php_active INTEGER NOT NULL DEFAULT 0,
    php_idle INTEGER NOT NULL DEFAULT 0,
    php_queue INTEGER NOT NULL DEFAULT 0,
    php_max_children INTEGER NOT NULL DEFAULT 0,
    php_max_reached INTEGER NOT NULL DEFAULT 0,
    php_rss_mb REAL NOT NULL DEFAULT 0,
    http_code INTEGER NOT NULL DEFAULT 0,
    tls_days INTEGER NOT NULL DEFAULT -1,
    backup_age_hours REAL NOT NULL DEFAULT -1,
    files_mb REAL NOT NULL DEFAULT 0,
    cache_mb REAL NOT NULL DEFAULT 0,
    logs_mb REAL NOT NULL DEFAULT 0,
    backups_mb REAL NOT NULL DEFAULT 0,
    php_pss_mb REAL NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_site_samples_ts_domain ON site_samples(ts, domain);
CREATE TABLE IF NOT EXISTS service_samples (
    ts INTEGER NOT NULL,
    mariadb_threads INTEGER NOT NULL DEFAULT 0,
    mariadb_questions INTEGER NOT NULL DEFAULT 0,
    mariadb_slow_queries INTEGER NOT NULL DEFAULT 0,
    redis_used_mb REAL NOT NULL DEFAULT 0,
    redis_hits INTEGER NOT NULL DEFAULT 0,
    redis_misses INTEGER NOT NULL DEFAULT 0,
    redis_evicted INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_service_samples_ts ON service_samples(ts);
CREATE TABLE IF NOT EXISTS sample_health (
    ts INTEGER NOT NULL, domain TEXT NOT NULL, component TEXT NOT NULL,
    valid INTEGER NOT NULL, PRIMARY KEY(ts,domain,component)
);
CREATE TABLE IF NOT EXISTS system_pressure (
    ts INTEGER PRIMARY KEY, cpu_steal REAL, io_wait REAL, memory_psi REAL,
    io_psi REAL, inode_pct REAL, oom_kills INTEGER
);
CREATE TABLE IF NOT EXISTS redis_site_samples (
    ts INTEGER NOT NULL, domain TEXT NOT NULL, used_mb REAL, hits INTEGER,
    misses INTEGER, evicted INTEGER, valid INTEGER, PRIMARY KEY(ts,domain)
);
SQL
    if ! sqlite3 "$METRICS_DB" 'PRAGMA table_info(site_samples);' | awk -F'|' '$2=="php_pss_mb" {found=1} END {exit !found}'; then
        sqlite3 "$METRICS_DB" 'ALTER TABLE site_samples ADD COLUMN php_pss_mb REAL NOT NULL DEFAULT 0;'
    fi
    chmod 0600 "$METRICS_DB"
}

numeric_or_zero() {
    [[ "${1:-}" =~ ^-?[0-9]+([.][0-9]+)?$ ]] && printf '%s' "$1" || printf '0'
}

record_metric_sql() {
    if [[ -n "${COLLECTOR_SQL_FILE:-}" ]]; then
        printf '%s\n' "$1" >> "$COLLECTOR_SQL_FILE"
    else
        sqlite3 -cmd '.timeout 5000' "$METRICS_DB" "$1"
    fi
}

record_sample_health() {
    record_metric_sql "INSERT OR REPLACE INTO sample_health VALUES($1,'$2','$3',$4);"
}

read_pool_limit() {
    local domain="$1" version="$2" fallback="$3" value file
    file="/etc/php/$version/fpm/pool.d/wp-shell-$(site_pool_id "$domain").conf"
    value="$(awk -F= '/^[[:space:]]*pm.max_children[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); v=$2} END {print v}' "$file" 2>/dev/null || true)"
    if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then printf '%s' "$value"; else printf '%s' "$fallback"; fi
}

refresh_actual_pool_limits() {
    local i
    for ((i=1; i<=SITE_COUNT; i++)); do
        SITE_PHP_MAX_CHILDREN[i]="$(read_pool_limit "${SITE_DOMAINS[$i]}" "${SITE_PHP_VERSIONS[$i]}" "${SITE_PHP_MAX_CHILDREN[$i]:-2}")"
    done
}

collect_cpu_percent() {
    local _cpu user nice system idle iowait irq softirq steal _guest _guest_nice total idle_total
    read -r _cpu user nice system idle iowait irq softirq steal _guest _guest_nice < /proc/stat
    total=$((user + nice + system + idle + iowait + irq + softirq + steal))
    idle_total=$((idle + iowait))
    local state_file="${METRICS_CURSOR_DIR:-$STATE_DIR}/cpu.state" previous_total="$total" previous_idle="$idle_total"
    if [[ -r "$state_file" ]]; then
        read -r previous_total previous_idle < "$state_file" || true
    fi
    printf '%s %s\n' "$total" "$idle_total" > "$state_file"
    awk -v t="$total" -v i="$idle_total" -v pt="$previous_total" -v pi="$previous_idle" \
        'BEGIN { dt=t-pt; di=i-pi; if (dt<=0) print "0.0"; else printf "%.1f", 100*(dt-di)/dt }'
}

network_bytes() {
    awk -F'[: ]+' 'NR>2 && $2 != "lo" {rx+=$3; tx+=$11} END {printf "%d %d\n", rx, tx}' /proc/net/dev
}

collect_system_sample() {
    local ts="$1" cpu load1 mem_total mem_available swap_total swap_free swap_used disk_pct rx tx
    cpu="$(collect_cpu_percent)"
    load1="$(awk '{print $1}' /proc/loadavg)"
    mem_total="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
    mem_available="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)"
    swap_total="$(awk '/^SwapTotal:/ {print int($2/1024)}' /proc/meminfo)"
    swap_free="$(awk '/^SwapFree:/ {print int($2/1024)}' /proc/meminfo)"
    swap_used=$((swap_total - swap_free))
    disk_pct="$(df -P / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
    read -r rx tx < <(network_bytes)
    record_metric_sql "INSERT INTO system_samples VALUES($ts,$cpu,$load1,$mem_total,$mem_available,$swap_used,$disk_pct,$rx,$tx);"
    record_sample_health "$ts" '' system 1
}

collect_pressure_sample() {
    local ts="$1" total wait steal previous_total=0 previous_wait=0 previous_steal=0
    local wait_pct=-1 steal_pct=-1 memory_psi=-1 io_psi=-1 inode_pct oom=-1
    read -r total wait steal < <(awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8+$9,$6,$9; exit}' /proc/stat)
    if [[ -r "${METRICS_CURSOR_DIR:-$STATE_DIR}/pressure.state" ]]; then
        read -r previous_total previous_wait previous_steal < "${METRICS_CURSOR_DIR:-$STATE_DIR}/pressure.state" || true
        if ((total > previous_total && wait >= previous_wait && steal >= previous_steal)); then
            wait_pct="$(awk -v a="$wait" -v b="$previous_wait" -v dt="$((total-previous_total))" 'BEGIN {printf "%.2f",100*(a-b)/dt}')"
            steal_pct="$(awk -v a="$steal" -v b="$previous_steal" -v dt="$((total-previous_total))" 'BEGIN {printf "%.2f",100*(a-b)/dt}')"
        fi
    fi
    printf '%s %s %s\n' "$total" "$wait" "$steal" > "${METRICS_CURSOR_DIR:-$STATE_DIR}/pressure.state"
    [[ ! -r /proc/pressure/memory ]] || memory_psi="$(awk '/^some / {split($2,a,"="); print a[2]}' /proc/pressure/memory)"
    [[ ! -r /proc/pressure/io ]] || io_psi="$(awk '/^some / {split($2,a,"="); print a[2]}' /proc/pressure/io)"
    inode_pct="$(df -Pi / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
    [[ ! -r /proc/vmstat ]] || oom="$(awk 'BEGIN {v=-1} /^oom_kill / {v=$2} END {print v}' /proc/vmstat)"
    record_metric_sql "INSERT INTO system_pressure VALUES($ts,$steal_pct,$wait_pct,$memory_psi,$io_psi,$(numeric_or_zero "$inode_pct"),$oom);"
}

collect_nginx_interval() {
    local domain="$1" log_file="/var/www/$1/logs/nginx-access.log" hash offset_file offset=0 size=0 temp stats valid=1
    hash="$(printf '%s' "$domain" | sha256sum | cut -c1-12)"
    offset_file="${METRICS_CURSOR_DIR:-$STATE_DIR}/nginx-$hash.offset"
    [[ -f "$log_file" ]] || { printf '0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0'; return; }
    size="$(stat -c '%s' "$log_file" 2>/dev/null || printf '0')"
    if [[ -r "$offset_file" ]]; then
        read -r offset < "$offset_file" || true
    fi
    [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
    ((size < offset)) && offset=0
    if ((size - offset > 5242880)); then
        offset=$((size - 5242880))
        valid=0
    fi
    temp="$(mktemp /tmp/wp-shell-nginx.XXXXXX)"
    timeout 4s dd if="$log_file" iflag=skip_bytes,count_bytes skip="$offset" count="$((size-offset))" status=none > "$temp" 2>/dev/null || valid=0
    printf '%s\n' "$size" > "$offset_file"
    if ! stats="$(jq -Rsr '
      [split("\n")[] | fromjson?] as $r |
      if ($r|length)==0 then [0,0,0,0,0,0,0,0,0,0,0]
      else
        ($r|map(.request_time * 1000)|sort) as $lat |
        [($r|length),
         ($r|map(select(.status>=200 and .status<300))|length),
         ($r|map(select(.status>=400 and .status<500))|length),
         ($r|map(select(.status>=500))|length),
         ($r|map(.bytes)|add // 0),
         (($lat|add)/($lat|length)),
         $lat[((($lat|length)*0.95|ceil)-1)],
         ($r|map(select(.cache=="HIT"))|length),
         ($r|map(select(.cache=="MISS" or .cache=="EXPIRED"))|length),
         ($r|map(select(.cache=="BYPASS"))|length),
         ($r|map(select(.cache=="UPDATING" or .cache=="STALE"))|length)]
      end | @tsv' "$temp" 2>/dev/null)"; then
        stats=$'0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0'; valid=0
    fi
    rm -f "$temp"
    if ((size > offset)) && [[ "${stats%%$'\t'*}" == 0 ]]; then valid=0; fi
    printf '%s\t%s' "$stats" "$valid"
}

collect_php_pool_status() {
    local domain="$1" socket json pool_id rss pss pid process_rss args process_pss
    local rss_kb=0 pss_kb=0
    socket="$(site_pool_status_socket "$domain")"
    pool_id="$(site_pool_id "$domain")"
    json=""
    if [[ -S "$socket" && -x "$(command -v cgi-fcgi 2>/dev/null || true)" ]]; then
        json="$(SCRIPT_NAME=/status SCRIPT_FILENAME=/status REQUEST_METHOD=GET QUERY_STRING=json \
            timeout 4s cgi-fcgi -bind -connect "$socket" 2>/dev/null | sed -n '/^{/,$p' | tr -d '\r' || true)"
    fi
    while read -r pid process_rss args; do
        [[ "$args" == "php-fpm: pool $pool_id" ]] || continue
        rss_kb=$((rss_kb + process_rss))
        process_pss=""
        if [[ -r "/proc/$pid/smaps_rollup" ]]; then
            process_pss="$(awk '$1=="Pss:" {print $2; exit}' "/proc/$pid/smaps_rollup" 2>/dev/null || true)"
        fi
        [[ "$process_pss" =~ ^[0-9]+$ ]] || process_pss="$process_rss"
        pss_kb=$((pss_kb + process_pss))
    done < <(ps -eo pid=,rss=,args= 2>/dev/null)
    rss="$(awk -v kb="$rss_kb" 'BEGIN {printf "%.1f",kb/1024}')"
    pss="$(awk -v kb="$pss_kb" 'BEGIN {printf "%.1f",kb/1024}')"
    if jq -e '[.["active processes"],.["idle processes"],.["listen queue"],.["max children reached"]] | all(.[]; type=="number" and .>=0 and floor==.)' >/dev/null 2>&1 <<< "$json"; then
        jq -r --arg rss "$rss" --arg pss "$pss" '[.["active processes"], .["idle processes"], .["listen queue"], .["max active processes"]//0, .["max children reached"], ($rss|tonumber), ($pss|tonumber), 1] | @tsv' <<< "$json"
    else
        printf '0\t0\t0\t0\t0\t%s\t%s\t0' "${rss:-0}" "${pss:-0}"
    fi
}

directory_size_mb() {
    local cache_file now timestamp=0 value=-1 measured
    cache_file="${METRICS_CURSOR_DIR:-$STATE_DIR}/size-$(printf '%s' "$1" | sha256sum | cut -c1-16).state"
    now="$(date +%s)"
    if [[ -r "$cache_file" ]]; then read -r timestamp value < "$cache_file" || true; fi
    [[ "$timestamp" =~ ^[0-9]+$ && "$value" =~ ^-?[0-9]+$ ]] || { timestamp=0; value=-1; }
    if ((now-timestamp >= 900)); then
        measured="$(timeout 1s du -sm -- "$1" 2>/dev/null | awk '{print $1}')" || measured=-1
        if [[ "$measured" =~ ^[0-9]+$ ]]; then value="$measured"; fi
        printf '%s %s\n' "$now" "$value" > "$cache_file"
    fi
    printf '%s' "$value"
}

tls_days_remaining() {
    local domain="$1" end epoch now
    [[ -r "/etc/letsencrypt/live/$domain/fullchain.pem" ]] || { printf '%s' '-1'; return; }
    end="$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$domain/fullchain.pem" 2>/dev/null | cut -d= -f2-)"
    epoch="$(date -d "$end" +%s 2>/dev/null || printf '0')"
    now="$(date +%s)"
    ((epoch > 0)) && printf '%s' "$(((epoch - now) / 86400))" || printf '%s' '-1'
}

backup_age_hours() {
    local directory="$1" latest now
    [[ -d "$directory" && ! -L "$directory" ]] || { printf '%s' '-1'; return; }
    if ! latest="$(find "$directory" -mindepth 1 -maxdepth 1 -type d -name '20??????-??????' -printf '%T@\n' 2>/dev/null |
        awk 'BEGIN {latest=-1} $1 + 0 > latest {latest=int($1)} END {if (latest >= 0) print latest}')"; then
        printf '%s' '-1'
        return
    fi
    [[ "$latest" =~ ^[0-9]+$ ]] || { printf '%s' '-1'; return; }
    now="$(date +%s)"
    awk -v n="$now" -v t="$latest" 'BEGIN{printf "%.1f",(n-t)/3600}'
}

collect_site_sample() {
    local ts="$1" index="$2" domain primary wp_path log_stats php_stats
    local requests s2 s4 s5 bytes avg p95 hits misses bypass stale active idle queue _max_active reached rss pss php_valid
    local http_code tls_days backup_age files_mb cache_mb logs_mb backups_mb
    domain="${SITE_DOMAINS[$index]}"
    primary="${SITE_PRIMARY_DOMAINS[$index]}"
    wp_path="${SITE_PATHS[$index]}"
    log_stats="$(collect_nginx_interval "$domain")"
    local traffic_valid
    read -r requests s2 s4 s5 bytes avg p95 hits misses bypass stale traffic_valid <<< "${log_stats//$'\t'/ }"
    php_stats="$(collect_php_pool_status "$domain")"
    read -r active idle queue _max_active reached rss pss php_valid <<< "${php_stats//$'\t'/ }"
    http_code="$(curl --silent --output /dev/null --max-time 5 --write-out '%{http_code}' "https://$primary" 2>/dev/null || printf '0')"
    [[ "$http_code" =~ ^[0-9]{3}$ ]] || http_code=0
    tls_days="$(tls_days_remaining "$domain")"
    backup_age="$(backup_age_hours "$(site_backup_dir "$domain")")"
    files_mb="$(directory_size_mb "$wp_path")"
    cache_mb="$(directory_size_mb "$(site_cache_dir "$domain")")"
    logs_mb="$(directory_size_mb "/var/www/$domain/logs")"
    backups_mb="$(directory_size_mb "$(site_backup_dir "$domain")")"
    record_metric_sql "INSERT INTO site_samples VALUES($ts,'$domain',$(numeric_or_zero "$requests"),$(numeric_or_zero "$s2"),$(numeric_or_zero "$s4"),$(numeric_or_zero "$s5"),$(numeric_or_zero "$bytes"),$(numeric_or_zero "$avg"),$(numeric_or_zero "$p95"),$(numeric_or_zero "$hits"),$(numeric_or_zero "$misses"),$(( $(numeric_or_zero "$bypass") + $(numeric_or_zero "$stale") )),$(numeric_or_zero "$active"),$(numeric_or_zero "$idle"),$(numeric_or_zero "$queue"),${SITE_PHP_MAX_CHILDREN[$index]:-0},$(numeric_or_zero "$reached"),$(numeric_or_zero "$rss"),$http_code,$tls_days,$backup_age,$files_mb,$cache_mb,$logs_mb,$backups_mb,$(numeric_or_zero "$pss"));"
    record_sample_health "$ts" "$domain" php "${php_valid:-0}"
    record_sample_health "$ts" "$domain" nginx "${traffic_valid:-0}"
    if [[ "$(site_policy_value "$domain" redis-mode)" == isolated ]]; then collect_private_redis_sample "$ts" "$domain"; fi
}

collect_private_redis_sample() {
    local ts="$1" domain="$2" info valid=0 used=0 hits=0 misses=0 evicted=0
    info="$(REDISCLI_AUTH="$(site_policy_value "$domain" redis-secret)" timeout 4s redis-cli -s "$(site_redis_socket "$domain")" INFO stats memory 2>/dev/null | tr -d '\r' || true)"
    if [[ "$info" == *used_memory:* ]]; then
        valid=1
        used="$(awk -F: '$1=="used_memory" {printf "%.1f",$2/1048576}' <<< "$info")"
        hits="$(awk -F: '$1=="keyspace_hits" {print $2}' <<< "$info")"
        misses="$(awk -F: '$1=="keyspace_misses" {print $2}' <<< "$info")"
        evicted="$(awk -F: '$1=="evicted_keys" {print $2}' <<< "$info")"
    fi
    record_metric_sql "INSERT INTO redis_site_samples VALUES($ts,'$domain',$(numeric_or_zero "$used"),$(numeric_or_zero "$hits"),$(numeric_or_zero "$misses"),$(numeric_or_zero "$evicted"),$valid);"
    record_sample_health "$ts" "$domain" redis "$valid"
}

collect_service_sample() {
    local ts="$1" mariadb_values threads=0 questions=0 slow=0 redis_info="" redis_used=0 hits=0 misses=0 evicted=0 key value
    local db_valid=0 redis_valid=0
    mariadb_values="$(timeout 4s mariadb --connect-timeout=3 --batch --skip-column-names -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected','Questions','Slow_queries');" 2>/dev/null || true)"
    [[ "$mariadb_values" != *Threads_connected* ]] || db_valid=1
    while read -r key value; do
        case "$key" in
            Threads_connected) threads="$value" ;;
            Questions) questions="$value" ;;
            Slow_queries) slow="$value" ;;
        esac
    done <<< "$mariadb_values"
    if [[ -s "$REDIS_SECRET_FILE" ]]; then
        redis_info="$(REDISCLI_AUTH="$(<"$REDIS_SECRET_FILE")" timeout 4s redis-cli --no-auth-warning INFO stats memory 2>/dev/null | tr -d '\r' || true)"
        [[ "$redis_info" != *used_memory:* ]] || redis_valid=1
        redis_used="$(awk -F: '$1=="used_memory"{printf "%.1f",$2/1048576}' <<< "$redis_info")"
        hits="$(awk -F: '$1=="keyspace_hits"{print $2}' <<< "$redis_info")"
        misses="$(awk -F: '$1=="keyspace_misses"{print $2}' <<< "$redis_info")"
        evicted="$(awk -F: '$1=="evicted_keys"{print $2}' <<< "$redis_info")"
    fi
    record_metric_sql "INSERT INTO service_samples VALUES($ts,$(numeric_or_zero "$threads"),$(numeric_or_zero "$questions"),$(numeric_or_zero "$slow"),$(numeric_or_zero "$redis_used"),$(numeric_or_zero "$hits"),$(numeric_or_zero "$misses"),$(numeric_or_zero "$evicted"));"
    record_sample_health "$ts" '' mariadb "$db_valid"
    record_sample_health "$ts" '' redis "$redis_valid"
}

collect_metrics() (
    CURRENT_STEP="collect metrics"
    exec 8>"$STATE_DIR/collector.lock"
    flock -n 8 || return 0
    init_metrics_database
    calculate_resource_budget quiet
    refresh_actual_pool_limits
    local ts i stage cursor
    ts="$(date +%s)"
    [[ "$(sqlite3 "$METRICS_DB" "SELECT COUNT(*) FROM system_samples WHERE ts=$ts;")" == 0 ]] || return 0
    stage="$(mktemp -d "$STATE_DIR/.sample.XXXXXX")"
    COLLECTOR_SQL_FILE="$stage/transaction.sql"
    METRICS_CURSOR_DIR="$stage/cursors"
    mkdir "$METRICS_CURSOR_DIR"
    trap 'rm -rf -- "$stage"' EXIT
    for cursor in "$STATE_DIR"/*.state "$STATE_DIR"/nginx-*.offset; do
        [[ ! -f "$cursor" ]] || cp -p "$cursor" "$METRICS_CURSOR_DIR/"
    done
    printf 'BEGIN IMMEDIATE;\n' > "$COLLECTOR_SQL_FILE"
    collect_system_sample "$ts"
    collect_service_sample "$ts"
    for ((i = 1; i <= SITE_COUNT; i++)); do
        collect_site_sample "$ts" "$i"
    done
    collect_pressure_sample "$ts"
    record_metric_sql "DELETE FROM system_samples WHERE ts < $((ts - 2592000)); DELETE FROM site_samples WHERE ts < $((ts - 2592000)); DELETE FROM service_samples WHERE ts < $((ts - 2592000)); DELETE FROM sample_health WHERE ts < $((ts - 2592000)); DELETE FROM system_pressure WHERE ts < $((ts - 2592000)); DELETE FROM redis_site_samples WHERE ts < $((ts - 2592000)); COMMIT;"
    sqlite3 -bail -cmd '.timeout 5000' "$METRICS_DB" < "$COLLECTOR_SQL_FILE" || exit 1
    for cursor in "$METRICS_CURSOR_DIR"/*; do
        [[ ! -f "$cursor" ]] || mv -f "$cursor" "$STATE_DIR/"
    done
    sqlite3 "$METRICS_DB" "PRAGMA wal_checkpoint(PASSIVE);" >/dev/null
)

show_metrics_status() {
    local timer_state collector_state="idle" counts="0|0|0" system_samples=0 site_samples=0 service_samples=0
    local last_sample="" sample_age=""
    timer_state="$(systemctl is-active wp-shell-metrics.timer 2>/dev/null || printf 'inactive')"
    if systemctl is-failed --quiet wp-shell-metrics.service 2>/dev/null; then
        collector_state="failed"
    elif systemctl is-active --quiet wp-shell-metrics.service 2>/dev/null; then
        collector_state="running"
    elif [[ "$timer_state" != "active" ]]; then
        collector_state="inactive"
    fi

    if [[ -s "$METRICS_DB" ]]; then
        counts="$(sqlite3 -separator '|' "$METRICS_DB" "SELECT (SELECT COUNT(*) FROM system_samples),(SELECT COUNT(*) FROM site_samples),(SELECT COUNT(*) FROM service_samples);" 2>/dev/null || printf '0|0|0')"
        IFS='|' read -r system_samples site_samples service_samples <<< "$counts"
        last_sample="$(sqlite3 "$METRICS_DB" "SELECT COALESCE(MAX(ts),'') FROM system_samples;" 2>/dev/null || true)"
    fi

    printf 'Timer: %s\n' "$timer_state"
    printf 'Collector: %s\n' "$collector_state"
    printf 'Samples: system=%s site=%s service=%s\n' "$system_samples" "$site_samples" "$service_samples"
    if [[ "$last_sample" =~ ^[0-9]+$ ]]; then
        sample_age=$(( $(date +%s) - last_sample ))
        printf 'Last sample: %s (%ss ago)\n' "$(date --date="@$last_sample" '+%Y-%m-%d %H:%M:%S')" "$sample_age"
    else
        printf 'Last sample: none\n'
    fi
    printf 'Database: %s\n' "$METRICS_DB"
}

install_metrics_timer() {
    CURRENT_STEP="install the metrics collector"
    init_metrics_database
    transaction_begin "$CURRENT_STEP"
    transaction_mark_service systemd
    write_managed_file /etc/systemd/system/wp-shell-metrics.service 0644 root root <<EOF
[Unit]
Description=Collect local wp-shell metrics
After=nginx.service mariadb.service redis-server.service

[Service]
Type=oneshot
ExecStart=$MANAGED_SCRIPT metrics collect
TimeoutStartSec=120s
Nice=10
IOSchedulingClass=idle
ProtectHome=true
PrivateTmp=true
EOF
    write_managed_file /etc/systemd/system/wp-shell-metrics.timer 0644 root root <<'EOF'
[Unit]
Description=Collect wp-shell metrics every minute

[Timer]
OnBootSec=2m
OnUnitActiveSec=60s
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now wp-shell-metrics.timer
}

duration_seconds() {
    case "${1:-24h}" in
        1h) printf '3600' ;;
        6h) printf '21600' ;;
        24h) printf '86400' ;;
        7d) printf '604800' ;;
        14d) printf '1209600' ;;
        30d) printf '2592000' ;;
        *) return 1 ;;
    esac
}

metrics_report() {
    local range="${1:-24h}" seconds since
    seconds="$(duration_seconds "$range")" || die "Unsupported range: $range (use 1h, 6h, 24h, 7d, 14d, or 30d)."
    [[ -s "$METRICS_DB" ]] || die "No metrics are available yet. Run: sudo wp-shell metrics collect"
    since=$(( $(date +%s) - seconds ))
    printf 'wp-shell report | range %s | generated %s\n\n' "$range" "$(date --iso-8601=seconds)"
    sqlite3 -header -column "$METRICS_DB" "SELECT printf('%.1f%%',cpu_pct) AS CPU, printf('%.2f',load1) AS Load1, (mem_total_mb-mem_available_mb)||'/'||mem_total_mb||' MB' AS Memory, swap_used_mb||' MB' AS Swap, printf('%.0f%%',disk_pct) AS Disk FROM system_samples ORDER BY ts DESC LIMIT 1;"
    printf '\nSites (interval samples aggregated over %s)\n' "$range"
    sqlite3 -header -column "$METRICS_DB" "SELECT domain AS Domain, SUM(requests) AS Requests, SUM(status_4xx) AS '4xx', SUM(status_5xx) AS '5xx', printf('%.0f',MAX(p95_ms)) AS 'P95 ms', CASE WHEN SUM(cache_hits+cache_misses)>0 THEN printf('%.0f%%',100.0*SUM(cache_hits)/SUM(cache_hits+cache_misses)) ELSE '-' END AS 'Cache hit', printf('%.0f',MAX(php_pss_mb)) AS 'PHP PSS MB', MAX(php_queue) AS Queue, MAX(http_code) AS HTTP, MIN(tls_days) AS 'TLS days', CASE WHEN MIN(backup_age_hours)<0 THEN '-' ELSE printf('%.1fh',MIN(backup_age_hours)) END AS Backup FROM site_samples WHERE ts >= $since GROUP BY domain ORDER BY SUM(requests) DESC;"
}

dashboard() {
    [[ -t 0 && -t 1 ]] || die "The dashboard requires an interactive terminal. Use 'wp-shell report' for plain output."
    [[ -s "$METRICS_DB" ]] || die "No metrics are available yet. Run: sudo wp-shell metrics collect"
    python3 /dev/fd/3 "$METRICS_DB" "$SITES_CONFIG_FILE" 3<<'PY'
import curses
import datetime
import os
import sqlite3
import subprocess
import sys
import time

DB = sys.argv[1]
CONFIG = sys.argv[2]
VIEWS = ["Overview", "Traffic", "Resources", "Operations", "Alerts"]


def clamp(value, low=0.0, high=100.0):
    return max(low, min(high, float(value or 0)))


def human_bytes(value):
    value = float(value or 0)
    if value < 0:
        return "?"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            return f"{value:.1f}{unit}" if value < 10 else f"{value:.0f}{unit}"
        value /= 1024


def shorten(text, width):
    text = str(text)
    if width <= 0:
        return ""
    return text if len(text) <= width else text[: max(1, width - 1)] + "~"


def add(stdscr, y, x, text, style=0, width=None):
    height, screen_width = stdscr.getmaxyx()
    if y < 0 or y >= height or x >= screen_width:
        return
    allowed = max(0, screen_width - x - 1)
    if width is not None:
        allowed = min(allowed, width)
    try:
        stdscr.addnstr(y, x, str(text), allowed, style)
    except curses.error:
        pass


def bar(value, width):
    width = max(4, width)
    filled = round(width * clamp(value) / 100)
    return "[" + "#" * filled + "-" * (width - filled) + "]"


def load_modes():
    result = {}
    try:
        with open(CONFIG, encoding="ascii", errors="ignore") as handle:
            for line in handle:
                parts = line.rstrip("\n").split("|")
                if len(parts) >= 8 and parts[0] == "site":
                    result[parts[1]] = {"primary": parts[2], "php": parts[3], "mode": parts[7]}
    except OSError:
        pass
    return result


def collector_failed():
    try:
        result = subprocess.run(
            ["systemctl", "is-failed", "--quiet", "wp-shell-metrics.service"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=1,
            check=False,
        )
        return result.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def fetch_data(modes):
    connection = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=2)
    connection.row_factory = sqlite3.Row
    now = int(time.time())
    system = connection.execute("SELECT * FROM system_samples ORDER BY ts DESC LIMIT 1").fetchone()
    service = connection.execute("SELECT * FROM service_samples ORDER BY ts DESC LIMIT 1").fetchone()
    has_health = connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='sample_health'").fetchone()
    def valid_probe(ts, domain, component):
        if not has_health:
            return False
        row = connection.execute("SELECT valid FROM sample_health WHERE ts=? AND domain=? AND component=?", (ts, domain, component)).fetchone()
        return bool(row and row[0] == 1)
    service = dict(service) if service else {}
    if service:
        service["_db_valid"] = valid_probe(service["ts"], "", "mariadb")
        service["_redis_valid"] = valid_probe(service["ts"], "", "redis")
    sampled_domains = {row[0] for row in connection.execute("SELECT DISTINCT domain FROM site_samples")}
    domains = sorted(set(modes) | sampled_domains)
    sites = []
    for domain in domains:
        latest = connection.execute(
            "SELECT * FROM site_samples WHERE domain=? ORDER BY ts DESC LIMIT 1", (domain,)
        ).fetchone()
        aggregate = connection.execute(
            """SELECT COALESCE(SUM(requests),0) requests,
                      COALESCE(SUM(status_2xx),0) status_2xx,
                      COALESCE(SUM(status_4xx),0) status_4xx,
                      COALESCE(SUM(status_5xx),0) status_5xx,
                      COALESCE(SUM(bytes_sent),0) bytes_sent,
                      COALESCE(MAX(p95_ms),0) p95_ms,
                      COALESCE(SUM(cache_hits),0) cache_hits,
                      COALESCE(SUM(cache_misses),0) cache_misses,
                      COALESCE(SUM(cache_bypass),0) cache_bypass
                 FROM site_samples WHERE domain=? AND ts>=?""",
            (domain, now - 300),
        ).fetchone()
        if latest:
            site = dict(latest)
            site["_has_sample"] = True
            site["_php_valid"] = valid_probe(site["ts"], domain, "php")
            site["_traffic_valid"] = valid_probe(site["ts"], domain, "nginx")
            previous = connection.execute(
                "SELECT php_max_reached FROM site_samples "
                "WHERE domain=? AND ts<? ORDER BY ts DESC LIMIT 1",
                (domain, latest["ts"]),
            ).fetchone()
            current_reached = int(latest["php_max_reached"] or 0)
            previous_reached = int(previous[0] or 0) if previous is not None else None
            site["_php_max_increased"] = bool(
                site["_php_valid"] and previous_reached is not None
                and (
                    current_reached > previous_reached
                    or (current_reached < previous_reached and current_reached > 0)
                )
            )
        else:
            site = {"domain": domain, "_has_sample": False, "_php_max_increased": False}
        sites.append((site, dict(aggregate)))
    connection.close()
    return (dict(system) if system else {}, dict(service) if service else {}, sites)


def alert_for(site, agg):
    if not site.get("_has_sample", False):
        return "NO DATA"
    alerts = []
    if not site.get("_php_valid", True):
        alerts.append("PHP ?")
    if not site.get("_traffic_valid", True):
        alerts.append("Logs ?")
    code = int(site.get("http_code", 0) or 0)
    if code < 200 or code >= 400:
        alerts.append(f"HTTP {code or 'DOWN'}")
    if int(site.get("php_queue", 0) or 0) > 0:
        alerts.append("PHP queue")
    if site.get("_php_max_increased", False):
        alerts.append("PHP max")
    if int(site.get("tls_days", -1) or -1) < 14:
        alerts.append("TLS")
    backup = float(site.get("backup_age_hours", -1) or -1)
    if backup < 0 or backup > 48:
        alerts.append("Backup")
    requests = max(1, int(agg.get("requests", 0) or 0))
    if int(agg.get("status_5xx", 0) or 0) / requests >= 0.01:
        alerts.append("5xx")
    return ",".join(alerts) if alerts else "OK"


def row_style(selected, bad=False):
    if selected:
        return curses.A_REVERSE
    if bad and curses.has_colors():
        return curses.color_pair(3) | curses.A_BOLD
    return 0


def draw_header(stdscr, system, view, modes, failed):
    height, width = stdscr.getmaxyx()
    title = f" wp-shell {VIEWS[view]} "
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    age = int(time.time() - int(system.get("ts", 0) or 0)) if system else -1
    if failed:
        collector = "FAILED"
    elif age < 0:
        collector = "WAITING"
    elif age > 180:
        collector = "STALE"
    else:
        collector = "OK"
    sample = f"sample {age}s" if age >= 0 else "no sample"
    right = f"sites {len(modes)} | collector {collector} | {sample} | {stamp} "
    style = curses.color_pair(1) | curses.A_BOLD if curses.has_colors() else curses.A_REVERSE
    add(stdscr, 0, 0, (title + " " * width)[:width], style)
    add(stdscr, 0, max(len(title), width - len(right) - 1), right, style)
    if not system:
        return 2
    total = max(1, int(system.get("mem_total_mb", 0) or 0))
    used = total - int(system.get("mem_available_mb", 0) or 0)
    memory_pct = 100 * used / total
    boundaries = ((1, width // 3), (width // 3, 2 * width // 3), (2 * width // 3, width))
    metrics = (
        (f"CPU {float(system.get('cpu_pct', 0)):5.1f}%", system.get("cpu_pct", 0)),
        (f"MEM {used}/{total}MB", memory_pct),
        (f"DISK {float(system.get('disk_pct', 0)):4.0f}%", system.get("disk_pct", 0)),
    )
    for (start, end), (label, percent) in zip(boundaries, metrics):
        available = max(1, end - start - 1)
        bar_width = max(4, available - len(label) - 3)
        add(stdscr, 1, start, f"{label} {bar(percent, bar_width)}", width=available)
    try:
        cores = len(os.sched_getaffinity(0))
    except (AttributeError, OSError):
        cores = os.cpu_count() or "?"
    add(stdscr, 2, 1, f"Load {float(system.get('load1', 0)):.2f} / {cores} cores | Swap {int(system.get('swap_used_mb', 0))}MB | Raw data retained 30d | Window 5m")
    return 4


def table_layout(width, view):
    if view == 0:
        return [("Domain", 24), ("Req/5m", 8), ("P95", 8), ("Hit", 7), ("PHP", 10), ("PSS", 8), ("HTTP", 6), ("Health", 16)]
    if view == 1:
        return [("Domain", 24), ("Requests", 9), ("2xx", 7), ("4xx", 7), ("5xx", 7), ("Bytes", 9), ("P95", 8), ("Cache", 8)]
    if view == 2:
        return [("Domain", 24), ("Active", 8), ("Idle", 7), ("Queue", 7), ("Max", 7), ("PSS", 9), ("RSSsum", 9), ("Files", 9), ("Cache", 9), ("Logs", 8)]
    if view == 3:
        return [("Domain", 24), ("HTTP", 7), ("TLS", 9), ("Backup", 10), ("Backups", 10), ("PHP", 8), ("Mode", 10), ("Health", 16)]
    return [("Domain", 24), ("Severity", 10), ("Finding", 50)]


def fit_columns(columns, width):
    available = max(20, width - len(columns) - 1)
    result = list(columns)
    while sum(item[1] for item in result) > available and result:
        largest = max(range(len(result)), key=lambda i: result[i][1])
        name, size = result[largest]
        minimum = 10 if name == "Domain" else max(5, len(name))
        if size > minimum:
            result[largest] = (name, size - 1)
        elif len(result) > 3:
            result.pop()
        else:
            break
    return result


def values_for(view, site, agg, meta):
    if not site.get("_has_sample", False):
        if view == 0:
            return [site["domain"], "-", "-", "-", "-", "-", "-", "NO DATA"]
        if view == 1:
            return [site["domain"], "-", "-", "-", "-", "-", "-", "-"]
        if view == 2:
            return [site["domain"], "-", "-", "-", "-", "-", "-", "-", "-", "-"]
        if view == 3:
            return [site["domain"], "-", "-", "none", "-", meta.get("php", "-"), meta.get("mode", "-"), "NO DATA"]
        return [site["domain"], "WARN", "NO DATA"]
    requests = int(agg.get("requests", 0) or 0)
    cache_total = int(agg.get("cache_hits", 0) or 0) + int(agg.get("cache_misses", 0) or 0)
    hit = f"{100*int(agg.get('cache_hits',0))/cache_total:.0f}%" if cache_total else "-"
    health = alert_for(site, agg)
    if view == 0:
        return [site["domain"], requests, f"{float(agg.get('p95_ms',0)):.0f}ms", hit,
                f"{site.get('php_active',0)}/{site.get('php_max_children',0)}" if site.get('_php_valid', True) else "?",
                f"{float(site.get('php_pss_mb',0)):.0f}MB" if site.get('_php_valid', True) else "?",
                site.get("http_code", 0), health]
    if view == 1:
        return [site["domain"], requests, agg.get("status_2xx", 0), agg.get("status_4xx", 0), agg.get("status_5xx", 0),
                human_bytes(agg.get("bytes_sent", 0)), f"{float(agg.get('p95_ms',0)):.0f}ms", hit]
    if view == 2:
        values = [site["domain"], site.get("php_active", 0), site.get("php_idle", 0), site.get("php_queue", 0),
                site.get("php_max_children", 0), f"{float(site.get('php_pss_mb',0)):.0f}MB",
                f"{float(site.get('php_rss_mb',0)):.0f}MB", human_bytes(float(site.get('files_mb',-1))*1048576),
                human_bytes(float(site.get('cache_mb',-1))*1048576), human_bytes(float(site.get('logs_mb',-1))*1048576)]
        if not site.get('_php_valid', True):
            values[1:4] = ['?'] * 3
            values[5:7] = ['?'] * 2
        return values
    if view == 3:
        backup = float(site.get("backup_age_hours", -1) or -1)
        return [site["domain"], site.get("http_code", 0), f"{site.get('tls_days',-1)}d", "none" if backup < 0 else f"{backup:.1f}h",
                f"{float(site.get('backups_mb',0)):.0f}MB", meta.get("php", "-"), meta.get("mode", "-"), health]
    severity = "OK" if health == "OK" else "WARN"
    return [site["domain"], severity, health]


def draw(stdscr, view, selected):
    stdscr.erase()
    height, width = stdscr.getmaxyx()
    if height < 14 or width < 64:
        add(stdscr, 0, 0, "Terminal too small for wp-shell dashboard.", curses.A_BOLD)
        add(stdscr, 2, 0, f"Current: {width}x{height}; minimum: 64x14")
        add(stdscr, 4, 0, "Resize the SSH terminal, or press q to quit.")
        stdscr.refresh()
        return selected
    modes = load_modes()
    try:
        system, service, sites = fetch_data(modes)
    except (sqlite3.Error, OSError) as error:
        add(stdscr, 0, 0, f"Metrics unavailable: {error}", curses.A_BOLD)
        stdscr.refresh()
        return selected
    start_y = draw_header(stdscr, system, view, modes, collector_failed())
    columns = fit_columns(table_layout(width, view), width)
    header = " ".join(shorten(name, size).ljust(size) for name, size in columns)
    add(stdscr, start_y, 0, header, curses.A_BOLD | (curses.color_pair(2) if curses.has_colors() else 0))
    visible = max(1, height - start_y - 3)
    selected = max(0, min(selected, max(0, len(sites) - 1)))
    top = max(0, selected - visible + 1)
    for screen_row, (site, agg) in enumerate(sites[top: top + visible], start=start_y + 1):
        meta = modes.get(site["domain"], {})
        values = values_for(view, site, agg, meta)
        values = values[:len(columns)]
        line = " ".join(shorten(value, size).ljust(size) for value, (_, size) in zip(values, columns))
        bad = alert_for(site, agg) != "OK"
        add(stdscr, screen_row, 0, line, row_style(top + screen_row - start_y - 1 == selected, bad))
    if not sites:
        add(stdscr, start_y + 2, 1, "No registered sites.")
    service_text = ""
    if service:
        total = int(service.get("redis_hits", 0) or 0) + int(service.get("redis_misses", 0) or 0)
        ratio = 100 * int(service.get("redis_hits", 0) or 0) / total if total else 0
        db_text = str(service.get('mariadb_threads',0)) if service.get('_db_valid') else '?'
        redis_text = f"{float(service.get('redis_used_mb',0)):.1f}MB hit {ratio:.0f}%" if service.get('_redis_valid') else '?'
        service_text = f"DB threads {db_text} | Redis {redis_text} | Sizes cached 15m"
    add(stdscr, height - 2, 0, service_text)
    footer = "F1 Overview  F2 Traffic  F3 Resources  F4 Operations  F5 Alerts  Up/Down Select  r Refresh  q Quit"
    style = curses.color_pair(1) if curses.has_colors() else curses.A_REVERSE
    add(stdscr, height - 1, 0, (footer + " " * width)[:width], style)
    stdscr.refresh()
    return selected


def run(stdscr):
    curses.curs_set(0)
    stdscr.keypad(True)
    stdscr.timeout(1000)
    if curses.has_colors():
        curses.start_color()
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_BLACK, curses.COLOR_CYAN)
        curses.init_pair(2, curses.COLOR_CYAN, -1)
        curses.init_pair(3, curses.COLOR_YELLOW, -1)
    view = 0
    selected = 0
    last_draw = 0.0
    while True:
        now = time.monotonic()
        if now - last_draw >= 2:
            selected = draw(stdscr, view, selected)
            last_draw = now
        key = stdscr.getch()
        if key in (ord("q"), ord("Q")):
            break
        if key in (curses.KEY_F1, ord("1")):
            view = 0
        elif key in (curses.KEY_F2, ord("2")):
            view = 1
        elif key in (curses.KEY_F3, ord("3")):
            view = 2
        elif key in (curses.KEY_F4, ord("4")):
            view = 3
        elif key in (curses.KEY_F5, ord("5")):
            view = 4
        elif key in (curses.KEY_RIGHT, ord("l")):
            view = (view + 1) % len(VIEWS)
        elif key in (curses.KEY_LEFT, ord("h")):
            view = (view - 1) % len(VIEWS)
        elif key in (curses.KEY_DOWN, ord("j")):
            selected += 1
        elif key in (curses.KEY_UP, ord("k")):
            selected = max(0, selected - 1)
        if key != -1:
            last_draw = 0


curses.wrapper(run)
PY
}

build_tuning_recommendations() {
    local output="$1" seconds="${2:-1209600}" now since i domain current stats count first last peak saturated worker
    local system_stats system_count min_available_pct peak_cpu system_last allocation=0 recommended reason
    local -A evidence=()
    : > "$output"
    # Legacy rows and failed probes are historical evidence, not safe tuning input.
    init_metrics_database
    refresh_actual_pool_limits
    now="$(date +%s)"
    since=$((now - seconds))
    system_stats="$(sqlite3 -separator '|' "$METRICS_DB" "SELECT COUNT(*),COALESCE(MIN(100.0*s.mem_available_mb/NULLIF(s.mem_total_mb,0)),0),COALESCE(MAX(s.cpu_pct),100),COALESCE(MAX(s.ts),0) FROM system_samples s JOIN sample_health h ON h.ts=s.ts AND h.domain='' AND h.component='system' AND h.valid=1 WHERE s.ts >= $since;")"
    IFS='|' read -r system_count min_available_pct peak_cpu system_last <<< "$system_stats"
    ((system_count >= 1000 && now-system_last <= 180)) || return 0
    for ((i = 1; i <= SITE_COUNT; i++)); do
        domain="${SITE_DOMAINS[$i]}"
        current="${SITE_PHP_MAX_CHILDREN[$i]:-2}"
        stats="$(sqlite3 -separator '|' "$METRICS_DB" "SELECT COUNT(*),COALESCE(MIN(s.ts),0),COALESCE(MAX(s.ts),0),COALESCE(MAX(s.php_active),0),COALESCE(SUM(CASE WHEN s.php_queue>0 OR (s.php_active>=s.php_max_children AND s.php_max_children>0) THEN 1 ELSE 0 END),0),CAST(MAX(96,COALESCE(MAX(1.25*s.php_pss_mb/NULLIF(s.php_active+s.php_idle,0)),96))+0.999 AS INTEGER) FROM site_samples s JOIN sample_health h ON h.ts=s.ts AND h.domain=s.domain AND h.component='php' AND h.valid=1 WHERE s.domain='$domain' AND s.ts >= $since;")"
        IFS='|' read -r count first last peak saturated worker <<< "$stats"
        # All pools need valid evidence, otherwise their future memory demand is unknown.
        ((count >= 1000 && last-first >= 86400 && now-last <= 180)) || return 0
        evidence[$domain]="$stats"
        allocation=$((allocation + current * worker))
    done
    for ((i = 1; i <= SITE_COUNT; i++)); do
        domain="${SITE_DOMAINS[$i]}"
        current="${SITE_PHP_MAX_CHILDREN[$i]:-2}"
        IFS='|' read -r count first last peak saturated worker <<< "${evidence[$domain]}"
        recommended="$current"
        reason=""
        if awk -v m="$min_available_pct" -v c="$peak_cpu" 'BEGIN{exit !(m>=25 && c<85)}'; then
            if ((saturated >= 10 && saturated * 100 >= count)); then
                recommended=$((current + (current + 4) / 5))
                ((recommended > 50)) && recommended=50
                while ((recommended > current && allocation + (recommended-current)*worker > PHP_TOTAL_BUDGET_MB)); do
                    recommended=$((recommended-1))
                done
                reason="Repeated saturation; CPU <85%; memory >=25%; measured worker estimate ${worker}MB; within global budget"
            elif ((last-first >= 1200000 && peak * 3 < current && current > 2 && saturated == 0)); then
                recommended=$((current - (current + 4) / 5))
                ((recommended < 2)) && recommended=2
                reason="Fourteen days of valid samples; peak below one third of the actual pool limit"
            fi
        fi
        if ((recommended != current)); then
            printf '%s|%s|%s|%s\n' "$domain" "$current" "$recommended" "$reason" >> "$output"
            allocation=$((allocation + (recommended-current)*worker))
        fi
    done
}

analyze_metrics() {
    local range="${1:-7d}" seconds since recommendation_file
    seconds="$(duration_seconds "$range")" || die "Unsupported range: $range (use 1h, 6h, 24h, 7d, 14d, or 30d)."
    [[ -s "$METRICS_DB" ]] || die "No metrics are available yet. Run: sudo wp-shell metrics collect"
    calculate_resource_budget
    since=$(( $(date +%s) - seconds ))
    printf 'wp-shell resource analysis | range %s\n\n' "$range"
    sqlite3 -header -column "$METRICS_DB" "SELECT COUNT(*) AS Samples, printf('%.1f%%',MAX(cpu_pct)) AS 'Peak CPU', printf('%.1f%%',MIN(100.0*mem_available_mb/NULLIF(mem_total_mb,0))) AS 'Minimum free memory', printf('%.0f%%',MAX(disk_pct)) AS 'Peak disk' FROM system_samples WHERE ts >= $since;"
    printf '\nPer-site PHP evidence\n'
    sqlite3 -header -column "$METRICS_DB" "WITH ordered AS (SELECT *,LAG(php_max_reached) OVER (PARTITION BY domain ORDER BY ts) AS previous_reached FROM site_samples WHERE ts >= $since) SELECT domain AS Domain,COUNT(*) AS Samples,MAX(php_active) AS 'Peak active',MAX(php_queue) AS 'Peak queue',COALESCE(SUM(CASE WHEN previous_reached IS NULL THEN 0 WHEN php_max_reached >= previous_reached THEN php_max_reached-previous_reached ELSE php_max_reached END),0) AS 'New max events',printf('%.0f MB',MAX(php_pss_mb)) AS 'Peak PSS',printf('%.0f MB',MAX(php_rss_mb)) AS 'Peak RSS sum',printf('%.0f ms',MAX(p95_ms)) AS 'Peak P95' FROM ordered GROUP BY domain ORDER BY domain;"
    printf '\nShared services\n'
    sqlite3 -header -column "$METRICS_DB" "WITH ordered AS (SELECT *,LAG(mariadb_slow_queries) OVER (ORDER BY ts) AS previous_slow,LAG(redis_evicted) OVER (ORDER BY ts) AS previous_evicted FROM service_samples WHERE ts >= $since) SELECT MAX(mariadb_threads) AS 'Peak DB threads',COALESCE(SUM(CASE WHEN previous_slow IS NULL THEN 0 WHEN mariadb_slow_queries >= previous_slow THEN mariadb_slow_queries-previous_slow ELSE mariadb_slow_queries END),0) AS 'New slow queries',printf('%.1f MB',MAX(redis_used_mb)) AS 'Peak Redis',COALESCE(SUM(CASE WHEN previous_evicted IS NULL THEN 0 WHEN redis_evicted >= previous_evicted THEN redis_evicted-previous_evicted ELSE redis_evicted END),0) AS 'Redis evictions' FROM ordered;"
    printf '\nConfigured budget: MariaDB %sMB | Redis %sMB | shared OPcache %sMB | PHP-FPM workers %sMB\n' "$MARIADB_BUFFER_MB" "$REDIS_MAX_MEMORY_MB" "$OPCACHE_TOTAL_BUDGET_MB" "$PHP_TOTAL_BUDGET_MB"
    recommendation_file="$STATE_DIR/last-recommendations.tsv"
    build_tuning_recommendations "$recommendation_file" "$seconds"
    printf '\nSafe automatic PHP recommendations\n'
    if [[ -s "$recommendation_file" ]]; then
        printf '%-28s %8s %8s  %s\n' "DOMAIN" "CURRENT" "PROPOSED" "REASON"
        while IFS='|' read -r domain current proposed reason; do
            printf '%-28s %8s %8s  %s\n' "$domain" "$current" "$proposed" "$reason"
        done < "$recommendation_file"
        printf '\nReview with: sudo wp-shell tune --apply --range %s\n' "$range"
    else
        printf 'No safe changes. Requires >=1,000 valid samples per pool spanning >=24h, fresh data, repeated saturation, CPU <85%%, memory >=25%%, and global budget headroom.\n'
    fi
    printf '\nProbe validity (unmarked old samples are UNKNOWN; never used for automatic tuning)\n'
    sqlite3 -header -column "$METRICS_DB" "SELECT component,domain,COUNT(*) AS probes,SUM(valid) AS valid FROM sample_health WHERE ts >= $since GROUP BY component,domain;"
    printf '\nHost pressure (-1 means unavailable; OOM is a cumulative kernel counter)\n'
    sqlite3 -header -column "$METRICS_DB" "SELECT MAX(cpu_steal) AS 'Peak steal %',MAX(io_wait) AS 'Peak IO wait %',MAX(memory_psi) AS 'Memory PSI %',MAX(io_psi) AS 'IO PSI %',MAX(inode_pct) AS 'Inodes %',MAX(oom_kills) AS OOM FROM system_pressure WHERE ts >= $since;"
    printf '\nPrivate Redis instances (shared-service Redis counters above exclude these)\n'
    sqlite3 -header -column "$METRICS_DB" "SELECT domain,COUNT(*) AS samples,SUM(valid) AS valid,MAX(CASE WHEN valid=1 THEN used_mb END) AS 'Peak MB' FROM redis_site_samples WHERE ts >= $since GROUP BY domain;"
    printf '\nMariaDB and Redis findings are advisory; wp-shell does not auto-change them from aggregate counters alone.\n'
}

apply_tuning() {
    local assume_yes="" range=14d seconds recommendation_file="$STATE_DIR/pending-tuning-recommendations.tsv" domain current proposed reason
    while (($#)); do
        case "$1" in
            --yes) assume_yes=--yes; shift ;;
            --range) [[ -n "${2:-}" ]] || die "Missing range."; range="$2"; shift 2 ;;
            '') shift ;;
            *) die "Usage: wp-shell tune --apply [--yes] [--range 7d|14d|30d]" ;;
        esac
    done
    seconds="$(duration_seconds "$range")" || die "Unsupported range: $range"
    [[ -s "$METRICS_DB" ]] || die "No metrics are available yet."
    calculate_resource_budget
    build_tuning_recommendations "$recommendation_file" "$seconds"
    [[ -s "$recommendation_file" ]] || { log_message INFO "No high-confidence changes are available."; return 0; }
    printf 'The following PHP-FPM limits will be applied:\n'
    while IFS='|' read -r domain current proposed reason; do
        printf '  %s: %s -> %s (%s)\n' "$domain" "$current" "$proposed" "$reason"
    done < "$recommendation_file"
    if [[ "$assume_yes" != "--yes" ]]; then
        collect_yes_no "Apply these reversible tuning overrides" no || { log_message INFO "No changes were applied."; return 0; }
    fi
    (
        local stage success=no index version pool_file i
        local -A versions=()
        stage="$(mktemp -d "$STATE_DIR/.tuning.XXXXXX")"
        [[ ! -f "$TUNING_CONFIG_FILE" ]] || cp -a "$TUNING_CONFIG_FILE" "$stage/tuning.v1"
        # shellcheck disable=SC2317,SC2329
        cleanup_tuning() {
            if [[ "$success" != yes ]]; then
                while IFS='|' read -r domain _current _proposed _reason; do
                    index="$(site_index_by_domain "$domain")"
                    version="${SITE_PHP_VERSIONS[$index]}"
                    pool_file="/etc/php/$version/fpm/pool.d/wp-shell-$(site_pool_id "$domain").conf"
                    [[ ! -f "$stage/$domain.conf" ]] || cp -a "$stage/$domain.conf" "$pool_file"
                done < "$recommendation_file"
                if [[ -f "$stage/tuning.v1" ]]; then cp -a "$stage/tuning.v1" "$TUNING_CONFIG_FILE"; else rm -f "$TUNING_CONFIG_FILE"; fi
                for version in "${!versions[@]}"; do php_fpm_service_action reload "$version" || true; done
                log_message WARNING "PHP tuning failed; previous pool files and tuning policy restored."
            fi
            rm -rf -- "$stage"
        }
        trap cleanup_tuning EXIT
        build_tuning_recommendations "$stage/rechecked.tsv" "$seconds"
        cmp -s "$recommendation_file" "$stage/rechecked.tsv" || die "Metrics or pool configuration changed while waiting; review recommendations again."
        # Preserve all actual limits; a future budget reapply must not silently undo them.
        for ((i=1; i<=SITE_COUNT; i++)); do PHP_CHILD_OVERRIDES["${SITE_DOMAINS[$i]}"]="${SITE_PHP_MAX_CHILDREN[$i]}"; done
        while IFS='|' read -r domain current proposed _reason; do
            index="$(site_index_by_domain "$domain")"
            version="${SITE_PHP_VERSIONS[$index]}"
            pool_file="/etc/php/$version/fpm/pool.d/wp-shell-$(site_pool_id "$domain").conf"
            [[ -f "$pool_file" && "$(read_pool_limit "$domain" "$version" 0)" == "$current" ]] || die "Pool configuration changed; review recommendations again."
            cp -a "$pool_file" "$stage/$domain.conf"
            sed -E "s/^[[:space:]]*pm[.]max_children[[:space:]]*=.*/pm.max_children = $proposed/" "$pool_file" > "$stage/new.conf"
            install -m 0644 "$stage/new.conf" "$pool_file"
            PHP_CHILD_OVERRIDES["$domain"]="$proposed"
            versions[$version]=1
        done < "$recommendation_file"
        for version in "${!versions[@]}"; do "php-fpm$version" -t; done
        save_tuning_config
        for version in "${!versions[@]}"; do php_fpm_service_action reload "$version"; done
        success=yes
    )
    log_message SUCCESS "PHP-FPM tuning overrides were saved to $TUNING_CONFIG_FILE and applied."
}

install_backup_timer() {
    CURRENT_STEP="install the automatic backup timer"
    transaction_begin "$CURRENT_STEP"
    transaction_mark_service systemd
    write_managed_file /etc/systemd/system/wp-shell-backup.service 0644 root root <<EOF
[Unit]
Description=Back up all WordPress sites managed by wp-shell
After=mariadb.service

[Service]
Type=oneshot
ExecStart=$MANAGED_SCRIPT backup-all
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF
    write_managed_file /etc/systemd/system/wp-shell-backup.timer 0644 root root <<'EOF'
[Unit]
Description=Daily wp-shell backup

[Timer]
OnCalendar=*-*-* 02:00:00
RandomizedDelaySec=20m
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl disable --now wp-vps-backup.timer wp-single-backup.timer 2>/dev/null || true
    systemctl enable --now wp-shell-backup.timer
}

list_sites() {
    if ((SITE_COUNT == 0)); then
        printf 'No sites are managed.\n'
        return
    fi
    calculate_resource_budget quiet
    refresh_actual_pool_limits
    local i redis_label
    printf '%-3s %-28s %-28s %-5s %-8s %-8s %-5s\n' "ID" "DOMAIN" "PRIMARY" "PHP" "MODE" "REDIS" "POOL"
    for ((i = 1; i <= SITE_COUNT; i++)); do
        redis_label="${SITE_REDIS_DATABASES[$i]}"
        if [[ "$(site_policy_value "${SITE_DOMAINS[$i]}" redis-mode)" == isolated ]]; then redis_label="private"; fi
        printf '%-3s %-28s %-28s %-5s %-8s %-8s %-5s\n' \
            "$i" "${SITE_DOMAINS[$i]}" "${SITE_PRIMARY_DOMAINS[$i]}" "${SITE_PHP_VERSIONS[$i]}" \
            "${SITE_MODES[$i]}" "$redis_label" "${SITE_PHP_MAX_CHILDREN[$i]:--}"
    done
}

status_all_sites() {
    local i
    for ((i = 1; i <= SITE_COUNT; i++)); do
        site_status "$i"
    done
}

detect_site_php_version_from_nginx() {
    local domain="$1" wp_path="$2" config version
    local -a configs=()
    [[ -d /etc/nginx/sites-enabled ]] || return 1
    mapfile -d '' -t configs < <(
        find /etc/nginx/sites-enabled -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -print0 2>/dev/null
    )
    for config in "${configs[@]}"; do
        [[ -f "$config" ]] || continue
        if ! awk -v expected_root="$wp_path" -v expected_domain="$domain" '
            {
                line=$0
                sub(/[[:space:]]*#.*/, "", line)
                $0=line
                if ($1 == "root") {
                    value=$2
                    sub(/;$/, "", value)
                    if (value == expected_root) matched=1
                } else if ($1 == "server_name") {
                    for (i=2; i<=NF; i++) {
                        value=$i
                        sub(/;$/, "", value)
                        if (value == expected_domain || value == "www." expected_domain) matched=1
                    }
                }
            }
            END {exit !matched}
        ' "$config"; then
            continue
        fi
        version="$(awk '
            {
                line=$0
                while (match(line, /php[0-9]+[.][0-9]+-fpm/)) {
                    value=substr(line, RSTART, RLENGTH)
                    sub(/^php/, "", value)
                    sub(/-fpm$/, "", value)
                    if (first == "") first=value
                    line=substr(line, RSTART + RLENGTH)
                }
            }
            END {if (first != "") print first}
        ' "$config")"
        if validate_php_version "$version"; then
            printf '%s' "$version"
            return 0
        fi
    done
    return 1
}

import_existing_sites() {
    CURRENT_STEP="detect existing WordPress sites"
    if ! command -v wp >/dev/null 2>&1; then
        log_message INFO "WP-CLI is required for discovery and will be installed."
        apt-get update
        apt_install ca-certificates curl gnupg php-cli
        install_wp_cli
    fi
    local wp_config wp_path wp_owner url host domain primary www php_version next_index redis_db imported=0
    while IFS= read -r -d '' wp_config; do
        wp_path="$(dirname "$wp_config")"
        [[ ! "$wp_path" =~ [[:space:]] ]] || { log_message WARNING "Skipping a path containing whitespace: $wp_path"; continue; }
        [[ -f "$wp_path/wp-includes/version.php" ]] || continue
        wp_owner="$(stat -c '%U' "$wp_config" 2>/dev/null || printf 'www-data')"
        id "$wp_owner" >/dev/null 2>&1 || wp_owner="www-data"
        if [[ "$(id -u "$wp_owner")" == 0 ]] || id -nG "$wp_owner" | grep -Eq '(^| )(sudo|wheel|docker|lxd)( |$)'; then
            wp_owner="www-data"
        fi
        if ! sudo -u "$wp_owner" test -r "$wp_config"; then
            log_message WARNING "Skipping $wp_path: wp-config.php is not readable by a non-root site user. Fix its owner/group explicitly before import."
            continue
        fi
        url="$(timeout 20s sudo -u "$wp_owner" wp --skip-plugins --skip-themes option get home --path="$wp_path" 2>/dev/null || true)"
        host="$(printf '%s' "$url" | sed -E 's#^https?://([^/]+).*$#\1#')"
        primary="$host"
        domain="${host#www.}"
        validate_domain "$domain" || continue
        site_index_by_domain "$domain" >/dev/null 2>&1 && continue
        php_version="$(detect_site_php_version_from_nginx "$domain" "$wp_path" || true)"
        if ! validate_php_version "$php_version"; then
            validate_php_version "$DEFAULT_PHP_VERSION" || \
                die "The configured default PHP version is invalid: $DEFAULT_PHP_VERSION"
            php_version="$DEFAULT_PHP_VERSION"
        fi
        next_index=$((SITE_COUNT + 1))
        redis_db="$(first_available_redis_database)" || die "No Redis database is available; at most 16 sites can be imported."
        www=no
        [[ "$primary" == "www.$domain" ]] && www=yes
        SITE_COUNT=$next_index
        SITE_DOMAINS[next_index]="$domain"
        SITE_PRIMARY_DOMAINS[next_index]="$primary"
        SITE_PHP_VERSIONS[next_index]="$php_version"
        SITE_WOOCOMMERCE[next_index]="no"
        SITE_WWW[next_index]="$www"
        SITE_REDIS_DATABASES[next_index]="$redis_db"
        SITE_ADMIN_USERS[next_index]="unknown"
        SITE_ADMIN_EMAILS[next_index]="unknown@$domain"
        SITE_TITLES[next_index]="$domain"
        SITE_PATHS[next_index]="$wp_path"
        SITE_MODES[next_index]="imported"
        set_site_policy "$domain" user "$wp_owner"
        imported=$((imported + 1))
        log_message SUCCESS "Imported $domain from $wp_path."
    done < <(find /var/www /home -xdev -type f -name wp-config.php -print0 2>/dev/null)
    save_sites_config
    ensure_environment_config
    log_message INFO "Import completed; $imported site(s) added."
}

headers_have_managed_hsts() {
    local headers="$1"
    grep -Eqi '^strict-transport-security:[[:space:]]*max-age=15552000([;[:space:]]|$)' <<< "$headers" &&
        ! grep -Eqi '^strict-transport-security:[[:space:]]*max-age=0([;[:space:]]|$)' <<< "$headers"
}

wp_debug_value_is_false() {
    case "${1-}" in
        ""|0|false) return 0 ;;
        *) return 1 ;;
    esac
}

host_audit_line() {
    printf '%-7s %-24s %s\n' "$1" "$2" "$3"
}

system_audit() {
    local ssh_config listeners unsafe timer value i domain user_id
    printf 'wp-shell host audit (read-only; UNKNOWN means not verified)\n\n'
    if ssh_config="$(sshd -T 2>/dev/null)"; then
        value="$(awk '$1=="permitrootlogin" {print $2}' <<< "$ssh_config")"
        case "$value" in no|prohibit-password|without-password) host_audit_line PASS SSH-root "$value" ;; *) host_audit_line WARN SSH-root "$value: review root login policy" ;; esac
        value="$(awk '$1=="passwordauthentication" {print $2}' <<< "$ssh_config")"
        if [[ "$value" == no ]]; then host_audit_line PASS SSH-password disabled
        else host_audit_line WARN SSH-password 'Enabled; verify a second key-based session before changing SSH settings.'; fi
        host_audit_line INFO SSH-port "$(awk '$1=="port" {print $2}' <<< "$ssh_config" | paste -sd, -) (Match blocks may differ per user/address)"
    else
        host_audit_line UNKNOWN SSH 'Cannot read sshd effective defaults.'
    fi
    if listeners="$(ss -H -lnt 2>/dev/null)"; then
        unsafe="$(awk '$4 ~ /:(3306|6379)$/ && $4 !~ /^(127[.]|\[::1\]:|::1:)/ {print $4}' <<< "$listeners")"
        if [[ -z "$unsafe" ]]; then host_audit_line PASS DB-Redis-listeners 'No TCP listeners exposed on non-loopback addresses at 3306/6379.'
        else host_audit_line WARN DB-Redis-listeners "Review public bind/firewall: $unsafe"; fi
        printf '\nListening TCP addresses (review nonstandard ports separately):\n'
        awk '{print "  "$4}' <<< "$listeners"
    else host_audit_line UNKNOWN Listeners 'ss failed.'; fi
    if value="$(timeout 4s mariadb --connect-timeout=3 -NBe "SELECT COUNT(*) FROM mysql.user WHERE User='' OR (User='root' AND Host NOT IN ('localhost','127.0.0.1','::1'));" 2>/dev/null)"; then
        if [[ "$value" == 0 ]]; then host_audit_line PASS DB-accounts 'No anonymous or remote-root accounts found.'
        else host_audit_line WARN DB-accounts "$value anonymous/remote-root account(s); review grants before removing."; fi
    else host_audit_line UNKNOWN DB-accounts 'Could not inspect local MariaDB grants.'; fi
    for timer in apt-daily.timer apt-daily-upgrade.timer certbot.timer wp-shell-backup.timer wp-shell-metrics.timer; do
        if systemctl is-active --quiet "$timer"; then host_audit_line PASS "$timer" active
        else host_audit_line WARN "$timer" 'inactive or not installed'; fi
    done
    if dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -Fq 'install ok installed'; then
        value="$(apt-config dump | grep -E 'APT::Periodic::Unattended-Upgrade|Unattended-Upgrade::(Allowed-Origins|Origins-Pattern|Automatic-Reboot)' || true)"
        printf '\nUnattended upgrade policy (timers alone do not prove package/origin coverage):\n%s\n' "$value"
        host_audit_line WARN PPA-updates 'Verify PHP PPA coverage with unattended-upgrade --dry-run --debug; third-party origins are not implicitly trusted.'
    else host_audit_line WARN Security-updates 'unattended-upgrades is not installed. Opt in: wp-shell system updates enable --confirm'; fi
    if [[ -e /var/run/reboot-required ]]; then host_audit_line WARN Reboot 'A reboot is required; schedule it after checking backups.'
    else host_audit_line PASS Reboot 'No reboot-required marker.'; fi
    if command -v aa-status >/dev/null 2>&1; then
        if aa-status --enabled >/dev/null 2>&1; then host_audit_line PASS AppArmor enabled
        else host_audit_line WARN AppArmor 'Not enabled; review OS policy.'; fi
    else host_audit_line UNKNOWN AppArmor 'aa-status is not installed.'; fi
    printf '\nMemory, swap, filesystem capacity and inode use:\n'
    free -m
    df -h / /var/www
    df -i / /var/www
    for value in /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io; do
        [[ ! -r "$value" ]] || { printf '%s: ' "$value"; head -n 1 "$value"; }
    done
    awk '/^oom_kill / {print "Kernel OOM kills since boot: " $2}' /proc/vmstat
    printf '\nSite boundaries and schedules:\n'
    for ((i=1; i<=SITE_COUNT; i++)); do
        domain="${SITE_DOMAINS[$i]}"
        user_id="$(site_run_user "$domain")"
        if [[ "$user_id" == www-data ]]; then host_audit_line WARN "$domain" 'Legacy shared PHP UID; separate pools are not a security boundary.'
        else host_audit_line PASS "$domain" "PHP user: $user_id"; fi
        host_audit_line INFO "$domain" "Redis mode: $(site_policy_value "$domain" redis-mode shared); WP cron: $(site_policy_value "$domain" cron-mode request); cache invalidation: $(site_policy_value "$domain" cache-auto disabled)"
    done
    host_audit_line INFO Redis-boundary 'Redis DB numbers/prefixes do not isolate credentials. Use per-site instances for untrusted sites.'
    host_audit_line INFO Scope 'No SSH/firewall/accounts/sysctl settings were changed. Review service updates, plugins and offsite restore tests separately.'
}

enable_security_updates() {
    [[ "${1:-}" == --confirm ]] || die "Impact: install unattended-upgrades and enable daily security package installation without automatic reboot. Re-run with --confirm."
    apt-get update
    apt_install unattended-upgrades
    write_managed_file /etc/apt/apt.conf.d/52wp-shell-updates 0644 root root <<'EOF'
// Managed opt-in. Preserve Ubuntu/vendor origin lists. Never reboot unattended.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
    log_message SUCCESS "Daily unattended upgrades enabled without automatic reboots. Existing allowed origins are preserved; review PHP PPA coverage with a dry run."
}

authorized_admin_key_file() {
    local candidate user
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
        candidate="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.ssh/authorized_keys"
        if [[ -f "$candidate" && ! -L "$candidate" ]] && grep -Eq '^[[:space:]]*(ssh-|ecdsa-|sk-)' "$candidate"; then
            printf '%s' "$candidate"
            return 0
        fi
    fi
    while IFS=: read -r user _uid _gid _comment home _shell; do
        [[ "$user" != root ]] || continue
        id -nG "$user" 2>/dev/null | grep -Eq '(^| )(sudo|admin)( |$)' || continue
        candidate="$home/.ssh/authorized_keys"
        if [[ -f "$candidate" && ! -L "$candidate" ]] && grep -Eq '^[[:space:]]*(ssh-|ecdsa-|sk-)' "$candidate"; then
            printf '%s' "$candidate"
            return 0
        fi
    done < /etc/passwd
    return 1
}

apply_ssh_hardening() {
    CURRENT_STEP="apply SSH hardening"
    local confirmation="${1:-}" key_file
    [[ "$confirmation" == --confirm-lockout-risk ]] || die "Impact: disable root/password/keyboard-interactive SSH logins after validating an admin public key. Re-run with --confirm-lockout-risk from an active SSH session."
    [[ -n "${SSH_CONNECTION:-}" ]] || die "Refusing SSH hardening without an active SSH connection. Use the provider console for first access."
    key_file="$(authorized_admin_key_file)" || die "No usable public key was found for a non-root sudo administrator. SSH was not changed."
    install -d -m 0755 /etc/ssh/sshd_config.d
    transaction_begin "$CURRENT_STEP"
    transaction_mark_service sshd
    write_managed_file /etc/ssh/sshd_config.d/99-wp-shell-hardening.conf 0644 root root <<'EOF'
# Managed by wp-shell. Keep site-specific Match blocks in a separate file.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
EOF
    if [[ "$DRY_RUN" == no ]]; then
        sshd -t || die "sshd rejected the hardening drop-in; the transaction will be rolled back."
        systemctl reload ssh 2>/dev/null || systemctl reload sshd
    fi
    log_message SUCCESS "SSH hardening applied after verifying $key_file. The current established connection was not terminated."
}

ufw_rule_present() {
    local expression="$1"
    ufw status 2>/dev/null | grep -Eq "$expression"
}

apply_firewall_policy() {
    CURRENT_STEP="apply UFW policy"
    local confirmation="${1:-}" ssh_port
    [[ "$confirmation" == --confirm ]] || die "Impact: set default-deny inbound and add rate-limited SSH plus HTTP/HTTPS rules. Existing unrelated rules are reported but not deleted. Re-run with --confirm."
    ssh_port="$(detect_ssh_port)"
    [[ "$ssh_port" =~ ^[0-9]+$ && "$ssh_port" -ge 1 && "$ssh_port" -le 65535 ]] || die "Could not determine a valid SSH port."
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        [[ "${SSH_CONNECTION##* }" == "$ssh_port" ]] || die "The active SSH destination port differs from sshd's effective port; UFW was not changed."
    fi
    ufw default deny incoming
    ufw default allow outgoing
    ufw_rule_present "^${ssh_port}/tcp[[:space:]]+LIMIT" || ufw limit "${ssh_port}/tcp" comment 'SSH rate limit managed by wp-shell'
    ufw_rule_present '^80/tcp[[:space:]]+ALLOW' || ufw allow 80/tcp comment 'HTTP managed by wp-shell'
    ufw_rule_present '^443/tcp[[:space:]]+ALLOW' || ufw allow 443/tcp comment 'HTTPS managed by wp-shell'
    ufw --force enable
    log_message SUCCESS "UFW default-deny is active with SSH $ssh_port rate limiting and ports 80/443. Existing unrelated rules were preserved for lockout safety; review 'ufw status numbered'."
}

configure_aide() {
    CURRENT_STEP="configure AIDE weekly audit"
    local confirmation="${1:-}" aide_timer
    [[ "$confirmation" == --confirm ]] || die "Impact: install AIDE configuration and one low-priority weekly integrity check; no initial database or check is run. Re-run with --confirm."
    apt-get update
    apt_install aide
    install -d -m 0755 /etc/aide/aide.conf.d /etc/cron.d
    write_managed_file /etc/aide/aide.conf.d/99_wp_shell 0644 root root <<'EOF'
# Managed by wp-shell. Mutable WordPress data is intentionally excluded.
!/var/www/.*/public/wp-content/uploads
!/var/www/.*/public/wp-content/cache
!/var/www/.*/cache
!/var/www/.*/backups
!/var/www/.*/public/.*/wp-content/uploads
!/var/www/.*/public/.*/wp-content/cache
EOF
    write_managed_file /etc/cron.d/wp-shell-aide 0644 root root <<'EOF'
SHELL=/bin/sh
PATH=/usr/sbin:/usr/bin:/sbin:/bin
17 3 * * 0 root timeout 30m nice -n 19 ionice -c3 aide --check >>/var/log/wp-shell/aide-check.log 2>&1
EOF
    for aide_timer in wp-shell-aide.timer aidecheck.timer dailyaidecheck.timer; do
        if systemctl list-unit-files "$aide_timer" >/dev/null 2>&1; then systemctl disable --now "$aide_timer"; fi
    done
    log_message SUCCESS "AIDE weekly cron installed. Initialize its database manually after reviewing exclusions; no check was started."
}

configure_external_mail() {
    CURRENT_STEP="restrict Postfix to loopback"
    local confirmation="${1:-}" stage
    [[ "$confirmation" == --confirm-external-mail ]] || die "Impact: make local Postfix listen only on loopback because WordPress uses a confirmed external provider such as Amazon SES. No mail is sent. Re-run with --confirm-external-mail."
    command -v postconf >/dev/null 2>&1 || die "Postfix is not installed; nothing was changed."
    stage="$(safe_temp_dir)"
    register_temp_path "$stage"
    cp -a /etc/postfix/. "$stage/"
    postconf -c "$stage" -e 'inet_interfaces = loopback-only'
    postfix -c "$stage" check
    transaction_begin "$CURRENT_STEP"
    transaction_mark_service postfix
    write_managed_file /etc/postfix/main.cf 0644 root root < "$stage/main.cf"
    postfix check
    systemctl reload postfix
    set_host_policy external-mail confirmed
    rm -rf -- "$stage"
    log_message SUCCESS "Postfix now listens on loopback only. No test message was sent."
}

system_command() {
    case "${1:-audit}" in
        audit) system_audit ;;
        updates) [[ "${2:-}" == enable ]] || die "Usage: wp-shell system updates enable --confirm"; enable_security_updates "${3:-}" ;;
        logs) [[ "${2:-}" == install ]] || die "Usage: wp-shell system logs install"; configure_log_rotation ;;
        wp-cli) [[ "${2:-}" == verify ]] || die "Usage: wp-shell system wp-cli verify"; install_wp_cli --verify ;;
        ssh) [[ "${2:-}" == apply ]] || die "Usage: wp-shell system ssh apply --confirm-lockout-risk"; apply_ssh_hardening "${3:-}" ;;
        firewall) [[ "${2:-}" == apply ]] || die "Usage: wp-shell system firewall apply --confirm"; apply_firewall_policy "${3:-}" ;;
        aide) [[ "${2:-}" == apply ]] || die "Usage: wp-shell system aide apply --confirm"; configure_aide "${3:-}" ;;
        mail) [[ "${2:-}" == external ]] || die "Usage: wp-shell system mail external --confirm-external-mail"; configure_external_mail "${3:-}" ;;
        *) die "Usage: wp-shell system audit|updates|logs|wp-cli|ssh|firewall|aide|mail" ;;
    esac
}

validate_managed_stack() {
    local version
    command -v nginx >/dev/null 2>&1 && nginx -t
    while IFS= read -r version; do
        [[ -n "$version" && -x "/usr/sbin/php-fpm$version" ]] || continue
        "php-fpm$version" -t
    done < <(unique_php_versions)
    command -v sshd >/dev/null 2>&1 && sshd -t
}

wordpress_queue_status() {
    local domain="$1" due="unknown" prefix table pending="unknown" failed="unknown"
    due="$(site_wp_cli_readonly "$domain" cron event list --due-now --format=count 2>/dev/null || printf unknown)"
    prefix="$(site_wp_cli_readonly "$domain" db prefix 2>/dev/null || true)"
    if [[ "$prefix" =~ ^[A-Za-z0-9_]{1,48}$ ]]; then
        table="${prefix}actionscheduler_actions"
        if site_wp_cli_readonly "$domain" db query "SHOW TABLES LIKE '$table';" --skip-column-names 2>/dev/null | grep -Fxq "$table"; then
            pending="$(site_wp_cli_readonly "$domain" db query "SELECT COUNT(*) FROM $table WHERE status='pending';" --skip-column-names 2>/dev/null || printf unknown)"
            failed="$(site_wp_cli_readonly "$domain" db query "SELECT COUNT(*) FROM $table WHERE status='failed';" --skip-column-names 2>/dev/null || printf unknown)"
        else
            pending=not-installed
            failed=not-installed
        fi
    fi
    printf '  Queues: wp-cron-due=%s action-scheduler-pending=%s failed=%s\n' "$due" "$pending" "$failed"
}

backup_public_probe() {
    local index="$1" domain primary code
    domain="${SITE_DOMAINS[$index]}"
    primary="${SITE_PRIMARY_DOMAINS[$index]}"
    [[ -s "/etc/letsencrypt/live/$domain/fullchain.pem" ]] || { printf 'not-tested(no-certificate)'; return; }
    code="$(curl --noproxy '*' --silent --insecure --output /dev/null --max-time 5 --write-out '%{http_code}' \
        --resolve "$primary:443:127.0.0.1" "https://$primary/backups/wp-shell-audit.zip" 2>/dev/null || printf 000)"
    case "$code" in 403|404) printf 'blocked(%s)' "$code" ;; *) printf 'review(%s)' "$code" ;; esac
}

control_plane_status() {
    local version
    printf 'wp-shell %s control-plane status\n' "$WP_SHELL_VERSION"
    printf 'Environment: mode=%s PHP=%s sites=%s Cloudflare=%s\n' \
        "${ENVIRONMENT_MODE:-unconfigured}" "$DEFAULT_PHP_VERSION" "$SITE_COUNT" "$(host_policy_value cloudflare disabled)"
    printf 'Services: nginx=%s mariadb=%s redis=%s fail2ban=%s\n' \
        "$(service_state nginx)" "$(service_state mariadb)" "$(service_state redis-server)" "$(service_state fail2ban)"
    while IFS= read -r version; do
        [[ -n "$version" ]] || continue
        printf 'PHP %s FPM: %s\n' "$version" "$(service_state "php${version}-fpm")"
    done < <(unique_php_versions)
    printf 'Timers: metrics=%s backup=%s certificate=%s Cloudflare=%s\n' \
        "$(service_state wp-shell-metrics.timer)" "$(service_state wp-shell-backup.timer)" \
        "$(service_state certbot.timer)" "$(service_state wp-shell-cloudflare-ips.timer)"
    printf 'Failed units: '
    systemctl --failed --no-legend --plain 2>/dev/null | awk 'END{print NR+0}'
    printf 'Last transaction: %s\n' "$(if [[ -s "$LAST_TRANSACTION_FILE" ]]; then head -n1 "$LAST_TRANSACTION_FILE"; else printf none; fi)"
}

control_plane_audit() {
    local i domain wp_config mode owner group redis_info severe_log_count=0 log_file php_pressure
    printf 'wp-shell audit (read-only; no task, email, form, update, deletion or service reload)\n\n'
    if validate_managed_stack >/dev/null 2>&1; then host_audit_line PASS Config-syntax 'Nginx, installed PHP-FPM and sshd candidates validate.'
    else host_audit_line WARN Config-syntax 'At least one Nginx/PHP-FPM/sshd validation failed.'; fi
    system_audit
    printf '\nRuntime capacity\n'
    free -m
    swapon --show 2>/dev/null || true
    df -h / /var/www
    if [[ -s "$REDIS_SECRET_FILE" ]]; then
        redis_info="$(REDISCLI_AUTH="$(<"$REDIS_SECRET_FILE")" timeout 4s redis-cli --no-auth-warning INFO memory stats 2>/dev/null || true)"
        printf 'Redis used/max/evicted: %s / %s / %s\n' \
            "$(awk -F: '$1=="used_memory_human"{gsub(/\r/,"",$2);print $2}' <<< "$redis_info")" \
            "$(awk -F: '$1=="maxmemory_human"{gsub(/\r/,"",$2);print $2}' <<< "$redis_info")" \
            "$(awk -F: '$1=="evicted_keys"{gsub(/\r/,"",$2);print $2}' <<< "$redis_info")"
    fi
    printf '\n'
    mariadb_audit
    printf '\nWordPress sites\n'
    for ((i=1; i<=SITE_COUNT; i++)); do
        domain="${SITE_DOMAINS[$i]}"
        wp_config="$(site_wp_path "$domain")/wp-config.php"
        if [[ -f "$wp_config" ]]; then
            read -r mode owner group < <(stat -c '%a %U %G' "$wp_config")
        else
            mode=missing; owner=unknown; group=unknown
        fi
        printf '%s: wp-config=%s:%s:%s TLS=%s backup-public=%s\n' "$domain" "$mode" "$owner" "$group" \
            "$(site_tls_expiry "$domain")" "$(backup_public_probe "$i")"
        if [[ -s "$METRICS_DB" ]]; then
            php_pressure="$(sqlite3 -separator / "$METRICS_DB" "SELECT php_active,php_max_children,php_queue FROM site_samples WHERE domain='$domain' ORDER BY ts DESC LIMIT 1;" 2>/dev/null || true)"
            printf '  PHP active/max/queue: %s\n' "${php_pressure:-unknown}"
        fi
        wordpress_queue_status "$domain"
        printf '  Policies: page-cache=%s object-cache=%s headers=%s HSTS=%s XML-RPC=%s login-limit=%s staging=%s\n' \
            "$(site_policy_value "$domain" page-cache disabled)" "$(site_policy_value "$domain" object-cache disabled)" \
            "$(site_policy_value "$domain" header-profile compatible)" "$(site_policy_value "$domain" hsts disabled)" \
            "$(site_policy_value "$domain" xmlrpc enabled)" "$(site_policy_value "$domain" login-limit disabled)" \
            "$(site_policy_value "$domain" staging-path none)"
    done
    printf '\nRecent severe log tail (up to 2,000 lines per file; counts only)\n'
    for log_file in /var/log/nginx/error.log /var/log/mysql/error.log /var/log/redis/redis-server.log /var/www/*/logs/php-error.log; do
        [[ -f "$log_file" ]] || continue
        severe_log_count="$(tail -n 2000 "$log_file" 2>/dev/null | grep -Eci 'fatal|panic|emerg|crit|out of memory|allowed memory size|server reached pm.max_children' || true)"
        printf '%s: %s\n' "$log_file" "$severe_log_count"
    done
    printf '\nCloudflare Web attacks: use Nginx verified-IP rate limiting and, when needed, a separately managed application firewall or Cloudflare WAF. Standard nftables Fail2ban jails cannot ban the real visitor through Cloudflare. API blocking remains disabled unless a separate token is explicitly supplied.\n'
}

control_plane_plan() {
    local i domain version mariadb_block
    printf 'wp-shell apply plan (no changes)\n'
    printf '  Host: Nginx global/default-host/log format, PHP baseline, loopback Redis/MariaDB, SSH-only Fail2ban, logrotate and certificate hook.\n'
    printf '  Excluded: SSH hardening, UFW reconciliation, AIDE install, Cloudflare enablement, plugin/theme updates, due tasks, email tests, backup deletion and reboot.\n'
    for ((i=1; i<=SITE_COUNT; i++)); do
        domain="${SITE_DOMAINS[$i]}"
        [[ "${SITE_MODES[$i]}" == managed ]] || continue
        printf '  Site %s: Nginx security/cache template, production constants and bounded permissions.\n' "$domain"
    done
    while IFS= read -r version; do [[ -z "$version" ]] || printf '  Validate/reload PHP %s FPM if its managed fingerprint changes.\n' "$version"; done < <(unique_php_versions)
    printf '  Every changed file receives a timestamp/transaction backup; candidates are atomically installed and syntax-validated.\n'
    mariadb_block="$(mariadb_apply_block_reason)"
    if [[ -n "$mariadb_block" ]]; then
        printf '  BLOCKED: %s\n' "$mariadb_block"
    fi
}

apply_wordpress_baseline() {
    local i domain wp_config
    for ((i=1; i<=SITE_COUNT; i++)); do
        [[ "${SITE_MODES[$i]}" == managed ]] || continue
        domain="${SITE_DOMAINS[$i]}"
        wp_config="$(site_wp_path "$domain")/wp-config.php"
        [[ -f "$wp_config" && ! -L "$wp_config" ]] || continue
        adopt_object_cache_policy "$domain"
        transaction_begin "$CURRENT_STEP"
        [[ "$TRANSACTION_ACTIVE" != yes ]] || transaction_backup_file "$wp_config"
        site_wp_cli "$domain" config set WP_DEBUG false --raw
        site_wp_cli "$domain" config set DISALLOW_FILE_EDIT true --raw
        site_wp_cli "$domain" config set FORCE_SSL_ADMIN true --raw
        site_wp_cli "$domain" config set WP_ENVIRONMENT_TYPE production
        if [[ "$(site_policy_value "$domain" cron-mode request)" == system ]]; then
            site_wp_cli "$domain" config set DISABLE_WP_CRON true --raw
        fi
        chmod "$(site_config_mode "$domain")" "$wp_config"
    done
}

apply_control_plane() {
    local confirmation="${1:-}" i
    [[ "$confirmation" == --confirm ]] || { control_plane_plan; die "Impact: rewrite managed service/site configuration and gracefully reload affected services. Re-run with: wp-shell apply --confirm"; }
    CURRENT_STEP="apply audited baseline"
    control_plane_plan
    configure_mariadb
    configure_redis
    configure_php
    configure_fail2ban
    configure_log_rotation
    install_certbot_deploy_hook
    install_nginx_log_format
    disable_distribution_nginx_default
    for ((i=1; i<=SITE_COUNT; i++)); do
        [[ "${SITE_MODES[$i]}" == managed && -s "/etc/letsencrypt/live/${SITE_DOMAINS[$i]}/fullchain.pem" ]] || continue
        configure_https_site "$i"
    done
    apply_wordpress_baseline
    validate_managed_stack
    systemctl reload nginx
    log_message SUCCESS "Audited baseline applied. SSH/UFW/AIDE/Cloudflare remain separate explicit operations."
}

rollback_command() {
    local transaction_id="${1:-}" confirmation="${2:-}" path
    if [[ -z "$transaction_id" || "$transaction_id" == --confirm ]]; then
        [[ -s "$LAST_TRANSACTION_FILE" ]] || die "No last transaction is recorded."
        confirmation="${1:-}"
        transaction_id="$(head -n1 "$LAST_TRANSACTION_FILE")"
    fi
    [[ "$transaction_id" =~ ^[0-9]{8}T[0-9]{6}Z-[a-z0-9-]+\.[A-Za-z0-9]+$ ]] || die "Invalid transaction ID."
    [[ "$confirmation" == --confirm ]] || die "Impact: restore every file recorded before transaction $transaction_id and reload affected services. Re-run with --confirm."
    path="$TRANSACTION_DIR/$transaction_id"
    [[ -d "$path" && ! -L "$path" ]] || die "Transaction not found: $transaction_id"
    transaction_rollback_internal "$path" manual
    validate_managed_stack
}

dry_run_command() {
    DRY_RUN=yes
    case "${1:-apply}" in
        apply) control_plane_plan ;;
        *) die "Usage: wp-shell dry-run apply" ;;
    esac
}

security_scan() {
    local failed=0 i domain primary wp_config perms version constant value credentials_file
    local origin_headers public_headers redis_secret
    for service in nginx mariadb redis-server fail2ban; do
        if ! systemctl is-active --quiet "$service"; then
            log_message ERROR "$service is not running."
            failed=$((failed + 1))
        fi
    done
    while IFS= read -r version; do
        [[ -n "$version" ]] || continue
        if ! systemctl is-active --quiet "php${version}-fpm"; then
            log_message ERROR "php${version}-fpm is not running."
            failed=$((failed + 1))
        fi
    done < <(unique_php_versions)
    nginx -t || failed=$((failed + 1))
    fail2ban-client -t || failed=$((failed + 1))
    for ((i = 1; i <= SITE_COUNT; i++)); do
        domain="${SITE_DOMAINS[$i]}"
        wp_config="$(site_wp_path "$domain")/wp-config.php"
        if [[ -f "$wp_config" ]]; then
            perms="$(stat -c '%a' "$wp_config")"
            [[ "$perms" == "640" || "$perms" == "600" ]] || { log_message WARNING "$wp_config has permissions $perms."; failed=$((failed + 1)); }
            if [[ "$(stat -c '%U' "$wp_config")" != root || "$(stat -c '%G' "$wp_config")" != "$(id -gn "$(site_run_user "$domain")")" ]]; then
                log_message WARNING "$domain wp-config.php must be root-owned and readable only by its PHP group."
                failed=$((failed + 1))
            fi
            for constant in FORCE_SSL_ADMIN DISALLOW_FILE_EDIT; do
                value="$(site_wp_cli "$domain" config get "$constant" 2>/dev/null || true)"
                [[ "$value" == "1" || "$value" == "true" ]] || {
                    log_message WARNING "$domain does not have $constant enabled."
                    failed=$((failed + 1))
                }
            done
            value="$(site_wp_cli "$domain" config get WP_DEBUG 2>/dev/null || true)"
            wp_debug_value_is_false "$value" || { log_message WARNING "$domain must have WP_DEBUG disabled."; failed=$((failed + 1)); }
            value="$(site_wp_cli "$domain" config get WP_ENVIRONMENT_TYPE 2>/dev/null || true)"
            [[ "$value" == production ]] || { log_message WARNING "$domain main site environment type is not production."; failed=$((failed + 1)); }
            if [[ "$(site_policy_value "$domain" object-cache disabled)" == enabled ]] && \
               ! site_wp_cli "$domain" redis status 2>/dev/null | grep -Fq 'Status: Connected'; then
                log_message WARNING "$domain is not connected to Redis Object Cache."
                failed=$((failed + 1))
            fi
            if ! verify_wordpress_core_strict "$domain" >/dev/null 2>&1; then
                log_message WARNING "$domain does not pass strict WordPress core checksum verification. Run: sudo wp-shell site $domain core-repair"
                failed=$((failed + 1))
            fi
        else
            log_message ERROR "$domain is missing wp-config.php; its security state cannot be verified."
            failed=$((failed + 1))
        fi
        [[ -s "/etc/letsencrypt/live/$domain/fullchain.pem" ]] || { log_message ERROR "$domain has no certificate."; failed=$((failed + 1)); }
        if [[ "$(site_policy_value "$domain" cron-mode)" == system ]] && [[ ! -s "/etc/cron.d/wp-shell-$(site_pool_id "$domain")" ]]; then
            log_message ERROR "$domain has managed WP-Cron enabled but its Cron file is missing."
            failed=$((failed + 1))
        fi
        if [[ "$(site_policy_value "$domain" cache-auto)" == enabled ]]; then
            if [[ ! -f "$(site_wp_path "$domain")/wp-content/mu-plugins/wp-shell-cache.php" ]] || ! systemctl is-active --quiet wp-shell-operations.timer; then
                log_message ERROR "$domain automatic page-cache invalidation is incomplete."
                failed=$((failed + 1))
            fi
        fi
        primary="${SITE_PRIMARY_DOMAINS[$i]}"
        origin_headers="$(curl --silent --show-error --output /dev/null --dump-header - --max-time 5 \
            --resolve "$primary:443:127.0.0.1" "https://$primary/wp-login.php" 2>/dev/null | tr -d '\r' || true)"
        public_headers="$(curl --silent --show-error --output /dev/null --dump-header - --max-time 5 \
            "https://$primary/wp-login.php" 2>/dev/null | tr -d '\r' || true)"
        if [[ "$(site_policy_value "$domain" hsts disabled)" == enabled ]]; then
            if ! headers_have_managed_hsts "$origin_headers"; then
                log_message WARNING "$domain origin does not return its explicitly enabled HSTS policy."
                failed=$((failed + 1))
            elif ! headers_have_managed_hsts "$public_headers"; then
                log_message WARNING "$domain public endpoint overrides or removes HSTS; check Cloudflare or another reverse proxy."
                failed=$((failed + 1))
            fi
        fi
        credentials_file="$(site_credentials_file "$domain")"
        if [[ -e "$credentials_file" && "$(stat -c '%a' "$credentials_file")" != "600" ]]; then
            log_message WARNING "$credentials_file must have permissions 600."
            failed=$((failed + 1))
        fi
    done
    if [[ "$ENVIRONMENT_UFW" == "yes" ]] && ! ufw status 2>/dev/null | grep -Fq 'Status: active'; then
        log_message WARNING "UFW is configured for this environment but is not active."
        failed=$((failed + 1))
    fi
    if [[ -s "$REDIS_SECRET_FILE" ]]; then
        redis_secret="$(<"$REDIS_SECRET_FILE")"
        if secret_exists_in_logs "$redis_secret"; then
            log_message WARNING "The current Redis credential appears in wp-shell logs. Run: sudo wp-shell rotate-redis-secret"
            failed=$((failed + 1))
        fi
    fi
    if ((failed == 0)); then
        log_message SUCCESS "Security checks passed. This is a configuration check, not a complete security guarantee. Use 'wp-shell system audit' for host advisories."
    else
        die "Security checks found $failed issue(s)."
    fi
}

add_site_command() {
    local index
    [[ -f "$ENVIRONMENT_CONFIG_FILE" ]] || die "Install or adopt the WordPress environment before adding a website."
    wordpress_environment_detected || die "The Nginx/PHP-FPM/database environment is incomplete. Repair it before adding a website."
    collect_site_input
    index="$SITE_COUNT"
    create_site_identity "${SITE_DOMAINS[$index]}"
    prepare_stack
    deploy_site "$index"
    install_self
    install_metrics_timer
    collect_metrics
    show_site_deployment_summary "$index"
}

new_server_wizard() {
    local mode_choice php_choice i
    printf '\nwp-shell v%s environment setup\n\n' "$WP_SHELL_VERSION"
    printf 'Deployment mode:\n  1) Single website\n  2) Multiple websites\n'
    while true; do
        read -r -p "Select [1-2]: " mode_choice
        case "$mode_choice" in
            1) ENVIRONMENT_MODE="single"; break ;;
            2) ENVIRONMENT_MODE="multi"; break ;;
            *) log_message WARNING "Invalid selection." ;;
        esac
    done

    printf '\nPHP version:\n'
    for i in "${!AVAILABLE_PHP_VERSIONS[@]}"; do
        printf '  %d) PHP %s\n' "$((i + 1))" "${AVAILABLE_PHP_VERSIONS[$i]}"
    done
    while true; do
        read -r -p "Select [1-${#AVAILABLE_PHP_VERSIONS[@]}]: " php_choice
        [[ "$php_choice" =~ ^[0-9]+$ ]] || { log_message WARNING "Invalid selection."; continue; }
        ((php_choice >= 1 && php_choice <= ${#AVAILABLE_PHP_VERSIONS[@]})) || { log_message WARNING "Invalid selection."; continue; }
        DEFAULT_PHP_VERSION="${AVAILABLE_PHP_VERSIONS[$((php_choice - 1))]}"
        break
    done

    if collect_yes_no "Enable and configure UFW (existing rules are preserved)" yes; then
        ENVIRONMENT_UFW="yes"
    else
        ENVIRONMENT_UFW="no"
    fi
    save_environment_config
    bootstrap_server
}

nginx_installed() {
    command -v nginx >/dev/null 2>&1 || [[ -x /usr/sbin/nginx ]]
}

php_fpm_installed() {
    compgen -G '/etc/php/*/fpm/pool.d' >/dev/null || compgen -G '/usr/sbin/php-fpm*' >/dev/null
}

database_server_installed() {
    command -v mariadb >/dev/null 2>&1 || command -v mysql >/dev/null 2>&1 || \
        [[ -x /usr/sbin/mariadbd || -x /usr/sbin/mysqld ]]
}

service_state() {
    local state
    state="$(systemctl is-active "$1" 2>/dev/null || true)"
    printf '%s' "${state:-unknown}"
}

wordpress_environment_detected() {
    nginx_installed && php_fpm_installed && database_server_installed
}

wp_shell_environment_managed() {
    [[ -f "$ENVIRONMENT_CONFIG_FILE" ]] && wordpress_environment_detected
}

install_or_repair_environment() {
    if [[ -f "$ENVIRONMENT_CONFIG_FILE" ]]; then
        load_environment_config
        bootstrap_server
    else
        new_server_wizard
    fi
}

installation_menu() {
    printf '\nwp-shell v%s\n' "$WP_SHELL_VERSION"
    printf 'Environment: WordPress stack not detected\n\n'
    printf '1) Install WordPress environment\n2) Import an existing WordPress site\n3) Show command help\n0) Exit\n'
    local choice
    read -r -p "Select [0-3]: " choice
    case "$choice" in
        1) install_or_repair_environment ;;
        2) import_existing_sites; install_self ;;
        3) show_help ;;
        0) return ;;
        *) die "Invalid selection." ;;
    esac
}

show_detected_environment() {
    printf '\nDetected WordPress stack\n'
    if nginx_installed; then
        printf '  %-14s installed (%s)\n' "Nginx" "$(service_state nginx)"
    else
        printf '  %-14s not installed\n' "Nginx"
    fi
    if php_fpm_installed; then
        printf '  %-14s installed (%s)\n' "PHP-FPM" "$(find /etc/php -mindepth 2 -maxdepth 2 -type d -name fpm -printf '%h\n' 2>/dev/null | xargs -r -n1 basename | sort -Vu | paste -sd, -)"
    else
        printf '  %-14s not installed\n' "PHP-FPM"
    fi
    if database_server_installed; then
        if command -v mariadb >/dev/null 2>&1 || [[ -x /usr/sbin/mariadbd ]]; then
            printf '  %-14s installed (%s)\n' "Database" "$(service_state mariadb)"
        else
            printf '  %-14s installed (%s)\n' "Database" "$(service_state mysql)"
        fi
    else
        printf '  %-14s not installed\n' "Database"
    fi
    printf '\nDetected WordPress configuration files\n'
    find /var/www /home -xdev -maxdepth 6 -type f -name wp-config.php -print 2>/dev/null | sed -n '1,20p'
}

prepare_imported_monitoring() {
    import_existing_sites
    ((SITE_COUNT > 0)) || die "No WordPress sites could be imported. Check file ownership and WP-CLI access."
    apt-get update
    apt_install ca-certificates curl python3 sqlite3 jq libfcgi-bin
    install_self
    install_metrics_timer
    collect_metrics
    log_message SUCCESS "Imported sites and local monitoring are ready. Existing Nginx and PHP routing were not changed."
    log_message INFO "Traffic and per-pool PHP metrics become complete after a site is explicitly transferred to wp-shell management."
}

transfer_imported_site() {
    local selector domain index email php_version
    ((SITE_COUNT > 0)) || import_existing_sites
    ((SITE_COUNT > 0)) || die "No WordPress sites could be imported."
    list_sites
    read -r -p "Site ID or domain to transfer to wp-shell: " selector
    domain="$(site_domain_from_selector "$selector")" || die "Unknown site ID or domain: $selector"
    index="$(site_index_by_domain "$domain")" || die "Unmanaged site: $domain"
    if [[ "${SITE_MODES[$index]}" != "imported" ]]; then
        die "$domain is already managed by wp-shell."
    fi
    printf '\nThis operation will replace the site Nginx/PHP-FPM/cache configuration and enable wp-shell Redis settings.\n'
    printf 'Create an independent server backup before continuing.\n'
    collect_yes_no "Transfer $domain to wp-shell management" no || { log_message INFO "No changes were applied."; return; }
    read -r -p "PHP version [${SITE_PHP_VERSIONS[$index]}]: " php_version
    php_version="${php_version:-${SITE_PHP_VERSIONS[$index]}}"
    validate_php_version "$php_version" || die "Unsupported PHP version: $php_version"
    SITE_PHP_VERSIONS[index]="$php_version"
    if [[ "${SITE_PRIMARY_DOMAINS[$index]}" == "www.$domain" ]]; then
        SITE_WWW[index]="yes"
    elif collect_yes_no "Include www.$domain in Nginx and the certificate" no; then
        SITE_WWW[index]="yes"
    else
        SITE_WWW[index]="no"
    fi
    if [[ "${SITE_ADMIN_EMAILS[$index]}" == unknown@* ]]; then
        while true; do
            read -r -p "Certificate administrator email: " email
            validate_email "$email" && break
            log_message WARNING "Invalid email address."
        done
        SITE_ADMIN_EMAILS[index]="$email"
    fi
    save_sites_config
    deploy_domain "$domain"
    collect_metrics
}

adoption_menu() {
    printf '\nwp-shell v%s\n' "$WP_SHELL_VERSION"
    printf 'Environment: existing WordPress stack detected, not managed by wp-shell\n\n'
    printf '1) Import existing websites only (safe)\n2) Import websites and enable local monitoring\n3) Import and transfer one website for wp-shell optimization\n4) Show detected environment\n5) Show command help\n0) Exit\n'
    local choice
    read -r -p "Select [0-5]: " choice
    case "$choice" in
        1) import_existing_sites; install_self ;;
        2) prepare_imported_monitoring ;;
        3) transfer_imported_site ;;
        4) show_detected_environment ;;
        5) show_help ;;
        0) return ;;
        *) die "Invalid selection." ;;
    esac
}

management_menu() {
    install_self
    printf '\nwp-shell v%s\n' "$WP_SHELL_VERSION"
    printf 'Environment: installed | Mode: %s | PHP: %s | Sites: %s\n\n' \
        "$ENVIRONMENT_MODE" "$DEFAULT_PHP_VERSION" "$SITE_COUNT"
    printf '1) Dashboard\n2) Add a new website\n3) Website list\n4) Website status\n5) Deploy or repair a website\n6) Back up one website\n7) Back up all websites\n8) Restore a website\n9) Import existing websites\n10) Traffic and resource report\n11) Analyze resource usage\n12) Apply safe tuning recommendations\n13) Apply audited configuration baseline\n14) Security scan\n15) Repair backup and metrics timers\n16) OPcache settings\n17) Host security and pressure audit\n18) Advanced operations help\n0) Exit\n'
    local choice domain backup_id range
    read -r -p "Select [0-18]: " choice
    case "$choice" in
        1)
            if [[ ! -s "$METRICS_DB" ]]; then
                install_self
                install_metrics_timer
                collect_metrics
            fi
            dashboard </dev/tty >/dev/tty
            ;;
        2) add_site_command ;;
        3) list_sites ;;
        4)
            if ((SITE_COUNT == 0)); then
                log_message WARNING "No sites are registered. Use option 2 or 9 first."
                return
            fi
            list_sites
            read -r -p "Site ID or domain (leave empty for all sites): " domain
            if [[ -n "$domain" ]]; then site_action "$domain" status; else status_all_sites; fi
            ;;
        5)
            ((SITE_COUNT > 0)) || die "No sites are registered. Use option 2 or 9 first."
            list_sites
            read -r -p "Site ID or domain to deploy or repair: " domain
            deploy_domain "$domain"
            ;;
        6)
            ((SITE_COUNT > 0)) || die "No sites are registered."
            list_sites
            read -r -p "Site ID or domain to back up: " domain
            site_action "$domain" backup
            ;;
        7) ((SITE_COUNT > 0)) || die "No sites are registered."; backup_all_sites ;;
        8)
            ((SITE_COUNT > 0)) || die "No sites are registered."
            list_sites
            read -r -p "Site ID or domain: " domain
            site_action "$domain" backups
            read -r -p "Backup ID: " backup_id
            site_action "$domain" restore "$backup_id"
            ;;
        9) import_existing_sites; install_self ;;
        10)
            read -r -p "Range [24h]: " range
            metrics_report "${range:-24h}"
            ;;
        11)
            read -r -p "Range [7d]: " range
            analyze_metrics "${range:-7d}"
            ;;
        12) apply_tuning ;;
        13)
            control_plane_plan
            collect_yes_no "Apply this transactional baseline" no || { log_message INFO "No changes were applied."; return; }
            apply_control_plane --confirm
            ;;
        14) security_scan ;;
        15) install_self; install_backup_timer; install_metrics_timer ;;
        16) opcache_menu ;;
        17) system_audit ;;
        18) show_help ;;
        0) return ;;
        *) die "Invalid selection." ;;
    esac
}

interactive_menu() {
    if wp_shell_environment_managed; then
        management_menu
    elif wordpress_environment_detected; then
        adoption_menu
    else
        installation_menu
    fi
}

show_help() {
    cat <<EOF
wp-shell v$WP_SHELL_VERSION - WordPress VPS operations without a web control panel

Usage:
  sudo wp-shell                                 Open the context-aware main menu
  sudo wp-shell install                         Install or repair the server environment
  sudo wp-shell dashboard                       Open the compact SSH dashboard
  sudo wp-shell audit                           Run the expanded read-only host/site audit
  sudo wp-shell status                          Show compact control-plane and service status
  sudo wp-shell dry-run apply                   Show the baseline plan without changing files
  sudo wp-shell apply --confirm                 Apply the transactional audited baseline
  sudo wp-shell rollback [ID] --confirm         Restore a committed transaction if files are unchanged
  sudo wp-shell report [1h|6h|24h|7d|14d|30d]   Print a non-interactive metrics report
  sudo wp-shell analyze [range]                  Analyze collected resource evidence
  sudo wp-shell tune --apply [--yes]             Apply safe PHP-FPM recommendations
  sudo wp-shell opcache status [PHP_VERSION]     Inspect configuration and live FPM OPcache
  sudo wp-shell opcache set PHP_VERSION MB STRINGS_MB  Save and apply OPcache settings
  sudo wp-shell mariadb audit                    Inspect runtime/effective values and all relevant definitions
  sudo wp-shell mariadb migrate-legacy --confirm  Transactionally remove recognized legacy memory directives
  sudo wp-shell site add                         Add and deploy a site
  sudo wp-shell site list                        List managed and imported sites
  sudo wp-shell site status [DOMAIN|ID]          Show site status
  sudo wp-shell site DOMAIN|ID summary           Show the website deployment summary
  sudo wp-shell site DOMAIN|ID core-verify       Strictly verify WordPress core files
  sudo wp-shell site DOMAIN|ID core-repair       Back up and repair WordPress core from ZIP
  sudo wp-shell site deploy DOMAIN|ID            Idempotently deploy or repair a site
  sudo wp-shell site import                      Discover existing WordPress sites
  sudo wp-shell site DOMAIN|ID ACTION            Run a compatibility site action
  sudo wp-shell metrics collect                  Collect one local metrics sample
  sudo wp-shell metrics install                  Install the one-minute collector
  sudo wp-shell backup-all                       Back up all sites
  sudo wp-shell restore DOMAIN|ID BACKUP_ID      Restore one backup
  sudo wp-shell optimize --confirm               Compatibility alias for the audited baseline apply
  sudo wp-shell rotate-redis-secret              Rotate Redis auth and redact matching logs
  sudo wp-shell cloudflare enable --confirm      Trust verified official Cloudflare proxy ranges
  sudo wp-shell cloudflare disable --confirm     Remove Cloudflare trust/updater without changing sites
  sudo wp-shell cloudflare check SOURCE CLAIMED  Test trusted vs forged CF-Connecting-IP handling
  sudo wp-shell security-scan                    Validate services, TLS, and permissions
  sudo wp-shell system audit                     Read-only host security/pressure review
  sudo wp-shell system updates enable --confirm  Opt in to unattended security updates
  sudo wp-shell system logs install              Install operation/site log rotation
  sudo wp-shell system wp-cli verify             Verify and reinstall signed WP-CLI
  sudo wp-shell system ssh apply --confirm-lockout-risk
  sudo wp-shell system firewall apply --confirm
  sudo wp-shell system aide apply --confirm
  sudo wp-shell system mail external --confirm-external-mail
  sudo wp-shell site DOMAIN nginx-apply           Refresh managed Nginx; preserve custom includes
  sudo wp-shell site DOMAIN page-cache enable --confirm|disable|status
  sudo wp-shell site DOMAIN object-cache enable --confirm|disable --confirm|status
  sudo wp-shell site DOMAIN cache-clear [page|object|opcache|all]
  sudo wp-shell site DOMAIN cache-auto enable|disable|status
  sudo wp-shell site DOMAIN cache-exclude /staging/
  sudo wp-shell site DOMAIN cron enable|disable|status
  sudo wp-shell site DOMAIN staging configure ABS_PATH URL_PATH PREFIX|off --confirm
  sudo wp-shell site DOMAIN hsts enable|disable|status
  sudo wp-shell site DOMAIN xmlrpc enable|disable|status
  sudo wp-shell site DOMAIN headers strict|compatible|status
  sudo wp-shell site DOMAIN isolate [--yes]       Migrate a legacy site to its own PHP UID
  sudo wp-shell site DOMAIN redis-isolate [MB]    Opt in to a private Redis socket/instance
  sudo wp-shell site DOMAIN login-limit direct|off|status
  sudo wp-shell backup verify DOMAIN [ID|latest]  Verify files, manifest and SHA256
  sudo wp-shell backup drill DOMAIN [ID|latest]   Test files + disposable restricted database
  sudo wp-shell backup remote DOMAIN crypt:PATH|off|status
  sudo wp-shell site DOMAIN maintenance on|off|status

Site actions: status, info, summary, core-verify, core-repair, cache-clear,
backup, backups, restore, update --confirm-updates, restart
All dashboard text and stored operational metadata are ASCII/English. Access metrics
exclude cookies and query strings. Verified client/edge IPs remain in rotated Nginx logs
for security auditing but are not copied into the metrics database. Raw metrics are retained for 30 days.
EOF
}

deploy_domain() {
    local selector="$1" domain index
    domain="$(site_domain_from_selector "$selector")" || die "Unknown site ID or domain: $selector"
    index="$(site_index_by_domain "$domain")" || die "Unmanaged site: $domain"
    prepare_stack
    deploy_site "$index"
    install_self
    install_metrics_timer
    show_site_deployment_summary "$index"
}

site_command() {
    local subcommand="${1:-list}"
    (($# == 0)) || shift
    case "$subcommand" in
        add) add_site_command ;;
        list) list_sites ;;
        status)
            if [[ -n "${1:-}" ]]; then
                site_action "$1" status
            else
                status_all_sites
            fi
            ;;
        deploy) [[ -n "${1:-}" ]] || die "Usage: wp-shell site deploy DOMAIN|ID"; deploy_domain "$1" ;;
        import) import_existing_sites; install_self ;;
        *) site_action "$subcommand" "$@" ;;
    esac
}

legacy_single_command() {
    local command="${1:-deploy}" domain="" record version legacy_domain _rest
    ((SITE_COUNT > 0)) || { new_server_wizard; return; }
    if [[ -r "$LEGACY_SINGLE_CONFIG_DIR/site.v2" ]]; then
        IFS='|' read -r record version legacy_domain _rest < "$LEGACY_SINGLE_CONFIG_DIR/site.v2"
        if [[ "$record" == "site" && "$version" == "2" ]] && site_index_by_domain "$legacy_domain" >/dev/null 2>&1; then
            domain="$legacy_domain"
        fi
    fi
    if [[ -z "$domain" && "$SITE_COUNT" -eq 1 ]]; then
        domain="${SITE_DOMAINS[1]}"
    fi
    [[ -n "$domain" ]] || die "The legacy single-site command is ambiguous; use 'wp-shell site DOMAIN|ID ACTION'."
    case "$command" in
        deploy|--reconfigure) deploy_domain "$domain" ;;
        manage) site_action "$domain" "${2:-status}" "${3:-}" ;;
        --version|-v) printf 'wp-shell %s\n' "$WP_SHELL_VERSION" ;;
        --help|-h) show_help ;;
        *) die "Unknown legacy single-site command: $command" ;;
    esac
}

execute_command() {
    local command="${1:-}"
    case "$command" in
        "") interactive_menu ;;
        install)
            install_or_repair_environment
            ;;
        dashboard) dashboard ;;
        audit) control_plane_audit ;;
        apply) apply_control_plane "${2:-}" ;;
        rollback) rollback_command "${2:-}" "${3:-}" ;;
        dry-run) dry_run_command "${2:-apply}" ;;
        report) metrics_report "${2:-24h}" ;;
        analyze) analyze_metrics "${2:-7d}" ;;
        tune) [[ "${2:-}" == "--apply" ]] || die "Usage: wp-shell tune --apply [--yes] [--range RANGE]"; shift 2; apply_tuning "$@" ;;
        opcache) shift; opcache_command "$@" ;;
        mariadb) shift; mariadb_command "$@" ;;
        site) shift; site_command "$@" ;;
        metrics)
            case "${2:-status}" in
                collect) collect_metrics ;;
                install) install_self; install_metrics_timer ;;
                status)
                    show_metrics_status
                    ;;
                *) die "Usage: wp-shell metrics collect|install|status" ;;
            esac
            ;;
        list) list_sites ;;
        status) control_plane_status ;;
        add-site) add_site_command ;;
        deploy) [[ -n "${2:-}" ]] || die "A site ID or domain is required."; deploy_domain "$2" ;;
        import) import_existing_sites; install_self ;;
        backup-all) backup_all_sites ;;
        backup) shift; backup_command "$@" ;;
        restore) [[ -n "${2:-}" && -n "${3:-}" ]] || die "Usage: restore DOMAIN|ID BACKUP_ID"; site_action "$2" restore "$3" ;;
        optimize) [[ "${2:-}" == --confirm ]] || die "'optimize' now applies the audited baseline. Review 'wp-shell dry-run apply', then use 'wp-shell optimize --confirm'."; apply_control_plane --confirm ;;
        rotate-redis-secret) rotate_redis_secret ;;
        cloudflare) shift; cloudflare_command "$@" ;;
        security-scan) security_scan ;;
        system) shift; system_command "$@" ;;
        cron-run) [[ -n "${2:-}" ]] || die "A managed domain is required."; run_site_cron "$2" ;;
        ops) [[ "${2:-}" == run ]] || die "Use ops run."; run_operations ;;
        install-backup-timer) install_self; install_backup_timer ;;
        migrate) log_message SUCCESS "Configuration is using the current v3 format." ;;
        legacy-vps) shift; execute_command "$@" ;;
        legacy-single) shift; legacy_single_command "$@" ;;
        *) die "Unknown command: $command. Use --help for usage." ;;
    esac
}

main() {
    if [[ "$(basename "$0")" == "wp-single-manager" ]]; then
        set -- legacy-single "$@"
    fi
    case "${1:-}" in
        --help|-h) show_help; return ;;
        --version|-v) printf 'wp-shell %s\n' "$WP_SHELL_VERSION"; return ;;
    esac

    ensure_root "$@"
    check_platform
    require_command base64
    case "${1:-}" in
        audit|status|dry-run)
            # These control-plane commands are contractually read-only.  In
            # particular, do not create state directories, migrate legacy
            # files, or synthesize an environment configuration here.
            load_sites_config
            load_environment_config
            load_tuning_config
            load_opcache_config
            execute_command "$@"
            ;;
        mariadb)
            if [[ "${2:-audit}" == audit ]]; then
                # MariaDB audit is contractually read-only and must not create
                # wp-shell state or migrate unrelated legacy configuration.
                load_sites_config
                load_environment_config
                load_tuning_config
                load_opcache_config
                execute_command "$@"
            else
                init_runtime
                TRANSACTION_CONTEXT=yes
                migrate_legacy_configs
                load_sites_config
                ensure_environment_config
                load_tuning_config
                load_opcache_config
                execute_command "$@"
                transaction_commit
            fi
            ;;
        dashboard|report|analyze|metrics|cron-run|ops)
            init_paths
            migrate_legacy_configs
            load_sites_config
            ensure_environment_config
            load_tuning_config
            load_opcache_config
            execute_command "$@"
            ;;
        *)
            init_runtime
            TRANSACTION_CONTEXT=yes
            migrate_legacy_configs
            load_sites_config
            ensure_environment_config
            load_tuning_config
            load_opcache_config
            execute_command "$@"
            transaction_commit
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
