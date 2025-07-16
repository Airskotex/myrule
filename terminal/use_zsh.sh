#!/bin/bash

# ================================================================
# Zsh 环境自动配置脚本 v2.0
# 优化版本：增强错误处理、性能优化、回滚机制
# ================================================================

# 启用严格的错误处理
set -euo pipefail
trap 'error_handler $? $LINENO "$BASH_COMMAND"' ERR

# 全局变量
SCRIPT_VERSION="2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$HOME/.zsh_install_$(date +%Y%m%d_%H%M%S).log"
ROLLBACK_DIR="$HOME/.zsh_install_rollback"
PARALLEL_JOBS=4

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# ================================================================
# 日志和输出函数
# ================================================================

# 带时间戳的日志函数
log() {
    local level="$1"
    local message="$2"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local color=""
    
    case "$level" in
        "INFO") color="$GREEN" ;;
        "WARN") color="$YELLOW" ;;
        "ERROR") color="$RED" ;;
        "DEBUG") color="$BLUE" ;;
    esac
    
    # 输出到终端
    echo -e "${color}[$timestamp] [$level]${NC} $message"
    # 写入日志文件
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

log_info() { log "INFO" "$1"; }
log_warn() { log "WARN" "$1"; }
log_error() { log "ERROR" "$1"; }
log_debug() { log "DEBUG" "$1"; }

# 进度条显示
show_progress() {
    local current=$1
    local total=$2
    local width=50
    local progress=$((current * width / total))
    
    printf "\r["
    printf "%${progress}s" | tr ' ' '='
    printf "%$((width - progress))s" | tr ' ' ' '
    printf "] %d%%" $((current * 100 / total))
}

# ================================================================
# 错误处理和回滚机制
# ================================================================

# 错误处理函数
error_handler() {
    local exit_code=$1
    local line_no=$2
    local bash_command=$3
    
    log_error "命令失败 (退出码: $exit_code)"
    log_error "错误位置: 第 $line_no 行"
    log_error "失败命令: $bash_command"
    
    # 询问是否回滚
    read -p "是否执行回滚操作？[y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rollback
    fi
    
    exit $exit_code
}

# 创建回滚点
create_rollback_point() {
    local item="$1"
    local backup_path="$ROLLBACK_DIR/$(basename "$item").$(date +%s)"
    
    mkdir -p "$ROLLBACK_DIR"
    
    if [ -e "$item" ]; then
        cp -r "$item" "$backup_path"
        echo "$item:$backup_path" >> "$ROLLBACK_DIR/manifest"
        log_debug "创建回滚点: $item -> $backup_path"
    fi
}

# 执行回滚
rollback() {
    log_warn "开始执行回滚操作..."
    
    if [ ! -f "$ROLLBACK_DIR/manifest" ]; then
        log_warn "没有找到回滚信息"
        return
    fi
    
    while IFS=: read -r original backup; do
        if [ -f "$backup" ] || [ -d "$backup" ]; then
            log_info "恢复: $original"
            rm -rf "$original"
            mv "$backup" "$original"
        fi
    done < "$ROLLBACK_DIR/manifest"
    
    rm -rf "$ROLLBACK_DIR"
    log_info "回滚完成"
}

# ================================================================
# 系统检查函数
# ================================================================

# 检查操作系统
check_os() {
    if [[ "$OSTYPE" != "linux-gnu"* ]]; then
        log_error "此脚本仅支持 Linux 系统"
        log_error "当前系统: $OSTYPE"
        exit 1
    fi
    
    # 检查发行版
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        log_info "操作系统: $NAME $VERSION"
    fi
}

# 检查包管理器
check_package_manager() {
    if ! command -v apt &> /dev/null; then
        log_error "未找到 apt 包管理器"
        log_error "此脚本需要基于 Debian/Ubuntu 的系统"
        exit 1
    fi
}

# 检查网络连接
check_network() {
    log_info "检查网络连接..."
    
    local test_sites=("github.com" "raw.githubusercontent.com")
    local failed=0
    
    for site in "${test_sites[@]}"; do
        if ! ping -c 1 -W 3 "$site" &> /dev/null; then
            log_warn "无法连接到 $site"
            ((failed++))
        fi
    done
    
    if [ $failed -eq ${#test_sites[@]} ]; then
        log_error "网络连接失败，请检查网络设置"
        exit 1
    fi
}

# 检查命令是否存在（优化版）
command_exists() {
    command -v "$1" &> /dev/null
}

# 检查是否已安装（通用函数）
is_installed() {
    local check_type="$1"
    local check_target="$2"
    
    case "$check_type" in
        "dir") [ -d "$check_target" ] ;;
        "file") [ -f "$check_target" ] ;;
        "cmd") command_exists "$check_target" ;;
        "pkg") dpkg -l | grep -q "^ii  $check_target " ;;
    esac
}

