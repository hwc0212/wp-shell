#!/bin/bash

# ======================================================================
# WordPress 高性能部署自动化脚本 (Cloudways/SpinupWP 增强版)
# ======================================================================
# 版本: 4.1
# 最后更新: 2025-12-26
# 适用系统: Ubuntu 20.04/22.04/24.04
# 核心目标: 实现超越Cloudways标准的极致性能、安全和可维护性
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
SCRIPT_NAME="deploy-wordpress-optimized.sh"
LOG_FILE="/var/log/wp-deploy-$(date +%Y%m%d-%H%M%S).log"
STATE_FILE="/tmp/wp-deploy.state"
PHP_VERSION=""  # 留空，由用户选择
MYSQL_VERSION="8.0"
USE_WOOCOMMERCE="no"
AVAILABLE_PHP_VERSIONS=("8.2" "8.3" "8.4")

# --- 初始化函数 ---
init_script() {
    echo -e "${CYAN}[INFO]${NC} WordPress高性能部署脚本启动"
    
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

# --- 检查PHP版本可用性 ---
check_php_version_availability() {
    local version="$1"
    
    # 对于PHP 8.4，检查系统版本是否支持
    if [[ "$version" == "8.4" ]]; then
        local ubuntu_version=$(lsb_release -cs)
        
        # PHP 8.4在不同Ubuntu版本的可用性检查
        case "$ubuntu_version" in
            "focal")  # Ubuntu 20.04
                echo -e "${YELLOW}[警告]${NC} Ubuntu 20.04 上 PHP 8.4 需要通过PPA安装，可能会有稳定性问题"
                read -rp "是否继续使用 PHP 8.4? (y/n): " CONTINUE
                if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
                    return 1
                fi
                ;;
            "jammy")  # Ubuntu 22.04
                echo -e "${CYAN}[信息]${NC} Ubuntu 22.04 上 PHP 8.4 可以正常安装"
                ;;
            "noble")  # Ubuntu 24.04
                echo -e "${GREEN}[信息]${NC} Ubuntu 24.04 原生支持 PHP 8.4"
                ;;
            *)
                echo -e "${YELLOW}[警告]${NC} 未知的 Ubuntu 版本，PHP 8.4 安装可能失败"
                read -rp "是否继续使用 PHP 8.4? (y/n): " CONTINUE
                if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
                    return 1
                fi
                ;;
        esac
    fi
    return 0
}

