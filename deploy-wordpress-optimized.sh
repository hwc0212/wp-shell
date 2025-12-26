#!/bin/bash

# ======================================================================
# WordPress 高性能部署自动化脚本 (Cloudways/SpinupWP 增强版)
# ======================================================================
# 版本: 4.0
# 最后更新: 2025-12-23
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
PHP_VERSION="8.3"
MYSQL_VERSION="8.0"
USE_WOOCOMMERCE="no"

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
    echo "站点标题: $SITE_TITLE"
    echo "管理员用户名: $ADMIN_USER"
    echo "管理员邮箱: $ADMIN_EMAIL"
    echo "PHP版本: $PHP_VERSION"
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
    
    # 添加PPA
    add-apt-repository ppa:ondrej/php -y
    apt update
    
    # 安装PHP及扩展
    apt install -y php$PHP_VERSION-fpm php$PHP_VERSION-mysql php$PHP_VERSION-redis \
                   php$PHP_VERSION-cli php$PHP_VERSION-curl php$PHP_VERSION-gd \
                   php$PHP_VERSION-mbstring php$PHP_VERSION-xml php$PHP_VERSION-zip \
                   php$PHP_VERSION-intl php$PHP_VERSION-bcmath php$PHP_VERSION-imagick \
                   php$PHP_VERSION-soap
    
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
    sed -i "s/^pm.max_children = .*/pm.max_children = $max_children/" "$PHP_FPM_CONF"
    sed -i "s/^pm.start_servers = .*/pm.start_servers = $start_servers/" "$PHP_FPM_CONF"
    sed -i "s/^pm.min_spare_servers = .*/pm.min_spare_servers = $min_spare/" "$PHP_FPM_CONF"
    sed -i "s/^pm.max_spare_servers = .*/pm.max_spare_servers = $max_spare/" "$PHP_FPM_CONF"
    
    # 配置php.ini
    PHP_INI="/etc/php/$PHP_VERSION/fpm/php.ini"
    sed -i "s/^memory_limit = .*/memory_limit = $php_memory_limit/" "$PHP_INI"
    sed -i "s/^max_execution_time = .*/max_execution_time = 300/" "$PHP_INI"
    sed -i "s/^upload_max_filesize = .*/upload_max_filesize = 64M/" "$PHP_INI"
    sed -i "s/^post_max_size = .*/post_max_size = 64M/" "$PHP_INI"
    
    # 配置OPcache
    cat > /etc/php/$PHP_VERSION/fpm/conf.d/10-opcache.ini << EOF
zend_extension=opcache.so
opcache.enable=1
opcache.memory_consumption=256
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=10000
opcache.revalidate_freq=2
opcache.fast_shutdown=1
opcache.enable_cli=1
EOF
    
    if [[ "$PHP_VERSION" == "8.3" ]] || [[ "$PHP_VERSION" == "8.4" ]]; then
        echo "opcache.jit=1255" >> /etc/php/$PHP_VERSION/fpm/conf.d/10-opcache.ini
        echo "opcache.jit_buffer_size=256M" >> /etc/php/$PHP_VERSION/fpm/conf.d/10-opcache.ini
    fi
    
    systemctl restart php$PHP_VERSION-fpm
    log_message "SUCCESS" "PHP安装和优化完成"
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
innodb_buffer_pool_size = ${innodb_size_gb}G
innodb_log_file_size = 256M
innodb_log_buffer_size = 16M
innodb_flush_log_at_trx_commit = 1
innodb_file_per_table = 1
innodb_flush_method = O_DIRECT
max_connections = 200
thread_cache_size = 100
table_open_cache = 4096
table_definition_cache = 4096
slow_query_log = 1
slow_query_log_file = /var/log/mysql/mysql-slow.log
long_query_time = 2
log_queries_not_using_indexes = 1
EOF
    
    # 启动MySQL
    systemctl start mysql
    systemctl enable mysql
    
    # 安全配置
    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASS';"
    mysql -e "DELETE FROM mysql.user WHERE User='';"
    mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    mysql -e "DROP DATABASE IF EXISTS test;"
    mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
    mysql -e "FLUSH PRIVILEGES;"
    
    # 创建WordPress数据库
    mysql -u root -p"$MYSQL_ROOT_PASS" -e "CREATE DATABASE $WP_DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mysql -u root -p"$MYSQL_ROOT_PASS" -e "CREATE USER '$WP_DB_USER'@'localhost' IDENTIFIED BY '$WP_DB_PASS';"
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
    
    apt install -y redis-server php$PHP_VERSION-redis
    
    # 优化配置
    local total_mem=$(free -m | awk '/^Mem:/{print $2}')
    local redis_max_mem=$(( total_mem * 10 / 100 ))
    [[ $redis_max_mem -lt 128 ]] && redis_max_mem=128
    
    REDIS_CONF="/etc/redis/redis.conf"
    sed -i "s/^# requirepass .*/requirepass $REDIS_PASS/" "$REDIS_CONF"
    sed -i "s/^# maxmemory .*/maxmemory ${redis_max_mem}mb/" "$REDIS_CONF"
    sed -i "s/^# maxmemory-policy .*/maxmemory-policy allkeys-lru/" "$REDIS_CONF"
    
    systemctl restart redis-server
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
    else
        ufw allow 22/tcp
    fi
    
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
EOF
    
    cat > /etc/fail2ban/filter.d/wordpress.conf << EOF
