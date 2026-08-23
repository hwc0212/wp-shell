# wp-shell

`wp-shell` 是一个面向 Ubuntu VPS 的 WordPress 部署与运维脚本，目标是在不安装 Web 控制面板的前提下，覆盖 Cloudways、SpinupWP 等托管面板中最常用的单机部署、站点管理、监控、备份和资源调优能力。

项目不需要常驻的面板 Web 服务、面板数据库或额外后台应用。服务器管理通过 Shell、WP-CLI 和 systemd 完成，更适合希望节省 VPS 资源、减少攻击面，并愿意通过 SSH 管理服务器的用户。

- 当前版本：`wp-shell.sh` v9.4.3
- 支持系统：Ubuntu 22.04 / 24.04 LTS
- 支持架构：x86_64、aarch64
- GitHub：<https://github.com/hwc0212/wp-shell>
- 作者：<https://huwencai.com>

> 重要：脚本会安装软件包，并修改 Nginx、PHP-FPM、MariaDB、Redis、Certbot、Fail2ban、UFW、logrotate 和 systemd 配置。首次使用请优先在测试 VPS 上验证。接管已有生产服务器前，务必准备服务器外部备份和可用的恢复方案。

## 项目特点

- 使用一个统一入口 `wp-shell.sh` 管理单站点和多站点环境。
- 每个网站拥有独立的 PHP-FPM pool、Unix socket、状态 socket、进程额度和 PHP 日志。
- 每个网站拥有独立的 FastCGI 缓存目录、Redis DB、数据库账号、日志和备份目录。
- 通过本地 SQLite 保存服务器和各网站的历史指标。
- 提供适合 SSH 单屏显示的 `htop` 风格终端看板。
- 可按域名查看请求量、状态码、P95 延迟、缓存命中率、PHP 内存、磁盘占用、TLS 和备份状态。
- 可根据一段时间的历史数据生成资源分析和安全的 PHP-FPM 调整建议。
- 自动迁移旧版多站点脚本和单站点脚本的配置。
- 不提供 Web 控制面板，不开放远程监控端口，不上传遥测数据。

旧文件名 `wp-vps-manager.sh` 和 `deploy-single-wordpress.sh` 仍然保留，但它们现在只是兼容包装器。新安装和新自动化任务应统一使用 `wp-shell.sh` 或安装后的 `wp-shell` 命令。

## 一、使用前准备

### 1. VPS 最低要求

- Ubuntu 22.04 或 Ubuntu 24.04 LTS
- 至少 1GB 内存
- 根分区至少有 8GB 可用空间
- 可以使用 root 或 sudo
- 域名已经解析到当前 VPS
- 云厂商安全组允许 TCP 80 和 443
- SSH 端口没有被云防火墙阻止

不建议在 512MB 或更小的 VPS 上运行现代 WordPress、MariaDB、Redis 和 PHP-FPM 组合。

### 2. 建议站点数量

脚本会根据物理内存限制可以管理的站点数量：

| VPS 内存 | 默认允许的最大站点数 |
|---|---:|
| 1GB 至 2GB | 1 |
| 2GB 至 4GB | 2 |
| 4GB 至 8GB | 4 |
| 8GB 及以上 | 8 |

这是安全上限，不代表一定能承受对应数量的高流量网站。WooCommerce、页面构建器、大量插件、未命中缓存的动态请求都会显著降低实际容量。

### 3. DNS 准备

假设需要部署 `example.com`：

```text
example.com      A      VPS_IPV4
www.example.com  A      VPS_IPV4
```

如果不使用 `www`，只需要配置根域名。如果在安装时选择证书包含 `www.example.com`，则 `www` 必须提前解析成功，否则 Certbot 会停止申请证书。

可以在部署前检查：

```bash
getent ahosts example.com
getent ahosts www.example.com
```

### 4. 已有服务器备份

接管已有服务器前，至少备份：

```text
/etc/nginx/
/etc/php/
/etc/mysql/
/etc/redis/
/var/www/
所有 WordPress 数据库
```

本地备份无法防止整台 VPS 或磁盘损坏，因此生产环境还应把备份复制到对象存储或其他服务器。

## 二、在全新 VPS 上安装

### 1. 下载主脚本

```bash
wget https://raw.githubusercontent.com/hwc0212/wp-shell/main/wp-shell.sh
chmod +x wp-shell.sh
```

也可以使用 Git：

```bash
git clone https://github.com/hwc0212/wp-shell.git
cd wp-shell
```

### 2. 启动主菜单

```bash
sudo ./wp-shell.sh
```

在全新 VPS 上，脚本检测不到完整的 Nginx、PHP-FPM 和数据库环境时，会显示：

```text
Environment: WordPress stack not detected

1) Install WordPress environment
2) Import an existing WordPress site
3) Show command help
0) Exit
```

选择 `1` 开始安装 WordPress 环境。

如果不需要菜单，也可以直接启动安装向导：

```bash
sudo ./wp-shell.sh install
```

环境安装向导只询问三类服务器级设置，不会询问域名或 WordPress 管理员信息：

1. 部署模式：`Single website` 或 `Multiple websites`。
2. 环境统一使用的 PHP 版本：8.2、8.3 或 8.4。
3. 是否启用并配置 UFW。

