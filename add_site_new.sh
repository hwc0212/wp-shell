#!/bin/bash
# 功能：全自动部署WordPress站点（含缓存/日志/SSL自动化管理）
# 执行：sudo bash add_site.sh 域名 数据库名 数据库用户 数据库密码
# 示例：sudo bash add_site.sh example.com wp_db wp_user 'StrongPass123!'

# 参数检查
if [ $# -ne 4 ]; then
  echo "用法：sudo bash $0 域名 数据库名 数据库用户 数据库密码"
  exit 1
fi

DOMAIN=$1
DB_NAME=$2
DB_USER=$3
DB_PASS=$4
PHP_VERSION="8.3"
SITE_ROOT="/var/www/${DOMAIN}"

# 创建站点目录结构
mkdir -p ${SITE_ROOT}/{public_html,logs,cache,ssl}
chown -R www-data:www-data ${SITE_ROOT}
chmod 750 ${SITE_ROOT}/{cache,ssl}

# 创建数据库及用户
mysql -u root <<MYSQL_SCRIPT
CREATE DATABASE ${DB_NAME};
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

# 配置独立PHP-FPM进程池
PHP_POOL_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/${DOMAIN}.conf"
cat <<EOF > ${PHP_POOL_CONF}
[${DOMAIN}]
user = www-data
group = www-data
listen = ${SITE_ROOT}/php-fpm.sock
listen.owner = www-data
listen.group = www-data
pm = dynamic
pm.max_children = 20
pm.start_servers = 4
pm.min_spare_servers = 4
pm.max_spare_servers = 8
pm.max_requests = 500
php_admin_value[upload_max_filesize] = 50M
php_admin_value[post_max_size] = 55M
php_admin_value[error_log] = ${SITE_ROOT}/logs/php-error.log
php_admin_value[opcache.file_cache] = ${SITE_ROOT}/opcache
EOF
systemctl restart php${PHP_VERSION}-fpm

# 生成Nginx配置文件
cat <<EOF > /etc/nginx/sites-available/${DOMAIN}
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    root ${SITE_ROOT}/public_html;
    index index.php index.html;

    access_log ${SITE_ROOT}/logs/access.log;
    error_log ${SITE_ROOT}/logs/error.log warn;

    # FastCGI缓存配置
    fastcgi_cache_path ${SITE_ROOT}/cache levels=1:2 keys_zone=WORDPRESS_${DOMAIN}:100m inactive=60m;

    # 安全头部
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Content-Security-Policy "default-src 'self' https: data: 'unsafe-inline' 'unsafe-eval';" always;

    # PHP处理
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${SITE_ROOT}/php-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;

        # FastCGI缓存
        fastcgi_cache WORDPRESS_${DOMAIN};
        fastcgi_cache_valid 200 301 302 1h;
        fastcgi_cache_use_stale error timeout updating http_500;
        add_header X-Cache \$upstream_cache_status;
    }

    # 静态文件缓存
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)\$ {
        expires 365d;
        access_log off;
        add_header Cache-Control "public";
    }

    # 阻止敏感文件访问
    location ~* (\.env|\.git|wp-config\.php|/wp-content/uploads/.*\.php) {
        deny all;
        return 444;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
}
EOF

# 启用Nginx配置
ln -s /etc/nginx/sites-available/${DOMAIN} /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# 申请SSL证书
certbot --nginx -d ${DOMAIN} -d www.${DOMAIN} --non-interactive --agree-tos -m admin@${DOMAIN} --cert-path ${SITE_ROOT}/ssl/cert.pem --key-path ${SITE_ROOT}/ssl/key.pem --redirect

# 安装WordPress
sudo -u www-data wp core download --path=${SITE_ROOT}/public_html
sudo -u www-data wp config create --dbname=${DB_NAME} --dbuser=${DB_USER} --dbpass=${DB_PASS} --path=${SITE_ROOT}/public_html

# 安全加固
sed -i "/define('WP_DEBUG'/i define('DISALLOW_FILE_EDIT', true);" ${SITE_ROOT}/public_html/wp-config.php
sed -i "/define('WP_DEBUG'/i define('DISABLE_WP_CRON', true);" ${SITE_ROOT}/public_html/wp-config.php

# Redis缓存配置
sudo -u www-data wp config set WP_REDIS_HOST 127.0.0.1 --path=${SITE_ROOT}/public_html
sudo -u www-data wp config set WP_REDIS_PORT 6379 --path=${SITE_ROOT}/public_html
sudo -u www-data wp plugin install redis-cache --activate --path=${SITE_ROOT}/public_html
sudo -u www-data wp redis enable --path=${SITE_ROOT}/public_html

# 自动化任务配置
# 1. 系统Cron替代WP-Cron
(crontab -l 2>/dev/null; echo "*/15 * * * * curl -s -o /dev/null https://${DOMAIN}/wp-cron.php?doing_wp_cron >/dev/null 2>&1") | crontab -

# 2. FastCGI缓存自动清理
cat <<EOF > /scripts/clear_cache_${DOMAIN}.sh
#!/bin/bash
rm -rf ${SITE_ROOT}/cache/*
echo "\$(date) - ${DOMAIN}缓存已清理" >> ${SITE_ROOT}/logs/cache_clean.log
EOF
chmod +x /scripts/clear_cache_${DOMAIN}.sh
echo "0 2 * * * /bin/bash /scripts/clear_cache_${DOMAIN}.sh" | crontab -

# 3. 缓存预热
cat <<EOF > /scripts/warm_cache_${DOMAIN}.sh
#!/bin/bash
curl -s https://${DOMAIN}/wp-sitemap.xml | grep -oP '<loc>\K[^<]+' | xargs -I{} curl -s -o /dev/null -L {}
echo "\$(date) - ${DOMAIN}缓存已预热" >> ${SITE_ROOT}/logs/cache_warm.log
EOF
chmod +x /scripts/warm_cache_${DOMAIN}.sh
echo "0 3 * * * /bin/bash /scripts/warm_cache_${DOMAIN}.sh" | crontab -

# 4. 日志管理（Logrotate）
cat <<EOF > /etc/logrotate.d/nginx-${DOMAIN}
${SITE_ROOT}/logs/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 0640 www-data adm
    sharedscripts
    postrotate
        /usr/sbin/nginx -s reload
    endscript
}
EOF

echo "网站 ${DOMAIN} 已部署！访问 https://${DOMAIN}"
