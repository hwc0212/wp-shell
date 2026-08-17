#!/usr/bin/env bash

# Single-site WordPress deployment
# Version 2.1.0
# Supported systems: Ubuntu 22.04/24.04 LTS

set -Eeuo pipefail
umask 077

readonly VERSION="2.1.0"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH
CONFIG_DIR="${WP_SINGLE_CONFIG_DIR:-/etc/wp-single-deploy}"
readonly CONFIG_DIR
readonly SITE_CONFIG="$CONFIG_DIR/site.v2"
readonly DATABASE_CONFIG="$CONFIG_DIR/database.v1"
readonly REDIS_SECRET_FILE="$CONFIG_DIR/redis.secret"
readonly LOG_DIR="/var/log/wp-shell"
LOG_FILE="$LOG_DIR/wp-single-deploy-$(date +%Y%m%d-%H%M%S).log"
readonly LOG_FILE
readonly LEGACY_BACKUP_ROOT="/var/backups/wp-shell-single"
readonly LEGACY_CACHE_ROOT="/var/cache/nginx"
readonly MANAGED_SCRIPT="/usr/local/sbin/wp-single-manager"
readonly WP_CLI_VERSION="${WP_CLI_VERSION:-2.12.0}"
readonly WORDPRESS_LOCALE="${WORDPRESS_LOCALE:-zh_CN}"
readonly BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"

readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[1;33m'
readonly CYAN=$'\033[0;36m'
readonly NC=$'\033[0m'

AVAILABLE_PHP_VERSIONS=("8.2" "8.3" "8.4")
DOMAIN=""
PRIMARY_DOMAIN=""
INCLUDE_WWW="no"
PHP_VERSION=""
USE_WOOCOMMERCE="no"
SITE_TITLE=""
ADMIN_EMAIL=""
ADMIN_USER=""
DB_NAME=""
DB_USER=""
DB_PASSWORD=""
REDIS_PASSWORD=""
MARIADB_BUFFER_MB=256
MARIADB_MAX_CONNECTIONS=40
MARIADB_TMP_TABLE_MB=32
REDIS_MAX_MEMORY_MB=64
PHP_MAX_CHILDREN=4
PHP_MEMORY_LIMIT="256M"
CURRENT_STEP="初始化"

supports_color() {
    [[ -t 1 && "${NO_COLOR:-}" == "" ]]
}

log_message() {
    local level="$1"
    shift
    local color="" reset=""
    if supports_color; then
        case "$level" in
            ERROR) color="$RED" ;;
            SUCCESS) color="$GREEN" ;;
            WARNING) color="$YELLOW" ;;
            *) color="$CYAN" ;;
        esac
        reset="$NC"
    fi
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
    install -d -m 0700 "$CONFIG_DIR"
    install -d -m 0755 /var/www
    install -d -m 0750 "$LOG_DIR"
    touch "$LOG_FILE"
    chmod 0600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE")
    exec 2> >(tee -a "$LOG_FILE" >&2)
    exec 9>/run/wp-single-deploy.lock
    flock -n 9 || die "另一个单站点部署/管理进程正在运行"
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

save_site_config() {
    local temp_file
    temp_file="$(mktemp "$CONFIG_DIR/.site.XXXXXX")"
    printf 'site|2|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$DOMAIN" "$PRIMARY_DOMAIN" "$INCLUDE_WWW" "$PHP_VERSION" "$USE_WOOCOMMERCE" \
        "$(b64_encode "$SITE_TITLE")" "$(b64_encode "$ADMIN_EMAIL")" "$(b64_encode "$ADMIN_USER")" > "$temp_file"
    if [[ $EUID -eq 0 ]]; then
        install -o root -g root -m 0600 "$temp_file" "$SITE_CONFIG"
    else
        install -m 0600 "$temp_file" "$SITE_CONFIG"
    fi
    rm -f "$temp_file"
}

load_site_config() {
    local record version title_b64 email_b64 user_b64
    [[ -f "$SITE_CONFIG" ]] || return 1
    IFS='|' read -r record version DOMAIN PRIMARY_DOMAIN INCLUDE_WWW PHP_VERSION USE_WOOCOMMERCE title_b64 email_b64 user_b64 < "$SITE_CONFIG"
    [[ "$record" == "site" && "$version" == "2" ]] || die "站点配置格式无效"
    validate_domain "$DOMAIN" || die "配置中的域名无效"
    [[ "$PRIMARY_DOMAIN" == "$DOMAIN" || "$PRIMARY_DOMAIN" == "www.$DOMAIN" ]] || die "配置中的主域名无效"
    [[ "$INCLUDE_WWW" == "yes" || "$INCLUDE_WWW" == "no" ]] || die "配置中的 www 选项无效"
    [[ "$PRIMARY_DOMAIN" != "www.$DOMAIN" || "$INCLUDE_WWW" == "yes" ]] || die "主域名使用 www 时必须启用 www"
    validate_php_version "$PHP_VERSION" || die "配置中的 PHP 版本无效"
    [[ "$USE_WOOCOMMERCE" == "yes" || "$USE_WOOCOMMERCE" == "no" ]] || die "配置中的 WooCommerce 选项无效"
    SITE_TITLE="$(b64_decode "$title_b64")"
    ADMIN_EMAIL="$(b64_decode "$email_b64")"
    ADMIN_USER="$(b64_decode "$user_b64")"
}