选择 `Single website` 后只能添加一个网站；适合整台 VPS 只运行一个 WordPress 的情况。选择 `Multiple websites` 后可以继续添加网站，但仍受服务器内存上限和最多 16 个 Redis DB 的限制。部署模式不是 WordPress Multisite，它表示这台 VPS 允许 wp-shell 管理一个还是多个相互独立的网站。

UFW 选项只处理服务器防火墙。选择启用时，脚本会保留当前 SSH 端口，开放 SSH、HTTP 和 HTTPS，不执行 `ufw reset`；如果云厂商还提供安全组或云防火墙，仍需在云平台开放相同端口。

完成三项选择后，环境设置写入 `/etc/wp-shell/environment.v1`。即使当前还没有网站，再次运行 `sudo wp-shell` 也会进入完整管理菜单。

安装结束时会显示一屏环境摘要，包括：

- wp-shell 版本、单网站或多网站模式、PHP 版本。
- 检测到的公网 IPv4 和私网 IPv4。
- UFW 状态、当前网站数和安全容量上限。
- Nginx、PHP-FPM、MariaDB、Redis、Fail2ban 状态。
- 自动备份和指标采集 timer 状态。

脚本会优先通过 AWS EC2 本地元数据和网卡地址检测公网 IPv4，不使用第三方公网 IP 查询服务。如果无法可靠检测，会显示 `not detected`，此时应到 VPS 云厂商控制台查找或分配公网 IPv4。不要把 `10.x.x.x`、`172.16-31.x.x` 或 `192.168.x.x` 私网地址用于公网 DNS。

添加 WordPress 网站前，必须先在域名 DNS 服务商完成：

1. 把根域名的 `A` 记录指向这台服务器的公网 IPv4。
2. 如果需要 `www`，将 `www` 设置为指向根域名的 `CNAME`，或设置为同一公网 IPv4 的 `A` 记录。
3. 在云厂商安全组或云防火墙中确认 TCP 80、443 已开放。
4. 等待 DNS 生效后，再运行 `sudo wp-shell` 并选择 `Add a new website`。

摘要中显示的公网地址也应与云厂商控制台核对后再修改 DNS，尤其是使用 NAT、负载均衡器或浮动 IP 的服务器。

### 3. 安装过程会执行什么

脚本会依次：

1. 检查 Ubuntu 版本、CPU 架构、内存和磁盘空间。
2. 安装 Nginx、MariaDB、Redis、PHP-FPM、Certbot、WP-CLI、Fail2ban、SQLite 等组件。
3. 根据整机内存计算 MariaDB、Redis 和 PHP-FPM 初始预算。
4. 配置选定 PHP 版本的全局安全参数；站点 PHP-FPM pool 会在添加网站时创建。
5. 安装每日备份 timer 和每分钟指标采集 timer。
6. 安装统一的全局 `wp-shell` 命令。

Nginx 配置在启用前必须通过 `nginx -t`。验证失败时，脚本会恢复原配置。

### 4. 添加第一个网站

环境安装完成后，重新打开菜单：

```bash
sudo wp-shell
```

选择：

```text
2) Add a new website
```

也可以直接执行：

```bash
sudo wp-shell site add
```

只有添加网站时才会询问以下内容：

1. 每个网站的不带 `www` 的基础域名。
2. WordPress 管理员邮箱。
3. WordPress 管理员用户名。
4. 网站标题。
5. 是否把 `www` 加入证书。
6. 根域名和 `www` 中哪一个作为主域名。
7. 是否安装 WooCommerce。

输入基础域名时只输入：

```text
example.com
```

不要输入 `www`、协议、路径或末尾斜杠，例如不要输入：

```text
www.example.com
https://example.com/
```

如果选择把 `www` 加入证书，脚本才会继续询问是否使用 `www.example.com` 作为主域名。未把 `www` 加入证书时，根域名自动成为主域名。

添加网站时，脚本会创建独立 PHP-FPM pool、数据库账号、Redis DB、站点目录、证书和 Nginx 配置，并安装 WordPress、Redis Object Cache 以及可选的 WooCommerce。网站沿用环境安装时选择的 PHP 版本，不会再次询问 PHP。

### 5. 安装完成后检查

```bash
sudo wp-shell --version
sudo wp-shell site list
sudo wp-shell site status
sudo wp-shell security-scan
sudo wp-shell metrics status
systemctl status wp-shell-backup.timer
systemctl status wp-shell-metrics.timer
```

`security-scan` 不只检查服务是否启动，还会验证 Nginx 和 Fail2ban 配置、每站点 `wp-config.php` 权限、`FORCE_SSL_ADMIN`、`DISALLOW_FILE_EDIT`、`WP_CACHE`、Redis Object Cache 连接、证书文件、root-only 凭据文件权限，以及环境选择启用 UFW 时的实际状态。HSTS 会分别检查绕过 DNS/CDN 的本机 Nginx 源站和正常 DNS 访问的公网端点，因此可以区分服务器配置错误与 CDN/反向代理覆盖响应头。扫描还会检查当前 Redis 密钥是否意外出现在本机 wp-shell 日志中，但不会输出密钥内容。

新建 WordPress 网站成功后，脚本会在当前交互式 SSH 终端中一次性显示登录地址、管理员用户名和自动生成的管理员密码。密码直接写入终端设备，不经过普通标准输出，因此不会被写入 `/var/log/wp-shell/` 的部署日志。

