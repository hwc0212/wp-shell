# WordPress VPS管理平台 (Cloudways/SpinupWP替代方案)

## 概述

**wp-vps-manager** 是一个功能强大的WordPress VPS管理脚本，专门设计用来替代Cloudways和SpinupWP等付费服务。该脚本提供了完整的VPS和WordPress管理功能，支持在单个Ubuntu服务器上部署和管理多个WordPress站点，每个站点可以使用不同的PHP版本。

## 🎯 替代方案对比

| 功能特性 | Cloudways | SpinupWP | wp-vps-manager |
|---------|-----------|----------|----------------|
| 月费成本 | $10-100+ | $12-50+ | **免费开源** |
| 多站点管理 | ✓ | ✓ | ✓ |
| 多PHP版本 | ✓ | ✓ | ✓ |
| SSL自动化 | ✓ | ✓ | ✓ |
| 性能优化 | ✓ | ✓ | ✓ |
| 备份管理 | ✓ | ✓ | ✓ |
| 监控分析 | ✓ | ✓ | ✓ |
| 完全控制 | ❌ | ❌ | ✓ |
| 自定义配置 | 有限 | 有限 | ✓ |

## 主要特性

### 🚀 核心功能
- **多站点部署**: 在单个服务器上部署多个WordPress站点
- **多PHP版本支持**: 支持PHP 8.2、8.3、8.4同时运行
- **智能站点检测**: 自动检测现有WordPress站点并导入管理
- **统一管理界面**: 类似Cloudways的控制面板体验
- **兼容性优先**: 与现有站点完全兼容，无需重新部署

### 📊 监控和分析
- **实时监控**: 系统资源和站点状态实时监控
- **访问日志分析**: 详细的访问统计和热门页面分析
- **错误日志分析**: 自动分析和报告错误日志
- **性能基准测试**: 内置性能测试工具
- **多站点对比**: 站点间访问量和性能对比

### 💾 备份和迁移
- **自动备份**: 支持定时备份设置
- **完整备份**: 包含文件和数据库的完整备份
- **站点恢复**: 快速恢复到任意备份点
- **跨服务器迁移**: 支持站点在不同服务器间迁移
- **域名迁移**: 安全的域名变更功能

### ⚡ 性能优化
- **FastCGI缓存**: 每个站点独立的FastCGI缓存
- **Redis缓存**: 共享Redis对象缓存
- **PHP OPcache**: 自动优化的PHP OPcache配置
- **MariaDB调优**: 智能MariaDB性能优化
- **Nginx优化**: 高性能Nginx配置

### 🔒 安全特性
- **SSL自动化**: Let's Encrypt SSL证书自动获取和续期
- **防火墙管理**: UFW防火墙配置和管理
- **Fail2ban集成**: 自动防护暴力攻击
- **安全扫描**: 内置安全检查工具
- **权限管理**: 严格的文件权限控制

## 系统要求

### 支持的操作系统
- Ubuntu 20.04 LTS
- Ubuntu 22.04 LTS  
- Ubuntu 24.04 LTS

### 硬件要求
- **最小配置**: 2GB RAM, 20GB 存储空间
- **推荐配置**: 4GB+ RAM, 40GB+ SSD存储
- **网络**: 稳定的互联网连接