[Definition]
failregex = ^<HOST>.*"POST.*wp-login.php.*" 200
            ^<HOST>.*"POST.*xmlrpc.php.*" 200
ignoreregex = ^<HOST>.*"POST.*wp-admin/admin-ajax.php.*"
EOF
    
    systemctl restart fail2ban
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
    snap install --classic certbot
    ln -s /snap/bin/certbot /usr/bin/certbot
    
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
    
    curl -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x /usr/local/bin/wp
    
    log_message "SUCCESS" "WP-CLI安装完成"
    mark_complete "install_wpcli"
}

# --- 配置Nginx站点 ---
configure_nginx_site() {
    if load_progress "configure_nginx_site"; then
        log_message "INFO" "Nginx配置已完成，跳过..."
        return
    fi
    
    log_message "TASK" "配置Nginx虚拟主机..."
    
    # 创建Nginx配置
    cat > /etc/nginx/sites-available/$DOMAIN << EOF
# HTTP重定向到HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $PRIMARY_DOMAIN $ALT_DOMAIN;
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
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:50m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 8.8.8.8 1.1.1.1 valid=300s;
    resolver_timeout 5s;
    
    # 安全头
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    
    # 日志
    access_log /var/www/$DOMAIN/logs/nginx-access.log;
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
    
    # 静态文件缓存
    location ~* \\.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
        expires 365d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }
    
    # 安全规则
    location ~ /\\. {
        deny all;
    }
    
    location ~ /(wp-config\\.php|xmlrpc\\.php) {
        deny all;
    }
    
    # PHP处理
    location ~ \\.php\$ {
        fastcgi_split_path_info ^(.+\\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php$PHP_VERSION-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        
        # FastCGI缓存
        fastcgi_cache WORDPRESS;
        fastcgi_cache_valid 200 1h;
        fastcgi_cache_use_stale error timeout updating http_500 http_503;
        fastcgi_cache_background_update on;
        fastcgi_cache_lock on;
        
        fastcgi_no_cache \$skip_cache;
        fastcgi_cache_bypass \$skip_cache;
        
        add_header X-FastCGI-Cache \$upstream_cache_status;
    }
    
    # WordPress重写规则
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
}
EOF
    
    # 启用站点
    ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
    
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
    
    # 临时停止Nginx
    systemctl stop nginx
    
    # 获取证书
    certbot certonly --standalone --agree-tos --non-interactive \
        --email "$ADMIN_EMAIL" \
        -d "$PRIMARY_DOMAIN" \
        -d "$ALT_DOMAIN" \
        --preferred-challenges http
    
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
    
    cd /var/www/$DOMAIN
    
    # 下载WordPress
    sudo -u www-data wp core download --locale=en_US
    
    # 创建配置文件
    sudo -u www-data wp config create \
        --dbname="$WP_DB_NAME" \
        --dbuser="$WP_DB_USER" \
        --dbpass="$WP_DB_PASS" \
        --dbhost="localhost" \
        --dbcharset="utf8mb4" \
        --dbcollate="utf8mb4_unicode_ci"
    
    # 获取安全密钥
    SECRET_KEYS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
    
    # 内存限制
    local wp_memory_limit="256M"
    local wp_max_memory_limit="512M"
    if [[ "$USE_WOOCOMMERCE" == "yes" ]]; then
        wp_memory_limit="512M"
        wp_max_memory_limit="1024M"
    fi
    
    # 添加高级配置
    cat >> public/wp-config.php << EOF

