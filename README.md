# wp-shell

`wp-shell` 是一个面向 Ubuntu VPS 的 WordPress 部署与运维脚本，目标是在不安装 Web 控制面板的前提下，覆盖 Cloudways、SpinupWP 等托管面板中最常用的单机部署、站点管理、监控、备份和资源调优能力。

项目不需要常驻的面板 Web 服务、面板数据库或额外后台应用。服务器管理通过 Shell、WP-CLI 和 systemd 完成，更适合希望节省 VPS 资源、减少攻击面，并愿意通过 SSH 管理服务器的用户。

- 当前版本：`wp-shell.sh` v10.0.5
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
- 按 PHP 版本持久保存 OPcache 容量，并通过本地 FPM socket 检查运行时缓存状态。
- 新网站使用独立 PHP 用户；旧网站可显式迁移，并可选择独立 Redis socket/实例。
- 可选系统 WP-Cron、内容变更触发的页面缓存清理、登录 POST 限速和加密异地备份。
- 备份完成前验证归档和校验清单；调优受有效样本、CPU、实际内存证据和全站预算约束。
- 自动迁移旧版多站点脚本和单站点脚本的配置。
- 不提供 Web 控制面板，不开放远程监控端口，不上传遥测数据。

旧文件名 `wp-vps-manager.sh` 和 `deploy-single-wordpress.sh` 仍然保留，但它们现在只是兼容包装器。新安装和新自动化任务应统一使用 `wp-shell.sh` 或安装后的 `wp-shell` 命令。

## v10 安全控制面：先审计、再计划、再应用

v10 把服务配置写入统一事务。推荐的日常顺序是：

```bash
sudo wp-shell audit
sudo wp-shell dry-run apply
sudo wp-shell apply --confirm
sudo wp-shell status
```

- `audit`：只读检查主机、服务、WordPress、Cron、Action Scheduler、证书、权限和备份公网访问，不重载服务、不执行到期任务、不发邮件。WordPress 队列查询跳过普通插件和主题，避免为审计加载第三方业务代码；必须加载的 MU 插件仍属于站点自身的审计边界。
- `dry-run apply`：列出基线会触及的模块和站点，不写文件、不重载服务。
- `apply --confirm`：为每个将变化的文件建立事务备份，生成同文件系统候选文件，原子替换并运行配置检查；只平滑重载有必要的服务。
- `status`：显示控制面、站点数量、Cloudflare 模式、服务、timer、失败单元和最近事务。
- `rollback [ID] --confirm`：恢复指定事务；省略 ID 时使用最近事务。如果文件在提交后被管理员或其他工具改过，回滚会拒绝覆盖，必须先人工审查。

每个事务位于：

```text
/etc/wp-shell/transactions/TIMESTAMP-OPERATION.RANDOM/
```

`manifest.v1` 记录操作名称、修改前文件、提交后指纹和需要重新加载的服务。配置验证或命令中途失败时会自动恢复本事务已记录的文件；自动回滚不删除网站数据库、WordPress 内容或已完成的网站备份。新建网站、恢复数据库和插件升级属于应用数据操作，仍然依赖网站备份，而不是把配置事务误当成数据库快照。

### MariaDB 实际配置审计与旧配置迁移（v10.0.2）

早期 `wp-vps-manager` 曾生成 `/etc/mysql/mariadb.conf.d/50-wordpress.cnf`，其中可能包含 `1G` InnoDB Buffer Pool、`300` 个连接和 `128M` 内存临时表。MariaDB 会合并读取多个 `.cnf`；只生成新的 `60-wp-shell.cnf` 并不能证明这些旧值已经失效。v10.0.2 因此先检查实际生效状态，不再把资源报告里的理论预算当作 MariaDB 实际配置。

只读检查：

```bash
sudo wp-shell mariadb audit
# 完整控制面审计也包含同一段 MariaDB 结果
sudo wp-shell audit
```

输出明确区分：

- 当前运行中的 runtime 值；
- 按磁盘配置在下次启动时生效的值；
- `Max_used_connections`、当前连接/运行线程和内存/磁盘临时表累计计数；
- `/etc/mysql/my.cnf`、`conf.d/` 与 `mariadb.conf.d/` 中相关定义及可能的最终来源；
- 已知旧 wp-shell 文件与管理员/发行版文件；
- 低内存主机上的高风险组合。风险判断是保守的准入信号，不是 MariaDB 实际内存上限证明，也不把 Swap 当作 RAM。

审计完全只读。检测到危险的已知旧值时，普通 `apply` 会在写文件或重启 MariaDB 前停止，并要求显式迁移：

```bash
sudo wp-shell mariadb audit
sudo wp-shell mariadb migrate-legacy --confirm
sudo wp-shell mariadb audit
sudo wp-shell apply --confirm
```

迁移会从识别出的旧版 `50-wordpress.cnf` 中移除 `innodb_buffer_pool_size`、`max_connections`、`tmp_table_size`、`max_heap_table_size` 四项；对当前 wp-shell 管理的 `60-wp-shell.cnf` 则逐项使用同一低内存风险策略，只移除该定义本身已被判定为危险的行，安全的已有调优值和无关内容保持原样。迁移不会用另一组百分比覆盖旧值，不删除配置文件，也不会因为另一个旧文件存在风险而清空安全的受管调优。候选片段和完整配置都必须通过 MariaDB 解析，事务会保存文件原始内容、权限和所有者。只有配置的实际生效值发生变化才重启 MariaDB；重启、健康检查或 runtime 对照失败时自动恢复精确旧文件并尝试恢复服务。

未知管理员文件永远不会被迁移命令自动删除或改写。如果危险值仍由这类文件提供，迁移会失败并回滚，必须由管理员结合业务负载和监控证据人工处理。

### 导入已有站点的配置写入安全（v10.0.3）

导入站点仍然使用原网站的非 root 运行账户执行 WP-CLI。部署或修复时，脚本不会在 WordPress 配置更新之前先对整棵目录执行最终权限收紧。每条 `wp config set/delete/create` 命令都有独立、短暂的写入窗口：脚本先确认登记的 WordPress 绝对路径和 `wp-config.php` 都不是符号链接，再把现有配置临时设为 `0660 root:站点私有组`；命令成功、失败或被中断后都恢复为 `0640 root:站点私有组`。最终 `core is-installed` 检查通过后才统一收紧站点权限。

如果站点没有可识别的 Nginx PHP socket，导入会使用环境配置中的 `DEFAULT_PHP_VERSION`，不会再静默写死 PHP 8.3。符号链接、消失的配置文件或无法恢复的所有权/权限会使操作明确失败，不会继续把站点标记为已完成。安全扫描只有在 WP-CLI 成功读取 `WP_DEBUG` 后才解释空值、`0` 或 `false`；命令失败会报告“无法验证”，不会把空输出误判为安全状态。

### PHP-FPM 整机硬预算（v10.0.4）

`PHP_TOTAL_BUDGET_MB` 现在是写入 PHP-FPM pool 前的整机硬准入约束，而不是尽量遵守的建议值。脚本把每个受管站点的 `pm.max_children`，以及每个启用 PHP 版本保留的一个最小 `www` pool worker 一起计入：

```text
aggregate workers × worker memory estimate <= PHP_TOTAL_BUDGET_MB
```

脚本不再为了保证每站点至少两个 worker 而扩大总 slots，也不把 Swap 算成可常驻的 PHP 容量。低流量站点必要时会使用 `pm=ondemand`、`pm.max_children=1`。如果连每站点一个 worker、各 PHP 版本的默认 pool 和显式 tuning override 都无法容纳，`apply`、环境安装、添加/导入站点和直接 PHP 配置会在写入 pool 或重载服务之前失败。错误信息会列出物理 RAM、Swap、PHP 硬预算、worker 估算证据、安全/请求 worker 数、站点及 WooCommerce 权重，并建议减少站点、降低 override、增加 RAM 或迁移站点。

初次或指标不足时，每个 worker 使用保守的 96MB 基线。只有某个站点至少有 1,000 个有效 PHP PSS 样本、跨度不少于 24 小时且最新样本不超过 180 秒，脚本才使用每进程 PSS 的 95 分位并增加 25% 安全余量；多站点取最高的合格估算，且不会低于 96MB。实测证据只能让估算保持或变得更保守，不能绕过整机硬预算。

只读检查：

```bash
sudo wp-shell audit
sudo wp-shell dry-run apply
sudo wp-shell analyze 7d
```

`audit` 和 `analyze` 会区分当前 pool 总量与安全建议总量。当前总量不是从目标文件名推断，而是读取 `php-fpmVERSION -tt` 输出的最终合并配置，包括每个启用 PHP 版本实际生效的 `[www] pm.max_children` 和各站点 pool。无法取得这项证据时会显示 `UNKNOWN`，并禁止自动扩容，不会假定 default pool 已经是 1。已有配置超预算时仍继续采集指标，便于诊断，但不会继续自动扩容。手工 tuning override 会作为整机组合验证；两个单独合法但合计超预算的值会被整体拒绝，不会被静默截断。