# --- 用户输入收集 ---
collect_input() {
    if load_progress "collect_input"; then
        log_message "INFO" "用户输入已收集，跳过..."
        return
    fi
    
    echo -e "\n${CYAN}=== WordPress部署配置 ===${NC}\n"
    
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
            
            # 检查PHP版本可用性
            if check_php_version_availability "$PHP_VERSION"; then
                break
            else
                echo -e "${YELLOW}[提示]${NC} 请重新选择PHP版本"
            fi
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
    echo -e "\n是否计划安装WooCommerce（电商网站）？这将启用更激进的优化配置。"
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
    echo "MySQL版本: $MYSQL_VERSION"
    echo "WooCommerce优化模式: $USE_WOOCOMMERCE"
    
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

# --- 系统优化 ---
system_optimization() {
    if load_progress "system_optimization"; then
        log_message "INFO" "系统优化已完成，跳过..."
        return
    fi
    
    log_message "TASK" "执行系统级优化..."
    
    # 更新系统
    apt update && apt upgrade -y
    log_message "SUCCESS" "系统更新完成"
    
    # 安装基础工具
    apt install -y curl wget git nano htop net-tools software-properties-common \
                   apt-transport-https ca-certificates gnupg lsb-release \
                   unzip zip
    log_message "SUCCESS" "基础工具安装完成"
    
    # 内核优化
    cat >> /etc/sysctl.conf << EOF
# WordPress优化参数
net.core.somaxconn = 65536
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 20000
net.ipv4.ip_local_port_range = 10000 65000
fs.file-max = 1000000
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
    
    sysctl -p
    log_message "SUCCESS" "内核参数优化完成"
    
    # 文件句柄限制
    cat >> /etc/security/limits.conf << EOF
* soft nofile 65536
* hard nofile 65536
www-data soft nofile 65536
www-data hard nofile 65536
EOF
    
    mark_complete "system_optimization"
}

# --- 安装Nginx ---
install_nginx() {
    if load_progress "install_nginx"; then
        log_message "INFO" "Nginx已安装，跳过..."
        return
    fi
    
    log_message "TASK" "安装Nginx..."
    
    # 添加Nginx官方源
    wget -O /tmp/nginx_signing.key https://nginx.org/keys/nginx_signing.key
    gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg /tmp/nginx_signing.key
    
    OS_CODENAME=$(lsb_release -cs)
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu $OS_CODENAME nginx" | tee /etc/apt/sources.list.d/nginx.list
    
    apt update
    apt install -y nginx
    
    # 创建站点目录
    mkdir -p /var/www/$DOMAIN/{public,cache,logs,backups}
    
    log_message "SUCCESS" "Nginx安装完成"
    mark_complete "install_nginx"
}

# --- 安装PHP ---
install_php() {
    if load_progress "install_php"; then
        log_message "INFO" "PHP已安装，跳过..."
        return
    fi
    
    log_message "TASK" "安装PHP $PHP_VERSION..."
    
    # 添加Ondřej Surý的PPA（包含最新PHP版本）
    add-apt-repository ppa:ondrej/php -y
    apt update
    
    # 为PHP 8.4做特殊准备（如果需要）
    if [[ "$PHP_VERSION" == "8.4" ]]; then
        log_message "INFO" "准备PHP 8.4安装环境..."
        
        # 确保系统是最新的
        apt update && apt upgrade -y
        
        # 检查Ubuntu版本并提示
        UBUNTU_VERSION=$(lsb_release -rs)
        case "$UBUNTU_VERSION" in
            "20.04")
                echo -e "${YELLOW}[注意]${NC} Ubuntu 20.04上PHP 8.4可能需要额外配置"
                ;;
            "22.04")
                echo -e "${CYAN}[信息]${NC} Ubuntu 22.04上PHP 8.4安装正常"
                ;;
            "24.04")
                echo -e "${GREEN}[信息]${NC} Ubuntu 24.04原生支持PHP 8.4"
                ;;
        esac
    fi
    
    # 安装PHP及扩展
    log_message "INFO" "安装PHP $PHP_VERSION 及其扩展..."
    
    # 基本包
    apt install -y php$PHP_VERSION-fpm php$PHP_VERSION-cli
    
    # 常见扩展
    apt install -y php$PHP_VERSION-mysql php$PHP_VERSION-redis \
                   php$PHP_VERSION-curl php$PHP_VERSION-gd \
                   php$PHP_VERSION-mbstring php$PHP_VERSION-xml \
                   php$PHP_VERSION-zip php$PHP_VERSION-intl \
                   php$PHP_VERSION-bcmath
    
    # 可选但推荐的扩展
    apt install -y php$PHP_VERSION-imagick php$PHP_VERSION-soap
    
    # 对于PHP 8.4，可能需要额外处理
    if [[ "$PHP_VERSION" == "8.4" ]]; then
        # 检查是否有特定于8.4的扩展
        if apt-cache show php8.4-raphf 2>/dev/null; then
            apt install -y php8.4-raphf php8.4-protobuf
        fi
    fi
    
    # 动态优化配置
    local total_mem=$(free -m | awk '/^Mem:/{print $2}')
    local php_mem_per_child=128
    local system_reserve=512
    local php_memory_limit="256M"
    
    if [[ "$USE_WOOCOMMERCE" == "yes" ]]; then
        php_mem_per_child=256
        system_reserve=1024
        php_memory_limit="512M"
    fi
    
    # 计算最大子进程数
    local max_children=$(( (total_mem - system_reserve) / php_mem_per_child ))
    [[ $max_children -lt 4 ]] && max_children=4
    [[ $max_children -gt 50 ]] && max_children=50
    
    local start_servers=$(( max_children / 4 ))
    local min_spare=$(( max_children / 8 ))
    local max_spare=$(( max_children / 4 ))
    
    # 配置PHP-FPM
    PHP_FPM_CONF="/etc/php/$PHP_VERSION/fpm/pool.d/www.conf"
    if [[ -f "$PHP_FPM_CONF" ]]; then
        sed -i "s/^pm.max_children = .*/pm.max_children = $max_children/" "$PHP_FPM_CONF"
        sed -i "s/^pm.start_servers = .*/pm.start_servers = $start_servers/" "$PHP_FPM_CONF"
        sed -i "s/^pm.min_spare_servers = .*/pm.min_spare_servers = $min_spare/" "$PHP_FPM_CONF"
        sed -i "s/^pm.max_spare_servers = .*/pm.max_spare_servers = $max_spare/" "$PHP_FPM_CONF"
        
        # 启用状态页
        sed -i "s/^;pm.status_path = .*/pm.status_path = \/php-status/" "$PHP_FPM_CONF"
        
        # 启用ping路径
        sed -i "s/^;ping.path = .*/ping.path = \/php-ping/" "$PHP_FPM_CONF"
    else
        log_message "WARNING" "PHP-FPM配置文件未找到: $PHP_FPM_CONF"
    fi
    
    # 配置php.ini
    PHP_INI="/etc/php/$PHP_VERSION/fpm/php.ini"
    if [[ -f "$PHP_INI" ]]; then
        sed -i "s/^memory_limit = .*/memory_limit = $php_memory_limit/" "$PHP_INI"
        sed -i "s/^max_execution_time = .*/max_execution_time = 300/" "$PHP_INI"
        sed -i "s/^max_input_time = .*/max_input_time = 300/" "$PHP_INI"
        sed -i "s/^upload_max_filesize = .*/upload_max_filesize = 64M/" "$PHP_INI"
        sed -i "s/^post_max_size = .*/post_max_size = 64M/" "$PHP_INI"
        sed -i "s/^max_file_uploads = .*/max_file_uploads = 20/" "$PHP_INI"
        
        # 错误处理
        sed -i "s/^display_errors = .*/display_errors = Off/" "$PHP_INI"
        sed -i "s/^log_errors = .*/log_errors = On/" "$PHP_INI"
        sed -i "s|^;error_log =.*|error_log = /var/log/php$PHP_VERSION-fpm-error.log|" "$PHP_INI"
    fi
    
    # 配置OPcache
    OP_CACHE_FILE="/etc/php/$PHP_VERSION/fpm/conf.d/10-opcache.ini"
    if [[ ! -f "$OP_CACHE_FILE" ]]; then
        cat > "$OP_CACHE_FILE" << EOF
zend_extension=opcache.so
opcache.enable=1
opcache.memory_consumption=256
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=10000
opcache.revalidate_freq=2
opcache.fast_shutdown=1
opcache.enable_cli=1
opcache.save_comments=1
opcache.load_comments=1
opcache.enable_file_override=1
EOF
    fi
    
    # 为PHP 8.3+启用JIT（包括8.4）
    if [[ "$PHP_VERSION" == "8.3" ]] || [[ "$PHP_VERSION" == "8.4" ]]; then
        if grep -q "opcache.jit" "$OP_CACHE_FILE"; then
            sed -i "s/^opcache.jit=.*/opcache.jit=1255/" "$OP_CACHE_FILE"
            sed -i "s/^opcache.jit_buffer_size=.*/opcache.jit_buffer_size=256M/" "$OP_CACHE_FILE"
        else
            echo "opcache.jit=1255" >> "$OP_CACHE_FILE"
            echo "opcache.jit_buffer_size=256M" >> "$OP_CACHE_FILE"
        fi
    fi
    
    # 启动PHP-FPM
    systemctl restart php$PHP_VERSION-fpm
    systemctl enable php$PHP_VERSION-fpm
    
    log_message "SUCCESS" "PHP $PHP_VERSION 安装和优化完成"
    mark_complete "install_php"
}

