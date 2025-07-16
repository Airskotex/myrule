#!/bin/bash
# ========================================
# Zsh 环境自动配置脚本 (国内优化版)
# 功能：自动安装配置 Oh My Zsh + Powerlevel10k + 插件
# 支持：自动检测国内服务器并使用代理加速
# ========================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# GitHub 代理地址配置
GITHUB_PROXY1="https://github.airskotex.nyc.mn/"
GITHUB_PROXY2="https://github.proxies.ip-ddns.com/"
CURRENT_PROXY=""

# 打印带颜色的消息
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# 检测是否为国内服务器
check_china_server() {
    print_message "$BLUE" "检测服务器位置..."
    
    # 方法1：通过检测能否快速访问国内特定网站
    if curl -s --connect-timeout 3 "http://www.baidu.com" > /dev/null 2>&1; then
        # 再检测 GitHub 访问速度
        if ! curl -s --connect-timeout 5 "https://github.com" > /dev/null 2>&1; then
            print_message "$YELLOW" "检测到可能是国内服务器（GitHub 访问受限）"
            return 0
        fi
    fi
    
    # 方法2：通过 IP 地理位置检测
    local ip_info=$(curl -s --connect-timeout 5 "http://ip-api.com/json/?fields=country,countryCode" 2>/dev/null)
    if echo "$ip_info" | grep -qE '"countryCode":"CN"|"country":"China"'; then
        print_message "$YELLOW" "检测到国内服务器（基于 IP 地理位置）"
        return 0
    fi
    
    # 方法3：检测时区
    if [[ "$(date +%z)" == "+0800" ]] && [[ "$(cat /etc/timezone 2>/dev/null)" =~ "Asia/Shanghai|Asia/Beijing" ]]; then
        print_message "$YELLOW" "检测到可能是国内服务器（基于时区）"
        return 0
    fi
    
    print_message "$GREEN" "检测到非国内服务器或无需代理"
    return 1
}

# 选择可用的代理
select_proxy() {
    print_message "$BLUE" "测试代理可用性..."
    
    # 测试第一个代理
    if curl -s --connect-timeout 5 "${GITHUB_PROXY1}https://github.com" > /dev/null 2>&1; then
        CURRENT_PROXY="$GITHUB_PROXY1"
        print_message "$GREEN" "使用代理: $GITHUB_PROXY1"
        return 0
    fi
    
    # 测试第二个代理
    if curl -s --connect-timeout 5 "${GITHUB_PROXY2}https://github.com" > /dev/null 2>&1; then
        CURRENT_PROXY="$GITHUB_PROXY2"
        print_message "$GREEN" "使用代理: $GITHUB_PROXY2"
        return 0
    fi
    
    print_message "$YELLOW" "警告：所有代理都不可用，将尝试直接访问"
    return 1
}