受管 default pool 使用排序晚于发行版 `www.conf` 的 `/etc/php/VERSION/fpm/pool.d/zz-wp-shell.conf`。从 v10.0.3 升级并确认应用时，脚本会在同一事务中迁移自己能精确识别的旧 `99-wp-shell.conf`，保留管理员文件，并在重载前验证最终 `[www]` 确实为 `pm=ondemand`、`pm.max_children=1`。每个受管站点 pool 也必须在 PHP-FPM 最终合并配置中精确得到计划的 `pm.max_children`。如果更晚的管理员配置覆盖 default 或站点目标，应用会失败并恢复旧文件，不会编辑管理员／发行版配置或假装硬预算已经生效。

### 内部模块边界与单文件兼容性

为了保留 `wget` 后一个文件即可安装、旧包装器仍可委托执行的兼容性，v10 继续发布单个 `wp-shell.sh`，但代码按职责分区，而不是再拆出一组可能只下载到一半的运行时文件：

1. 严格模式、路径校验、安全临时目录、日志和统一事务。
2. 只解析数据、不执行配置内容的环境/站点/策略状态层。
3. Nginx、PHP-FPM、MariaDB、Redis、SSH/UFW、Cloudflare 等候选配置渲染与验证层。
4. WordPress、staging、备份、Cron、Action Scheduler 和缓存操作层。
5. `audit/apply/status/rollback/dry-run` 控制面与兼容命令路由。

包装器、GitHub Actions 和测试保持独立文件；生产运行不通过 `source` 加载可被站点用户修改的模块。这样减少部分升级造成的版本错配，同时仍能用函数级测试约束各模块。

普通 `apply` 明确不做以下事情：

- 不修改 SSH 登录策略或删除 UFW 的未知规则。
- 不启用 Cloudflare 信任、AIDE 或外部邮件模式。
- 不更新 WordPress 核心、插件或主题。
- 不运行 WP-Cron/Action Scheduler 任务，不发送测试邮件，不提交表单。
- 不删除本地/远端备份，不重启 VPS。

这些高影响功能均有独立命令和显式确认参数，便于先审计影响再执行。

### 兼容优先的站点默认值

v10.0.1 起不再把性能或安全偏好当成所有 WordPress 网站的共同前提：

- FastCGI 匿名整页缓存、Redis Object Cache、严格 iframe/Permissions 响应头、HSTS、登录限速、系统 WP-Cron 和 Cloudflare 信任均默认关闭。
- XML-RPC 保持 WordPress 默认可用；确认不依赖移动端、远程发布或外部集成后才禁用。
- 不自动修改固定链接，不设置通用 `WP_CACHE`，不删除 WordPress 随附插件。
- WooCommerce 只有在添加网站时明确选择才安装；其他主题和插件不由脚本安装或配置。
- 旧受管站点已有 FastCGI 缓存、严格响应头或已激活 Redis Object Cache 时，应用升级会登记并保留原状态，不借版本升级突然改变线上行为。

安全文件权限、TLS、未知 Host、防止 PHP 在 uploads 执行、敏感文件阻断、数据库/Redis loopback 和配置语法验证仍属于通用基线，因为这些不依赖具体主题或插件的业务行为。

### Cloudflare 代理与真实访客 IP

Cloudflare 模式默认关闭。确认域名使用橙云代理后执行：

```bash
sudo wp-shell cloudflare enable --confirm
sudo wp-shell cloudflare status
```

这是主机级的“只信任 Cloudflare 官方出口网段”能力，不代表所有域名都使用 Cloudflare。直连网站不会因为该能力而自动获得缓存、登录限速或 WordPress 改动；可信头只在连接来源确实属于官方网段时生效。服务器上已经没有任何 Cloudflare 代理站时可撤销：

```bash
sudo wp-shell cloudflare disable --confirm
```

脚本只从 Cloudflare 官方 `ips-v4`、`ips-v6` 地址读取代理网段，分别验证为严格 IPv4/IPv6 CIDR，生成候选配置并通过 `nginx -t` 后才原子替换：

```nginx
real_ip_header CF-Connecting-IP;
real_ip_recursive on;
```

只有候选文件中列出的 Cloudflare 网段能改写 Nginx 的 `$remote_addr`。下载为空、出现非法行或 Nginx 验证失败时保留旧配置。启用后安装每周更新 timer；也可手动执行：

```bash
sudo wp-shell cloudflare update
```

可离线验证某个直连来源是否有资格提供 `CF-Connecting-IP`：

```bash
sudo wp-shell cloudflare check 173.245.48.10 203.0.113.25
sudo wp-shell cloudflare check 198.51.100.10 203.0.113.25
```

第一条来源位于受信代理网段时，effective 应为声明的访客地址；第二条非受信来源伪造同名头时，effective 仍是直连来源。Nginx 轮转日志保存验证后的 `client_ip` 和直接对端 `edge_ip`，但 SQLite 性能指标不复制 IP、Cookie 或 Query String。

普通 Fail2ban/nftables 无法在 Cloudflare 后面按真实 Web 访客 IP 有效封禁，因为 VPS 网络层看到的是 Cloudflare 边缘节点。wp-shell 因此只默认启用经过配置测试的 SSH jail；网站登录攻击使用 Nginx 限速，并可按需结合独立维护的应用防火墙或 Cloudflare WAF。脚本不会在未提供、未明确授权 Cloudflare API Token 时调用 Cloudflare 封禁 API，也不会把 Token 保存到 Git 或站点策略。

### 嵌套 staging（与主站位于同一 Web Root）

不要把随机 staging 目录写死在脚本中。创建 staging 后，从服务器确认它的绝对目录和 URL 子路径，例如：

```bash
sudo wp-shell site example.com staging configure \
  /var/www/example.com/public/preview-a81f/ \
  /preview-a81f/ \
  example-staging-a81f: \
  --confirm
```

命令要求目录真实存在、不是符号链接、位于已登记 Web Root 内，并且文件系统目录必须与 URL 子路径一致。它会：

- 设置 `WP_DEBUG=false`、`DISALLOW_FILE_EDIT=true`、`FORCE_SSL_ADMIN=true`。
- 设置 `WP_ENVIRONMENT_TYPE=staging` 和 `DISABLE_WP_CRON=true`。
- 为所有 staging 响应添加 `X-Robots-Tag: noindex, nofollow, noarchive`。
- 绕过 FastCGI 缓存，并禁止 staging uploads/cache 执行脚本。
- 使用显式且不同于主站的 Redis Prefix。

如果不准备分配独立 Prefix，应传入 `off`：

```bash
sudo wp-shell site example.com staging configure \
  /var/www/example.com/public/preview-a81f/ /preview-a81f/ off --confirm
```

此时 staging 设置 `WP_REDIS_DISABLED=true`，不会冒险与主站共享对象缓存键。staging 默认不创建系统 WP-Cron，避免重复处理生产队列或发送邮件。命令不会克隆数据库、创建 staging、激活商业许可证或替任何插件修改设置；staging 的创建、数据同步和插件授权由所选工具及站长负责。

检查状态：

```bash
sudo wp-shell site example.com staging status
curl -I https://example.com/preview-a81f/
```

### HSTS、XML-RPC 和登录限速

新站 HSTS 默认关闭，避免在尚未核实 Cloudflare、子域和证书覆盖时误启用 `includeSubDomains`/`preload`。脚本永远不会自动加入这两个指令。确认源站和代理策略后，按站点启用：

```bash
sudo wp-shell site example.com hsts enable
sudo wp-shell site example.com hsts status
```

从 v9 升级时，如果原受管 Nginx 配置已经包含 wp-shell 的 HSTS 值，首次重新渲染会把它登记为显式启用，不会静默撤销。XML-RPC 默认保持 WordPress 原生可用状态，避免破坏移动客户端、远程发布和依赖 XML-RPC 的集成；确认站点不需要时再逐站点禁用：

```bash
sudo wp-shell site example.com xmlrpc disable
```

登录限速只限制 `wp-login.php` 的 POST：每个验证后的访客 IP 10 次/分钟，burst 20。启用 Cloudflare 只安装可信代理 IP 能力，不会自动改变任何网站的登录、缓存、DNS、TLS 或 WordPress 设置。需要限速的网站必须逐站点启用；Cloudflare 代理站应先启用并检查真实 IP：

```bash
sudo wp-shell cloudflare status
sudo wp-shell site example.com login-limit direct
```

`X-Content-Type-Options` 和 `Referrer-Policy` 使用兼容性较高的默认值。可能影响跨域 iframe 或第三方支付组件的 `X-Frame-Options`、`Permissions-Policy` 默认不强制；确认主题和插件兼容后可逐站点启用严格响应头：

