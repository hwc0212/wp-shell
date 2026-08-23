#!/usr/bin/env bash

# wp-shell - WordPress VPS manager
# Version 9.4.0
# Supported systems: Ubuntu 22.04/24.04 LTS

set -Eeuo pipefail
umask 077

readonly WP_SHELL_VERSION="9.4.0"
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
readonly BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"

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
SITE_COUNT=0
LEGACY_SINGLE_DOMAIN=""
ENVIRONMENT_MODE=""
DEFAULT_PHP_VERSION="8.3"
ENVIRONMENT_UFW="no"
CURRENT_STEP="initialization"
MARIADB_BUFFER_MB=256
MARIADB_MAX_CONNECTIONS=50
MARIADB_TMP_TABLE_MB=32
REDIS_MAX_MEMORY_MB=64
PHP_TOTAL_BUDGET_MB=256

supports_color() {
    [[ -t 1 && "${NO_COLOR:-}" == "" ]]
}

color_for_level() {
    local level="$1"
    if ! supports_color; then
        printf ''
        return
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
    exit 1
}

on_error() {
    local exit_code=$?
    log_message ERROR "Step '$CURRENT_STEP' failed with exit code $exit_code. Log: $LOG_FILE"
    exit "$exit_code"
}
trap on_error ERR

ensure_root() {
    if [[ $EUID -eq 0 ]]; then
        return
    fi
    command -v sudo >/dev/null 2>&1 || die "Root privileges are required and sudo is not installed."
    exec sudo -E bash "$SCRIPT_PATH" "$@"
}

init_paths() {
    install -d -m 0700 "$CONFIG_DIR" "$DATABASE_CONFIG_DIR" "$STATE_DIR"
    install -d -m 0755 /var/www
    install -d -m 0750 "$LOG_DIR"
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
    if [[ $EUID -eq 0 ]]; then
        install -o root -g root -m 0600 "$temp_file" "$SITES_CONFIG_FILE"
    else
        install -m 0600 "$temp_file" "$SITES_CONFIG_FILE"
    fi
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
    if [[ $EUID -eq 0 ]]; then
        install -o root -g root -m 0600 "$source" "$target"
    else
        install -m 0600 "$source" "$target"
    fi
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
    local total_mem site_count os_reserve cache_reserve available
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
    cache_reserve=$((site_count * 16))
    available=$((total_mem - os_reserve - MARIADB_BUFFER_MB - REDIS_MAX_MEMORY_MB - cache_reserve))
    PHP_TOTAL_BUDGET_MB=$available
    ((PHP_TOTAL_BUDGET_MB < 192)) && PHP_TOTAL_BUDGET_MB=192
    if ((PHP_TOTAL_BUDGET_MB > total_mem * 35 / 100)); then
        PHP_TOTAL_BUDGET_MB=$((total_mem * 35 / 100))
    fi

    if ((total_mem < 2048)); then
        MARIADB_MAX_CONNECTIONS=30
        MARIADB_TMP_TABLE_MB=16
    elif ((total_mem < 4096)); then
        MARIADB_MAX_CONNECTIONS=60
        MARIADB_TMP_TABLE_MB=32
    elif ((total_mem < 8192)); then
        MARIADB_MAX_CONNECTIONS=120
        MARIADB_TMP_TABLE_MB=48
    else
        MARIADB_MAX_CONNECTIONS=200
        MARIADB_TMP_TABLE_MB=64
    fi

    calculate_site_php_allocations
    if [[ "${1:-}" != "quiet" ]]; then
        log_message INFO "Resource budget: OS reserve ${os_reserve}MB, MariaDB ${MARIADB_BUFFER_MB}MB, Redis ${REDIS_MAX_MEMORY_MB}MB, PHP-FPM ${PHP_TOTAL_BUDGET_MB}MB."
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
    local current_version="" temp_file download_url
    if command -v wp >/dev/null 2>&1; then
        current_version="$(wp --allow-root cli version 2>/dev/null | awk '{print $2}' || true)"
    fi
    [[ "$current_version" == "$WP_CLI_VERSION" ]] && return 0

    temp_file="$(mktemp /tmp/wp-cli.XXXXXX.phar)"
    download_url="https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar"
    curl --fail --location --retry 3 --proto '=https' --tlsv1.2 --output "$temp_file" "$download_url"
    php "$temp_file" --info >/dev/null
    install -o root -g root -m 0755 "$temp_file" /usr/local/bin/wp
    rm -f "$temp_file"
}

