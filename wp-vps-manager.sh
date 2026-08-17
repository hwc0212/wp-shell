#!/usr/bin/env bash

# WordPress VPS Manager
# Version 8.1.0
# Supported systems: Ubuntu 22.04/24.04 LTS

set -Eeuo pipefail
umask 077

readonly VERSION="8.1.0"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH
CONFIG_DIR="${WP_VPS_CONFIG_DIR:-/etc/wp-vps-manager}"
readonly CONFIG_DIR
readonly SITES_CONFIG_FILE="$CONFIG_DIR/sites.v2"
readonly DATABASE_CONFIG_DIR="$CONFIG_DIR/databases"
readonly REDIS_SECRET_FILE="$CONFIG_DIR/redis.secret"
readonly STATE_DIR="/var/lib/wp-vps-manager"
readonly LEGACY_BACKUP_ROOT="/var/backups/wp-shell"
readonly LEGACY_CACHE_ROOT="/var/cache/nginx"
readonly LOG_DIR="/var/log/wp-shell"
LOG_FILE="$LOG_DIR/wp-vps-manager-$(date +%Y%m%d-%H%M%S).log"
readonly LOG_FILE
readonly MANAGED_SCRIPT="/usr/local/sbin/wp-vps-manager"
readonly WP_CLI_VERSION="${WP_CLI_VERSION:-2.12.0}"
readonly WORDPRESS_LOCALE="${WORDPRESS_LOCALE:-zh_CN}"
readonly BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"

readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[1;33m'
readonly CYAN=$'\033[0;36m'
readonly NC=$'\033[0m'

AVAILABLE_PHP_VERSIONS=("8.2" "8.3" "8.4")
declare -a SITE_DOMAINS=()
declare -a SITE_PHP_VERSIONS=()
declare -a SITE_WOOCOMMERCE=()
declare -a SITE_WWW=()
declare -a SITE_REDIS_DATABASES=()
declare -a SITE_ADMIN_USERS=()
declare -a SITE_ADMIN_EMAILS=()
declare -a SITE_TITLES=()
declare -a SITE_PATHS=()
SITE_COUNT=0
CURRENT_STEP="初始化"
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
    log_message ERROR "步骤 '$CURRENT_STEP' 失败（退出码 $exit_code），日志：$LOG_FILE"
    exit "$exit_code"
}
trap on_error ERR

ensure_root() {
    if [[ $EUID -eq 0 ]]; then
        return
    fi
    command -v sudo >/dev/null 2>&1 || die "需要 root 权限，且系统未安装 sudo"
    exec sudo -E bash "$SCRIPT_PATH" "$@"
}

init_runtime() {
    install -d -m 0700 "$CONFIG_DIR" "$DATABASE_CONFIG_DIR" "$STATE_DIR"
    install -d -m 0755 /var/www
    install -d -m 0750 "$LOG_DIR"
    touch "$LOG_FILE"
    chmod 0600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE")
    exec 2> >(tee -a "$LOG_FILE" >&2)
    exec 9>/run/wp-vps-manager.lock
    flock -n 9 || die "另一个 wp-vps-manager 进程正在运行"
}

check_platform() {
    [[ -r /etc/os-release ]] || die "无法识别操作系统"
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || die "仅支持 Ubuntu"
    case "${VERSION_ID:-}" in
        22.04|24.04) ;;
        *) die "仅支持 Ubuntu 22.04/24.04 LTS，当前为 ${VERSION_ID:-unknown}" ;;
    esac
    [[ "$(uname -m)" == "x86_64" || "$(uname -m)" == "aarch64" ]] || die "不支持的架构：$(uname -m)"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
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
    SITE_PHP_VERSIONS=()
    SITE_WOOCOMMERCE=()
    SITE_WWW=()
    SITE_REDIS_DATABASES=()
    SITE_ADMIN_USERS=()
    SITE_ADMIN_EMAILS=()
    SITE_TITLES=()
    SITE_PATHS=()
    SITE_COUNT=0
}