```bash
sudo wp-shell site example.com headers strict
sudo wp-shell site example.com headers compatible
```

### SSH、UFW、AIDE 和外部邮件

这些功能不属于普通 `apply`，必须分别确认：

```bash
sudo wp-shell system ssh apply --confirm-lockout-risk
sudo wp-shell system firewall apply --confirm
sudo wp-shell system aide apply --confirm
sudo wp-shell system mail external --confirm-external-mail
sudo wp-shell system updates enable --confirm
```

- SSH：只允许从一个活跃 SSH 会话执行；先确认非 root sudo 管理员存在可用公钥，再写独立 drop-in、运行 `sshd -t` 并 reload，不终止当前连接。
- UFW：自动识别当前 SSH 端口，设置默认拒绝入站、SSH `limit`、80/443 allow。为避免锁出，不删除脚本无法确认归属的既有规则，之后应人工检查 `ufw status numbered`。
- AIDE：只安装排除规则和一个每周 Cron；排除 uploads、cache、backups 及嵌套 staging 可变数据。禁用已知重复 AIDE timer，不自动初始化数据库，也不立即运行检查。
- 外部邮件：仅当站长确认 WordPress 使用 Amazon SES 等外部服务时，把 Postfix 限制为 loopback-only；不发送测试邮件。

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
8. 是否启用 Nginx FastCGI 匿名整页缓存。
9. 是否安装并启用 Redis Object Cache 集成。

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

添加网站时，脚本会创建独立 PHP-FPM pool、数据库账号、Redis DB、站点目录、证书和 Nginx 配置，并安装 WordPress。WooCommerce、Nginx 匿名整页缓存和 Redis Object Cache 都只在明确选择后启用；脚本不会修改固定链接结构，也不会删除 WordPress 随附插件。网站沿用环境安装时选择的 PHP 版本，不会再次询问 PHP。

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

`security-scan` 不只检查服务是否启动，还会验证 Nginx 和 Fail2ban 配置、每站点 `wp-config.php` 权限/属主、`WP_DEBUG`、`WP_ENVIRONMENT_TYPE`、`FORCE_SSL_ADMIN`、`DISALLOW_FILE_EDIT`、WordPress 核心严格校验、证书文件、root-only 凭据文件权限，以及环境选择启用 UFW 时的实际状态。只有站点明确启用 Redis Object Cache 时才检查其连接；只有明确启用 HSTS 时才分别检查本机源站和公网代理端点。扫描不会把 `WP_CACHE` 当作通用安全要求。它还会检查当前 Redis 密钥是否意外出现在本机 wp-shell 日志中，但不会输出密钥内容。

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

一次性密码区块只在真正创建 WordPress 管理员账号的那次交互式部署中显示。以后运行 `site DOMAIN|ID summary`、修复已有网站或打开菜单，都不会再次把密码打印到终端。通过管道、定时任务或其他无交互终端方式部署时也不会显示密码，应使用上面的 `sudo cat` 命令读取 root-only 凭据文件。

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

建议先选择 `1`，运行备份并核对网站列表。确认无误后，再重新运行 `sudo wp-shell`，通过管理菜单或 `site deploy DOMAIN|ID` 接管单个网站。

选择 `3` 接管站点时，脚本还会询问目标 PHP 版本、是否包含 `www` 和证书管理员邮箱。接管会生成新的 Nginx/PHP-FPM/缓存配置、启用 wp-shell Redis 设置，并按登记的非 root 运行用户整理权限。该操作前必须准备独立的网站和数据库备份。发现 root 或属于 sudo/docker/lxd 等管理组的文件所有者时，导入阶段不会以该用户执行网站代码；无法让 `www-data` 读取的配置会跳过，需管理员明确调整后重试。

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
16) OPcache settings
17) Host security and pressure audit
18) Advanced operations help
0) Exit
```

这个菜单把日常使用频率最高的看板、建站、列表、备份、恢复和资源分析集中在一屏内。每次选择完成后脚本退出，避免在 SSH 中保留不必要的长期管理进程；需要继续操作时重新执行 `sudo wp-shell` 即可。

网站列表第一列的 `ID` 可以直接用于状态、修复、备份、恢复和已有站点接管。所有显示网站列表的输入框都同时接受站点编号或基础域名。例如列表中的第二个网站既可以输入 `2`，也可以输入完整基础域名。编号只代表当前列表顺序；脚本会先把编号解析为登记域名，再执行文件、数据库或服务操作，编号本身不会进入目录路径或 Nginx 配置。

### 4. 直接执行命令

菜单只是常用功能入口，所有功能仍可直接调用：


```bash
sudo wp-shell dashboard
sudo wp-shell site list
sudo wp-shell site status 2
sudo wp-shell backup 2
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

PSS 会把 PHP 进程共享页面按比例分摊，更接近这个 PHP-FPM pool 对物理内存的实际占用，因此 Overview 默认显示 PSS。`RSS sum` 是所有 pool 进程 RSS 的直接相加，其中共享的 PHP 库和 OPcache 页面会被重复计算，可能大于整机已用内存；它保留在 Resources 视图中用于观察趋势，不应直接当作站点独占内存。站点使用 `ondemand` PHP-FPM 时，空闲一段时间后可能没有常驻子进程，此时 `PHP 0/N` 和 `PSS 0MB` 是正常的空闲状态，请求到达后会自动创建进程。

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

`PHP max` 只表示最新一分钟出现了新的 PHP-FPM 进程池饱和事件，不会因旧累计值长期保留。`Backup` 表示尚无本地备份或最近备份超过 48 小时；新网站完成第一次手动或定时备份并等待下一次采样后，该提示会自动消失。

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
| `Enable Nginx FastCGI page cache...` | 只有纯匿名公共页面及动态路由已经确认可绕过时选择 yes |
| `Install and enable Redis Object Cache...` | 接受安装 Redis Object Cache 插件并需要对象缓存时选择 yes |

站点 PHP 版本由 `/etc/wp-shell/environment.v1` 决定，添加网站时不会单独询问。如果环境模式是 `single`，已有一个网站后脚本会拒绝添加第二个；如果是 `multi`，脚本会根据整机内存策略检查允许的网站数量。

信息确认后，命令会重新计算整机资源预算，创建 PHP-FPM pool、数据库、证书、Nginx 配置和 WordPress。

部署成功后会显示适合 SSH 单屏查看的网站摘要，包括：

- 网站地址和 WordPress 后台地址。
- 基础域名、`www` 别名和管理员用户名/邮箱。
- WordPress/PHP 版本、WooCommerce、页面缓存和 Redis Object Cache 状态。
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
- Nginx HTTPS、安全模板以及该站点已经明确选择的 FastCGI 缓存策略
- 仅重新应用已经明确启用或从旧配置识别并保留的 Redis Object Cache 集成

在已有生产站点执行前，仍建议先创建备份。

### 5. 更新 WordPress

```bash
sudo wp-shell site example.com update --confirm-updates
```

更新前会先创建备份，然后执行：

- WordPress 核心更新
- 数据库升级
- 所有插件更新
- 所有主题更新
- 缓存清理

生产网站建议先在测试环境确认插件和主题兼容性。

### 6. 验证和修复 WordPress 核心

严格验证核心文件：

```bash
sudo wp-shell site example.com core-verify
```

如果存在缺失、校验失败或核心目录中的额外文件，执行：

```bash
sudo wp-shell site example.com core-repair
```

修复命令会先创建完整网站备份，再从 WordPress 官方 API 获取与当前版本和语言匹配的 ZIP 包，强制覆盖核心文件、保留 `wp-content`、`wp-config.php` 和数据库，并删除校验明确报告的异常核心文件。完成后会再次执行严格校验、恢复权限并清理缓存。

### 7. 清理单站点缓存

```bash
sudo wp-shell site example.com cache-clear
```

默认只清理该域名的 FastCGI **页面缓存**，不刷新 Redis，不重载 PHP-FPM。需要其他范围时明确指定：

```bash
sudo wp-shell site example.com cache-clear page
sudo wp-shell site example.com cache-clear object
sudo wp-shell site example.com cache-clear opcache
sudo wp-shell site example.com cache-clear all
```

`object` 调用当前网站的 WordPress 对象缓存插件清理接口，其影响范围取决于插件和 Redis 配置；不要在不同网站之间复用同一个 Redis DB。`opcache` 和 `all` 会重载同一 PHP 版本的 FPM，因此会影响共用该 PHP 版本的其他网站。日常发布内容不需要这样做。

### 8. 统一站点操作语法

不再生成 `manage-DOMAIN` 类型的每站点脚本。所有站点操作统一使用：

```bash
sudo wp-shell site example.com status
sudo wp-shell site example.com info
sudo wp-shell site example.com core-verify
sudo wp-shell site example.com core-repair
sudo wp-shell site example.com cache-clear
sudo wp-shell site example.com backup
sudo wp-shell site example.com backups
sudo wp-shell site example.com restore 20260817-020000 --confirm
sudo wp-shell site example.com update --confirm-updates
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
sudo wp-shell backup 2
```