# ================================================================
# 安装函数
# ================================================================

# 安装系统包
install_packages() {
    log_info "检查并安装必要的软件包..."
    
    local packages=("zsh" "git" "curl" "wget" "fonts-powerline" "fzf" "bat" "parallel")
    local to_install=()
    
    for pkg in "${packages[@]}"; do
        if ! is_installed "pkg" "$pkg"; then
            to_install+=("$pkg")
        else
            log_debug "$pkg 已安装"
        fi
    done
    
    if [ ${#to_install[@]} -gt 0 ]; then
        log_info "需要安装的包: ${to_install[*]}"
        
        # 更新包列表
        log_info "更新包列表..."
        sudo apt update || {
            log_error "无法更新包列表"
            exit 1
        }
        
        # 安装包
        log_info "安装软件包..."
        sudo apt install -y "${to_install[@]}" || {
            log_error "软件包安装失败"
            exit 1
        }
    else
        log_info "所有必要软件包已安装"
    fi
}

# 安装 Oh My Zsh
install_oh_my_zsh() {
    if [ -d "$HOME/.oh-my-zsh" ]; then
        log_warn "Oh My Zsh 已安装"
        
        # 提供更新选项
        read -p "是否更新 Oh My Zsh？[y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "更新 Oh My Zsh..."
            cd "$HOME/.oh-my-zsh" && git pull
        fi
    else
        log_info "安装 Oh My Zsh..."
        create_rollback_point "$HOME/.oh-my-zsh"
        create_rollback_point "$HOME/.zshrc"
        
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended || {
            log_error "Oh My Zsh 安装失败"
            exit 1
        }
    fi
}

# 安装主题
install_theme() {
    local P10K_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
    
    if [ -d "$P10K_DIR" ]; then
        log_warn "Powerlevel10k 已安装"
        
        read -p "是否更新 Powerlevel10k？[y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "更新 Powerlevel10k..."
            cd "$P10K_DIR" && git pull
        fi
    else
        log_info "安装 Powerlevel10k..."
        create_rollback_point "$P10K_DIR"
        
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_DIR" || {
            log_error "Powerlevel10k 安装失败"
            exit 1
        }
    fi
}

# 通用插件安装函数
install_plugin() {
    local plugin_name="$1"
    local plugin_url="$2"
    local plugin_dir="${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/$plugin_name"
    
    if [ -d "$plugin_dir" ]; then
        log_debug "$plugin_name 插件已安装"
        return 0
    else
        log_info "安装 $plugin_name 插件..."
        create_rollback_point "$plugin_dir"
        
        git clone "$plugin_url" "$plugin_dir" || {
            log_error "$plugin_name 插件安装失败"
            return 1
        }
    fi
}

# 批量安装插件
install_plugins() {
    log_info "安装 Zsh 插件..."
    
    local plugins=(
        "zsh-syntax-highlighting|https://github.com/zsh-users/zsh-syntax-highlighting.git"
        "zsh-autosuggestions|https://github.com/zsh-users/zsh-autosuggestions"
        "fzf-tab|https://github.com/Aloxaf/fzf-tab"
    )
    
    local total=${#plugins[@]}
    local current=0
    
    for plugin_info in "${plugins[@]}"; do
        IFS='|' read -r name url <<< "$plugin_info"
        install_plugin "$name" "$url"
        ((current++))
        show_progress $current $total
    done
    echo # 换行
}

# 并行下载字体
install_fonts() {
    log_info "安装 Nerd 字体..."
    
    local FONT_DIR="$HOME/.local/share/fonts"
    mkdir -p "$FONT_DIR"
    
    local fonts=(
        "https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Regular.ttf"
        "https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold.ttf"
        "https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Italic.ttf"
        "https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold%20Italic.ttf"
    )
    
    # 创建下载函数
    download_font() {
        local url="$1"
        local filename=$(basename "$url" | sed 's/%20/ /g')
        local filepath="$FONT_DIR/$filename"
        
        if [ ! -f "$filepath" ]; then
            log_debug "下载: $filename"
            wget -q "$url" -O "$filepath" || {
                log_error "下载失败: $filename"
                rm -f "$filepath"
            }
        fi
    }
    
    # 导出函数以供并行使用
    export -f download_font log_debug log_error
    export FONT_DIR LOG_FILE
    
    # 并行下载
    if command_exists parallel; then
        printf "%s\n" "${fonts[@]}" | parallel -j $PARALLEL_JOBS download_font
    else
        # 降级到串行下载
        for font_url in "${fonts[@]}"; do
            download_font "$font_url"
        done
    fi
    
    # 更新字体缓存
    log_info "更新字体缓存..."
    fc-cache -f
}

# ================================================================
# 配置函数
# ================================================================

# 备份文件（带时间戳）
backup_file() {
    local file="$1"
    local backup_dir="$HOME/.config/zsh_backups"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$backup_dir/$(basename "$file").backup.$timestamp"
    
    if [ -f "$file" ]; then
        mkdir -p "$backup_dir"
        cp "$file" "$backup_file"
        log_info "已备份: $file -> $backup_file"
        
        # 保留最近5个备份
        ls -t "$backup_dir"/$(basename "$file").backup.* 2>/dev/null | tail -n +6 | xargs -r rm
    fi
}

# 配置 .zshrc
configure_zshrc() {
    log_info "配置 .zshrc..."
    
    # 备份原始文件
    backup_file "$HOME/.zshrc"
    create_rollback_point "$HOME/.zshrc"
    
    # 配置主题
    if ! grep -q "ZSH_THEME=\"powerlevel10k/powerlevel10k\"" "$HOME/.zshrc"; then
        log_info "设置 Powerlevel10k 主题..."
        sed -i 's/ZSH_THEME=".*"/ZSH_THEME="powerlevel10k\/powerlevel10k"/' "$HOME/.zshrc"
    fi
    
    # 配置插件
    if ! grep -q "zsh-syntax-highlighting" "$HOME/.zshrc"; then
        log_info "配置插件..."
        sed -i '/^plugins=/c\plugins=(\n    git\n    fzf-tab\n    zsh-autosuggestions\n    zsh-syntax-highlighting\n)' "$HOME/.zshrc"
    fi
    
    # 添加自定义配置
    add_custom_config
}

# 添加自定义配置
add_custom_config() {
    local marker="# === CUSTOM ZSH CONFIG V2 ==="
    
    if ! grep -q "$marker" "$HOME/.zshrc"; then
        log_info "添加自定义配置..."
        cat >> "$HOME/.zshrc" << 'EOF'

# === CUSTOM ZSH CONFIG V2 ===
# 生成时间: $(date)

# 性能优化
zmodload zsh/zprof 2>/dev/null  # 性能分析（需要时取消注释）

# fzf-tab 配置
zstyle ':completion:*:git-checkout:*' sort false
zstyle ':completion:*:descriptions' format '[%d]'
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls -1 --color=always $realpath 2>/dev/null || echo "无法预览"'
zstyle ':fzf-tab:complete:kill:argument-rest' fzf-preview 'ps aux | grep $word'

# 历史记录优化
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt EXTENDED_HISTORY          # 记录时间戳
setopt HIST_EXPIRE_DUPS_FIRST    # 删除重复历史时优先删除旧的
setopt HIST_IGNORE_DUPS          # 忽略重复命令
setopt HIST_IGNORE_SPACE         # 忽略空格开头的命令
setopt HIST_VERIFY               # 历史展开后不立即执行
setopt SHARE_HISTORY             # 共享历史

# 彩色输出别名
alias ls='ls --color=auto'
alias ll='ls -lh'
alias la='ls -lah'
alias grep='grep --color=auto'
alias diff='diff --color=auto'

# 目录导航
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias ~='cd ~'
alias -- -='cd -'

# 安全别名
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -i'
alias ln='ln -i'

# 实用别名
alias mkdir='mkdir -pv'
alias df='df -h'
alias du='du -h'
alias free='free -h'
alias ps='ps auxf'
alias psg='ps aux | grep -v grep | grep -i -e VSZ -e'
alias myip='curl -s ifconfig.me'
alias ports='netstat -tulanp 2>/dev/null || ss -tulanp'

# bat 配置（如果存在）
if command -v batcat &> /dev/null; then
    alias cat='batcat'
    alias bat='batcat'
    export BAT_THEME="TwoDark"
fi

# 自定义函数
# 创建目录并进入
mkcd() {
    mkdir -p "$@" && cd "$_"
}

# 解压任意压缩文件
extract() {
    if [ -f "$1" ]; then
        case "$1" in
            *.tar.bz2)   tar xjf "$1"     ;;
            *.tar.gz)    tar xzf "$1"     ;;
            *.bz2)       bunzip2 "$1"     ;;
            *.rar)       unrar e "$1"     ;;
            *.gz)        gunzip "$1"      ;;
            *.tar)       tar xf "$1"      ;;
            *.tbz2)      tar xjf "$1"     ;;
            *.tgz)       tar xzf "$1"     ;;
            *.zip)       unzip "$1"       ;;
            *.Z)         uncompress "$1"  ;;
            *.7z)        7z x "$1"        ;;
            *)           echo "'$1' 无法解压" ;;
        esac
    else
        echo "'$1' 不是有效的文件"
    fi
}

