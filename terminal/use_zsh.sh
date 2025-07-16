#!/bin/bash

# ================================================================
# Zsh 环境自动配置脚本 v3.2 (修复版)
# 支持：Debian/Ubuntu (apt)、RHEL/CentOS (yum/dnf)、macOS (brew)
# ================================================================

# 启用严格的错误处理
set -euo pipefail
trap 'error_handler $? $LINENO "$BASH_COMMAND"' ERR

# 全局变量
SCRIPT_VERSION="3.2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  
IS_ROOT=$([[ $EUID -eq 0 ]] && echo "true" || echo "false")
LOG_FILE="$HOME/.zsh_install_$(date +%Y%m%d_%H%M%S).log"
PACKAGE_MANAGER=""
OS_TYPE=""
SKIP_USERS=("nobody" "systemd-network" "systemd-resolve" "daemon" "bin" "sys")

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
    
    # 使用 printf 避免日志格式问题
    printf "${color}[%s] [%s]${NC} %s\n" "$timestamp" "$level" "$message"
    printf "[%s] [%s] %s\n" "$timestamp" "$level" "$message" >> "$LOG_FILE" 2>/dev/null || true
}

log_info() { log "INFO" "$1"; }
log_warn() { log "WARN" "$1"; }
log_error() { log "ERROR" "$1"; }
log_debug() { log "DEBUG" "$1"; }

# 错误处理
error_handler() {
    local exit_code=$1
    local line_no=$2
    local bash_command=$3
    
    log_error "命令失败 (退出码: $exit_code)"
    log_error "错误位置: 第 $line_no 行"
    log_error "失败命令: $bash_command"
    
    exit $exit_code
}

# ================================================================
# 系统检测函数
# ================================================================

# 检测操作系统类型
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS_TYPE="macos"
        log_info "检测到系统: macOS"
    elif [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_TYPE="linux"
        log_info "检测到系统: $NAME $VERSION"
    else
        log_error "无法识别的操作系统"
        exit 1
    fi
}

# 检测包管理器
detect_package_manager() {
    log_info "检测包管理器..."
    
    if [[ "$OS_TYPE" == "macos" ]]; then
        if command -v brew &> /dev/null; then
            PACKAGE_MANAGER="brew"
        else
            log_error "macOS 系统需要先安装 Homebrew"
            log_info "请访问 https://brew.sh 安装 Homebrew"
            exit 1
        fi
    elif command -v apt &> /dev/null; then
        PACKAGE_MANAGER="apt"
    elif command -v dnf &> /dev/null; then
        PACKAGE_MANAGER="dnf"
    elif command -v yum &> /dev/null; then
        PACKAGE_MANAGER="yum"
    else
        log_error "未找到支持的包管理器 (apt/yum/dnf/brew)"
        exit 1
    fi
    
    log_info "使用包管理器: $PACKAGE_MANAGER"
}

# 检查命令是否存在
command_exists() {
    command -v "$1" &> /dev/null
}

# ================================================================
# 包管理器操作函数
# ================================================================

# 更新包索引
update_package_index() {
    log_info "更新包索引..."
    
    case "$PACKAGE_MANAGER" in
        apt)
            if [ "$IS_ROOT" = "true" ]; then
                apt update
            else
                sudo apt update
            fi
            ;;
        yum|dnf)
            # yum/dnf 通常不需要手动更新索引
            :
            ;;
        brew)
            brew update
            ;;
    esac
}

# 安装单个包
install_package() {
    local package="$1"
    
    case "$PACKAGE_MANAGER" in
        apt)
            if [ "$IS_ROOT" = "true" ]; then
                apt install -y "$package"
            else
                sudo apt install -y "$package"
            fi
            ;;
        yum)
            if [ "$IS_ROOT" = "true" ]; then
                yum install -y "$package"
            else
                sudo yum install -y "$package"
            fi
            ;;
        dnf)
            if [ "$IS_ROOT" = "true" ]; then
                dnf install -y "$package"
            else
                sudo dnf install -y "$package"
            fi
            ;;
        brew)
            brew install "$package"
            ;;
    esac
}