# --- 安装MySQL ---
install_mysql() {
    if load_progress "install_mysql"; then
        log_message "INFO" "MySQL已安装，跳过..."
        return
    fi
    
    log_message "TASK" "安装MySQL $MYSQL_VERSION..."
    
    # 安装MySQL
    apt install -y mysql-server
    
    # 动态优化配置
    local total_mem=$(free -m | awk '/^Mem:/{print $2}')
    local innodb_percent=60
    
    if [[ "$USE_WOOCOMMERCE" == "yes" ]]; then
        innodb_percent=70
    fi
    
    local innodb_size_mb=$(( total_mem * innodb_percent / 100 ))
    local innodb_size_gb=$(( innodb_size_mb / 1024 ))
    [[ $innodb_size_gb -lt 1 ]] && innodb_size_gb=1
    
    # 配置MySQL
    MYSQL_CONF="/etc/mysql/mysql.conf.d/mysqld.cnf"
    cat >> "$MYSQL_CONF" << EOF

# WordPress优化配置
[mysqld]
# 内存配置
innodb_buffer_pool_size = ${innodb_size_gb}G
innodb_log_file_size = 256M
innodb_log_buffer_size = 16M

# 性能配置
innodb_flush_log_at_trx_commit = 1
innodb_file_per_table = 1
innodb_flush_method = O_DIRECT
innodb_buffer_pool_instances = $(nproc)
innodb_read_io_threads = $(nproc)
innodb_write_io_threads = $(nproc)

# 连接配置
max_connections = 200
thread_cache_size = 100
table_open_cache = 4096
table_definition_cache = 4096

# 查询缓存
query_cache_type = 0
query_cache_size = 0

# 日志配置
slow_query_log = 1
slow_query_log_file = /var/log/mysql/mysql-slow.log
long_query_time = 2
log_queries_not_using_indexes = 1

# 字符集
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
EOF
    
    # 启动MySQL
    systemctl start mysql
    systemctl enable mysql
    
    # 安全配置
    log_message "INFO" "执行MySQL安全配置..."
    
    # 临时文件存储MySQL安全配置
    MYSQL_SECURE_TMP="/tmp/mysql_secure_install.sql"
    
    cat > "$MYSQL_SECURE_TMP" << EOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASS';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
    
    # 执行安全配置
    mysql -e "source $MYSQL_SECURE_TMP"
    rm -f "$MYSQL_SECURE_TMP"
    
    # 创建WordPress数据库
    log_message "INFO" "创建WordPress数据库..."
    
    mysql -u root -p"$MYSQL_ROOT_PASS" -e "CREATE DATABASE IF NOT EXISTS $WP_DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mysql -u root -p"$MYSQL_ROOT_PASS" -e "CREATE USER IF NOT EXISTS '$WP_DB_USER'@'localhost' IDENTIFIED BY '$WP_DB_PASS';"
    mysql -u root -p"$MYSQL_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON $WP_DB_NAME.* TO '$WP_DB_USER'@'localhost';"
    mysql -u root -p"$MYSQL_ROOT_PASS" -e "FLUSH PRIVILEGES;"
    
    systemctl restart mysql
    log_message "SUCCESS" "MySQL安装和优化完成"
    mark_complete "install_mysql"
}

# --- 安装Redis ---
install_redis() {
    if load_progress "install_redis"; then
        log_message "INFO" "Redis已安装，跳过..."
        return
    fi
    
    log_message "TASK" "安装Redis..."
    
    apt install -y redis-server
    
    # 检查是否安装了对应的PHP Redis扩展
    if ! dpkg -l | grep -q "php$PHP_VERSION-redis"; then
        apt install -y php$PHP_VERSION-redis
    fi
    
    # 优化配置
    local total_mem=$(free -m | awk '/^Mem:/{print $2}')
    local redis_max_mem=$(( total_mem * 10 / 100 ))
    [[ $redis_max_mem -lt 128 ]] && redis_max_mem=128
    [[ $redis_max_mem -gt 1024 ]] && redis_max_mem=1024
    
    REDIS_CONF="/etc/redis/redis.conf"
    
    # 备份原始配置
    cp "$REDIS_CONF" "$REDIS_CONF.backup"
    
    # 应用优化配置
    sed -i "s/^# requirepass .*/requirepass $REDIS_PASS/" "$REDIS_CONF"
    sed -i "s/^# maxmemory .*/maxmemory ${redis_max_mem}mb/" "$REDIS_CONF"
    sed -i "s/^# maxmemory-policy .*/maxmemory-policy allkeys-lru/" "$REDIS_CONF"
    
    # 性能优化
    sed -i "s/^tcp-backlog .*/tcp-backlog 65536/" "$REDIS_CONF"
    sed -i "s/^timeout .*/timeout 0/" "$REDIS_CONF"
    sed -i "s/^tcp-keepalive .*/tcp-keepalive 300/" "$REDIS_CONF"
    
    # 启用AOF持久化
    sed -i "s/^appendonly no/appendonly yes/" "$REDIS_CONF"
    sed -i "s/^appendfsync everysec/appendfsync everysec/" "$REDIS_CONF"
    
    # 内存优化
    sed -i "s/^hash-max-ziplist-entries .*/hash-max-ziplist-entries 512/" "$REDIS_CONF"
    sed -i "s/^hash-max-ziplist-value .*/hash-max-ziplist-value 64/" "$REDIS_CONF"
    
    systemctl restart redis-server
    systemctl enable redis-server
    
    log_message "SUCCESS" "Redis安装和优化完成"
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
    
    # 允许必要的服务
    ufw allow 53/udp  # DNS
    ufw allow 123/udp # NTP
    
    echo "y" | ufw enable
    ufw status verbose
    
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
    
    # 创建jail.local配置
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 3600
findtime = 600
maxretry = 5
destemail = $ADMIN_EMAIL
sender = fail2ban@$DOMAIN
mta = sendmail
action = %(action_mwl)s

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

[nginx-botsearch]
enabled = true
port = http,https
filter = nginx-botsearch
logpath = /var/log/nginx/access.log
maxretry = 5

[wordpress]
enabled = true
port = http,https
filter = wordpress
logpath = /var/www/$DOMAIN/logs/nginx-access.log
maxretry = 5
bantime = 86400
findtime = 3600

[php-url-fopen]
enabled = true
port = http,https
filter = php-url-fopen
logpath = /var/log/nginx/access.log
maxretry = 3

[phpmyadmin-syslog]
enabled = false
port = http,https
filter = phpmyadmin
logpath = /var/log/auth.log
maxretry = 3
EOF
    
    # 创建WordPress过滤器
    cat > /etc/fail2ban/filter.d/wordpress.conf << EOF
[Definition]
failregex = ^<HOST>.*"POST.*wp-login.php.*" 200
            ^<HOST>.*"POST.*xmlrpc.php.*" 200
            ^<HOST>.*"GET.*wp-login.php.*" 200
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
    
    # 确保snap路径
    if [[ ! -d /snap ]]; then
        ln -s /var/lib/snapd/snap /snap
    fi
    
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
    
    # 验证文件
    if [[ -f /usr/local/bin/wp ]]; then
        chmod +x /usr/local/bin/wp
        
        # 测试WP-CLI
        if /usr/local/bin/wp --info --allow-root 2>/dev/null | grep -q "WP-CLI"; then
            log_message "SUCCESS" "WP-CLI安装完成"
        else
            log_message "WARNING" "WP-CLI安装可能有问题，尝试备用方法..."
            
            # 备用方法
            wget -O /tmp/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
            php /tmp/wp-cli.phar --info --allow-root
            mv /tmp/wp-cli.phar /usr/local/bin/wp
            chmod +x /usr/local/bin/wp
        fi
    else
        log_message "ERROR" "WP-CLI下载失败"
        exit 1
    fi
    
    mark_complete "install_wpcli"
}