域名和站点列表中的 `ID` 均可使用。交互菜单选择 `Back up one website` 后同样可以输入这两种形式。

### 2. 备份所有网站

```bash
sudo wp-shell backup-all
```

### 3. 查看可用备份

```bash
sudo wp-shell site example.com backups
sudo wp-shell site 2 backups
```

备份编号格式类似：

```text
20260817-020000
```

### 4. 恢复备份

恢复会同时替换网站文件和数据库，命令行必须显式确认：

```bash
sudo wp-shell restore example.com 20260817-020000 --confirm
sudo wp-shell restore 2 20260817-020000 --confirm
```

恢复流程会：

1. 校验完整的 `SHA256SUMS`、站点归属和压缩包，并拒绝链接、设备文件和危险归档路径。
2. 在一次性临时数据库中完整导入目标 SQL；预演失败时不进入 maintenance，也不改网站。
3. 创建持久化、追加式 operation journal，锁住该站点的手工与系统 WP-Cron；非法状态跳转会被拒绝。
4. 启用 Nginx maintenance，并通过 `127.0.0.1` 对站点 HTTPS 做实际 `503` 探测；只有确认新请求已被阻断，才等待站点 PHP-FPM pool 连续处于 idle，减少恢复快照期间的并发写入。
5. 创建经过校验的本地 safety backup。该事务快照不会触发 remote upload 或 retention，完成后保留供审计/人工恢复。
6. 依次记录并执行 `files-applying`、`database-applying`、权限/Redis policy/WordPress 验证和缓存清理。
7. 只有全部验证成功才进入 `commit-ready`，移除维护标记并记录 `committed`。

恢复会还原备份中的 `wp-config.php`，以保留与旧数据库内容匹配的 `$table_prefix` 和网站级常量；随后在进入数据库导入前重新写入当前 `DB_NAME`、`DB_USER`、`DB_HOST`、`DB_PASSWORD`。数据库密码通过临时 placeholder 原子替换，不出现在命令行、journal 或日志中。对 managed 站点，验证阶段还会按当前站点 policy 重建 Redis 连接，因此备份里的旧数据库/Redis 凭据不会重新上线；尚未接管的 imported 站点不会被脚本猜测或重写第三方插件专用常量，应在恢复前审查其 `wp-config.php` 和对象缓存方案。脚本自己的 `.maintenance` 控制文件不从旧备份恢复。

从 `files-applying` 开始发生语法错误、磁盘/数据库错误、验证失败，或收到 `HUP`、`INT`、`TERM` 时，脚本会从 safety backup 自动恢复恢复前的文件和数据库。自动回滚验证成功后才关闭 maintenance，并把 journal 标记为 `rolled-back`；自动回滚本身失败则标记为 `recovery-required`，维护页保持，不会误报成功。

查看最近一次恢复状态：

```bash
sudo wp-shell restore status example.com
```

断电、`SIGKILL` 或回滚失败后，先查看 journal，再显式继续恢复：

```bash
sudo wp-shell restore recover example.com --confirm
```

`commit-ready` 表示文件、数据库和缓存已经验证，只差 maintenance 收尾；recovery 会完成提交而不反向回滚。`files-applying` 到 `recovery-required` 会使用 journal 记录的 safety backup 重新执行幂等回滚。不要直接删除 `/var/lib/wp-shell/restore-operations/`，也不要只运行 `maintenance off` 掩盖未完成事务。

journal 位于：

```text
/var/lib/wp-shell/restore-operations/POOL_ID/current/journal.v1
```

它只保存域名、备份 ID、数据库名称、编码后的站点路径和状态事件，不保存数据库密码、API Token 或私钥。完成的 journal 在下一次恢复开始时移动到同一站点的 `history/`，不会被静默覆盖。旧 Nginx 模板需先更新为包含 wp-shell 管理的 `.wp-shell-maintenance` fail-closed 规则；仅在文件中出现同名注释并不算通过，实际 HTTPS 探测不是 `503` 时恢复会在任何文件/数据库写入前停止。尚未采用 managed Nginx 模板的 imported 站点，应先审查并明确接管其 Nginx 配置，不能为绕过准入而手工关闭该检查。

### 5. 备份文件内容

每个备份目录包含：