# 检查包是否已安装
is_package_installed() {
    local package="$1"
    
    case "$PACKAGE_MANAGER" in
        apt)
            dpkg -l 2>/dev/null | grep -q "^ii  $package " || dpkg -l 2>/dev/null | grep -q "^ii  $package:"  
            ;;
        yum|dnf)
            rpm -q "$package" &> /dev/null
            ;;
        brew)
            brew list "$package" &> /dev/null
            ;;
    esac
}

# ================================================================
# 安装函数
# ================================================================

# 获取包名称映射
get_package_name() {
    local generic_name="$1"
    
    case "$generic_name" in
        "bat")
            case "$PACKAGE_MANAGER" in
                apt) echo "bat" ;;
                yum|dnf) echo "bat" ;;
                brew) echo "bat" ;;
                *) echo "" ;;
            esac
            ;;
        "fzf")
            echo "fzf"  # 所有支持的包管理器都使用相同名称
            ;;
        "fonts-powerline")
            case "$PACKAGE_MANAGER" in
                apt) echo "fonts-powerline" ;;
                yum|dnf) echo "powerline-fonts" ;;
                brew) echo "" ;;  # macOS 通过其他方式安装字体
                *) echo "" ;;
            esac
            ;;
        "fontconfig")
            case "$PACKAGE_MANAGER" in
                apt|yum|dnf) echo "fontconfig" ;;
                brew) echo "" ;;  # macOS 不需要
                *) echo "" ;;
            esac
            ;;
        *)
            echo "$generic_name"  # 默认返回原名称
            ;;
    esac
}