install_system_packages() {
    CURRENT_STEP="install system packages"
    apt-get update
    apt_install ca-certificates curl openssl unzip rsync dnsutils sudo python3 sqlite3 jq libfcgi-bin nginx mariadb-server mariadb-client redis-server certbot fail2ban ufw

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

configure_php() {
    CURRENT_STEP="configure PHP-FPM"
    calculate_resource_budget
    local version memory_limit i domain pool_id pool_file max_children
    memory_limit="256M"
    (( $(memory_mb) >= 4096 )) && memory_limit="512M"

    while IFS= read -r version; do
        [[ -n "$version" ]] || continue
        install -d -m 0755 "/etc/php/$version/fpm/pool.d" "/etc/php/$version/fpm/conf.d"
        cat > "/etc/php/$version/fpm/pool.d/99-wp-shell.conf" <<EOF
; Managed by wp-shell. Keep the distribution pool available with minimal idle use.
[www]
pm = ondemand
pm.max_children = 2
pm.process_idle_timeout = 20s
pm.max_requests = 500
EOF
        cat > "/etc/php/$version/fpm/conf.d/99-wp-shell.ini" <<EOF
; Managed by wp-shell.
memory_limit = $memory_limit
max_execution_time = 300
max_input_time = 300
upload_max_filesize = 128M
post_max_size = 128M
max_file_uploads = 30
display_errors = Off
log_errors = On
expose_php = Off
opcache.enable = 1
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 20000
opcache.validate_timestamps = 1
opcache.revalidate_freq = 2
opcache.jit = disable
opcache.jit_buffer_size = 0
EOF
    done < <(unique_php_versions)

    for ((i = 1; i <= SITE_COUNT; i++)); do
        domain="${SITE_DOMAINS[$i]}"
        version="${SITE_PHP_VERSIONS[$i]}"
        pool_id="$(site_pool_id "$domain")"
        pool_file="/etc/php/$version/fpm/pool.d/wp-shell-${pool_id}.conf"
        max_children="${SITE_PHP_MAX_CHILDREN[$i]}"
        install -d -o www-data -g www-data -m 0750 "/var/www/$domain/logs"
        cat > "$pool_file" <<EOF
; Managed by wp-shell for $domain.
[$pool_id]
user = www-data
group = www-data
listen = $(site_pool_socket "$domain")
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = $max_children
pm.process_idle_timeout = 20s
pm.max_requests = 500
pm.status_path = /status
pm.status_listen = $(site_pool_status_socket "$domain")
ping.path = /ping
request_terminate_timeout = 300s
request_slowlog_timeout = 5s
slowlog = /var/www/$domain/logs/php-fpm-slow.log
catch_workers_output = yes
php_admin_flag[log_errors] = on
php_admin_value[error_log] = /var/www/$domain/logs/php-error.log
EOF
    done

    while IFS= read -r version; do
        [[ -n "$version" ]] || continue
        "php-fpm${version}" -t
        systemctl enable "php${version}-fpm"
        systemctl restart "php${version}-fpm"
    done < <(unique_php_versions)
    if ((SITE_COUNT > 0)); then
        log_message SUCCESS "Configured one PHP-FPM pool per site within a shared ${PHP_TOTAL_BUDGET_MB}MB budget."
    else
        log_message SUCCESS "Configured PHP ${DEFAULT_PHP_VERSION}-FPM. Site pools will be created when websites are added."
    fi
}

configure_mariadb() {
    CURRENT_STEP="configure MariaDB"
    calculate_resource_budget
    local config_file backup_file temp_file
    config_file="/etc/mysql/mariadb.conf.d/60-wp-shell.cnf"
    backup_file="$config_file.previous"
    temp_file="$(mktemp /etc/mysql/mariadb.conf.d/.wp-shell.XXXXXX)"
    cat > "$temp_file" <<EOF
[mysqld]
innodb_buffer_pool_size = ${MARIADB_BUFFER_MB}M
max_connections = ${MARIADB_MAX_CONNECTIONS}
tmp_table_size = ${MARIADB_TMP_TABLE_MB}M
max_heap_table_size = ${MARIADB_TMP_TABLE_MB}M
thread_cache_size = 32
table_open_cache = 2048
innodb_file_per_table = 1
innodb_flush_method = O_DIRECT
innodb_flush_log_at_trx_commit = 1
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
slow_query_log = 1
slow_query_log_file = /var/log/mysql/wp-shell-slow.log
long_query_time = 2
EOF
    [[ -f "$config_file" ]] && cp -a "$config_file" "$backup_file"
    install -o root -g root -m 0644 "$temp_file" "$config_file"
    rm -f "$temp_file"
    if ! systemctl restart mariadb; then
        if [[ -f "$backup_file" ]]; then
            mv -f "$backup_file" "$config_file"
        else
            rm -f "$config_file"
        fi
        systemctl restart mariadb || true
        die "MariaDB could not start with the new configuration; the previous configuration was restored."
    fi
    rm -f "$backup_file"
    systemctl enable mariadb
}

load_or_create_redis_secret() {
    if [[ ! -s "$REDIS_SECRET_FILE" ]]; then
        generate_password > "$REDIS_SECRET_FILE"
        chmod 0600 "$REDIS_SECRET_FILE"
    fi
    REDIS_PASSWORD="$(<"$REDIS_SECRET_FILE")"
    [[ "$REDIS_PASSWORD" =~ ^[a-f0-9]{48}$ ]] || die "The Redis secret file has an invalid format."
}

configure_redis() {
    CURRENT_STEP="configure Redis"
    calculate_resource_budget
    load_or_create_redis_secret
    local config_file override_dir override_file previous_config="" previous_override=""
    config_file="/etc/redis/wp-shell.conf"
    override_dir="/etc/systemd/system/redis-server.service.d"
    override_file="$override_dir/wp-shell.conf"
    [[ -f "$config_file" ]] && previous_config="$(mktemp /tmp/redis-config.XXXXXX)" && cp -a "$config_file" "$previous_config"
    [[ -f "$override_file" ]] && previous_override="$(mktemp /tmp/redis-override.XXXXXX)" && cp -a "$override_file" "$previous_override"
    cat > "$config_file" <<EOF
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
maxmemory ${REDIS_MAX_MEMORY_MB}mb
maxmemory-policy allkeys-lru
save ""
appendonly no
EOF
    chown root:redis "$config_file"
    chmod 0640 "$config_file"
    install -d -m 0755 "$override_dir"
    cat > "$override_file" <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/redis-server $config_file --supervised systemd --daemonize no
EOF
    systemctl daemon-reload
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

configure_fail2ban() {
    CURRENT_STEP="configure Fail2ban"
    install -d -m 0755 /etc/fail2ban/jail.d
    cat > /etc/fail2ban/jail.d/wp-shell.local <<'EOF'
[sshd]
enabled = true
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h

[nginx-http-auth]
enabled = true
maxretry = 5
findtime = 10m
bantime = 1h
EOF
    fail2ban-client -t
    systemctl enable fail2ban
    systemctl restart fail2ban
}

configure_log_rotation() {
    cat > /etc/logrotate.d/wp-shell-sites <<'EOF'
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
}

detect_ssh_port() {
    local port=""
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        port="${SSH_CONNECTION##* }"
    fi
    if [[ ! "$port" =~ ^[0-9]+$ ]] && command -v sshd >/dev/null 2>&1; then
        port="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}')"
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
    ufw allow "${ssh_port}/tcp" comment 'SSH managed by wp-shell'
    ufw allow 80/tcp comment 'HTTP managed by wp-shell'
    ufw allow 443/tcp comment 'HTTPS managed by wp-shell'
    ufw --force enable
    log_message SUCCESS "UFW allows SSH on port $ssh_port plus HTTP and HTTPS; existing rules were preserved."
}

install_certbot_deploy_hook() {
    install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
nginx -t
systemctl reload nginx
EOF
    chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx
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
    if [[ $EUID -eq 0 ]]; then
        install -o root -g root -m 0600 "$temp_file" "$path"
    else
        install -m 0600 "$temp_file" "$path"
    fi
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
    install -d -m 0755 /etc/nginx/conf.d
    cat > /etc/nginx/conf.d/wp-shell-log-format.conf <<'EOF'
# Managed by wp-shell. It intentionally excludes client IPs, cookies, and query strings.
log_format wp_shell escape=json '{"ts":"$time_iso8601","status":$status,"bytes":$body_bytes_sent,"request_time":$request_time,"upstream_time":"$upstream_response_time","cache":"$upstream_cache_status","method":"$request_method","uri":"$uri"}';
EOF
}

install_nginx_files() {
    local domain="$1" site_temp="$2" cache_temp="${3:-}"
    local site_target cache_target site_backup="" cache_backup=""
    site_target="/etc/nginx/sites-available/$domain"
    cache_target="/etc/nginx/conf.d/wp-cache-$domain.conf"
    [[ -f "$site_target" ]] && site_backup="$(mktemp /tmp/nginx-site.XXXXXX)" && cp -a "$site_target" "$site_backup"
    [[ -f "$cache_target" ]] && cache_backup="$(mktemp /tmp/nginx-cache.XXXXXX)" && cp -a "$cache_target" "$cache_backup"
    install -o root -g root -m 0644 "$site_temp" "$site_target"
    if [[ -n "$cache_temp" ]]; then
        install -o root -g root -m 0644 "$cache_temp" "$cache_target"
    else
        rm -f "$cache_target"
    fi
    ln -sfn "$site_target" "/etc/nginx/sites-enabled/$domain"
    if ! nginx -t; then
        if [[ -n "$site_backup" ]]; then cp -a "$site_backup" "$site_target"; else rm -f "$site_target" "/etc/nginx/sites-enabled/$domain"; fi
        if [[ -n "$cache_backup" ]]; then cp -a "$cache_backup" "$cache_target"; else rm -f "$cache_target"; fi
        nginx -t || true
        rm -f "$site_backup" "$cache_backup"
        die "Nginx configuration validation failed; $domain was rolled back."
    fi
    rm -f "$site_backup" "$cache_backup"
    systemctl enable nginx
    systemctl reload nginx
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
    domain="${SITE_DOMAINS[$index]}"
    primary="${SITE_PRIMARY_DOMAINS[$index]}"
    wp_path="${SITE_PATHS[$index]}"
    pool_socket="$(site_pool_socket "$domain")"
    server_names="$(site_server_names "$index")"
    zone="$(nginx_zone_name "$domain")"
    site_temp="$(mktemp /tmp/nginx-site.XXXXXX)"
    cache_temp="$(mktemp /tmp/nginx-cache.XXXXXX)"
    cat > "$cache_temp" <<EOF
fastcgi_cache_path $(site_cache_dir "$domain") levels=1:2 keys_zone=${zone}:16m inactive=60m max_size=512m use_temp_path=off;
EOF
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

    add_header Strict-Transport-Security "max-age=15552000" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    if (\$host != $primary) { return 301 https://$primary\$request_uri; }

    client_max_body_size 128M;
    access_log /var/www/$domain/logs/nginx-access.log wp_shell;
    error_log /var/www/$domain/logs/nginx-error.log warn;

    set \$skip_cache 0;
    if (\$request_method = POST) { set \$skip_cache 1; }
    if (\$query_string != "") { set \$skip_cache 1; }
    if (\$request_uri ~* "^/(wp-admin|wp-login.php|wp-cron.php|xmlrpc.php|cart|checkout|my-account|wc-api|feed|sitemap)") { set \$skip_cache 1; }
    if (\$http_cookie ~* "wordpress_logged_in|comment_author|wp-postpass|woocommerce_items_in_cart|woocommerce_cart_hash|wp_woocommerce_session_") { set \$skip_cache 1; }

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~* /(?:uploads|files)/.*\.php$ {
        deny all;
    }

    location ~* ^/(?:wp-config\.php|readme\.html|license\.txt)$ {
        deny all;
    }

    location ~ /\. {
        deny all;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$pool_socket;
        fastcgi_cache $zone;
        fastcgi_cache_key "\$scheme\$request_method\$host\$request_uri";
        fastcgi_cache_methods GET HEAD;
        fastcgi_cache_valid 200 301 302 30m;
        fastcgi_cache_use_stale error timeout updating http_500 http_503;
        fastcgi_cache_background_update on;
        fastcgi_cache_lock on;
        fastcgi_cache_bypass \$skip_cache;
        fastcgi_no_cache \$skip_cache;
        add_header Strict-Transport-Security "max-age=15552000" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        add_header X-FastCGI-Cache \$upstream_cache_status;
    }

    location ~* \.(?:css|js|jpg|jpeg|gif|png|ico|webp|avif|svg|woff2?|ttf)$ {
        expires 30d;
        add_header Strict-Transport-Security "max-age=15552000" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        add_header Cache-Control "public, max-age=2592000, immutable";
        access_log off;
        try_files \$uri =404;
    }
}
EOF
    install -d -o www-data -g www-data -m 0750 "$(site_cache_dir "$domain")"
    install_nginx_log_format
    install_nginx_files "$domain" "$site_temp" "$cache_temp"
    rm -f "$site_temp" "$cache_temp"
}

create_site_directories() {
    local domain="$1" wp_path="$2"
    install -d -o root -g root -m 0755 "/var/www/$domain"
    install -d -o www-data -g www-data -m 0755 "$wp_path"
    install -d -o www-data -g www-data -m 0750 "/var/www/$domain/logs"
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
    local domain="$1" cache_dir backup_dir wp_cli_home
    cache_dir="$(site_cache_dir "$domain")"
    backup_dir="$(site_backup_dir "$domain")"
    wp_cli_home="$(site_wp_cli_home "$domain")"
    install -d -o www-data -g www-data -m 0750 "$cache_dir"
    install -d -o www-data -g www-data -m 0750 "$wp_cli_home" "$wp_cli_home/cache"
    install -d -o root -g root -m 0700 "$backup_dir"
    migrate_legacy_backups "$LEGACY_BACKUP_ROOT/$domain" "$backup_dir"
    migrate_legacy_backups "$LEGACY_SINGLE_BACKUP_ROOT/$domain" "$backup_dir"
}

site_wp_cli() {
    local domain="$1" index wp_path site_home wp_cli_home
    shift
    index="$(site_index_by_domain "$domain")" || die "Unmanaged site: $domain"
    wp_path="${SITE_PATHS[$index]}"
    site_home="/var/www/$domain"
    wp_cli_home="$(site_wp_cli_home "$domain")"
    install -d -o www-data -g www-data -m 0750 "$wp_cli_home" "$wp_cli_home/cache"
    (
        cd "$wp_path"
        sudo -u www-data env \
            HOME="$site_home" \
            WP_CLI_CACHE_DIR="$wp_cli_home/cache" \
            wp --path="$wp_path" "$@"
    )
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

site_credentials_file() {
    printf '/root/wordpress-credentials-%s.txt' "$1"
}

set_site_permissions() {
    local domain="$1" wp_path site_root
    wp_path="$(site_wp_path "$domain")"
    site_root="/var/www/$domain"
    find "$wp_path" -xdev \
        \( -path "$site_root/backups" -o -path "$site_root/cache" -o \
           -path "$site_root/logs" -o -path "$site_root/.wp-cli" \) -prune -o \
        -exec chown -h www-data:www-data {} +
    find "$wp_path" -xdev \
        \( -path "$site_root/backups" -o -path "$site_root/cache" -o \
           -path "$site_root/logs" -o -path "$site_root/.wp-cli" \) -prune -o \
        -type d -exec chmod 0755 {} +
    find "$wp_path" -xdev \
        \( -path "$site_root/backups" -o -path "$site_root/cache" -o \
           -path "$site_root/logs" -o -path "$site_root/.wp-cli" \) -prune -o \
        -type f -exec chmod 0644 {} +
    [[ -f "$wp_path/wp-config.php" ]] && chmod 0640 "$wp_path/wp-config.php"
    chown -R www-data:www-data "$site_root/logs"
    chmod 0750 "/var/www/$domain/logs"
    ensure_site_storage "$domain"
    chown -R root:root "$(site_backup_dir "$domain")"
}

install_wordpress_site() {
    CURRENT_STEP="install WordPress"
    local index="$1" domain primary wp_path admin_password credentials_file redis_password memory_limit initial_mode
    domain="${SITE_DOMAINS[$index]}"
    primary="${SITE_PRIMARY_DOMAINS[$index]}"
    wp_path="${SITE_PATHS[$index]}"
    initial_mode="${SITE_MODES[$index]}"
    load_or_create_redis_secret
    redis_password="$REDIS_PASSWORD"

    if [[ ! -f "$wp_path/wp-load.php" ]]; then
        site_wp_cli "$domain" core download --locale="$WORDPRESS_LOCALE"
    fi
    if [[ ! -f "$wp_path/wp-config.php" ]]; then
        load_database_config "$domain"
        site_wp_cli_prompt_secret "$domain" "$DB_PASSWORD" config create \
            --dbname="$DB_NAME" --dbuser="$DB_USER" \
            --dbhost=localhost --dbprefix=wp_ --dbcharset=utf8mb4 --prompt=dbpass
    fi

    site_wp_cli "$domain" config set FORCE_SSL_ADMIN true --raw
    site_wp_cli "$domain" config set DISALLOW_FILE_EDIT true --raw
    site_wp_cli "$domain" config set WP_CACHE true --raw
    site_wp_cli "$domain" config set WP_REDIS_HOST 127.0.0.1
    site_wp_cli "$domain" config set WP_REDIS_PORT 6379 --raw
    site_wp_cli "$domain" config set WP_REDIS_PASSWORD "$redis_password"
    site_wp_cli "$domain" config set WP_REDIS_DATABASE "${SITE_REDIS_DATABASES[$index]}" --raw
    site_wp_cli "$domain" config set WP_REDIS_PREFIX "${domain}:"
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
    fi

    if [[ "$initial_mode" == "managed" ]]; then
        site_wp_cli "$domain" rewrite structure '/%postname%/'
    fi
    site_wp_cli "$domain" plugin install redis-cache --activate
    site_wp_cli "$domain" redis enable
    if [[ "${SITE_WOOCOMMERCE[$index]}" == "yes" ]]; then
        site_wp_cli "$domain" plugin install woocommerce --activate
    fi
    if [[ "$initial_mode" == "managed" ]]; then
        site_wp_cli "$domain" plugin delete hello akismet 2>/dev/null || true
    fi
    set_site_permissions "$domain"
}

install_self() {
    if [[ "$SCRIPT_PATH" != "$MANAGED_SCRIPT" ]] && ! cmp -s "$SCRIPT_PATH" "$MANAGED_SCRIPT" 2>/dev/null; then
        install -o root -g root -m 0755 "$SCRIPT_PATH" "$MANAGED_SCRIPT"
    fi
    ln -sfn "$MANAGED_SCRIPT" /usr/local/bin/wp-shell
    ln -sfn "$MANAGED_SCRIPT" /usr/local/bin/wp-vps-manager
    ln -sfn "$MANAGED_SCRIPT" /usr/local/sbin/wp-vps-manager
    ln -sfn "$MANAGED_SCRIPT" /usr/local/sbin/wp-single-manager
    local i legacy_wrapper
    for ((i = 1; i <= SITE_COUNT; i++)); do
        legacy_wrapper="/usr/local/bin/manage-${SITE_DOMAINS[$i]}"
        if [[ -f "$legacy_wrapper" || -L "$legacy_wrapper" ]]; then
            rm -f -- "$legacy_wrapper"
            log_message INFO "Removed legacy site shortcut: $legacy_wrapper"
        fi
    done
}

deploy_site() {
    local index="$1" domain initial_mode
    domain="${SITE_DOMAINS[$index]}"
    initial_mode="${SITE_MODES[$index]}"
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
    if [[ "$initial_mode" == "imported" ]]; then
        set_site_permissions "$domain"
    fi
    install_wordpress_site "$index"
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
    rm -f /etc/nginx/sites-enabled/default
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
    printf '  Redis: %s\n' "$(systemctl is-active redis-server 2>/dev/null || true)"
}

site_tls_expiry() {
    local domain="$1" certificate end_date
    certificate="/etc/letsencrypt/live/$domain/fullchain.pem"
    [[ -s "$certificate" ]] || { printf 'missing'; return; }
    end_date="$(openssl x509 -in "$certificate" -noout -enddate 2>/dev/null | cut -d= -f2- || true)"
    [[ -n "$end_date" ]] || { printf 'unknown'; return; }
    date --utc --date="$end_date" +%F 2>/dev/null || printf 'unknown'
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
    printf 'Redis cache    enabled (DB %s)\n' "${SITE_REDIS_DATABASES[$index]}"
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
}

create_mysql_defaults_file() {
    local domain="$1" defaults_file db_user db_password db_host escaped_password
    defaults_file="$(mktemp /run/wp-vps-mysql.XXXXXX)"
    db_user="$(site_wp_cli "$domain" config get DB_USER)"
    db_password="$(site_wp_cli "$domain" config get DB_PASSWORD)"
    db_host="$(site_wp_cli "$domain" config get DB_HOST)"
    escaped_password="${db_password//\\/\\\\}"
    escaped_password="${escaped_password//\"/\\\"}"
    {
        printf '[client]\n'
        printf 'user=%s\n' "$db_user"
        printf 'password="%s"\n' "$escaped_password"
        printf 'host=%s\n' "$db_host"
    } > "$defaults_file"
    chmod 0600 "$defaults_file"
    printf '%s' "$defaults_file"
}

backup_site() {
    CURRENT_STEP="back up the site"
    local index="$1" domain wp_path timestamp site_backup_root temp_dir final_dir defaults_file db_name
    domain="${SITE_DOMAINS[$index]}"
    wp_path="$(site_wp_path "$domain")"
    [[ -f "$wp_path/wp-config.php" ]] || die "WordPress is not installed for $domain."
    timestamp="$(date +%Y%m%d-%H%M%S)"
    ensure_site_storage "$domain"
    site_backup_root="$(site_backup_dir "$domain")"
    temp_dir="$(mktemp -d "$site_backup_root/.incomplete.XXXXXX")"
    final_dir="$site_backup_root/$timestamp"
    defaults_file="$(create_mysql_defaults_file "$domain")"
    db_name="$(site_wp_cli "$domain" config get DB_NAME)"

    if ! tar --exclude='./wp-content/cache/*' --exclude='./wp-content/uploads/cache/*' -czf "$temp_dir/files.tar.gz" -C "$wp_path" .; then
        rm -rf -- "$temp_dir"
        rm -f "$defaults_file"
        die "File backup failed for $domain."
    fi
    if ! mariadb-dump --defaults-extra-file="$defaults_file" --single-transaction --quick --routines --triggers --add-drop-table "$db_name" | gzip -9 > "$temp_dir/database.sql.gz"; then
        rm -rf -- "$temp_dir"
        rm -f "$defaults_file"
        die "Database backup failed for $domain."
    fi
    rm -f "$defaults_file"
    {
        printf 'domain=%s\n' "$domain"
        printf 'created_at=%s\n' "$(date --iso-8601=seconds)"
        printf 'wordpress_version=%s\n' "$(site_wp_cli "$domain" core version)"
    } > "$temp_dir/manifest.txt"
    (cd "$temp_dir" && sha256sum files.tar.gz database.sql.gz manifest.txt > SHA256SUMS)
    mv "$temp_dir" "$final_dir"
    find "$site_backup_root" -mindepth 1 -maxdepth 1 -type d -name '20??????-??????' -mtime "+$BACKUP_RETENTION_DAYS" -exec rm -rf -- {} +
    log_message SUCCESS "Backup completed: $final_dir"
    printf '%s\n' "$final_dir"
}

restore_site() {
    CURRENT_STEP="restore the site"
    local index="$1" backup_id="$2" domain wp_path backup_dir defaults_file db_name
    domain="${SITE_DOMAINS[$index]}"
    wp_path="$(site_wp_path "$domain")"
    [[ "$backup_id" =~ ^20[0-9]{6}-[0-9]{6}$ ]] || die "Invalid backup ID format."
    ensure_site_storage "$domain"
    backup_dir="$(site_backup_dir "$domain")/$backup_id"
    [[ -d "$backup_dir" ]] || die "Backup not found: $backup_dir"
    (cd "$backup_dir" && sha256sum --check SHA256SUMS)
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
            site_wp_cli "$domain" maintenance-mode deactivate >/dev/null 2>&1 || true
        }
        trap cleanup_restore EXIT
        tar -xzf "$backup_dir/files.tar.gz" -C "$local_stage"
        [[ -f "$local_stage/wp-config.php" ]]
        site_wp_cli "$domain" maintenance-mode activate >/dev/null 2>&1 || true
        rsync -a --delete "$local_stage/" "$wp_path/"
        gzip -dc "$backup_dir/database.sql.gz" | mariadb --defaults-extra-file="$defaults_file" "$db_name"
        set_site_permissions "$domain"
    )
    clear_site_cache "$index"
    log_message SUCCESS "$domain was restored to $backup_id."
}

clear_site_cache() {
    local index="$1" domain wp_path cache_dir legacy_cache_dir
    domain="${SITE_DOMAINS[$index]}"
    wp_path="$(site_wp_path "$domain")"
    cache_dir="$(site_cache_dir "$domain")"
    legacy_cache_dir="$LEGACY_CACHE_ROOT/$domain"
    [[ -d "$cache_dir" ]] && find "$cache_dir" -mindepth 1 -delete
    [[ -d "$legacy_cache_dir" ]] && find "$legacy_cache_dir" -mindepth 1 -delete
    if [[ -f "$wp_path/wp-config.php" ]]; then
        site_wp_cli "$domain" cache flush || true
    fi
    systemctl reload "php${SITE_PHP_VERSIONS[$index]}-fpm"
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

site_action() {
    local domain="$1" action="${2:-status}" index wp_path
    index="$(site_index_by_domain "$domain")" || die "Unmanaged site: $domain"
    wp_path="$(site_wp_path "$domain")"
    case "$action" in
        status) site_status "$index" ;;
        info)
            site_status "$index"
            [[ -f "$wp_path/wp-config.php" ]] && printf '  WordPress: %s\n' "$(site_wp_cli "$domain" core version)"
            ;;
        summary) show_site_deployment_summary "$index" ;;
        cache-clear) clear_site_cache "$index"; log_message SUCCESS "$domain cache was cleared." ;;
        backup) backup_site "$index" ;;
        backups) list_backups "$index" ;;
        restore) [[ -n "${3:-}" ]] || die "Usage: wp-shell restore $domain BACKUP_ID"; restore_site "$index" "$3" ;;
        update) update_site "$index" ;;
        restart)
            systemctl restart "php${SITE_PHP_VERSIONS[$index]}-fpm"
            nginx -t && systemctl reload nginx
            ;;
        *) die "Unknown site action: $action (use status, info, summary, cache-clear, backup, backups, restore, update, or restart)." ;;
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
    backups_mb REAL NOT NULL DEFAULT 0
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
SQL
    chmod 0600 "$METRICS_DB"
}

