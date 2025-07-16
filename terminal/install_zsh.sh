#!/bin/bash

# ================================================================
# Zsh 环境自动配置脚本 v3.3 (国内代理增强版)
# 支持：Debian/Ubuntu (apt)、RHEL/CentOS (yum/dnf)、macOS (brew)
# 新增：国内服务器检测和GitHub代理支持
# ================================================================

# 启用严格的错误处理
set -euo pipefail
trap 'error_handler $? $LINENO "$BASH_COMMAND"' ERR

# 全局变量
SCRIPT_VERSION="3.3"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  
IS_ROOT=$([[ $EUID -eq 0 ]] && echo "true" || echo "false")
LOG_FILE="$HOME/.zsh_install_$(date +%Y%m%d_%H%M%S).log"
PACKAGE_MANAGER=""
OS_TYPE=""
SKIP_USERS=("nobody" "systemd-network" "systemd-resolve" "daemon" "bin" "sys")

# 新增：国内代理配置
IS_CHINA_SERVER="false"
GITHUB_PROXY=""
GITHUB_RAW_PROXY=""

# GitHub代理列表
GITHUB_PROXIES=(
    "https://github.airskotex.nyc.mn"
    "https://github.proxies.ip-ddns.com"
)

GITHUB_RAW_PROXIES=(
    "https://raw.airskotex.nyc.mn"
    "https://raw.proxies.ip-ddns.com"
)

# 颜色定义
RED='\033[0;31m'  
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# ================================================================
# 新增：国内服务器检测和代理配置
# ================================================================

# 检测是否为国内服务器
detect_china_server() {
    log_info "检测服务器位置..."
    
    # 方法1：检查IP地址归属
    local ip_info=""
    if command_exists curl; then
        # 尝试多个IP检测服务
        local ip_services=(
            "https://ipinfo.io/country"
            "https://httpbin.org/ip"
            "https://api.ipify.org"
        )
        
        for service in "${ip_services[@]}"; do
            if ip_info=$(curl -m 5 -s "$service" 2>/dev/null); then
                if [[ "$ip_info" =~ "CN" ]] || [[ "$ip_info" =~ "China" ]]; then
                    IS_CHINA_SERVER="true"
                    log_info "检测到国内服务器环境"
                    return 0
                fi
                break
            fi
        done
    fi
    
    # 方法2：检查DNS解析时间（GitHub访问速度）
    local github_ping_time=0
    if command_exists ping; then
        github_ping_time=$(ping -c 3 -W 2 github.com 2>/dev/null | grep "avg" | cut -d'/' -f5 | cut -d'.' -f1 || echo "999")
    fi
    
    # 方法3：检查系统时区
    local timezone=""
    if [ -f /etc/timezone ]; then
        timezone=$(cat /etc/timezone)
    elif [ -L /etc/localtime ]; then
        timezone=$(readlink /etc/localtime | sed 's/.*zoneinfo\///')
    fi
    
    # 综合判断
    if [[ "$timezone" =~ "Asia/Shanghai" ]] || [[ "$timezone" =~ "Asia/Chongqing" ]] || 
       [[ "$github_ping_time" -gt 200 ]]; then
        IS_CHINA_SERVER="true"
        log_info "根据网络环境判断为国内服务器"
    else
        log_info "检测为海外服务器环境"
    fi
}