# 转换 GitHub URL
convert_github_url() {
    local url="$1"
    if [[ -n "$CURRENT_PROXY" ]]; then
        # 如果 URL 以 https:// 开头，直接在前面加代理
        if [[ "$url" =~ ^https:// ]]; then
            echo "${CURRENT_PROXY}${url}"
        # 如果是 git 协议的 URL
        elif [[ "$url" =~ ^git@github.com: ]]; then
            # 转换为 https 格式并加代理
            local converted=$(echo "$url" | sed 's|git@github.com:|https://github.com/|')
            echo "${CURRENT_PROXY}${converted}"
        else
            echo "$url"
        fi
    else
        echo "$url"
    fi
}

# Git clone 包装函数
git_clone_with_proxy() {
    local repo_url="$1"
    local destination="$2"
    
    if [[ -n "$CURRENT_PROXY" ]]; then
        local proxy_url=$(convert_github_url "$repo_url")
        print_message "$BLUE" "使用代理克隆: $proxy_url"
        git clone --depth=1 "$proxy_url" "$destination"
    else
        git clone --depth=1 "$repo_url" "$destination"
    fi
}

# 检查系统环境
check_system() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if command -v apt-get &> /dev/null; then
            PKG_MANAGER="apt-get"
            PKG_UPDATE="sudo apt-get update"
            PKG_INSTALL="sudo apt-get install -y"
        elif command -v yum &> /dev/null; then
            PKG_MANAGER="yum"
            PKG_UPDATE="sudo yum check-update"
            PKG_INSTALL="sudo yum install -y"
        elif command -v dnf &> /dev/null; then
            PKG_MANAGER="dnf"
            PKG_UPDATE="sudo dnf check-update"
            PKG_INSTALL="sudo dnf install -y"
        elif command -v pacman &> /dev/null; then
            PKG_MANAGER="pacman"
            PKG_UPDATE="sudo pacman -Sy"
            PKG_INSTALL="sudo pacman -S --noconfirm"
        else
            print_message "$RED" "错误：不支持的包管理器"
            exit 1
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        if ! command -v brew &> /dev/null; then
            print_message "$RED" "错误：macOS 需要先安装 Homebrew"
            exit 1
        fi
        PKG_MANAGER="brew"
        PKG_UPDATE="brew update"
        PKG_INSTALL="brew install"
    else
        print_message "$RED" "错误：不支持的操作系统"
        exit 1
    fi
}

# 检查并安装依赖
install_dependencies() {
    local deps=("zsh" "git" "curl" "wget")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_message "$YELLOW" "安装缺失的依赖: ${missing_deps[*]}"
        $PKG_UPDATE
        $PKG_INSTALL "${missing_deps[@]}"
    fi
}

# 安装 Oh My Zsh
install_oh_my_zsh() {
    if [[ -d "$HOME/.oh-my-zsh" ]]; then
        print_message "$GREEN" "Oh My Zsh 已经安装"
        return 0
    fi
    
    print_message "$BLUE" "正在安装 Oh My Zsh..."
    
    # 原始 URL
    local install_url="https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh"
    
    # 如果检测到国内服务器，转换 URL
    if [[ -n "$CURRENT_PROXY" ]]; then
        install_url=$(convert_github_url "$install_url")
        print_message "$BLUE" "使用代理下载: $install_url"
    fi
    
    # 下载并运行安装脚本
    export RUNZSH=no  # 防止自动切换到 zsh
    if command -v curl &> /dev/null; then
        sh -c "$(curl -fsSL $install_url)" "" --unattended
    elif command -v wget &> /dev/null; then
        sh -c "$(wget -O- $install_url)" "" --unattended
    else
        print_message "$RED" "错误：需要 curl 或 wget"
        return 1
    fi
}

# 安装 Powerlevel10k 主题
install_powerlevel10k() {
    local theme_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
    
    if [[ -d "$theme_dir" ]]; then
        print_message "$GREEN" "Powerlevel10k 已经安装"
        return 0
    fi
    
    print_message "$BLUE" "正在安装 Powerlevel10k 主题..."
    git_clone_with_proxy "https://github.com/romkatv/powerlevel10k.git" "$theme_dir"
}

# 安装字体
install_fonts() {
    print_message "$BLUE" "正在安装 Nerd Fonts..."
    
    local font_dir=""
    if [[ "$OSTYPE" == "darwin"* ]]; then
        font_dir="$HOME/Library/Fonts"
    else
        font_dir="$HOME/.local/share/fonts"
    fi
    
    mkdir -p "$font_dir"
    
    # 字体列表
    local fonts=(
        "MesloLGS%20NF%20Regular.ttf"
        "MesloLGS%20NF%20Bold.ttf"
        "MesloLGS%20NF%20Italic.ttf"
        "MesloLGS%20NF%20Bold%20Italic.ttf"
    )
    
    for font in "${fonts[@]}"; do
        local font_name=$(echo "$font" | sed 's/%20/ /g')
        if [[ ! -f "$font_dir/$font_name" ]]; then
            local font_url="https://github.com/romkatv/powerlevel10k-media/raw/master/$font"
            if [[ -n "$CURRENT_PROXY" ]]; then
                font_url=$(convert_github_url "$font_url")
            fi
            print_message "$BLUE" "下载字体: $font_name"
            curl -fsSL "$font_url" -o "$font_dir/$font_name"
        fi
    done
    
    # 刷新字体缓存
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        fc-cache -fv
    fi
}

# 安装插件
install_plugins() {
    local custom_plugins="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins"
    mkdir -p "$custom_plugins"
    
    # 插件列表
    declare -A plugins=(
        ["zsh-autosuggestions"]="https://github.com/zsh-users/zsh-autosuggestions"
        ["zsh-syntax-highlighting"]="https://github.com/zsh-users/zsh-syntax-highlighting"
        ["zsh-completions"]="https://github.com/zsh-users/zsh-completions"
        ["zsh-history-substring-search"]="https://github.com/zsh-users/zsh-history-substring-search"
        ["zsh-vi-mode"]="https://github.com/jeffreytse/zsh-vi-mode"
        ["fzf-tab"]="https://github.com/Aloxaf/fzf-tab"
    )
    
    for plugin_name in "${!plugins[@]}"; do
        local plugin_url="${plugins[$plugin_name]}"
        local plugin_dir="$custom_plugins/$plugin_name"
        
        if [[ ! -d "$plugin_dir" ]]; then
            print_message "$BLUE" "安装插件: $plugin_name"
            git_clone_with_proxy "$plugin_url.git" "$plugin_dir"
        else
            print_message "$GREEN" "插件已存在: $plugin_name"
        fi
    done
    
    # 安装 fzf
    if ! command -v fzf &> /dev/null; then
        print_message "$BLUE" "安装 fzf..."
        if [[ "$PKG_MANAGER" == "brew" ]]; then
            brew install fzf
        else
            git_clone_with_proxy "https://github.com/junegunn/fzf.git" "$HOME/.fzf"
            "$HOME/.fzf/install" --all --no-bash --no-fish
        fi
    fi
}

# 配置 .zshrc
configure_zshrc() {
    print_message "$BLUE" "配置 .zshrc..."
    
    # 备份原有配置
    if [[ -f "$HOME/.zshrc" ]]; then
        cp "$HOME/.zshrc" "$HOME/.zshrc.backup.$(date +%Y%m%d%H%M%S)"
    fi
    
    # 创建新的 .zshrc
    cat > "$HOME/.zshrc" << 'EOF'
# Enable Powerlevel10k instant prompt
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# Path to your oh-my-zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Set theme
ZSH_THEME="powerlevel10k/powerlevel10k"

# Plugins
plugins=(
    git
    docker
    docker-compose
    kubectl
    npm
    node
    python
    pip
    sudo
    command-not-found
    extract
    z
    colored-man-pages
    zsh-autosuggestions
    zsh-syntax-highlighting
    zsh-completions
    zsh-history-substring-search
    zsh-vi-mode
    fzf-tab
)

# Oh My Zsh settings
CASE_SENSITIVE="false"
HYPHEN_INSENSITIVE="true"
DISABLE_AUTO_UPDATE="false"
DISABLE_UPDATE_PROMPT="false"
export UPDATE_ZSH_DAYS=13
DISABLE_MAGIC_FUNCTIONS="false"
DISABLE_LS_COLORS="false"
DISABLE_AUTO_TITLE="false"
ENABLE_CORRECTION="true"
COMPLETION_WAITING_DOTS="true"
DISABLE_UNTRACKED_FILES_DIRTY="false"
HIST_STAMPS="yyyy-mm-dd"

source $ZSH/oh-my-zsh.sh

# User configuration

# Aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias cls='clear'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias ~='cd ~'
alias df='df -h'
alias du='du -h'
alias free='free -h'

# History settings
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt appendhistory
setopt sharehistory
setopt hist_ignore_space
setopt hist_ignore_all_dups
setopt hist_save_no_dups
setopt hist_ignore_dups
setopt hist_find_no_dups

# Key bindings
bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down
bindkey '^P' history-substring-search-up
bindkey '^N' history-substring-search-down

# Autosuggestions settings
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=#666666"
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
bindkey '^f' autosuggest-accept

# FZF settings
if [[ -f ~/.fzf.zsh ]]; then
    source ~/.fzf.zsh
fi

# Load custom configurations
if [[ -f ~/.zshrc.local ]]; then
    source ~/.zshrc.local
fi

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
EOF
    
    # 创建 .p10k.zsh 配置
    if [[ ! -f "$HOME/.p10k.zsh" ]]; then
        print_message "$BLUE" "生成 Powerlevel10k 配置..."
        # 这里可以添加预设的 p10k 配置，或让用户手动运行 p10k configure
    fi
}

# 检查网络连接
check_network() {
    print_message "$BLUE" "检查网络连接..."
    if ! ping -c 1 -W 3 google.com &> /dev/null && ! ping -c 1 -W 3 baidu.com &> /dev/null; then
        print_message "$RED" "错误：没有网络连接"
        exit 1
    fi
}

# 主函数
main() {
    print_message "$GREEN" "========================================="
    print_message "$GREEN" "   Zsh 环境自动配置脚本 (国内优化版)"
    print_message "$GREEN" "========================================="
    
    # 检查网络
    check_network
    
    # 检查系统
    check_system
    
    # 检查是否为国内服务器
    if check_china_server; then
        select_proxy
    fi
    
    # 安装依赖
    install_dependencies
    
    # 安装 Oh My Zsh
    install_oh_my_zsh
    
    # 设置 ZSH_CUSTOM 变量
    export ZSH_CUSTOM="$HOME/.oh-my-zsh/custom"
    
    # 安装 Powerlevel10k
    install_powerlevel10k
    
    # 安装字体
    install_fonts
    
    # 安装插件
    install_plugins
    
    # 配置 .zshrc
    configure_zshrc
    
    # 设置 zsh 为默认 shell
    if [[ "$SHELL" != *"zsh" ]]; then
        print_message "$BLUE" "设置 zsh 为默认 shell..."
        if command -v chsh &> /dev/null; then
            chsh -s "$(which zsh)"
        else
            print_message "$YELLOW" "请手动运行: chsh -s $(which zsh)"
        fi
    fi
    
    print_message "$GREEN" "========================================="
    print_message "$GREEN" "配置完成！"
    print_message "$YELLOW" "请注意："
    print_message "$YELLOW" "1. 重新登录或运行 'exec zsh' 以使用新配置"
    print_message "$YELLOW" "2. 首次进入 zsh 可能会运行 'p10k configure' 配置向导"
    print_message "$YELLOW" "3. 确保终端使用 'MesloLGS NF' 字体"
    print_message "$GREEN" "========================================="
}

# 运行主函数
main "$@"