collect_site_input() {
    local choice canonical_www
    while true; do
        read -r -p "域名（不含 www）：" DOMAIN
        DOMAIN="${DOMAIN,,}"
        validate_domain "$DOMAIN" && break
        log_message WARNING "域名格式不正确"
    done
    if collect_yes_no "是否同时配置 www.$DOMAIN？请确保 DNS 已解析" no; then
        INCLUDE_WWW=yes
        if collect_yes_no "是否将 www.$DOMAIN 作为主访问域名？" no; then canonical_www=yes; else canonical_www=no; fi
    else
        INCLUDE_WWW=no
        canonical_www=no
    fi
    [[ "$canonical_www" == "yes" ]] && PRIMARY_DOMAIN="www.$DOMAIN" || PRIMARY_DOMAIN="$DOMAIN"

    printf 'PHP 版本：\n'
    local i
    for i in "${!AVAILABLE_PHP_VERSIONS[@]}"; do
        printf '  %d) PHP %s\n' "$((i + 1))" "${AVAILABLE_PHP_VERSIONS[$i]}"
    done
    while true; do
        read -r -p "选择 [1-${#AVAILABLE_PHP_VERSIONS[@]}]：" choice
        [[ "$choice" =~ ^[0-9]+$ ]] || continue
        ((choice >= 1 && choice <= ${#AVAILABLE_PHP_VERSIONS[@]})) || continue
        PHP_VERSION="${AVAILABLE_PHP_VERSIONS[$((choice - 1))]}"
        break
    done

    read -r -p "站点标题 [$DOMAIN]：" SITE_TITLE
    SITE_TITLE="${SITE_TITLE:-$DOMAIN}"
    while true; do
        read -r -p "管理员邮箱：" ADMIN_EMAIL
        validate_email "$ADMIN_EMAIL" && break
        log_message WARNING "邮箱格式不正确"
    done
    read -r -p "管理员用户名 [wpadmin]：" ADMIN_USER
    ADMIN_USER="${ADMIN_USER:-wpadmin}"
    [[ "$ADMIN_USER" =~ ^[a-zA-Z0-9_.-]{4,60}$ ]] || die "管理员用户名格式无效"
    collect_yes_no "是否安装 WooCommerce？" no && USE_WOOCOMMERCE=yes || USE_WOOCOMMERCE=no
    save_site_config
}

memory_mb() {
    awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo
}

calculate_resource_budget() {
    local total_mem os_reserve available php_budget process_memory
    total_mem="$(memory_mb)"
    ((total_mem >= 1024)) || die "稳定运行至少需要 1GB 内存；当前为 ${total_mem}MB"
    os_reserve=$((total_mem * 25 / 100))
    ((os_reserve < 384)) && os_reserve=384
    MARIADB_BUFFER_MB=$((total_mem * 35 / 100))
    ((MARIADB_BUFFER_MB < 256)) && MARIADB_BUFFER_MB=256
    ((MARIADB_BUFFER_MB > 6144)) && MARIADB_BUFFER_MB=6144
    REDIS_MAX_MEMORY_MB=$((total_mem * 5 / 100))
    ((REDIS_MAX_MEMORY_MB < 32)) && REDIS_MAX_MEMORY_MB=32
    ((REDIS_MAX_MEMORY_MB > 512)) && REDIS_MAX_MEMORY_MB=512
    available=$((total_mem - os_reserve - MARIADB_BUFFER_MB - REDIS_MAX_MEMORY_MB - 32))
    php_budget=$available
    ((php_budget > total_mem * 35 / 100)) && php_budget=$((total_mem * 35 / 100))
    ((php_budget < 192)) && php_budget=192
    process_memory=96
    PHP_MAX_CHILDREN=$((php_budget / process_memory))
    ((PHP_MAX_CHILDREN < 2)) && PHP_MAX_CHILDREN=2
    ((PHP_MAX_CHILDREN > 80)) && PHP_MAX_CHILDREN=80
    PHP_MEMORY_LIMIT="256M"
    ((total_mem >= 4096)) && PHP_MEMORY_LIMIT="512M"

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
    log_message INFO "资源预算：系统预留 ${os_reserve}MB，MariaDB ${MARIADB_BUFFER_MB}MB，Redis ${REDIS_MAX_MEMORY_MB}MB，PHP-FPM 最多 $PHP_MAX_CHILDREN 个进程"
}

check_capacity() {
    local available_gb
    calculate_resource_budget
    available_gb="$(df -Pm / | awk 'NR == 2 {print int($4 / 1024)}')"
    ((available_gb >= 8)) || die "根分区至少需要 8GB 可用空间；当前约 ${available_gb}GB"
}

apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Use-Pty=0 install -y --no-install-recommends "$@"
}

ensure_php_repository() {
    if ! apt-cache show "php${PHP_VERSION}-fpm" >/dev/null 2>&1; then
        apt_install software-properties-common ca-certificates gnupg
        add-apt-repository -y ppa:ondrej/php
        apt-get update
    fi
}

install_wp_cli() {
    local current_version="" temp_file url
    if command -v wp >/dev/null 2>&1; then
        current_version="$(wp --allow-root cli version 2>/dev/null | awk '{print $2}' || true)"
    fi
    [[ "$current_version" == "$WP_CLI_VERSION" ]] && return
    temp_file="$(mktemp /tmp/wp-cli.XXXXXX.phar)"
    url="https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar"
    curl --fail --location --retry 3 --proto '=https' --tlsv1.2 --output "$temp_file" "$url"
    php "$temp_file" --info >/dev/null
    install -o root -g root -m 0755 "$temp_file" /usr/local/bin/wp
    rm -f "$temp_file"
}

install_system_packages() {
    CURRENT_STEP="安装系统软件包"
    apt-get update
    apt_install ca-certificates curl openssl unzip rsync dnsutils sudo nginx mariadb-server mariadb-client redis-server certbot fail2ban ufw
    ensure_php_repository
    apt_install \
        "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-cli" "php${PHP_VERSION}-mysql" \
        "php${PHP_VERSION}-curl" "php${PHP_VERSION}-gd" "php${PHP_VERSION}-mbstring" \
        "php${PHP_VERSION}-xml" "php${PHP_VERSION}-zip" "php${PHP_VERSION}-intl" \
        "php${PHP_VERSION}-bcmath" "php${PHP_VERSION}-imagick" "php${PHP_VERSION}-redis"
    install_wp_cli
}

configure_php() {
    CURRENT_STEP="配置 PHP-FPM"
    calculate_resource_budget
    local start_servers min_spare max_spare
    start_servers=$((PHP_MAX_CHILDREN / 4)); ((start_servers < 1)) && start_servers=1
    min_spare=$((PHP_MAX_CHILDREN / 4)); ((min_spare < 1)) && min_spare=1
    max_spare=$((PHP_MAX_CHILDREN / 2)); ((max_spare < 2)) && max_spare=2
    cat > "/etc/php/$PHP_VERSION/fpm/pool.d/99-wp-shell.conf" <<EOF
[www]
pm = dynamic
pm.max_children = $PHP_MAX_CHILDREN
pm.start_servers = $start_servers
pm.min_spare_servers = $min_spare
pm.max_spare_servers = $max_spare
pm.max_requests = 500
request_terminate_timeout = 300s
request_slowlog_timeout = 5s
slowlog = /var/log/php${PHP_VERSION}-fpm-slow.log
catch_workers_output = yes
EOF
    cat > "/etc/php/$PHP_VERSION/fpm/conf.d/99-wp-shell.ini" <<EOF
memory_limit = $PHP_MEMORY_LIMIT
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
    "php-fpm${PHP_VERSION}" -t
    systemctl enable "php${PHP_VERSION}-fpm"
    systemctl restart "php${PHP_VERSION}-fpm"
}

configure_mariadb() {
    CURRENT_STEP="配置 MariaDB"
    calculate_resource_budget
    local config_file backup_file temp_file
    config_file="/etc/mysql/mariadb.conf.d/60-wp-single.cnf"
    backup_file="$config_file.previous"
    temp_file="$(mktemp /etc/mysql/mariadb.conf.d/.wp-single.XXXXXX)"
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
slow_query_log_file = /var/log/mysql/wp-single-slow.log
long_query_time = 2
EOF
    [[ -f "$config_file" ]] && cp -a "$config_file" "$backup_file"
    install -o root -g root -m 0644 "$temp_file" "$config_file"
    rm -f "$temp_file"
    if ! systemctl restart mariadb; then
        if [[ -f "$backup_file" ]]; then mv -f "$backup_file" "$config_file"; else rm -f "$config_file"; fi
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
    local config_file override_dir override_file config_backup="" override_backup=""
    config_file="/etc/redis/wp-single.conf"
    override_dir="/etc/systemd/system/redis-server.service.d"
    override_file="$override_dir/wp-shell.conf"
    [[ -f "$config_file" ]] && config_backup="$(mktemp /tmp/wp-single-redis.XXXXXX)" && cp -a "$config_file" "$config_backup"
    [[ -f "$override_file" ]] && override_backup="$(mktemp /tmp/wp-single-redis-override.XXXXXX)" && cp -a "$override_file" "$override_backup"
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
        if [[ -n "$config_backup" ]]; then cp -a "$config_backup" "$config_file"; else rm -f "$config_file"; fi
        if [[ -n "$override_backup" ]]; then cp -a "$override_backup" "$override_file"; else rm -f "$override_file"; fi
        systemctl daemon-reload
        systemctl restart redis-server || true
        rm -f "$config_backup" "$override_backup"
        die "Redis 新配置无法启动，已回滚"
    fi
    rm -f "$config_backup" "$override_backup"
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
    [[ -n "${SSH_CONNECTION:-}" ]] && port="${SSH_CONNECTION##* }"
    if [[ ! "$port" =~ ^[0-9]+$ ]] && command -v sshd >/dev/null 2>&1; then
        port="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}')"
    fi
    [[ "$port" =~ ^[0-9]+$ ]] || port=22
    printf '%s' "$port"
}

configure_firewall() {
    CURRENT_STEP="配置 UFW"
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

configure_sysctl() {
    cat > /etc/sysctl.d/99-wp-single.conf <<'EOF'
# Conservative settings managed by wp-shell.
vm.swappiness = 10
net.core.somaxconn = 4096
EOF
    sysctl --system >/dev/null
}

load_database_config() {
    local record pass_b64
    [[ -f "$DATABASE_CONFIG" ]] || return 1
    IFS='|' read -r record DB_NAME DB_USER pass_b64 < "$DATABASE_CONFIG"
    [[ "$record" == "database" ]] || die "数据库配置损坏"
    [[ "$DB_NAME" =~ ^wp_[a-f0-9]{12}$ ]] || die "数据库名无效"
    [[ "$DB_USER" =~ ^wp_[a-f0-9]{12}$ ]] || die "数据库用户名无效"
    DB_PASSWORD="$(b64_decode "$pass_b64")"
}

ensure_site_database() {
    CURRENT_STEP="创建站点数据库"
    local hash temp_file
    if ! load_database_config; then
        hash="$(printf '%s' "$DOMAIN" | sha256sum | cut -c1-12)"
        DB_NAME="wp_$hash"
        DB_USER="wp_$hash"
        DB_PASSWORD="$(generate_password)"
        temp_file="$(mktemp "$CONFIG_DIR/.database.XXXXXX")"
        printf 'database|%s|%s|%s\n' "$DB_NAME" "$DB_USER" "$(b64_encode "$DB_PASSWORD")" > "$temp_file"
        if [[ $EUID -eq 0 ]]; then
            install -o root -g root -m 0600 "$temp_file" "$DATABASE_CONFIG"
        else
            install -m 0600 "$temp_file" "$DATABASE_CONFIG"
        fi
        rm -f "$temp_file"
    fi
    mariadb --protocol=socket <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
}

server_names() {
    printf '%s' "$DOMAIN"
    [[ "$INCLUDE_WWW" == "yes" ]] && printf ' www.%s' "$DOMAIN"
}

install_nginx_files() {
    local site_temp="$1" cache_temp="${2:-}" site_target cache_target site_backup="" cache_backup=""
    site_target="/etc/nginx/sites-available/$DOMAIN"
    cache_target="/etc/nginx/conf.d/wp-cache-$DOMAIN.conf"
    [[ -f "$site_target" ]] && site_backup="$(mktemp /tmp/nginx-site.XXXXXX)" && cp -a "$site_target" "$site_backup"
    [[ -f "$cache_target" ]] && cache_backup="$(mktemp /tmp/nginx-cache.XXXXXX)" && cp -a "$cache_target" "$cache_backup"
    install -o root -g root -m 0644 "$site_temp" "$site_target"
    if [[ -n "$cache_temp" ]]; then install -o root -g root -m 0644 "$cache_temp" "$cache_target"; else rm -f "$cache_target"; fi
    ln -sfn "$site_target" "/etc/nginx/sites-enabled/$DOMAIN"
    if ! nginx -t; then
        if [[ -n "$site_backup" ]]; then cp -a "$site_backup" "$site_target"; else rm -f "$site_target" "/etc/nginx/sites-enabled/$DOMAIN"; fi
        if [[ -n "$cache_backup" ]]; then cp -a "$cache_backup" "$cache_target"; else rm -f "$cache_target"; fi
        nginx -t || true
        rm -f "$site_backup" "$cache_backup"
        die "Nginx 配置验证失败，已回滚"
    fi
    rm -f "$site_backup" "$cache_backup"
    systemctl enable nginx
    systemctl reload nginx
}

configure_acme_site() {
    CURRENT_STEP="配置 ACME 临时站点"
    local temp_file names
    names="$(server_names)"
    temp_file="$(mktemp /tmp/nginx-acme.XXXXXX)"
    cat > "$temp_file" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $names;
    root /var/www/$DOMAIN/public;
    location ^~ /.well-known/acme-challenge/ { default_type text/plain; try_files \$uri =404; }
    location / { return 503; }
}
EOF
    install_nginx_files "$temp_file"
    rm -f "$temp_file"
}

issue_ssl_certificate() {
    CURRENT_STEP="申请 SSL 证书"
    local -a domains args
    getent ahosts "$DOMAIN" >/dev/null 2>&1 || die "$DOMAIN 尚未解析"
    domains=(-d "$DOMAIN")
    if [[ "$INCLUDE_WWW" == "yes" ]]; then
        getent ahosts "www.$DOMAIN" >/dev/null 2>&1 || die "www.$DOMAIN 尚未解析"
        domains+=(-d "www.$DOMAIN")
    fi
    args=(certonly --webroot --webroot-path "/var/www/$DOMAIN/public" --cert-name "$DOMAIN" --agree-tos --non-interactive --email "$ADMIN_EMAIL" --keep-until-expiring)
    [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]] && args+=(--expand)
    certbot "${args[@]}" "${domains[@]}"
    [[ -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]] || die "证书文件未生成"
}

configure_https_site() {
    CURRENT_STEP="配置 HTTPS 站点"
    local names zone site_temp cache_temp redirect_target
    names="$(server_names)"
    zone="wp_${DOMAIN//[^a-zA-Z0-9]/_}"
    redirect_target="$PRIMARY_DOMAIN"
    site_temp="$(mktemp /tmp/nginx-site.XXXXXX)"
    cache_temp="$(mktemp /tmp/nginx-cache.XXXXXX)"
    cat > "$cache_temp" <<EOF
fastcgi_cache_path $(site_cache_dir) levels=1:2 keys_zone=${zone}:16m inactive=60m max_size=1g use_temp_path=off;
EOF
    cat > "$site_temp" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $names;
    root /var/www/$DOMAIN/public;
    location ^~ /.well-known/acme-challenge/ { default_type text/plain; try_files \$uri =404; }
    location / { return 301 https://$redirect_target\$request_uri; }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $names;
    root /var/www/$DOMAIN/public;
    index index.php index.html;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=15552000" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    client_max_body_size 128M;
    access_log /var/www/$DOMAIN/logs/nginx-access.log;
    error_log /var/www/$DOMAIN/logs/nginx-error.log warn;

    set \$skip_cache 0;
    if (\$request_method = POST) { set \$skip_cache 1; }
    if (\$query_string != "") { set \$skip_cache 1; }
    if (\$request_uri ~* "^/(wp-admin|wp-login.php|wp-cron.php|xmlrpc.php|cart|checkout|my-account|wc-api|feed|sitemap)") { set \$skip_cache 1; }
    if (\$http_cookie ~* "wordpress_logged_in|comment_author|wp-postpass|woocommerce_items_in_cart|woocommerce_cart_hash|wp_woocommerce_session_") { set \$skip_cache 1; }

    location / { try_files \$uri \$uri/ /index.php?\$args; }
    location ~* /(?:uploads|files)/.*\.php$ { deny all; }
    location ~* ^/(?:wp-config\.php|readme\.html|license\.txt)$ { deny all; }
    location ~ /\. { deny all; }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
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
    install -d -o www-data -g www-data -m 0750 "$(site_cache_dir)"
    install_nginx_files "$site_temp" "$cache_temp"
    rm -f "$site_temp" "$cache_temp"
}

install_certbot_hook() {
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

site_cache_dir() {
    printf '/var/www/%s/cache' "$DOMAIN"
}

site_backup_dir() {
    printf '/var/www/%s/backups' "$DOMAIN"
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
    local cache_dir backup_dir
    cache_dir="$(site_cache_dir)"
    backup_dir="$(site_backup_dir)"
    install -d -o www-data -g www-data -m 0750 "$cache_dir"
    install -d -o root -g root -m 0700 "$backup_dir"
    migrate_legacy_backups "$LEGACY_BACKUP_ROOT/$DOMAIN" "$backup_dir"
}

create_site_directories() {
    install -d -o www-data -g www-data -m 0755 "/var/www/$DOMAIN/public"
    install -d -o www-data -g www-data -m 0750 "/var/www/$DOMAIN/logs"
    ensure_site_storage
}

set_site_permissions() {
    local wp_path="/var/www/$DOMAIN/public"
    chown -R www-data:www-data "$wp_path" "/var/www/$DOMAIN/logs"
    find "$wp_path" -type d -exec chmod 0755 {} +
    find "$wp_path" -type f -exec chmod 0644 {} +
    [[ -f "$wp_path/wp-config.php" ]] && chmod 0640 "$wp_path/wp-config.php"
    chmod 0750 "/var/www/$DOMAIN/logs"
}

install_wordpress() {
    CURRENT_STEP="安装 WordPress"
    local wp_path admin_password credentials_file
    wp_path="/var/www/$DOMAIN/public"
    load_or_create_redis_secret
    if [[ ! -f "$wp_path/wp-load.php" ]]; then
        sudo -u www-data wp core download --path="$wp_path" --locale="$WORDPRESS_LOCALE"
    fi
    if [[ ! -f "$wp_path/wp-config.php" ]]; then
        load_database_config
        printf '%s\n' "$DB_PASSWORD" | sudo -u www-data wp config create --path="$wp_path" --dbname="$DB_NAME" --dbuser="$DB_USER" --dbhost=localhost --dbprefix=wp_ --dbcharset=utf8mb4 --prompt=dbpass
    fi
    sudo -u www-data wp config set FORCE_SSL_ADMIN true --raw --path="$wp_path"
    sudo -u www-data wp config set DISALLOW_FILE_EDIT true --raw --path="$wp_path"
    sudo -u www-data wp config set WP_CACHE true --raw --path="$wp_path"
    sudo -u www-data wp config set WP_REDIS_HOST 127.0.0.1 --path="$wp_path"
    sudo -u www-data wp config set WP_REDIS_PORT 6379 --raw --path="$wp_path"
    sudo -u www-data wp config set WP_REDIS_PASSWORD "$REDIS_PASSWORD" --path="$wp_path"
    sudo -u www-data wp config set WP_REDIS_DATABASE 0 --raw --path="$wp_path"
    sudo -u www-data wp config set WP_REDIS_PREFIX "${DOMAIN}:" --path="$wp_path"
    sudo -u www-data wp config set WP_MEMORY_LIMIT "$PHP_MEMORY_LIMIT" --path="$wp_path"
    if ! sudo -u www-data wp core is-installed --path="$wp_path" >/dev/null 2>&1; then
        admin_password="$(generate_password)"
        printf '%s\n' "$admin_password" | sudo -u www-data wp core install --path="$wp_path" --url="https://$PRIMARY_DOMAIN" --title="$SITE_TITLE" --admin_user="$ADMIN_USER" --admin_email="$ADMIN_EMAIL" --skip-email --prompt=admin_password
        credentials_file="/root/wordpress-single-credentials-$DOMAIN.txt"
        {
            printf 'WordPress 单站点凭据\n'
            printf '生成时间：%s\n' "$(date --iso-8601=seconds)"
            printf '登录地址：https://%s/wp-admin/\n' "$PRIMARY_DOMAIN"
            printf '管理员：%s\n' "$ADMIN_USER"
            printf '管理员密码：%s\n' "$admin_password"
            printf '管理员邮箱：%s\n' "$ADMIN_EMAIL"
        } > "$credentials_file"
        chmod 0600 "$credentials_file"
    fi
    sudo -u www-data wp rewrite structure '/%postname%/' --hard --path="$wp_path"
    sudo -u www-data wp plugin install redis-cache --activate --path="$wp_path"
    sudo -u www-data wp redis enable --path="$wp_path"
    if [[ "$USE_WOOCOMMERCE" == "yes" ]]; then
        sudo -u www-data wp plugin install woocommerce --activate --path="$wp_path"
    fi
    sudo -u www-data wp plugin delete hello akismet --path="$wp_path" 2>/dev/null || true
    set_site_permissions
}

create_mysql_defaults_file() {
    local wp_path="/var/www/$DOMAIN/public" defaults_file db_user db_password db_host escaped_password
    defaults_file="$(mktemp /run/wp-single-mysql.XXXXXX)"
    db_user="$(sudo -u www-data wp config get DB_USER --path="$wp_path")"
    db_password="$(sudo -u www-data wp config get DB_PASSWORD --path="$wp_path")"
    db_host="$(sudo -u www-data wp config get DB_HOST --path="$wp_path")"
    escaped_password="${db_password//\\/\\\\}"
    escaped_password="${escaped_password//\"/\\\"}"
    {
        printf '[client]\nuser=%s\npassword="%s"\nhost=%s\n' "$db_user" "$escaped_password" "$db_host"
    } > "$defaults_file"
    chmod 0600 "$defaults_file"
    printf '%s' "$defaults_file"
}

backup_site() {
    CURRENT_STEP="备份站点"
    local wp_path timestamp root temp_dir final_dir defaults_file db_name
    wp_path="/var/www/$DOMAIN/public"
    [[ -f "$wp_path/wp-config.php" ]] || die "WordPress 尚未安装"
    timestamp="$(date +%Y%m%d-%H%M%S)"
    ensure_site_storage
    root="$(site_backup_dir)"
    temp_dir="$(mktemp -d "$root/.incomplete.XXXXXX")"
    final_dir="$root/$timestamp"
    defaults_file="$(create_mysql_defaults_file)"
    db_name="$(sudo -u www-data wp config get DB_NAME --path="$wp_path")"
    if ! tar --exclude='./wp-content/cache/*' --exclude='./wp-content/uploads/cache/*' -czf "$temp_dir/files.tar.gz" -C "$wp_path" .; then
        rm -rf -- "$temp_dir"; rm -f "$defaults_file"; die "文件备份失败"
    fi
    if ! mariadb-dump --defaults-extra-file="$defaults_file" --single-transaction --quick --routines --triggers --add-drop-table "$db_name" | gzip -9 > "$temp_dir/database.sql.gz"; then
        rm -rf -- "$temp_dir"; rm -f "$defaults_file"; die "数据库备份失败"
    fi
    rm -f "$defaults_file"
    printf 'domain=%s\ncreated_at=%s\nwordpress_version=%s\n' "$DOMAIN" "$(date --iso-8601=seconds)" "$(sudo -u www-data wp core version --path="$wp_path")" > "$temp_dir/manifest.txt"
    (cd "$temp_dir" && sha256sum files.tar.gz database.sql.gz manifest.txt > SHA256SUMS)
    mv "$temp_dir" "$final_dir"
    find "$root" -mindepth 1 -maxdepth 1 -type d -name '20??????-??????' -mtime "+$BACKUP_RETENTION_DAYS" -exec rm -rf -- {} +
    log_message SUCCESS "备份完成：$final_dir"
}

list_backups() {
    local backup_dir
    ensure_site_storage
    backup_dir="$(site_backup_dir)"
    printf '可用备份：\n'
    find "$backup_dir" -mindepth 1 -maxdepth 1 -type d -name '20??????-??????' -printf '  %f\n' 2>/dev/null | sort -r || true
}

clear_cache() {
    local wp_path="/var/www/$DOMAIN/public" cache_dir legacy_cache_dir
    cache_dir="$(site_cache_dir)"
    legacy_cache_dir="$LEGACY_CACHE_ROOT/$DOMAIN"
    [[ -d "$cache_dir" ]] && find "$cache_dir" -mindepth 1 -delete
    [[ -d "$legacy_cache_dir" ]] && find "$legacy_cache_dir" -mindepth 1 -delete
    if [[ -f "$wp_path/wp-config.php" ]]; then
        sudo -u www-data wp cache flush --path="$wp_path" || true
    fi
    systemctl reload "php${PHP_VERSION}-fpm"
}

restore_site() {
    CURRENT_STEP="恢复站点"
    local backup_id="$1" wp_path backup_dir defaults_file db_name
    [[ "$backup_id" =~ ^20[0-9]{6}-[0-9]{6}$ ]] || die "备份编号格式无效"
    wp_path="/var/www/$DOMAIN/public"
    ensure_site_storage
    backup_dir="$(site_backup_dir)/$backup_id"
    [[ -d "$backup_dir" ]] || die "备份不存在：$backup_dir"
    (cd "$backup_dir" && sha256sum --check SHA256SUMS)
    log_message INFO "恢复前创建安全备份"
    backup_site >/dev/null
    defaults_file="$(create_mysql_defaults_file)"
    db_name="$(sudo -u www-data wp config get DB_NAME --path="$wp_path")"
    (
        set -Eeuo pipefail
        local_stage="$(mktemp -d /tmp/wp-single-restore.XXXXXX)"
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
        set_site_permissions
    )
    clear_cache
    log_message SUCCESS "已恢复到 $backup_id"
}

site_status() {
    local code wp_path="/var/www/$DOMAIN/public"
    code="$(curl --silent --show-error --output /dev/null --max-time 8 --write-out '%{http_code}' "https://$PRIMARY_DOMAIN" 2>/dev/null || true)"
    printf '域名：%s\n' "$PRIMARY_DOMAIN"
    printf 'HTTPS：%s\n' "${code:-000}"
    printf 'Nginx：%s\n' "$(systemctl is-active nginx 2>/dev/null || true)"
    printf 'PHP-FPM：%s\n' "$(systemctl is-active "php${PHP_VERSION}-fpm" 2>/dev/null || true)"
    printf 'MariaDB：%s\n' "$(systemctl is-active mariadb 2>/dev/null || true)"
    printf 'Redis：%s\n' "$(systemctl is-active redis-server 2>/dev/null || true)"
    [[ -f "$wp_path/wp-config.php" ]] && printf 'WordPress：%s\n' "$(sudo -u www-data wp core version --path="$wp_path")"
}

update_site() {
    local wp_path="/var/www/$DOMAIN/public"
    backup_site >/dev/null
    sudo -u www-data wp core update --path="$wp_path"
    sudo -u www-data wp core update-db --path="$wp_path"
    sudo -u www-data wp plugin update --all --path="$wp_path"
    sudo -u www-data wp theme update --all --path="$wp_path"
    clear_cache
}

install_management_commands() {
    if [[ "$SCRIPT_PATH" != "$MANAGED_SCRIPT" ]] && ! cmp -s "$SCRIPT_PATH" "$MANAGED_SCRIPT" 2>/dev/null; then
        install -o root -g root -m 0755 "$SCRIPT_PATH" "$MANAGED_SCRIPT"
    fi
    cat > "/usr/local/bin/manage-$DOMAIN" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ \$EUID -eq 0 ]]; then
    exec $MANAGED_SCRIPT manage "\$@"
fi
exec sudo $MANAGED_SCRIPT manage "\$@"
EOF
    chmod 0755 "/usr/local/bin/manage-$DOMAIN"
}

install_backup_timer() {
    cat > /etc/systemd/system/wp-single-backup.service <<EOF
[Unit]
Description=Back up the WordPress site managed by wp-shell
After=mariadb.service

[Service]
Type=oneshot
ExecStart=$MANAGED_SCRIPT manage backup
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF
    cat > /etc/systemd/system/wp-single-backup.timer <<'EOF'
[Unit]
Description=Daily single-site WordPress backup

[Timer]
OnCalendar=*-*-* 02:00:00
RandomizedDelaySec=20m
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now wp-single-backup.timer
}

security_scan() {
    local failed=0 wp_config perms
    for service in nginx mariadb redis-server fail2ban "php${PHP_VERSION}-fpm"; do
        systemctl is-active --quiet "$service" || { log_message ERROR "$service 未运行"; failed=$((failed + 1)); }
    done
    nginx -t || failed=$((failed + 1))
    fail2ban-client -t || failed=$((failed + 1))
    wp_config="/var/www/$DOMAIN/public/wp-config.php"
    if [[ -f "$wp_config" ]]; then
        perms="$(stat -c '%a' "$wp_config")"
        [[ "$perms" == "640" || "$perms" == "600" ]] || { log_message WARNING "$wp_config 权限为 $perms"; failed=$((failed + 1)); }
    fi
    [[ -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]] || { log_message ERROR "SSL 证书不存在"; failed=$((failed + 1)); }
    if ((failed == 0)); then
        log_message SUCCESS "安全检查通过"
    else
        die "安全检查发现 $failed 个问题"
    fi
}

manage_command() {
    local action="${1:-status}"
    load_site_config || die "未找到已部署站点配置"
    case "$action" in
        status|info) site_status ;;
        cache-clear) clear_cache; log_message SUCCESS "缓存已清理" ;;
        backup) backup_site ;;
        backups) list_backups ;;
        restore) [[ -n "${2:-}" ]] || die "用法：manage-$DOMAIN restore BACKUP_ID"; restore_site "$2" ;;
        update) update_site ;;
        optimize) configure_mariadb; configure_redis; configure_php ;;
        security-scan) security_scan ;;
        restart) systemctl restart nginx "php${PHP_VERSION}-fpm" mariadb redis-server ;;
        *) die "未知操作：$action（支持 status/info/cache-clear/backup/backups/restore/update/optimize/security-scan/restart）" ;;
    esac
}