# 测试并选择最快的代理
select_best_proxy() {
    log_info "测试GitHub代理速度..."
    
    local best_proxy=""
    local best_raw_proxy=""
    local best_time=999
    
    # 测试GitHub代理
    for proxy in "${GITHUB_PROXIES[@]}"; do
        log_debug "测试代理: $proxy"
        local start_time=$(date +%s%N)
        
        if curl -m 5 -s -o /dev/null "$proxy" 2>/dev/null; then
            local end_time=$(date +%s%N)
            local response_time=$(( (end_time - start_time) / 1000000 ))
            
            log_debug "代理 $proxy 响应时间: ${response_time}ms"
            
            if [ "$response_time" -lt "$best_time" ]; then
                best_time=$response_time
                best_proxy=$proxy
            fi
        else
            log_debug "代理 $proxy 不可用"
        fi
    done
    
    # 设置最佳代理
    if [ -n "$best_proxy" ]; then
        GITHUB_PROXY="$best_proxy"
        log_info "选择GitHub代理: $GITHUB_PROXY (${best_time}ms)"
        
        # 设置对应的raw代理
        case "$best_proxy" in
            *"airskotex.nyc.mn"*)
                GITHUB_RAW_PROXY="https://raw.airskotex.nyc.mn"
                ;;
            *"proxies.ip-ddns.com"*)
                GITHUB_RAW_PROXY="https://raw.proxies.ip-ddns.com"
                ;;
        esac
        
        log_info "选择Raw代理: $GITHUB_RAW_PROXY"
    else
        log_warn "所有代理都不可用，将使用直连"
        IS_CHINA_SERVER="false"
    fi
}

# 配置代理环境
setup_proxy_environment() {
    detect_china_server
    
    if [[ "$IS_CHINA_SERVER" == "true" ]]; then
        select_best_proxy
    fi
}

# URL代理转换函数
proxy_url() {
    local url="$1"
    
    if [[ "$IS_CHINA_SERVER" == "true" && -n "$GITHUB_PROXY" ]]; then
        # 替换GitHub URL
        if [[ "$url" =~ ^https://github\.com/ ]]; then
            url="${url/https:\/\/github.com/$GITHUB_PROXY}"
            log_debug "GitHub URL代理: $url"
        # 替换Raw URL
        elif [[ "$url" =~ ^https://raw\.githubusercontent\.com/ ]]; then
            url="${url/https:\/\/raw.githubusercontent.com/$GITHUB_RAW_PROXY}"
            log_debug "Raw URL代理: $url"
        fi
    fi
    
    echo "$url"
}

# 代理模式的curl函数
proxy_curl() {
    local url="$1"
    shift
    local proxied_url=$(proxy_url "$url")
    
    curl "$@" "$proxied_url"
}

# 代理模式的git clone函数
proxy_git_clone() {
    local url="$1"
    local dest="$2"
    local extra_args="${3:-}"
    
    local proxied_url=$(proxy_url "$url")
    
    if [ -n "$extra_args" ]; then
        git clone $extra_args "$proxied_url" "$dest"
    else
        git clone "$proxied_url" "$dest"
    fi
}

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

command_exists() {
    command -v "$1" &> /dev/null
}

# ================================================================
# 网络检测函数
# ================================================================

check_network() {
    log_info "检查网络连接..."
    
    local test_urls=(
        "https://github.com"
        "https://raw.githubusercontent.com"
    )
    
    for url in "${test_urls[@]}"; do
        local proxied_url=$(proxy_url "$url")
        if curl -fsS --connect-timeout 10 -o /dev/null "$proxied_url" 2>/dev/null; then
            log_info "网络连接正常: $proxied_url"
            return 0
        fi
    done
    
    log_error "无法连接到 GitHub"
    return 1
}

# ================================================================
# 系统包安装函数
# ================================================================

install_system_packages() {
    log_info "安装系统包..."
    
    local packages=("zsh" "git" "curl" "wget" "fontconfig")
    
    case "$PACKAGE_MANAGER" in
        "apt")
            apt update
            apt install -y "${packages[@]}"
            ;;
        "yum")
            yum install -y "${packages[@]}"
            ;;
        "dnf")
            dnf install -y "${packages[@]}"
            ;;
        "brew")
            # macOS上通常已经有这些包
            for pkg in "${packages[@]}"; do
                if ! command_exists "$pkg"; then
                    brew install "$pkg" || log_warn "无法安装 $pkg"
                fi
            done
            ;;
    esac
    
    log_info "系统包安装完成"
}