脚本还会把首次生成的 WordPress 管理员密码保存在仅 root 可读的文件中，防止终端关闭后无法找回：

```text
/root/wordpress-credentials-DOMAIN.txt
```

例如：

```bash
sudo cat /root/wordpress-credentials-example.com.txt
```

首次登录后，建议把密码保存到密码管理器，然后删除服务器上的明文凭据文件。

一次性密码区块只在真正创建 WordPress 管理员账号的那次交互式部署中显示。以后运行 `site DOMAIN summary`、修复已有网站或打开菜单，都不会再次把密码打印到终端。通过管道、定时任务或其他无交互终端方式部署时也不会显示密码，应使用上面的 `sudo cat` 命令读取 root-only 凭据文件。

### 6. WordPress 语言

脚本默认下载 `en_US` WordPress。如果需要为新网站安装简体中文版，应在添加网站时指定：

```bash
sudo env WORDPRESS_LOCALE=zh_CN wp-shell site add
```

终端程序本身始终使用英文和 ASCII 字符，以避免不同 SSH 客户端的编码和字符宽度问题；这不影响 WordPress 后台语言，也不影响本 README 使用中文。

## 三、无参数启动和环境识别菜单

日常管理时直接运行：

```bash
sudo wp-shell
```

在源码目录中也可以运行：

```bash
sudo ./wp-shell.sh
```

脚本不会立即修改服务器，而是先判断环境属于以下哪一种状态。

### 1. 状态一：没有完整 WordPress 运行环境

脚本同时检查：

- Nginx 是否已经安装
- PHP-FPM 是否已经安装
- MariaDB 或 MySQL 是否已经安装

只要缺少其中一项，就显示安装/修复菜单：

```text
1) Install WordPress environment
2) Import an existing WordPress site
3) Show command help
0) Exit
```

通常选择 `1`。如果尚无环境配置，脚本只询问单网站或多网站模式、PHP 版本和 UFW；不会在这里询问域名。如果之前安装中断但 `/etc/wp-shell/environment.v1` 已经保存，脚本会按保存的设置修复环境，不会重复收集信息。

### 2. 状态二：已有 Nginx、PHP-FPM 和数据库，但不是 wp-shell 安装

当三个核心组件已经安装，但不存在有效的 `/etc/wp-shell/environment.v1` 环境配置时，脚本认为这是一个尚未由 wp-shell 管理的外部 WordPress 环境，显示导入与优化菜单：

```text
1) Import existing websites only (safe)
2) Import websites and enable local monitoring
3) Import and transfer one website for wp-shell optimization
4) Show detected environment
5) Show command help
0) Exit
```

各选项含义：

- `1`：只扫描和登记现有网站，不改写 Nginx、PHP-FPM、数据库或 Redis 配置。这是推荐的第一步。
- `2`：导入网站，并安装本地 SQLite 指标采集器。不会替换现有 Nginx 和 PHP 路由。
- `3`：先导入，再明确选择一个域名交给 wp-shell 接管和优化。执行前会再次确认。
- `4`：显示检测到的 Nginx、PHP-FPM、数据库状态和 `wp-config.php` 路径。
- `5`：显示命令帮助。

建议先选择 `1`，运行备份并核对网站列表。确认无误后，再重新运行 `sudo wp-shell`，通过管理菜单或 `site deploy DOMAIN` 接管单个网站。

选择 `3` 接管站点时，脚本还会询问目标 PHP 版本、是否包含 `www` 和证书管理员邮箱。接管会生成新的 Nginx/PHP-FPM/缓存配置，启用 wp-shell Redis 设置，并把站点文件权限统一为 `www-data`。该操作前必须准备独立的网站和数据库备份。

### 3. 状态三：已经由 wp-shell 管理

当 `/etc/wp-shell/environment.v1` 存在，并且 Nginx、PHP-FPM 和数据库组件齐全时，显示完整运维菜单。此时允许 `/etc/wp-shell/sites.v3` 不存在或网站数量为 0：

```text
1) Dashboard
2) Add a new website
3) Website list
4) Website status
5) Deploy or repair a website
6) Back up one website
7) Back up all websites
8) Restore a website
9) Import existing websites
10) Traffic and resource report
11) Analyze resource usage
12) Apply safe tuning recommendations
13) Reapply service resource budget
14) Security scan
15) Repair backup and metrics timers
0) Exit
```

这个菜单把日常使用频率最高的看板、建站、列表、备份、恢复和资源分析集中在一屏内。每次选择完成后脚本退出，避免在 SSH 中保留不必要的长期管理进程；需要继续操作时重新执行 `sudo wp-shell` 即可。

### 4. 直接执行命令

菜单只是常用功能入口，所有功能仍可直接调用：


```bash
sudo wp-shell dashboard
sudo wp-shell site list
sudo wp-shell backup-all
sudo wp-shell report 24h
sudo wp-shell --help
```

## 四、SSH 终端看板

### 1. 打开看板

```bash
sudo wp-shell dashboard
```

看板会原地刷新，不会像 `tail -f` 一样不断向下滚动。列宽会根据 SSH 窗口宽度自动缩减，行数会根据终端高度自动限制。

看板始终先从站点配置读取已登记域名，因此即使采集器尚未产生第一条样本，网站也会显示为 `NO DATA`，不会被误认为尚未添加。顶部同时显示 `collector OK`、`WAITING`、`STALE` 或 `FAILED`；出现 `FAILED` 时应运行 `sudo wp-shell metrics status` 查看采集器状态。