```text
files.tar.gz       WordPress 文件
database.sql.gz    MariaDB 数据库
manifest.txt       域名、时间、WordPress 版本和备份用途
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

默认每天约 02:00 执行并带有随机延迟。v10 默认不自动删除任何已完成备份；远端备份也从不由脚本删除。

如果已经完成异地备份和恢复演练，并明确希望本次运行删除超过 30 天的本地备份，可显式设置：

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

### 5. 访问日志与隐私

Nginx 使用专门的结构化日志格式，故意不保存：

- Cookie
- Query String
- Referrer
- User-Agent

日志保留 URI 路径、经过可信代理校验的 `client_ip` 和直接连接对端 `edge_ip`，用于登录攻击审计、Cloudflare 信任检查以及 WordPress/WooCommerce 路由性能判断。IP 只存在于每日轮转的 Nginx 原始日志，不写入 SQLite 指标库；Query String、Cookie、Referrer 和 User-Agent 仍不记录。应按适用的隐私法规控制日志访问和保留期。

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
- PHP 达到最大进程数的新增事件
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

确认并重新校验建议后，才会写入受影响的进程池配置，并重载相关 PHP-FPM 服务。写入候选值后会用 PHP-FPM 最终合并配置验证每个目标 pool 的有效 `pm.max_children`；语法、语义或重载失败都会恢复原 pool 和 `tuning.v1`，不会把被外部配置覆盖的候选值报告为成功。

无人值守确认：

```bash
sudo wp-shell tune --apply --yes
```

不建议在第一次运行时使用 `--yes`，应先人工检查建议和服务器可用内存。

### 3. 自动调优的安全限制

自动调优目前只修改每个站点的 PHP-FPM `pm.max_children`：

- 每个站点至少有 1,000 个有效 PHP 样本，跨度不少于 24 小时，最近样本不超过 180 秒。
- 老版本没有有效性标记的样本、失败探测得到的占位数值，不用于自动调优。
- 增加进程数要求所选观察窗口内 CPU 峰值低于 85%，可用内存最低占比至少 25%。这是偏保守的门槛，短暂 CPU 峰值也可能阻止自动扩容。
- 需要至少 10 次、且占有效样本至少 1% 的排队或活动进程达到配置上限的证据；一次历史累计饱和事件不再触发扩容。
- 按实测 PSS/进程数加 25% 余量估算单进程消耗，最低按 96MB；所有建议合计不得超过共享 OPcache 扣除后的 PHP 工作进程预算。
- 调优只改变站点 pool，不运行完整 `configure_php`，因此 prospective budget 使用 `php-fpmVERSION -tt` 读取的当前有效 default/站点 pool 作为基线；只把目标站点当前有效值替换成建议值，不假定 default pool 会同时降为 1。
- 当前受管站点文件中的上限必须与 PHP-FPM 最终有效上限一致；若更晚的管理员配置改变了结果，自动调优会停止并要求先解决 override，不修改管理员文件。
- Swap 只作为风险信号，不增加 worker 容量。
- 观察窗口出现 OOM 增量、持续/增长的 Swap、明显内存 PSI、严重 IO PSI/IO wait、危险或无法确认的 MariaDB 有效配置、或当前 PHP 总量已经超预算时，禁止自动扩容。
- 从 PHP-FPM 最终合并配置读取当前有效上限，并与受管 pool 文件交叉验证；`analyze 7d` 与 `tune --apply --range 7d` 使用相同时间范围。
- 应用调优与部署/配置操作共用互斥锁；分析报表使用独立建议文件，不会覆盖等待确认的调优计划。
- 降低额度需要接近 14 天的持续低峰值使用。
- 单次调整约为 20%。
- 每站点限制在 1 至 50 个 PHP 子进程；`1` 是资源紧张主机的兼容下限，不代表所有生产负载都适合该容量。

自动覆盖值保存在：

```text
/etc/wp-shell/tuning.v1
```

MariaDB 和 Redis 的分析结果目前只作为建议展示，不会仅凭聚合计数自动改写它们的内存配置。这样可以避免在缺少 buffer pool 命中率、业务峰值和磁盘延迟背景时做出危险调整。

PHP-FPM 的 `max children reached`、MariaDB 慢查询和 Redis 淘汰都是服务启动以来的累计计数器。看板和历史报告按相邻样本的正向增量展示新增事件，重启后的计数归零不计为负数。自动扩容另外要求持续的排队/活动进程证据，不再仅根据累计计数器增量决定。

手动运行 `sudo wp-shell metrics collect` 成功时不会输出内容。v9.4.5 曾把 SQLite WAL checkpoint 的内部结果 `0|0|0` 打印到终端；该字符串不代表采样数量为零或采集失败，v9.4.6 已隐藏这项内部输出。采样数量应通过 `sudo wp-shell metrics status` 查看。

### 4. 重新应用初始资源预算

```bash
sudo wp-shell dry-run apply
sudo wp-shell optimize --confirm
```

`optimize` 在 v10 中是事务化 `apply` 的兼容别名，不再无确认改写资源。MariaDB 新配置不会在缺少命中率、慢查询和磁盘延迟证据时自动设置 Buffer Pool；风险门槛内的已有受管数值会保留，危险的旧值则阻断普通 `apply`，必须先显式审计和迁移。PHP worker 的自动变化仍只来自满足采样门槛的 `tune --apply`。

### 5. OPcache：检查、调整和验收（v9.4.8 起）

OPcache 缓存 PHP 编译结果，与 Redis 对象缓存、Nginx FastCGI 整页缓存不同。同一个 PHP-FPM 服务下的网站共享 OPcache，**不是每个网站、每个 PHP 子进程各占一份**。例如两个网站都使用 PHP 8.4，只需设置一次 8.4。

#### 先检查实际状态

```bash
sudo wp-shell opcache status
# 也可以只看一个版本
sudo wp-shell opcache status 8.4
free -m
```

也可运行 `sudo wp-shell`，选择 `16) OPcache settings`，输入 PHP 版本。看完状态后，在容量输入处直接回车即可退出，不修改配置。

状态输出分为三层：

- `Managed target`：脚本保存的目标；没有保存值时，读取已有 `99-zz-local-opcache.ini`，否则使用初始值 128/16MB。
- `Configuration on disk`：PHP-FPM 新进程读取的 INI 值，**不能单凭这个证明正在运行的进程已经生效**。
- `Runtime`：通过本机 Unix socket 请求运行中的 FPM，显示实际容量、Full、已用/空闲/浪费内存、字符串缓存、脚本数、键数、命中率及 OOM/hash/manual 重启计数。

运行时探针不启动 WordPress、不创建公网 `phpinfo.php`、不开放端口。它在 `/run` 临时生成一个只返回缓存统计的文件，请求结束后删除。需要 `libfcgi-bin`、`jq`、正常运行的本地 FPM socket；缺失或被 pool 限制时显示 `Runtime: unavailable`，不把缺失数据当成“正常”。自定义 `chroot`、`open_basedir`、`opcache.restrict_api` 可能限制探针，不应为读取状态而盲目移除这些安全设置。

#### 容量已满且内存足够时再调整

例如已经确认 128MB 缓存和 16MB 字符串空间耗尽，且服务器还有足够可用内存，可把 **256/32MB 作为第一轮测试值**：

```bash
sudo wp-shell opcache set 8.4 256 32
sudo wp-shell opcache status 8.4
sudo wp-shell site status
```

这不是所有网站的统一最佳值。`memory_consumption` 是总共享缓存容量，字符串空间包含在其中，预算不再额外加一次字符串容量。脚本限制单版本总容量为 64–2048MB、字符串为 4–512MB 且不超过总容量一半；各受管 PHP 版本的总 OPcache 目标不能超过服务器内存的 25%。扩容还要求当前可用内存覆盖增加量，并保留至少 256MB 或总内存 10%（取较大值）的余量。这些保护不等于承诺高峰时绝不会内存不足。

OPcache 增大还会先在内存中暂存候选值，重新计算 PHP worker 硬预算，并用 `php-fpmVERSION -tt` 读取当前有效 default/站点 pool。若现有 worker 暴露量放不进缩小后的候选预算，或者有效 pool 无法验证，命令会在写状态文件、写 INI 或重载 FPM 前拒绝。它不会顺带缩减站点 pool；应先明确降低并重新应用 worker 配额。OPcache 减小会释放预算，因此即使主机原已超配，只要操作不使状态更差，也可作为恢复操作执行。

此命令只做以下操作：

1. 备份旧的 OPcache 状态文件和受管 INI，保存在 `/etc/wp-shell/opcache-backups/时间戳.随机值/`，目录只有 root 可读。
2. 保存 `/etc/wp-shell/opcache.v1`，并写入 `/etc/php/8.4/fpm/conf.d/zz-wp-shell-opcache.ini`。
3. 运行 `php-fpm8.4 -t`，验证实际 INI 值没有被更晚加载的配置覆盖。
4. 执行 `systemctl daemon-reload`，再平滑重载对应的 `php8.4-fpm`。
5. 校验或应用失败时恢复原文件；如果恢复后的服务重载也失败，会明确报错，并给出备份位置供人工处理。

**不会重写 Nginx、WordPress 文件、数据库、Redis、PHP pool 进程额度，也不需要执行 `optimize` 或 `site deploy`。** 但重载会影响同一 PHP 版本的所有网站，并使 OPcache 重新预热，应选择低流量时段。PHP 服务的其他待生效配置也会随该服务重载生效。

脚本不会修改或删除已有的 `99-zz-local-opcache.ini`。首次没有持久值时，会沿用其中的两个有效数值；保存后以 `opcache.v1` 为准，并用排序更晚的受管 INI 生效。后续添加网站或重新应用 PHP 配置会保留这些数值，不再退回硬编码的 128/16。受管文件同名但没有 wp-shell 标记、是符号链接，或有更晚 INI 覆盖目标值时，应用会拒绝而不是悄悄覆盖。

如果你已经手工设置了 256/32MB，只需升级脚本后执行上面的 `opcache set 8.4 256 32`，把现值纳入持久配置。仅下载新脚本不会替你修改正在运行的 PHP。

#### 如何判断生效

重载后稍等片刻，访问首页、分类页、文章和后台，再次运行状态命令：

- `Runtime` 应显示 `256 32`，并与目标及磁盘配置一致。
- 预热后 `Full: false`，普通缓存和字符串缓存都有余量。
- 命中率在有代表性的使用后观察；刚重载的低命中率不能直接判定异常。
- OOM/hash 重启不应持续增长；同时检查网站状态和错误日志。

这里是手动按需检查，不会把 OPcache 自动扩容或定时清空；资源分析的历史表尚未采集 OPcache 运行时指标。不要为了命中率归零而反复清缓存，也不要仅凭这些值增加 PHP 进程数。

需退回上一组已知参数时，例如原来为 128/16MB：

```bash
sudo wp-shell opcache set 8.4 128 16
```

备份不会自动清理，`manifest` 记录变更前两个文件是否存在；备份只包含本次命令管理的文件，不是整个 PHP 或网站备份。遇到服务恢复失败，应结合备份和 `journalctl -u php8.4-fpm` 人工核查，不能把不完整的文件复制当成完整服务器回滚。

若旧版曾提示 `unit file ... changed on disk`，可先执行：

```bash
sudo systemctl daemon-reload
```

该命令只让 systemd 重读服务定义，不会单独重启网站或让 PHP INI 生效。v9.4.8 起脚本的 PHP 重载/重启路径会先执行此步骤。

## 十、资源预算逻辑

脚本先为操作系统预留内存，再为各服务计算安全初始值：

- MariaDB：资源报告仍保留保守预算估算，但该数字不是实际配置；`mariadb audit` 才显示 runtime、下次启动值和定义来源。新安装只设置 loopback、字符集和慢查询日志；没有监控证据时不把估算值写成 Buffer Pool。风险门槛内的已有受管内存值会保留，危险旧值会阻断普通应用。
- Redis：通常约总内存的 5%，限制为 32MB 至 512MB；约 2GB VPS 的默认起点为 96MB，可通过受验证参数覆盖。
- OPcache：每个不同的受管 PHP 版本预留一份共享容量，沿用已保存或已有的手工值；未配置时为 128MB（其中字符串空间 16MB）。
- PHP-FPM：扣除系统/page cache、临时 PHP/备份任务、MariaDB 规划量、Redis、Nginx cache zone 和共享 OPcache 后形成硬 worker 预算；任何成功分配都必须满足总 worker 估算不超过该预算。
- PHP 进程：指标不足时按 96MB/进程；有至少 1,000 个有效样本、24 小时跨度和新鲜数据时，使用每进程 PSS 的 95 分位加 25% 余量，并在多站点间采用最高合格值。
- 非 FPM 峰值：系统预留中明确保留临时 PHP/备份空间，用于 WP-CLI、WP-Cron、WooCommerce Action Scheduler、插件更新、图片处理和备份等短时任务。这是规划余量，不是这些任务内存的精确上限。
- WooCommerce：初始 pool 权重是普通网站的两倍，但只影响有限 slots 的分配顺序，绝不扩大整机 worker 预算。
- FastCGI keys zone：每个网站 16MB。
- 每个启用 PHP 版本的默认 `www` pool 也按一个 worker 计入；每个网站最低 1、默认上限 50。无法安全提供每站点一个 worker 时直接拒绝配置。
- Swap 是 OOM 前的应急缓冲和风险信号，不参与常驻 worker 容量计算；“有更多 Swap”不会让 2GB 主机获得更多 PHP workers。

这些值是安全起点，不是所有网站的最终最佳值。主题、插件、流量结构、缓存命中率和 WooCommerce 请求比例都会改变实际内存需求。

2GB 主机的 PHP 基线为 `memory_limit=256M`、执行/输入时间 120 秒、上传 16M、POST 20M、`expose_php=Off`、`pm.max_requests=300`。脚本不默认设置容易破坏插件调用的 `disable_functions`。上传大备份应优先使用所选备份工具的分片或远端传输能力；确需提高限制时，应作为明确的主机策略修改并重新做内存与超时验收。

主题或插件明确要求不同 PHP 限制时，不要修改脚本生成的 `99-wp-shell.ini`。可为对应 PHP 版本创建排序更晚的本机兼容文件，例如 `/etc/php/8.3/fpm/conf.d/zz-wp-shell-compat.ini`，只写插件文档明确要求的项目；wp-shell 会保留该文件，并在每次重载前运行 FPM 配置测试。不同 PHP 版本分别维护，避免把一个网站的特殊要求误当成所有版本和站点的通用默认值。

若剩余内存不足最低 PHP worker 额度，脚本会在任何 pool 写入或 PHP 重载前停止。1GB 仍是平台安装检查的最低门槛，但现代 WordPress、数据库、Redis、OPcache、默认 PHP pool 与站点 pool 的组合通常可能无法通过硬准入；这时应增加 RAM 或减少服务/站点，而不是依赖 Swap。该预算仍不是内核级 cgroup 限制，不能替代真实 PSS、可用内存和峰值观测。`opcache set` 不会主动重新分配已有 worker；增大缓存前必须证明现有有效 pool 仍能容纳在新的硬预算内。

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
/etc/wp-shell/opcache.v1                  按 PHP 版本保存的 OPcache 容量
/etc/wp-shell/opcache-backups/            OPcache 应用前的受管文件备份
/etc/wp-shell/site-policy/               每站点用户、定时任务、缓存和异地备份策略
/etc/wp-shell/host-policy.v1             Cloudflare、Redis覆盖值和外部邮件等主机策略
/etc/wp-shell/transactions/              配置事务的修改前副本、清单和提交指纹
/etc/wp-shell/nginx-backups/             Nginx 模板更新前的配置快照
/etc/nginx/wp-shell-custom/DOMAIN/        保留的每站点自定义 *.conf
/etc/nginx/conf.d/wp-shell-cloudflare-realip.conf  验证后的 Cloudflare 可信代理网段
/etc/cron.d/wp-shell-POOL_ID              每五分钟、以站点用户运行的可选 WP-Cron
/etc/wp-shell-redis/                     可选独立 Redis 实例配置
/etc/php/VERSION/fpm/conf.d/zz-wp-shell-opcache.ini
/etc/php/VERSION/fpm/pool.d/zz-wp-shell.conf
/etc/nginx/conf.d/wp-shell-log-format.conf
/usr/local/sbin/wp-shell                  安装后的主程序
/usr/local/bin/wp-shell                   全局命令链接
/var/lib/wp-shell/metrics.sqlite3         本地指标数据库
/var/log/wp-shell/                        部署和管理日志
```