# ================================================================
# 用户管理函数
# ================================================================

get_target_users() {
    local users=()
    
    if [[ "$IS_ROOT" == "true" ]]; then
        log_info "检测到 root 用户权限，将为所有用户配置"
        
        # 获取所有普通用户
        while IFS=':' read -r username _ uid _ _ home shell; do
            # 跳过系统用户和特殊用户
            if [[ "$uid" -ge 1000 ]] || [[ "$username" == "root" ]]; then
                local skip=false
                for skip_user in "${SKIP_USERS[@]}"; do
                    if [[ "$username" == "$skip_user" ]]; then
                        skip=true
                        break
                    fi
                done
                
                if [[ "$skip" == "false" ]]; then
                    users+=("$username:$home:$shell")
                fi
            fi
        done < /etc/passwd
    else
        # 非root用户，只为当前用户配置
        users+=("$USER:$HOME:$SHELL")
    fi
    
    printf '%s\n' "${users[@]}"
}

# ================================================================
# 用户安装函数
# ================================================================

install_for_user() {
    local username="$1"
    local user_home="$2"
    local user_shell="$3"
    
    log_info "========================================="
    log_info "为用户 $username 配置 Zsh 环境"
    log_info "主目录: $user_home"
    log_info "使用代理: $([[ "$IS_CHINA_SERVER" == "true" ]] && echo "是" || echo "否")"
    log_info "========================================="
    
    if [ ! -d "$user_home" ]; then
        log_warn "用户 $username 的主目录不存在，跳过"
        return
    fi
    
    local temp_script="/tmp/zsh_install_${username}_$$.sh"
    
    # 生成用户脚本
    cat > "$temp_script" << USERSCRIPT
#!/bin/bash
set -euo pipefail

# 用户级别的安装脚本
USERNAME="$username"
USER_HOME="$user_home"
IS_CHINA_SERVER="$IS_CHINA_SERVER"
GITHUB_PROXY="$GITHUB_PROXY"
GITHUB_RAW_PROXY="$GITHUB_RAW_PROXY"

export HOME="\$USER_HOME"
cd "\$HOME"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "\${GREEN}[INFO]\${NC} 开始为用户 \${USERNAME} 安装..."
if [[ "\$IS_CHINA_SERVER" == "true" ]]; then
    echo -e "\${YELLOW}[INFO]\${NC} 使用国内代理加速下载"
fi

# 代理URL转换函数
proxy_url() {
    local url="\$1"
    
    if [[ "\$IS_CHINA_SERVER" == "true" && -n "\$GITHUB_PROXY" ]]; then
        if [[ "\$url" =~ ^https://github\.com/ ]]; then
            url="\${url/https:\/\/github.com/\$GITHUB_PROXY}"
        elif [[ "\$url" =~ ^https://raw\.githubusercontent\.com/ ]]; then
            url="\${url/https:\/\/raw.githubusercontent.com/\$GITHUB_RAW_PROXY}"
        fi
    fi
    
    echo "\$url"
}

# 检查网络连接
check_network() {
    local test_urls=("https://github.com" "https://raw.githubusercontent.com")
    
    for url in "\${test_urls[@]}"; do
        local proxied_url=\$(proxy_url "\$url")
        if curl -fsS --connect-timeout 5 -o /dev/null "\$proxied_url" 2>/dev/null; then
            return 0
        fi
    done
    
    return 1
}

if ! check_network; then
    echo -e "\${RED}[ERROR]\${NC} 无法连接到 GitHub（即使使用代理）"
    exit 1
fi

# 安装 Oh My Zsh
if [ ! -d "\$HOME/.oh-my-zsh" ]; then
    echo -e "\${GREEN}[INFO]\${NC} 安装 Oh My Zsh..."
    export RUNZSH=no
    export CHSH=no
    
    local ohmyzsh_url=\$(proxy_url "https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh")
    sh -c "\$(curl -fsSL \$ohmyzsh_url)" "" --unattended || {
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
    local p10k_url=\$(proxy_url "https://github.com/romkatv/powerlevel10k.git")
    git clone --depth=1 "\$p10k_url" "\$P10K_DIR" || {
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
        local proxied_url=\$(proxy_url "\$plugin_url")
        git clone "\$proxied_url" "\$plugin_dir" || {
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

# 备份原配置
if [ -f "\$HOME/.zshrc" ]; then
    cp "\$HOME/.zshrc" "\$HOME/.zshrc.backup.\$(date +%Y%m%d_%H%M%S)"
fi

# 创建新的 .zshrc 配置
cat > "\$HOME/.zshrc" << 'EOF'
# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
if [[ -r "\${XDG_CACHE_HOME:-\$HOME/.cache}/p10k-instant-prompt-\${(%):-%n}.zsh" ]]; then
  source "\${XDG_CACHE_HOME:-\$HOME/.cache}/p10k-instant-prompt-\${(%):-%n}.zsh"
fi

# Path to oh-my-zsh installation
export ZSH="\$HOME/.oh-my-zsh"

# Set theme
ZSH_THEME="powerlevel10k/powerlevel10k"

# Uncomment the following line to use case-sensitive completion.
# CASE_SENSITIVE="true"

# Uncomment the following line to use hyphen-insensitive completion.
# Case-sensitive completion must be off. _ and - will be interchangeable.
HYPHEN_INSENSITIVE="true"

# Uncomment the following line to disable auto-setting terminal title.
# DISABLE_AUTO_TITLE="true"

# Uncomment the following line to enable command auto-correction.
ENABLE_CORRECTION="true"

# Uncomment the following line to display red dots whilst waiting for completion.
COMPLETION_WAITING_DOTS="true"

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

# Set language environment
export LANG=en_US.UTF-8

# Preferred editor for local and remote sessions
if [[ -n \$SSH_CONNECTION ]]; then
    export EDITOR='vim'
else
    export EDITOR='nvim'
fi

# Compilation flags
export ARCHFLAGS="-arch x86_64"

# === ALIASES ===
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# Git aliases
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git log --oneline --graph --all'
alias gd='git diff'
alias gb='git branch'
alias gco='git checkout'

# System aliases
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias ~='cd ~'
alias h='history'
alias j='jobs -l'
alias df='df -h'
alias du='du -h'
alias free='free -h'

# === FUNCTIONS ===

# Create directory and cd into it
mkcd() {
    mkdir -p "\$1" && cd "\$1"
}

# Extract various archive formats
extract() {
    if [ -f "\$1" ]; then
        case "\$1" in
            *.tar.bz2)  tar xjf "\$1"    ;;
            *.tar.gz)   tar xzf "\$1"    ;;
            *.bz2)      bunzip2 "\$1"    ;;
            *.rar)      unrar x "\$1"    ;;
            *.gz)       gunzip "\$1"     ;;
            *.tar)      tar xf "\$1"     ;;
            *.tbz2)     tar xjf "\$1"    ;;
            *.tgz)      tar xzf "\$1"    ;;
            *.zip)      unzip "\$1"      ;;
            *.Z)        uncompress "\$1" ;;
            *.7z)       7z x "\$1"       ;;
            *)          echo "'\$1' cannot be extracted via extract()" ;;
        esac
    else
        echo "'\$1' is not a valid file"
    fi
}

