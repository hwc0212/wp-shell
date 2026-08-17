# wp-shell

`wp-shell` 是一组面向 Ubuntu VPS 的 WordPress 部署与维护脚本。项目提供多站点管理版和单站点专用版，重点解决可重复部署、HTTPS、缓存、资源预算、备份恢复和基础安全配置。

项目定位是以轻量 CLI 和 systemd 工作流替代 Cloudways、SpinupWP 一类托管面板的常用部署与运维能力。它刻意不提供 Web 控制面板，不需要为面板常驻额外的 Web 服务、数据库或后台进程。

- 多站点管理器：`wp-vps-manager.sh` v8.1.0
- 单站点部署器：`deploy-single-wordpress.sh` v2.1.0
- 支持系统：Ubuntu 22.04 / 24.04 LTS
- 项目地址：https://github.com/hwc0212/wp-shell
- 作者：https://huwencai.com

> 重要：脚本会安装软件包并修改 Nginx、PHP-FPM、MariaDB、Redis、Fail2ban、UFW 和 systemd 配置。请先在测试服务器验证，并在操作已有服务器前创建独立备份。

## 选择哪个脚本

| 场景 | 推荐脚本 | 说明 |
|---|---|---|
| 一台 VPS 管理多个独立 WordPress 站点 | `wp-vps-manager.sh` | 每站点可选择 PHP 版本，具有独立 FastCGI 缓存目录、Redis DB 和管理命令 |
| 一台 VPS 只运行一个重点站点 | `deploy-single-wordpress.sh` | 使用单站点资源预算，可选择 apex 或 `www` 作为主域名 |
| 已有 WordPress 站点需要纳入备份和状态管理 | `wp-vps-manager.sh import` | 只登记站点，不自动替换已有 Nginx、证书或数据库配置 |

## v8/v2 的主要改进

- 使用 `set -Eeuo pipefail`、进程锁和明确错误步骤，避免静默失败和并发修改。
- 站点配置采用不可执行的数据格式，不再 `source` 用户输入生成的 Shell 文件。
- 首次部署先启用 HTTP ACME 站点，证书成功后才原子切换完整 HTTPS 配置。
- Nginx 配置先执行 `nginx -t`，失败会恢复原配置。
- 不再整体覆盖 `/etc/nginx/nginx.conf`，也不会执行 `ufw reset`。
- MariaDB、Redis 和 PHP-FPM 共用统一内存预算，避免各服务分别占用大部分系统内存。
- 多站点使用独立 Redis DB 和域名前缀，清理一个站点不会 `FLUSHDB` 影响其他站点。
- 管理脚本不再内嵌数据库或 Redis 密码；凭据文件均为 `0600`。
- 备份包含文件、数据库、元数据和 SHA-256 校验，恢复前自动创建安全备份。
- 每个站点的 `public`、日志、FastCGI 缓存和备份统一收纳在 `/var/www/DOMAIN/` 下。
- 自动备份改用 systemd timer，不再重复追加 crontab。
- 默认关闭 PHP JIT；WordPress 常见负载优先使用 OPcache，并预留真实 PHP-FPM 内存。
- CI 会执行 Bash 语法检查、安全模式检查和 ShellCheck。

## 系统要求

### 必需条件

- 全新的或可控的 Ubuntu 22.04/24.04 LTS VPS
- 至少 1GB 内存
- 至少 8GB 根分区可用空间
- root 或 sudo 权限
- 域名已解析到服务器
- 公网可以访问 TCP 80 和 443

不再支持 256MB/512MB VPS。现代 WordPress、PHP-FPM、MariaDB、Redis 和系统服务在这种配置下很难同时保持可预测的稳定性。

### 多站点建议上限

脚本会在部署前执行硬性检查：

| 内存 | 建议最大站点数 |
|---|---:|
| 1GB–2GB | 1 |
| 2GB–4GB | 2 |
| 4GB–8GB | 4 |
| 8GB+ | 8 |

实际容量仍取决于主题、插件、访问量和 WooCommerce 使用情况。高流量或电商站点应明显低于表中上限。

## 部署前准备