# 安装必要的软件包
install_system_packages() {
    log_info "检查并安装必要的软件包..."
    
    # 定义需要的包
    local generic_packages=("zsh" "git" "curl" "wget" "fonts-powerline" "fzf" "batcat" "bat" "fontconfig")              
    local to_install=()
    
    # 检查每个包
    for generic_pkg in "${generic_packages[@]}"; do
        local actual_pkg=$(get_package_name "$generic_pkg")
        
        if [ -n "$actual_pkg" ]; then
            if ! is_package_installed "$actual_pkg" && ! command_exists "${generic_pkg%%-*}"; then
                to_install+=("$actual_pkg")
            else
                log_debug "$actual_pkg 已安装"
            fi
        fi
    done
    
    # 安装缺失的包
    if [ ${#to_install[@]} -gt 0 ]; then
        log_info "需要安装的包: ${to_install[*]}"
        update_package_index
        
        for pkg in "${to_install[@]}"; do
            log_info "安装 $pkg..."
            if ! install_package "$pkg"; then
                log_warn "无法安装 $pkg，继续..."
            fi
        done
    else
        log_info "所有必要软件包已安装"
    fi
}

# ================================================================
# 用户安装函数（修复版）
# ================================================================

# 获取所有需要配置的用户
get_target_users() {
    if [[ "$OS_TYPE" == "macos" ]]; then
        # macOS：只为当前用户安装
        echo "$USER:$HOME:$SHELL"
    elif [ "$IS_ROOT" = "true" ]; then
        # 先输出 root 用户
        echo "root:/root:/bin/bash"
        
        # 然后输出普通用户
        local min_uid=1000
        local max_uid=60000
        
        # 使用 awk 更可靠地解析 /etc/passwd
        awk -F: -v min=$min_uid -v max=$max_uid '
            $3 >= min && $3 <= max && 
            $6 != "" && 
            $7 !~ /(false|nologin)$/ {
                print $1":"$6":"$7
            }
        ' /etc/passwd | while read -r line; do
            local username="${line%%:*}"
            local skip=false
            
            # 检查是否在跳过列表中
            for skip_user in nobody systemd-network systemd-resolve daemon bin sys; do
                if [[ "$username" == "$skip_user" ]]; then
                    skip=true
                    break
                fi
            done
            
            [[ "$skip" == "false" ]] && echo "$line"
        done
    else
        # Linux 普通用户：只返回当前用户
        echo "$USER:$HOME:$SHELL"
    fi
}

# 检查网络连接（优化版）
check_network() {
    # 尝试多个地址以提高可靠性
    local test_urls=(
        "https://github.com"
        "https://raw.githubusercontent.com"
        "https://api.github.com"
    )
    
    for url in "${test_urls[@]}"; do
        if curl -fsS --connect-timeout 5 -o /dev/null "$url" 2>/dev/null; then
            return 0
        fi
    done
    
    return 1
}

# 为单个用户安装配置（修复版）
install_for_user() {
    local username="$1"
    local user_home="$2"
    local user_shell="$3"
    
    log_info "========================================="
    log_info "为用户 $username 配置 Zsh 环境"
    log_info "主目录: $user_home"
    log_info "========================================="
    
    # 检查用户主目录
    if [ ! -d "$user_home" ]; then
        log_warn "用户 $username 的主目录不存在，跳过"
        return
    fi
    
    # 创建用户安装脚本，正确传递变量
    local temp_script="/tmp/zsh_install_${username}_$$.sh"
    
    # 使用 printf 而不是 echo，并正确转义变量
    cat > "$temp_script" << USERSCRIPT
#!/bin/bash
set -euo pipefail

# 用户级别的安装脚本
# 设置变量
USERNAME="$username"
USER_HOME="$user_home"
export HOME="\$USER_HOME"
cd "\$HOME"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "\${GREEN}[INFO]\${NC} 开始为用户 \${USERNAME} 安装..."

# 检查网络连接
check_network() {
    local test_urls=(
        "https://github.com"
        "https://raw.githubusercontent.com"
    )
    
    for url in "\${test_urls[@]}"; do
        if curl -fsS --connect-timeout 5 -o /dev/null "\$url" 2>/dev/null; then
            return 0
        fi
    done
    
    return 1
}

if ! check_network; then
    echo -e "\${RED}[ERROR]\${NC} 无法连接到 GitHub"
    exit 1
fi

# 安装 Oh My Zsh
if [ ! -d "\$HOME/.oh-my-zsh" ]; then
    echo -e "\${GREEN}[INFO]\${NC} 安装 Oh My Zsh..."
    export RUNZSH=no
    export CHSH=no
    sh -c "\$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended || {
        echo -e "\${RED}[ERROR]\${NC} Oh My Zsh 安装失败"
        exit 1
    }
else
    echo -e "\${YELLOW}[WARN]\${NC} Oh My Zsh 已安装"
fi

# 安装 Powerlevel10k
P10K_DIR="\${ZSH_CUSTOM:-\$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
if [ ! -d "\$P10K_DIR" ]; then
    echo -e "\${GREEN}[INFO]\${NC} 安装 Powerlevel10k..."
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "\$P10K_DIR" || {
        echo -e "\${RED}[ERROR]\${NC} Powerlevel10k 安装失败"
        exit 1
    }
else
    echo -e "\${YELLOW}[WARN]\${NC} Powerlevel10k 已安装"
fi

# 安装插件函数
install_plugin() {
    local plugin_name="\$1"
    local plugin_url="\$2"
    local plugin_dir="\${ZSH_CUSTOM:-\$HOME/.oh-my-zsh/custom}/plugins/\$plugin_name"
    
    if [ ! -d "\$plugin_dir" ]; then
        echo -e "\${GREEN}[INFO]\${NC} 安装 \$plugin_name 插件..."
        git clone "\$plugin_url" "\$plugin_dir" || {
            echo -e "\${YELLOW}[WARN]\${NC} \$plugin_name 插件安装失败"
            return 1
        }
    else
        echo -e "\${YELLOW}[WARN]\${NC} \$plugin_name 插件已安装"
    fi
}

# 安装插件
install_plugin "zsh-syntax-highlighting" "https://github.com/zsh-users/zsh-syntax-highlighting.git"
install_plugin "zsh-autosuggestions" "https://github.com/zsh-users/zsh-autosuggestions"
install_plugin "fzf-tab" "https://github.com/Aloxaf/fzf-tab"

# 备份并创建新的 .zshrc
if [ -f "\$HOME/.zshrc" ]; then
    cp "\$HOME/.zshrc" "\$HOME/.zshrc.backup.\$(date +%Y%m%d_%H%M%S)"
fi

# 创建配置文件
cat > "\$HOME/.zshrc" << 'EOF'
# Path to oh-my-zsh installation
export ZSH="\$HOME/.oh-my-zsh"

# Set theme
ZSH_THEME="powerlevel10k/powerlevel10k"

# Plugins
plugins=(
    git
    fzf-tab
    zsh-autosuggestions
    zsh-syntax-highlighting
)

# Source oh-my-zsh
source \$ZSH/oh-my-zsh.sh

# === CUSTOM CONFIGURATION ===

# Enable Powerlevel10k instant prompt
if [[ -r "\${XDG_CACHE_HOME:-\$HOME/.cache}/p10k-instant-prompt-\${(%):-%n}.zsh" ]]; then
  source "\${XDG_CACHE_HOME:-\$HOME/.cache}/p10k-instant-prompt-\${(%):-%n}.zsh"
fi

# fzf-tab configuration
zstyle ':completion:*:git-checkout:*' sort false
zstyle ':completion:*:descriptions' format '[%d]'
zstyle ':completion:*' list-colors \${(s.:.)LS_COLORS}
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls -1 --color=always \$realpath 2>/dev/null || echo "No preview"'
zstyle ':fzf-tab:complete:kill:argument-rest' fzf-preview 'ps aux | grep \$word'

# History configuration
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt EXTENDED_HISTORY
setopt HIST_EXPIRE_DUPS_FIRST
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE
setopt HIST_VERIFY
setopt SHARE_HISTORY

# Aliases
alias ls='ls --color=auto'
alias ll='ls -lh'
alias la='ls -lah'
alias grep='grep --color=auto'
alias diff='diff --color=auto'

# Directory navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# Safety aliases
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -i'
alias ln='ln -i'

# Utility aliases
alias mkdir='mkdir -pv'
alias df='df -h'
alias du='du -h'
alias free='free -h'
alias ps='ps auxf'

# bat 配置（如果存在）
# 注意：在 Debian/Ubuntu 上，bat 命令实际是 batcat
if command -v batcat &> /dev/null; then
    alias cat='batcat'
    alias bat='batcat'
    export BAT_THEME="TwoDark"
elif command -v bat &> /dev/null; then
    alias cat='bat'
    export BAT_THEME="TwoDark"
fi

# Custom functions
mkcd() { mkdir -p "\$@" && cd "\$_"; }

extract() {
    if [ -f "\$1" ]; then
        case "\$1" in
            *.tar.bz2)   tar xjf "\$1"     ;;
            *.tar.gz)    tar xzf "\$1"     ;;
            *.bz2)       bunzip2 "\$1"     ;;
            *.rar)       unrar e "\$1"     ;;
            *.gz)        gunzip "\$1"      ;;
            *.tar)       tar xf "\$1"      ;;
            *.tbz2)      tar xjf "\$1"     ;;
            *.tgz)       tar xzf "\$1"     ;;
            *.zip)       unzip "\$1"       ;;
            *.Z)         uncompress "\$1"  ;;
            *.7z)        7z x "\$1"        ;;
            *)           echo "'\$1' cannot be extracted" ;;
        esac
    else
        echo "'\$1' is not a valid file"
    fi
}