# === POWERLEVEL10K CONFIG ===
# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# === CUSTOM PATHS ===
# Add custom paths here
# export PATH="\$PATH:/custom/path"

# === PLUGIN CONFIGURATIONS ===

# fzf-tab configuration
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls --color=always \$realpath'
zstyle ':fzf-tab:complete:ls:*' fzf-preview 'ls --color=always \$realpath'

# zsh-autosuggestions configuration
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=#666666,underline"
ZSH_AUTOSUGGEST_STRATEGY=(history completion)

# === HISTORY CONFIGURATION ===
HISTSIZE=50000
SAVEHIST=50000
setopt EXTENDED_HISTORY
setopt SHARE_HISTORY
setopt APPEND_HISTORY
setopt INC_APPEND_HISTORY
setopt HIST_EXPIRE_DUPS_FIRST
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_FIND_NO_DUPS
setopt HIST_IGNORE_SPACE
setopt HIST_SAVE_NO_DUPS
setopt HIST_REDUCE_BLANKS
setopt HIST_VERIFY

# === COMPLETION CONFIGURATION ===
# Case insensitive completion
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'
# Menu selection
zstyle ':completion:*' menu select

# === WELCOME MESSAGE ===
echo "🎉 Zsh 环境配置完成！"
echo "💡 运行 'p10k configure' 来配置 Powerlevel10k 主题"
echo "📚 查看 ~/.zshrc 来自定义更多配置"
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
        echo -e "\${GREEN}[INFO]\${NC} 下载字体: \$font_name"
        local proxied_font_url=\$(proxy_url "\$font_url")
        curl -fsSL "\$proxied_font_url" -o "\$FONT_DIR/\$font_name" || echo -e "\${YELLOW}[WARN]\${NC} 无法下载 \$font_name"
    fi
