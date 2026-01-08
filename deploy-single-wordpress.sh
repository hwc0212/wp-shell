#!/bin/bash

# ======================================================================
# 单WordPress站点高性能部署脚本 (极致性能版)
# ======================================================================
# 版本: 1.0
# 最后更新: 2026-01-08
# 适用系统: Ubuntu 20.04/22.04/24.04
# 核心目标: VPS所有资源专用于单个WordPress站点，实现极致性能
# ======================================================================

set -e  # 任何命令失败立即退出

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 全局变量 ---
SCRIPT_NAME="deploy-single-wordpress.sh"
LOG_FILE="/var/log/wp-single-deploy-$(date +%Y%m%d-%H%M%S).log"
STATE_FILE="/tmp/wp-single-deploy.state"
PHP_VERSION=""
MARIADB_VERSION="10.11"
USE_WOOCOMMERCE="no"
AVAILABLE_PHP_VERSIONS=("8.2" "8.3" "8.4")

# --- 站点配置变量 ---
DOMAIN=""
PRIMARY_DOMAIN=""
ALT_DOMAIN=""
SITE_TITLE=""
ADMIN_EMAIL=""
ADMIN_USER=""
ADMIN_PASS=""
MYSQL_ROOT_PASS=""
WP_DB_NAME=""
WP_DB_USER=""
WP_DB_PASS=""
REDIS_PASS=""

# --- 初始化函数 ---
init_script() {
    echo -e "${CYAN}[INFO]${NC} 单WordPress站点高性能部署脚本启动"
    
    # 检查root权限
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[错误]${NC} 请使用root用户或sudo运行此脚本"
        exit 1
    fi
    
    # 检查Ubuntu系统
    if ! command -v lsb_release &> /dev/null || ! lsb_release -i | grep -q "Ubuntu"; then
        echo -e "${RED}[错误]${NC} 此脚本仅适用于Ubuntu系统"
        exit 1
    fi
    
    # 检查Ubuntu版本
    UBUNTU_VERSION=$(lsb_release -rs)
    if [[ "$UBUNTU_VERSION" != "20.04" ]] && [[ "$UBUNTU_VERSION" != "22.04" ]] && [[ "$UBUNTU_VERSION" != "24.04" ]]; then
        echo -e "${YELLOW}[警告]${NC} 此脚本主要测试于 Ubuntu 20.04/22.04/24.04，当前版本 $UBUNTU_VERSION 可能存在问题"
        read -rp "是否继续? (y/n): " CONTINUE
        if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # 创建日志文件
    touch "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE")
    exec 2> >(tee -a "$LOG_FILE" >&2)
}

# --- 日志函数 ---
log_message() {
    local type="$1"
    local message="$2"
    local color=""
    
    case "$type" in
        "ERROR") color="$RED" ;;
        "SUCCESS") color="$GREEN" ;;
        "WARNING") color="$YELLOW" ;;
        "INFO") color="$CYAN" ;;
        "TASK") color="$BLUE" ;;
        *) color="$NC" ;;
    esac
    
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${color}[${type}]${NC} ${message}"
}

# --- 状态管理 ---
load_progress() {
    local step="$1"
    if [[ -f "$STATE_FILE" ]] && grep -q "^$step$" "$STATE_FILE"; then
        return 0
    fi
    return 1
}

mark_complete() {
    local step="$1"
    echo "$step" >> "$STATE_FILE"
}

# --- 密码生成 ---
generate_password() {
    openssl rand -base64 32 | tr -d '=+/' | head -c 24
}

# --- 用户输入收集 ---
collect_input() {
    if load_progress "collect_input"; then
        log_message "INFO" "用户输入已收集，跳过..."
        return
    fi
    
    echo -e "\n${CYAN}=== 单WordPress站点高性能部署配置 ===${NC}\n"
    echo -e "${YELLOW}注意: 此脚本将VPS的所有资源专用于单个WordPress站点，以实现极致性能${NC}\n"
    
    # 域名配置
    while true; do
        read -rp "请输入主域名 (例如: example.com): " DOMAIN
        if [[ "$DOMAIN" =~ ^[a-zA-Z0-9]+([-.]?[a-zA-Z0-9]+)*\.[a-zA-Z]{2,}$ ]]; then
            break
        else
            echo -e "${RED}[错误]${NC} 域名格式不正确"
        fi
    done
    
    # WWW偏好
    echo -e "\n请选择主访问地址格式:"
    echo "1) 带www (www.${DOMAIN})"
    echo "2) 不带www (${DOMAIN}) [推荐]"
    read -rp "请选择 [1/2]: " WWW_CHOICE
    
    if [[ "$WWW_CHOICE" == "1" ]]; then
        PRIMARY_DOMAIN="www.$DOMAIN"
        ALT_DOMAIN="$DOMAIN"
    else
        PRIMARY_DOMAIN="$DOMAIN"
        ALT_DOMAIN="www.$DOMAIN"
    fi
    
    # PHP版本选择
    echo -e "\n请选择PHP版本:"
    for i in "${!AVAILABLE_PHP_VERSIONS[@]}"; do
        echo "$((i+1))) PHP ${AVAILABLE_PHP_VERSIONS[i]}"
    done
    
    while true; do
        read -rp "请选择 [1-${#AVAILABLE_PHP_VERSIONS[@]}]: " PHP_CHOICE
        
        if [[ "$PHP_CHOICE" =~ ^[0-9]+$ ]] && 
           [[ "$PHP_CHOICE" -ge 1 ]] && 
           [[ "$PHP_CHOICE" -le "${#AVAILABLE_PHP_VERSIONS[@]}" ]]; then
            PHP_VERSION="${AVAILABLE_PHP_VERSIONS[$((PHP_CHOICE-1))]}"
            break
        else
            echo -e "${RED}[错误]${NC} 请选择有效的PHP版本"
        fi
    done
    
    # 站点信息
    read -rp "请输入站点标题: " SITE_TITLE
    read -rp "请输入管理员邮箱: " ADMIN_EMAIL
    
    while true; do
        read -rp "请输入管理员用户名: " ADMIN_USER
        if [[ "$ADMIN_USER" =~ ^[a-zA-Z0-9_]{4,}$ ]]; then
            break
        else
            echo -e "${RED}[错误]${NC} 用户名必须至少4个字符，只能包含字母、数字和下划线"
        fi
    done
    
    # WooCommerce选项
    echo -e "\n是否安装WooCommerce（电商网站）？这将启用电商专用优化配置。"
    read -rp "请选择 (y/n): " WOO_CHOICE
    if [[ "$WOO_CHOICE" =~ ^[Yy]$ ]]; then
        USE_WOOCOMMERCE="yes"
    else
        USE_WOOCOMMERCE="no"
    fi
    
    # 确认信息
    echo -e "\n${YELLOW}=== 配置摘要 ===${NC}"
    echo "主域名: $PRIMARY_DOMAIN"
    echo "备用域名: $ALT_DOMAIN"
    echo "PHP版本: $PHP_VERSION"
    echo "站点标题: $SITE_TITLE"
    echo "管理员用户名: $ADMIN_USER"
    echo "管理员邮箱: $ADMIN_EMAIL"
    echo "MariaDB版本: $MARIADB_VERSION"
    echo "WooCommerce模式: $USE_WOOCOMMERCE"
    echo "性能模式: 极致性能 (VPS所有资源专用)"
    
    read -rp "确认以上配置? (y/n): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        log_message "INFO" "用户取消部署"
        exit 0
    fi
    
    # 生成密码
    MYSQL_ROOT_PASS=$(generate_password)
    WP_DB_NAME="wp_$(echo "$DOMAIN" | tr -cd 'a-zA-Z0-9' | head -c 16)"
    WP_DB_USER="wp_${WP_DB_NAME:3:8}"
    WP_DB_PASS=$(generate_password)
    ADMIN_PASS=$(generate_password)
    REDIS_PASS=$(generate_password)
    
    mark_complete "collect_input"
}