numeric_or_zero() {
    [[ "${1:-}" =~ ^-?[0-9]+([.][0-9]+)?$ ]] && printf '%s' "$1" || printf '0'
}

collect_cpu_percent() {
    local _cpu user nice system idle iowait irq softirq steal _guest _guest_nice total idle_total
    read -r _cpu user nice system idle iowait irq softirq steal _guest _guest_nice < /proc/stat
    total=$((user + nice + system + idle + iowait + irq + softirq + steal))
    idle_total=$((idle + iowait))
    local state_file="$STATE_DIR/cpu.state" previous_total="$total" previous_idle="$idle_total"
    if [[ -r "$state_file" ]]; then
        read -r previous_total previous_idle < "$state_file" || true
    fi
    printf '%s %s\n' "$total" "$idle_total" > "$state_file"
    awk -v t="$total" -v i="$idle_total" -v pt="$previous_total" -v pi="$previous_idle" \
        'BEGIN { dt=t-pt; di=i-pi; if (dt<=0) print "0.0"; else printf "%.1f", 100*(dt-di)/dt }'
}

network_bytes() {
    awk -F'[: ]+' 'NR>2 && $2 != "lo" {rx+=$3; tx+=$11} END {printf "%d %d", rx, tx}' /proc/net/dev
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
    sqlite3 "$METRICS_DB" "INSERT INTO system_samples VALUES($ts,$cpu,$load1,$mem_total,$mem_available,$swap_used,$disk_pct,$rx,$tx);"
}

