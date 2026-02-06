#!/bin/bash

#====================================================
# 并行下载加速工具安装脚本
# 支持: Ubuntu, Debian, CentOS, Fedora, Arch, openSUSE
# 工具: aria2, apt-fast (Debian系)
#====================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# 检测操作系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
        OS_LIKE=$ID_LIKE
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
    elif [ -f /etc/debian_version ]; then
        OS="debian"
    elif [ -f /etc/arch-release ]; then
        OS="arch"
    else
        OS=$(uname -s)
    fi
    
    log_info "检测到操作系统: $OS $VERSION"
}

# 检查是否为 root 用户
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 权限运行此脚本 (sudo $0)"
        exit 1
    fi
}

# 安装 aria2
install_aria2() {
    log_step "正在安装 aria2..."
    
    case $OS in
        ubuntu|debian|linuxmint|pop)
            apt-get update
            apt-get install -y aria2
            ;;
        centos|rhel|rocky|almalinux)
            if [ "${VERSION%%.*}" -ge 8 ]; then
                dnf install -y epel-release
                dnf install -y aria2
            else
                yum install -y epel-release
                yum install -y aria2
            fi
            ;;
        fedora)
            dnf install -y aria2
            ;;
        arch|manjaro|endeavouros)
            pacman -Sy --noconfirm aria2
            ;;
        opensuse*|sles)
            zypper install -y aria2
            ;;
        alpine)
            apk add aria2
            ;;
        *)
            log_error "不支持的操作系统: $OS"
            return 1
            ;;
    esac
    
    log_info "aria2 安装完成!"
}

# 安装 apt-fast (仅 Debian 系)
install_apt_fast() {
    case $OS in
        ubuntu|linuxmint|pop)
            log_step "正在安装 apt-fast (Ubuntu/衍生版)..."
            
            # 安装依赖
            apt-get install -y software-properties-common
            
            # 添加 PPA
            add-apt-repository -y ppa:apt-fast/stable
            apt-get update
            
            # 非交互式安装 apt-fast
            DEBIAN_FRONTEND=noninteractive apt-get install -y apt-fast
            
            log_info "apt-fast 安装完成!"
            ;;
        debian)
            log_step "正在安装 apt-fast (Debian)..."
            
            # Debian 需要手动安装
            apt-get install -y git
            
            if [ -d "/tmp/apt-fast" ]; then
                rm -rf /tmp/apt-fast
            fi
            
            git clone https://github.com/ilikenwf/apt-fast.git /tmp/apt-fast
            cp /tmp/apt-fast/apt-fast /usr/local/sbin/
            chmod +x /usr/local/sbin/apt-fast
            cp /tmp/apt-fast/apt-fast.conf /etc/
            
            # 添加 bash 补全
            cp /tmp/apt-fast/completions/bash/apt-fast /etc/bash_completion.d/
            
            rm -rf /tmp/apt-fast
            
            log_info "apt-fast 安装完成!"
            ;;
        *)
            log_warn "apt-fast 仅支持 Debian/Ubuntu 系发行版，跳过安装"
            return 0
            ;;
    esac
}

# 配置 aria2
configure_aria2() {
    log_step "正在配置 aria2..."
    
    # 创建配置目录
    ARIA2_CONF_DIR="$HOME/.aria2"
    mkdir -p "$ARIA2_CONF_DIR"
    
    # 创建会话文件
    touch "$ARIA2_CONF_DIR/aria2.session"
    
    # 创建配置文件
    cat > "$ARIA2_CONF_DIR/aria2.conf" << 'EOF'
#====================================================
# aria2 配置文件
#====================================================

# 基本设置
dir=${HOME}/Downloads
continue=true
max-concurrent-downloads=5
max-connection-per-server=16
min-split-size=1M
split=16

# 下载速度限制 (0 表示不限制)
max-overall-download-limit=0
max-download-limit=0

# 磁盘缓存
disk-cache=64M

# 文件预分配 (none, prealloc, trunc, falloc)
file-allocation=falloc

# 自动保存会话间隔 (秒)
save-session-interval=60

# HTTP/FTP 设置
connect-timeout=60
timeout=60
max-tries=5
retry-wait=10

# BT 设置
enable-dht=true
enable-dht6=true
bt-enable-lpd=true
enable-peer-exchange=true
bt-max-peers=100

# 用户代理
user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36

# 日志设置
log-level=notice
console-log-level=notice
EOF
    
    log_info "aria2 配置文件已创建: $ARIA2_CONF_DIR/aria2.conf"
}

# 配置 apt-fast
configure_apt_fast() {
    if [ ! -f /etc/apt-fast.conf ]; then
        log_warn "apt-fast 配置文件不存在，跳过配置"
        return 0
    fi
    
    log_step "正在优化 apt-fast 配置..."
    
    # 备份原配置
    cp /etc/apt-fast.conf /etc/apt-fast.conf.bak
    
    # 修改配置
    sed -i 's/^_MAXNUM=.*/_MAXNUM=16/' /etc/apt-fast.conf
    sed -i 's/^_MAXCONPERSRV=.*/_MAXCONPERSRV=16/' /etc/apt-fast.conf
    sed -i 's/^_SPLITCON=.*/_SPLITCON=16/' /etc/apt-fast.conf
    sed -i 's/^_MINSPLITSZ=.*/_MINSPLITSZ=1M/' /etc/apt-fast.conf
    
    log_info "apt-fast 配置优化完成!"
}