# --- 配置Nginx站点 ---
configure_nginx_site() {
    if load_progress "configure_nginx_site"; then
        log_message "INFO" "Nginx配置已完成，跳过..."
        return
    fi
    
    log_message "TASK" "配置Nginx虚拟主机..."
    
    # 创建Nginx缓存目录
    mkdir -p /var/cache/nginx/{fastcgi_cache,proxy_cache}
    chown -R www-data:www-data /var/cache/nginx
    
    # 创建Nginx配置
    cat > /etc/nginx/sites-available/$DOMAIN << EOF
# HTTP重定向到HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $PRIMARY_DOMAIN $ALT_DOMAIN;
    
    # 安全头（即使是重定向）
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    
    # 重定向到HTTPS
    return 301 https://\$host\$request_uri;
}

# HTTPS服务器
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $PRIMARY_DOMAIN $ALT_DOMAIN;
    
    root /var/www/$DOMAIN/public;
    index index.php index.html index.htm;
    
    # SSL证书
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    
    # SSL优化
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256';
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:50m;
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
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
    
    # 日志
    access_log /var/www/$DOMAIN/logs/nginx-access.log combined buffer=512k flush=1m;
    error_log /var/www/$DOMAIN/logs/nginx-error.log warn;
    
    # FastCGI缓存配置
    fastcgi_cache_path /var/cache/nginx/fastcgi_cache levels=1:2 keys_zone=WORDPRESS:100m inactive=60m max_size=1g;
    fastcgi_cache_key "\$scheme\$request_method\$host\$request_uri";
    fastcgi_cache_use_stale error timeout invalid_header http_500 http_503;
    fastcgi_cache_valid 200 301 302 1h;
    fastcgi_cache_bypass \$skip_cache;
    fastcgi_no_cache \$skip_cache;
    
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
    
    # 静态文件缓存
    location ~* \\.(js|css|png|jpg|jpeg|gif|ico|svg|webp|woff|woff2|ttf|eot|mp4|webm|ogv)\$ {
        expires 365d;
        add_header Cache-Control "public, immutable, max-age=31536000";
        access_log off;
        try_files \$uri =404;
    }
    
    # 安全规则
    location ~ /\\. {
        deny all;
        access_log off;
        log_not_found off;
    }
    
    location ~ /\\.(svn|git|hg|bzr|cvs)\$ {
        deny all;
        access_log off;
        log_not_found off;
    }
    
    location ~* /(?:uploads|files)/.*\\.php\$ {
        deny all;
    }
    
    location ~* \\.(ini|log|conf|sql|swp)$ {
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
    
    # PHP处理
    location ~ \\.php\$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php$PHP_VERSION-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_param HTTPS on;
        
        # FastCGI缓存设置
        fastcgi_cache WORDPRESS;
        fastcgi_cache_valid 200 301 302 1h;
        fastcgi_cache_use_stale error timeout updating http_500 http_503;
        fastcgi_cache_background_update on;
        fastcgi_cache_lock on;
        fastcgi_cache_lock_timeout 5s;
        
        fastcgi_no_cache \$skip_cache;
        fastcgi_cache_bypass \$skip_cache;
        
        add_header X-FastCGI-Cache \$upstream_cache_status;
        add_header X-Powered-By "PHP $PHP_VERSION";
    }
    
    # WordPress重写规则
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
        
        # 启用Gzip压缩
        gzip_static on;
    }
    
    # 禁止访问敏感目录
    location ~* /(wp-content/uploads/.*\\.php|wp-includes/.*\\.php)\$ {
        deny all;
    }
    
    # 限制请求方法
    if (\$request_method !~ ^(GET|HEAD|POST)\$) {
        return 444;
    }
}
EOF
    
    # 启用站点
    ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
    
    # 禁用默认站点
    rm -f /etc/nginx/sites-enabled/default
    
    # 全局Nginx优化
    cat > /etc/nginx/nginx.conf << EOF
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    # 基础设置
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    keepalive_requests 1000;
    types_hash_max_size 2048;
    server_tokens off;
    client_max_body_size 64M;
    
    # MIME类型
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    # 日志格式
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for"';
    
    access_log /var/log/nginx/access.log main buffer=512k flush=1m;
    error_log /var/log/nginx/error.log warn;
    
    # Gzip压缩
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript 
               application/json application/javascript application/xml+rss 
               application/atom+xml image/svg+xml;
    
    # 文件缓存
    open_file_cache max=200000 inactive=20s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;
    
    # 服务器配置
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
    
    # 测试配置
    nginx -t
    log_message "SUCCESS" "Nginx配置完成"
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
    
    # 等待确保端口释放
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
        
        # 备用方法：使用webroot方式
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