# --- 系统优化 (极致性能版) ---
system_optimization() {
    if load_progress "system_optimization"; then
        log_message "INFO" "系统优化已完成，跳过..."
        return
    fi
    
    log_message "TASK" "执行极致性能系统优化..."
    
    # 更新系统
    apt update && apt upgrade -y
    log_message "SUCCESS" "系统更新完成"
    
    # 安装基础工具
    apt install -y curl wget git nano htop net-tools software-properties-common \
                   apt-transport-https ca-certificates gnupg lsb-release \
                   unzip zip
    log_message "SUCCESS" "基础工具安装完成"
    
    # 获取系统内存信息
    local total_mem=$(free -m | awk '/^Mem:/{print $2}')
    local cpu_cores=$(nproc)
    
    log_message "INFO" "系统资源: ${total_mem}MB内存, ${cpu_cores}核CPU"
    
    # 极致性能内核优化
    cat >> /etc/sysctl.conf << EOF
# WordPress单站点极致性能优化参数
net.core.somaxconn = 65536
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 400000
net.ipv4.ip_local_port_range = 1024 65000
fs.file-max = 2000000
vm.swappiness = 1
vm.vfs_cache_pressure = 10
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
EOF
    
    sysctl -p
    log_message "SUCCESS" "极致性能内核参数优化完成"
    
    # 极致性能文件句柄限制
    cat >> /etc/security/limits.conf << EOF
* soft nofile 1000000
* hard nofile 1000000
www-data soft nofile 1000000
www-data hard nofile 1000000
root soft nofile 1000000
root hard nofile 1000000
EOF
    
    # 禁用不必要的服务以节省资源
    systemctl disable snapd 2>/dev/null || true
    systemctl stop snapd 2>/dev/null || true
    
    mark_complete "system_optimization"
}