// 安全密钥
$SECRET_KEYS

// 强制SSL
define('FORCE_SSL_ADMIN', true);

// 禁用文件编辑
define('DISALLOW_FILE_EDIT', true);

// 内存限制
define('WP_MEMORY_LIMIT', '$wp_memory_limit');
define('WP_MAX_MEMORY_LIMIT', '$wp_max_memory_limit');

// Redis缓存
define('WP_REDIS_HOST', '127.0.0.1');
define('WP_REDIS_PORT', 6379);
define('WP_REDIS_PASSWORD', '$REDIS_PASS');

// 自动保存优化
define('AUTOSAVE_INTERVAL', 300);
define('WP_POST_REVISIONS', 10);

// 调试设置
define('WP_DEBUG', false);
define('WP_DEBUG_LOG', true);
define('WP_DEBUG_DISPLAY', false);
EOF
    
    # 安装WordPress
    sudo -u www-data wp core install \
        --url="https://$PRIMARY_DOMAIN" \
        --title="$SITE_TITLE" \
        --admin_user="$ADMIN_USER" \
        --admin_password="$ADMIN_PASS" \
        --admin_email="$ADMIN_EMAIL" \
        --skip-email
    
    # 设置固定链接
    sudo -u www-data wp rewrite structure '/%postname%/' --hard
    
    # 安装Redis缓存插件
    sudo -u www-data wp plugin install redis-cache --activate
    sudo -u www-data wp redis enable
    
    # 如果启用WooCommerce，安装插件
    if [[ "$USE_WOOCOMMERCE" == "yes" ]]; then
        sudo -u www-data wp plugin install woocommerce --activate
        log_message "INFO" "WooCommerce插件已安装"
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
    chmod -R 775 cache/
    chmod -R 775 logs/
    
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