顶部 CPU、内存和磁盘使用独立的等宽区域，宽屏下不会互相覆盖。CPU 是根据 `/proc/stat` 相邻采样差值计算的整机使用率；`Load` 是一分钟平均负载，并同时显示当前可用 CPU 核心数，便于判断负载是否接近 CPU 容量。

建议终端至少为 `64x14`。如果窗口过小，看板会显示调整窗口的提示，而不是输出错位内容。

### 2. 看板快捷键

| 按键 | 功能 |
|---|---|
| `F1` 或 `1` | Overview：总体情况 |
| `F2` 或 `2` | Traffic：请求和状态码 |
| `F3` 或 `3` | Resources：PHP 和磁盘资源 |
| `F4` 或 `4` | Operations：HTTP、TLS、备份等运维状态 |
| `F5` 或 `5` | Alerts：只关注异常项 |
| `←` / `→` 或 `h` / `l` | 切换视图 |
| `↑` / `↓` 或 `k` / `j` | 选择站点 |
| `r` | 立即刷新 |
| `q` | 退出看板 |

### 3. 各视图主要字段

Overview 主要显示：

- 最近五分钟请求数
- P95 响应时间
- FastCGI 缓存命中率
- PHP 活跃进程和进程上限
- PHP PSS 内存
- HTTP 状态
- 综合健康提示

Traffic 主要显示：

- 请求总数
- 2xx、4xx、5xx 数量
- 返回流量大小
- P95 响应时间
- FastCGI 缓存命中率

Resources 主要显示：

- PHP 活跃进程
- PHP 空闲进程
- PHP 请求队列
- PHP 最大进程数
- PHP PSS 内存和 RSS sum
- WordPress 文件、缓存和日志占用

PSS 会把 PHP 进程共享页面按比例分摊，更接近这个 PHP-FPM pool 对物理内存的实际占用，因此 Overview 默认显示 PSS。`RSS sum` 是所有 pool 进程 RSS 的直接相加，其中共享的 PHP 库和 OPcache 页面会被重复计算，可能大于整机已用内存；它保留在 Resources 视图中用于观察趋势，不应直接当作站点独占内存。

Operations 主要显示：

- HTTP 探测结果
- TLS 剩余天数
- 最近备份时间
- 备份目录大小
- PHP 版本
- managed 或 imported 管理模式

Alerts 会集中显示：

- HTTP 不可用
- PHP 请求排队
- PHP 达到进程上限
- TLS 即将过期
- 缺少备份或备份过旧
- 5xx 比例异常

### 4. 非交互式报告

如果终端太窄、需要保存输出，或者准备在脚本中调用，可以使用普通文本报告：

```bash
sudo wp-shell report 1h
sudo wp-shell report 6h
sudo wp-shell report 24h
sudo wp-shell report 7d
sudo wp-shell report 14d
sudo wp-shell report 30d
```

例如保存最近七天报告：

```bash
sudo wp-shell report 7d > wp-shell-report.txt
```

## 五、添加和管理网站

### 1. 添加新网站

```bash
sudo wp-shell site add
```

也可以运行 `sudo wp-shell`，选择 `2) Add a new website`。这两个入口执行完全相同的流程。

命令会依次询问：

| 输入项 | 说明 |
|---|---|
| `Domain without www` | 只输入基础域名，例如 `example.com` |
| `Administrator email` | WordPress 管理员邮箱，也用于相关站点证书操作 |
| `Administrator username` | WordPress 管理员用户名，默认 `wpadmin` |
| `Site title` | WordPress 网站标题，默认使用基础域名 |
| `Include www...in the certificate` | 只有 `www` DNS 已解析到当前 VPS 时才选择 yes |
| `Use www...as the canonical domain` | 仅在证书包含 `www` 时出现；选择网站的唯一主域名 |
| `Install WooCommerce` | 需要电商功能时选择 yes |

站点 PHP 版本由 `/etc/wp-shell/environment.v1` 决定，添加网站时不会单独询问。如果环境模式是 `single`，已有一个网站后脚本会拒绝添加第二个；如果是 `multi`，脚本会根据整机内存策略检查允许的网站数量。

信息确认后，命令会重新计算整机资源预算，创建 PHP-FPM pool、数据库、证书、Nginx 配置和 WordPress。

部署成功后会显示适合 SSH 单屏查看的网站摘要，包括：

- 网站地址和 WordPress 后台地址。
- 基础域名、`www` 别名和管理员用户名/邮箱。
- WordPress/PHP 版本、WooCommerce 和 Redis Object Cache 状态。
- TLS 到期日期、文档根目录、HTTP/Nginx/PHP 健康状态。
- root-only 管理员凭据文件位置和终端看板命令。

常规摘要不会打印管理员密码；紧随首次成功部署摘要之后，脚本会在交互式 SSH 终端显示一次独立的凭据区块。该区块直接写入 `/dev/tty`，绕过普通标准输出和 `/var/log/wp-shell/` 日志。数据库密码和管理员密码通过 stdin 传给 WP-CLI，WP-CLI 重建命令中的密码会显示为 `[REDACTED]`。脚本仍会保留 `/root/wordpress-credentials-DOMAIN.txt` 作为仅 root 可读的恢复副本；首次登录后应把密码保存到密码管理器并删除该文件。