# --- 安装Nginx (极致性能版) ---
install_nginx() {
    if load_progress "install_nginx"; then
        log_message "INFO" "Nginx已安装，跳过..."
        return
    fi
    
    log_message "TASK" "安装Nginx (极致性能版)..."
    
    # 安装Nginx
    apt install -y nginx
    
    # 创建站点目录
    mkdir -p /var/www/$DOMAIN/{public,cache/fastcgi,logs,backups}
    
    # 极致性能Nginx配置
    local worker_processes=$(($(nproc) * 2))
    local worker_connections=8192
    
    cat > /etc/nginx/nginx.conf << EOF
user www-data;
worker_processes $worker_processes;
worker_rlimit_nofile 1000000;
pid /run/nginx.pid;

events {
    worker_connections $worker_connections;
    multi_accept on;
    use epoll;
    accept_mutex off;
}

http {
    # 基础设置
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 30;
    keepalive_requests 10000;
    types_hash_max_size 2048;
    server_tokens off;
    client_max_body_size 100M;
    client_body_buffer_size 128k;
    client_header_buffer_size 3m;
    large_client_header_buffers 4 256k;
    
    # MIME类型
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    # 日志格式
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for" '
                    'rt=\$request_time uct="\$upstream_connect_time" '
                    'uht="\$upstream_header_time" urt="\$upstream_response_time"';
    
    access_log /var/log/nginx/access.log main buffer=64k flush=5s;
    error_log /var/log/nginx/error.log warn;
    
    # Gzip压缩 (极致优化)
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_min_length 1000;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/json
        application/javascript
        application/xml+rss
        application/atom+xml
        image/svg+xml
        application/x-font-ttf
        application/vnd.ms-fontobject
        font/opentype;
    
    # Brotli压缩 (如果可用)
    # brotli on;
    # brotli_comp_level 6;
    # brotli_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
    
    # 文件缓存 (极致优化)
    open_file_cache max=200000 inactive=20s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;
    
    # FastCGI缓存配置
    fastcgi_cache_path /var/www/$DOMAIN/cache/fastcgi levels=1:2 keys_zone=WORDPRESS:500m inactive=60m max_size=2g;
    fastcgi_cache_key "\$scheme\$request_method\$host\$request_uri";
    fastcgi_cache_use_stale error timeout invalid_header http_500 http_503;
    fastcgi_cache_valid 200 301 302 1h;
    fastcgi_cache_valid 404 1m;
    
    # 服务器配置
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
    
    # 删除默认站点
    rm -f /etc/nginx/sites-enabled/default
    
    systemctl restart nginx
    systemctl enable nginx
    
    log_message "SUCCESS" "Nginx极致性能配置完成"
    mark_complete "install_nginx"
}

# --- 安装PHP (极致性能版) ---
install_php() {
    if load_progress "install_php"; then
        log_message "INFO" "PHP已安装，跳过..."
        return
    fi
    
    log_message "TASK" "安装PHP $PHP_VERSION (极致性能版)..."
    
    # 添加PPA
    add-apt-repository ppa:ondrej/php -y
    apt update
    
    # 安装PHP及扩展
    apt install -y php$PHP_VERSION-fpm php$PHP_VERSION-cli php$PHP_VERSION-mysql \
                   php$PHP_VERSION-redis php$PHP_VERSION-curl php$PHP_VERSION-gd \
                   php$PHP_VERSION-mbstring php$PHP_VERSION-xml php$PHP_VERSION-zip \
                   php$PHP_VERSION-intl php$PHP_VERSION-bcmath php$PHP_VERSION-imagick \
                   php$PHP_VERSION-soap
    
    # 获取系统资源信息
    local total_mem=$(free -m | awk '/^Mem:/{print $2}')
    local cpu_cores=$(nproc)
    
    # 极致性能PHP配置 (使用80%内存)
    local php_memory_limit="512M"
    local max_children=$(( total_mem * 80 / 100 / 128 ))  # 每个进程128MB
    [[ $max_children -lt 10 ]] && max_children=10
    [[ $max_children -gt 200 ]] && max_children=200
    
    local start_servers=$(( max_children / 4 ))
    local min_spare=$(( max_children / 8 ))
    local max_spare=$(( max_children / 2 ))
    
    if [[ "$USE_WOOCOMMERCE" == "yes" ]]; then
        php_memory_limit="1024M"
        max_children=$(( total_mem * 80 / 100 / 256 ))  # 每个进程256MB
        [[ $max_children -lt 5 ]] && max_children=5
        [[ $max_children -gt 100 ]] && max_children=100
    fi
    
    log_message "INFO" "PHP配置: 内存限制${php_memory_limit}, 最大进程${max_children}"
    
    # 配置PHP-FPM (极致性能)
    PHP_FPM_CONF="/etc/php/$PHP_VERSION/fpm/pool.d/www.conf"
    cat > "$PHP_FPM_CONF" << EOF
[www]
user = www-data
group = www-data
listen = /run/php/php$PHP_VERSION-fpm.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
listen.backlog = 65536

pm = dynamic
pm.max_children = $max_children
pm.start_servers = $start_servers
pm.min_spare_servers = $min_spare
pm.max_spare_servers = $max_spare
pm.process_idle_timeout = 10s
pm.max_requests = 1000

pm.status_path = /php-status
ping.path = /php-ping

slowlog = /var/log/php$PHP_VERSION-fpm-slow.log
request_slowlog_timeout = 5s

php_admin_value[error_log] = /var/log/php$PHP_VERSION-fpm-error.log
php_admin_flag[log_errors] = on
php_value[session.save_handler] = files
php_value[session.save_path] = /var/lib/php/sessions
php_value[soap.wsdl_cache_dir] = /var/lib/php/wsdlcache

# 极致性能设置
php_admin_value[memory_limit] = $php_memory_limit
php_admin_value[max_execution_time] = 300
php_admin_value[max_input_time] = 300
php_admin_value[upload_max_filesize] = 100M
php_admin_value[post_max_size] = 100M
php_admin_value[max_file_uploads] = 50
EOF
    
    # 配置php.ini (极致性能)
    PHP_INI="/etc/php/$PHP_VERSION/fpm/php.ini"
    sed -i "s/^memory_limit = .*/memory_limit = $php_memory_limit/" "$PHP_INI"
    sed -i "s/^max_execution_time = .*/max_execution_time = 300/" "$PHP_INI"
    sed -i "s/^max_input_time = .*/max_input_time = 300/" "$PHP_INI"
    sed -i "s/^upload_max_filesize = .*/upload_max_filesize = 100M/" "$PHP_INI"
    sed -i "s/^post_max_size = .*/post_max_size = 100M/" "$PHP_INI"
    sed -i "s/^max_file_uploads = .*/max_file_uploads = 50/" "$PHP_INI"
    sed -i "s/^display_errors = .*/display_errors = Off/" "$PHP_INI"
    sed -i "s/^log_errors = .*/log_errors = On/" "$PHP_INI"
    sed -i "s|^;error_log =.*|error_log = /var/log/php$PHP_VERSION-fpm-error.log|" "$PHP_INI"
    
    # 配置OPcache (极致性能)
    OP_CACHE_FILE="/etc/php/$PHP_VERSION/fpm/conf.d/10-opcache.ini"
    local opcache_memory=$(( total_mem / 4 ))
    [[ $opcache_memory -lt 128 ]] && opcache_memory=128
    [[ $opcache_memory -gt 512 ]] && opcache_memory=512
    
    cat > "$OP_CACHE_FILE" << EOF
zend_extension=opcache.so
opcache.enable=1
opcache.memory_consumption=${opcache_memory}
opcache.interned_strings_buffer=64
opcache.max_accelerated_files=20000
opcache.revalidate_freq=2
opcache.fast_shutdown=1
opcache.enable_cli=1
opcache.save_comments=1
opcache.load_comments=1
opcache.enable_file_override=1
opcache.validate_timestamps=1
opcache.huge_code_pages=1
EOF
    
    # 为PHP 8.3+启用JIT
    if [[ "$PHP_VERSION" == "8.3" ]] || [[ "$PHP_VERSION" == "8.4" ]]; then
        local jit_buffer=$(( opcache_memory / 2 ))
        echo "opcache.jit=1255" >> "$OP_CACHE_FILE"
        echo "opcache.jit_buffer_size=${jit_buffer}M" >> "$OP_CACHE_FILE"
        log_message "INFO" "PHP JIT已启用，缓冲区大小: ${jit_buffer}M"
    fi
    
    # 启动PHP-FPM
    systemctl restart php$PHP_VERSION-fpm
    systemctl enable php$PHP_VERSION-fpm
    
    log_message "SUCCESS" "PHP $PHP_VERSION 极致性能配置完成"
    mark_complete "install_php"
}

# --- 安装MariaDB (极致性能版) ---
install_mariadb() {
    if load_progress "install_mariadb"; then
        log_message "INFO" "MariaDB已安装，跳过..."
        return
    fi
    
    log_message "TASK" "安装MariaDB $MARIADB_VERSION (极致性能版)..."
    
    # 安装MariaDB
    apt install -y mariadb-server mariadb-client
    
    # 获取系统内存信息
    local total_mem=$(free -m | awk '/^Mem:/{print $2}')
    local innodb_percent=70  # 单站点使用70%内存
    
    if [[ "$USE_WOOCOMMERCE" == "yes" ]]; then
        innodb_percent=75  # WooCommerce使用更多内存
    fi
    
    local innodb_size_mb=$(( total_mem * innodb_percent / 100 ))
    local innodb_size_gb=$(( innodb_size_mb / 1024 ))
    [[ $innodb_size_gb -lt 1 ]] && innodb_size_gb=1
    
    local cpu_cores=$(nproc)
    
    log_message "INFO" "MariaDB配置: InnoDB缓冲池${innodb_size_gb}G, CPU核心${cpu_cores}"
    
    # 极致性能MariaDB配置
    cat > /etc/mysql/mariadb.conf.d/50-single-wordpress.cnf << EOF
[mysqld]
# 单WordPress站点极致性能配置

# 内存配置 (使用${innodb_percent}%内存)
innodb_buffer_pool_size = ${innodb_size_gb}G
innodb_log_file_size = 512M
innodb_log_buffer_size = 64M
innodb_buffer_pool_instances = $cpu_cores

# 性能配置
innodb_flush_log_at_trx_commit = 1
innodb_file_per_table = 1
innodb_flush_method = O_DIRECT
innodb_read_io_threads = $cpu_cores
innodb_write_io_threads = $cpu_cores
innodb_io_capacity = 2000
innodb_io_capacity_max = 4000

# 连接配置 (单站点优化)
max_connections = 500
thread_cache_size = 200
table_open_cache = 8192
table_definition_cache = 8192
open_files_limit = 65536

# 查询缓存 (MariaDB 10.11+推荐关闭)
query_cache_type = 0
query_cache_size = 0

# 临时表优化
tmp_table_size = 256M
max_heap_table_size = 256M

# 排序和分组优化
sort_buffer_size = 4M
read_buffer_size = 2M
read_rnd_buffer_size = 8M
join_buffer_size = 8M

# 字符集设置
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

# 二进制日志
log_bin = /var/log/mysql/mysql-bin.log
expire_logs_days = 3
max_binlog_size = 100M
binlog_cache_size = 1M

# 慢查询日志
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 1
log_queries_not_using_indexes = 1

# 错误日志
log_error = /var/log/mysql/error.log

# 性能模式
performance_schema = ON
EOF
    
    # 启动MariaDB
    systemctl start mariadb
    systemctl enable mariadb
    
    # 安全配置
    log_message "INFO" "执行MariaDB安全配置..."
    
    mariadb -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASS';"
    mariadb -u root -p"$MYSQL_ROOT_PASS" -e "DELETE FROM mysql.user WHERE User='';"
    mariadb -u root -p"$MYSQL_ROOT_PASS" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    mariadb -u root -p"$MYSQL_ROOT_PASS" -e "DROP DATABASE IF EXISTS test;"
    mariadb -u root -p"$MYSQL_ROOT_PASS" -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
    mariadb -u root -p"$MYSQL_ROOT_PASS" -e "FLUSH PRIVILEGES;"
    
    # 创建WordPress数据库
    log_message "INFO" "创建WordPress数据库..."
    
    mariadb -u root -p"$MYSQL_ROOT_PASS" -e "CREATE DATABASE IF NOT EXISTS $WP_DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mariadb -u root -p"$MYSQL_ROOT_PASS" -e "CREATE USER IF NOT EXISTS '$WP_DB_USER'@'localhost' IDENTIFIED BY '$WP_DB_PASS';"
    mariadb -u root -p"$MYSQL_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON $WP_DB_NAME.* TO '$WP_DB_USER'@'localhost';"
    mariadb -u root -p"$MYSQL_ROOT_PASS" -e "FLUSH PRIVILEGES;"
    
    # 创建MariaDB配置文件以便无密码访问
    cat > /root/.my.cnf << EOF
[client]
user=root
password=$MYSQL_ROOT_PASS
EOF
    chmod 600 /root/.my.cnf
    
    systemctl restart mariadb
    log_message "SUCCESS" "MariaDB极致性能配置完成"
    mark_complete "install_mariadb"
}

# --- 安装Redis (极致性能版) ---
install_redis() {
    if load_progress "install_redis"; then
        log_message "INFO" "Redis已安装，跳过..."
        return
    fi
    
    log_message "TASK" "安装Redis (极致性能版)..."
    
    apt install -y redis-server php$PHP_VERSION-redis
    
    # 获取系统内存信息
    local total_mem=$(free -m | awk '/^Mem:/{print $2}')
    local redis_max_mem=$(( total_mem * 15 / 100 ))  # 单站点使用15%内存
    [[ $redis_max_mem -lt 256 ]] && redis_max_mem=256
    [[ $redis_max_mem -gt 2048 ]] && redis_max_mem=2048
    
    log_message "INFO" "Redis配置: 最大内存${redis_max_mem}MB"
    
    # 极致性能Redis配置
    REDIS_CONF="/etc/redis/redis.conf"
    cp "$REDIS_CONF" "$REDIS_CONF.backup"
    
    cat > "$REDIS_CONF" << EOF
# Redis单WordPress站点极致性能配置
bind 127.0.0.1
port 6379
timeout 0
tcp-keepalive 300
tcp-backlog 65536

# 安全配置
requirepass $REDIS_PASS

# 内存配置
maxmemory ${redis_max_mem}mb
maxmemory-policy allkeys-lru

# 持久化配置 (性能优先)
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump.rdb
dir /var/lib/redis

# AOF配置
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec
no-appendfsync-on-rewrite no
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb

# 性能优化
hash-max-ziplist-entries 512
hash-max-ziplist-value 64
list-max-ziplist-size -2
list-compress-depth 0
set-max-intset-entries 512
zset-max-ziplist-entries 128
zset-max-ziplist-value 64
hll-sparse-max-bytes 3000

# 客户端配置
maxclients 10000

# 日志配置
loglevel notice
logfile /var/log/redis/redis-server.log
EOF
    
    # 创建日志目录
    mkdir -p /var/log/redis
    chown redis:redis /var/log/redis
    
    systemctl restart redis-server
    systemctl enable redis-server
    
    log_message "SUCCESS" "Redis极致性能配置完成"
    mark_complete "install_redis"
}

# --- 配置防火墙 ---
configure_firewall() {
    if load_progress "configure_firewall"; then
        log_message "INFO" "防火墙已配置，跳过..."
        return
    fi
    
    log_message "TASK" "配置防火墙..."
    
    apt install -y ufw
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    
    # 获取当前SSH端口
    SSH_PORT=$(ss -tlnp | grep sshd | awk '{print $4}' | cut -d':' -f2 | head -1)
    if [[ -n "$SSH_PORT" ]] && [[ "$SSH_PORT" != "22" ]]; then
        ufw allow "$SSH_PORT/tcp"
        log_message "INFO" "已允许SSH端口: $SSH_PORT"
    else
        ufw allow 22/tcp
        log_message "INFO" "已允许默认SSH端口: 22"
    fi
    
    # 允许HTTP/HTTPS
    ufw allow 80/tcp
    ufw allow 443/tcp
    
    echo "y" | ufw enable
    
    log_message "SUCCESS" "防火墙配置完成"
    mark_complete "configure_firewall"
}

# --- 安装Fail2ban ---
install_fail2ban() {
    if load_progress "install_fail2ban"; then
        log_message "INFO" "Fail2ban已安装，跳过..."
        return
    fi
    
    log_message "TASK" "安装Fail2ban..."
    
    apt install -y fail2ban
    
    # 配置Fail2ban
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 3600
findtime = 600
maxretry = 5
destemail = $ADMIN_EMAIL
sender = fail2ban@$DOMAIN

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3

[nginx-http-auth]
enabled = true
port = http,https
filter = nginx-http-auth
logpath = /var/log/nginx/error.log
maxretry = 3

[wordpress]
enabled = true
port = http,https
filter = wordpress
logpath = /var/www/$DOMAIN/logs/nginx-access.log
maxretry = 5
bantime = 86400
findtime = 3600
EOF
    
    # 创建WordPress过滤器
    cat > /etc/fail2ban/filter.d/wordpress.conf << EOF
[Definition]
failregex = ^<HOST>.*"POST.*wp-login.php.*" 200
            ^<HOST>.*"POST.*xmlrpc.php.*" 200
ignoreregex = ^<HOST>.*"POST.*wp-admin/admin-ajax.php.*"
EOF
    
    systemctl restart fail2ban
    systemctl enable fail2ban
    
    log_message "SUCCESS" "Fail2ban安装完成"
    mark_complete "install_fail2ban"
}

# --- 安装Certbot ---
install_certbot() {
    if load_progress "install_certbot"; then
        log_message "INFO" "Certbot已安装，跳过..."
        return
    fi
    
    log_message "TASK" "安装Certbot..."
    
    apt install -y snapd
    systemctl enable --now snapd.socket
    
    # 等待snapd启动
    sleep 5
    
    # 安装Certbot
    snap install --classic certbot
    ln -sf /snap/bin/certbot /usr/bin/certbot
    
    log_message "SUCCESS" "Certbot安装完成"
    mark_complete "install_certbot"
}

# --- 安装WP-CLI ---
install_wpcli() {
    if load_progress "install_wpcli"; then
        log_message "INFO" "WP-CLI已安装，跳过..."
        return
    fi
    
    log_message "TASK" "安装WP-CLI..."
    
    # 下载WP-CLI
    curl -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x /usr/local/bin/wp
    
    # 测试WP-CLI
    if /usr/local/bin/wp --info --allow-root 2>/dev/null | grep -q "WP-CLI"; then
        log_message "SUCCESS" "WP-CLI安装完成"
    else
        log_message "ERROR" "WP-CLI安装失败"
        exit 1
    fi
    
    mark_complete "install_wpcli"
}

# --- 配置Nginx站点 (极致性能版) ---
configure_nginx_site() {
    if load_progress "configure_nginx_site"; then
        log_message "INFO" "Nginx站点配置已完成，跳过..."
        return
    fi
    
    log_message "TASK" "配置Nginx虚拟主机 (极致性能版)..."
    
    # 创建Nginx站点配置
    cat > /etc/nginx/sites-available/$DOMAIN << EOF
# HTTP重定向到HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $PRIMARY_DOMAIN $ALT_DOMAIN;
    
    # 安全头
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    
    # 重定向到HTTPS
    return 301 https://\$host\$request_uri;
}

# HTTPS服务器 (极致性能配置)
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $PRIMARY_DOMAIN $ALT_DOMAIN;
    
    root /var/www/$DOMAIN/public;
    index index.php index.html index.htm;
    
    # SSL证书
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    
    # SSL极致性能优化
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:100m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 8.8.8.8 1.1.1.1 valid=300s;
    resolver_timeout 5s;
    
    # 安全头
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Content-Security-Policy "default-src 'self' https: data: 'unsafe-inline' 'unsafe-eval';" always;
    
    # 日志
    access_log /var/www/$DOMAIN/logs/nginx-access.log main buffer=64k flush=5s;
    error_log /var/www/$DOMAIN/logs/nginx-error.log warn;
    
    # 缓存设置
    set \$skip_cache 0;
    
    # 登录用户绕过缓存
    if (\$http_cookie ~* "wordpress_logged_in") {
        set \$skip_cache 1;
    }
    
    # WooCommerce动态页面
    if (\$request_uri ~* "(/cart/|/checkout/|/my-account/|/wc-api/)") {
        set \$skip_cache 1;
    }
    
    # 后台管理绕过缓存
    if (\$request_uri ~* "(/wp-admin/|/wp-login.php)") {
        set \$skip_cache 1;
    }
    
    # 静态文件缓存 (极致优化)
    location ~* \\.(js|css|png|jpg|jpeg|gif|ico|svg|webp|woff|woff2|ttf|eot|mp4|webm|ogv)\$ {
        expires 1y;
        add_header Cache-Control "public, immutable, max-age=31536000";
        add_header Vary "Accept-Encoding";
        access_log off;
        try_files \$uri =404;
    }
    
    # 安全规则
    location ~ /\\. {
        deny all;
        access_log off;
        log_not_found off;
    }
    
    location ~* /(?:uploads|files)/.*\\.php\$ {
        deny all;
    }
    
    location ~* \\.(ini|log|conf|sql|swp)\$ {
        deny all;
    }
    
    location ~ /(wp-config\\.php|xmlrpc\\.php|wp-config-sample.php|readme.html|license.txt) {
        deny all;
        access_log off;
        log_not_found off;
    }
    
    # PHP状态页
    location ~ ^/(php-status|php-ping)\$ {
        access_log off;
        fastcgi_pass unix:/run/php/php$PHP_VERSION-fpm.sock;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
    
    # PHP处理 (极致性能)
    location ~ \\.php\$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php$PHP_VERSION-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_param HTTPS on;
        
        # FastCGI缓存设置 (极致性能)
        fastcgi_cache WORDPRESS;
        fastcgi_cache_valid 200 301 302 1h;
        fastcgi_cache_valid 404 1m;
        fastcgi_cache_use_stale error timeout updating http_500 http_503;
        fastcgi_cache_background_update on;
        fastcgi_cache_lock on;
        fastcgi_cache_lock_timeout 5s;
        
        fastcgi_no_cache \$skip_cache;
        fastcgi_cache_bypass \$skip_cache;
        
        add_header X-FastCGI-Cache \$upstream_cache_status;
        add_header X-Powered-By "PHP $PHP_VERSION";
        
        # 连接优化
        fastcgi_connect_timeout 60s;
        fastcgi_send_timeout 180s;
        fastcgi_read_timeout 180s;
        fastcgi_buffer_size 128k;
        fastcgi_buffers 4 256k;
        fastcgi_busy_buffers_size 256k;
        fastcgi_temp_file_write_size 256k;
    }
    
    # WordPress重写规则
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
        
        # 启用Gzip压缩
        gzip_static on;
    }
    
    # 限制请求方法
    if (\$request_method !~ ^(GET|HEAD|POST)\$) {
        return 444;
    }
    
    # robots.txt和favicon.ico优化
    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }
    
    location = /favicon.ico {
        log_not_found off;
        access_log off;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
EOF
    
    # 启用站点
    ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
    
    # 测试配置
    nginx -t
    log_message "SUCCESS" "Nginx极致性能配置完成"
    mark_complete "configure_nginx_site"
}