collect_nginx_interval() {
    local domain="$1" log_file="/var/www/$1/logs/nginx-access.log" hash offset_file offset=0 size=0 start temp stats
    hash="$(printf '%s' "$domain" | sha256sum | cut -c1-12)"
    offset_file="$STATE_DIR/nginx-$hash.offset"
    [[ -f "$log_file" ]] || { printf '0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0'; return; }
    size="$(stat -c '%s' "$log_file" 2>/dev/null || printf '0')"
    if [[ -r "$offset_file" ]]; then
        read -r offset < "$offset_file" || true
    fi
    [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
    ((size < offset)) && offset=0
    if ((offset == 0 && size > 5242880)); then
        offset=$((size - 5242880))
    fi
    start=$((offset + 1))
    temp="$(mktemp /tmp/wp-shell-nginx.XXXXXX)"
    tail -c "+$start" "$log_file" > "$temp" 2>/dev/null || true
    printf '%s\n' "$size" > "$offset_file"
    stats="$(jq -Rsr '
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
      end | @tsv' "$temp" 2>/dev/null || printf '0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0')"
    rm -f "$temp"
    printf '%s' "$stats"
}

collect_php_pool_status() {
    local domain="$1" socket json pool_id rss
    socket="$(site_pool_status_socket "$domain")"
    pool_id="$(site_pool_id "$domain")"
    json=""
    if [[ -S "$socket" && -x "$(command -v cgi-fcgi 2>/dev/null || true)" ]]; then
        json="$(SCRIPT_NAME=/status SCRIPT_FILENAME=/status REQUEST_METHOD=GET QUERY_STRING=json \
            cgi-fcgi -bind -connect "$socket" 2>/dev/null | sed -n '/^{/,$p' | tr -d '\r' || true)"
    fi
    rss="$(ps -eo rss=,args= 2>/dev/null | awk -v needle="php-fpm: pool $pool_id" 'index($0,needle){sum+=$1} END{printf "%.1f",sum/1024}')"
    if jq -e . >/dev/null 2>&1 <<< "$json"; then
        jq -r --arg rss "$rss" '[.["active processes"]//0, .["idle processes"]//0, .["listen queue"]//0, .["max active processes"]//0, .["max children reached"]//0, ($rss|tonumber)] | @tsv' <<< "$json"
    else
        printf '0\t0\t0\t0\t0\t%s' "${rss:-0}"
    fi
}

directory_size_mb() {
    [[ -e "$1" ]] && du -sm -- "$1" 2>/dev/null | awk '{print $1}' || printf '0'
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
    latest="$(find "$directory" -mindepth 1 -maxdepth 1 -type d -name '20??????-??????' -printf '%T@\n' 2>/dev/null | sort -nr | head -n1 | cut -d. -f1)"
    [[ "$latest" =~ ^[0-9]+$ ]] || { printf '%s' '-1'; return; }
    now="$(date +%s)"
    awk -v n="$now" -v t="$latest" 'BEGIN{printf "%.1f",(n-t)/3600}'
}

collect_site_sample() {
    local ts="$1" index="$2" domain primary wp_path log_stats php_stats
    local requests s2 s4 s5 bytes avg p95 hits misses bypass stale active idle queue _max_active reached rss
    local http_code tls_days backup_age files_mb cache_mb logs_mb backups_mb
    domain="${SITE_DOMAINS[$index]}"
    primary="${SITE_PRIMARY_DOMAINS[$index]}"
    wp_path="${SITE_PATHS[$index]}"
    log_stats="$(collect_nginx_interval "$domain")"
    read -r requests s2 s4 s5 bytes avg p95 hits misses bypass stale <<< "${log_stats//$'\t'/ }"
    php_stats="$(collect_php_pool_status "$domain")"
    read -r active idle queue _max_active reached rss <<< "${php_stats//$'\t'/ }"
    http_code="$(curl --silent --output /dev/null --max-time 5 --write-out '%{http_code}' "https://$primary" 2>/dev/null || printf '0')"
    [[ "$http_code" =~ ^[0-9]{3}$ ]] || http_code=0
    tls_days="$(tls_days_remaining "$domain")"
    backup_age="$(backup_age_hours "$(site_backup_dir "$domain")")"
    files_mb="$(directory_size_mb "$wp_path")"
    cache_mb="$(directory_size_mb "$(site_cache_dir "$domain")")"
    logs_mb="$(directory_size_mb "/var/www/$domain/logs")"
    backups_mb="$(directory_size_mb "$(site_backup_dir "$domain")")"
    sqlite3 "$METRICS_DB" "INSERT INTO site_samples VALUES($ts,'$domain',$(numeric_or_zero "$requests"),$(numeric_or_zero "$s2"),$(numeric_or_zero "$s4"),$(numeric_or_zero "$s5"),$(numeric_or_zero "$bytes"),$(numeric_or_zero "$avg"),$(numeric_or_zero "$p95"),$(numeric_or_zero "$hits"),$(numeric_or_zero "$misses"),$(( $(numeric_or_zero "$bypass") + $(numeric_or_zero "$stale") )),$(numeric_or_zero "$active"),$(numeric_or_zero "$idle"),$(numeric_or_zero "$queue"),${SITE_PHP_MAX_CHILDREN[$index]:-0},$(numeric_or_zero "$reached"),$(numeric_or_zero "$rss"),$http_code,$tls_days,$backup_age,$files_mb,$cache_mb,$logs_mb,$backups_mb);"
}

collect_service_sample() {
    local ts="$1" mariadb_values threads=0 questions=0 slow=0 redis_info="" redis_used=0 hits=0 misses=0 evicted=0 key value
    mariadb_values="$(mariadb --batch --skip-column-names -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected','Questions','Slow_queries');" 2>/dev/null || true)"
    while read -r key value; do
        case "$key" in
            Threads_connected) threads="$value" ;;
            Questions) questions="$value" ;;
            Slow_queries) slow="$value" ;;
        esac
    done <<< "$mariadb_values"
    if [[ -s "$REDIS_SECRET_FILE" ]]; then
        redis_info="$(redis-cli --no-auth-warning -a "$(<"$REDIS_SECRET_FILE")" INFO stats memory 2>/dev/null | tr -d '\r' || true)"
        redis_used="$(awk -F: '$1=="used_memory"{printf "%.1f",$2/1048576}' <<< "$redis_info")"
        hits="$(awk -F: '$1=="keyspace_hits"{print $2}' <<< "$redis_info")"
        misses="$(awk -F: '$1=="keyspace_misses"{print $2}' <<< "$redis_info")"
        evicted="$(awk -F: '$1=="evicted_keys"{print $2}' <<< "$redis_info")"
    fi
    sqlite3 "$METRICS_DB" "INSERT INTO service_samples VALUES($ts,$(numeric_or_zero "$threads"),$(numeric_or_zero "$questions"),$(numeric_or_zero "$slow"),$(numeric_or_zero "$redis_used"),$(numeric_or_zero "$hits"),$(numeric_or_zero "$misses"),$(numeric_or_zero "$evicted"));"
}