case "\$1" in
    status)
        echo "=== 服务状态 ==="
        systemctl status nginx php$PHP_VERSION-fpm mysql redis-server fail2ban | grep -A 2 "Active:"
        
        echo -e "\\n=== 磁盘使用 ==="
        df -h / /var/www
        
        echo -e "\\n=== 内存使用 ==="
        free -h
        
        echo -e "\\n=== 缓存状态 ==="
        if [ -f "/var/www/\$DOMAIN/public/wp-content/object-cache.php" ]; then
            sudo -u www-data wp --path=/var/www/\$DOMAIN/public redis status
        fi
        ;;
    
    restart)
        echo "重启服务..."
        systemctl restart nginx php$PHP_VERSION-fpm mysql redis-server
        ;;
    
    cache-clear)
        echo "清除缓存..."
        rm -rf /var/www/\$DOMAIN/cache/*
        redis-cli -a '$REDIS_PASS' FLUSHALL
        echo "缓存已清除"
        ;;
    
    backup)
        echo "创建备份..."
        BACKUP_DIR="/var/www/\$DOMAIN/backups"
        BACKUP_FILE="backup-\$(date +%Y%m%d-%H%M%S).tar.gz"
        
        mkdir -p "\$BACKUP_DIR"
        
        # 备份数据库
        mysqldump -u $WP_DB_USER -p'$WP_DB_PASS' $WP_DB_NAME | gzip > "\$BACKUP_DIR/\${BACKUP_FILE%.tar.gz}.sql.gz"
        
        # 备份文件
        tar -czf "\$BACKUP_DIR/\$BACKUP_FILE" -C /var/www "\$DOMAIN"
        
        echo "备份完成: \$BACKUP_DIR/\$BACKUP_FILE"
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
                tail -f /var/log/mysql/mysql-slow.log
                ;;
            *)
                echo "可用日志:"
                echo "  nginx       - Nginx访问日志"
                echo "  nginx-error - Nginx错误日志"
                echo "  php         - PHP-FPM日志"
                echo "  mysql       - MySQL慢查询日志"
                ;;
        esac
        ;;
    
    update)
        echo "更新WordPress..."
        cd /var/www/\$DOMAIN/public
        sudo -u www-data wp core update
        sudo -u www-data wp plugin update --all
        sudo -u www-data wp theme update --all
        ;;
    
    optimize)
        echo "优化数据库..."
        cd /var/www/\$DOMAIN/public
        sudo -u www-data wp db optimize
        sudo -u www-data wp cache flush
        ;;
    
    info)
        echo "=== 站点信息 ==="
        echo "域名: \$DOMAIN"
        echo "路径: /var/www/\$DOMAIN"
        echo "数据库: $WP_DB_NAME"
        echo "管理员: $ADMIN_USER"
        
        echo -e "\\n=== 服务信息 ==="
        echo "PHP: \$(php -v | head -n1)"
        echo "MySQL: \$(mysql -V)"
        echo "Redis: \$(redis-server -v)"
        ;;
    
    help|*)
        echo "使用方法: manage-\$DOMAIN {command}"
        echo ""
        echo "命令:"
        echo "  status          - 显示服务状态"
        echo "  restart         - 重启所有服务"
        echo "  cache-clear     - 清除所有缓存"
        echo "  backup          - 创建站点备份"
        echo "  logs {type}     - 查看日志"
        echo "  update          - 更新WordPress"
        echo "  optimize        - 优化数据库"
        echo "  info            - 显示站点信息"
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
    
    echo -e "\\n${CYAN}=== 管理命令 ===${NC}"
    echo -e "站点管理: ${GREEN}manage-$DOMAIN {command}${NC}"
    echo -e "查看状态: manage-$DOMAIN status"
    echo -e "清除缓存: manage-$DOMAIN cache-clear"
    echo -e "创建备份: manage-$DOMAIN backup"
    
    echo -e "\\n${CYAN}=== 验证命令 ===${NC}"
    echo -e "检查HTTPS: curl -I https://$PRIMARY_DOMAIN"
    echo -e "检查缓存: curl -I https://$PRIMARY_DOMAIN | grep X-FastCGI-Cache"
    echo -e "检查SSL: openssl s_client -connect $PRIMARY_DOMAIN:443"
    
    echo -e "\\n${YELLOW}=== 安全提示 ===${NC}"
    echo -e "1. 立即保存上述凭据到安全位置"
    echo -e "2. 建议登录后台修改管理员密码"
    echo -e "3. 定期运行备份: manage-$DOMAIN backup"
    echo -e "4. 监控服务器资源使用情况"
    
    # 保存凭据到文件
    cat > /root/wordpress-credentials-$DOMAIN.txt << EOF
=== WordPress部署凭据 ===
部署时间: $(date)
主域名: https://$PRIMARY_DOMAIN
备用域名: https://$ALT_DOMAIN

=== WordPress管理员 ===
用户名: $ADMIN_USER
密码: $ADMIN_PASS
邮箱: $ADMIN_EMAIL

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
日志目录: /var/www/$DOMAIN/logs/

保存时间: $(date)
EOF
    
    echo -e "\\n${YELLOW}凭据已保存到: /root/wordpress-credentials-$DOMAIN.txt${NC}"
    
    # 清理状态文件
    rm -f "$STATE_FILE"
}

# --- 主执行流程 ---
main() {
    init_script
    collect_input
    
    echo -e "\\n${CYAN}开始部署WordPress高性能环境...${NC}"
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
    
    echo -e "\\n${GREEN}部署完成！总耗时: ${DURATION}秒${NC}"
    
    show_summary
}

# 错误处理
trap 'echo -e "${RED}[错误]${NC} 在步骤执行过程中出错，请检查日志: $LOG_FILE"; exit 1' ERR

# 运行主函数
main "$@"