# 为非 Debian 系安装包管理加速工具
install_package_manager_wrapper() {
    case $OS in
        fedora|centos|rhel|rocky|almalinux)
            log_step "正在配置 dnf 并行下载..."
            
            # dnf 原生支持并行下载，修改配置即可
            if grep -q "^max_parallel_downloads" /etc/dnf/dnf.conf; then
                sed -i 's/^max_parallel_downloads=.*/max_parallel_downloads=10/' /etc/dnf/dnf.conf
            else
                echo "max_parallel_downloads=10" >> /etc/dnf/dnf.conf
            fi
            
            # 启用 fastestmirror
            if grep -q "^fastestmirror" /etc/dnf/dnf.conf; then
                sed -i 's/^fastestmirror=.*/fastestmirror=True/' /etc/dnf/dnf.conf
            else
                echo "fastestmirror=True" >> /etc/dnf/dnf.conf
            fi
            
            log_info "dnf 并行下载配置完成!"
            ;;
        arch|manjaro|endeavouros)
            log_step "正在配置 pacman 并行下载..."
            
            # 启用 pacman 并行下载
            if grep -q "^#ParallelDownloads" /etc/pacman.conf; then
                sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
            elif ! grep -q "^ParallelDownloads" /etc/pacman.conf; then
                sed -i '/^\[options\]/a ParallelDownloads = 10' /etc/pacman.conf
            fi
            
            log_info "pacman 并行下载配置完成!"
            ;;
    esac
}

# 创建实用别名
create_aliases() {
    log_step "正在创建实用命令别名..."
    
    ALIAS_FILE="$HOME/.aria2_aliases"
    
    cat > "$ALIAS_FILE" << 'EOF'
# aria2 快捷命令别名
alias dl='aria2c'
alias dlx='aria2c -x16 -s16 -k1M'
alias dlbt='aria2c --seed-time=0'
alias dlm='aria2c -i'  # 从文件读取下载链接

# 快速下载函数
fastdl() {
    aria2c -x16 -s16 -k1M --file-allocation=falloc "$@"
}

# 批量下载函数
batchdl() {
    if [ -f "$1" ]; then
        aria2c -x16 -s16 -k1M -i "$1"
    else
        echo "用法: batchdl <url_list_file>"
    fi
}
EOF
    
    # 添加到 shell 配置文件
    for rc_file in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [ -f "$rc_file" ]; then
            if ! grep -q "aria2_aliases" "$rc_file"; then
                echo "" >> "$rc_file"
                echo "# aria2 快捷命令" >> "$rc_file"
                echo "[ -f $ALIAS_FILE ] && source $ALIAS_FILE" >> "$rc_file"
            fi
        fi
    done
    
    log_info "别名已创建，请运行 'source ~/.bashrc' 或重新登录以生效"
}

# 显示使用帮助
show_usage() {
    echo ""
    echo "========================================"
    echo "       安装完成！使用指南"
    echo "========================================"
    echo ""
    echo "📦 aria2 使用示例:"
    echo "   aria2c URL                    # 普通下载"
    echo "   aria2c -x16 -s16 URL          # 16线程高速下载"
    echo "   aria2c -c URL                 # 断点续传"
    echo "   aria2c -i urls.txt            # 批量下载"
    echo ""
    
    case $OS in
        ubuntu|debian|linuxmint|pop)
            echo "📦 apt-fast 使用示例:"
            echo "   apt-fast update              # 更新软件源"
            echo "   apt-fast upgrade             # 升级系统"
            echo "   apt-fast install <pkg>       # 安装软件"
            echo ""
            ;;
        fedora|centos|rhel|rocky|almalinux)
            echo "📦 dnf 已配置并行下载 (10个连接)"
            echo ""
            ;;
        arch|manjaro|endeavouros)
            echo "📦 pacman 已配置并行下载 (10个连接)"
            echo ""
            ;;
    esac
    
    echo "🚀 快捷命令 (需要 source ~/.bashrc):"
    echo "   dlx URL                       # 16线程快速下载"
    echo "   fastdl URL                    # 快速下载函数"
    echo "   batchdl urls.txt              # 批量下载"
    echo ""
    echo "📁 配置文件位置:"
    echo "   aria2:    ~/.aria2/aria2.conf"
    [ -f /etc/apt-fast.conf ] && echo "   apt-fast: /etc/apt-fast.conf"
    echo ""
}

# 主函数
main() {
    echo ""
    echo "╔════════════════════════════════════════════╗"
    echo "║   Linux 并行下载加速工具 - 一键安装脚本   ║"
    echo "╚════════════════════════════════════════════╝"
    echo ""
    
    check_root
    detect_os
    
    echo ""
    read -p "是否继续安装？[Y/n] " confirm
    confirm=${confirm:-Y}
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_warn "安装已取消"
        exit 0
    fi
    
    echo ""
    
    # 安装工具
    install_aria2
    install_apt_fast
    install_package_manager_wrapper
    
    # 配置工具
    configure_aria2
    configure_apt_fast
    
    # 创建别名
    create_aliases
    
    # 显示帮助
    show_usage
    
    log_info "🎉 所有安装和配置已完成！"
}

# 运行主函数
main "$@"