deploy() {
    check_capacity
    install_system_packages
    configure_mariadb
    configure_redis
    configure_php
    configure_fail2ban
    configure_sysctl
    create_site_directories
    if [[ ! -f "/var/www/$DOMAIN/public/wp-config.php" ]]; then
        ensure_site_database
    fi
    rm -f /etc/nginx/sites-enabled/default
    systemctl enable --now nginx
    if [[ ! -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" || ! -f "/etc/nginx/sites-available/$DOMAIN" ]]; then
        configure_acme_site
    fi
    issue_ssl_certificate
    configure_https_site
    install_certbot_hook
    install_wordpress
    install_management_commands
    install_backup_timer
    if collect_yes_no "是否启用并配置 UFW？现有规则会保留" yes; then
        configure_firewall
    fi
    log_message SUCCESS "部署完成：https://$PRIMARY_DOMAIN"
    log_message INFO "管理员凭据：/root/wordpress-single-credentials-$DOMAIN.txt"
    log_message INFO "管理命令：manage-$DOMAIN status"
}

show_help() {
    cat <<EOF
单站点 WordPress 部署脚本 v$VERSION

用法：
  sudo $0                         首次部署或幂等重配
  sudo $0 --reconfigure           使用现有安全配置重新应用部署
  sudo $0 manage ACTION [ARG]     执行站点管理操作
  $0 --version                    显示版本

ACTION：status、info、cache-clear、backup、backups、restore、update、optimize、security-scan、restart
EOF
}

main() {
    case "${1:-}" in
        --help|-h) show_help; return ;;
        --version|-v) printf 'deploy-single-wordpress %s\n' "$VERSION"; return ;;
    esac
    ensure_root "$@"
    init_runtime
    check_platform

    case "${1:-}" in
        manage) manage_command "${2:-status}" "${3:-}" ;;
        --reconfigure)
            load_site_config || die "没有可重配的站点"
            deploy
            ;;
        "")
            if load_site_config; then
                collect_yes_no "检测到 $PRIMARY_DOMAIN 的现有配置，是否幂等重配？" no || return 0
            else
                collect_site_input
            fi
            deploy
            ;;
        *) die "未知参数：$1；使用 --help 查看帮助" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