# 快速查找文件
ff() {
    find . -type f -iname "*$1*" 2>/dev/null
}

# 快速查找目录
fd() {
    find . -type d -iname "*$1*" 2>/dev/null
}

# === END CUSTOM CONFIG ===
EOF
    else
        log_warn "自定义配置已存在"
    fi
}

# 设置默认 Shell
set_default_shell() {
    local current_shell=$(basename "$SHELL")
    
    if [ "$current_shell" != "zsh" ]; then
        log_info "设置 Zsh 为默认 Shell..."
        
        # 确保 zsh 在 /etc/shells 中
        if ! grep -q "$(command -v zsh)" /etc/shells; then
            log_warn "将 zsh 添加到 /etc/shells"
            echo "$(command -v zsh)" | sudo tee -a /etc/shells
        fi
        
        if chsh -s "$(command -v zsh)"; then
            log_info "默认 Shell 已更改为 Zsh"
        else
            log_error "无法更改默认 Shell，请手动运行: chsh -s $(command -v zsh)"
        fi
    else
        log_info "Zsh 已经是默认 Shell"
    fi
}

# ================================================================
# 清理函数
# ================================================================

cleanup() {
    log_info "清理临时文件..."
    
    # 清理旧的日志文件（保留最近7天）
    find "$HOME" -name ".zsh_install_*.log" -mtime +7 -delete 2>/dev/null || true
    
    # 清理回滚目录（如果安装成功）
    if [ -d "$ROLLBACK_DIR" ] && [ -z "${ROLLBACK_KEEP:-}" ]; then
        rm -rf "$ROLLBACK_DIR"
    fi
}