# --- 获取SSL证书 ---
get_ssl_certificate() {
    if load_progress "get_ssl_certificate"; then
        log_message "INFO" "SSL证书已获取，跳过..."
        return
    fi
    
    log_message "TASK" "获取SSL证书..."
    
    # 停止Nginx以释放80端口
    systemctl stop nginx
    sleep 2
    
    # 获取证书
    if certbot certonly --standalone --agree-tos --non-interactive \
        --email "$ADMIN_EMAIL" \
        -d "$PRIMARY_DOMAIN" \
        -d "$ALT_DOMAIN" \
        --preferred-challenges http; then
        log_message "SUCCESS" "SSL证书获取成功"
    else
        log_message "ERROR" "SSL证书获取失败，尝试备用方法..."
        
        # 启动Nginx
        systemctl start nginx
        sleep 2
        
        # 创建webroot目录
        mkdir -p /var/www/$DOMAIN/public/.well-known/acme-challenge
        
        # 使用webroot方式获取证书
        certbot certonly --webroot --agree-tos --non-interactive \
            --email "$ADMIN_EMAIL" \
            -d "$PRIMARY_DOMAIN" \
            -d "$ALT_DOMAIN" \
            --webroot-path /var/www/$DOMAIN/public
            
        if [[ $? -ne 0 ]]; then
            log_message "ERROR" "SSL证书获取完全失败，请手动检查"
            exit 1
        fi
    fi
    
    # 启动Nginx
    systemctl start nginx
    
    # 设置自动续期
    (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook \"systemctl reload nginx\"") | crontab -
    
    log_message "SUCCESS" "SSL证书获取完成"
    mark_complete "get_ssl_certificate"
}

