# WordPress VPS管理平台 (Cloudways/SpinupWP替代方案)

**wp-vps-manager** 是一个功能强大的WordPress VPS管理脚本，专门设计用来替代Cloudways和SpinupWP等付费服务。支持在单个Ubuntu服务器上部署和管理多个WordPress站点，每个站点可以使用不同的PHP版本。

**最新版本**: v7.0 | **更新日期**: 2026-01-08

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

### 多站点管理
- 单服务器部署1-10个WordPress站点
- 每个站点独立PHP版本 (8.2/8.3/8.4)
- 智能站点检测和导入
- 统一管理界面

### 单站点极致性能版
- **VPS所有资源专用**于单个WordPress站点
- **MariaDB使用70%内存**，Redis使用15%内存
- **PHP-FPM动态进程池**，根据服务器资源自动调整
- **三重缓存**：FastCGI + Redis + OPcache
- **PHP JIT编译器**（PHP 8.3/8.4）
- **WooCommerce电商专用优化**

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

- **操作系统**: Ubuntu 20.04/22.04/24.04 LTS
- **硬件要求**: 最小2GB RAM, 20GB存储 | 推荐4GB+ RAM, 40GB+ SSD
- **网络**: 稳定的互联网连接

**自动安装软件**:
- Nginx (最新稳定版)
- MariaDB 10.11
- PHP 8.2/8.3/8.4 (根据需要)
- Redis, Certbot, Fail2ban, UFW防火墙

## 🚀 快速开始

### 1. 下载脚本
```bash
# 多站点管理版本
wget https://raw.githubusercontent.com/your-repo/wp-vps-manager/main/wp-vps-manager.sh
chmod +x wp-vps-manager.sh

# 单站点极致性能版本
wget https://raw.githubusercontent.com/your-repo/wp-vps-manager/main/deploy-single-wordpress.sh
chmod +x deploy-single-wordpress.sh
```

### 2. 选择部署方式

#### 多站点管理部署
适合需要管理多个WordPress站点的用户：
```bash
sudo ./wp-vps-manager.sh
```

#### 单站点极致性能部署
适合只需要一个WordPress站点，追求极致性能的用户：
```bash
sudo ./deploy-single-wordpress.sh
```

### 3. 部署流程

**多站点版本**：
1. 系统检查和初始化
2. 收集站点信息（1-10个站点）
3. 自动安装所有必需软件
4. 批量部署所有站点

**单站点极致性能版本**：
1. 系统检查和极致性能优化
2. 收集单站点信息
3. VPS所有资源专用配置
4. 极致性能WordPress部署

### 4. 部署完成后管理

**多站点管理命令**:
```bash
wp-vps-manager list        # 列出所有站点
wp-vps-manager status      # 检查所有站点状态  
wp-vps-manager backup-all  # 备份所有站点
```

**单站点管理命令**:
```bash
manage-DOMAIN status       # 检查站点状态和性能信息
manage-DOMAIN cache-clear  # 清除所有缓存（FastCGI+Redis+OPcache）
manage-DOMAIN backup       # 创建站点备份
manage-DOMAIN optimize     # 执行性能优化
manage-DOMAIN monitor      # 实时监控
```

## 📖 脚本选择指南

### wp-vps-manager.sh - 多站点管理版
**适用场景**：
- 需要管理多个WordPress站点（1-10个）
- 每个站点使用不同PHP版本
- 需要统一的管理界面
- 替代Cloudways/SpinupWP等服务

**特点**：
- 支持多站点部署和管理
- 每个站点独立配置
- 完整的VPS管理功能
- 适合代理商和多站点用户

### deploy-single-wordpress.sh - 单站点极致性能版
**适用场景**：
- 只需要部署一个WordPress站点
- 追求极致性能和速度
- VPS所有资源专用于单个站点
- 高流量网站或电商站点

**特点**：
- VPS所有资源专用于单个站点
- MariaDB使用70%内存，Redis使用15%内存
- PHP-FPM动态进程池优化
- 三重缓存：FastCGI + Redis + OPcache
- PHP JIT编译器（PHP 8.3/8.4）
- WooCommerce电商专用优化

## 📖 命令行选项

### 多站点管理版
```bash
sudo ./wp-vps-manager.sh [选项]

选项:
  无参数          交互式部署/管理模式
  -l, --list      列出所有已配置的站点
  -i, --import    检测并导入现有WordPress站点
  -h, --help      显示帮助信息
  -v, --version   显示版本信息
```

### 单站点极致性能版
```bash
sudo ./deploy-single-wordpress.sh

功能:
  - 自动检测系统资源并优化配置
  - VPS所有资源专用于单个WordPress站点
  - 极致性能优化配置
  - 支持WooCommerce电商优化
```

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
- ✅ **新增功能**: 单站点极致性能版本 (deploy-single-wordpress.sh)
- ✅ **数据库升级**: 替换MySQL为MariaDB 10.11，动态内存分配
- ✅ **功能整合**: 整合多个脚本的优秀特性
- ✅ **错误修复**: 改进WordPress安装流程，增加错误处理
- ✅ **凭据管理**: 完善凭据保存功能，包含管理员密码
- ✅ **SSL优化**: 优化SSL证书获取流程
- ✅ **极致性能**: VPS所有资源专用于单站点，实现极致性能
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
4. **社区支持**: GitHub Issues 和讨论

### 报告问题
提供以下信息：
- Ubuntu版本: `lsb_release -a`
- 错误日志内容
- 操作步骤描述

## 📄 许可证

本项目采用MIT许可证。

## ⚠️ 免责声明

本脚本仅供学习和测试使用。在生产环境中使用前，请充分测试并备份重要数据。作者不对使用本脚本造成的任何损失承担责任。

---

**注意**: 本脚本会修改系统配置，建议在测试环境中先行验证。使用前请确保已备份重要数据。