以后只重新显示同一份摘要，不重新部署网站：

```bash
sudo wp-shell site example.com summary
```

添加完成后检查：

```bash
sudo wp-shell site list
sudo wp-shell site status example.com
```

### 2. 列出所有网站

```bash
sudo wp-shell site list
```

列表会显示：

- 基础域名
- WordPress 主域名
- PHP 版本
- managed 或 imported 模式
- Redis DB 编号
- PHP-FPM 进程上限

### 3. 查看所有网站状态

```bash
sudo wp-shell site status
```

只查看一个网站：

```bash
sudo wp-shell site status example.com
```

### 4. 重新部署或修复网站

```bash
sudo wp-shell site deploy example.com
```

该命令按幂等方式重新应用服务配置，不会在已有 WordPress 数据库和配置存在时重新生成数据库密码或管理员密码。

它会重新检查和应用：

- 软件包和资源预算
- MariaDB、Redis 和 PHP-FPM 配置
- 站点目录和权限
- 证书
- Nginx HTTPS 和 FastCGI 缓存配置
- WordPress Redis Object Cache

在已有生产站点执行前，仍建议先创建备份。

### 5. 更新 WordPress

```bash
sudo wp-shell site example.com update
```

更新前会先创建备份，然后执行：

- WordPress 核心更新
- 数据库升级
- 所有插件更新
- 所有主题更新
- 缓存清理

生产网站建议先在测试环境确认插件和主题兼容性。

### 6. 清理单站点缓存

```bash
sudo wp-shell site example.com cache-clear
```

它只会清理该域名的 FastCGI 缓存和 WordPress 对象缓存，不会执行 Redis `FLUSHDB`，因此不会影响其他网站。

### 7. 统一站点操作语法

不再生成 `manage-DOMAIN` 类型的每站点脚本。所有站点操作统一使用：

```bash
sudo wp-shell site example.com status
sudo wp-shell site example.com info
sudo wp-shell site example.com cache-clear
sudo wp-shell site example.com backup
sudo wp-shell site example.com backups
sudo wp-shell site example.com restore 20260817-020000
sudo wp-shell site example.com update
sudo wp-shell site example.com restart
```

升级时，wp-shell 会删除已登记域名对应的旧 `/usr/local/bin/manage-DOMAIN` 脚本，避免同一功能存在多个入口。

## 六、导入已有 WordPress 网站

### 1. 扫描并登记网站

```bash
sudo wp-shell site import
```

脚本会在 `/var/www` 和 `/home` 下查找 `wp-config.php`，通过 WP-CLI 读取 WordPress 地址，然后把发现的网站登记为 `imported`。

导入操作不会自动修改：

- 已有 Nginx 配置
- 已有证书
- 已有数据库账号
- 已有 Redis 设置
- WordPress 文件内容

### 2. 核对导入结果

```bash
sudo wp-shell site list
sudo wp-shell site status example.com
```

导入站点会显示为：

```text
MODE imported
```

即使以后执行全局 `install`，脚本也会跳过 imported 站点，避免意外接管。

### 3. 明确交给 wp-shell 管理

确认备份和配置后，执行：

```bash
sudo wp-shell site deploy example.com
```

只有这个显式命令才会把对应站点从 `imported` 转换为 `managed`，并由 wp-shell 生成其 Nginx、PHP-FPM、缓存和相关配置。

## 七、备份和恢复

### 1. 备份一个网站

```bash
sudo wp-shell backup example.com
```

### 2. 备份所有网站

```bash
sudo wp-shell backup-all
```

### 3. 查看可用备份

```bash
sudo wp-shell site example.com backups
```

备份编号格式类似：

```text
20260817-020000
```

### 4. 恢复备份

```bash
sudo wp-shell restore example.com 20260817-020000
```

恢复流程会：

1. 校验 `SHA256SUMS`。
2. 为当前网站自动创建一份恢复前安全备份。
3. 启用 WordPress 维护模式。
4. 恢复网站文件。
5. 恢复数据库。
6. 重设文件权限。
7. 清理缓存并关闭维护模式。

### 5. 备份文件内容

每个备份目录包含：

```text
files.tar.gz       WordPress 文件
database.sql.gz    MariaDB 数据库
manifest.txt       域名、时间和 WordPress 版本
SHA256SUMS         完整性校验
```

备份位置：

```text
/var/www/DOMAIN/backups/TIMESTAMP/
```

该目录位于 WordPress `public` 目录之外，并使用 root-only 权限，不会被 Nginx 公开访问。

### 6. 自动备份

```bash
systemctl status wp-shell-backup.timer
systemctl list-timers --all | grep wp-shell
```

默认每天约 02:00 执行，带有随机延迟，并保留 14 天。

手动备份时临时使用 30 天保留期：

```bash
sudo env BACKUP_RETENTION_DAYS=30 wp-shell backup-all
```

如果希望自动 timer 永久使用不同保留期，应为 `wp-shell-backup.service` 创建 systemd override，而不是直接修改脚本生成的 unit。

## 八、指标采集

### 1. 检查采集器

```bash
sudo wp-shell metrics status
systemctl status wp-shell-metrics.timer
```

状态命令会同时显示 timer、collector、系统/站点/共享服务样本数量、最后采样时间和数据库位置。timer 为 `active` 只代表定时器正在调度；collector 为 `failed` 或最后采样时间持续超过三分钟，才表示实际采集异常。