# --- 安装WordPress (极致性能版) ---
install_wordpress() {
    if load_progress "install_wordpress"; then
        log_message "INFO" "WordPress已安装，跳过..."
        return
    fi
    
    log_message "TASK" "安装WordPress (极致性能版)..."
    
    cd /var/www/$DOMAIN/public
    
    # 下载WordPress
    sudo -u www-data wp core download --locale=en_US --version=latest
    
    # 检查下载是否成功
    if [[ ! -f "wp-config-sample.php" ]]; then
        log_message "ERROR" "WordPress下载失败"
        exit 1
    fi
    
    # 创建配置文件 (极致性能配置)
    sudo -u www-data wp config create \
        --dbname="$WP_DB_NAME" \
        --dbuser="$WP_DB_USER" \
        --dbpass="$WP_DB_PASS" \
        --dbhost="localhost" \
        --dbcharset="utf8mb4" \
        --dbcollate="utf8mb4_unicode_ci" \
        --extra-php << 'WPEOF'
// 强制SSL
define('FORCE_SSL_ADMIN', true);
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    $_SERVER['HTTPS'] = 'on';
}

// 禁用文件编辑
define('DISALLOW_FILE_EDIT', true);

// 极致性能内存限制
define('WP_MEMORY_LIMIT', '512M');
define('WP_MAX_MEMORY_LIMIT', '1024M');

// Redis缓存配置
define('WP_REDIS_HOST', '127.0.0.1');
define('WP_REDIS_PORT', 6379);
define('WP_REDIS_TIMEOUT', 1);
define('WP_REDIS_READ_TIMEOUT', 1);
define('WP_REDIS_DATABASE', 0);

// 自动保存优化
define('AUTOSAVE_INTERVAL', 300);
define('WP_POST_REVISIONS', 5);
define('EMPTY_TRASH_DAYS', 7);

// 调试设置
define('WP_DEBUG', false);
define('WP_DEBUG_LOG', true);
define('WP_DEBUG_DISPLAY', false);
define('SCRIPT_DEBUG', false);

// 极致性能优化
define('COMPRESS_CSS', true);
define('COMPRESS_SCRIPTS', true);
define('CONCATENATE_SCRIPTS', true);
define('ENFORCE_GZIP', true);
define('WP_CACHE', true);

// 安全设置
define('DISALLOW_UNFILTERED_HTML', true);
define('FORCE_SSL_LOGIN', true);