### 软件依赖
脚本会自动安装以下软件：
- Nginx (最新稳定版)
- MariaDB 10.11
- PHP 8.2/8.3/8.4 (根据需要)
- Redis
- Certbot (Let's Encrypt)
- Fail2ban
- UFW防火墙

## 安装和使用

### 快速开始

#### 1. 下载和准备脚本
```bash
# 下载脚本
wget https://raw.githubusercontent.com/your-repo/wp-vps-manager/main/wp-vps-manager.sh

# 给脚本添加执行权限
chmod +x wp-vps-manager.sh
```

#### 2. 首次运行（新服务器）
```bash
sudo ./wp-vps-manager.sh
```

#### 3. 新服务器部署流程

首次在新服务器上运行脚本时，将自动进入新服务器部署模式：

1. **系统检查和初始化**
   - 检测Ubuntu版本和系统兼容性
   - 验证sudo权限
   - 创建必要的目录和配置文件

2. **收集站点信息**
   - 输入要部署的站点数量（1-10个）
   - 为每个站点配置：
     - 域名
     - PHP版本（8.2/8.3/8.4）
     - 管理员信息
     - 是否安装WooCommerce

3. **自动安装和配置**
   - 安装Nginx、MariaDB、Redis、PHP等
   - 配置防火墙和安全设置
   - 为每个站点创建数据库和目录
   - 获取SSL证书
   - 安装和配置WordPress
   - 设置缓存和性能优化

#### 4. 部署完成后的管理

部署完成后，您将获得：

**全局管理命令**
```bash
wp-vps-manager list        # 列出所有站点
wp-vps-manager status      # 检查所有站点状态  
wp-vps-manager backup-all  # 备份所有站点
```

**单站点管理命令**
```bash
manage-DOMAIN status       # 检查站点状态
manage-DOMAIN cache-clear  # 清除缓存
manage-DOMAIN backup       # 创建备份
manage-DOMAIN update       # 更新WordPress
manage-DOMAIN restart      # 重启服务
manage-DOMAIN info         # 查看站点信息
```

#### 5. 重要文件位置

- **站点凭据**: `/root/wordpress-credentials-DOMAIN.txt`
- **部署摘要**: `/root/wp-vps-deployment-summary.txt`
- **站点配置**: `~/.vps-manager/wordpress-sites.conf`
- **部署日志**: `/var/log/wp-deploy-*.log`

### 命令行选项

```bash
# 显示帮助
sudo ./wp-vps-manager.sh --help

# 显示版本
sudo ./wp-vps-manager.sh --version

# 列出所有站点
sudo ./wp-vps-manager.sh --list

# 导入现有站点
sudo ./wp-vps-manager.sh --import

# 启动主菜单（交互式模式）
sudo ./wp-vps-manager.sh
```

## 功能详解

### 1. 新服务器部署

首次运行脚本时，会进入新服务器部署模式：

1. **系统检查**: 验证Ubuntu版本和系统兼容性
2. **软件安装**: 自动安装所需的所有软件包
3. **站点配置**: 收集站点信息（域名、PHP版本等）
4. **自动部署**: 创建站点目录、配置Nginx、获取SSL证书
5. **WordPress安装**: 自动下载和配置WordPress
6. **性能优化**: 应用缓存和性能优化配置

### 2. 多站点管理

#### 站点管理功能
- **状态检查**: 实时查看站点运行状态
- **服务重启**: 重启相关服务（Nginx、PHP-FPM等）
- **缓存管理**: 清除各种类型的缓存
- **备份创建**: 创建完整的站点备份
- **WordPress更新**: 安全更新WordPress核心和插件

#### 添加新站点

在已有服务器上添加新站点：

```bash
sudo ./wp-vps-manager.sh
# 选择 "1) 部署新的WordPress应用"
```

配置步骤：
1. 输入新域名
2. 选择PHP版本
3. 设置管理员信息
4. 选择是否安装WooCommerce
5. 自动部署和配置

### 3. PHP版本管理

#### 支持的PHP版本
- **PHP 8.2**: 稳定版本，推荐用于生产环境
- **PHP 8.3**: 最新稳定版本，性能更优
- **PHP 8.4**: 最新版本，适合测试新特性

#### PHP版本升级

升级现有站点的PHP版本：

```bash
sudo ./wp-vps-manager.sh
# 选择 "5) 升级PHP版本"
```

功能特点：
- 支持PHP 8.2、8.3、8.4
- 自动兼容性检查
- 安全升级流程
- 回滚支持

#### 版本兼容性检查
- 自动检测站点当前PHP版本
- 检查插件和主题兼容性
- 提供升级建议和风险评估

### 4. 监控和日志分析

#### 实时监控
```bash
sudo ./wp-vps-manager.sh
# 选择 "8) 实时监控面板"
```

功能包括：
- 系统资源监控
- 服务状态检查
- 实时访问日志
- 性能指标显示

#### 访问日志分析
```bash
sudo ./wp-vps-manager.sh
# 选择 "9) 访问日志分析"
```

分析内容：
- **基本统计**: 总请求数、今日请求数、状态码分布
- **热门页面**: 访问量最高的页面排行
- **访客分析**: IP地址统计和用户代理分析
- **时间分析**: 每小时访问量分布

#### 实时监控
- **系统资源**: CPU、内存、磁盘使用率
- **服务状态**: Nginx、PHP-FPM、MariaDB、Redis状态
- **网络连接**: HTTP/HTTPS连接统计
- **实时日志**: 访问日志实时监控

#### 性能分析
- **响应时间测试**: 网站响应时间测试
- **数据库性能**: MariaDB性能基准测试
- **磁盘I/O测试**: 存储性能测试
- **综合报告**: 生成详细的性能报告

### 5. 备份和恢复

#### 备份类型
- **完整备份**: 包含文件和数据库的完整备份
- **增量备份**: 仅备份变更的文件
- **配置备份**: Nginx配置和SSL证书备份
- **数据库备份**: 独立的数据库备份

#### 创建备份
```bash
# 单站点备份
manage-example.com backup

# 所有站点备份
sudo ./wp-vps-manager.sh
# 选择 "13) 手动备份/恢复" -> "2) 创建所有站点备份"
```

#### 恢复备份
```bash
sudo ./wp-vps-manager.sh
# 选择 "13) 手动备份/恢复" -> "3) 恢复站点备份"
```

#### 自动备份
```bash
# 设置每日自动备份
crontab -e
0 2 * * * /usr/local/bin/wp-vps-manager backup-all

# 或通过脚本设置
sudo ./wp-vps-manager.sh
# 选择 "12) 自动备份设置"
```

#### 恢复功能
- **选择性恢复**: 可选择恢复文件或数据库
- **时间点恢复**: 恢复到特定时间点
- **安全恢复**: 恢复前自动创建当前状态备份

### 6. 跨服务器迁移

#### 迁移功能
- **完整站点迁移**: 将站点迁移到另一台服务器
- **域名迁移**: 更改站点域名
- **批量迁移**: 同时迁移多个站点

#### 导出站点到远程服务器
```bash
sudo ./wp-vps-manager.sh
# 选择 "14) 跨服务器迁移" -> "迁移站点到远程服务器"
```

#### 从远程服务器导入站点
```bash
sudo ./wp-vps-manager.sh
# 选择 "14) 跨服务器迁移" -> "从远程服务器导入站点"
```

#### 域名迁移

更改现有站点的域名：

```bash
sudo ./wp-vps-manager.sh
# 选择 "13) 手动备份/恢复" -> "4) 域名迁移"
```

步骤：
1. 选择要迁移的站点
2. 输入新域名
3. 自动更新数据库
4. 重新配置Nginx
5. 获取新SSL证书

#### 迁移步骤
1. **源服务器备份**: 创建完整备份
2. **文件传输**: 安全传输备份文件
3. **目标服务器部署**: 在目标服务器恢复站点
4. **DNS更新**: 更新DNS记录
5. **验证测试**: 确保迁移成功

### 7. 现有站点导入

导入服务器上已存在的WordPress站点：

```bash
sudo ./wp-vps-manager.sh --import
```

或者：
```bash
sudo ./wp-vps-manager.sh
# 选择 "2) 导入现有WordPress站点"
```

### 8. 系统优化

#### 性能优化
```bash
sudo ./wp-vps-manager.sh
# 选择 "15) 服务器优化"
```

优化项目：
- Nginx配置更新
- MariaDB性能调优
- PHP配置优化
- 缓存配置优化

#### 自动优化
- **Nginx配置优化**: 高性能Nginx配置
- **PHP配置调优**: 根据服务器资源优化PHP设置
- **MariaDB优化**: 智能MariaDB配置优化
- **缓存配置**: 多层缓存配置优化

#### 安全加固
```bash
sudo ./wp-vps-manager.sh
# 选择 "17) 防火墙设置"
```

安全功能：
- UFW防火墙配置
- Fail2ban设置
- SSL证书管理
- 安全扫描

#### 安全加固
- **防火墙配置**: UFW防火墙规则配置
- **Fail2ban设置**: 防护暴力攻击
- **SSL配置**: 强化SSL/TLS配置
- **文件权限**: 安全的文件权限设置

## 配置文件和目录结构

### 站点配置文件
位置: `~/.vps-manager/wordpress-sites.conf`

包含所有站点的配置信息：
- 站点数量
- 域名列表
- PHP版本配置
- 管理员信息
- WooCommerce状态

### 凭据文件
每个站点的登录凭据保存在：
`/root/wordpress-credentials-DOMAIN.txt`

包含内容：
- WordPress管理员用户名和密码
- 数据库名称和凭据
- Redis密码
- 其他重要信息

### 站点目录结构
```
/var/www/DOMAIN/
├── public/          # WordPress文件
├── cache/
│   └── fastcgi/     # FastCGI缓存
├── logs/
│   ├── nginx-access.log
│   └── nginx-error.log
└── backups/         # 站点备份
```

### 配置文件位置
```
/etc/nginx/sites-available/DOMAIN    # Nginx配置
/etc/letsencrypt/live/DOMAIN/        # SSL证书
/usr/local/bin/manage-DOMAIN         # 站点管理脚本
```

### 日志文件
- **部署日志**: `/var/log/wp-deploy-YYYYMMDD-HHMMSS.log`
- **访问日志**: `/var/www/DOMAIN/logs/nginx-access.log`
- **错误日志**: `/var/www/DOMAIN/logs/nginx-error.log`

### 备份目录
- **站点备份**: `/var/www/DOMAIN/backups/`
- **全局备份**: `~/.vps-manager/backups/`

## 故障排除

### 常见问题

#### 1. 权限问题
```bash
# 确保使用sudo运行
sudo ./wp-vps-manager.sh

# 检查文件权限
ls -la wp-vps-manager.sh
```

#### 2. 脚本语法错误
```bash
# 检查语法
bash -n wp-vps-manager.sh
```

#### 3. 域名解析问题
```bash
# 检查DNS解析
nslookup your-domain.com

# 检查域名指向
dig your-domain.com
```

#### 4. SSL证书获取失败
```bash
# 检查域名DNS解析
nslookup your-domain.com

# 手动获取证书
certbot certonly --webroot -d your-domain.com --webroot-path /var/www/your-domain.com/public

# 检查证书状态
sudo certbot certificates
```

#### 5. PHP-FPM服务异常
```bash
# 检查PHP-FPM状态
systemctl status php8.3-fpm

# 重启PHP-FPM
systemctl restart php8.3-fpm

# 查看错误日志
tail -f /var/log/php8.3-fpm.log
```

#### 6. 数据库连接问题
```bash
# 检查MariaDB状态
systemctl status mariadb

# 测试数据库连接
mariadb -u username -p database_name

# 重置数据库密码
mariadb -e "ALTER USER 'username'@'localhost' IDENTIFIED BY 'new_password';"
```

#### 7. 缓存问题
```bash
# 清除所有缓存
manage-your-domain.com cache-clear

# 检查FastCGI缓存状态
manage-your-domain.com fastcgi-status

# 手动清除FastCGI缓存
rm -rf /var/www/your-domain.com/cache/fastcgi/*
```

#### 8. 服务异常
```bash
# 检查服务状态
systemctl status nginx php8.3-fpm mariadb redis-server

# 重启服务
sudo systemctl restart nginx php8.3-fpm mariadb redis-server
```

### 日志分析

#### 查看部署日志
```bash
tail -f /var/log/wp-deploy-*.log
```

#### 分析访问日志
```bash
# 查看访问统计
sudo ./wp-vps-manager.sh
# 选择 "9) 访问日志分析"
```

#### 检查错误日志
```bash
tail -f /var/www/your-domain.com/logs/nginx-error.log
```

#### 系统日志
```bash
journalctl -f -u nginx
journalctl -f -u php8.3-fpm
journalctl -f -u mariadb
```

## 性能优化建议

### 服务器级优化
1. **使用SSD存储**: 提高I/O性能
2. **充足内存**: 推荐4GB+内存
3. **CDN集成**: 使用CloudFlare等CDN服务
4. **定期更新**: 保持系统和软件更新

### 应用级优化
1. **缓存插件**: 使用Redis Object Cache插件
2. **图片优化**: 压缩和优化图片
3. **数据库优化**: 定期清理数据库
4. **插件管理**: 移除不必要的插件

### 监控建议
1. **设置监控**: 使用Uptime Robot等监控服务
2. **日志轮转**: 配置日志自动轮转
3. **磁盘监控**: 监控磁盘使用情况
4. **性能测试**: 定期进行性能测试

## 安全最佳实践

### 服务器安全
1. **定期更新**: 保持系统和软件更新
2. **强密码**: 使用强密码和SSH密钥
3. **防火墙**: 正确配置UFW防火墙
4. **Fail2ban**: 启用Fail2ban防护

### WordPress安全
1. **定期备份**: 设置自动备份
2. **插件更新**: 及时更新插件和主题
3. **用户权限**: 合理分配用户权限
4. **安全插件**: 使用Wordfence等安全插件

### SSL/TLS配置
1. **强制HTTPS**: 所有站点强制使用HTTPS
2. **HSTS**: 启用HTTP严格传输安全
3. **证书监控**: 监控SSL证书到期时间
4. **安全头**: 配置安全HTTP头

## 更新和维护

### 脚本更新
```bash
# 下载最新版本
wget https://your-domain.com/vps-manager-wordpress.sh -O vps-manager-wordpress-new.sh

# 备份当前版本
cp vps-manager-wordpress.sh vps-manager-wordpress-backup.sh

# 替换新版本
mv vps-manager-wordpress-new.sh vps-manager-wordpress.sh
chmod +x vps-manager-wordpress.sh
```

### 系统维护
```bash
# 系统更新
sudo apt update && sudo apt upgrade -y

# 清理系统
sudo ./wp-vps-manager.sh
# 选择 "15) 服务器优化" -> "5) 清理系统垃圾文件"

# 检查磁盘空间
df -h

# 检查服务状态
systemctl status nginx php8.3-fpm mariadb redis-server
```

### 维护计划

#### 日常维护
- 检查服务状态
- 查看错误日志
- 监控磁盘空间

#### 周期维护
- 更新系统和软件
- 清理日志文件
- 检查备份完整性

#### 月度维护
- 性能分析和优化
- 安全扫描和加固
- 备份策略评估

## 技术支持

### 获取帮助

如果遇到问题，请按以下顺序排查：

1. **查看文档**
   - README.md（本文档）
   - 内置帮助：`sudo ./wp-vps-manager.sh --help`

2. **检查日志**
   - 部署日志：`tail -f /var/log/wp-deploy-*.log`
   - 错误日志：`tail -f /var/www/DOMAIN/logs/nginx-error.log`
   - 系统日志：`journalctl -f -u nginx`

3. **运行诊断**
   ```bash
   # 语法检查
   bash -n wp-vps-manager.sh
   
   # 检查服务状态
   systemctl status nginx php8.3-fpm mariadb redis-server
   ```

4. **社区支持**
   - 查看GitHub Issues
   - 提交问题报告
   - 参与社区讨论

### 报告问题
在报告问题时，请提供：
1. Ubuntu版本信息：`lsb_release -a`
2. 错误日志内容
3. 操作步骤描述
4. 系统配置信息

### 贡献代码
欢迎提交Pull Request和Issue：
1. Fork项目仓库
2. 创建功能分支
3. 提交代码更改
4. 创建Pull Request

## 版本历史

### v7.0 (当前版本)
- 脚本重命名为 wp-vps-manager
- 替换MySQL为MariaDB 10.11
- 新增跨服务器迁移功能
- 改进PHP版本管理
- 增强监控和日志分析
- 优化备份和恢复功能
- 修复已知问题

### v6.1
- 新增跨服务器迁移功能
- 改进PHP版本管理
- 增强监控和日志分析
- 优化备份和恢复功能
- 修复已知问题

### v6.0
- 重构代码架构
- 新增实时监控功能
- 改进用户界面
- 增强安全特性

### v5.x
- 多PHP版本支持
- 自动站点检测
- 性能优化改进

## 许可证

本项目采用MIT许可证，详见LICENSE文件。

## 免责声明

本脚本仅供学习和测试使用。在生产环境中使用前，请充分测试并备份重要数据。作者不对使用本脚本造成的任何损失承担责任。

---

**注意**: 本脚本会修改系统配置，建议在测试环境中先行验证。使用前请确保已备份重要数据。