### 2. 手动采集一次

```bash
sudo wp-shell metrics collect
```

### 3. 重新安装或修复 timer

```bash
sudo wp-shell metrics install
```

### 4. 指标保存位置

```text
/var/lib/wp-shell/metrics.sqlite3
```

原始指标默认保存 30 天。所有数据只保存在当前 VPS，不会上传到远程服务。

采集的系统数据包括：

- CPU 使用率和 load
- 总内存和可用内存
- Swap 使用量
- 根分区使用率
- 网络收发字节计数

采集的站点数据包括：

- 请求总数
- 2xx、4xx、5xx 数量
- 响应流量
- 平均响应时间和 P95 响应时间
- FastCGI 缓存命中、未命中和绕过数量
- PHP 活跃、空闲和排队进程
- PHP 达到最大进程数的状态
- PHP-FPM PSS 和 RSS sum 内存
- HTTP 探测结果
- TLS 剩余有效天数
- 最近备份年龄
- 网站文件、缓存、日志和备份目录大小

MariaDB 和 Redis 作为共享服务，还会采集连接数、慢查询计数、Redis 内存、命中、未命中和淘汰计数。

### 5. 访问日志隐私

Nginx 使用专门的结构化日志格式，故意不保存：

- 客户端 IP
- Cookie
- Query String
- Referrer
- User-Agent

日志保留 URI 路径，用于判断 WordPress、WooCommerce 和特定路由的性能情况，但不会保存查询参数。

## 九、资源分析与调优

### 1. 查看资源分析

建议网站运行并积累具有代表性的真实流量后执行：

```bash
sudo wp-shell analyze 7d
sudo wp-shell analyze 14d
sudo wp-shell analyze 30d
```

分析结果包含：

- 峰值 CPU
- 最低可用内存比例
- 峰值磁盘占用
- 每个站点的 PHP 峰值活跃进程
- PHP 请求队列
- PHP 达到最大进程数的记录
- PHP 峰值 PSS 和 RSS sum
- P95 响应时间
- MariaDB 连接和慢查询变化
- Redis 峰值内存和淘汰数量

### 2. 查看并应用自动建议

```bash
sudo wp-shell tune --apply
```

脚本会先列出：

```text
DOMAIN  CURRENT  PROPOSED  REASON
```

确认后才会写入配置并重启相关 PHP-FPM 服务。

无人值守确认：

```bash
sudo wp-shell tune --apply --yes
```

不建议在第一次运行时使用 `--yes`，应先人工检查建议和服务器可用内存。

### 3. 自动调优的安全限制

自动调优目前只修改每个站点的 PHP-FPM `pm.max_children`：

- 至少需要 1,000 个历史样本。
- 增加进程数前要求观察到至少 20% 内存余量。
- 增加额度必须有 PHP 排队或进程池饱和证据。
- 降低额度需要接近 14 天的持续低峰值使用。
- 单次调整约为 20%。
- 每站点限制在 2 至 50 个 PHP 子进程。

自动覆盖值保存在：

```text
/etc/wp-shell/tuning.v1
```

MariaDB 和 Redis 的分析结果目前只作为建议展示，不会仅凭聚合计数自动改写它们的内存配置。这样可以避免在缺少 buffer pool 命中率、业务峰值和磁盘延迟背景时做出危险调整。

### 4. 重新应用初始资源预算

```bash
sudo wp-shell optimize
```

该命令会重新计算并应用 MariaDB、Redis 和 PHP-FPM 配置。它适合在升级 VPS 内存后使用。

## 十、资源预算逻辑

脚本先为操作系统预留内存，再为各服务计算安全初始值：

- 单网站模式 MariaDB：约总内存的 35%，设置上下限。
- 多网站模式 MariaDB：约总内存的 30%，设置上下限。
- Redis：约总内存的 5%，限制为 32MB 至 512MB。
- PHP-FPM：使用受限制的剩余预算。
- PHP 进程：按约 96MB/进程估算。
- WooCommerce：初始 pool 权重是普通网站的两倍。
- FastCGI keys zone：每个网站 16MB。
- 每个网站至少 2 个 PHP 子进程，默认上限 50。

这些值是安全起点，不是所有网站的最终最佳值。主题、插件、流量结构、缓存命中率和 WooCommerce 请求比例都会改变实际内存需求。

## 十一、站点目录结构

每个标准站点统一放在：

```text
/var/www/DOMAIN/public/       WordPress 文档根目录
/var/www/DOMAIN/logs/         Nginx 和 PHP-FPM 日志
/var/www/DOMAIN/cache/        Nginx FastCGI 缓存
/var/www/DOMAIN/backups/      本地备份
/var/www/DOMAIN/.wp-cli/      站点独立的 WP-CLI HOME 和下载缓存
```

例如：

```text
/var/www/example.com/public/
/var/www/example.com/logs/
/var/www/example.com/cache/
/var/www/example.com/backups/
/var/www/example.com/.wp-cli/
```

日志每天轮转，默认保留 14 个压缩轮转文件。

## 十二、主要配置文件

