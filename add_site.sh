#!/bin/bash
# 全自动站点部署脚本 - 含缓存优化和安全配置

# 检测Root权限
if [ "$EUID" -ne 0 ]; then
  echo "请使用sudo运行此脚本"
  exit 1
fi

# 获取输入参数
read -p "请输入完整域名（如 example.com）: " DOMAIN
DOMAIN_CLEAN=${DOMAIN//./_}
DB_NAME="${DOMAIN_CLEAN}"
DB_USER="${DOMAIN_CLEAN}"
DB_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9!%^*' | head -c 16)

# 创建目录结构
SITE_ROOT="/var/www/${DOMAIN}"
mkdir -p ${SITE_ROOT}/{public,logs,cache,ssl}
chown -R www-data:www-data ${SITE_ROOT}
chmod 750 ${SITE_ROOT}/{public,logs,cache}

# 生成Nginx优化配置
CPU_CORES=$(nproc)
cat > /etc/nginx/sites-available/${DOMAIN}.conf <<EOF
# 主服务器配置
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN} www.${DOMAIN};
    
    ssl_certificate ${SITE_ROOT}/ssl/fullchain.pem;
    ssl_certificate_key ${SITE_ROOT}/ssl/privkey.pem;
    
    root ${SITE_ROOT}/public;
    access_log ${SITE_ROOT}/logs/access.log buffer=16k flush=5m;
    error_log ${SITE_ROOT}/logs/error.log warn;
    
    # 缓存配置
    fastcgi_cache_path ${SITE_ROOT}/cache levels=1:2 keys_zone=${DOMAIN_CLEAN}:50m inactive=2h use_temp_path=off;
    
    # 安全头
    add_header X-Content-Type-Options "nosniff";
    add_header X-XSS-Protection "1; mode=block";
    add_header Content-Security-Policy "default-src 'self' https: data: 'unsafe-inline' 'unsafe-eval';";
    
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
        
        # 阻止用户枚举
        if (\$args ~* "^/?author=") { return 403; }
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$(ls /run/php/*.sock);
        
        # 动态缓存规则
        set \$skip_cache 0;
        if (\$request_method = POST) { set \$skip_cache 1; }
        if (\$query_string != "") { set \$skip_cache 1; }
        if (\$http_cookie ~* "wordpress_logged_in") { set \$skip_cache 1; }
        
        fastcgi_cache_bypass \$skip_cache;
        fastcgi_no_cache \$skip_cache;
        fastcgi_cache ${DOMAIN_CLEAN};
        fastcgi_cache_valid 200 301 302 1h;
        fastcgi_cache_lock on;
        add_header X-Cache-Status \$upstream_cache_status;
    }
    
    # 静态资源缓存
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2)\$ {
        expires 1y;
        add_header Cache-Control "public, no-transform";
        access_log off;
    }
    
    # 安全限制
    location ~* ^/(wp-config\.php|readme\.html|license\.txt) { 
        deny all; 
    }
    
    # 登录保护
    location = /wp-login.php {
        limit_req zone=one burst=3 nodelay;
        auth_pam "WordPress Admin";
        auth_pam_service_name "nginx";
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$(ls /run/php/*.sock);
    }
}

# 限速配置
limit_req_zone \$binary_remote_addr zone=one:10m rate=10r/m;
EOF

# 申请SSL证书
certbot certonly --nginx -d ${DOMAIN} -d www.${DOMAIN} \
--cert-path ${SITE_ROOT}/ssl/fullchain.pem \
--key-path ${SITE_ROOT}/ssl/privkey.pem \
--non-interactive --agree-tos

# 创建数据库
mysql -e "CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# 安装WordPress核心
sudo -u www-data wp core download --path=${SITE_ROOT}/public
sudo -u www-data wp config create --dbname=${DB_NAME} --dbuser=${DB_USER} \
--dbpass=${DB_PASS} --path=${SITE_ROOT}/public

# 高级安全配置
cat >> ${SITE_ROOT}/public/wp-config.php <<EOF
// 强化安全设置
define('AUTOMATIC_UPDATER_DISABLED', true);
define('DISALLOW_FILE_EDIT', true);
define('FORCE_SSL_ADMIN', true);
define('WP_HTTP_BLOCK_EXTERNAL', true);

// 调试配置
define('WP_DEBUG', true);
define('WP_DEBUG_LOG', '${SITE_ROOT}/logs/debug.log');
define('WP_DEBUG_DISPLAY', false);

// 缓存优化
define('WP_CACHE', true);
define('WP_REDIS_HOST', '127.0.0.1');
define('WP_REDIS_TIMEOUT', 1);

// 禁用内置Cron
define('DISABLE_WP_CRON', true);

// 文件权限
if (!defined('FS_CHMOD_DIR'))  define('FS_CHMOD_DIR', 0750);
if (!defined('FS_CHMOD_FILE')) define('FS_CHMOD_FILE', 0640);
EOF

# 配置系统Cron
CRON_JOB="*/15 * * * * curl -s -o /dev/null https://${DOMAIN}/wp-cron.php?doing_wp_cron"
(crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

# 设置文件权限
find ${SITE_ROOT}/public -type d -exec chmod 750 {} \;
find ${SITE_ROOT}/public -type f -exec chmod 640 {} \;
chmod 600 ${SITE_ROOT}/public/wp-config.php

# 自动清理任务
echo "0 3 * * * find ${SITE_ROOT}/cache -type f -mtime +7 -delete" | crontab -

systemctl reload nginx php*-fpm mariadb

# 输出安装信息
cat <<EOF

================ 部署完成 ================
访问地址: https://${DOMAIN}

数据库信息:
名称: ${DB_NAME}
用户: ${DB_USER}
密码: ${DB_PASS}

优化配置:
- FastCGI缓存路径: ${SITE_ROOT}/cache
- PHP内存限制: $(php -i | grep memory_limit)
- 数据库缓存池: $(mysql -Nse "SELECT @@innodb_buffer_pool_size/1024/1024" | awk '{print int($1)}')MB
===========================================
EOF