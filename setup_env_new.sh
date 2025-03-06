#!/bin/bash
# 功能：部署服务器环境 + 全局Nginx/PHP/MySQL优化
# 执行：sudo bash setup_env.sh

# 检查Root权限
if [ "$EUID" -ne 0 ]; then
  echo "请使用sudo或root用户执行脚本"
  exit 1
fi

PHP_VERSION="8.3"

# 系统更新与内核优化
apt update && apt upgrade -y
apt install -y curl wget ufw htop git unzip

# 内核参数调优
cat <<EOF >> /etc/sysctl.conf
net.ipv4.tcp_syncookies = 1
net.core.somaxconn = 65535
vm.swappiness = 10
fs.file-max = 2097152
EOF
sysctl -p

# 文件描述符限制
echo "* soft nofile 65535" >> /etc/security/limits.conf
echo "* hard nofile 65535" >> /etc/security/limits.conf

# 防火墙配置
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# 安装Nginx及性能优化
apt install -y nginx

# Nginx全局配置优化
cat <<EOF > /etc/nginx/nginx.conf
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log off;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 30;
    keepalive_requests 1000;
    server_tokens off;
    client_max_body_size 50M;
    client_body_buffer_size 128k;

    # Brotli压缩
    brotli on;
    brotli_comp_level 6;
    brotli_types text/plain text/css application/json application/javascript text/xml application/xml image/svg+xml;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

# 安装MySQL及性能优化
apt install -y mysql-server
mysql_secure_installation <<EOF
n
y
y
y
y
EOF

cat <<EOF >> /etc/mysql/mysql.conf.d/mysqld.cnf
[mysqld]
innodb_buffer_pool_size = 4G
innodb_log_file_size = 512M
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2
EOF
systemctl restart mysql

# 安装PHP及深度优化
apt install -y php-fpm php-mysql php-curl php-gd php-mbstring php-xml php-zip php-opcache php-redis

# PHP全局配置优化
sed -i "s/^;disable_functions.*/disable_functions = exec,passthru,shell_exec,system,proc_open,popen,curl_exec,curl_multi_exec,parse_ini_file,show_source/" /etc/php/${PHP_VERSION}/fpm/php.ini

cat <<EOF >> /etc/php/${PHP_VERSION}/fpm/php.ini
opcache.enable=1
opcache.memory_consumption=256
opcache.max_accelerated_files=10000
opcache.revalidate_freq=60
upload_max_filesize = 50M
post_max_size = 55M
memory_limit = 512M
EOF

# 安装Redis和Certbot
apt install -y redis-server certbot python3-certbot-nginx
systemctl enable redis-server

echo "服务器环境部署完成！"