collect_metrics() {
    exec 8>"$STATE_DIR/collector.lock"
    flock -n 8 || return 0
    init_metrics_database
    calculate_resource_budget quiet
    local ts i
    ts="$(date +%s)"
    collect_system_sample "$ts"
    collect_service_sample "$ts"
    for ((i = 1; i <= SITE_COUNT; i++)); do
        collect_site_sample "$ts" "$i"
    done
    sqlite3 "$METRICS_DB" "DELETE FROM system_samples WHERE ts < $((ts - 2592000)); DELETE FROM site_samples WHERE ts < $((ts - 2592000)); DELETE FROM service_samples WHERE ts < $((ts - 2592000)); PRAGMA wal_checkpoint(PASSIVE);"
}

install_metrics_timer() {
    CURRENT_STEP="install the metrics collector"
    init_metrics_database
    cat > /etc/systemd/system/wp-shell-metrics.service <<EOF
[Unit]
Description=Collect local wp-shell metrics
After=nginx.service mariadb.service redis-server.service

[Service]
Type=oneshot
ExecStart=$MANAGED_SCRIPT metrics collect
Nice=10
IOSchedulingClass=idle
ProtectHome=true
PrivateTmp=true
EOF
    cat > /etc/systemd/system/wp-shell-metrics.timer <<'EOF'
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
    sqlite3 -header -column "$METRICS_DB" "SELECT domain AS Domain, SUM(requests) AS Requests, SUM(status_4xx) AS '4xx', SUM(status_5xx) AS '5xx', printf('%.0f',MAX(p95_ms)) AS 'P95 ms', CASE WHEN SUM(cache_hits+cache_misses)>0 THEN printf('%.0f%%',100.0*SUM(cache_hits)/SUM(cache_hits+cache_misses)) ELSE '-' END AS 'Cache hit', printf('%.0f',MAX(php_rss_mb)) AS 'PHP MB', MAX(php_queue) AS Queue, MAX(http_code) AS HTTP, MIN(tls_days) AS 'TLS days', CASE WHEN MIN(backup_age_hours)<0 THEN '-' ELSE printf('%.1fh',MIN(backup_age_hours)) END AS Backup FROM site_samples WHERE ts >= $since GROUP BY domain ORDER BY SUM(requests) DESC;"
}