1. 为主域名配置 A/AAAA 记录。
2. 如果选择包含 `www`，也必须提前配置 `www` 的 DNS 记录。
3. 确认云厂商安全组允许当前 SSH 端口、80 和 443。
4. 已有服务器请备份 `/etc`、网站文件和数据库。
5. 不要同时运行两个部署或管理命令；脚本也会使用 `flock` 阻止并发执行。

## 多站点部署

```bash
wget https://raw.githubusercontent.com/hwc0212/wp-shell/main/wp-vps-manager.sh
chmod +x wp-vps-manager.sh
sudo ./wp-vps-manager.sh
```

首次运行会依次：

1. 收集站点、PHP、管理员和可选 `www` 信息。
2. 检查内存、磁盘和站点数量。
3. 安装 Nginx、MariaDB、Redis、PHP-FPM、Certbot、WP-CLI、Fail2ban 等组件。
4. 按整体内存预算配置 MariaDB、Redis 和所有 PHP-FPM 版本。
5. 为每个站点创建独立数据库、缓存区和 Redis DB。
6. 先部署 ACME HTTP 配置，再申请证书并切换 HTTPS。
7. 安装 WordPress、Redis Object Cache 和可选 WooCommerce。
8. 安装管理命令和每日自动备份 timer。
9. 询问是否启用 UFW；启用时保留现有规则，并先允许当前 SSH 端口。

### 多站点命令

```bash
sudo wp-vps-manager list
sudo wp-vps-manager status
sudo wp-vps-manager add-site
sudo wp-vps-manager deploy example.com
sudo wp-vps-manager import
sudo wp-vps-manager optimize
sudo wp-vps-manager security-scan
```

每个标准部署站点都会生成一个无密钥包装命令：

```bash
manage-example.com status
manage-example.com info
manage-example.com cache-clear
manage-example.com backup
manage-example.com backups
manage-example.com restore 20260817-020000
manage-example.com update
manage-example.com restart
```

也可以直接使用全局命令：

```bash
sudo wp-vps-manager backup example.com
sudo wp-vps-manager backup-all
sudo wp-vps-manager restore example.com 20260817-020000
sudo wp-vps-manager site example.com cache-clear
```

## 单站点部署

```bash
wget https://raw.githubusercontent.com/hwc0212/wp-shell/main/deploy-single-wordpress.sh
chmod +x deploy-single-wordpress.sh
sudo ./deploy-single-wordpress.sh
```

部署过程中可以选择：

- PHP 8.2、8.3 或 8.4
- 只使用根域名，或同时包含 `www`
- 根域名或 `www` 作为 WordPress 主地址
- 是否安装 WooCommerce

部署完成后使用：

```bash
manage-example.com status
manage-example.com cache-clear
manage-example.com backup
manage-example.com backups
manage-example.com restore 20260817-020000
manage-example.com update
manage-example.com optimize
manage-example.com security-scan
```

重新应用配置不会重新生成数据库或管理员密码：

```bash
sudo ./deploy-single-wordpress.sh --reconfigure
```

## 备份与恢复

### 备份内容

每个备份目录包含：

```text
files.tar.gz       WordPress 文件
database.sql.gz    MariaDB 数据库
manifest.txt       域名、时间和 WordPress 版本
SHA256SUMS         完整性校验
```

多站点和单站点使用相同的站点内备份布局：

```text
/var/www/DOMAIN/backups/TIMESTAMP/
```

备份目录位于站点的 `public` 文档根目录之外，并使用 root `0700` 权限，不会由 Nginx 对外提供。

默认保留 14 天。可以在执行部署脚本时设置：

```bash
sudo BACKUP_RETENTION_DAYS=30 ./wp-vps-manager.sh
```

恢复流程会：

1. 校验 `SHA256SUMS`。
2. 自动为当前状态创建一份恢复前备份。
3. 启用 WordPress 维护模式。
4. 原样恢复网站文件和数据库。
5. 重设文件权限并清理站点缓存。

### 自动备份

```bash
systemctl status wp-vps-backup.timer     # 多站点
systemctl status wp-single-backup.timer  # 单站点
systemctl list-timers --all | grep wp-
```