配置和密码文件使用 root `0600` 权限。所有站点操作统一通过 `wp-shell` 执行。数据库密码使用受控标准输入，Redis CLI 使用 `REDISCLI_AUTH`；写入 `wp-config.php` 时先让 WP-CLI 写入非敏感占位符，再由 root 在同一目录中完成原子替换。密码不作为外部进程命令行参数，也不在成功日志中回显。

## 十三、从旧版本升级

### 1. 拉取最新代码

如果使用 Git：

```bash
cd /path/to/wp-shell
git pull --ff-only
bash -n ./wp-shell.sh && sudo install -o root -g root -m 0755 ./wp-shell.sh /usr/local/sbin/wp-shell
sudo wp-shell --version
```

如果之前只下载了单个脚本：

```bash
wget -O wp-shell.sh.new https://raw.githubusercontent.com/hwc0212/wp-shell/main/wp-shell.sh &&
bash -n wp-shell.sh.new &&
sudo install -o root -g root -m 0755 wp-shell.sh.new /usr/local/sbin/wp-shell &&
sudo wp-shell --version
```

只更新脚本不需要重新运行 `install` 或 `site deploy`。这不会自动改动现有网站、PHP 用户、OPcache 手工参数或 SSH 登录方式。v10 功能的应用和验收见下方“十八、v10.0.5 升级后的操作”。

### 2. 从 v9.4.2 或 v9.4.3 升级后的必要安全操作

v9.4.2 在部署或修复网站时，WP-CLI 的成功信息可能把 Redis 密钥回显到 SSH 终端和对应的 `/var/log/wp-shell/` 日志。只要使用过该版本执行 `site add` 或 `site deploy`，就应把当前 Redis 密钥视为已经暴露。

v9.4.3 首次提供的轮换命令错误地尝试用 `--prompt=value` 填充 WP-CLI 必需的位置参数。真实 WP-CLI 会显示 `wp config set <name> <value>` 用法并拒绝执行；脚本随后会回滚 Redis 和已修改配置，因此不会留下半完成轮换，但旧密钥仍然有效、旧日志也仍需脱敏。升级并安装 v9.4.4 或更新版本后，先执行：

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

### 3. 从 v9.4.6 或更早版本升级后的 WordPress 7.x 核心修复

WP-CLI 2.12.0 使用 PHP `PharData` 解压 WordPress 7.x 的 tar 包时，可能把超过 100 个字符的路径静默截断。v9.4.6 及更早版本调用默认 `wp core download`，因此由这些版本新建的 WordPress 7.x 网站可能存在缺失的长路径核心文件及对应的截断文件。

v9.4.7 改为只使用 WordPress 官方 ZIP 包，并在下载后执行严格校验。升级后，应对每个由旧版脚本创建的 WordPress 7.x 网站运行一次：

```bash
sudo wp-shell site 1 core-repair
sudo wp-shell site 2 core-repair
sudo wp-shell security-scan
```

`core-repair` 会自动备份，不会修改 `wp-content`、`wp-config.php` 或数据库。普通 WP-CLI 校验即使发现额外文件仍可能以退出码 0 结束；wp-shell 的严格校验会把缺失文件和额外文件都视为失败。

### 4. 自动迁移的旧配置

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
- Nginx 阻止通过 HTTP 直接访问 WordPress 上传目录 PHP、`wp-admin/includes`、include-only 核心 PHP、`wp-config.php`、日志、SQL、INI 和备份后缀等敏感文件。
- 新网站从 WordPress 官方 ZIP 包安装，并立即执行严格核心校验；核心修复会先自动备份。
- `wp-config.php` 由 root 拥有并使用 `0640`；共享站点组为 `www-data`，独立 PHP 用户使用自己的私有组，避免其他站点读取配置。
- WordPress 在线文件编辑默认关闭。
- PHP-FPM status 使用本地 Unix socket，不通过 Nginx 暴露。
- Nginx 配置必须验证成功后才会生效。
- UFW 不执行 reset，并在启用前保留当前 SSH 端口。
- Fail2ban 默认只启用可验证的 SSH jail；Cloudflare 后的 Web 登录攻击交给可信真实 IP 限速，并可选用独立维护的应用防火墙或 Cloudflare WAF。
- HTTPS 启用 TLS 1.2/1.3 和常用安全响应头；HSTS 是显式站点策略，默认不加入 `includeSubDomains` 或 `preload`。
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

只有执行过 `site DOMAIN hsts enable` 的站点才要求源站返回 `max-age=15552000`。如果源站返回该值，而公网端点返回 `max-age=0`、其他值或没有该响应头，说明 VPS 上的 Nginx 策略已生效，但域名前方的 CDN、负载均衡器或反向代理覆盖了响应头。此时应在对应代理服务中核对 HSTS，重复运行 `sudo wp-shell security-scan`，而不是反复重新部署 WordPress。

## 十六、开发和测试

本地测试：

```bash
bash tests/static-checks.sh
bash tests/config-roundtrip.sh
bash tests/render-nginx.sh
bash tests/storage-layout.sh
bash tests/metrics-roundtrip.sh
bash tests/wordpress-core.sh
bash tests/dashboard-smoke.sh
bash tests/menu-routing.sh
bash tests/opcache-config.sh
bash tests/php-memory-budget.sh
bash tests/restore-transaction.sh
bash tests/mariadb-legacy.sh
bash tests/imported-site-reliability.sh
bash tests/reliability-regression.sh
bash tests/control-plane.sh
bash tests/cloudflare-policy.sh
bash tests/compatibility-policies.sh
```

ShellCheck：