```text
/etc/wp-shell/environment.v1              环境模式、默认 PHP 版本和 UFW 选择
/etc/wp-shell/sites.v3                    站点清单，不是可执行 Shell 配置
/etc/wp-shell/databases/                  每站点数据库凭据
/etc/wp-shell/redis.secret                Redis 密码
/etc/wp-shell/tuning.v1                   可选 PHP-FPM 调优覆盖值
/etc/nginx/conf.d/wp-shell-log-format.conf
/usr/local/sbin/wp-shell                  安装后的主程序
/usr/local/bin/wp-shell                   全局命令链接
/var/lib/wp-shell/metrics.sqlite3         本地指标数据库
/var/log/wp-shell/                        部署和管理日志
```

配置和密码文件使用 root `0600` 权限。所有站点操作统一通过 `wp-shell` 执行，数据库密码和 Redis 密码通过受控标准输入或 `REDISCLI_AUTH` 传递，不作为命令行参数，也不在成功日志中回显。

## 十三、从旧版本升级

### 1. 拉取最新代码

如果使用 Git：

```bash
cd /path/to/wp-shell
git pull --ff-only
sudo ./wp-shell.sh install
```

如果之前只下载了单个脚本：

```bash
wget -O wp-shell.sh https://raw.githubusercontent.com/hwc0212/wp-shell/main/wp-shell.sh
chmod +x wp-shell.sh
sudo ./wp-shell.sh install
```

### 2. 从 v9.4.2 升级后的必要安全操作

v9.4.2 在部署或修复网站时，WP-CLI 的成功信息可能把 Redis 密钥回显到 SSH 终端和对应的 `/var/log/wp-shell/` 日志。只要使用过该版本执行 `site add` 或 `site deploy`，就应把当前 Redis 密钥视为已经暴露。升级并安装 v9.4.3 后，先执行：

```bash
sudo wp-shell rotate-redis-secret
sudo wp-shell security-scan
```

`rotate-redis-secret` 会完成以下操作：

1. 验证旧密钥确实可以连接本机 Redis。
2. 为 Redis 生成一个新的随机密钥并实时切换认证。
3. 更新所有已登记 WordPress 网站的 `WP_REDIS_PASSWORD`。
4. 如果任何站点更新失败，尽力把 Redis、配置文件和已更新站点回滚到旧密钥。
5. 使用新密钥验证 Redis，并清理每个站点的缓存。
6. 将本机 wp-shell 日志中与旧密钥完全匹配的内容替换为 `[REDACTED]`。

脚本无法清除已经复制到聊天记录、SSH 客户端滚动缓冲区或其他外部系统中的旧密钥；轮换后旧密钥失效，因此不需要人工查看或复制新密钥。完成轮换和安全扫描后，再添加新网站。

### 3. 自动迁移的旧配置

当 `/etc/wp-shell/sites.v3` 不存在时，v9 会读取：

```text
/etc/wp-vps-manager/sites.v2
/etc/wp-single-deploy/site.v2
```

迁移过程会：

1. 合并旧的多站点和单站点清单。
2. 保留域名、PHP 版本、管理员信息、站点路径和 Redis DB。
3. 复制数据库凭据。
4. 复制已有 Redis 密钥。
5. 写入新的 `/etc/wp-shell/sites.v3`。
6. 把旧配置完整备份到迁移目录。

迁移备份位置：

```text
/etc/wp-shell/migration-backup/TIMESTAMP/
```

旧文件不会被自动删除。

### 4. 旧备份和缓存迁移

旧备份可能位于：

```text
/var/backups/wp-shell/DOMAIN
/var/backups/wp-shell-single/DOMAIN
```

首次使用新备份目录时，脚本会把旧备份复制到：

```text
/var/www/DOMAIN/backups
```

迁移不会覆盖同名的新备份，也不会删除旧目录。确认新备份完整后，可以人工删除旧备份目录。

旧缓存目录：

```text
/var/cache/nginx/DOMAIN
```

重新部署后，新缓存只保存在：

```text
/var/www/DOMAIN/cache
```

迁移阶段执行缓存清理时会同时处理新旧缓存目录。

### 5. 旧命令兼容

以下旧文件名仍然可以运行：

```bash
sudo ./wp-vps-manager.sh list
sudo ./deploy-single-wordpress.sh --reconfigure
```

安装后旧的 `/usr/local/sbin/wp-single-manager` 调用也会自动进入兼容模式。但建议逐步把自动化、文档和运维习惯改为统一的：

```bash
sudo wp-shell ...
```

安装统一备份 timer 时，脚本会禁用旧的 `wp-vps-backup.timer` 和 `wp-single-backup.timer`，避免同一天重复生成备份。旧 unit 文件会保留，方便审计或人工清理。

## 十四、安全设计

- 站点配置采用不可执行的数据格式，不会 `source` 用户输入生成的配置。
- Redis 只监听 loopback，并启用 protected mode 和随机密码。
- 每个站点使用不同 Redis DB 和域名前缀。
- 数据库和 Redis 密码不会出现在 `wp-shell` 命令行中。
- Redis 密钥更新使用无成功输出的受控调用；可以用 `sudo wp-shell rotate-redis-secret` 完成在线轮换和本机日志脱敏。
- `wp-config.php` 使用 `0640` 权限。
- WordPress 在线文件编辑默认关闭。
- PHP-FPM status 使用本地 Unix socket，不通过 Nginx 暴露。
- Nginx 配置必须验证成功后才会生效。
- UFW 不执行 reset，并在启用前保留当前 SSH 端口。
- Fail2ban 使用可验证的 SSH 和 Nginx 认证规则。
- HTTPS 启用 TLS 1.2/1.3、HSTS 和常用安全响应头。
- 恢复前自动生成安全备份。
- 备份使用 SHA-256 校验。