# ================================================================
# 主函数
# ================================================================

show_banner() {
    echo -e "${PURPLE}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║     Zsh 环境自动配置脚本 v$SCRIPT_VERSION              ║"
    echo "║     Enhanced with Oh My Zsh & Powerlevel10k ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

show_summary() {
    echo -e "\n${GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              安装完成！                      ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
    
    echo -e "\n${YELLOW}已安装组件：${NC}"
    echo "  ✓ Zsh Shell"
    echo "  ✓ Oh My Zsh 框架"
    echo "  ✓ Powerlevel10k 主题"
    echo "  ✓ 语法高亮插件"
    echo "  ✓ 自动建议插件"
    echo "  ✓ FZF Tab 补全"
    echo "  ✓ MesloLGS NF 字体"
    
    echo -e "\n${YELLOW}后续步骤：${NC}"
    echo "1. 重启终端或运行: ${GREEN}exec zsh${NC}"
    echo "2. 首次启动会运行 Powerlevel10k 配置向导"
    echo "3. 在终端设置中将字体改为: ${GREEN}MesloLGS NF${NC}"
    
    echo -e "\n${YELLOW}实用命令：${NC}"
    echo "• 重新配置主题: ${GREEN}p10k configure${NC}"
    echo "• 更新 Oh My Zsh: ${GREEN}omz update${NC}"
    echo "• 查看安装日志: ${GREEN}cat $LOG_FILE${NC}"
}

main() {
    # 显示横幅
    show_banner
    
    # 开始记录
    log_info "开始安装 (版本: $SCRIPT_VERSION)"
    log_info "日志文件: $LOG_FILE"
    
    # 系统检查
    log_info "=== 系统检查 ==="
    check_os
    check_package_manager
    check_network
    
    # 安装过程
    log_info "=== 开始安装 ==="
    install_packages
    install_oh_my_zsh
    install_theme
    install_plugins
    install_fonts
    
    # 配置
    log_info "=== 配置环境 ==="
    configure_zshrc
    set_default_shell
    
    # 清理
    cleanup
    
    # 显示总结
    show_summary
    
    log_info "安装脚本执行完成"
}

# ================================================================
# 脚本入口
# ================================================================

# 处理命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --rollback)
            rollback
            exit 0
            ;;
        --keep-rollback)
            ROLLBACK_KEEP=1
            shift
            ;;
        --debug)
            set -x
            shift
            ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo "选项:"
            echo "  --rollback      执行回滚操作"
            echo "  --keep-rollback 保留回滚文件"
            echo "  --debug         启用调试模式"
            echo "  --help, -h      显示此帮助"
            exit 0
            ;;
        *)
            log_error "未知选项: $1"
            exit 1
            ;;
    esac
done

# 检查是否以 root 运行
if [ "$EUID" -eq 0 ]; then
    log_error "请不要使用 root 用户运行此脚本"
    exit 1
fi

# 执行主函数
main