done

# 更新字体缓存
if command -v fc-cache &> /dev/null; then
    echo -e "\${GREEN}[INFO]\${NC} 更新字体缓存..."
    fc-cache -f "\$FONT_DIR" 2>/dev/null || true
fi

echo -e "\${GREEN}[INFO]\${NC} 用户 \${USERNAME} 的 Zsh 环境配置完成！"
echo -e "\${YELLOW}[提示]\${NC} 请重启终端或运行 'source ~/.zshrc' 来应用配置"
echo -e "\${YELLOW}[提示]\${NC} 运行 'p10k configure' 来配置 Powerlevel10k 主题"
USERSCRIPT

    # 设置脚本权限并运行
    chmod +x "$temp_script"
    
    if [ "$username" == "$USER" ] || ([ "$username" == "root" ] && [ "$IS_ROOT" == "true" ]); then
        bash "$temp_script"
    else
        su - "$username" -c "bash $temp_script"
    fi
    
    rm -f "$temp_script"
    
    # 设置默认shell
    if [[ "$user_shell" != */zsh ]]; then
        log_info "为用户 $username 设置默认 shell 为 zsh"
        
        local zsh_path=$(command -v zsh)
        if [ -n "$zsh_path" ]; then
            if [[ "$OS_TYPE" == "macos" ]]; then
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
# 展示横幅
# ================================================================

show_banner() {
    echo -e "${PURPLE}"
    echo "================================================================"
    echo "  ______ _____ _   _   _____ _   _  _____ _______       _      "
    echo " |___  // ____| | | | |_   _| \ | |/ ____|__   __|/\   | |     "
    echo "    / /| (___ | |_| |   | | |  \| | (___    | |  /  \  | |     "
    echo "   / /  \___ \|  _  |   | | | . \` |\___ \   | | / /\ \ | |     "
    echo "  / /__ ____) | | | |  _| |_| |\  |____) |  | |/ ____ \| |____ "
    echo " /_____|_____/|_| |_| |_____|_| \_|_____/   |_/_/    \_\______|"
    echo "                                                               "
    echo "================================================================"
    echo -e "${NC}"
    echo -e "${GREEN}Zsh 环境自动配置脚本 v${SCRIPT_VERSION}${NC}"
    echo -e "${GREEN}支持: Debian/Ubuntu/CentOS/RHEL/macOS${NC}"
    echo -e "${GREEN}新增: 国内服务器检测和GitHub代理支持${NC}"
    echo -e "${YELLOW}作者: AI Assistant${NC}"
    echo "================================================================"
}