## 十五、故障排除

### 1. 查看 wp-shell 日志

```bash
ls -lt /var/log/wp-shell/
sudo tail -n 200 /var/log/wp-shell/wp-shell-*.log
```

### 2. 查看网站日志

```bash
sudo tail -f /var/www/example.com/logs/nginx-error.log
sudo tail -f /var/www/example.com/logs/php-error.log
sudo tail -f /var/www/example.com/logs/php-fpm-slow.log
```

### 3. 检查服务

```bash
nginx -t
systemctl status nginx
systemctl status mariadb
systemctl status redis-server
systemctl status php8.3-fpm
systemctl status fail2ban
```

### 4. 检查站点对应 PHP-FPM pool

```bash
sudo wp-shell site list
ls -l /run/php/wp_*.sock
grep -R '^pm.max_children' /etc/php/*/fpm/pool.d/wp-shell-*.conf
```

### 5. 看板没有数据

```bash
sudo wp-shell metrics status
sudo wp-shell metrics collect
sudo wp-shell report 1h
journalctl -u wp-shell-metrics.service -n 100 --no-pager
```

首次安装后可能需要等待一分钟，才会出现第一批自动采集数据。

如果看板顶部已经显示站点数量，但站点行显示 `NO DATA`，说明网站已登记而采集器还没有成功写入样本。重点检查 `Collector`、`Samples` 和 `Last sample`，无需重新添加网站。

### 6. 证书申请失败

```bash
getent ahosts example.com
getent ahosts www.example.com
ss -ltnp | grep -E ':(80|443)\b'
ufw status verbose
certbot certificates
```

如果选择了 `www`，根域名和 `www` 都必须正确解析到 VPS。

### 7. Nginx 配置失败

```bash
nginx -t
ls -l /etc/nginx/sites-enabled/
sed -n '1,240p' /etc/nginx/sites-available/example.com
```

wp-shell 在生成配置失败时会回滚对应站点配置。修复问题后可以重新执行：

```bash
sudo wp-shell site deploy example.com
```

### 8. 手动验证备份

```bash
cd /var/www/example.com/backups/20260817-020000
sha256sum --check SHA256SUMS
```

### 9. WP-CLI 出现 Permission denied

`v9.3.1` 起，所有站点 WP-CLI 命令都会先切换到 WordPress 文档根目录，并使用 `/var/www/DOMAIN/.wp-cli/` 作为独立的可写配置和缓存目录。脚本不会让 `www-data` 在 `/home/USER` 或共享的 `/var/www/.wp-cli` 中创建文件。

如果旧版本在 WordPress 已安装后中断，并出现 `proc_open(): posix_spawn() failed: Permission denied`，更新脚本后执行：

```bash
sudo wp-shell site deploy example.com
```

修复过程会复用已有数据库、证书、WordPress 和管理员凭据，从中断的位置继续配置 permalink、Redis Object Cache 和可选插件。

### 10. HSTS 检查提示公网端点覆盖策略

先分别查看本机 Nginx 源站和正常公网访问的响应头：

```bash
sudo curl --resolve example.com:443:127.0.0.1 -sS -o /dev/null -D - \
  https://example.com/wp-login.php | grep -i '^strict-transport-security:'
curl -sS -o /dev/null -D - https://example.com/wp-login.php \
  | grep -i '^strict-transport-security:'
```

wp-shell 管理的值是 `max-age=15552000`。如果源站返回该值，而公网端点返回 `max-age=0`、其他值或没有该响应头，说明 VPS 上的 Nginx 已正确配置，但域名前方的 CDN、负载均衡器或反向代理覆盖了响应头。此时应在对应代理服务中修正 HSTS，重复运行 `sudo wp-shell security-scan`，而不是反复重新部署 WordPress。

## 十六、开发和测试

本地测试：

```bash
bash tests/static-checks.sh
bash tests/config-roundtrip.sh
bash tests/render-nginx.sh
bash tests/storage-layout.sh
bash tests/metrics-roundtrip.sh
bash tests/dashboard-smoke.sh
bash tests/menu-routing.sh
```

ShellCheck：

```bash
shellcheck -x wp-shell.sh wp-vps-manager.sh deploy-single-wordpress.sh tests/*.sh
```

GitHub Actions 还会在 Ubuntu 24.04 容器中使用真实的 Nginx、MariaDB、Redis 和 PHP-FPM 验证生成的配置。

## 十七、当前边界

不提供 Web 控制面板是项目的明确设计目标，而不是缺失功能。

项目专注于一台 Ubuntu VPS，不宣称支持：

- 集群和高可用
- 数据库复制
- 自动跨服务器迁移
- 一键克隆网站
- 自动上传云端备份
- 托管式控制平面
- 自动完成所有 MariaDB 和 Redis 性能调优

这些能力可以结合 WP-CLI、rsync、rclone、对象存储和云厂商工具实现，但在缺少完整验证和回滚机制前，不会作为已经完成的菜单功能提供。

## 免责声明

本项目按现状提供。生产环境使用前，请在相同 Ubuntu 和 PHP 组合上测试，并保留可以在服务器之外恢复的备份。作者不对脚本使用导致的数据丢失、停机或服务中断承担责任。

## License

MIT
