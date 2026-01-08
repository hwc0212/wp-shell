# WordPress VPS管理平台 (Cloudways/SpinupWP替代方案)

**wp-shell** 是一个功能强大的WordPress VPS管理脚本，专门设计用来替代Cloudways和SpinupWP等付费服务。支持在单个Ubuntu服务器上部署和管理多个WordPress站点，每个站点可以使用不同的PHP版本。

**GitHub仓库**: https://github.com/hwc0212/wp-shell  
**最新版本**: v7.0 | **更新日期**: 2026-01-08  
**作者**: [huwencai.com](https://huwencai.com)

## 🔗 快速链接

- **多站点管理脚本**: [wp-vps-manager.sh](https://github.com/hwc0212/wp-shell/blob/main/wp-vps-manager.sh)
- **单站点极致性能脚本**: [deploy-single-wordpress.sh](https://github.com/hwc0212/wp-shell/blob/main/deploy-single-wordpress.sh)
- **功能对比**: [查看下方对比表](#-替代方案对比)
- **VPS配置要求**: [查看系统要求](#-系统要求)

## 🎯 替代方案对比

| 功能特性 | Cloudways | SpinupWP | wp-vps-manager |
|---------|-----------|----------|----------------|
| 月费成本 | $10-100+ | $12-50+ | **免费开源** |
| 多站点管理 | ✓ | ✓ | ✓ |
| 多PHP版本 | ✓ | ✓ | ✓ (8.2/8.3/8.4) |
| SSL自动化 | ✓ | ✓ | ✓ |
| 性能优化 | ✓ | ✓ | ✓ |
| 备份管理 | ✓ | ✓ | ✓ |
| 监控分析 | ✓ | ✓ | ✓ |
| 完全控制 | ❌ | ❌ | ✓ |
| 自定义配置 | 有限 | 有限 | ✓ |

## 🚀 核心功能

### 智能VPS配置检查
- **自动检测VPS配置**：内存、CPU、存储空间
- **智能站点数量限制**：根据VPS配置动态调整最大站点数
- **配置等级评估**：从超小VPS到高配置的5个等级
- **优化策略匹配**：为每个配置等级提供专门的优化方案

### 多站点管理
- 单服务器部署1-10个WordPress站点
- 每个站点独立PHP版本 (8.2/8.3/8.4)
- 智能站点检测和导入
- 统一管理界面

### 单站点极致性能版
- **VPS所有资源专用**于单个WordPress站点
- **智能配置优化**：根据VPS配置自动调整参数
- **小VPS专用优化**：为512MB-1GB内存的VPS提供极限优化
- **MariaDB动态分配**：高配置使用70%内存，小VPS使用40-50%内存
- **PHP-FPM智能调整**：根据VPS配置动态调整进程数和内存限制
- **三重缓存**：FastCGI + Redis + OPcache
- **PHP JIT编译器**（PHP 8.3/8.4）
- **WooCommerce智能警告**：小VPS自动警告WooCommerce风险

### 性能优化
- **FastCGI缓存**: 每个站点独立缓存
- **Redis缓存**: 共享对象缓存
- **PHP OPcache**: 自动优化配置
- **MariaDB调优**: 动态内存分配
- **Nginx优化**: 高性能配置

### 安全防护
- **SSL自动化**: Let's Encrypt证书自动获取和续期
- **防火墙管理**: UFW防火墙配置
- **Fail2ban集成**: 自动防护暴力攻击
- **安全扫描**: 内置安全检查工具

### 监控和备份
- **实时监控**: 系统资源和站点状态
- **访问日志分析**: 详细统计和热门页面
- **自动备份**: 支持定时备份设置
- **完整恢复**: 快速恢复到任意备份点

## 📋 系统要求

### 基本要求
- **操作系统**: Ubuntu 20.04/22.04/24.04 LTS
- **网络**: 稳定的互联网连接

### VPS配置要求

#### 多站点管理版 (wp-vps-manager.sh)
| 配置等级 | 内存 | CPU | 存储 | 最大站点数 | 推荐站点数 |
|----------|------|-----|------|------------|------------|
| 高配置   | 8GB+ | 4核+ | 40GB+ | 10个 | 8个 |
| 中等配置 | 4GB+ | 2核+ | 30GB+ | 6个  | 4个 |
| 标准配置 | 2GB+ | 2核+ | 25GB+ | 3个  | 2个 |
| 基础配置 | 1GB+ | 1核+ | 20GB+ | 2个  | 1个 |
| 最低要求 | 512MB | 1核 | 10GB | 1个  | 1个 |

#### 单站点极致性能版 (deploy-single-wordpress.sh)
| 配置等级 | 内存 | CPU | 存储 | 优化策略 | WooCommerce支持 |
|----------|------|-----|------|----------|-----------------|
| 高配置   | 4GB+ | 2核+ | 20GB+ | 标准优化 | ✓ 完全支持 |
| 中等配置 | 2GB+ | 2核+ | 15GB+ | 积极优化 | ✓ 支持 |
| 标准配置 | 1GB+ | 1核+ | 10GB+ | 激进优化 | ⚠ 谨慎使用 |
| 小VPS    | 512MB+ | 1核+ | 8GB+ | 极限优化 | ❌ 不推荐 |
| 超小VPS  | 256MB+ | 1核+ | 5GB+ | 生存模式 | ❌ 强烈不推荐 |

**自动安装软件**:
- Nginx (最新稳定版)
- MariaDB 10.11
- PHP 8.2/8.3/8.4 (根据需要)
- Redis, Certbot, Fail2ban, UFW防火墙

## 🚀 一键部署

### 多站点管理版本
```bash
wget https://raw.githubusercontent.com/hwc0212/wp-shell/main/wp-vps-manager.sh
chmod +x wp-vps-manager.sh
sudo ./wp-vps-manager.sh
```

### 单站点极致性能版本
```bash
wget https://raw.githubusercontent.com/hwc0212/wp-shell/main/deploy-single-wordpress.sh
chmod +x deploy-single-wordpress.sh
sudo ./deploy-single-wordpress.sh
```

## 🎯 脚本选择指南

### 选择多站点版本的情况：
- 需要管理多个WordPress站点
- 代理商或多站点用户
- 需要统一的管理界面
- 替代Cloudways/SpinupWP服务

### 选择单站点版本的情况：
- 只有一个WordPress站点
- 追求极致性能和速度
- 高流量网站或电商站点
- VPS资源充足，希望全部用于单站点
- 小VPS需要极限优化 (512MB-1GB内存)

## 📖 部署后管理

### 多站点管理命令
```bash
wp-vps-manager list        # 列出所有站点
wp-vps-manager status      # 检查所有站点状态  
wp-vps-manager backup-all  # 备份所有站点
```

### 单站点管理命令
```bash
manage-DOMAIN status       # 检查站点状态和性能
manage-DOMAIN cache-clear  # 清除所有缓存
manage-DOMAIN backup       # 创建站点备份
manage-DOMAIN optimize     # 执行性能优化
manage-DOMAIN monitor      # 实时监控
```

## 🛠️ 常见问题

### Q: 我的VPS配置很低，能用吗？
A: 可以！脚本会自动检测VPS配置：
- **512MB-1GB**: 建议使用单站点版本，启用极限优化
- **2GB+**: 可以使用多站点版本，支持2-3个站点
- **4GB+**: 完全支持多站点部署

### Q: 如何选择PHP版本？
A: 脚本支持PHP 8.2/8.3/8.4：
- **PHP 8.4**: 最新版本，性能最佳，推荐新项目
- **PHP 8.3**: 稳定版本，支持JIT编译器
- **PHP 8.2**: 兼容性最好，适合老项目

### Q: WooCommerce对VPS有什么要求？
A: WooCommerce需要更多资源：
- **最低**: 1GB内存
- **推荐**: 2GB+内存
- **小VPS**: 脚本会自动警告并提供优化建议

### Q: 部署失败怎么办？
A: 脚本有完整的错误处理：
- 检查日志文件：`/var/log/wp-deploy-*.log`
- 重新运行脚本会自动跳过已完成的步骤
- 联系支持或查看GitHub Issues

## 🎛️ 管理功能

### VPS管理控制面板
运行脚本后可访问完整的管理界面：

**📱 应用管理**:
- 部署新的WordPress应用
- 导入现有WordPress站点
- 克隆现有应用

**⚙️ 应用操作**:
- 管理应用设置
- 升级PHP版本
- SSL证书管理
- 域名管理

**📊 监控和分析**:
- 实时监控面板
- 访问日志分析
- 性能分析报告
- 安全扫描

**💾 备份和迁移**:
- 自动备份设置
- 手动备份/恢复
- 跨服务器迁移

**🔧 服务器管理**:
- 服务器优化
- 软件包管理
- 防火墙设置
- 系统更新

## 📁 重要文件位置

### 多站点管理版
```
/root/wordpress-credentials-DOMAIN.txt    # 站点登录凭据
/root/wp-vps-deployment-summary.txt       # 部署摘要
~/.vps-manager/wordpress-sites.conf       # 站点配置
/var/log/wp-deploy-*.log                  # 部署日志
/var/www/DOMAIN/                          # 站点目录
├── public/                               # WordPress文件
├── cache/fastcgi/                        # FastCGI缓存
├── logs/                                 # 站点日志
└── backups/                              # 站点备份
```

### 单站点极致性能版
```
/root/wordpress-single-credentials-DOMAIN.txt  # 站点凭据
/var/log/wp-single-deploy-*.log                # 部署日志
/var/www/DOMAIN/                               # 站点目录
├── public/                                    # WordPress文件
├── cache/fastcgi/                             # FastCGI缓存（极致优化）
├── logs/                                      # 站点日志
└── backups/                                   # 站点备份
/usr/local/bin/manage-DOMAIN                   # 极致性能管理脚本
```

## 🔧 性能优化详情

### 小VPS专用优化 (deploy-single-wordpress.sh)

#### 系统级优化
- **内核参数调整**: 小VPS降低网络缓冲区大小 (65536→8192)
- **文件句柄限制**: 小VPS从100万降低到10万
- **服务禁用**: 禁用更多不必要的系统服务
- **Swap配置**: 小VPS自动配置swap缓解内存压力

#### 数据库优化 (MariaDB)
- **内存分配**: 高配置70%，小VPS50%，超小VPS40%
- **连接数**: 标准500，小VPS100，超小VPS50
- **缓冲区优化**: 小VPS大幅降低各种缓冲区大小

#### PHP优化
- **内存限制**: 标准512M，小VPS256M，超小VPS128M
- **进程池配置**: 根据VPS配置动态调整进程数和内存
- **OPcache优化**: 标准1/4内存，小VPS1/6内存，超小VPS1/8内存

#### Redis优化
- **内存分配**: 标准15%，小VPS10%，超小VPS8%
- **连接限制**: 标准10000，小VPS1000，超小VPS500

#### WooCommerce智能警告
- **超小VPS**: 强烈不建议安装，需要用户强制确认
- **小VPS**: 给出详细使用建议和限制说明
- **标准配置以上**: 正常支持，提供优化建议

## 🔧 故障排除

### 常见问题解决

**权限问题**:
```bash
sudo ./wp-vps-manager.sh  # 确保使用sudo运行
```

**语法检查**:
```bash
bash -n wp-vps-manager.sh  # 检查脚本语法
```

**SSL证书获取失败**:
```bash
# 检查域名DNS解析
nslookup your-domain.com

# 手动获取证书
certbot certonly --webroot -d your-domain.com --webroot-path /var/www/your-domain.com/public
```

**服务异常**:
```bash
# 检查服务状态
systemctl status nginx php8.3-fpm mariadb redis-server

# 重启服务
systemctl restart nginx php8.3-fpm mariadb redis-server
```

**缓存问题**:
```bash
# 清除所有缓存
manage-your-domain.com cache-clear

# 手动清除FastCGI缓存
rm -rf /var/www/your-domain.com/cache/fastcgi/*
```

### 日志分析
```bash
# 查看部署日志
tail -f /var/log/wp-deploy-*.log

# 查看访问日志
tail -f /var/www/your-domain.com/logs/nginx-access.log

# 查看错误日志
tail -f /var/www/your-domain.com/logs/nginx-error.log
```

## 📈 更新日志

### v7.0 (2026-01-08) - 当前版本
- ✅ **重大更新**: 脚本重命名为 wp-vps-manager
- ✅ **智能VPS配置检查**: 自动检测VPS配置并限制站点数量
- ✅ **小VPS专用优化**: 为512MB-1GB内存VPS提供极限优化
- ✅ **新增功能**: 单站点极致性能版本 (deploy-single-wordpress.sh)
- ✅ **数据库升级**: 替换MySQL为MariaDB 10.11，动态内存分配
- ✅ **功能整合**: 整合多个脚本的优秀特性
- ✅ **错误修复**: 改进WordPress安装流程，增加错误处理
- ✅ **凭据管理**: 完善凭据保存功能，包含管理员密码
- ✅ **SSL优化**: 优化SSL证书获取流程
- ✅ **WooCommerce智能警告**: 小VPS自动警告WooCommerce风险
- ✅ **测试完善**: 通过完整的语法检查和功能测试

### 单站点极致性能版特性 (v1.0)
- 🚀 **VPS资源专用**: 所有系统资源专用于单个WordPress站点
- 🚀 **动态资源分配**: MariaDB使用70%内存，Redis使用15%内存
- 🚀 **三重缓存**: FastCGI + Redis + OPcache
- 🚀 **PHP JIT**: PHP 8.3/8.4 JIT编译器支持
- 🚀 **WooCommerce优化**: 电商专用性能优化
- 🚀 **实时监控**: 内置性能监控功能

### v6.1
- 新增跨服务器迁移功能
- 改进PHP版本管理
- 增强监控和日志分析
- 优化备份和恢复功能

### v6.0
- 重构代码架构
- 新增实时监控功能
- 改进用户界面
- 增强安全特性

### v5.x
- 多PHP版本支持
- 自动站点检测
- 性能优化改进

## 📞 技术支持

### 获取帮助
1. **查看文档**: 内置帮助 `sudo ./wp-vps-manager.sh --help`
2. **检查日志**: 部署日志 `/var/log/wp-deploy-*.log`
3. **运行诊断**: 语法检查 `bash -n wp-vps-manager.sh`
4. **GitHub支持**: [Issues](https://github.com/hwc0212/wp-shell/issues) 和 [Discussions](https://github.com/hwc0212/wp-shell/discussions)

### 报告问题
提供以下信息：
- Ubuntu版本: `lsb_release -a`
- 错误日志内容
- 操作步骤描述
- 在 [GitHub Issues](https://github.com/hwc0212/wp-shell/issues) 中提交

## 📄 许可证

本项目采用MIT许可证。

## ⚠️ 免责声明

本脚本仅供学习和测试使用。在生产环境中使用前，请充分测试并备份重要数据。作者不对使用本脚本造成的任何损失承担责任。

---

**作者**: [huwencai.com](https://huwencai.com)  
**GitHub**: https://github.com/hwc0212/wp-shell  
**注意**: 本脚本会修改系统配置，建议在测试环境中先行验证。使用前请确保已备份重要数据。