// 数据库优化
define('WP_ALLOW_REPAIR', false);
WPEOF
    
    # 添加Redis密码配置
    sudo -u www-data wp config set WP_REDIS_PASSWORD "$REDIS_PASS" --path="/var/www/$DOMAIN/public"
    
    # 获取安全密钥
    local secret_keys=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/ 2>/dev/null || echo "")
    
    if [[ -n "$secret_keys" ]]; then
        echo "$secret_keys" >> wp-config.php
    else
        log_message "WARNING" "无法获取安全密钥，使用本地生成"
        for key in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
            local value=$(openssl rand -base64 48 | tr -d '\n')
            echo "define('$key', '$value');" >> wp-config.php
        done
    fi
    
    # 安装WordPress
    sudo -u www-data wp core install \
        --url="https://$PRIMARY_DOMAIN" \
        --title="$SITE_TITLE" \
        --admin_user="$ADMIN_USER" \
        --admin_password="$ADMIN_PASS" \
        --admin_email="$ADMIN_EMAIL" \
        --skip-email
    
    # 检查安装是否成功
    if [[ $? -ne 0 ]]; then
        log_message "ERROR" "WordPress安装失败"
        exit 1
    fi
    
    # 设置固定链接
    sudo -u www-data wp rewrite structure '/%postname%/' --hard
    
    # 安装Redis缓存插件
    log_message "INFO" "安装Redis对象缓存插件..."
    sudo -u www-data wp plugin install redis-cache --activate
    sudo -u www-data wp redis enable
    
    # 如果启用WooCommerce，安装WooCommerce插件
    if [[ "$USE_WOOCOMMERCE" == "yes" ]]; then
        log_message "INFO" "安装WooCommerce插件..."
        sudo -u www-data wp plugin install woocommerce --activate
        
        # WooCommerce性能优化
        sudo -u www-data wp config set WC_ADMIN_DISABLED true --raw
        sudo -u www-data wp config set WOOCOMMERCE_BLOCKS_PHASE 3 --raw
    fi
    
    # 清理默认内容
    sudo -u www-data wp post delete 1 2 3 --force 2>/dev/null || true
    sudo -u www-data wp plugin delete akismet hello 2>/dev/null || true
    
    log_message "SUCCESS" "WordPress极致性能安装完成"
    mark_complete "install_wordpress"
}

# --- 设置文件权限 ---
set_permissions() {
    if load_progress "set_permissions"; then
        log_message "INFO" "文件权限已设置，跳过..."
        return
    fi
    
    log_message "TASK" "设置文件权限..."
    
    cd /var/www/$DOMAIN
    
    # 设置所有权
    chown -R www-data:www-data .
    
    # 设置目录权限
    find . -type d -exec chmod 755 {} \;
    find . -type f -exec chmod 644 {} \;
    
    # WordPress特定权限
    chmod 640 public/wp-config.php
    chmod -R 775 public/wp-content/uploads/
    chmod -R 775 public/wp-content/cache/
    chmod -R 775 cache/
    chmod -R 775 logs/
    
    # 设置setgid位，确保新文件继承组权限
    chmod g+s public/wp-content/uploads/
    chmod g+s cache/
    chmod g+s logs/
    
    log_message "SUCCESS" "文件权限设置完成"
    mark_complete "set_permissions"
}

# --- 创建管理脚本 ---
create_management_script() {
    if load_progress "create_management_script"; then
        log_message "INFO" "管理脚本已创建，跳过..."
        return
    fi
    
    log_message "TASK" "创建管理脚本..."
    
    cat > /usr/local/bin/manage-$DOMAIN << EOF
#!/bin/bash

# 单WordPress站点管理脚本 - $DOMAIN (极致性能版)
DOMAIN="$DOMAIN"
PHP_VERSION="$PHP_VERSION"
REDIS_PASS="$REDIS_PASS"
WP_DB_NAME="$WP_DB_NAME"
WP_DB_USER="$WP_DB_USER"
WP_DB_PASS="$WP_DB_PASS"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

case "\$1" in
    status)
        echo -e "\${CYAN}=== \$DOMAIN 站点状态 (极致性能版) ===\${NC}"
        echo "PHP版本: \$PHP_VERSION"
        echo "WordPress路径: /var/www/\$DOMAIN/public"
        echo ""
        
        # 检查服务状态
        echo -e "\${BLUE}服务状态:\${NC}"
        systemctl is-active nginx && echo "  Nginx: 运行中" || echo "  Nginx: 未运行"
        systemctl is-active "php\$PHP_VERSION-fpm" && echo "  PHP-FPM: 运行中" || echo "  PHP-FPM: 未运行"
        systemctl is-active mariadb && echo "  MariaDB: 运行中" || echo "  MariaDB: 未运行"
        systemctl is-active redis-server && echo "  Redis: 运行中" || echo "  Redis: 未运行"
        
        # 检查网站访问
        echo -e "\${BLUE}网站状态:\${NC}"
        if curl -I "https://\$DOMAIN" 2>/dev/null | grep -q "200 OK"; then
            echo "  网站访问: 正常"
        else
            echo "  网站访问: 异常"
        fi
        
        # 性能状态
        echo -e "\${BLUE}性能状态:\${NC}"
        local load_avg=\$(uptime | awk -F'load average:' '{print \$2}')
        echo "  系统负载:\$load_avg"
        
        local mem_usage=\$(free -m | awk 'NR==2{printf "%.1f%%", \$3*100/\$2}')
        echo "  内存使用: \$mem_usage"
        
        # 缓存状态
        echo -e "\${BLUE}缓存状态:\${NC}"
        if [[ -d "/var/www/\$DOMAIN/cache/fastcgi" ]]; then
            local cache_files=\$(find "/var/www/\$DOMAIN/cache/fastcgi" -type f | wc -l)
            local cache_size=\$(du -sh "/var/www/\$DOMAIN/cache/fastcgi" 2>/dev/null | cut -f1)
            echo "  FastCGI缓存: \$cache_files 文件, \$cache_size"
        fi
        
        if command -v redis-cli &> /dev/null; then
            local redis_info=\$(redis-cli -a "\$REDIS_PASS" info memory 2>/dev/null | grep used_memory_human | cut -d: -f2 | tr -d '\r')
            echo "  Redis缓存: \$redis_info"
        fi
        ;;
        
    restart)
        echo -e "\${CYAN}重启所有服务...\${NC}"
        systemctl restart nginx "php\$PHP_VERSION-fpm" mariadb redis-server fail2ban
        echo -e "\${GREEN}所有服务重启完成\${NC}"
        ;;
        
    cache-clear)
        echo -e "\${CYAN}清除所有缓存 (极致性能版)...\${NC}"
        
        # 清除FastCGI缓存
        rm -rf "/var/www/\$DOMAIN/cache/fastcgi/*"
        echo "FastCGI缓存已清除"
        
        # 清除Redis缓存
        if command -v redis-cli &> /dev/null; then
            redis-cli -a "\$REDIS_PASS" FLUSHDB >/dev/null 2>&1
            echo "Redis缓存已清除"
        fi
        
        # 清除WordPress缓存
        if [[ -f "/var/www/\$DOMAIN/public/wp-config.php" ]]; then
            sudo -u www-data wp cache flush --path="/var/www/\$DOMAIN/public" 2>/dev/null
            echo "WordPress缓存已清除"
        fi
        
        # 重启PHP-FPM以清除OPcache
        systemctl reload "php\$PHP_VERSION-fpm"
        echo "OPcache已清除"
        
        echo -e "\${GREEN}所有缓存清除完成\${NC}"
        ;;
        
    backup)
        echo -e "\${CYAN}创建站点备份...\${NC}"
        
        local backup_dir="/var/www/\$DOMAIN/backups"
        local timestamp=\$(date +%Y%m%d-%H%M%S)
        
        mkdir -p "\$backup_dir"
        
        # 备份文件
        echo "备份网站文件..."
        tar -czf "\$backup_dir/files-\$timestamp.tar.gz" \\
            --exclude="cache/*" \\
            --exclude="backups/*" \\
            --exclude="logs/*" \\
            -C "/var/www/\$DOMAIN" public
        
        # 备份数据库
        echo "备份数据库..."
        mariadb-dump "\$WP_DB_NAME" --single-transaction --quick --lock-tables=false | gzip > "\$backup_dir/database-\$timestamp.sql.gz"
        
        # 清理旧备份（保留最近7天）
        find "\$backup_dir" -name "*.tar.gz" -mtime +7 -delete
        find "\$backup_dir" -name "*.sql.gz" -mtime +7 -delete
        
        echo -e "\${GREEN}备份完成: \$backup_dir/\${NC}"
        echo "文件备份: files-\$timestamp.tar.gz"
        echo "数据库备份: database-\$timestamp.sql.gz"
        ;;
        
    optimize)
        echo -e "\${CYAN}执行性能优化...\${NC}"
        
        # 优化数据库
        echo "优化数据库..."
        sudo -u www-data wp --path="/var/www/\$DOMAIN/public" db optimize
        
        # 清理WordPress
        echo "清理WordPress..."
        sudo -u www-data wp --path="/var/www/\$DOMAIN/public" transient delete --expired
        sudo -u www-data wp --path="/var/www/\$DOMAIN/public" post delete \$(sudo -u www-data wp --path="/var/www/\$DOMAIN/public" post list --post_type='revision' --format=ids) 2>/dev/null || true
        
        # 重新生成缓存
        echo "重新生成缓存..."
        sudo -u www-data wp --path="/var/www/\$DOMAIN/public" cache flush
        
        # 预热缓存
        echo "预热缓存..."
        curl -s "https://\$DOMAIN" > /dev/null
        curl -s "https://\$DOMAIN/sitemap.xml" > /dev/null 2>&1 || true
        
        echo -e "\${GREEN}性能优化完成\${NC}"
        ;;
        
    monitor)
        echo "实时监控模式启动，按Ctrl+C退出..."
        echo "时间,负载,内存,磁盘,连接,缓存"
        
        while true; do
            local load=\$(uptime | awk -F'load average:' '{print \$2}' | sed 's/ //g' | cut -d, -f1)
            local mem=\$(free -m | awk 'NR==2{printf "%.1f%%", \$3*100/\$2}')
            local disk=\$(df -h /var/www/\$DOMAIN | awk 'NR==2{print \$5}')
            local conn=\$(netstat -ant | grep :443 | wc -l)
            local cache=\$(find "/var/www/\$DOMAIN/cache/fastcgi" -type f | wc -l)
            
            echo "\$(date '+%H:%M:%S'),\$load,\$mem,\$disk,\$conn,\$cache"
            sleep 5
        done
        ;;
        
    info)
        echo -e "\${CYAN}=== \$DOMAIN 站点信息 (极致性能版) ===\${NC}"
        echo "域名: \$DOMAIN"
        echo "PHP版本: \$PHP_VERSION"
        echo "WordPress路径: /var/www/\$DOMAIN/public"
        echo "数据库: \$WP_DB_NAME"
        echo "备份目录: /var/www/\$DOMAIN/backups"
        echo "日志目录: /var/www/\$DOMAIN/logs"
        echo "性能模式: 极致性能 (VPS所有资源专用)"
        
        if [[ -f "/var/www/\$DOMAIN/public/wp-config.php" ]]; then
            echo ""
            echo "WordPress版本: \$(sudo -u www-data wp core version --path="/var/www/\$DOMAIN/public")"
            echo "主题: \$(sudo -u www-data wp theme list --status=active --field=name --path="/var/www/\$DOMAIN/public")"
            echo "插件数量: \$(sudo -u www-data wp plugin list --field=name --path="/var/www/\$DOMAIN/public" | wc -l)"
        fi
        ;;
        
    *)
        echo "单WordPress站点管理脚本 (极致性能版) - \$DOMAIN"
        echo ""
        echo "用法: \$0 {status|restart|cache-clear|backup|optimize|monitor|info}"
        echo ""
        echo "命令说明:"
        echo "  status      - 显示站点状态和性能信息"
        echo "  restart     - 重启所有服务"
        echo "  cache-clear - 清除所有缓存 (FastCGI + Redis + OPcache)"
        echo "  backup      - 创建站点备份"
        echo "  optimize    - 执行性能优化"
        echo "  monitor     - 实时监控"
        echo "  info        - 显示站点信息"
        ;;