# ================================================================
# 显示总结
# ================================================================

show_summary() {
    echo -e "${GREEN}"
    echo "================================================================"
    echo "                    安装完成总结"
    echo "================================================================"
    echo -e "${NC}"
    
    echo -e "${GREEN}✅ 系统检测${NC}"
    echo -e "   操作系统: $OS_TYPE"
    echo -e "   包管理器: $PACKAGE_MANAGER"
    echo -e "   服务器位置: $([[ "$IS_CHINA_SERVER" == "true" ]] && echo "国内" || echo "海外")"
    echo -e "   GitHub代理: $([[ -n "$GITHUB_PROXY" ]] && echo "$GITHUB_PROXY" || echo "未使用")"
    echo
    
    echo -e "${GREEN}✅ 已安装组件${NC}"
    echo -e "   • Zsh Shell"
    echo -e "   • Oh My Zsh"
    echo -e "   • Powerlevel10k 主题"
    echo -e "   • zsh-syntax-highlighting 插件"
    echo -e "   • zsh-autosuggestions 插件"
    echo -e "   • fzf-tab 插件"
    echo -e "   • MesloLGS NF 字体"
    echo
    
    echo -e "${GREEN}✅ 配置位置${NC}"
    echo -e "   • 配置文件: ~/.zshrc"
    echo -e "   • 主题配置: ~/.p10k.zsh"
    echo -e "   • 字体目录: ~/.local/share/fonts"
    echo -e "   • 安装日志: $LOG_FILE"
    echo
    
    echo -e "${YELLOW}🔧 下一步操作${NC}"
    echo -e "   1. 重启终端或运行: source ~/.zshrc"
    echo -e "   2. 运行 'p10k configure' 配置主题"
    echo -e "   3. 在终端应用中选择 MesloLGS NF 字体"
    echo
    
    echo -e "${GREEN}📖 更多信息${NC}"
    echo -e "   • Powerlevel10k: https://github.com/romkatv/powerlevel10k"
    echo -e "   • Oh My Zsh: https://ohmyz.sh"
    echo -e "   • 配置教程: https://github.com/ohmyzsh/ohmyzsh/wiki"
    echo
    
    echo -e "${GREEN}================================================================${NC}"
}

# ================================================================
# 主函数
# ================================================================

main() {
    show_banner
    
    log_info "开始安装 (版本: $SCRIPT_VERSION)"
    log_info "运行用户: $(whoami) (UID: $EUID)"
    log_info "日志文件: $LOG_FILE"
    
    # 系统检测
    log_info "=== 系统检测 ==="
    detect_os
    detect_package_manager
    
    # 代理环境配置
    log_info "=== 代理环境配置 ==="
    setup_proxy_environment
    
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
    
    # 获取目标用户
    log_info "=== 用户配置 ==="
    local users=($(get_target_users))
    log_info "找到 ${#users[@]} 个用户需要配置"
    
    # 为每个用户安装
    for user_info in "${users[@]}"; do
        IFS=':' read -r username user_home user_shell <<< "$user_info"
        install_for_user "$username" "$user_home" "$user_shell"
    done
    
    # 显示总结
    show_summary
    
    log_info "所有用户的 Zsh 环境配置完成！"
}

# 帮助信息
show_help() {
    echo "使用方法: $0 [选项]"
    echo
    echo "选项:"
    echo "  -h, --help     显示帮助信息"
    echo "  -v, --version  显示版本信息"
    echo
    echo "示例:"
    echo "  $0              # 运行安装"
    echo "  sudo $0         # 以root权限运行，为所有用户安装"
    echo
}

# 处理命令行参数
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    -v|--version)
        echo "Zsh 环境配置脚本 v$SCRIPT_VERSION"
        exit 0
        ;;
    *)
        # 执行主函数
        main "$@"
        ;;
esac
