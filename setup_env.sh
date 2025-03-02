#!/bin/bash
# 全自动环境初始化脚本 - 含硬件优化和安全加固

# 检测Root权限
if [ "$EUID" -ne 0 ]; then
  echo "请使用sudo运行此脚本"
  exit 1
fi

# 获取硬件配置
CPU_CORES=$(nproc)
TOTAL_MEM=$(free -m | awk '/Mem:/{print $2}')
SWAP_SIZE=$(free -m | awk '/Swap:/{print $2}')

# 安装核心组件
apt update && apt upgrade -y
apt install -y curl wget unzip git ufw nginx php-fpm php-cli php-mysql \
php-curl php-gd php-mbstring php-xml php-zip php-opcache php-redis \
mariadb-server mariadb-client redis-server fail2ban

# 配置防火墙
ufw default deny incoming
ufw allow ssh
ufw allow http
ufw allow https
ufw --force enable

# 动态优化Nginx配置
cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
worker_rlimit_nofile $((CPU_CORES * 1024));

events {
    worker_connections $((CPU_CORES * 1024));
    multi_accept on;
    use epoll;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 30;
    types_hash_max_size 2048;
    server_tokens off;
    
    open_file_cache max=$((CPU_CORES * 2000)) inactive=20s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;
    
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log off;
    error_log /var/log/nginx/error.log warn;
    
    # 全局FastCGI缓存路径
    fastcgi_cache_path /var/cache/nginx levels=1:2 keys_zone=GLOBAL_CACHE:100m inactive=60m use_temp_path=off;
    
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

# PHP动态优化
PHP_MEM=$((TOTAL_MEM / 4))M
cat > /etc/php/*/fpm/conf.d/optimization.ini <<EOF
opcache.enable=1
opcache.memory_consumption=$((TOTAL_MEM / 16))
opcache.max_accelerated_files=$((CPU_CORES * 2000))
opcache.validate_timestamps=0
memory_limit = ${PHP_MEM}
upload_max_filesize = 64M
post_max_size = 64M
EOF

# PHP-FPM进程优化
cat > /etc/php/*/fpm/pool.d/www.conf <<EOF
[www]
user = www-data
group = www-data
listen = /run/php/php-fpm.sock
pm = dynamic
pm.max_children = $((TOTAL_MEM / 70))
pm.start_servers = $((CPU_CORES * 2))
pm.min_spare_servers = $((CPU_CORES * 1))
pm.max_spare_servers = $((CPU_CORES * 3))
pm.max_requests = 1000
EOF

# MariaDB自动优化
INNODB_BUFFER=$((TOTAL_MEM * 70 / 100))M
cat > /etc/mysql/mariadb.conf.d/60-optimize.cnf <<EOF
[mysqld]
innodb_buffer_pool_size = ${INNODB_BUFFER}
innodb_log_file_size = $((TOTAL_MEM / 8))M
key_buffer_size = $((TOTAL_MEM / 10))M
query_cache_type = 0
thread_cache_size = $((CPU_CORES * 2))
max_connections = $((TOTAL_MEM / 20))
EOF

# 安装Certbot
snap install --classic certbot
ln -s /snap/bin/certbot /usr/bin/certbot

# Fail2ban防护规则
cat > /etc/fail2ban/jail.d/wordpress.conf <<EOF
[nginx-bruteforce]
enabled = true
port = http,https
filter = nginx-bruteforce
logpath = /var/www/*/logs/access.log
maxretry = 3
findtime = 600
bantime = 86400
EOF

cat > /etc/fail2ban/filter.d/nginx-bruteforce.conf <<EOF
[Definition]
failregex = ^<HOST>.*"(GET|POST).*/wp-login.php.* 404
            ^<HOST>.*POST.*/xmlrpc.php.* 403
ignoreregex =
EOF

# 创建缓存目录
mkdir -p /var/cache/nginx
chown -R www-data:www-data /var/cache/nginx

systemctl restart nginx php*-fpm mariadb fail2ban

echo "环境初始化完成！优化配置：CPU×${CPU_CORES} | 内存${TOTAL_MEM}MB | 缓存池${INNODB_BUFFER}"