# 快速查找文件
ff() {
    find . -type f -iname "*\$1*" 2>/dev/null
}

# 快速查找目录
fd() {
    find . -type d -iname "*\$1*" 2>/dev/null
}

# Load Powerlevel10k configuration
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# === END CUSTOM CONFIGURATION ===
EOF

# 安装字体
FONT_DIR="\$HOME/.local/share/fonts"
mkdir -p "\$FONT_DIR"

echo -e "\${GREEN}[INFO]\${NC} 安装 Nerd 字体..."
fonts=(
    "https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Regular.ttf"
    "https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold.ttf"
    "https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Italic.ttf"
    "https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold%20Italic.ttf"
)

for font_url in "\${fonts[@]}"; do
    font_name=\$(basename "\$font_url" | sed 's/%20/ /g')
    if [ ! -f "\$FONT_DIR/\$font_name" ]; then
        curl -fsSL "\$font_url" -o "\$FONT_DIR/\$font_name" || echo -e "\${YELLOW}[WARN]\${NC} 无法下载 \$font_name"
    fi
done

# 更新字体缓存
if command -v fc-cache &> /dev/null; then
    fc-cache -f "\$FONT_DIR" 2>/dev/null || true
fi

echo -e "\${GREEN}[INFO]\${NC} 用户 \${USERNAME} 的配置完成！"
USERSCRIPT

    # 设置脚本权限
    chmod +x "$temp_script"
    
    # 运行脚本
    if [ "$username" == "$USER" ] || ([ "$username" == "root" ] && [ "$IS_ROOT" == "true" ]); then
        # 当前用户直接运行
        bash "$temp_script"
    else
        # 其他用户使用 su 运行
        su - "$username" -c "bash $temp_script"
    fi
    
    # 清理
    rm -f "$temp_script"
    
    # 更改默认 shell
    if [[ "$user_shell" != */zsh ]]; then
        log_info "为用户 $username 设置默认 shell 为 zsh"
        
        local zsh_path=""
        if command_exists zsh; then
            zsh_path=$(command -v zsh)
        fi
        
        if [ -n "$zsh_path" ]; then
            if [[ "$OS_TYPE" == "macos" ]]; then
                # macOS 使用 chsh
                if [ "$username" == "$USER" ]; then
                    chsh -s "$zsh_path"
                fi
            elif [ "$IS_ROOT" = "true" ]; then
                usermod -s "$zsh_path" "$username"
            else
                if [ "$username" == "$USER" ]; then
                    chsh -s "$zsh_path"
                fi
            fi
        fi
    fi
}