esac
EOF
    
    chmod +x /usr/local/bin/manage-$DOMAIN
    log_message "SUCCESS" "管理脚本创建完成: manage-$DOMAIN"
    mark_complete "create_management_script"
}

# --- 重启服务 ---
restart_services() {
    if load_progress "restart_services"; then
        log_message "INFO" "服务已重启，跳过..."
        return
    fi
    
    log_message "TASK" "重启所有服务..."
    
    systemctl restart nginx php$PHP_VERSION-fpm mariadb redis-server fail2ban
    systemctl enable nginx php$PHP_VERSION-fpm mariadb redis-server fail2ban
    
    # 检查服务状态
    log_message "INFO" "检查服务状态..."
    
    for service in nginx php$PHP_VERSION-fpm mariadb redis-server fail2ban; do
        if systemctl is-active --quiet "$service"; then
            log_message "SUCCESS" "$service 服务运行正常"
        else
            log_message "ERROR" "$service 服务启动失败"
            systemctl status "$service" --no-pager -l
        fi
    done
    
    log_message "SUCCESS" "服务重启完成"
    mark_complete "restart_services"
}

# --- 显示摘要 ---
show_summary() {
    echo -e "\\n${GREEN}============================================${NC}"
    echo -e "${GREEN}    单WordPress站点极致性能部署完成！${NC}"
    echo -e "${GREEN}============================================${NC}\\n"
    
    echo -e "${CYAN}=== 站点信息 ===${NC}"
    echo -e "主域名: ${GREEN}https://$PRIMARY_DOMAIN${NC}"
    echo -e "备用域名: ${GREEN}https://$ALT_DOMAIN${NC}"
    echo -e "站点标题: $SITE_TITLE"
    echo -e "安装路径: /var/www/$DOMAIN"
    echo -e "PHP版本: $PHP_VERSION"
    echo -e "性能模式: ${YELLOW}极致性能 (VPS所有资源专用)${NC}"
    
    echo -e "\\n${CYAN}=== 管理员凭据 ===${NC}"
    echo -e "用户名: ${YELLOW}$ADMIN_USER${NC}"
    echo -e "密码: ${RED}$ADMIN_PASS${NC}"
    echo -e "邮箱: $ADMIN_EMAIL"
    echo -e "登录地址: ${GREEN}https://$PRIMARY_DOMAIN/wp-admin${NC}"
    
    echo -e "\\n${CYAN}=== 数据库信息 ===${NC}"
    echo -e "数据库名: $WP_DB_NAME"
    echo -e "数据库用户: $WP_DB_USER"
    echo -e "数据库密码: ${RED}$WP_DB_PASS${NC}"
    echo -e "MariaDB Root密码: ${RED}$MYSQL_ROOT_PASS${NC}"
    
    echo -e "\\n${CYAN}=== Redis信息 ===${NC}"
    echo -e "Redis密码: ${RED}$REDIS_PASS${NC}"
    
    echo -e "\\n${CYAN}=== 极致性能优化 ===${NC}"
    echo -e "✓ VPS所有资源专用于单个WordPress站点"
    echo -e "✓ MariaDB使用70%内存 ($(( $(free -m | awk '/^Mem:/{print $2}') * 70 / 100 ))MB)"
    echo -e "✓ Redis使用15%内存 ($(( $(free -m | awk '/^Mem:/{print $2}') * 15 / 100 ))MB)"
    echo -e "✓ PHP-FPM动态进程池优化"
    echo -e "✓ Nginx极致性能配置"
    echo -e "✓ FastCGI + Redis + OPcache三重缓存"
    if [[ "$PHP_VERSION" == "8.3" ]] || [[ "$PHP_VERSION" == "8.4" ]]; then
        echo -e "✓ PHP JIT编译器已启用"
    fi
    if [[ "$USE_WOOCOMMERCE" == "yes" ]]; then
        echo -e "✓ WooCommerce电商专用优化"
    fi
    
    echo -e "\\n${CYAN}=== 管理命令 ===${NC}"
    echo -e "站点管理: ${GREEN}manage-$DOMAIN {command}${NC}"
    echo -e "查看状态: manage-$DOMAIN status"
    echo -e "清除缓存: manage-$DOMAIN cache-clear"
    echo -e "创建备份: manage-$DOMAIN backup"
    echo -e "性能优化: manage-$DOMAIN optimize"
    echo -e "实时监控: manage-$DOMAIN monitor"
    
    echo -e "\\n${CYAN}=== 验证命令 ===${NC}"
    echo -e "检查HTTPS: curl -I https://$PRIMARY_DOMAIN"
    echo -e "检查缓存: curl -I https://$PRIMARY_DOMAIN | grep X-FastCGI-Cache"
    echo -e "检查PHP: curl https://$PRIMARY_DOMAIN/php-ping"
    echo -e "性能测试: ab -n 100 -c 10 https://$PRIMARY_DOMAIN/"
    
    echo -e "\\n${YELLOW}=== 重要提示 ===${NC}"
    echo -e "1. 立即保存上述凭据到安全位置"
    echo -e "2. 首次登录后立即修改管理员密码"
    echo -e "3. 定期备份: manage-$DOMAIN backup"
    echo -e "4. 监控性能: manage-$DOMAIN monitor"
    echo -e "5. 定期优化: manage-$DOMAIN optimize"
    echo -e "6. VPS所有资源已专用于此站点，实现极致性能"
    
    # 保存凭据到文件
    cat > /root/wordpress-single-credentials-$DOMAIN.txt << EOF
=== 单WordPress站点极致性能部署凭据 ===
部署时间: $(date)
主域名: https://$PRIMARY_DOMAIN
备用域名: https://$ALT_DOMAIN
PHP版本: $PHP_VERSION
性能模式: 极致性能 (VPS所有资源专用)

=== WordPress管理员 ===
用户名: $ADMIN_USER
密码: $ADMIN_PASS
邮箱: $ADMIN_EMAIL
登录地址: https://$PRIMARY_DOMAIN/wp-admin

=== 数据库信息 ===
数据库名: $WP_DB_NAME
数据库用户: $WP_DB_USER
数据库密码: $WP_DB_PASS
MariaDB Root密码: $MYSQL_ROOT_PASS

=== Redis缓存 ===
Redis密码: $REDIS_PASS

=== 管理命令 ===
站点管理: manage-$DOMAIN {command}

=== 重要路径 ===
站点根目录: /var/www/$DOMAIN
网站文件: /var/www/$DOMAIN/public
日志目录: /var/www/$DOMAIN/logs/
备份目录: /var/www/$DOMAIN/backups/
Nginx配置: /etc/nginx/sites-available/$DOMAIN
PHP配置: /etc/php/$PHP_VERSION/fpm/pool.d/www.conf

=== 极致性能优化说明 ===
1. VPS所有资源专用于单个WordPress站点
2. MariaDB使用70%内存，Redis使用15%内存
3. PHP-FPM动态进程池，根据服务器资源自动调整
4. Nginx极致性能配置，支持HTTP/2
5. FastCGI + Redis + OPcache三重缓存
6. 使用 manage-$DOMAIN cache-clear 清除所有缓存
7. 使用 manage-$DOMAIN optimize 执行性能优化

保存时间: $(date)
EOF
    
    echo -e "\\n${YELLOW}凭据已保存到: /root/wordpress-single-credentials-$DOMAIN.txt${NC}"
    echo -e "${YELLOW}部署日志: $LOG_FILE${NC}"
    
    # 清理状态文件
    rm -f "$STATE_FILE"
    
    # 最后测试
    echo -e "\\n${CYAN}=== 最终测试 ===${NC}"
    
    # 测试网站访问
    if curl -I "https://$PRIMARY_DOMAIN" 2>/dev/null | grep -q "200 OK"; then
        echo -e "${GREEN}✓ 网站可正常访问${NC}"
    else
        echo -e "${RED}✗ 网站访问测试失败${NC}"
    fi
    
    # 测试SSL证书
    if openssl s_client -connect "$PRIMARY_DOMAIN:443" -servername "$PRIMARY_DOMAIN" 2>/dev/null | openssl x509 -noout -dates >/dev/null 2>&1; then
        echo -e "${GREEN}✓ SSL证书安装正常${NC}"
    else
        echo -e "${RED}✗ SSL证书测试失败${NC}"
    fi
    
    # 测试数据库连接
    if mariadb -u "$WP_DB_USER" -p"$WP_DB_PASS" -e "SELECT 1;" "$WP_DB_NAME" 2>/dev/null; then
        echo -e "${GREEN}✓ 数据库连接正常${NC}"
    else
        echo -e "${RED}✗ 数据库连接失败${NC}"
    fi
    
    # 测试Redis连接
    if redis-cli -a "$REDIS_PASS" ping 2>/dev/null | grep -q "PONG"; then
        echo -e "${GREEN}✓ Redis连接正常${NC}"
    else
        echo -e "${RED}✗ Redis连接失败${NC}"
    fi
    
    # 测试PHP-FPM
    if curl -s "https://$PRIMARY_DOMAIN/php-ping" 2>/dev/null | grep -q "pong"; then
        echo -e "${GREEN}✓ PHP-FPM运行正常${NC}"
    else
        echo -e "${YELLOW}⚠ PHP-FPM状态页未启用${NC}"
    fi
}