自动备份使用 systemd timer，每天约 02:00 执行，并带有随机延迟。服务器关机错过计划后，会在恢复运行时补执行。

本地备份无法防范整台 VPS 或磁盘损坏。生产环境还应使用 `rclone`、对象存储或其他工具把 `/var/www/*/backups` 同步到异地，并定期执行恢复演练。

## 缓存设计

每个站点包含三层缓存：

- Nginx FastCGI 页面缓存：独立目录和 16MB keys zone。
- Redis Object Cache：多站点分别使用 Redis DB 0–15，并设置域名前缀。
- PHP OPcache：默认启用，JIT 默认关闭。

FastCGI 会跳过 POST、查询字符串、WordPress 后台、登录、Cron、XML-RPC、WooCommerce 购物车/结账/账户页面，以及登录和购物车 Cookie。

如果使用特殊会员、支付、语言或个性化插件，应继续扩展对应站点的 Nginx 跳过规则，并在生产流量下验证缓存行为。

## 资源预算

脚本不会再把 70% 内存分给 MariaDB、同时把 80% 分给 PHP。新的预算会先为系统保留内存，再计算：

- 多站点 MariaDB：约总内存 30%，有上下限。
- 单站点 MariaDB：约总内存 35%，有上下限。
- Redis：约总内存 5%，32–512MB。
- PHP-FPM：使用剩余预算，按约 96MB/进程估算，并设置最大进程数。
- FastCGI keys zone：每个站点 16MB。

这是一套安全初始值，不替代基于真实流量的调优。上线后应观察 PHP-FPM RSS、MariaDB buffer pool 命中率、慢查询、磁盘延迟和缓存命中率。

## 安全措施

- 配置目录和数据库密码文件为 root `0600`。
- Redis 只监听回环地址，启用密码和 protected mode。
- 管理包装器不包含数据库或 Redis 密码。
- 部署日志为 `0600`，不会输出生成的密码。
- `wp-config.php` 使用 `0640`，禁止在线文件编辑。
- 不公开 PHP-FPM status/ping 页面。
- UFW 不重置现有规则，并优先识别当前 SSH 连接端口。
- Fail2ban 只启用系统自带并可验证的 SSH/Nginx 认证规则，不使用可能误封成功登录的 WordPress POST 规则。
- HTTPS 配置启用 TLS 1.2/1.3、HSTS（不自动 preload）和常用安全响应头。

管理员密码只在首次安装时生成，并保存在：

```text
/root/wordpress-credentials-DOMAIN.txt
/root/wordpress-single-credentials-DOMAIN.txt
```

文件权限为 `0600`。首次登录后仍建议将凭据转移到密码管理器并删除明文文件。

## 重要文件

### 多站点

```text
/etc/wp-vps-manager/sites.v2                 站点清单（不可执行数据格式）
/etc/wp-vps-manager/databases/               每站点数据库凭据
/etc/wp-vps-manager/redis.secret             Redis 密码
/usr/local/sbin/wp-vps-manager               安装后的完整管理器
/usr/local/bin/manage-DOMAIN                  无密钥站点包装器
/var/www/DOMAIN/public                        标准站点目录
/var/www/DOMAIN/logs                          Nginx 站点日志
/var/www/DOMAIN/cache                         FastCGI 缓存
/var/www/DOMAIN/backups                       本地备份
/var/log/wp-shell                             部署与管理日志
```

### 单站点

```text
/etc/wp-single-deploy/site.v2                 站点配置
/etc/wp-single-deploy/database.v1             数据库凭据
/etc/wp-single-deploy/redis.secret            Redis 密码
/usr/local/sbin/wp-single-manager             安装后的管理器
/usr/local/bin/manage-DOMAIN                  无密钥站点包装器
/var/www/DOMAIN/public                        WordPress 目录
/var/www/DOMAIN/logs                          Nginx 站点日志
/var/www/DOMAIN/cache                         FastCGI 缓存
/var/www/DOMAIN/backups                       本地备份
/var/log/wp-shell                             部署与管理日志
```

## 从 v7/旧单站点脚本升级

