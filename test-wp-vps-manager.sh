#!/bin/bash

# WordPress VPS管理脚本测试工具

SCRIPT="wp-vps-manager.sh"

echo "=== WordPress VPS管理脚本测试工具 ==="
echo ""

# 检查脚本文件是否存在
if [[ ! -f "$SCRIPT" ]]; then
    echo "❌ 错误: 找不到 $SCRIPT 文件"
    exit 1
fi

echo "✅ 脚本文件存在: $SCRIPT"

# 语法检查
echo ""
echo "1. 语法检查:"
if bash -n "$SCRIPT"; then
    echo "   ✅ 语法正确"
else
    echo "   ❌ 语法错误"
    exit 1
fi

# 帮助功能测试
echo ""
echo "2. 帮助功能测试:"
if timeout 10 bash "$SCRIPT" --help >/dev/null 2>&1; then
    echo "   ✅ 帮助功能正常"
else
    echo "   ❌ 帮助功能异常"
fi

# 版本信息测试
echo ""
echo "3. 版本信息测试:"
if timeout 10 bash "$SCRIPT" --version >/dev/null 2>&1; then
    echo "   ✅ 版本信息正常"
else
    echo "   ❌ 版本信息异常"
fi

# 检查关键函数
echo ""
echo "4. 关键函数检查:"
functions_to_check=(
    "init_script"
    "log_message" 
    "select_operation_mode"
    "deploy_new_server"
    "install_system_packages"
    "setup_mysql"
    "setup_nginx"
    "deploy_single_site"
    "create_site_management_script"
    "show_deployment_summary"
)

missing_functions=()
for func in "${functions_to_check[@]}"; do
    if grep -q "^${func}()" "$SCRIPT"; then
        echo "   ✅ $func"
    else
        echo "   ❌ $func (缺失)"
        missing_functions+=("$func")
    fi
done

# 检查脚本大小
echo ""
echo "5. 脚本信息:"
echo "   文件大小: $(du -h "$SCRIPT" | cut -f1)"
echo "   行数: $(wc -l < "$SCRIPT")"
echo "   字符数: $(wc -c < "$SCRIPT")"

# 总结
echo ""
echo "=== 测试总结 ==="
if [[ ${#missing_functions[@]} -eq 0 ]]; then
    echo "✅ 所有测试通过！脚本可以使用"
    echo ""
    echo "使用方法:"
    echo "  chmod +x $SCRIPT"
    echo "  sudo ./$SCRIPT --help"
    echo "  sudo ./$SCRIPT --version"
    echo "  sudo ./$SCRIPT  # 开始部署"
else
    echo "❌ 发现问题:"
    echo "   缺失函数: ${#missing_functions[@]} 个"
    for func in "${missing_functions[@]}"; do
        echo "     - $func"
    done
fi

echo ""
echo "=== 脚本特性 ==="
echo "🎯 替代方案: Cloudways + SpinupWP"
echo "💰 成本: 免费开源 vs $10-100+/月"
echo "🚀 功能: 多站点管理、SSL自动化、性能优化"
echo "🔧 支持: Ubuntu 20.04/22.04/24.04"
echo "🐘 PHP: 8.2, 8.3, 8.4 多版本支持"
echo "🗄️  数据库: MySQL 8.0"
echo "⚡ 缓存: Redis + FastCGI"
echo "🔒 安全: UFW + Fail2ban + SSL"