# --- 主执行流程 ---
main() {
    init_script
    collect_input
    
    echo -e "\\n${CYAN}开始单WordPress站点极致性能部署...${NC}"
    echo -e "选择PHP版本: ${GREEN}$PHP_VERSION${NC}"
    echo -e "WooCommerce模式: ${GREEN}$USE_WOOCOMMERCE${NC}"
    echo -e "性能模式: ${YELLOW}极致性能 (VPS所有资源专用)${NC}"
    echo -e "预计时间: 10-15分钟\\n"
    
    START_TIME=$(date +%s)
    
    # 执行部署步骤
    system_optimization
    install_nginx
    install_php
    install_mariadb
    install_redis
    configure_firewall
    install_fail2ban
    install_certbot
    install_wpcli
    configure_nginx_site
    get_ssl_certificate
    install_wordpress
    set_permissions
    create_management_script
    restart_services
    
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    MINUTES=$((DURATION / 60))
    SECONDS=$((DURATION % 60))
    
    echo -e "\\n${GREEN}极致性能部署完成！总耗时: ${MINUTES}分${SECONDS}秒${NC}"
    
    show_summary
}

# 错误处理
trap 'log_message "ERROR" "在步骤执行过程中出错，请检查日志: $LOG_FILE"; exit 1' ERR

# 运行主函数
main "$@"