# ================================================================
# 新用户模板配置（仅限Linux）
# ================================================================

setup_skel() {
    if [[ "$OS_TYPE" == "macos" ]] || [ "$IS_ROOT" != "true" ]; then
        return
    fi
    
    log_info "配置新用户默认模板..."
    
    # 创建自动配置脚本
    cat > /usr/local/bin/auto-setup-zsh << 'EOF'
#!/bin/bash
# 新用户首次登录自动配置脚本

if [ ! -d "$HOME/.oh-my-zsh" ] && [ -x /usr/bin/zsh ]; then
    echo "正在为您自动配置 Zsh 环境..."
    
    # 运行用户配置
    curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh | sh -s -- --unattended
    
    echo "配置完成！请重新登录以使用 Zsh。"
fi
EOF
    
    chmod +x /usr/local/bin/auto-setup-zsh
    
    # 在 /etc/skel/.bashrc 中添加自动运行
    if [ -f /etc/skel/.bashrc ] && ! grep -q "auto-setup-zsh" /etc/skel/.bashrc 2>/dev/null; then
        echo -e "\n# Auto setup zsh for new users\n[ -x /usr/local/bin/auto-setup-zsh ] && /usr/local/bin/auto-setup-zsh" >> /etc/skel/.bashrc
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
    
    echo -e "\n${YELLOW}系统信息：${NC}"
    echo "  • 操作系统: $OS_TYPE"
    echo "  • 包管理器: $PACKAGE_MANAGER"
    echo "  • 安装模式: $([ "$IS_ROOT" = "true" ] && echo "所有用户" || echo "当前用户")"
    
    echo -e "\n${YELLOW}已安装组件：${NC}"
    echo "  ✓ Zsh Shell"
    echo "  ✓ Oh My Zsh 框架"
    echo "  ✓ Powerlevel10k 主题"
    echo "  ✓ 语法高亮插件"
    echo "  ✓ 自动建议插件"
    echo "  ✓ FZF Tab 补全"
    echo "  ✓ MesloLGS NF 字体"
    if command_exists batcat || command_exists bat; then
        echo "  ✓ bat (彩色 cat)"
    fi
    
    echo -e "\n${YELLOW}后续步骤：${NC}"
    
    if [[ "$OS_TYPE" == "macos" ]]; then
        echo -e "1. 重启终端或运行: ${GREEN}exec zsh${NC}"
        echo -e "2. 首次使用 zsh 时会运行 Powerlevel10k 配置向导"
        echo -e "3. 在终端偏好设置中将字体改为: ${GREEN}MesloLGS NF${NC}"
    elif [ "$IS_ROOT" = "true" ]; then
        echo -e "1. 通知用户重新登录或运行: ${GREEN}exec zsh${NC}"
        echo -e "2. 首次使用 zsh 时会运行 Powerlevel10k 配置向导"
        echo -e "3. 提醒用户在终端中设置字体为: ${GREEN}MesloLGS NF${NC}"
    else
        echo -e "1. 重启终端或运行: ${GREEN}exec zsh${NC}"
        echo -e "2. 首次启动会运行 Powerlevel10k 配置向导"
        echo -e "3. 在终端设置中将字体改为: ${GREEN}MesloLGS NF${NC}"
    fi
    
    echo -e "\n${YELLOW}实用命令：${NC}"
    echo -e "• 重新配置主题: ${GREEN}p10k configure${NC}"
    echo -e "• 更新 Oh My Zsh: ${GREEN}omz update${NC}"
    
    # 特别提示 bat/batcat
    if command_exists batcat; then
        echo -e "• 彩色查看文件: ${GREEN}cat <file>${NC} 或 ${GREEN}batcat <file>${NC}"
    elif command_exists bat; then
        echo -e "• 彩色查看文件: ${GREEN}cat <file>${NC} 或 ${GREEN}bat <file>${NC}"
    fi
    
    echo -e "• 查看安装日志: ${GREEN}cat $LOG_FILE${NC}"
}