load_sites_config() {
    reset_sites
    [[ -f "$SITES_CONFIG_FILE" ]] || return 0

    local record domain php woo www redis_db admin_b64 email_b64 title_b64 path_b64
    while IFS='|' read -r record domain php woo www redis_db admin_b64 email_b64 title_b64 path_b64; do
        [[ -n "$record" ]] || continue
        case "$record" in
            version)
                [[ "$domain" == "2" ]] || die "不支持的站点配置版本：$domain"
                ;;
            site)
                validate_domain "$domain" || die "配置中包含非法域名：$domain"
                validate_php_version "$php" || die "配置中包含不支持的 PHP 版本：$php"
                [[ "$woo" == "yes" || "$woo" == "no" ]] || die "配置中的 WooCommerce 值无效"
                [[ "$www" == "yes" || "$www" == "no" ]] || die "配置中的 www 值无效"
                [[ "$redis_db" =~ ^([0-9]|1[0-5])$ ]] || die "配置中的 Redis DB 无效"
                SITE_COUNT=$((SITE_COUNT + 1))
                SITE_DOMAINS[SITE_COUNT]="$domain"
                SITE_PHP_VERSIONS[SITE_COUNT]="$php"
                SITE_WOOCOMMERCE[SITE_COUNT]="$woo"
                SITE_WWW[SITE_COUNT]="$www"
                SITE_REDIS_DATABASES[SITE_COUNT]="$redis_db"
                SITE_ADMIN_USERS[SITE_COUNT]="$(b64_decode "$admin_b64")"
                SITE_ADMIN_EMAILS[SITE_COUNT]="$(b64_decode "$email_b64")"
                SITE_TITLES[SITE_COUNT]="$(b64_decode "$title_b64")"
                if [[ -n "$path_b64" ]]; then
                    SITE_PATHS[SITE_COUNT]="$(b64_decode "$path_b64")"
                else
                    SITE_PATHS[SITE_COUNT]="/var/www/$domain/public"
                fi
                [[ "${SITE_PATHS[SITE_COUNT]}" == /* ]] || die "配置中的站点路径不是绝对路径"
                [[ ! "${SITE_PATHS[SITE_COUNT]}" =~ [[:space:]] ]] || die "站点路径不能包含空白字符"
                ;;
            \#*) ;;
            *) die "未知站点配置记录：$record" ;;
        esac
    done < "$SITES_CONFIG_FILE"
}

save_sites_config() {
    local temp_file i
    temp_file="$(mktemp "$CONFIG_DIR/.sites.XXXXXX")"
    {
        printf 'version|2\n'
        for ((i = 1; i <= SITE_COUNT; i++)); do
            printf 'site|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
                "${SITE_DOMAINS[$i]}" \
                "${SITE_PHP_VERSIONS[$i]}" \
                "${SITE_WOOCOMMERCE[$i]}" \
                "${SITE_WWW[$i]}" \
                "${SITE_REDIS_DATABASES[$i]}" \
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
    ((total_mem >= 1024)) || die "至少需要 1GB 内存；当前为 ${total_mem}MB"

    os_reserve=$((total_mem * 25 / 100))
    ((os_reserve < 384)) && os_reserve=384
    MARIADB_BUFFER_MB=$((total_mem * 30 / 100))
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

    log_message INFO "资源预算：系统预留 ${os_reserve}MB，MariaDB ${MARIADB_BUFFER_MB}MB，Redis ${REDIS_MAX_MEMORY_MB}MB，PHP-FPM 总预算 ${PHP_TOTAL_BUDGET_MB}MB"
}

check_capacity() {
    local total_mem max_sites available_gb
    total_mem="$(memory_mb)"
    max_sites="$(max_sites_for_memory "$total_mem")"
    available_gb="$(df -Pm / | awk 'NR == 2 {print int($4 / 1024)}')"
    ((available_gb >= 8)) || die "根分区至少需要 8GB 可用空间；当前约 ${available_gb}GB"
    ((SITE_COUNT <= max_sites)) || die "当前内存建议最多部署 $max_sites 个站点；配置中有 $SITE_COUNT 个"
    log_message INFO "服务器：${total_mem}MB 内存，$(cpu_count) 核 CPU，约 ${available_gb}GB 可用空间，建议最多 $max_sites 个站点"
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
    CURRENT_STEP="安装系统软件包"
    apt-get update
    apt_install ca-certificates curl openssl unzip rsync dnsutils sudo nginx mariadb-server mariadb-client redis-server certbot fail2ban ufw

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

configure_php() {
    CURRENT_STEP="配置 PHP-FPM"
    calculate_resource_budget
    local version_count version per_version_budget process_memory max_children start_servers min_spare max_spare memory_limit
    version_count="$(unique_php_versions | grep -c . || true)"
    ((version_count > 0)) || return 0
    per_version_budget=$((PHP_TOTAL_BUDGET_MB / version_count))
    process_memory=96
    max_children=$((per_version_budget / process_memory))
    ((max_children < 2)) && max_children=2
    ((max_children > 50)) && max_children=50
    start_servers=$((max_children / 4))
    ((start_servers < 1)) && start_servers=1
    min_spare=$((max_children / 4))
    ((min_spare < 1)) && min_spare=1
    max_spare=$((max_children / 2))
    ((max_spare < 2)) && max_spare=2
    memory_limit="256M"
    ((per_version_budget >= 1024)) && memory_limit="512M"

    while IFS= read -r version; do
        [[ -n "$version" ]] || continue
        install -d -m 0755 "/etc/php/$version/fpm/pool.d" "/etc/php/$version/fpm/conf.d"
        cat > "/etc/php/$version/fpm/pool.d/99-wp-shell.conf" <<EOF
[www]
pm = dynamic
pm.max_children = $max_children
pm.start_servers = $start_servers
pm.min_spare_servers = $min_spare
pm.max_spare_servers = $max_spare
pm.max_requests = 500
request_terminate_timeout = 300s
request_slowlog_timeout = 5s
slowlog = /var/log/php${version}-fpm-slow.log
catch_workers_output = yes
EOF
        cat > "/etc/php/$version/fpm/conf.d/99-wp-shell.ini" <<EOF
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
        "php-fpm${version}" -t
        systemctl enable "php${version}-fpm"
        systemctl restart "php${version}-fpm"
    done < <(unique_php_versions)
    log_message SUCCESS "PHP-FPM 已按所有版本共享预算配置，每个版本最多 $max_children 个进程"
}

configure_mariadb() {
    CURRENT_STEP="配置 MariaDB"
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
        die "MariaDB 新配置无法启动，已回滚"
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
    [[ "$REDIS_PASSWORD" =~ ^[a-f0-9]{48}$ ]] || die "Redis 密码文件格式无效"
}

configure_redis() {
    CURRENT_STEP="配置 Redis"
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
        die "Redis 新配置无法启动，已尝试回滚"
    fi
    rm -f "$previous_config" "$previous_override"
    systemctl enable redis-server
}

configure_fail2ban() {
    CURRENT_STEP="配置 Fail2ban"
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
    CURRENT_STEP="配置 UFW 防火墙"
    local ssh_port
    ssh_port="$(detect_ssh_port)"
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${ssh_port}/tcp" comment 'SSH managed by wp-shell'
    ufw allow 80/tcp comment 'HTTP managed by wp-shell'
    ufw allow 443/tcp comment 'HTTPS managed by wp-shell'
    ufw --force enable
    log_message SUCCESS "UFW 已保留原规则并允许 SSH 端口 $ssh_port、HTTP 和 HTTPS"
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
    [[ "$record" == "database" ]] || die "数据库配置损坏：$path"
    [[ "$DB_NAME" =~ ^wp_[a-f0-9]{12}$ ]] || die "数据库名无效：$DB_NAME"
    [[ "$DB_USER" =~ ^wp_[a-f0-9]{12}$ ]] || die "数据库用户名无效：$DB_USER"
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
    CURRENT_STEP="创建站点数据库"
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
        die "Nginx 配置验证失败，已回滚 $domain"
    fi
    rm -f "$site_backup" "$cache_backup"
    systemctl enable nginx
    systemctl reload nginx
}

configure_acme_site() {
    CURRENT_STEP="配置 ACME 临时站点"
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
    CURRENT_STEP="申请 SSL 证书"
    local index="$1" domain email wp_path
    local -a domains certbot_args
    domain="${SITE_DOMAINS[$index]}"
    email="${SITE_ADMIN_EMAILS[$index]}"
    wp_path="${SITE_PATHS[$index]}"
    domains=(-d "$domain")
    [[ "${SITE_WWW[$index]}" == "yes" ]] && domains+=(-d "www.$domain")
    getent ahosts "$domain" >/dev/null 2>&1 || die "域名 $domain 尚未解析，无法申请证书"
    if [[ "${SITE_WWW[$index]}" == "yes" ]]; then
        getent ahosts "www.$domain" >/dev/null 2>&1 || die "www.$domain 尚未解析，请取消 www 或先配置 DNS"
    fi
    certbot_args=(certonly --webroot --webroot-path "$wp_path" --cert-name "$domain" --agree-tos --non-interactive --email "$email" --keep-until-expiring)
    if [[ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]]; then
        certbot_args+=(--expand)
    fi
    certbot "${certbot_args[@]}" "${domains[@]}"
    [[ -s "/etc/letsencrypt/live/$domain/fullchain.pem" ]] || die "证书文件未生成：$domain"
}

configure_https_site() {
    CURRENT_STEP="配置 HTTPS 站点"
    local index="$1" domain php_version server_names zone site_temp cache_temp wp_path
    domain="${SITE_DOMAINS[$index]}"
    php_version="${SITE_PHP_VERSIONS[$index]}"
    wp_path="${SITE_PATHS[$index]}"
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
        return 301 https://$domain\$request_uri;
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

    client_max_body_size 128M;
    access_log /var/www/$domain/logs/nginx-access.log;
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
        fastcgi_pass unix:/run/php/php${php_version}-fpm.sock;
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
    install_nginx_files "$domain" "$site_temp" "$cache_temp"
    rm -f "$site_temp" "$cache_temp"
}

create_site_directories() {
    local domain="$1" wp_path="$2"
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

migrate_legacy_backups() {
    local legacy_dir="$1" destination="$2" marker="$2/.legacy-backups-imported"
    [[ -d "$legacy_dir" && ! -e "$marker" ]] || return 0
    rsync -a --ignore-existing --exclude='.incomplete.*' "$legacy_dir/" "$destination/"
    printf 'copied_from=%s\ncopied_at=%s\n' "$legacy_dir" "$(date --iso-8601=seconds)" > "$marker"
    chmod 0600 "$marker"
    log_message INFO "旧备份已安全复制到 $destination；确认无误后可手动删除 $legacy_dir"
}

ensure_site_storage() {
    local domain="$1" cache_dir backup_dir
    cache_dir="$(site_cache_dir "$domain")"
    backup_dir="$(site_backup_dir "$domain")"
    install -d -o www-data -g www-data -m 0750 "$cache_dir"
    install -d -o root -g root -m 0700 "$backup_dir"
    migrate_legacy_backups "$LEGACY_BACKUP_ROOT/$domain" "$backup_dir"
}

set_site_permissions() {
    local domain="$1" wp_path
    wp_path="$(site_wp_path "$domain")"
    chown -R www-data:www-data "$wp_path" "/var/www/$domain/logs"
    find "$wp_path" -type d -exec chmod 0755 {} +
    find "$wp_path" -type f -exec chmod 0644 {} +
    [[ -f "$wp_path/wp-config.php" ]] && chmod 0640 "$wp_path/wp-config.php"
    chmod 0750 "/var/www/$domain/logs"
}

install_wordpress_site() {
    CURRENT_STEP="安装 WordPress"
    local index="$1" domain wp_path admin_password credentials_file redis_password memory_limit
    domain="${SITE_DOMAINS[$index]}"
    wp_path="${SITE_PATHS[$index]}"
    load_or_create_redis_secret
    redis_password="$REDIS_PASSWORD"

    if [[ ! -f "$wp_path/wp-load.php" ]]; then
        sudo -u www-data wp core download --path="$wp_path" --locale="$WORDPRESS_LOCALE"
    fi
    if [[ ! -f "$wp_path/wp-config.php" ]]; then
        load_database_config "$domain"
        printf '%s\n' "$DB_PASSWORD" | sudo -u www-data wp config create \
            --path="$wp_path" --dbname="$DB_NAME" --dbuser="$DB_USER" \
            --dbhost=localhost --dbprefix=wp_ --dbcharset=utf8mb4 --prompt=dbpass
    fi

    sudo -u www-data wp config set FORCE_SSL_ADMIN true --raw --path="$wp_path"
    sudo -u www-data wp config set DISALLOW_FILE_EDIT true --raw --path="$wp_path"
    sudo -u www-data wp config set WP_CACHE true --raw --path="$wp_path"
    sudo -u www-data wp config set WP_REDIS_HOST 127.0.0.1 --path="$wp_path"
    sudo -u www-data wp config set WP_REDIS_PORT 6379 --raw --path="$wp_path"
    sudo -u www-data wp config set WP_REDIS_PASSWORD "$redis_password" --path="$wp_path"
    sudo -u www-data wp config set WP_REDIS_DATABASE "${SITE_REDIS_DATABASES[$index]}" --raw --path="$wp_path"
    sudo -u www-data wp config set WP_REDIS_PREFIX "${domain}:" --path="$wp_path"
    memory_limit="256M"
    (( $(memory_mb) >= 4096 )) && memory_limit="512M"
    sudo -u www-data wp config set WP_MEMORY_LIMIT "$memory_limit" --path="$wp_path"

    if ! sudo -u www-data wp core is-installed --path="$wp_path" >/dev/null 2>&1; then
        admin_password="$(generate_password)"
        printf '%s\n' "$admin_password" | sudo -u www-data wp core install \
            --path="$wp_path" --url="https://$domain" \
            --title="${SITE_TITLES[$index]}" \
            --admin_user="${SITE_ADMIN_USERS[$index]}" \
            --admin_email="${SITE_ADMIN_EMAILS[$index]}" --skip-email --prompt=admin_password
        credentials_file="/root/wordpress-credentials-$domain.txt"
        {
            printf 'WordPress 站点凭据\n'
            printf '生成时间：%s\n' "$(date --iso-8601=seconds)"
            printf '登录地址：https://%s/wp-admin/\n' "$domain"
            printf '管理员：%s\n' "${SITE_ADMIN_USERS[$index]}"
            printf '管理员密码：%s\n' "$admin_password"
            printf '管理员邮箱：%s\n' "${SITE_ADMIN_EMAILS[$index]}"
        } > "$credentials_file"
        chmod 0600 "$credentials_file"
    fi

    sudo -u www-data wp rewrite structure '/%postname%/' --hard --path="$wp_path"
    sudo -u www-data wp plugin install redis-cache --activate --path="$wp_path"
    sudo -u www-data wp redis enable --path="$wp_path"
    if [[ "${SITE_WOOCOMMERCE[$index]}" == "yes" ]]; then
        sudo -u www-data wp plugin install woocommerce --activate --path="$wp_path"
    fi
    sudo -u www-data wp plugin delete hello akismet --path="$wp_path" 2>/dev/null || true
    set_site_permissions "$domain"
}

install_site_wrapper() {
    local domain="$1" wrapper="/usr/local/bin/manage-$1"
    cat > "$wrapper" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ \$EUID -eq 0 ]]; then
    exec $MANAGED_SCRIPT site "$domain" "\$@"
fi
exec sudo $MANAGED_SCRIPT site "$domain" "\$@"
EOF
    chmod 0755 "$wrapper"
}

install_self() {
    if [[ "$SCRIPT_PATH" != "$MANAGED_SCRIPT" ]] && ! cmp -s "$SCRIPT_PATH" "$MANAGED_SCRIPT" 2>/dev/null; then
        install -o root -g root -m 0755 "$SCRIPT_PATH" "$MANAGED_SCRIPT"
    fi
    ln -sfn "$MANAGED_SCRIPT" /usr/local/bin/wp-vps-manager
    local i
    for ((i = 1; i <= SITE_COUNT; i++)); do
        install_site_wrapper "${SITE_DOMAINS[$i]}"
    done
}

deploy_site() {
    local index="$1" domain
    domain="${SITE_DOMAINS[$index]}"
    log_message INFO "开始部署 $domain（PHP ${SITE_PHP_VERSIONS[$index]}）"
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
    install_site_wrapper "$domain"
    log_message SUCCESS "$domain 部署完成"
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
    local next_index=$((SITE_COUNT + 1)) domain php_choice email admin title www woo max_sites
    max_sites="$(max_sites_for_memory "$(memory_mb)")"
    ((next_index <= max_sites)) || die "当前服务器建议最多 $max_sites 个站点"

    while true; do
        read -r -p "域名（不含 www）：" domain
        domain="${domain,,}"
        validate_domain "$domain" || { log_message WARNING "域名格式不正确"; continue; }
        if site_index_by_domain "$domain" >/dev/null 2>&1; then
            log_message WARNING "域名已存在"
            continue
        fi
        break
    done

    printf 'PHP 版本：\n'
    local i
    for i in "${!AVAILABLE_PHP_VERSIONS[@]}"; do
        printf '  %d) PHP %s\n' "$((i + 1))" "${AVAILABLE_PHP_VERSIONS[$i]}"
    done
    while true; do
        read -r -p "选择 [1-${#AVAILABLE_PHP_VERSIONS[@]}]：" php_choice
        [[ "$php_choice" =~ ^[0-9]+$ ]] || continue
        ((php_choice >= 1 && php_choice <= ${#AVAILABLE_PHP_VERSIONS[@]})) || continue
        break
    done

    while true; do
        read -r -p "管理员邮箱：" email
        validate_email "$email" && break
        log_message WARNING "邮箱格式不正确"
    done
    read -r -p "管理员用户名 [wpadmin]：" admin
    admin="${admin:-wpadmin}"
    [[ "$admin" =~ ^[a-zA-Z0-9_.-]{4,60}$ ]] || die "管理员用户名格式无效"
    read -r -p "站点标题 [$domain]：" title
    title="${title:-$domain}"
    collect_yes_no "证书是否包含 www.$domain？请确保 DNS 已解析" no && www=yes || www=no
    collect_yes_no "是否安装 WooCommerce？" no && woo=yes || woo=no

    SITE_COUNT=$next_index
    SITE_DOMAINS[next_index]="$domain"
    SITE_PHP_VERSIONS[next_index]="${AVAILABLE_PHP_VERSIONS[$((php_choice - 1))]}"
    SITE_WOOCOMMERCE[next_index]="$woo"
    SITE_WWW[next_index]="$www"
    SITE_REDIS_DATABASES[next_index]="$((next_index - 1))"
    SITE_ADMIN_USERS[next_index]="$admin"
    SITE_ADMIN_EMAILS[next_index]="$email"
    SITE_TITLES[next_index]="$title"
    SITE_PATHS[next_index]="/var/www/$domain/public"
    save_sites_config
}

prepare_stack() {
    check_capacity
    install_system_packages
    configure_mariadb
    configure_redis
    configure_php
    configure_fail2ban
    install_certbot_deploy_hook
    rm -f /etc/nginx/sites-enabled/default
    systemctl enable --now nginx
    install_self
}

bootstrap_server() {
    local configure_ufw="no" i
    prepare_stack
    if collect_yes_no "是否启用并配置 UFW？现有规则会保留" yes; then
        configure_ufw=yes
    fi
    [[ "$configure_ufw" == "yes" ]] || log_message INFO "已跳过 UFW 配置"
    for ((i = 1; i <= SITE_COUNT; i++)); do
        deploy_site "$i"
    done
    install_self
    install_backup_timer
}

site_wp_path() {
    local index
    index="$(site_index_by_domain "$1")" || return 1
    printf '%s' "${SITE_PATHS[$index]}"
}

site_http_status() {
    local domain="$1" code
    code="$(curl --silent --show-error --output /dev/null --max-time 8 --write-out '%{http_code}' "https://$domain" 2>/dev/null || true)"
    [[ "$code" =~ ^[23][0-9]{2}$ ]] && printf '正常（HTTP %s）' "$code" || printf '异常（HTTP %s）' "${code:-000}"
}

site_status() {
    local index="$1" domain php_version
    domain="${SITE_DOMAINS[$index]}"
    php_version="${SITE_PHP_VERSIONS[$index]}"
    printf '站点：%s\n' "$domain"
    printf '  HTTPS：%s\n' "$(site_http_status "$domain")"
    printf '  Nginx：%s\n' "$(systemctl is-active nginx 2>/dev/null || true)"
    printf '  PHP-FPM：%s\n' "$(systemctl is-active "php${php_version}-fpm" 2>/dev/null || true)"
    printf '  MariaDB：%s\n' "$(systemctl is-active mariadb 2>/dev/null || true)"
    printf '  Redis：%s\n' "$(systemctl is-active redis-server 2>/dev/null || true)"
}

create_mysql_defaults_file() {
    local wp_path="$1" defaults_file db_user db_password db_host escaped_password
    defaults_file="$(mktemp /run/wp-vps-mysql.XXXXXX)"
    db_user="$(sudo -u www-data wp config get DB_USER --path="$wp_path")"
    db_password="$(sudo -u www-data wp config get DB_PASSWORD --path="$wp_path")"
    db_host="$(sudo -u www-data wp config get DB_HOST --path="$wp_path")"
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
    CURRENT_STEP="备份站点"
    local index="$1" domain wp_path timestamp site_backup_root temp_dir final_dir defaults_file db_name
    domain="${SITE_DOMAINS[$index]}"
    wp_path="$(site_wp_path "$domain")"
    [[ -f "$wp_path/wp-config.php" ]] || die "$domain 尚未安装 WordPress"
    timestamp="$(date +%Y%m%d-%H%M%S)"
    ensure_site_storage "$domain"
    site_backup_root="$(site_backup_dir "$domain")"
    temp_dir="$(mktemp -d "$site_backup_root/.incomplete.XXXXXX")"
    final_dir="$site_backup_root/$timestamp"
    defaults_file="$(create_mysql_defaults_file "$wp_path")"
    db_name="$(sudo -u www-data wp config get DB_NAME --path="$wp_path")"

    if ! tar --exclude='./wp-content/cache/*' --exclude='./wp-content/uploads/cache/*' -czf "$temp_dir/files.tar.gz" -C "$wp_path" .; then
        rm -rf -- "$temp_dir"
        rm -f "$defaults_file"
        die "文件备份失败：$domain"
    fi
    if ! mariadb-dump --defaults-extra-file="$defaults_file" --single-transaction --quick --routines --triggers --add-drop-table "$db_name" | gzip -9 > "$temp_dir/database.sql.gz"; then
        rm -rf -- "$temp_dir"
        rm -f "$defaults_file"
        die "数据库备份失败：$domain"
    fi
    rm -f "$defaults_file"
    {
        printf 'domain=%s\n' "$domain"
        printf 'created_at=%s\n' "$(date --iso-8601=seconds)"
        printf 'wordpress_version=%s\n' "$(sudo -u www-data wp core version --path="$wp_path")"
    } > "$temp_dir/manifest.txt"
    (cd "$temp_dir" && sha256sum files.tar.gz database.sql.gz manifest.txt > SHA256SUMS)
    mv "$temp_dir" "$final_dir"
    find "$site_backup_root" -mindepth 1 -maxdepth 1 -type d -name '20??????-??????' -mtime "+$BACKUP_RETENTION_DAYS" -exec rm -rf -- {} +
    log_message SUCCESS "备份完成：$final_dir"
    printf '%s\n' "$final_dir"
}

restore_site() {
    CURRENT_STEP="恢复站点"
    local index="$1" backup_id="$2" domain wp_path backup_dir defaults_file db_name
    domain="${SITE_DOMAINS[$index]}"
    wp_path="$(site_wp_path "$domain")"
    [[ "$backup_id" =~ ^20[0-9]{6}-[0-9]{6}$ ]] || die "备份编号格式无效"
    ensure_site_storage "$domain"
    backup_dir="$(site_backup_dir "$domain")/$backup_id"
    [[ -d "$backup_dir" ]] || die "备份不存在：$backup_dir"
    (cd "$backup_dir" && sha256sum --check SHA256SUMS)
    log_message INFO "恢复前创建安全备份"
    backup_site "$index" >/dev/null
    defaults_file="$(create_mysql_defaults_file "$wp_path")"
    db_name="$(sudo -u www-data wp config get DB_NAME --path="$wp_path")"

    (
        set -Eeuo pipefail
        local_stage="$(mktemp -d /tmp/wp-restore.XXXXXX)"
        # shellcheck disable=SC2317,SC2329
        cleanup_restore() {
            rm -rf -- "$local_stage"
            rm -f "$defaults_file"
            sudo -u www-data wp maintenance-mode deactivate --path="$wp_path" >/dev/null 2>&1 || true
        }
        trap cleanup_restore EXIT
        tar -xzf "$backup_dir/files.tar.gz" -C "$local_stage"
        [[ -f "$local_stage/wp-config.php" ]]
        sudo -u www-data wp maintenance-mode activate --path="$wp_path" >/dev/null 2>&1 || true
        rsync -a --delete "$local_stage/" "$wp_path/"
        gzip -dc "$backup_dir/database.sql.gz" | mariadb --defaults-extra-file="$defaults_file" "$db_name"
        set_site_permissions "$domain"
    )
    clear_site_cache "$index"
    log_message SUCCESS "$domain 已恢复到 $backup_id"
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
        sudo -u www-data wp cache flush --path="$wp_path" || true
    fi
    systemctl reload "php${SITE_PHP_VERSIONS[$index]}-fpm"
}

update_site() {
    local index="$1" domain wp_path
    domain="${SITE_DOMAINS[$index]}"
    wp_path="$(site_wp_path "$domain")"
    backup_site "$index" >/dev/null
    sudo -u www-data wp core update --path="$wp_path"
    sudo -u www-data wp core update-db --path="$wp_path"
    sudo -u www-data wp plugin update --all --path="$wp_path"
    sudo -u www-data wp theme update --all --path="$wp_path"
    clear_site_cache "$index"
}

list_backups() {
    local index="$1" domain backup_dir
    domain="${SITE_DOMAINS[$index]}"
    ensure_site_storage "$domain"
    backup_dir="$(site_backup_dir "$domain")"
    printf '可用备份（%s）：\n' "$domain"
    find "$backup_dir" -mindepth 1 -maxdepth 1 -type d -name '20??????-??????' -printf '  %f\n' 2>/dev/null | sort -r || true
}

site_action() {
    local domain="$1" action="${2:-status}" index wp_path
    index="$(site_index_by_domain "$domain")" || die "未管理的站点：$domain"
    wp_path="$(site_wp_path "$domain")"
    case "$action" in
        status) site_status "$index" ;;
        info)
            site_status "$index"
            [[ -f "$wp_path/wp-config.php" ]] && printf '  WordPress：%s\n' "$(sudo -u www-data wp core version --path="$wp_path")"
            ;;
        cache-clear) clear_site_cache "$index"; log_message SUCCESS "$domain 缓存已清理" ;;
        backup) backup_site "$index" ;;
        backups) list_backups "$index" ;;
        restore) [[ -n "${3:-}" ]] || die "用法：manage-$domain restore BACKUP_ID"; restore_site "$index" "$3" ;;
        update) update_site "$index" ;;
        restart)
            systemctl restart "php${SITE_PHP_VERSIONS[$index]}-fpm"
            nginx -t && systemctl reload nginx
            ;;
        *) die "未知站点操作：$action（支持 status/info/cache-clear/backup/backups/restore/update/restart）" ;;
    esac
}

backup_all_sites() {
    local i failures=0
    for ((i = 1; i <= SITE_COUNT; i++)); do
        if ! backup_site "$i"; then
            failures=$((failures + 1))
        fi
    done
    ((failures == 0)) || die "$failures 个站点备份失败"
}

install_backup_timer() {
    CURRENT_STEP="安装自动备份定时器"
    cat > /etc/systemd/system/wp-vps-backup.service <<EOF
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
    cat > /etc/systemd/system/wp-vps-backup.timer <<'EOF'
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
    systemctl enable --now wp-vps-backup.timer
}

list_sites() {
    if ((SITE_COUNT == 0)); then
        printf '当前没有管理的站点。\n'
        return
    fi
    local i
    for ((i = 1; i <= SITE_COUNT; i++)); do
        printf '%d. %s | PHP %s | WooCommerce %s | Redis DB %s\n' \
            "$i" "${SITE_DOMAINS[$i]}" "${SITE_PHP_VERSIONS[$i]}" \
            "${SITE_WOOCOMMERCE[$i]}" "${SITE_REDIS_DATABASES[$i]}"
    done
}

status_all_sites() {
    local i
    for ((i = 1; i <= SITE_COUNT; i++)); do
        site_status "$i"
    done
}

import_existing_sites() {
    CURRENT_STEP="检测现有 WordPress 站点"
    local wp_config wp_path url domain php_version next_index imported=0
    while IFS= read -r -d '' wp_config; do
        wp_path="$(dirname "$wp_config")"
        [[ ! "$wp_path" =~ [[:space:]] ]] || { log_message WARNING "跳过包含空白字符的路径：$wp_path"; continue; }
        [[ -f "$wp_path/wp-includes/version.php" ]] || continue
        url="$(sudo -u www-data wp option get home --path="$wp_path" 2>/dev/null || true)"
        domain="$(printf '%s' "$url" | sed -E 's#^https?://([^/]+).*$#\1#; s#^www\.##')"
        validate_domain "$domain" || continue
        site_index_by_domain "$domain" >/dev/null 2>&1 && continue
        php_version="$(grep -RhoE 'php[0-9]+\.[0-9]+-fpm' /etc/nginx/sites-enabled 2>/dev/null | head -n 1 | sed -E 's/php([0-9]+\.[0-9]+)-fpm/\1/' || true)"
        validate_php_version "$php_version" || php_version="8.3"
        next_index=$((SITE_COUNT + 1))
        ((next_index <= 16)) || die "Redis 数据库编号不足，最多导入 16 个站点"
        SITE_COUNT=$next_index
        SITE_DOMAINS[next_index]="$domain"
        SITE_PHP_VERSIONS[next_index]="$php_version"
        SITE_WOOCOMMERCE[next_index]="no"
        SITE_WWW[next_index]="no"
        SITE_REDIS_DATABASES[next_index]="$((next_index - 1))"
        SITE_ADMIN_USERS[next_index]="unknown"
        SITE_ADMIN_EMAILS[next_index]="unknown@$domain"
        SITE_TITLES[next_index]="$domain"
        SITE_PATHS[next_index]="$wp_path"
        install_site_wrapper "$domain"
        imported=$((imported + 1))
        log_message SUCCESS "已导入 $domain（目录 $wp_path）"
    done < <(find /var/www /home -xdev -type f -name wp-config.php -print0 2>/dev/null)
    save_sites_config
    log_message INFO "导入完成，共新增 $imported 个站点"
}

security_scan() {
    local failed=0 i domain wp_config perms version
    for service in nginx mariadb redis-server fail2ban; do
        if ! systemctl is-active --quiet "$service"; then
            log_message ERROR "$service 未运行"
            failed=$((failed + 1))
        fi
    done
    while IFS= read -r version; do
        [[ -n "$version" ]] || continue
        if ! systemctl is-active --quiet "php${version}-fpm"; then
            log_message ERROR "php${version}-fpm 未运行"
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
            [[ "$perms" == "640" || "$perms" == "600" ]] || { log_message WARNING "$wp_config 权限为 $perms"; failed=$((failed + 1)); }
        fi
        [[ -s "/etc/letsencrypt/live/$domain/fullchain.pem" ]] || { log_message ERROR "$domain 缺少证书"; failed=$((failed + 1)); }
    done
    if ((failed == 0)); then
        log_message SUCCESS "安全检查通过"
    else
        die "安全检查发现 $failed 个问题"
    fi
}

add_site_command() {
    local index
    collect_site_input
    index="$SITE_COUNT"
    prepare_stack
    deploy_site "$index"
    install_self
}

new_server_wizard() {
    local site_count i
    printf '\nWordPress VPS Manager v%s\n\n' "$VERSION"
    read -r -p "要部署多少个站点？" site_count
    if [[ ! "$site_count" =~ ^[0-9]+$ ]] || ((site_count < 1)); then
        die "站点数量无效"
    fi
    for ((i = 1; i <= site_count; i++)); do
        printf '\n配置站点 %d/%d\n' "$i" "$site_count"
        collect_site_input
    done
    bootstrap_server
    log_message SUCCESS "服务器和 $SITE_COUNT 个站点部署完成；凭据保存在 /root/wordpress-credentials-*.txt"
}

interactive_menu() {
    if ((SITE_COUNT == 0)); then
        new_server_wizard
        return
    fi
    printf '\nWordPress VPS Manager v%s\n' "$VERSION"
    printf '1) 添加站点\n2) 部署/修复已有站点\n3) 列出站点\n4) 所有站点状态\n5) 备份所有站点\n6) 恢复站点\n7) 导入现有站点\n8) 重新计算并应用资源配置\n9) 安全检查\n10) 安装/修复自动备份定时器\n0) 退出\n'
    local choice domain backup_id index
    read -r -p "选择 [0-10]：" choice
    case "$choice" in
        1) add_site_command ;;
        2)
            list_sites
            read -r -p "要部署/修复的域名：" domain
            index="$(site_index_by_domain "$domain")" || die "未管理的站点：$domain"
            prepare_stack
            deploy_site "$index"
            ;;
        3) list_sites ;;
        4) status_all_sites ;;
        5) backup_all_sites ;;
        6)
            read -r -p "域名：" domain
            site_action "$domain" backups
            read -r -p "备份编号：" backup_id
            site_action "$domain" restore "$backup_id"
            ;;
        7) import_existing_sites; install_self ;;
        8) configure_mariadb; configure_redis; configure_php ;;
        9) security_scan ;;
        10) install_backup_timer ;;
        0) return ;;
        *) die "无效选择" ;;
    esac
}

show_help() {
    cat <<EOF
WordPress VPS Manager v$VERSION

用法：
  sudo $0                         交互式管理
  sudo $0 list                    列出站点
  sudo $0 status                  检查所有站点
  sudo $0 add-site                添加并部署站点
  sudo $0 deploy DOMAIN           重新执行指定站点的幂等部署
  sudo $0 import                  导入现有站点
  sudo $0 backup-all              备份所有站点
  sudo $0 backup DOMAIN           备份指定站点
  sudo $0 restore DOMAIN ID       恢复指定备份
  sudo $0 site DOMAIN ACTION      站点操作
  sudo $0 optimize                重新应用资源预算
  sudo $0 security-scan           检查服务、证书和权限
  sudo $0 install-backup-timer    安装每日备份定时器
  $0 --version                    显示版本

ACTION：status、info、cache-clear、backup、backups、restore、update、restart
EOF
}

main() {
    case "${1:-}" in
        --help|-h) show_help; return ;;
        --version|-v) printf 'wp-vps-manager %s\n' "$VERSION"; return ;;
    esac

    ensure_root "$@"
    init_runtime
    check_platform
    require_command base64
    load_sites_config

    case "${1:-}" in
        "") interactive_menu ;;
        list) list_sites ;;
        status) status_all_sites ;;
        add-site) add_site_command ;;
        deploy)
            local index
            [[ -n "${2:-}" ]] || die "需要域名"
            index="$(site_index_by_domain "$2")" || die "未管理的站点：$2"
            prepare_stack
            deploy_site "$index"
            install_self
            ;;
        import) import_existing_sites; install_self ;;
        backup-all) backup_all_sites ;;
        backup) [[ -n "${2:-}" ]] || die "需要域名"; site_action "$2" backup ;;
        restore) [[ -n "${2:-}" && -n "${3:-}" ]] || die "用法：restore DOMAIN BACKUP_ID"; site_action "$2" restore "$3" ;;
        site) [[ -n "${2:-}" ]] || die "需要域名"; site_action "$2" "${3:-status}" "${4:-}" ;;
        optimize) configure_mariadb; configure_redis; configure_php ;;
        security-scan) security_scan ;;
        install-backup-timer) install_backup_timer ;;
        *) die "未知命令：$1；使用 --help 查看帮助" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