# --- 安装WordPress ---
install_wordpress() {
    if load_progress "install_wordpress"; then
        log_message "INFO" "WordPress已安装，跳过..."
        return
    fi
    
    log_message "TASK" "安装WordPress..."
    
    cd /var/www/$DOMAIN/public
    
    # 下载WordPress
    sudo -u www-data wp core download --locale=en_US --version=latest
    
    # 检查下载是否成功
    if [[ ! -f "wp-config-sample.php" ]]; then
        log_message "ERROR" "WordPress下载失败"
        exit 1
    fi
    
    # 创建配置文件
    sudo -u www-data wp config create \
        --dbname="$WP_DB_NAME" \
        --dbuser="$WP_DB_USER" \
        --dbpass="$WP_DB_PASS" \
        --dbhost="localhost" \
        --dbcharset="utf8mb4" \
        --dbcollate="utf8mb4_unicode_ci" \
        --extra-php << 'EOF'
// 强制SSL
define('FORCE_SSL_ADMIN', true);
if ($_SERVER['HTTP_X_FORWARDED_PROTO'] == 'https') {
    $_SERVER['HTTPS'] = 'on';
}

// 禁用文件编辑
define('DISALLOW_FILE_EDIT', true);

// 禁用自动更新（推荐手动更新）
define('AUTOMATIC_UPDATER_DISABLED', true);

// 自动保存优化
define('AUTOSAVE_INTERVAL', 300);
define('WP_POST_REVISIONS', 10);
define('EMPTY_TRASH_DAYS', 30);

// 调试设置
define('WP_DEBUG', false);
define('WP_DEBUG_LOG', true);
define('WP_DEBUG_DISPLAY', false);
define('SCRIPT_DEBUG', false);

// 内存限制
$wp_memory_limit = '256M';
$wp_max_memory_limit = '512M';
define('WP_MEMORY_LIMIT', $wp_memory_limit);
define('WP_MAX_MEMORY_LIMIT', $wp_max_memory_limit);

// Redis缓存
define('WP_REDIS_HOST', '127.0.0.1');
define('WP_REDIS_PORT', 6379);
define('WP_REDIS_PASSWORD', '$REDIS_PASS');
define('WP_REDIS_TIMEOUT', 1);
define('WP_REDIS_READ_TIMEOUT', 1);

// 性能优化
define('COMPRESS_CSS', true);
define('COMPRESS_SCRIPTS', true);
define('CONCATENATE_SCRIPTS', true);
define('ENFORCE_GZIP', true);

// 安全设置
define('DISALLOW_UNFILTERED_HTML', true);
define('FORCE_SSL_LOGIN', true);
EOF
    
    # 获取安全密钥
    SECRET_KEYS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/ 2>/dev/null || echo "")
    
    if [[ -n "$SECRET_KEYS" ]]; then
        # 在配置文件中添加安全密钥
        sed -i "/\*\* Authentication Unique Keys and Salts./a $SECRET_KEYS" wp-config.php
    else
        log_message "WARNING" "无法获取安全密钥，使用本地生成"
        # 本地生成安全密钥
        for i in {1..8}; do
            key=$(openssl rand -base64 48 | tr -d '\n')
            case $i in
                1) define="define('AUTH_KEY', '$key');" ;;
                2) define="define('SECURE_AUTH_KEY', '$key');" ;;
                3) define="define('LOGGED_IN_KEY', '$key');" ;;
                4) define="define('NONCE_KEY', '$key');" ;;
                5) define="define('AUTH_SALT', '$key');" ;;
                6) define="define('SECURE_AUTH_SALT', '$key');" ;;
                7) define="define('LOGGED_IN_SALT', '$key');" ;;
                8) define="define('NONCE_SALT', '$key');" ;;
            esac
            sed -i "/\*\* Authentication Unique Keys and Salts./a $define" wp-config.php
        done
    fi
    
    # 根据WooCommerce模式调整内存限制
    if [[ "$USE_WOOCOMMERCE" == "yes" ]]; then
        sed -i "/\$wp_memory_limit = '256M';/c\$wp_memory_limit = '512M';" wp-config.php
        sed -i "/\$wp_max_memory_limit = '512M';/c\$wp_max_memory_limit = '1024M';" wp-config.php
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
    
    # 安装Redis缓存插件并启用
    log_message "INFO" "安装Redis对象缓存插件..."
    sudo -u www-data wp plugin install redis-cache --activate
    sudo -u www-data wp redis enable
    
    # 如果启用WooCommerce，安装WooCommerce插件
    if [[ "$USE_WOOCOMMERCE" == "yes" ]]; then
        log_message "INFO" "安装WooCommerce插件..."
        sudo -u www-data wp plugin install woocommerce --activate
    fi
    
    # 清理默认内容
    sudo -u www-data wp post delete 1 2 3 --force 2>/dev/null || true
    sudo -u www-data wp plugin delete akismet hello 2>/dev/null || true
    
    log_message "SUCCESS" "WordPress安装完成"
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
    
    # 重要文件保护
    chmod 444 public/.htaccess 2>/dev/null || true
    chmod 444 public/index.php
    
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

# 日志函数
log() {
    echo -e "\${GREEN}[\$(date '+%Y-%m-%d %H:%M:%S')]\${NC} \$1"
}

error() {
    echo -e "\${RED}[\$(date '+%Y-%m-%d %H:%M:%S')]\${NC} \$1"
}