```bash
shellcheck -x wp-shell.sh wp-vps-manager.sh deploy-single-wordpress.sh tests/*.sh
```

GitHub Actions 还会在 Ubuntu 24.04 容器中使用真实的 Nginx、MariaDB、Redis 和 PHP-FPM 验证生成的配置，并在 Ubuntu 22.04/24.04 容器中分别验证 MariaDB 旧配置的实际解析、显式迁移和幂等性。OPcache 测试覆盖手工参数接管、持久值重用、共享预算去重、无效参数/低内存拒绝、配置及重载失败回滚、INI 加载冲突，以及通过真实 FPM socket 读取运行时状态。

v10.0.5 继续保留原有备份、调优、采集、Redis 隔离、WP-CLI 签名和恢复演练测试，并覆盖配置事务、失败回滚、MariaDB 旧值检测/只读审计/精确回滚、导入站点非 root 连续配置写入及失败后权限恢复、Cloudflare CIDR、staging noindex、未知 Host、敏感路径、不存在 PHP 404，以及页面缓存、对象缓存、XML-RPC、响应头和 Cloudflare 登录策略不会在未选择时自动启用。PHP 硬预算矩阵覆盖 1/2/4/8/16GB、单站点/多站点、普通/WooCommerce/混合站点、零/低/较大 Swap、多 PHP 版本、旧站点数量、全局 override、PSS 证据、压力否决、幂等和失败前无写入，并通过导入联合测试确认容量不足时不持久化站点或 policy、容量足够时仅按目标站点或默认 PHP 完成一次幂等导入。新增 restore 测试覆盖 journal admission、历史保留、低磁盘拒绝、备份 `wp-config.php` 恢复后当前数据库凭据的无命令行泄露重写、真实 MariaDB 成功恢复、数据库中途失败自动回滚、`TERM` 中断回滚、回滚失败保持 maintenance，以及后续显式 recovery。`nginx-integration.sh`、`service-config-integration.sh`、`restore-transaction-integration.sh`、`operations-integration.sh`、`mariadb-legacy-integration.sh` 和 `imported-site-integration.sh` 会修改系统配置，只能按 CI 的方式在可丢弃容器中以 root 运行，不能在生产 VPS 上执行。

## 十七、当前边界

不提供 Web 控制面板是项目的明确设计目标，而不是缺失功能。

项目专注于一台 Ubuntu VPS，不宣称支持：

- 集群和高可用
- 数据库复制
- 自动跨服务器迁移
- 一键克隆网站
- 在未配置目标和加密凭据时自动上传云端备份
- 托管式控制平面
- 自动完成所有 MariaDB 和 Redis 性能调优

异地备份已提供显式选择的 rclone crypt 上传与下载校验；其余未列入命令帮助的能力不视为已实现。脚本也不会自动关闭 SSH 密码登录、修改内核/sysctl、创建 swap、关闭或配置第三方安全插件，或把 Redis DB 编号当作安全隔离。

## 十八、v10.0.5 升级后的操作

### 1. 先验证脚本和现有站点，不要重新部署全部环境

完成“十三、从旧版本升级”中的脚本更新后运行：

```bash
sudo wp-shell --version
sudo wp-shell site list
sudo wp-shell site status
sudo wp-shell opcache status
sudo wp-shell metrics install
sudo wp-shell metrics collect
sudo wp-shell metrics status
sudo wp-shell system audit
sudo wp-shell mariadb audit
sudo wp-shell audit
sudo wp-shell dry-run apply
```

如果 MariaDB 审计报告 `Unsafe legacy/wp-shell definitions detected`，先不要执行普通 `apply`。确认已具备外部备份和 SSH 维护窗口后，运行 `sudo wp-shell mariadb migrate-legacy --confirm`，再重复审计；没有该警告时不需要为了版本号主动重启 MariaDB。

升级到 v10.0.4/v10.0.5 后先查看 `audit` 中的 `PHP-FPM hard capacity admission`。`SAFE` 表示按当前物理 RAM、站点、PHP 版本、OPcache 和 worker 证据可以生成不超过硬预算的配置；`OVERCOMMITTED` 表示实际 pool 总量高于预算；`BLOCKED` 表示站点最低需求或已有 tuning override 已经无法容纳。只读审计不会改 pool 或重载 PHP。

现有 pool 超预算但没有强制 override 时，确认计划后运行 `sudo wp-shell apply --confirm` 会把 wp-shell 管理的 limits 重新分配到硬预算内。显式 override 不会被静默缩小；请先审查 `/etc/wp-shell/tuning.v1`，明确降低对应值后再运行审计与 apply。不要通过增加 Swap、删除 OPcache 余量或提高 PHP 预算来绕过准入。低流量站点变为一个 ondemand worker 是允许的兼容结果；高峰负载不能接受该容量时，应减少同机站点或增加物理 RAM。

采样历史保留。新采样才带有探测有效性标记，因此升级后暂时没有自动扩容建议是正常保护，不是采集故障。看板中的 `PHP ?`、`Logs ?` 或共享服务的 `?` 表示探测不可用或日志覆盖不完整，不能解释为零负载。目录大小最多每 15 分钟刷新一次，单次扫描限时；失败时保留上次值或显示未知。访问日志每次最多处理 5MiB，超限会标记覆盖不完整。

`analyze` 增加 CPU steal、IO wait、内存/IO PSI、inode 占用和内核累计 OOM 计数。共享 Redis 与独立 Redis 分开列出。`system audit` 的 `PASS/WARN/UNKNOWN` 是逐项检查结果：不能获取的信息不会当作通过，某个 PASS 也不表示整台服务器绝对安全。

### 2. 应用 Nginx 缓存与安全模板

每个站点单独操作。已有手工改过的 Nginx 规则，尤其是 staging 路由、反向代理和自定义 WooCommerce 路径，应先审查并移到 `/etc/nginx/wp-shell-custom/DOMAIN/*.conf`。这些文件会保留；脚本无法自动判断旧文件中的任意手工改动是否应当迁移。

```bash
sudo wp-shell backup example.com
sudo wp-shell site example.com nginx-apply
sudo wp-shell site example.com status
sudo wp-shell security-scan
```

更新前的 Nginx 配置保存在终端显示的 `/etc/wp-shell/nginx-backups/` 快照中。新模板提供：

- Authorization、非 GET/HEAD、查询参数、登录 Cookie、REST、嵌套后台/登录路径等页面缓存绕过规则；继续尊重上游 `Cache-Control` 和 `Set-Cookie`。
- 对 CSS、JS、JSON、SVG 等文本资源启用 Gzip；HTTP/2 继续保留。
- 静态资源采用较保守的 7 天浏览器缓存，不添加 `immutable`，降低主题、插件或媒体使用同 URL 替换文件时长期显示旧内容的风险。已进入浏览器的旧缓存不能靠服务器清理立即撤回。
- 拒绝直接下载多种常见备份工具的默认目录内容；这是通用的路径级防护，不会安装或配置这些插件。自定义备份路径仍需单独检查。
- 支持 Nginx 层维护标记。

FastCGI 匿名整页缓存默认关闭。它可能缓存主题或插件没有正确声明为私有的个性化 HTML，启用前应先列出登录、会员、表单、搜索、API、购物车和账户路径。确认后执行：

```bash
sudo wp-shell site example.com page-cache enable --confirm
sudo wp-shell site example.com page-cache status
```

升级旧版时，如果现有受管 Nginx 文件已经启用 FastCGI 缓存，首次重新渲染会登记并保留原行为，不会借升级静默关闭线上缓存；全新站点及没有缓存证据的站点保持关闭。自定义动态路径需要显式排除，例如：

```bash
sudo wp-shell site example.com cache-exclude /staging/
sudo wp-shell site example.com cache-exclude /basket/
```

这里的路径只是示例，替换成实际 URL 路径，并以 `/` 结束。排除缓存不等于自动配置 staging 的 WordPress 路由、数据库、Cookie 或 Redis 隔离，也不等于解决所有插件授权问题。

明确启用页面缓存后，匿名访问同一公开页面两次应能看到 MISS 后 HIT；登录/鉴权/后台路径应不命中，POST 可能不输出 `X-FastCGI-Cache`，不能要求它一定显示 BYPASS：

```bash
curl -sS -o /dev/null -D - https://example.com/ | grep -Ei 'HTTP/|x-fastcgi-cache|cache-control'
curl -sS -o /dev/null -D - https://example.com/ | grep -Ei 'HTTP/|x-fastcgi-cache|cache-control'
```

有 CDN 时还要区分源站和公网响应。脚本无法替你清除 CDN、浏览器或其他页面缓存插件中的内容。

Redis 服务可以安装在主机上而不接管某个 WordPress 网站。对象缓存集成默认关闭，因为网站可能已经使用其他对象缓存 drop-in，或插件作者要求不同配置。需要时逐站点执行：

