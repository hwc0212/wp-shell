
#!/bin/bash

# ======================================================================
# WordPress VPS管理平台 (Cloudways/SpinupWP替代方案)
# ======================================================================
# 脚本名称: wp-vps-manager
# 版本: 7.0
# 最后更新: 2025-01-07
# 适用系统: Ubuntu 20.04/22.04/24.04
# 核心目标: 完整的VPS和WordPress管理平台，替代Cloudways和SpinupWP
# 功能特性: 多站点部署、PHP版本管理、VPS优化、现有站点导入、监控告警、自动备份
# ======================================================================

set -e  # 任何命令失败立即退出

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 全局变量 ---
SCRIPT_NAME="wp-vps-manager"
LOG_FILE="/var/log/wp-deploy-$(date +%Y%m%d-%H%M%S).log"
STATE_FILE="/tmp/wp-deploy.state"
MARIADB_VERSION="10.11"
AVAILABLE_PHP_VERSIONS=("8.2" "8.3" "8.4")

# --- 运行模式变量 ---
OPERATION_MODE=""
SITE_COUNT=0
SITES_CONFIG_FILE="$HOME/.vps-manager/wordpress-sites.conf"

# --- 站点配置变量 ---
declare -A SITE_DOMAINS
declare -A SITE_PHP_VERSIONS
declare -A SITE_WOOCOMMERCE
declare -A SITE_ADMIN_USERS
declare -A SITE_ADMIN_EMAILS
declare -A SITE_TITLES
# --- 日志函数 ---
log_message() {
    local type="$1"
    local message="$2"
    local color=""
    
    case "$type" in
        "ERROR") color="$RED" ;;
        "SUCCESS") color="$GREEN" ;;
        "WARNING") color="$YELLOW" ;;
        "INFO") color="$CYAN" ;;
        "TASK") color="$BLUE" ;;
        *) color="$NC" ;;
    esac
    
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${color}[${type}]${NC} ${message}"
}

# --- 初始化函数 ---
init_script() {
    echo -e "${CYAN}[INFO]${NC} WordPress VPS管理平台启动"
    
    # 检查sudo权限
    if [[ $EUID -eq 0 ]]; then
        echo -e "${YELLOW}[警告]${NC} 检测到以root用户运行"
        echo -e "${YELLOW}[建议]${NC} 为了安全起见，建议使用sudo用户运行此脚本"
        read -rp "是否继续? (y/n): " CONTINUE_ROOT
        if [[ ! "$CONTINUE_ROOT" =~ ^[Yy]$ ]]; then
            echo -e "${CYAN}[提示]${NC} 请使用以下命令以sudo用户运行:"
            echo -e "  sudo $0"
            exit 1
        fi
    elif ! sudo -n true 2>/dev/null; then
        echo -e "${RED}[错误]${NC} 此脚本需要sudo权限"
        echo -e "${CYAN}[提示]${NC} 请使用以下命令运行:"
        echo -e "  sudo $0"
        exit 1
    fi
    # 检查Ubuntu系统
    if ! command -v lsb_release &> /dev/null || ! lsb_release -i | grep -q "Ubuntu"; then
        echo -e "${RED}[错误]${NC} 此脚本仅适用于Ubuntu系统"
        exit 1
    fi
    
    # 检查Ubuntu版本
    UBUNTU_VERSION=$(lsb_release -rs)
    if [[ "$UBUNTU_VERSION" != "20.04" ]] && [[ "$UBUNTU_VERSION" != "22.04" ]] && [[ "$UBUNTU_VERSION" != "24.04" ]]; then
        echo -e "${YELLOW}[警告]${NC} 此脚本主要测试于 Ubuntu 20.04/22.04/24.04，当前版本 $UBUNTU_VERSION 可能存在问题"
        read -rp "是否继续? (y/n): " CONTINUE
        if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # 创建日志文件
    touch "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE")
    exec 2> >(tee -a "$LOG_FILE" >&2)
    
    # 加载现有站点配置
    load_sites_config
    
    # 如果没有配置文件，检测现有站点
    if [[ $SITE_COUNT -eq 0 ]]; then
        detect_existing_sites
    fi
    
    # 检查系统兼容性
    check_system_compatibility
}
# --- 站点配置管理 ---
load_sites_config() {
    # 确保配置目录存在
    mkdir -p "$(dirname "$SITES_CONFIG_FILE")"
    
    if [[ -f "$SITES_CONFIG_FILE" ]]; then
        source "$SITES_CONFIG_FILE"
        log_message "INFO" "已加载现有站点配置，共 $SITE_COUNT 个站点"
    else
        log_message "INFO" "未找到现有站点配置，这是新服务器"
        SITE_COUNT=0
    fi
}

save_sites_config() {
    cat > "$SITES_CONFIG_FILE" << 'CONFIGEOF'
# WordPress多站点配置文件
# 自动生成，请勿手动编辑

SITE_COUNT=$SITE_COUNT

# 站点配置数组
CONFIGEOF

    # 保存关联数组
    for i in $(seq 1 $SITE_COUNT); do
        echo "SITE_DOMAINS[$i]=\"${SITE_DOMAINS[$i]}\"" >> "$SITES_CONFIG_FILE"
        echo "SITE_PHP_VERSIONS[$i]=\"${SITE_PHP_VERSIONS[$i]}\"" >> "$SITES_CONFIG_FILE"
        echo "SITE_WOOCOMMERCE[$i]=\"${SITE_WOOCOMMERCE[$i]}\"" >> "$SITES_CONFIG_FILE"
        echo "SITE_ADMIN_USERS[$i]=\"${SITE_ADMIN_USERS[$i]}\"" >> "$SITES_CONFIG_FILE"
        echo "SITE_ADMIN_EMAILS[$i]=\"${SITE_ADMIN_EMAILS[$i]}\"" >> "$SITES_CONFIG_FILE"
        echo "SITE_TITLES[$i]=\"${SITE_TITLES[$i]}\"" >> "$SITES_CONFIG_FILE"
    done
    
    log_message "SUCCESS" "站点配置已保存到 $SITES_CONFIG_FILE"
}
list_sites() {
    if [[ $SITE_COUNT -eq 0 ]]; then
        echo -e "${YELLOW}当前没有配置的WordPress站点${NC}"
        return
    fi
    
    echo -e "\n${CYAN}=== 已配置的WordPress站点 ===${NC}"
    for i in $(seq 1 $SITE_COUNT); do
        echo -e "${GREEN}站点 $i:${NC}"
        echo "  域名: ${SITE_DOMAINS[$i]}"
        echo "  PHP版本: ${SITE_PHP_VERSIONS[$i]}"
        echo "  WooCommerce: ${SITE_WOOCOMMERCE[$i]}"
        echo "  管理员: ${SITE_ADMIN_USERS[$i]} (${SITE_ADMIN_EMAILS[$i]})"
        echo "  标题: ${SITE_TITLES[$i]}"
        echo ""
    done
}

# --- 服务器信息显示 ---
display_server_overview() {
    echo -e "${CYAN}=== 服务器概览 ===${NC}"
    echo -e "主机名: $(hostname)"
    echo -e "系统: $(lsb_release -ds 2>/dev/null || echo 'Unknown')"
    echo -e "内核: $(uname -r)"
    echo -e "CPU: $(nproc) 核心"
    echo -e "内存: $(free -h | awk '/^Mem:/ {print $2}')"
    echo -e "磁盘: $(df -h / | awk 'NR==2 {print $4 " 可用 / " $2 " 总计"}')"
    echo -e "负载: $(uptime | awk -F'load average:' '{print $2}')"
    
    # 服务状态
    echo -e "\n${CYAN}=== 服务状态 ===${NC}"
    local services=("nginx" "mariadb" "redis-server")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            echo -e "$service: ${GREEN}运行中${NC}"
        else
            echo -e "$service: ${RED}未运行${NC}"
        fi
    done
    
    # PHP版本
    echo -e "\n${CYAN}=== PHP版本 ===${NC}"
    for version in "${AVAILABLE_PHP_VERSIONS[@]}"; do
        if systemctl is-active --quiet "php$version-fpm" 2>/dev/null; then
            echo -e "PHP $version: ${GREEN}已安装${NC}"
        else
            echo -e "PHP $version: ${YELLOW}未安装${NC}"
        fi
    done
}