dashboard() {
    [[ -t 0 && -t 1 ]] || die "The dashboard requires an interactive terminal. Use 'wp-shell report' for plain output."
    [[ -s "$METRICS_DB" ]] || die "No metrics are available yet. Run: sudo wp-shell metrics collect"
    python3 /dev/fd/3 "$METRICS_DB" "$SITES_CONFIG_FILE" 3<<'PY'
import curses
import datetime
import sqlite3
import sys
import time

DB = sys.argv[1]
CONFIG = sys.argv[2]
VIEWS = ["Overview", "Traffic", "Resources", "Operations", "Alerts"]


def clamp(value, low=0.0, high=100.0):
    return max(low, min(high, float(value or 0)))


def human_bytes(value):
    value = float(value or 0)
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


def fetch_data():
    connection = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=2)
    connection.row_factory = sqlite3.Row
    now = int(time.time())
    system = connection.execute("SELECT * FROM system_samples ORDER BY ts DESC LIMIT 1").fetchone()
    service = connection.execute("SELECT * FROM service_samples ORDER BY ts DESC LIMIT 1").fetchone()
    domains = [row[0] for row in connection.execute("SELECT DISTINCT domain FROM site_samples ORDER BY domain")]
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
        sites.append((dict(latest), dict(aggregate)))
    connection.close()
    return (dict(system) if system else {}, dict(service) if service else {}, sites)


def alert_for(site, agg):
    alerts = []
    code = int(site.get("http_code", 0) or 0)
    if code < 200 or code >= 400:
        alerts.append(f"HTTP {code or 'DOWN'}")
    if int(site.get("php_queue", 0) or 0) > 0:
        alerts.append("PHP queue")
    if int(site.get("php_max_reached", 0) or 0) > 0:
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