case "\$1" in
    status)
        echo "=== 服务状态 ==="
        systemctl status nginx php$PHP_VERSION-fpm mysql redis-server fail2ban | grep -A 2 "Active:" | sed 's/^/  /'
        
        echo -e "\\n=== 磁盘使用 ==="
        df -h / /var/www | sed 's/^/  /'
        
        echo -e "\\n=== 内存使用 ==="
        free -h | sed 's/^/  /'
        
        echo -e "\\n=== 负载状态 ==="
        uptime | sed 's/^/  /'
        
        echo -e "\\n=== PHP状态 ==="
        curl -s http://localhost/php-status 2>/dev/null | grep -A 5 "pool:" || echo "  PHP状态页未启用"
        
        echo -e "\\n=== 缓存状态 ==="
        if [ -f "/var/www/\$DOMAIN/public/wp-content/object-cache.php" ]; then
            echo "  Redis缓存状态:"
            sudo -u www-data wp --path=/var/www/\$DOMAIN/public redis status 2>/dev/null || echo "    无法获取状态"
        else
            echo "  Redis缓存未启用"
        fi
        
        echo -e "\\n=== 网站状态 ==="
        curl -I https://\$DOMAIN 2>/dev/null | head -5 | sed 's/^/  /'
        ;;
    
    restart)
        log "重启服务..."
        systemctl restart nginx php$PHP_VERSION-fpm mysql redis-server fail2ban
        log "服务重启完成"
        ;;
    
    cache-clear)
        log "清除缓存..."
        
        # Nginx FastCGI缓存
        rm -rf /var/cache/nginx/fastcgi_cache/*
        rm -rf /var/cache/nginx/proxy_cache/*
        
        # WordPress缓存
        if [ -d "/var/www/\$DOMAIN/public/wp-content/cache" ]; then
            rm -rf /var/www/\$DOMAIN/public/wp-content/cache/*
        fi
        
        # Redis缓存
        if command -v redis-cli &> /dev/null; then
            redis-cli -a '$REDIS_PASS' FLUSHALL >/dev/null 2>&1
        fi
        
        # 重启PHP-FPM
        systemctl reload php$PHP_VERSION-fpm
        
        log "所有缓存已清除"
        ;;
    
    backup)
        log "创建备份..."
        BACKUP_DIR="/var/www/\$DOMAIN/backups"
        TIMESTAMP=\$(date +%Y%m%d-%H%M%S)
        BACKUP_FILE="backup-\$TIMESTAMP.tar.gz"
        
        mkdir -p "\$BACKUP_DIR"
        
        log "备份数据库中..."
        mysqldump -u $WP_DB_USER -p'$WP_DB_PASS' $WP_DB_NAME --single-transaction --quick --lock-tables=false | gzip > "\$BACKUP_DIR/\${TIMESTAMP}.sql.gz"
        
        log "备份文件中..."
        tar -czf "\$BACKUP_DIR/\$BACKUP_FILE" \\
            --exclude="cache/*" \\
            --exclude="backups/*" \\
            --exclude="logs/*" \\
            -C /var/www "\$DOMAIN"
        
        # 清理旧备份（保留最近7天）
        find "\$BACKUP_DIR" -name "backup-*.tar.gz" -mtime +7 -delete
        find "\$BACKUP_DIR" -name "*.sql.gz" -mtime +7 -delete
        
        log "备份完成: \$BACKUP_DIR/\$BACKUP_FILE"
        echo "备份大小: \$(du -h "\$BACKUP_DIR/\$BACKUP_FILE" | cut -f1)"
        ;;
    
    restore)
        if [ -z "\$2" ]; then
            error "请指定备份文件"
            echo "用法: manage-\$DOMAIN restore <备份文件>"
            exit 1
        fi
        
        BACKUP_FILE="\$2"
        if [ ! -f "\$BACKUP_FILE" ]; then
            error "备份文件不存在: \$BACKUP_FILE"
            exit 1
        fi
        
        log "从 \$BACKUP_FILE 恢复..."
        
        read -p "确认恢复？这将覆盖当前站点数据。(y/n): " CONFIRM
        if [[ "\$CONFIRM" != "y" ]] && [[ "\$CONFIRM" != "Y" ]]; then
            log "恢复已取消"
            exit 0
        fi
        
        # 停止服务
        systemctl stop nginx php$PHP_VERSION-fpm
        
        # 解压备份
        tar -xzf "\$BACKUP_FILE" -C /var/www/
        
        # 查找并恢复数据库备份
        SQL_BACKUP="\$(dirname "\$BACKUP_FILE")/\$(basename "\$BACKUP_FILE" .tar.gz).sql.gz"
        if [ -f "\$SQL_BACKUP" ]; then
            log "恢复数据库中..."
            gunzip -c "\$SQL_BACKUP" | mysql -u $WP_DB_USER -p'$WP_DB_PASS' $WP_DB_NAME
        fi
        
        # 启动服务
        systemctl start nginx php$PHP_VERSION-fpm
        
        log "恢复完成"
        ;;
    
    logs)
        case "\$2" in
            nginx)
                tail -f /var/www/\$DOMAIN/logs/nginx-access.log
                ;;
            nginx-error)
                tail -f /var/www/\$DOMAIN/logs/nginx-error.log
                ;;
            php)
                tail -f /var/log/php$PHP_VERSION-fpm.log
                ;;
            mysql)
                tail -f /var/log/mysql/error.log
                ;;
            mysql-slow)
                tail -f /var/log/mysql/mysql-slow.log
                ;;
            redis)
                tail -f /var/log/redis/redis-server.log
                ;;
            fail2ban)
                tail -f /var/log/fail2ban.log
                ;;
            *)
                echo "可用日志:"
                echo "  nginx          - Nginx访问日志"
                echo "  nginx-error    - Nginx错误日志"
                echo "  php            - PHP-FPM日志"
                echo "  mysql          - MySQL错误日志"
                echo "  mysql-slow     - MySQL慢查询日志"
                echo "  redis          - Redis日志"
                echo "  fail2ban       - Fail2ban日志"
                ;;
        esac
        ;;
    
    update)
        log "更新WordPress..."
        cd /var/www/\$DOMAIN/public
        
        # 备份当前状态
        mysqldump -u $WP_DB_USER -p'$WP_DB_PASS' $WP_DB_NAME > /tmp/wp-backup-\$(date +%s).sql
        
        # 更新核心
        sudo -u www-data wp core update
        
        # 更新已安装的插件
        sudo -u www-data wp plugin update --all
        
        # 更新语言文件
        sudo -u www-data wp language core update
        
        # 清理缓存
        sudo -u www-data wp transient delete --expired
        
        log "WordPress更新完成"
        ;;
    
    optimize)
        log "优化数据库..."
        cd /var/www/\$DOMAIN/public
        
        # 优化数据库
        sudo -u www-data wp db optimize
        
        # 清理transients
        sudo -u www-data wp transient delete --expired
        sudo -u www-data wp transient delete --all
        
        # 清理修订版
        sudo -u www-data wp post delete \$(sudo -u www-data wp post list --post_type='revision' --format=ids) 2>/dev/null || true
        
        # 清理自动草稿
        sudo -u www-data wp post delete \$(sudo -u www-data wp post list --post_status=auto-draft --format=ids) 2>/dev/null || true
        
        # 清理垃圾
        sudo -u www-data wp post delete \$(sudo -u www-data wp post list --post_status=trash --format=ids) 2>/dev/null || true
        
        # 清理缓存
        sudo -u www-data wp cache flush
        
        log "数据库优化完成"
        ;;
    
    security)
        log "执行安全检查..."
        cd /var/www/\$DOMAIN/public
        
        # 检查文件权限
        echo "=== 文件权限检查 ==="
        find . -type f -perm /o+w -ls | head -20
        
        # 检查可疑文件
        echo -e "\\n=== 可疑文件检查 ==="
        find . -name "*.php" -exec grep -l "base64_decode\|eval\|system\|shell_exec\|passthru\|phpinfo" {} \; | head -10
        
        # 检查用户
        echo -e "\\n=== 用户检查 ==="
        sudo -u www-data wp user list
        
        # 检查插件
        echo -e "\\n=== 插件检查 ==="
        sudo -u www-data wp plugin status
        
        log "安全检查完成"
        ;;
    
    info)
        echo "=== 站点信息 ==="
        echo "域名: \$DOMAIN"
        echo "路径: /var/www/\$DOMAIN"
        echo "PHP版本: $PHP_VERSION"
        echo "数据库: $WP_DB_NAME"
        echo "数据库用户: $WP_DB_USER"
        echo "管理员: $ADMIN_USER"
        
        echo -e "\\n=== 服务信息 ==="
        echo "PHP: \$(php -v | head -n1)"
        echo "Nginx: \$(nginx -v 2>&1)"
        echo "MySQL: \$(mysql -V)"
        echo "Redis: \$(redis-server -v | head -n1)"
        
        echo -e "\\n=== 磁盘信息 ==="
        df -h /var/www/\$DOMAIN
        
        echo -e "\\n=== 内存信息 ==="
        free -h
        ;;
    
    monitor)
        echo "监控模式启动，按Ctrl+C退出..."
        echo "时间,负载,内存,磁盘,连接"
        
        while true; do
            LOAD=\$(uptime | awk -F'load average:' '{print \$2}' | sed 's/ //g')
            MEM=\$(free -m | awk 'NR==2{printf "%.1f%%", \$3*100/\$2}')
            DISK=\$(df -h / | awk 'NR==2{print \$5}')
            CONN=\$(netstat -ant | grep :80 | wc -l)
            
            echo "\$(date '+%H:%M:%S'),\$LOAD,\$MEM,\$DISK,\$CONN"
            sleep 5
        done
        ;;
    
    help|*)
        echo "使用方法: manage-\$DOMAIN {command}"
        echo ""
        echo "命令:"
        echo "  status          - 显示服务状态"
        echo "  restart         - 重启所有服务"
        echo "  cache-clear     - 清除所有缓存（包括Nginx FastCGI和Redis）"
        echo "  backup          - 创建站点备份"
        echo "  restore <file>  - 从备份恢复"
        echo "  logs {type}     - 查看日志"
        echo "  update          - 更新WordPress核心和插件"
        echo "  optimize        - 优化数据库"
        echo "  security        - 安全检查"
        echo "  info            - 显示站点信息"
        echo "  monitor         - 实时监控"
        echo "  help            - 显示帮助"
        ;;
esac
EOF
    
    chmod +x /usr/local/bin/manage-$DOMAIN
    log_message "SUCCESS" "管理脚本创建完成"
    mark_complete "create_management_script"
}

# --- 重启服务 ---
restart_services() {
    if load_progress "restart_services"; then
        log_message "INFO" "服务已重启，跳过..."
        return
    fi
    
    log_message "TASK" "重启所有服务..."
    
    systemctl restart nginx php$PHP_VERSION-fpm mysql redis-server fail2ban
    systemctl enable nginx php$PHP_VERSION-fpm mysql redis-server fail2ban
    
    # 检查服务状态
    log_message "INFO" "检查服务状态..."
    
    for service in nginx php$PHP_VERSION-fpm mysql redis-server fail2ban; do
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
    echo -e "${GREEN}          WordPress部署完成！${NC}"
    echo -e "${GREEN}============================================${NC}\\n"
    
    echo -e "${CYAN}=== 站点信息 ===${NC}"
    echo -e "主域名: ${GREEN}https://$PRIMARY_DOMAIN${NC}"
    echo -e "备用域名: ${GREEN}https://$ALT_DOMAIN${NC}"
    echo -e "站点标题: $SITE_TITLE"
    echo -e "安装路径: /var/www/$DOMAIN"
    echo -e "PHP版本: $PHP_VERSION"
    
    echo -e "\\n${CYAN}=== 管理员凭据 ===${NC}"
    echo -e "用户名: ${YELLOW}$ADMIN_USER${NC}"
    echo -e "密码: ${RED}$ADMIN_PASS${NC}"
    echo -e "邮箱: $ADMIN_EMAIL"
    echo -e "登录地址: ${GREEN}https://$PRIMARY_DOMAIN/wp-admin${NC}"
    
    echo -e "\\n${CYAN}=== 数据库信息 ===${NC}"
    echo -e "数据库名: $WP_DB_NAME"
    echo -e "数据库用户: $WP_DB_USER"
    echo -e "数据库密码: ${RED}$WP_DB_PASS${NC}"
    echo -e "MySQL Root密码: ${RED}$MYSQL_ROOT_PASS${NC}"
    
    echo -e "\\n${CYAN}=== Redis信息 ===${NC}"
    echo -e "Redis密码: ${RED}$REDIS_PASS${NC}"
    
    echo -e "\\n${CYAN}=== 系统配置 ===${NC}"
    echo -e "PHP版本: $PHP_VERSION"
    echo -e "MySQL版本: $MYSQL_VERSION"
    echo -e "WooCommerce模式: $USE_WOOCOMMERCE"
    echo -e "Ubuntu版本: $(lsb_release -ds)"
    
    echo -e "\\n${CYAN}=== 已安装的优化组件 ===${NC}"
    echo -e "✓ Nginx FastCGI缓存"
    echo -e "✓ Redis对象缓存插件"
    if [[ "$USE_WOOCOMMERCE" == "yes" ]]; then
        echo -e "✓ WooCommerce插件"
    fi
    
    echo -e "\\n${CYAN}=== 管理命令 ===${NC}"
    echo -e "站点管理: ${GREEN}manage-$DOMAIN {command}${NC}"
    echo -e "查看状态: manage-$DOMAIN status"
    echo -e "清除缓存: manage-$DOMAIN cache-clear"
    echo -e "创建备份: manage-$DOMAIN backup"
    echo -e "更新WordPress: manage-$DOMAIN update"
    
    echo -e "\\n${CYAN}=== 验证命令 ===${NC}"
    echo -e "检查HTTPS: curl -I https://$PRIMARY_DOMAIN"
    echo -e "检查SSL: openssl s_client -connect $PRIMARY_DOMAIN:443 -servername $PRIMARY_DOMAIN 2>/dev/null | openssl x509 -noout -dates"
    echo -e "检查PHP: curl https://$PRIMARY_DOMAIN/php-ping"
    echo -e "检查缓存: curl -I https://$PRIMARY_DOMAIN | grep X-FastCGI-Cache"
    
    echo -e "\\n${YELLOW}=== 重要提示 ===${NC}"
    echo -e "1. 立即保存上述凭据到安全位置"
    echo -e "2. 首次登录后立即修改管理员密码"
    echo -e "3. 配置每日备份: manage-$DOMAIN backup"
    echo -e "4. 监控服务器资源使用情况"
    echo -e "5. 保持系统和WordPress更新"
    echo -e "6. 已自动安装Redis缓存插件和FastCGI缓存"
    
    # 保存凭据到文件
    cat > /root/wordpress-credentials-$DOMAIN.txt << EOF
=== WordPress部署凭据 ===
部署时间: $(date)
主域名: https://$PRIMARY_DOMAIN
备用域名: https://$ALT_DOMAIN
PHP版本: $PHP_VERSION

=== WordPress管理员 ===
用户名: $ADMIN_USER
密码: $ADMIN_PASS
邮箱: $ADMIN_EMAIL
登录地址: https://$PRIMARY_DOMAIN/wp-admin

=== 数据库信息 ===
数据库名: $WP_DB_NAME
数据库用户: $WP_DB_USER
数据库密码: $WP_DB_PASS
MySQL Root密码: $MYSQL_ROOT_PASS

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

=== 已安装的优化组件 ===
1. Nginx FastCGI缓存 - 页面级缓存
2. Redis对象缓存插件 - 数据库查询缓存
3. WooCommerce插件: $USE_WOOCOMMERCE

=== 服务管理 ===
重启所有服务: systemctl restart nginx php$PHP_VERSION-fpm mysql redis-server
查看服务状态: systemctl status nginx php$PHP_VERSION-fpm mysql redis-server
查看日志: journalctl -u nginx -u php$PHP_VERSION-fpm -f

=== 性能优化说明 ===
1. Nginx FastCGI缓存: 缓存动态页面，显著提升加载速度
2. Redis缓存: 缓存数据库查询，减少数据库负载
3. 使用 manage-$DOMAIN cache-clear 清除所有缓存

保存时间: $(date)
EOF
    
    echo -e "\\n${YELLOW}凭据已保存到: /root/wordpress-credentials-$DOMAIN.txt${NC}"
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
    if openssl s_client -connect "$PRIMARY_DOMAIN:443" -servername "$PRIMARY_DOMAIN" 2>/dev/null | openssl x509 -noout -dates; then
        echo -e "${GREEN}✓ SSL证书安装正常${NC}"
    else
        echo -e "${RED}✗ SSL证书测试失败${NC}"
    fi
    
    # 测试数据库连接
    if mysql -u "$WP_DB_USER" -p"$WP_DB_PASS" -e "SELECT 1;" "$WP_DB_NAME" 2>/dev/null; then
        echo -e "${GREEN}✓ 数据库连接正常${NC}"
    else
        echo -e "${RED}✗ 数据库连接失败${NC}"
    fi
    
    # 测试PHP-FPM
    if curl -s "https://$PRIMARY_DOMAIN/php-ping" 2>/dev/null | grep -q "pong"; then
        echo -e "${GREEN}✓ PHP-FPM运行正常${NC}"
    else
        echo -e "${YELLOW}⚠ PHP-FPM状态页未启用${NC}"
    fi
    
    # 测试Redis插件
    echo -e "\\n${CYAN}=== Redis缓存插件状态 ===${NC}"
    cd /var/www/$DOMAIN/public
    sudo -u www-data wp redis status 2>/dev/null || echo -e "${YELLOW}⚠ Redis插件状态检查失败，可能需要手动检查${NC}"
}

# --- 主执行流程 ---
main() {
    init_script
    collect_input
    
    echo -e "\\n${CYAN}开始部署WordPress高性能环境...${NC}"
    echo -e "选择PHP版本: ${GREEN}$PHP_VERSION${NC}"
    echo -e "WooCommerce模式: ${GREEN}$USE_WOOCOMMERCE${NC}"
    echo -e "预计时间: 10-15分钟\\n"
    
    START_TIME=$(date +%s)
    
    # 执行部署步骤
    system_optimization
    install_nginx
    install_php
    install_mysql
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
    
    echo -e "\\n${GREEN}部署完成！总耗时: ${MINUTES}分${SECONDS}秒${NC}"
    
    show_summary
}

# 错误处理
trap 'log_message "ERROR" "在步骤执行过程中出错，请检查日志: $LOG_FILE"; exit 1' ERR

# 运行主函数
main "$@"