main() {
    # 显示横幅
    show_banner
    
    # 记录开始
    log_info "开始安装 (版本: $SCRIPT_VERSION)"
    log_info "运行用户: $(whoami) (UID: $EUID)"
    log_info "日志文件: $LOG_FILE"
    
    # 系统检测
    log_info "=== 系统检测 ==="
    detect_os
    detect_package_manager
    
    # 检查网络连接
    log_info "=== 网络检测 ==="
    if ! check_network; then
        log_error "无法连接到 GitHub，请检查网络连接"
        exit 1
    fi
    log_info "网络连接正常"
    
    # 安装系统包
    log_info "=== 安装系统包 ==="
    install_system_packages
    
    # 获取目标用户列表
    log_info "=== 用户配置 ==="
    
    # 调试：显示当前状态
    log_debug "IS_ROOT=$IS_ROOT, OS_TYPE=$OS_TYPE"
    
    # 获取用户列表（不使用 readarray）
    local users_temp_file="/tmp/zsh_users_$$"
    get_target_users > "$users_temp_file" 2>/dev/null
    
    # 计算用户数量
    local user_count=0
    if [ -f "$users_temp_file" ] && [ -s "$users_temp_file" ]; then
        user_count=$(wc -l < "$users_temp_file")
    fi
    
    if [ "$user_count" -eq 0 ]; then
        log_error "无法获取用户列表"
        rm -f "$users_temp_file"
        exit 1
    fi
    
    log_info "将为 $user_count 个用户进行配置"
    
    # 为每个用户安装
    while IFS= read -r user_info; do
        if [[ -n "$user_info" ]]; then
            # 解析用户信息
            IFS=: read -r username home shell <<< "$user_info"
            
            # 验证信息完整性
            if [[ -n "$username" && -n "$home" && -n "$shell" ]]; then
                log_debug "处理用户: $username"
                install_for_user "$username" "$home" "$shell"
            else
                log_warn "跳过无效的用户信息: $user_info"
            fi
        fi
    done < "$users_temp_file"
    
    # 清理临时文件
    rm -f "$users_temp_file"
    
    # 如果是Linux root，设置新用户模板
    if [ "$IS_ROOT" = "true" ] && [[ "$OS_TYPE" == "linux" ]]; then
        setup_skel
    fi
    
    # 显示总结
    show_summary
    
    log_info "所有操作完成！"
}

# ================================================================
# 脚本入口
# ================================================================

# 处理命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            echo "用法: $0 [选项]"
            echo ""
            echo "自动检测用户身份："
            echo "  • root用户：为所有用户安装"
            echo "  • 普通用户：仅为当前用户安装"
            echo ""
            echo "支持的系统："
            echo "  • Debian/Ubuntu (apt)"
            echo "  • RHEL/CentOS/Fedora (yum/dnf)"
            echo "  • macOS (brew)"
            echo ""
            echo "选项:"
            echo "  --help, -h      显示此帮助"
            exit 0
            ;;
        *)
            log_error "未知选项: $1"
            exit 1
            ;;
    esac
    shift
done

# 执行主函数
main