def draw_header(stdscr, system, view, modes):
    height, width = stdscr.getmaxyx()
    title = f" wp-shell {VIEWS[view]} "
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    age = int(time.time() - int(system.get("ts", 0) or 0)) if system else -1
    right = f"sites {len(modes)} | sample {age}s | {stamp} " if age >= 0 else f"sites {len(modes)} | no sample | {stamp} "
    style = curses.color_pair(1) | curses.A_BOLD if curses.has_colors() else curses.A_REVERSE
    add(stdscr, 0, 0, (title + " " * width)[:width], style)
    add(stdscr, 0, max(len(title), width - len(right) - 1), right, style)
    if not system:
        return 2
    total = max(1, int(system.get("mem_total_mb", 0) or 0))
    used = total - int(system.get("mem_available_mb", 0) or 0)
    memory_pct = 100 * used / total
    columns = max(12, (width - 45) // 3)
    add(stdscr, 1, 1, f"CPU {float(system.get('cpu_pct', 0)) :5.1f}% {bar(system.get('cpu_pct', 0), columns)}")
    add(stdscr, 1, min(width // 3, 30), f"MEM {used}/{total}MB {bar(memory_pct, columns)}")
    add(stdscr, 1, min(2 * width // 3, 60), f"DISK {float(system.get('disk_pct', 0)):4.0f}% {bar(system.get('disk_pct', 0), columns)}")
    add(stdscr, 2, 1, f"Load {float(system.get('load1', 0)):.2f} | Swap {int(system.get('swap_used_mb', 0))}MB | Raw data retained 30d | Window 5m")
    return 4


def table_layout(width, view):
    if view == 0:
        return [("Domain", 24), ("Req/5m", 8), ("P95", 8), ("Hit", 7), ("PHP", 10), ("RSS", 8), ("HTTP", 6), ("Health", 16)]
    if view == 1:
        return [("Domain", 24), ("Requests", 9), ("2xx", 7), ("4xx", 7), ("5xx", 7), ("Bytes", 9), ("P95", 8), ("Cache", 8)]
    if view == 2:
        return [("Domain", 24), ("Active", 8), ("Idle", 7), ("Queue", 7), ("Max", 7), ("RSS", 9), ("Files", 9), ("Cache", 9), ("Logs", 8)]
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
    requests = int(agg.get("requests", 0) or 0)
    cache_total = int(agg.get("cache_hits", 0) or 0) + int(agg.get("cache_misses", 0) or 0)
    hit = f"{100*int(agg.get('cache_hits',0))/cache_total:.0f}%" if cache_total else "-"
    health = alert_for(site, agg)
    if view == 0:
        return [site["domain"], requests, f"{float(agg.get('p95_ms',0)):.0f}ms", hit,
                f"{site.get('php_active',0)}/{site.get('php_max_children',0)}", f"{float(site.get('php_rss_mb',0)):.0f}MB",
                site.get("http_code", 0), health]
    if view == 1:
        return [site["domain"], requests, agg.get("status_2xx", 0), agg.get("status_4xx", 0), agg.get("status_5xx", 0),
                human_bytes(agg.get("bytes_sent", 0)), f"{float(agg.get('p95_ms',0)):.0f}ms", hit]
    if view == 2:
        return [site["domain"], site.get("php_active", 0), site.get("php_idle", 0), site.get("php_queue", 0),
                site.get("php_max_children", 0), f"{float(site.get('php_rss_mb',0)):.0f}MB",
                f"{float(site.get('files_mb',0)):.0f}MB", f"{float(site.get('cache_mb',0)):.0f}MB", f"{float(site.get('logs_mb',0)):.0f}MB"]
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
        system, service, sites = fetch_data()
    except (sqlite3.Error, OSError) as error:
        add(stdscr, 0, 0, f"Metrics unavailable: {error}", curses.A_BOLD)
        stdscr.refresh()
        return selected
    start_y = draw_header(stdscr, system, view, modes)
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
        add(stdscr, start_y + 2, 1, "No site samples yet. The collector runs once per minute.")
    service_text = ""
    if service:
        total = int(service.get("redis_hits", 0) or 0) + int(service.get("redis_misses", 0) or 0)
        ratio = 100 * int(service.get("redis_hits", 0) or 0) / total if total else 0
        service_text = f"DB threads {service.get('mariadb_threads',0)} | Redis {float(service.get('redis_used_mb',0)):.1f}MB hit {ratio:.0f}%"
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
    local output="$1" now since min_available_pct i domain current stats sample_count first_ts peak_active peak_queue reached recommended reason
    : > "$output"
    now="$(date +%s)"
    since=$((now - 1209600))
    min_available_pct="$(sqlite3 "$METRICS_DB" "SELECT COALESCE(MIN(100.0*mem_available_mb/NULLIF(mem_total_mb,0)),0) FROM system_samples WHERE ts >= $since;")"
    for ((i = 1; i <= SITE_COUNT; i++)); do
        domain="${SITE_DOMAINS[$i]}"
        current="${SITE_PHP_MAX_CHILDREN[$i]:-2}"
        stats="$(sqlite3 -separator '|' "$METRICS_DB" "SELECT COUNT(*),COALESCE(MIN(ts),0),COALESCE(MAX(php_active),0),COALESCE(MAX(php_queue),0),COALESCE(MAX(php_max_reached),0) FROM site_samples WHERE domain='$domain' AND ts >= $since;")"
        IFS='|' read -r sample_count first_ts peak_active peak_queue reached <<< "$stats"
        recommended="$current"
        reason="No high-confidence change"
        if ((sample_count >= 1000)) && awk -v p="$min_available_pct" 'BEGIN{exit !(p>=20)}'; then
            if ((peak_queue > 0 || reached > 0)); then
                recommended=$((current + (current + 4) / 5))
                ((recommended > 50)) && recommended=50
                reason="Queue or pool saturation with at least 20% memory headroom"
            elif ((now - first_ts >= 1200000 && peak_active * 3 < current && current > 2)); then
                recommended=$((current - (current + 4) / 5))
                ((recommended < 2)) && recommended=2
                reason="Fourteen-day peak stayed below one third of the pool limit"
            fi
        fi
        if ((recommended != current)); then
            printf '%s|%s|%s|%s\n' "$domain" "$current" "$recommended" "$reason" >> "$output"
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
    sqlite3 -header -column "$METRICS_DB" "SELECT domain AS Domain, COUNT(*) AS Samples, MAX(php_active) AS 'Peak active', MAX(php_queue) AS 'Peak queue', MAX(php_max_reached) AS 'Max reached', printf('%.0f MB',MAX(php_rss_mb)) AS 'Peak RSS', printf('%.0f ms',MAX(p95_ms)) AS 'Peak P95' FROM site_samples WHERE ts >= $since GROUP BY domain ORDER BY domain;"
    printf '\nShared services\n'
    sqlite3 -header -column "$METRICS_DB" "SELECT MAX(mariadb_threads) AS 'Peak DB threads', MAX(mariadb_slow_queries)-MIN(mariadb_slow_queries) AS 'New slow queries', printf('%.1f MB',MAX(redis_used_mb)) AS 'Peak Redis', MAX(redis_evicted)-MIN(redis_evicted) AS 'Redis evictions' FROM service_samples WHERE ts >= $since;"
    printf '\nConfigured budget: MariaDB %sMB | Redis %sMB | PHP-FPM %sMB\n' "$MARIADB_BUFFER_MB" "$REDIS_MAX_MEMORY_MB" "$PHP_TOTAL_BUDGET_MB"
    recommendation_file="$STATE_DIR/last-recommendations.tsv"
    build_tuning_recommendations "$recommendation_file"
    printf '\nSafe automatic PHP recommendations\n'
    if [[ -s "$recommendation_file" ]]; then
        printf '%-28s %8s %8s  %s\n' "DOMAIN" "CURRENT" "PROPOSED" "REASON"
        while IFS='|' read -r domain current proposed reason; do
            printf '%-28s %8s %8s  %s\n' "$domain" "$current" "$proposed" "$reason"
        done < "$recommendation_file"
        printf '\nReview with: sudo wp-shell tune --apply\n'
    else
        printf 'No high-confidence automatic changes. At least 1,000 samples and memory headroom are required.\n'
    fi
    printf '\nMariaDB and Redis findings are advisory; wp-shell does not auto-change them from aggregate counters alone.\n'
}

apply_tuning() {
    local assume_yes="${1:-}" recommendation_file="$STATE_DIR/last-recommendations.tsv" domain current proposed reason
    [[ -s "$METRICS_DB" ]] || die "No metrics are available yet."
    calculate_resource_budget
    build_tuning_recommendations "$recommendation_file"
    [[ -s "$recommendation_file" ]] || { log_message INFO "No high-confidence changes are available."; return 0; }
    printf 'The following PHP-FPM limits will be applied:\n'
    while IFS='|' read -r domain current proposed reason; do
        printf '  %s: %s -> %s (%s)\n' "$domain" "$current" "$proposed" "$reason"
    done < "$recommendation_file"
    if [[ "$assume_yes" != "--yes" ]]; then
        collect_yes_no "Apply these reversible tuning overrides" no || { log_message INFO "No changes were applied."; return 0; }
    fi
    while IFS='|' read -r domain _current proposed _reason; do
        PHP_CHILD_OVERRIDES["$domain"]="$proposed"
    done < "$recommendation_file"
    save_tuning_config
    configure_php
    log_message SUCCESS "PHP-FPM tuning overrides were saved to $TUNING_CONFIG_FILE and applied."
}

install_backup_timer() {
    CURRENT_STEP="install the automatic backup timer"
    cat > /etc/systemd/system/wp-shell-backup.service <<EOF
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
    cat > /etc/systemd/system/wp-shell-backup.timer <<'EOF'
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
    local i
    printf '%-3s %-28s %-28s %-5s %-8s %-8s %-5s\n' "ID" "DOMAIN" "PRIMARY" "PHP" "MODE" "REDIS" "POOL"
    for ((i = 1; i <= SITE_COUNT; i++)); do
        printf '%-3s %-28s %-28s %-5s %-8s %-8s %-5s\n' \
            "$i" "${SITE_DOMAINS[$i]}" "${SITE_PRIMARY_DOMAINS[$i]}" "${SITE_PHP_VERSIONS[$i]}" \
            "${SITE_MODES[$i]}" "${SITE_REDIS_DATABASES[$i]}" "${SITE_PHP_MAX_CHILDREN[$i]:--}"
    done
}

status_all_sites() {
    local i
    for ((i = 1; i <= SITE_COUNT; i++)); do
        site_status "$i"
    done
}

import_existing_sites() {
    CURRENT_STEP="detect existing WordPress sites"
    if ! command -v wp >/dev/null 2>&1; then
        log_message INFO "WP-CLI is required for discovery and will be installed."
        apt-get update
        apt_install ca-certificates curl php-cli
        install_wp_cli
    fi
    local wp_config wp_path wp_owner url host domain primary www php_version next_index redis_db imported=0
    while IFS= read -r -d '' wp_config; do
        wp_path="$(dirname "$wp_config")"
        [[ ! "$wp_path" =~ [[:space:]] ]] || { log_message WARNING "Skipping a path containing whitespace: $wp_path"; continue; }
        [[ -f "$wp_path/wp-includes/version.php" ]] || continue
        wp_owner="$(stat -c '%U' "$wp_config" 2>/dev/null || printf 'www-data')"
        id "$wp_owner" >/dev/null 2>&1 || wp_owner="www-data"
        if [[ "$wp_owner" == "root" ]]; then
            url="$(wp --allow-root option get home --path="$wp_path" 2>/dev/null || true)"
        else
            url="$(sudo -u "$wp_owner" wp option get home --path="$wp_path" 2>/dev/null || true)"
        fi
        host="$(printf '%s' "$url" | sed -E 's#^https?://([^/]+).*$#\1#')"
        primary="$host"
        domain="${host#www.}"
        validate_domain "$domain" || continue
        site_index_by_domain "$domain" >/dev/null 2>&1 && continue
        php_version="$(grep -RhoE 'php[0-9]+\.[0-9]+-fpm' /etc/nginx/sites-enabled 2>/dev/null | head -n 1 | sed -E 's/php([0-9]+\.[0-9]+)-fpm/\1/' || true)"
        validate_php_version "$php_version" || php_version="8.3"
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
        imported=$((imported + 1))
        log_message SUCCESS "Imported $domain from $wp_path."
    done < <(find /var/www /home -xdev -type f -name wp-config.php -print0 2>/dev/null)
    save_sites_config
    ensure_environment_config
    log_message INFO "Import completed; $imported site(s) added."
}

security_scan() {
    local failed=0 i domain wp_config perms version
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
        fi
        [[ -s "/etc/letsencrypt/live/$domain/fullchain.pem" ]] || { log_message ERROR "$domain has no certificate."; failed=$((failed + 1)); }
    done
    if ((failed == 0)); then
        log_message SUCCESS "Security checks passed."
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
    local domain index email php_version
    ((SITE_COUNT > 0)) || import_existing_sites
    ((SITE_COUNT > 0)) || die "No WordPress sites could be imported."
    list_sites
    read -r -p "Domain to transfer to wp-shell: " domain
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
    printf '1) Dashboard\n2) Add a new website\n3) Website list\n4) Website status\n5) Deploy or repair a website\n6) Back up one website\n7) Back up all websites\n8) Restore a website\n9) Import existing websites\n10) Traffic and resource report\n11) Analyze resource usage\n12) Apply safe tuning recommendations\n13) Reapply service resource budget\n14) Security scan\n15) Repair backup and metrics timers\n0) Exit\n'
    local choice domain backup_id range
    read -r -p "Select [0-15]: " choice
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
            read -r -p "Domain (leave empty for all sites): " domain
            if [[ -n "$domain" ]]; then site_action "$domain" status; else status_all_sites; fi
            ;;
        5)
            ((SITE_COUNT > 0)) || die "No sites are registered. Use option 2 or 9 first."
            list_sites
            read -r -p "Domain to deploy or repair: " domain
            deploy_domain "$domain"
            ;;
        6)
            ((SITE_COUNT > 0)) || die "No sites are registered."
            list_sites
            read -r -p "Domain to back up: " domain
            site_action "$domain" backup
            ;;
        7) ((SITE_COUNT > 0)) || die "No sites are registered."; backup_all_sites ;;
        8)
            ((SITE_COUNT > 0)) || die "No sites are registered."
            list_sites
            read -r -p "Domain: " domain
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
        13) configure_mariadb; configure_redis; configure_php ;;
        14) security_scan ;;
        15) install_self; install_backup_timer; install_metrics_timer ;;
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
  sudo wp-shell report [1h|6h|24h|7d|14d|30d]   Print a non-interactive metrics report
  sudo wp-shell analyze [range]                  Analyze collected resource evidence
  sudo wp-shell tune --apply [--yes]             Apply safe PHP-FPM recommendations
  sudo wp-shell site add                         Add and deploy a site
  sudo wp-shell site list                        List managed and imported sites
  sudo wp-shell site status [DOMAIN]             Show site status
  sudo wp-shell site DOMAIN summary              Show the website deployment summary
  sudo wp-shell site deploy DOMAIN               Idempotently deploy or repair a site
  sudo wp-shell site import                      Discover existing WordPress sites
  sudo wp-shell site DOMAIN ACTION               Run a compatibility site action
  sudo wp-shell metrics collect                  Collect one local metrics sample
  sudo wp-shell metrics install                  Install the one-minute collector
  sudo wp-shell backup-all                       Back up all sites
  sudo wp-shell restore DOMAIN BACKUP_ID         Restore one backup
  sudo wp-shell optimize                         Reapply the resource budget
  sudo wp-shell security-scan                    Validate services, TLS, and permissions