```bash
sudo wp-shell site example.com object-cache enable --confirm
sudo wp-shell site example.com object-cache status
sudo wp-shell site example.com object-cache disable --confirm
```

禁用只移除 Redis Object Cache 的活动 drop-in，不删除插件文件、Redis 数据或已有常量。升级旧版时，脚本只会把已经处于 active 状态的 `redis-cache` 集成登记为启用，不会因为服务器装有 Redis 就给其他网站自动安装插件。

### 3. 内容更新后自动清理页面缓存（可选）

```bash
sudo wp-shell site example.com cache-auto enable
sudo wp-shell site example.com cache-auto status
```

此命令会安装一个小型 MU 插件 `wp-content/mu-plugins/wp-shell-cache.php`，监听文章、菜单、主题、分类、评论、升级等事件，在文档根目录外写入变更标记。systemd 任务约一分钟内清理该域名的页面缓存，不清空对象缓存、不重载 PHP-FPM，也没有常驻 Web 面板进程。

不需要定时清空全部缓存。页面默认 TTL 仍为 30 分钟；第三方插件的特殊修改若不触发上述事件，可手动 `cache-clear page`。该功能目前仅支持 `/var/www/DOMAIN/public` 布局；复制到子目录的 staging 不会自动作为独立受管站点处理。

```bash
sudo wp-shell site example.com cache-auto disable
```

禁用只移除对应的 wp-shell MU 插件和策略，不删除其他插件或网站内容。

### 4. 用系统任务运行 WP-Cron（可选）

```bash
sudo wp-shell site example.com cron enable
sudo wp-shell site example.com cron status
```

先检查并避免已有 crontab/云平台重复调度。脚本只做 WordPress 安装预检，不会为了“测试”而运行任何到期任务；随后原子写入 `/etc/cron.d/wp-shell-POOL_ID`，再设置 `DISABLE_WP_CRON=true`。任务每五分钟以该站点用户和对应 PHP 版本运行，使用 `flock` 防重叠并限制 240 秒；不是以 root 执行网站 PHP。

失败时检查 `/var/www/DOMAIN/logs/wp-cron.log` 和 `/etc/cron.d/wp-shell-POOL_ID`。切回之前的设置：

```bash
sudo wp-shell site example.com cron disable
```

会先恢复启用前的 `DISABLE_WP_CRON` 值，再删除受管 Cron 文件。如果原值已经是 true，应确认原来的外部调度仍然存在。

### 5. 旧网站的用户和 Redis 隔离（可选，低流量时执行）

新建网站默认采用独立 Linux/PHP 用户；仅升级脚本不会迁移旧站。旧站先完成 Nginx 模板更新，并安装 ACL 工具：

```bash
sudo apt-get install acl
sudo wp-shell site example.com isolate
```

确认后会备份网站，短暂开启维护模式，记录原权限，然后调整 PHP pool 与文件所有者。独立站点目录/普通文件为 750/640；`wp-config.php` 为 `root:站点私有组 0640`，既阻止 PHP 修改自身配置，也不让其他站点组读取。共享旧站使用 `root:www-data 0640`。迁移失败会尝试恢复原 PHP pool 和 ACL/所有者；若回滚也失败，会保留维护状态及现场快照，不会宣称已恢复。插件写文件、备份、上传和 staging 功能都应再抽查。所有站点都迁出共享 UID 后，文件系统边界才更完整；这不是容器或虚拟机级隔离。

Redis DB 编号和前缀不是访问控制。需要对象缓存隔离时，再执行：

```bash
sudo wp-shell site example.com redis-isolate 64
sudo wp-shell site example.com status
sudo wp-shell rotate-redis-secret
sudo wp-shell security-scan
```

`64` 表示从原有 Redis 总预算中划出 64MB，而不是额外再给每站点一份总预算。共享实例至少保留 32MB，超过总预算会拒绝。独立实例有单独 Redis 用户、Unix socket、密码，不监听 TCP，使用自己的 DB 0。减少共享实例容量可能触发旧缓存淘汰。

迁移后应轮换共享 Redis 密钥，撤销该站点此前可能保存在旧配置/插件备份中的共享密码；轮换会跳过独立 Redis 站点。不能只迁移一个站点就宣称所有旧站已经完全隔离。独立实例当前不提供自动合并回共享实例或自动调整其容量，需按实际数据审查配置后处理。

### 6. 备份校验、恢复演练和加密异地备份

```bash
sudo wp-shell backup example.com
sudo wp-shell backup verify example.com latest
sudo wp-shell backup drill example.com latest
```

备份会在空间预检、文件归档、数据库导出、完整清单生成和实际校验都成功后才发布为正式备份。任一步失败返回非零值，不会以空清单假装成功；批量备份仍会继续处理其他站点，并最终报告失败。日志、缓存和私有备份目录不会在旧的非 public 布局中被递归打进自身备份。

`verify` 检查校验和、站点归属及压缩包。`drill` 额外解包到临时目录，把 SQL 导入临时数据库；专用临时数据库用户没有其他数据库/服务器权限，导入禁用客户端 shell 命令和 LOCAL 文件读取，结束后清理临时数据库和用户。它**不会运行插件、发送邮件或执行网站 PHP，也不等于完成真实访客页面、下单和邮件功能的恢复验收**。含链接或特殊 DEFINER 权限的备份可能需人工处理，不会强行继续。

异地备份默认关闭。先自行选择存储目标、安装 `rclone`，并以 root 配置一个 **crypt 加密 remote**；密钥在服务器终端配置，不要发送到聊天或写进 GitHub：

```bash
sudo rclone config
sudo wp-shell backup remote example.com encrypted:wp-backups
sudo wp-shell backup example.com
```

`encrypted` 替换成你配置的 crypt remote 名称。脚本拒绝普通未加密 remote，并在上传后下载校验，因此会产生额外上传/下载流量与存储费用。远端失败时保留本地备份，跳过本地过期清理，整次任务报告失败。脚本不会删除远端文件或为你购买云存储。

```bash
sudo wp-shell backup remote example.com status
sudo wp-shell backup remote example.com off
```

请把 crypt 密钥保存在服务器外；只存于同一 VPS 的密钥和备份无法应对整机丢失。灾难恢复仍需你从远端取回解密后的归档，验证后再走恢复流程。

### 7. 系统安全和登录保护

```bash
sudo wp-shell system audit
sudo wp-shell system logs install
sudo wp-shell system wp-cli verify
```

巡检覆盖 SSH 有效默认值、数据库/Redis 监听地址、匿名/远程 root 数据库账号、更新与备份/证书/指标 timer、待重启标记、AppArmor、磁盘/inode、内存和压力信息。SSH Match 块、非默认数据库端口、云安全组和 CDN 防护仍需结合实际配置检查。Fail2ban 默认只有 SSH jail；它不冒充 Cloudflare 后的 WordPress 表单封禁器。

`system wp-cli verify` 会下载固定版本 PHAR 与签名，检查官方固定 GPG 指纹并验签，成功后才执行/安装；需 `curl`、`gpg` 和 PHP CLI。不要把单纯下载到文件视为已经验签。

自动安全更新需要明确选择：

```bash
sudo wp-shell system updates enable --confirm
sudo unattended-upgrade --dry-run --debug
```

保留现有允许来源列表，并禁止自动重启。尤其要核实 PHP PPA 是否被允许，不能因为 timer 活跃就认为第三方 PHP 安全更新也已覆盖。

仅对直接到达 Nginx 的访客连接，可选择登录 POST 限速：

```bash
sudo wp-shell site example.com login-limit direct
sudo wp-shell site example.com login-limit status
sudo wp-shell site example.com login-limit off
```

默认每个验证后的客户端 IP 10 次/分钟、burst 20，只限制 `wp-login.php` POST，超限返回 429，不拦截普通后台 AJAX。该全局限速区可在启用站点间共享计数。Cloudflare 站必须先执行 `cloudflare enable --confirm` 并检查真实 IP；脚本不信任任意来源的 `X-Forwarded-For`。限速不替代密码强度、2FA、漏洞修复或独立维护的应用层安全方案。

### 8. 最后验收

```bash
sudo wp-shell security-scan
sudo wp-shell site status
sudo wp-shell metrics status
sudo wp-shell analyze 7d
sudo systemctl --failed --no-pager
```

再抽查两个网站的匿名页面缓存、登录/后台、媒体上传、插件更新、WP-Cron 和实际备份恢复。脚本的自动测试不能代替你 VPS 上现有插件、staging 和自定义规则的验收。不要为了看到“推荐扩容”而降低采样/CPU/内存安全门槛，也不要把同一分钟各站点以外的历史峰值简单相加当成实测总内存。

## 免责声明

本项目按现状提供。生产环境使用前，请在相同 Ubuntu 和 PHP 组合上测试，并保留可以在服务器之外恢复的备份。作者不对脚本使用导致的数据丢失、停机或服务中断承担责任。

## License

MIT