v8 不会执行旧版 `~/.vps-manager/wordpress-sites.conf`，因为旧格式本质上是可执行 Shell 配置，且无法安全解析任意历史输入。

推荐迁移流程：

1. 备份旧站点、数据库和 `/etc/nginx`。
2. 下载新的 `wp-vps-manager.sh`。
3. 运行 `sudo ./wp-vps-manager.sh import` 登记现有 WordPress 路径。
4. 使用 `sudo wp-vps-manager list` 核对站点。
5. 先执行一次手动备份并检查 `SHA256SUMS`。
6. 不要对导入站点直接执行 `deploy`，除非确定要让脚本接管其 Nginx、证书和缓存配置。

导入命令只添加管理记录和包装命令，不会自动替换现有 Nginx、SSL、数据库或 Redis 设置。

如果旧版本已在 `/var/backups/wp-shell/DOMAIN` 或 `/var/backups/wp-shell-single/DOMAIN` 保存备份，新脚本首次访问该站点的备份功能时会把旧备份安全复制到 `/var/www/DOMAIN/backups`，且不会覆盖同名新备份或删除旧目录。重新部署或重配后，Nginx 会改用 `/var/www/DOMAIN/cache`；缓存清理命令在迁移期间会同时清理新旧缓存目录。

## 故障排除

### 查看日志

```bash
ls -lt /var/log/wp-shell/
tail -f /var/log/wp-shell/wp-vps-manager-*.log
tail -f /var/log/wp-shell/wp-single-deploy-*.log
```

### 验证服务

```bash
nginx -t
systemctl status nginx mariadb redis-server fail2ban
systemctl status php8.3-fpm
certbot certificates
```

### 证书失败

```bash
getent ahosts example.com
getent ahosts www.example.com
ss -ltnp | grep -E ':(80|443)\b'
ufw status verbose
```

如果选择了 `www`，但其 DNS 没有解析，证书申请会主动停止。修复 DNS 后重新运行：

```bash
sudo wp-vps-manager deploy example.com
# 或单站点
sudo ./deploy-single-wordpress.sh --reconfigure
```

### 恢复验证

```bash
cd /var/www/example.com/backups/20260817-020000
sha256sum --check SHA256SUMS
```

## 开发与检查

本地静态检查：

```bash
bash tests/static-checks.sh
bash tests/config-roundtrip.sh
bash tests/render-nginx.sh
bash tests/storage-layout.sh
docker run --rm -v "$PWD:/mnt:ro" koalaman/shellcheck:stable \
  -x /mnt/wp-vps-manager.sh /mnt/deploy-single-wordpress.sh \
  /mnt/tests/static-checks.sh /mnt/tests/config-roundtrip.sh \
  /mnt/tests/render-nginx.sh /mnt/tests/storage-layout.sh \
  /mnt/tests/nginx-integration.sh \
  /mnt/tests/service-config-integration.sh
```

GitHub Actions 还会在 Ubuntu 24.04 容器中用真实的 Nginx、MariaDB、Redis 和 PHP-FPM 解析生成的服务配置，并在每次 push 和 pull request 时执行完整检查。

## 设计取舍与当前边界

不提供 Web 控制面板是本项目的明确设计目标，而不是待补功能。站点管理通过 Shell 命令、WP-CLI 和 systemd 完成，以减少常驻资源、额外攻击面和面板自身的升级维护工作。

项目目标是覆盖单机 WordPress VPS 的常用部署与运维流程，不会复制托管平台的完整控制平面，也没有宣称支持以下能力：

- 一键克隆站点
- 自动跨服务器迁移
- 自动域名替换
- 交互式 PHP 大版本迁移
- 云端/异地备份上传
- 集群、高可用或数据库复制

这些操作可以通过 WP-CLI、rsync、对象存储和供应商工具完成，但在没有完整验证和回滚机制前不会作为菜单中的“已完成”功能展示。

## 免责声明

本项目按现状提供。生产环境使用前，请在相同 Ubuntu/PHP 组合上测试，并保留可在服务器之外恢复的备份。作者不对脚本使用导致的数据丢失、停机或服务中断承担责任。

## License

MIT