Site actions: status, info, summary, cache-clear, backup, backups, restore, update, restart
All dashboard text and stored operational metadata are ASCII/English. Access metrics
exclude client IPs, cookies, and query strings. Raw samples are retained for 30 days.
EOF
}

deploy_domain() {
    local domain="$1" index
    index="$(site_index_by_domain "$domain")" || die "Unmanaged site: $domain"
    prepare_stack
    deploy_site "$index"
    install_self
    install_metrics_timer
    show_site_deployment_summary "$index"
}

site_command() {
    local subcommand="${1:-list}"
    case "$subcommand" in
        add) add_site_command ;;
        list) list_sites ;;
        status)
            if [[ -n "${2:-}" ]]; then
                site_action "$2" status
            else
                status_all_sites
            fi
            ;;
        deploy) [[ -n "${2:-}" ]] || die "Usage: wp-shell site deploy DOMAIN"; deploy_domain "$2" ;;
        import) import_existing_sites; install_self ;;
        *) site_action "$subcommand" "${2:-status}" "${3:-}" ;;
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
    [[ -n "$domain" ]] || die "The legacy single-site command is ambiguous; use 'wp-shell site DOMAIN ACTION'."
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
        report) metrics_report "${2:-24h}" ;;
        analyze) analyze_metrics "${2:-7d}" ;;
        tune) [[ "${2:-}" == "--apply" ]] || die "Usage: wp-shell tune --apply [--yes]"; apply_tuning "${3:-}" ;;
        site) site_command "${2:-list}" "${3:-}" "${4:-}" ;;
        metrics)
            case "${2:-status}" in
                collect) collect_metrics ;;
                install) install_self; install_metrics_timer ;;
                status)
                    printf 'Timer: %s\n' "$(systemctl is-active wp-shell-metrics.timer 2>/dev/null || printf 'inactive')"
                    printf 'Database: %s\n' "$METRICS_DB"
                    [[ -s "$METRICS_DB" ]] && sqlite3 "$METRICS_DB" "SELECT 'Last sample: '||datetime(MAX(ts),'unixepoch','localtime') FROM system_samples;"
                    ;;
                *) die "Usage: wp-shell metrics collect|install|status" ;;
            esac
            ;;
        list) list_sites ;;
        status) status_all_sites ;;
        add-site) add_site_command ;;
        deploy) [[ -n "${2:-}" ]] || die "A domain is required."; deploy_domain "$2" ;;
        import) import_existing_sites; install_self ;;
        backup-all) backup_all_sites ;;
        backup) [[ -n "${2:-}" ]] || die "A domain is required."; site_action "$2" backup ;;
        restore) [[ -n "${2:-}" && -n "${3:-}" ]] || die "Usage: restore DOMAIN BACKUP_ID"; site_action "$2" restore "$3" ;;
        optimize) configure_mariadb; configure_redis; configure_php ;;
        security-scan) security_scan ;;
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
        dashboard|report|analyze|tune|metrics)
            init_paths
            migrate_legacy_configs
            load_sites_config
            ensure_environment_config
            load_tuning_config
            execute_command "$@"
            ;;
        *)
            init_runtime
            migrate_legacy_configs
            load_sites_config
            ensure_environment_config
            load_tuning_config
            execute_command "$@"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