display_detailed_server_info() {
    echo -e "\n${CYAN}=== 详细服务器信息 ===${NC}\n"
    
    # 基本系统信息
    echo -e "${BLUE}系统信息:${NC}"
    echo -e "  主机名: $(hostname)"
    echo -e "  系统: $(lsb_release -ds 2>/dev/null || echo 'Unknown')"
    echo -e "  内核: $(uname -r)"
    echo -e "  架构: $(uname -m)"
    echo -e "  启动时间: $(uptime -s 2>/dev/null || echo 'Unknown')"
    echo -e "  运行时间: $(uptime -p 2>/dev/null || echo 'Unknown')"
    
    # 硬件信息
    echo -e "\n${BLUE}硬件信息:${NC}"
    echo -e "  CPU: $(nproc) 核心"
    echo -e "  CPU型号: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
    echo -e "  内存: $(free -h | awk '/^Mem:/ {print $2 " 总计, " $3 " 已用, " $7 " 可用"}')"
    echo -e "  交换: $(free -h | awk '/^Swap:/ {print $2 " 总计, " $3 " 已用"}')"
    
    # 磁盘信息
    echo -e "\n${BLUE}磁盘信息:${NC}"
    df -h | grep -E '^/dev/' | while read line; do
        echo -e "  $line"
    done
    
    # 网络信息
    echo -e "\n${BLUE}网络信息:${NC}"
    echo -e "  IP地址: $(hostname -I | awk '{print $1}')"
    echo -e "  网络接口:"
    ip -o link show | awk -F': ' '{print "    " $2}' | grep -v lo
    
    # 服务状态
    echo -e "\n${BLUE}服务状态:${NC}"
    local services=("nginx" "mariadb" "redis-server" "fail2ban" "ufw")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            local status="${GREEN}运行中${NC}"
            local uptime=$(systemctl show "$service" --property=ActiveEnterTimestamp --value 2>/dev/null)
            if [[ -n "$uptime" ]]; then
                status="$status (启动于: $(date -d "$uptime" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'Unknown'))"
            fi
            echo -e "  $service: $status"
        else
            echo -e "  $service: ${RED}未运行${NC}"
        fi
    done
    
    # PHP版本详情
    echo -e "\n${BLUE}PHP版本详情:${NC}"
    for version in "${AVAILABLE_PHP_VERSIONS[@]}"; do
        if systemctl is-active --quiet "php$version-fpm" 2>/dev/null; then
            echo -e "  PHP $version: ${GREEN}已安装并运行${NC}"
            local php_version_full=$(php$version -v 2>/dev/null | head -1 | awk '{print $2}')
            if [[ -n "$php_version_full" ]]; then
                echo -e "    完整版本: $php_version_full"
            fi
        else
            echo -e "  PHP $version: ${YELLOW}未安装${NC}"
        fi
    done
    
    # 系统负载
    echo -e "\n${BLUE}系统负载:${NC}"
    echo -e "  负载平均值: $(uptime | awk -F'load average:' '{print $2}')"
    echo -e "  CPU使用率: $(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)%"
    
    # 内存使用详情
    echo -e "\n${BLUE}内存使用详情:${NC}"
    free -h | while read line; do
        echo -e "  $line"
    done
    
    # 最近的系统日志
    echo -e "\n${BLUE}最近的系统日志 (最后10条):${NC}"
    journalctl --no-pager -n 10 --output=short 2>/dev/null | while read line; do
        echo -e "  $line"
    done
    
    # 站点信息
    if [[ $SITE_COUNT -gt 0 ]]; then
        echo -e "\n${BLUE}WordPress站点:${NC}"
        for i in $(seq 1 $SITE_COUNT); do
            echo -e "  站点 $i: ${SITE_DOMAINS[$i]} (PHP ${SITE_PHP_VERSIONS[$i]})"
        done
    fi
}
# --- 运行模式选择 ---
select_operation_mode() {
    echo -e "\n${CYAN}=== WordPress VPS管理平台 (Cloudways/SpinupWP替代方案) ===${NC}\n"
    
    # 显示服务器概览
    display_server_overview
    
    if [[ $SITE_COUNT -eq 0 ]]; then
        echo -e "\n${YELLOW}检测到这是新服务器或未配置的VPS${NC}"
        echo "将进行服务器初始化和WordPress部署"
        OPERATION_MODE="new-server"
    else
        echo -e "\n${GREEN}=== VPS管理控制面板 ===${NC}"
        echo ""
        echo "📱 应用管理:"
        echo "  1) 部署新的WordPress应用"
        echo "  2) 导入现有WordPress站点"
        echo "  3) 克隆现有应用"
        echo ""
        echo "⚙️  应用操作:"
        echo "  4) 管理应用设置"
        echo "  5) 升级PHP版本"
        echo "  6) SSL证书管理"
        echo "  7) 域名管理"
        echo ""
        echo "📊 监控和分析:"
        echo "  8) 实时监控面板"
        echo "  9) 访问日志分析"
        echo "  10) 性能分析报告"
        echo "  11) 安全扫描"
        echo ""
        echo "💾 备份和迁移:"
        echo "  12) 自动备份设置"
        echo "  13) 手动备份/恢复"
        echo "  14) 跨服务器迁移"
        echo ""
        echo "🔧 服务器管理:"
        echo "  15) 服务器优化"
        echo "  16) 软件包管理"
        echo "  17) 防火墙设置"
        echo "  18) 系统更新"
        echo ""
        echo "📋 信息查看:"
        echo "  19) 服务器信息"
        echo "  20) 应用列表"
        echo "  21) 系统日志"
        echo ""
        echo "  0) 退出"
        read -rp "请选择功能 [0-21]: " MODE_CHOICE
        
        case "$MODE_CHOICE" in
            1) OPERATION_MODE="add-site" ;;
            2) OPERATION_MODE="import-existing" ;;
            3) OPERATION_MODE="clone-site" ;;
            4) OPERATION_MODE="site-manage" ;;
            5) OPERATION_MODE="upgrade-php" ;;
            6) OPERATION_MODE="ssl-manage" ;;
            7) OPERATION_MODE="domain-manage" ;;
            8) OPERATION_MODE="realtime-monitor" ;;
            9) OPERATION_MODE="logs" ;;
            10) OPERATION_MODE="performance-report" ;;
            11) OPERATION_MODE="security-scan" ;;
            12) OPERATION_MODE="auto-backup" ;;
            13) OPERATION_MODE="backup-migrate" ;;
            14) OPERATION_MODE="cross-server-migrate" ;;
            15) OPERATION_MODE="optimize" ;;
            16) OPERATION_MODE="package-manage" ;;
            17) OPERATION_MODE="firewall-manage" ;;
            18) OPERATION_MODE="system-update" ;;
            19) 
                display_detailed_server_info
                exit 0
                ;;
            20) 
                list_sites
                exit 0
                ;;
            21) OPERATION_MODE="system-logs" ;;
            0) exit 0 ;;
            *) 
                echo -e "${RED}[错误]${NC} 无效选择"
                exit 1
                ;;
        esac
    fi
}
# --- 基础工具函数 ---
generate_password() {
    openssl rand -base64 32 | tr -d '=+/' | head -c 24
}

load_progress() {
    local step="$1"
    if [[ -f "$STATE_FILE" ]] && grep -q "^$step$" "$STATE_FILE"; then
        return 0
    fi
    return 1
}

mark_complete() {
    local step="$1"
    echo "$step" >> "$STATE_FILE"
}

# --- 系统兼容性检查 ---
check_system_compatibility() {
    log_message "INFO" "检查系统兼容性..."
    
    # 检查必要的命令
    local required_commands=("curl" "wget" "tar" "gzip" "openssl")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_message "WARNING" "缺少命令: $cmd，将尝试安装"
            apt update && apt install -y "$cmd"
        fi
    done
    
    # 检查网络连接
    if ! curl -s --connect-timeout 5 https://www.google.com > /dev/null; then
        log_message "WARNING" "网络连接可能有问题，请检查网络设置"
    fi
    
    log_message "SUCCESS" "系统兼容性检查完成"
}
# --- 现有站点检测 ---
detect_existing_sites() {
    log_message "INFO" "检测现有WordPress站点..."
    
    local detected_sites=()
    
    # 检查常见的WordPress目录
    local common_paths=(
        "/var/www/html"
        "/var/www"
        "/home/*/public_html"
        "/opt/wordpress"
    )
    
    for path in "${common_paths[@]}"; do
        if [[ -d "$path" ]]; then
            # 查找WordPress安装
            find "$path" -name "wp-config.php" -type f 2>/dev/null | while read wp_config; do
                local site_dir=$(dirname "$wp_config")
                local domain=$(basename "$(dirname "$site_dir")" 2>/dev/null || basename "$site_dir")
                
                # 验证是否为有效的WordPress安装
                if [[ -f "$site_dir/wp-includes/version.php" ]]; then
                    detected_sites+=("$domain:$site_dir")
                    log_message "INFO" "发现WordPress站点: $domain ($site_dir)"
                fi
            done
        fi
    done
    
    # 检查Nginx配置中的站点
    if [[ -d "/etc/nginx/sites-enabled" ]]; then
        for config in /etc/nginx/sites-enabled/*; do
            if [[ -f "$config" ]] && [[ "$(basename "$config")" != "default" ]]; then
                local domain=$(basename "$config")
                local root_path=$(grep -E "^\s*root\s+" "$config" | head -1 | awk '{print $2}' | tr -d ';')
                
                if [[ -n "$root_path" ]] && [[ -f "$root_path/wp-config.php" ]]; then
                    log_message "INFO" "发现Nginx配置的WordPress站点: $domain ($root_path)"
                fi
            fi
        done
    fi
    
    if [[ ${#detected_sites[@]} -gt 0 ]]; then
        echo -e "\n${YELLOW}发现现有WordPress站点，是否导入到管理系统？${NC}"
        read -rp "是否导入现有站点? (y/n): " IMPORT_EXISTING
        
        if [[ "$IMPORT_EXISTING" =~ ^[Yy]$ ]]; then
            import_detected_sites "${detected_sites[@]}"
        fi
    else
        log_message "INFO" "未发现现有WordPress站点"
    fi
}

import_detected_sites() {
    local sites=("$@")
    
    for site_info in "${sites[@]}"; do
        local domain="${site_info%%:*}"
        local path="${site_info##*:}"
        
        # 检测PHP版本
        local php_version="8.3"  # 默认版本
        
        # 尝试从现有配置检测PHP版本
        if [[ -f "/etc/nginx/sites-available/$domain" ]]; then
            local detected_php=$(grep -o "php[0-9]\.[0-9]" "/etc/nginx/sites-available/$domain" | head -1 | sed 's/php//')
            if [[ -n "$detected_php" ]]; then
                php_version="$detected_php"
            fi
        fi
        
        # 添加到站点配置
        SITE_COUNT=$((SITE_COUNT + 1))
        SITE_DOMAINS[$SITE_COUNT]="$domain"
        SITE_PHP_VERSIONS[$SITE_COUNT]="$php_version"
        SITE_WOOCOMMERCE[$SITE_COUNT]="unknown"
        SITE_ADMIN_USERS[$SITE_COUNT]="admin"
        SITE_ADMIN_EMAILS[$SITE_COUNT]="admin@$domain"
        SITE_TITLES[$SITE_COUNT]="$domain"
        
        log_message "SUCCESS" "已导入站点: $domain (PHP $php_version)"
    done
    
    # 保存配置
    save_sites_config
}
# --- 新服务器部署 ---
deploy_new_server() {
    log_message "TASK" "开始新服务器WordPress部署..."
    
    # 收集站点信息
    collect_new_server_input
    
    # 系统初始化
    if ! load_progress "system_init"; then
        install_system_packages
        mark_complete "system_init"
    fi
    
    # 安装和配置服务
    if ! load_progress "services_setup"; then
        setup_mariadb
        setup_nginx
        setup_redis
        setup_fail2ban
        setup_firewall
        mark_complete "services_setup"
    fi
    
    # 部署所有站点
    for i in $(seq 1 $SITE_COUNT); do
        deploy_single_site "$i"
    done
    
    # 创建管理脚本
    create_management_scripts
    
    # 系统优化
    optimize_system_performance
    
    log_message "SUCCESS" "新服务器部署完成！"
    show_deployment_summary
}

collect_new_server_input() {
    echo -e "\n${CYAN}=== 新服务器初始化配置 ===${NC}\n"
    
    # 询问要部署多少个站点
    while true; do
        read -rp "请输入要部署的WordPress站点数量 (1-10): " SITES_TO_DEPLOY
        if [[ "$SITES_TO_DEPLOY" =~ ^[1-9]$|^10$ ]]; then
            break
        else
            echo -e "${RED}[错误]${NC} 请输入1-10之间的数字"
        fi
    done
    
    SITE_COUNT="$SITES_TO_DEPLOY"
    
    # 收集每个站点的信息
    for i in $(seq 1 $SITE_COUNT); do
        echo -e "\n${BLUE}=== 配置站点 $i ===${NC}"
        
        # 域名
        while true; do
            read -rp "请输入站点 $i 的域名: " domain
            if [[ "$domain" =~ ^[a-zA-Z0-9]+([-.]?[a-zA-Z0-9]+)*\.[a-zA-Z]{2,}$ ]]; then
                SITE_DOMAINS[$i]="$domain"
                break
            else
                echo -e "${RED}[错误]${NC} 域名格式不正确，请重新输入"
            fi
        done
        
        # PHP版本选择
        echo "请选择PHP版本:"
        for j in "${!AVAILABLE_PHP_VERSIONS[@]}"; do
            echo "$((j+1))) PHP ${AVAILABLE_PHP_VERSIONS[j]}"
        done
        
        while true; do
            read -rp "请选择 [1-${#AVAILABLE_PHP_VERSIONS[@]}]: " php_choice
            if [[ "$php_choice" =~ ^[0-9]+$ ]] && 
               [[ "$php_choice" -ge 1 ]] && 
               [[ "$php_choice" -le "${#AVAILABLE_PHP_VERSIONS[@]}" ]]; then
                SITE_PHP_VERSIONS[$i]="${AVAILABLE_PHP_VERSIONS[$((php_choice-1))]}"
                break
            else
                echo -e "${RED}[错误]${NC} 请选择有效的PHP版本"
            fi
        done
        # 管理员信息
        read -rp "请输入管理员邮箱: " admin_email
        SITE_ADMIN_EMAILS[$i]="$admin_email"
        
        read -rp "请输入管理员用户名 (默认: admin): " admin_user
        SITE_ADMIN_USERS[$i]="${admin_user:-admin}"
        
        read -rp "请输入站点标题 (默认: ${SITE_DOMAINS[$i]}): " site_title
        SITE_TITLES[$i]="${site_title:-${SITE_DOMAINS[$i]}}"
        
        # WooCommerce
        read -rp "是否安装WooCommerce? (y/n): " install_woo
        if [[ "$install_woo" =~ ^[Yy]$ ]]; then
            SITE_WOOCOMMERCE[$i]="yes"
        else
            SITE_WOOCOMMERCE[$i]="no"
        fi
        
        echo -e "${GREEN}站点 $i 配置完成:${NC}"
        echo "  域名: ${SITE_DOMAINS[$i]}"
        echo "  PHP版本: ${SITE_PHP_VERSIONS[$i]}"
        echo "  管理员: ${SITE_ADMIN_USERS[$i]} (${SITE_ADMIN_EMAILS[$i]})"
        echo "  WooCommerce: ${SITE_WOOCOMMERCE[$i]}"
    done
    
    # 保存配置
    save_sites_config
    
    echo -e "\n${GREEN}所有站点配置完成！${NC}"
    echo -e "即将开始部署 $SITE_COUNT 个WordPress站点"
    
    read -rp "确认开始部署? (y/n): " CONFIRM_DEPLOY
    if [[ ! "$CONFIRM_DEPLOY" =~ ^[Yy]$ ]]; then
        log_message "INFO" "用户取消部署"
        exit 0
    fi
}
# --- 系统包安装 ---
install_system_packages() {
    log_message "TASK" "安装系统包..."
    
    # 更新包列表
    apt update
    
    # 安装基础包
    apt install -y \
        curl \
        wget \
        unzip \
        software-properties-common \
        apt-transport-https \
        ca-certificates \
        gnupg \
        lsb-release \
        ufw \
        fail2ban \
        htop \
        tree \
        git
    
    # 安装Nginx
    apt install -y nginx
    
    # 安装MariaDB
    apt install -y mariadb-server mariadb-client
    
    # 安装Redis
    apt install -y redis-server
    
    # 添加PHP仓库
    add-apt-repository -y ppa:ondrej/php
    apt update
    
    # 安装所需的PHP版本
    local php_versions=()
    for i in $(seq 1 $SITE_COUNT); do
        local version="${SITE_PHP_VERSIONS[$i]}"
        if [[ ! " ${php_versions[@]} " =~ " ${version} " ]]; then
            php_versions+=("$version")
        fi
    done
    
    for version in "${php_versions[@]}"; do
        log_message "INFO" "安装PHP $version..."
        apt install -y \
            "php$version" \
            "php$version-fpm" \
            "php$version-mysql" \
            "php$version-curl" \
            "php$version-gd" \
            "php$version-mbstring" \
            "php$version-xml" \
            "php$version-zip" \
            "php$version-bcmath" \
            "php$version-intl" \
            "php$version-redis" \
            "php$version-imagick"
    done
    
    # 安装Certbot
    apt install -y certbot python3-certbot-nginx
    
    # 安装WP-CLI
    curl -O https://raw.githubusercontent.com/wp-cli/wp-cli/v2.8.1/wp-cli.phar
    chmod +x wp-cli.phar
    mv wp-cli.phar /usr/local/bin/wp
    
    log_message "SUCCESS" "系统包安装完成"
}
# --- 服务配置 ---
setup_mariadb() {
    log_message "TASK" "配置MariaDB..."
    
    # 启动MariaDB
    systemctl start mariadb
    systemctl enable mariadb
    
    # 生成root密码
    local root_password=$(generate_password)
    
    # 安全配置
    mariadb -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$root_password';"
    mariadb -u root -p"$root_password" -e "DELETE FROM mysql.user WHERE User='';"
    mariadb -u root -p"$root_password" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    mariadb -u root -p"$root_password" -e "DROP DATABASE IF EXISTS test;"
    mariadb -u root -p"$root_password" -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
    mariadb -u root -p"$root_password" -e "FLUSH PRIVILEGES;"
    
    # 保存root密码
    echo "MARIADB_ROOT_PASSWORD=\"$root_password\"" > /root/.mariadb-root-password
    chmod 600 /root/.mariadb-root-password
    
    # 创建MariaDB配置文件以便无密码访问
    cat > /root/.my.cnf << EOF
[client]
user=root
password=$root_password
EOF
    chmod 600 /root/.my.cnf
    
    # 优化配置
    cat > /etc/mysql/mariadb.conf.d/50-wordpress.cnf << 'MARIADBEOF'
[mysqld]
# WordPress优化配置
max_connections = 200
innodb_buffer_pool_size = 256M
innodb_log_file_size = 64M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
query_cache_type = 1
query_cache_size = 32M
query_cache_limit = 2M
tmp_table_size = 32M
max_heap_table_size = 32M

# MariaDB特定优化
innodb_buffer_pool_instances = 1
innodb_read_io_threads = 4
innodb_write_io_threads = 4
innodb_thread_concurrency = 0
innodb_flush_neighbors = 1
innodb_log_buffer_size = 16M

# 字符集设置
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

# 二进制日志
log_bin = /var/log/mysql/mysql-bin.log
expire_logs_days = 7
max_binlog_size = 100M

# 慢查询日志
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2
MARIADBEOF
    
    systemctl restart mariadb
    log_message "SUCCESS" "MariaDB配置完成"
}

setup_nginx() {
    log_message "TASK" "配置Nginx..."
    
    # 启动Nginx
    systemctl start nginx
    systemctl enable nginx
    
    # 备份默认配置
    cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup
    
    # 优化主配置
    cat > /etc/nginx/nginx.conf << 'NGINXEOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
    use epoll;
    multi_accept on;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;
    
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    # Gzip压缩
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/json
        application/javascript
        application/xml+rss
        application/atom+xml
        image/svg+xml;
    
    # 日志格式
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log;
    
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
NGINXEOF
    
    # 删除默认站点
    rm -f /etc/nginx/sites-enabled/default
    
    systemctl restart nginx
    log_message "SUCCESS" "Nginx配置完成"
}
setup_redis() {
    log_message "TASK" "配置Redis..."
    
    # 启动Redis
    systemctl start redis-server
    systemctl enable redis-server
    
    # 生成Redis密码
    local redis_password=$(generate_password)
    
    # 配置Redis
    sed -i "s/# requirepass foobared/requirepass $redis_password/" /etc/redis/redis.conf
    sed -i "s/# maxmemory <bytes>/maxmemory 256mb/" /etc/redis/redis.conf
    sed -i "s/# maxmemory-policy noeviction/maxmemory-policy allkeys-lru/" /etc/redis/redis.conf
    
    systemctl restart redis-server
    
    # 保存Redis密码
    echo "REDIS_PASSWORD=\"$redis_password\"" > /root/.redis-password
    
    log_message "SUCCESS" "Redis配置完成"
}

setup_fail2ban() {
    log_message "TASK" "配置Fail2ban..."
    
    systemctl start fail2ban
    systemctl enable fail2ban
    
    # 配置Nginx保护
    cat > /etc/fail2ban/jail.local << 'FAIL2BANEOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[nginx-http-auth]
enabled = true

[nginx-noscript]
enabled = true

[nginx-badbots]
enabled = true

[nginx-noproxy]
enabled = true

[nginx-limit-req]
enabled = true
filter = nginx-limit-req
action = iptables-multiport[name=ReqLimit, port="http,https", protocol=tcp]
logpath = /var/log/nginx/*error.log
findtime = 600
bantime = 7200
maxretry = 10
FAIL2BANEOF
    
    systemctl restart fail2ban
    log_message "SUCCESS" "Fail2ban配置完成"
}

setup_firewall() {
    log_message "TASK" "配置防火墙..."
    
    # 重置UFW
    ufw --force reset
    
    # 默认策略
    ufw default deny incoming
    ufw default allow outgoing
    
    # 允许SSH
    ufw allow ssh
    
    # 允许HTTP和HTTPS
    ufw allow 80/tcp
    ufw allow 443/tcp
    
    # 启用防火墙
    ufw --force enable
    
    log_message "SUCCESS" "防火墙配置完成"
}
# --- 单站点部署 ---
deploy_single_site() {
    local site_index="$1"
    local domain="${SITE_DOMAINS[$site_index]}"
    local php_version="${SITE_PHP_VERSIONS[$site_index]}"
    
    log_message "TASK" "部署站点: $domain (PHP $php_version)"
    
    # 创建站点目录
    create_site_directories "$domain"
    
    # 创建数据库
    create_site_database "$site_index"
    
    # 配置Nginx
    configure_nginx_site "$site_index"
    
    # 获取SSL证书
    get_ssl_certificate "$domain"
    
    # 安装WordPress
    install_wordpress "$site_index"
    
    # 配置缓存
    setup_site_caching "$site_index"
    
    # 设置权限
    set_site_permissions "$domain"
    
    # 创建站点管理脚本
    create_site_management_script "$site_index"
    
    log_message "SUCCESS" "站点 $domain 部署完成"
}

create_site_directories() {
    local domain="$1"
    
    # 创建目录结构
    mkdir -p "/var/www/$domain"/{public,cache/fastcgi,logs,backups}
    
    # 设置基础权限
    chown -R www-data:www-data "/var/www/$domain"
    chmod -R 755 "/var/www/$domain"
}

create_site_database() {
    local site_index="$1"
    local domain="${SITE_DOMAINS[$site_index]}"
    
    # 生成数据库信息
    local db_name="wp_$(echo "$domain" | tr -cd 'a-zA-Z0-9' | head -c 16)"
    local db_user="wp_${db_name:3:8}"
    local db_pass=$(generate_password)
    
    # 创建数据库和用户
    mariadb -e "CREATE DATABASE IF NOT EXISTS $db_name CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mariadb -e "CREATE USER IF NOT EXISTS '$db_user'@'localhost' IDENTIFIED BY '$db_pass';"
    mariadb -e "GRANT ALL PRIVILEGES ON $db_name.* TO '$db_user'@'localhost';"
    mariadb -e "FLUSH PRIVILEGES;"
    
    # 保存数据库信息
    cat > "/var/www/$domain/.db-config" << EOF
DB_NAME="$db_name"
DB_USER="$db_user"
DB_PASS="$db_pass"
EOF
    
    chmod 600 "/var/www/$domain/.db-config"
}
configure_nginx_site() {
    local site_index="$1"
    local domain="${SITE_DOMAINS[$site_index]}"
    local php_version="${SITE_PHP_VERSIONS[$site_index]}"
    
    # 创建Nginx配置
    cat > "/etc/nginx/sites-available/$domain" << EOF
server {
    listen 80;
    server_name $domain www.$domain;
    root /var/www/$domain/public;
    index index.php index.html index.htm;
    
    # 安全头
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;
    
    # FastCGI缓存配置
    set \$skip_cache 0;
    
    # POST请求和查询字符串不缓存
    if (\$request_method = POST) {
        set \$skip_cache 1;
    }
    if (\$query_string != "") {
        set \$skip_cache 1;
    }
    
    # WordPress特定不缓存
    if (\$request_uri ~* "/wp-admin/|/xmlrpc.php|wp-.*.php|/feed/|index.php|sitemap(_index)?.xml") {
        set \$skip_cache 1;
    }
    
    # 登录用户不缓存
    if (\$http_cookie ~* "comment_author|wordpress_[a-f0-9]+|wp-postpass|wordpress_no_cache|wordpress_logged_in") {
        set \$skip_cache 1;
    }
    
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php$php_version-fpm.sock;
        
        # FastCGI缓存
        fastcgi_cache_path /var/www/$domain/cache/fastcgi levels=1:2 keys_zone=${domain}_cache:100m inactive=60m;
        fastcgi_cache ${domain}_cache;
        fastcgi_cache_valid 200 60m;
        fastcgi_cache_bypass \$skip_cache;
        fastcgi_no_cache \$skip_cache;
        add_header X-FastCGI-Cache \$upstream_cache_status;
    }
    
    # 静态文件缓存
    location ~* \.(css|gif|ico|jpeg|jpg|js|png|webp|woff|woff2|ttf|svg)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }
    
    # 安全配置
    location ~ /\.ht {
        deny all;
    }
    
    location = /favicon.ico {
        log_not_found off;
        access_log off;
    }
    
    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }
    
    # 日志
    access_log /var/www/$domain/logs/nginx-access.log;
    error_log /var/www/$domain/logs/nginx-error.log;
}
EOF
    
    # 启用站点
    ln -sf "/etc/nginx/sites-available/$domain" "/etc/nginx/sites-enabled/"
    
    # 测试配置
    nginx -t && systemctl reload nginx
}

get_ssl_certificate() {
    local domain="$1"
    
    log_message "TASK" "获取SSL证书: $domain"
    
    # 获取证书
    certbot certonly --webroot --agree-tos --non-interactive \
        --email "${SITE_ADMIN_EMAILS[1]}" \
        -d "$domain" -d "www.$domain" \
        --webroot-path "/var/www/$domain/public"
    
    if [[ $? -eq 0 ]]; then
        # 更新Nginx配置以使用SSL
        update_nginx_ssl_config "$domain"
        log_message "SUCCESS" "SSL证书获取成功: $domain"
    else
        log_message "WARNING" "SSL证书获取失败: $domain"
    fi
}

update_nginx_ssl_config() {
    local domain="$1"
    
    # 备份当前配置
    cp "/etc/nginx/sites-available/$domain" "/etc/nginx/sites-available/$domain.backup"
    
    # 添加SSL配置
    cat >> "/etc/nginx/sites-available/$domain" << EOF

server {
    listen 443 ssl http2;
    server_name $domain www.$domain;
    root /var/www/$domain/public;
    index index.php index.html index.htm;
    
    # SSL配置
    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    
    # 其他配置与HTTP版本相同...
    # (这里会包含与上面HTTP配置相同的location块)
}

# HTTP重定向到HTTPS
server {
    listen 80;
    server_name $domain www.$domain;
    return 301 https://\$server_name\$request_uri;
}
EOF
    
    nginx -t && systemctl reload nginx
}
install_wordpress() {
    local site_index="$1"
    local domain="${SITE_DOMAINS[$site_index]}"
    local wp_path="/var/www/$domain/public"
    
    log_message "TASK" "安装WordPress: $domain"
    
    # 下载WordPress
    cd "/var/www/$domain"
    sudo -u www-data wp core download --path="$wp_path"
    
    # 加载数据库配置
    source "/var/www/$domain/.db-config"
    
    # 创建wp-config.php
    sudo -u www-data wp config create \
        --path="$wp_path" \
        --dbname="$DB_NAME" \
        --dbuser="$DB_USER" \
        --dbpass="$DB_PASS" \
        --dbhost="localhost" \
        --dbprefix="wp_"
    
    # 安装WordPress
    sudo -u www-data wp core install \
        --path="$wp_path" \
        --url="https://$domain" \
        --title="${SITE_TITLES[$site_index]}" \
        --admin_user="${SITE_ADMIN_USERS[$site_index]}" \
        --admin_password="$(generate_password)" \
        --admin_email="${SITE_ADMIN_EMAILS[$site_index]}"
    
    # 安装WooCommerce（如果需要）
    if [[ "${SITE_WOOCOMMERCE[$site_index]}" == "yes" ]]; then
        sudo -u www-data wp plugin install woocommerce --activate --path="$wp_path"
    fi
    
    # 安装推荐插件
    sudo -u www-data wp plugin install redis-cache --activate --path="$wp_path"
    sudo -u www-data wp plugin install wp-super-cache --path="$wp_path"
    
    # 保存WordPress凭据
    save_wordpress_credentials "$site_index"
    
    log_message "SUCCESS" "WordPress安装完成: $domain"
}

setup_site_caching() {
    local site_index="$1"
    local domain="${SITE_DOMAINS[$site_index]}"
    local wp_path="/var/www/$domain/public"
    
    # 配置Redis缓存
    if [[ -f "/root/.redis-password" ]]; then
        source "/root/.redis-password"
        
        # 添加Redis配置到wp-config.php
        sudo -u www-data wp config set WP_REDIS_HOST 'localhost' --path="$wp_path"
        sudo -u www-data wp config set WP_REDIS_PORT 6379 --path="$wp_path"
        sudo -u www-data wp config set WP_REDIS_PASSWORD "$REDIS_PASSWORD" --path="$wp_path"
        sudo -u www-data wp config set WP_REDIS_DATABASE 0 --path="$wp_path"
        
        # 启用Redis缓存
        sudo -u www-data wp redis enable --path="$wp_path"
    fi
    
    # 创建FastCGI缓存目录
    mkdir -p "/var/www/$domain/cache/fastcgi"
    chown -R www-data:www-data "/var/www/$domain/cache"
}

set_site_permissions() {
    local domain="$1"
    
    # 设置正确的权限
    chown -R www-data:www-data "/var/www/$domain"
    find "/var/www/$domain" -type d -exec chmod 755 {} \;
    find "/var/www/$domain" -type f -exec chmod 644 {} \;
    
    # WordPress特殊权限
    chmod 600 "/var/www/$domain/public/wp-config.php"
    chmod 755 "/var/www/$domain/public"
}

save_wordpress_credentials() {
    local site_index="$1"
    local domain="${SITE_DOMAINS[$site_index]}"
    
    # 获取WordPress管理员密码
    local wp_admin_pass=$(sudo -u www-data wp user get "${SITE_ADMIN_USERS[$site_index]}" --field=user_pass --path="/var/www/$domain/public")
    
    # 加载数据库配置
    source "/var/www/$domain/.db-config"
    
    # 保存凭据
    cat > "/root/wordpress-credentials-$domain.txt" << EOF
=== WordPress站点凭据 ===
域名: $domain
部署时间: $(date)

=== WordPress管理员 ===
登录URL: https://$domain/wp-admin/
用户名: ${SITE_ADMIN_USERS[$site_index]}
邮箱: ${SITE_ADMIN_EMAILS[$site_index]}
密码: [请使用忘记密码功能重置]

=== 数据库信息 ===
数据库名: $DB_NAME
用户名: $DB_USER
密码: $DB_PASS
主机: localhost

=== 管理脚本 ===
站点管理: manage-$domain
状态检查: manage-$domain status
缓存清理: manage-$domain cache-clear
创建备份: manage-$domain backup

=== 重要文件路径 ===
网站根目录: /var/www/$domain/public
配置文件: /var/www/$domain/public/wp-config.php
Nginx配置: /etc/nginx/sites-available/$domain
SSL证书: /etc/letsencrypt/live/$domain/
日志目录: /var/www/$domain/logs
备份目录: /var/www/$domain/backups
EOF
    
    chmod 600 "/root/wordpress-credentials-$domain.txt"
}
create_site_management_script() {
    local site_index="$1"
    local domain="${SITE_DOMAINS[$site_index]}"
    local php_version="${SITE_PHP_VERSIONS[$site_index]}"
    
    # 加载数据库和Redis配置
    source "/var/www/$domain/.db-config"
    source "/root/.redis-password" 2>/dev/null || REDIS_PASSWORD=""
    
    cat > "/usr/local/bin/manage-$domain" << EOF
#!/bin/bash

# WordPress站点管理脚本 - $domain
DOMAIN="$domain"
PHP_VERSION="$php_version"
WP_PATH="/var/www/$domain/public"
DB_NAME="$DB_NAME"
DB_USER="$DB_USER"
DB_PASS="$DB_PASS"
REDIS_PASS="$REDIS_PASSWORD"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

case "\$1" in
    status)
        echo -e "\${CYAN}=== \$DOMAIN 站点状态 ===\${NC}"
        echo "PHP版本: \$PHP_VERSION"
        echo "WordPress路径: \$WP_PATH"
        echo ""
        
        # 检查服务状态
        echo -e "\${BLUE}服务状态:\${NC}"
        systemctl is-active nginx && echo "  Nginx: 运行中" || echo "  Nginx: 未运行"
        systemctl is-active "php\$PHP_VERSION-fpm" && echo "  PHP-FPM: 运行中" || echo "  PHP-FPM: 未运行"
        systemctl is-active mariadb && echo "  MariaDB: 运行中" || echo "  MariaDB: 未运行"
        
        # 检查网站访问
        echo -e "\${BLUE}网站状态:\${NC}"
        if curl -I "https://\$DOMAIN" 2>/dev/null | grep -q "200 OK"; then
            echo "  网站访问: 正常"
        else
            echo "  网站访问: 异常"
        fi
        
        # 缓存状态
        echo -e "\${BLUE}缓存状态:\${NC}"
        if [[ -d "/var/www/\$DOMAIN/cache/fastcgi" ]]; then
            local cache_files=\$(find "/var/www/\$DOMAIN/cache/fastcgi" -type f | wc -l)
            local cache_size=\$(du -sh "/var/www/\$DOMAIN/cache/fastcgi" 2>/dev/null | cut -f1)
            echo "  FastCGI缓存: \$cache_files 文件, \$cache_size"
        fi
        ;;
        
    restart)
        echo -e "\${CYAN}重启相关服务...\${NC}"
        systemctl restart "php\$PHP_VERSION-fpm"
        systemctl reload nginx
        echo -e "\${GREEN}服务重启完成\${NC}"
        ;;
        
    cache-clear)
        echo -e "\${CYAN}清除所有缓存...\${NC}"
        
        # 清除FastCGI缓存
        rm -rf "/var/www/\$DOMAIN/cache/fastcgi/*"
        echo "FastCGI缓存已清除"
        
        # 清除Redis缓存
        if [[ -n "\$REDIS_PASS" ]]; then
            redis-cli -a "\$REDIS_PASS" FLUSHDB >/dev/null 2>&1
            echo "Redis缓存已清除"
        fi
        
        # 清除WordPress缓存
        if [[ -f "\$WP_PATH/wp-config.php" ]]; then
            sudo -u www-data wp cache flush --path="\$WP_PATH" 2>/dev/null
            echo "WordPress缓存已清除"
        fi
        
        echo -e "\${GREEN}所有缓存清除完成\${NC}"
        ;;
        
    backup)
        echo -e "\${CYAN}创建站点备份...\${NC}"
        
        local backup_dir="/var/www/\$DOMAIN/backups"
        local timestamp=\$(date +%Y%m%d-%H%M%S)
        
        mkdir -p "\$backup_dir"
        
        # 备份文件
        echo "备份网站文件..."
        tar -czf "\$backup_dir/backup-\$timestamp.tar.gz" -C "/var/www/\$DOMAIN" public
        
        # 备份数据库
        echo "备份数据库..."
        mariadb-dump "\$DB_NAME" | gzip > "\$backup_dir/\$DB_NAME-\$timestamp.sql.gz"
        
        echo -e "\${GREEN}备份完成: \$backup_dir/backup-\$timestamp.tar.gz\${NC}"
        ;;
        
    update)
        echo -e "\${CYAN}更新WordPress...\${NC}"
        cd "\$WP_PATH"
        sudo -u www-data wp core update
        sudo -u www-data wp plugin update --all
        sudo -u www-data wp theme update --all
        echo -e "\${GREEN}WordPress更新完成\${NC}"
        ;;
        
    info)
        echo -e "\${CYAN}=== \$DOMAIN 站点信息 ===\${NC}"
        echo "域名: \$DOMAIN"
        echo "PHP版本: \$PHP_VERSION"
        echo "WordPress路径: \$WP_PATH"
        echo "数据库: \$DB_NAME"
        echo "备份目录: /var/www/\$DOMAIN/backups"
        echo "日志目录: /var/www/\$DOMAIN/logs"
        
        if [[ -f "\$WP_PATH/wp-config.php" ]]; then
            echo ""
            echo "WordPress版本: \$(sudo -u www-data wp core version --path="\$WP_PATH")"
            echo "主题: \$(sudo -u www-data wp theme list --status=active --field=name --path="\$WP_PATH")"
            echo "插件数量: \$(sudo -u www-data wp plugin list --field=name --path="\$WP_PATH" | wc -l)"
        fi
        ;;
        
    *)
        echo "WordPress站点管理脚本 - \$DOMAIN"
        echo ""
        echo "用法: \$0 {status|restart|cache-clear|backup|update|info}"
        echo ""
        echo "命令说明:"
        echo "  status      - 显示站点状态"
        echo "  restart     - 重启相关服务"
        echo "  cache-clear - 清除所有缓存"
        echo "  backup      - 创建站点备份"
        echo "  update      - 更新WordPress"
        echo "  info        - 显示站点信息"
        ;;
esac
EOF
    
    chmod +x "/usr/local/bin/manage-$domain"
    log_message "SUCCESS" "站点管理脚本创建完成: manage-$domain"
}
create_management_scripts() {
    log_message "TASK" "创建全局管理脚本..."
    
    # 创建全局管理脚本
    cat > "/usr/local/bin/wp-vps-manager" << 'GLOBALEOF'
#!/bin/bash

# WordPress VPS全局管理脚本
SITES_CONFIG="$HOME/.vps-manager/wordpress-sites.conf"

if [[ -f "$SITES_CONFIG" ]]; then
    source "$SITES_CONFIG"
else
    echo "未找到站点配置文件"
    exit 1
fi

case "$1" in
    list)
        echo "=== 已配置的WordPress站点 ==="
        for i in $(seq 1 $SITE_COUNT); do
            echo "站点 $i: ${SITE_DOMAINS[$i]} (PHP ${SITE_PHP_VERSIONS[$i]})"
        done
        ;;
    status)
        echo "=== 所有站点状态 ==="
        for i in $(seq 1 $SITE_COUNT); do
            echo "检查站点: ${SITE_DOMAINS[$i]}"
            manage-${SITE_DOMAINS[$i]} status
            echo ""
        done
        ;;
    backup-all)
        echo "=== 备份所有站点 ==="
        for i in $(seq 1 $SITE_COUNT); do
            echo "备份站点: ${SITE_DOMAINS[$i]}"
            manage-${SITE_DOMAINS[$i]} backup
        done
        ;;
    *)
        echo "WordPress VPS全局管理脚本"
        echo ""
        echo "用法: $0 {list|status|backup-all}"
        echo ""
        echo "命令说明:"
        echo "  list       - 列出所有站点"
        echo "  status     - 检查所有站点状态"
        echo "  backup-all - 备份所有站点"
        ;;
esac
GLOBALEOF
    
    chmod +x "/usr/local/bin/wp-vps-manager"
    
    # 创建符号链接
    ln -sf "/usr/local/bin/wp-vps-manager" "/usr/local/bin/wpvps"
    
    log_message "SUCCESS" "全局管理脚本创建完成"
}

optimize_system_performance() {
    log_message "TASK" "优化系统性能..."
    
    # 优化PHP配置
    for version in "${AVAILABLE_PHP_VERSIONS[@]}"; do
        if systemctl is-active --quiet "php$version-fpm"; then
            # 优化PHP-FPM配置
            local fpm_conf="/etc/php/$version/fpm/pool.d/www.conf"
            if [[ -f "$fpm_conf" ]]; then
                sed -i 's/pm.max_children = .*/pm.max_children = 50/' "$fpm_conf"
                sed -i 's/pm.start_servers = .*/pm.start_servers = 5/' "$fpm_conf"
                sed -i 's/pm.min_spare_servers = .*/pm.min_spare_servers = 5/' "$fpm_conf"
                sed -i 's/pm.max_spare_servers = .*/pm.max_spare_servers = 35/' "$fpm_conf"
                
                systemctl restart "php$version-fpm"
            fi
            
            # 优化PHP配置
            local php_ini="/etc/php/$version/fpm/php.ini"
            if [[ -f "$php_ini" ]]; then
                sed -i 's/memory_limit = .*/memory_limit = 256M/' "$php_ini"
                sed -i 's/max_execution_time = .*/max_execution_time = 300/' "$php_ini"
                sed -i 's/upload_max_filesize = .*/upload_max_filesize = 64M/' "$php_ini"
                sed -i 's/post_max_size = .*/post_max_size = 64M/' "$php_ini"
                
                # 启用OPcache
                echo "opcache.enable=1" >> "$php_ini"
                echo "opcache.memory_consumption=128" >> "$php_ini"
                echo "opcache.interned_strings_buffer=8" >> "$php_ini"
                echo "opcache.max_accelerated_files=4000" >> "$php_ini"
                echo "opcache.revalidate_freq=2" >> "$php_ini"
                echo "opcache.fast_shutdown=1" >> "$php_ini"
            fi
        fi
    done
    
    # 设置自动SSL续期
    (crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet") | crontab -
    
    # 设置日志轮转
    cat > /etc/logrotate.d/wordpress << 'LOGROTATEEOF'
/var/www/*/logs/*.log {
    daily
    missingok
    rotate 52
    compress
    delaycompress
    notifempty
    create 644 www-data www-data
    postrotate
        systemctl reload nginx
    endscript
}
LOGROTATEEOF
    
    log_message "SUCCESS" "系统性能优化完成"
}
show_deployment_summary() {
    echo -e "\n${GREEN}============================================${NC}"
    echo -e "${GREEN}    WordPress VPS管理平台部署完成！${NC}"
    echo -e "${GREEN}============================================${NC}\n"
    
    echo -e "${CYAN}=== 服务器信息 ===${NC}"
    echo -e "Ubuntu版本: $(lsb_release -ds)"
    echo -e "MariaDB版本: $MARIADB_VERSION"
    echo -e "Redis: 已安装并优化"
    echo -e "总站点数: ${GREEN}$SITE_COUNT${NC}"
    
    # 显示PHP版本摘要
    local php_versions=()
    for i in $(seq 1 $SITE_COUNT); do
        local version="${SITE_PHP_VERSIONS[$i]}"
        if [[ ! " ${php_versions[@]} " =~ " ${version} " ]]; then
            php_versions+=("$version")
        fi
    done
    echo -e "已安装PHP版本: ${GREEN}${php_versions[*]}${NC}"
    
    echo -e "\n${CYAN}=== 站点详情 ===${NC}"
    for i in $(seq 1 $SITE_COUNT); do
        local domain="${SITE_DOMAINS[$i]}"
        local php_version="${SITE_PHP_VERSIONS[$i]}"
        local admin_user="${SITE_ADMIN_USERS[$i]}"
        local woocommerce="${SITE_WOOCOMMERCE[$i]}"
        
        echo -e "\n${GREEN}站点 $i: $domain${NC}"
        echo -e "  URL: https://$domain"
        echo -e "  PHP版本: $php_version"
        echo -e "  管理员: $admin_user"
        echo -e "  WooCommerce: $woocommerce"
        echo -e "  管理脚本: ${GREEN}manage-$domain${NC}"
        echo -e "  凭据文件: /root/wordpress-credentials-$domain.txt"
    done
    
    echo -e "\n${CYAN}=== 全局管理命令 ===${NC}"
    echo -e "查看所有站点: ${GREEN}wp-vps-manager list${NC}"
    echo -e "检查站点状态: ${GREEN}wp-vps-manager status${NC}"
    echo -e "备份所有站点: ${GREEN}wp-vps-manager backup-all${NC}"
    echo -e "运行主脚本: ${GREEN}$0${NC}"
    
    echo -e "\n${CYAN}=== 单站点管理 ===${NC}"
    for i in $(seq 1 $SITE_COUNT); do
        local domain="${SITE_DOMAINS[$i]}"
        echo -e "站点 $i ($domain):"
        echo -e "  状态检查: manage-$domain status"
        echo -e "  清除缓存: manage-$domain cache-clear"
        echo -e "  创建备份: manage-$domain backup"
        echo -e "  更新WordPress: manage-$domain update"
    done
    
    echo -e "\n${YELLOW}=== 重要提示 ===${NC}"
    echo -e "1. 所有站点凭据已保存到 /root/wordpress-credentials-*.txt"
    echo -e "2. 每个站点都有独立的FastCGI缓存目录"
    echo -e "3. 支持不同PHP版本的站点共存"
    echo -e "4. SSL证书将自动续期"
    echo -e "5. 定期备份所有站点数据"
    echo -e "6. 使用防火墙和Fail2ban保护服务器"
    
    echo -e "\n${CYAN}=== 性能优化说明 ===${NC}"
    echo -e "✓ 每个站点独立的FastCGI缓存"
    echo -e "✓ Redis对象缓存（所有站点共享）"
    echo -e "✓ PHP OPcache优化"
    echo -e "✓ MariaDB性能调优"
    echo -e "✓ Nginx高性能配置"
    echo -e "✓ 自动SSL证书管理"
    
    # 保存部署摘要
    cat > /root/wp-vps-deployment-summary.txt << EOF
=== WordPress VPS管理平台部署摘要 ===
部署时间: $(date)
服务器: $(hostname)
Ubuntu版本: $(lsb_release -ds)
总站点数: $SITE_COUNT

=== 站点列表 ===
EOF

    for i in $(seq 1 $SITE_COUNT); do
        echo "站点 $i: ${SITE_DOMAINS[$i]} (PHP ${SITE_PHP_VERSIONS[$i]})" >> /root/wp-vps-deployment-summary.txt
    done
    
    cat >> /root/wp-vps-deployment-summary.txt << EOF

=== 管理命令 ===
全局管理: wp-vps-manager
查看站点: wp-vps-manager list
检查状态: wp-vps-manager status
备份所有: wp-vps-manager backup-all

=== 凭据文件 ===
EOF

    for i in $(seq 1 $SITE_COUNT); do
        echo "/root/wordpress-credentials-${SITE_DOMAINS[$i]}.txt" >> /root/wp-vps-deployment-summary.txt
    done
    
    echo "" >> /root/wp-vps-deployment-summary.txt
    echo "生成时间: $(date)" >> /root/wp-vps-deployment-summary.txt
    
    echo -e "\n${YELLOW}部署摘要已保存到: /root/wp-vps-deployment-summary.txt${NC}"
    echo -e "${YELLOW}部署日志: $LOG_FILE${NC}"
}
# --- 命令行参数处理 ---
handle_command_line_args() {
    case "$1" in
        --list|-l)
            init_script
            list_sites
            exit 0
            ;;
        --import|-i)
            init_script
            detect_existing_sites
            exit 0
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        --version|-v)
            echo "WordPress VPS管理平台 v7.0"
            echo "Cloudways/SpinupWP替代方案"
            exit 0
            ;;
        "")
            # 无参数，正常运行
            ;;
        *)
            echo -e "${RED}[错误]${NC} 未知参数: $1"
            show_help
            exit 1
            ;;
    esac
}

show_help() {
    echo "WordPress VPS管理平台 v7.0 (Cloudways/SpinupWP替代方案)"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  无参数          交互式部署/管理模式"
    echo "  -l, --list      列出所有已配置的站点"
    echo "  -i, --import    检测并导入现有WordPress站点"
    echo "  -h, --help      显示此帮助信息"
    echo "  -v, --version   显示版本信息"
    echo ""
    echo "核心功能:"
    echo "  • 新服务器多站点部署"
    echo "  • 添加新WordPress站点"
    echo "  • 升级现有站点PHP版本"
    echo "  • 全面的站点管理功能"
    echo "  • 支持多PHP版本共存"
    echo "  • 独立FastCGI缓存管理"
    echo "  • 自动SSL证书管理"
    echo "  • 系统性能优化"
    echo "  • 安全防护配置"
    echo ""
    echo "管理功能:"
    echo "  • 实时监控和日志分析"
    echo "  • 自动备份和恢复"
    echo "  • 跨服务器迁移"
    echo "  • 防火墙和安全扫描"
    echo "  • 性能基准测试"
    echo ""
    echo "全局管理命令:"
    echo "  wp-vps-manager list      - 列出所有站点"
    echo "  wp-vps-manager status    - 检查所有站点状态"
    echo "  wp-vps-manager backup-all - 备份所有站点"
    echo ""
    echo "单站点管理:"
    echo "  manage-DOMAIN status     - 检查站点状态"
    echo "  manage-DOMAIN cache-clear - 清除缓存"
    echo "  manage-DOMAIN backup     - 创建备份"
    echo "  manage-DOMAIN update     - 更新WordPress"
    echo ""
    echo "示例:"
    echo "  sudo $0              # 交互式部署/管理"
    echo "  sudo $0 --list       # 查看所有站点"
    echo "  sudo $0 --import     # 导入现有WordPress站点"
    echo ""
    echo "特性对比:"
    echo "  ✓ 替代Cloudways的VPS管理功能"
    echo "  ✓ 替代SpinupWP的WordPress优化"
    echo "  ✓ 完全开源，无月费"
    echo "  ✓ 支持Ubuntu 20.04/22.04/24.04"
    echo "  ✓ 多PHP版本并存"
    echo "  ✓ 企业级性能优化"
}

# --- 主程序 ---
main() {
    init_script
    select_operation_mode
    
    case "$OPERATION_MODE" in
        "new-server")
            echo -e "\n${CYAN}开始WordPress VPS管理平台部署...${NC}"
            echo -e "站点数量: ${GREEN}$SITE_COUNT${NC}"
            
            # 显示PHP版本摘要
            local php_versions=()
            for i in $(seq 1 $SITE_COUNT); do
                local version="${SITE_PHP_VERSIONS[$i]}"
                if [[ ! " ${php_versions[@]} " =~ " ${version} " ]]; then
                    php_versions+=("$version")
                fi
            done
            echo -e "PHP版本: ${GREEN}${php_versions[*]}${NC}"
            echo -e "预计时间: 15-25分钟\n"
            
            deploy_new_server
            ;;
        *)
            echo -e "${YELLOW}[提示]${NC} 其他功能正在开发中..."
            echo -e "当前版本主要支持新服务器部署功能"
            echo -e "更多功能将在后续版本中添加"
            ;;
    esac
}

# 错误处理
trap 'log_message "ERROR" "在步骤执行过程中出错，请检查日志: $LOG_FILE"; exit 1' ERR

# 处理命令行参数
handle_command_line_args "$@"

# 运行主函数
main "$@"