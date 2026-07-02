#!/bin/bash

# ================================================================
# Zsh 环境自动配置脚本 (Starship + Fastfetch 版)
# 支持：Debian/Ubuntu (apt)、RHEL/CentOS (yum/dnf)、macOS (brew)
# ================================================================  

# 启用严格的错误处理
set -euo pipefail
trap 'error_handler $? $LINENO "$BASH_COMMAND"' ERR

# 全局变量
SCRIPT_VERSION="0.6.2-1984-light"
IS_ROOT=$([[ $EUID -eq 0 ]] && echo "true" || echo "false")
LOG_FILE="$HOME/.zsh_install_$(date +%Y%m%d_%H%M%S).log"
PACKAGE_MANAGER=""
OS_TYPE=""
ARCH_GNU=""
SKIP_USERS=("nobody" "systemd-network" "systemd-resolve" "daemon" "bin" "sys")

# GitHub 镜像加速：国内环境自动切换为 xget.pp.ua/gh 镜像
# detect_china() 会在 main 开头探测，重设以下两个前缀
GH_PREFIX="https://github.com"
RAW_PREFIX="https://raw.githubusercontent.com"
USE_MIRROR="false"

# 颜色定义：面向 Termius "1984 Light" 这类浅色主题，使用深色高对比前景色。
init_terminal_colors() {
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
        COLOR_RESET='\033[0m'
        COLOR_BOLD='\033[1m'
        COLOR_SUCCESS='\033[1;38;5;28m'   # 深绿
        COLOR_WARN='\033[1;38;5;130m'     # 棕金，替代浅色主题下难读的亮黄
        COLOR_ERROR='\033[1;38;5;124m'    # 深红
        COLOR_INFO='\033[1;38;5;25m'      # 深蓝
        COLOR_DEBUG='\033[38;5;31m'       # 青蓝调试色
        COLOR_ACCENT='\033[1;38;5;90m'    # 靛紫
        COLOR_SECTION='\033[1;38;5;24m'   # 蓝绿色标题
    else
        COLOR_RESET=''
        COLOR_BOLD=''
        COLOR_SUCCESS=''
        COLOR_WARN=''
        COLOR_ERROR=''
        COLOR_INFO=''
        COLOR_DEBUG=''
        COLOR_ACCENT=''
        COLOR_SECTION=''
    fi

    RED="$COLOR_ERROR"
    GREEN="$COLOR_SUCCESS"
    YELLOW="$COLOR_WARN"
    BLUE="$COLOR_INFO"
    PURPLE="$COLOR_ACCENT"
    NC="$COLOR_RESET"
}
init_terminal_colors

# ================================================================
# 日志和输出函数
# ================================================================  

log() {
    local level="$1"
    local message="$2"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local color=""  

    case "$level" in
        "INFO") color="$COLOR_INFO" ;;
        "WARN") color="$YELLOW" ;;
        "ERROR") color="$RED" ;;
        "DEBUG") color="$COLOR_DEBUG" ;;
    esac  

    printf "${color}[%s] [%s]${NC} %s\n" "$timestamp" "$level" "$message"
    printf "[%s] [%s] %s\n" "$timestamp" "$level" "$message" >> "$LOG_FILE" 2>/dev/null || true
}  

log_info() { log "INFO" "$1"; }
log_warn() { log "WARN" "$1"; }
log_error() { log "ERROR" "$1"; }
log_debug() { log "DEBUG" "$1"; }  

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

# 检测 CPU 架构，归一化为 GNU 三元组里常用的写法（x86_64 / aarch64）
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   ARCH_GNU="x86_64" ;;
        aarch64|arm64)  ARCH_GNU="aarch64" ;;
        *)              ARCH_GNU="" ;;
    esac
    if [ -n "$ARCH_GNU" ]; then
        log_info "检测到架构: $ARCH_GNU"
    else
        log_warn "未识别的架构 $(uname -m)，二进制兜底安装将跳过"
    fi
}

# ================================================================
# 包管理器操作函数
# ================================================================  

update_package_index() {
    log_info "更新包索引..."
    case "$PACKAGE_MANAGER" in
        apt)
            if [ "$IS_ROOT" = "true" ]; then apt update; else sudo apt update; fi
            ;;
        yum|dnf) : ;;
        brew) brew update ;;
    esac
}  

install_package() {
    local package="$1"  
    case "$PACKAGE_MANAGER" in
        apt)
            if [ "$IS_ROOT" = "true" ]; then apt install -y "$package"; else sudo apt install -y "$package"; fi
            ;;
        yum)
            if [ "$IS_ROOT" = "true" ]; then yum install -y "$package"; else sudo yum install -y "$package"; fi
            ;;
        dnf)
            if [ "$IS_ROOT" = "true" ]; then dnf install -y "$package"; else sudo dnf install -y "$package"; fi
            ;;
        brew) brew install "$package" ;;
    esac
}  

is_package_installed() {
    local package="$1"  
    case "$PACKAGE_MANAGER" in
        apt) dpkg -l 2>/dev/null | grep -q "^ii  $package " || dpkg -l 2>/dev/null | grep -q "^ii  $package:" ;;
        yum|dnf) rpm -q "$package" &> /dev/null ;;
        brew) brew list "$package" &> /dev/null ;;
    esac
}  

# ================================================================
# 安装函数
# ================================================================  

get_package_name() {
    local generic_name="$1"  
    case "$generic_name" in
        "bat")
            case "$PACKAGE_MANAGER" in
                apt|yum|dnf|brew) echo "bat" ;;
                *) echo "" ;;
            esac
            ;;
        "fzf"|"fastfetch") echo "$generic_name" ;;
        "fonts-powerline")
            case "$PACKAGE_MANAGER" in
                apt) echo "fonts-powerline" ;;
                yum|dnf) echo "powerline-fonts" ;;
                brew|*) echo "" ;;
            esac
            ;;
        "fontconfig")
            case "$PACKAGE_MANAGER" in
                apt|yum|dnf) echo "fontconfig" ;;
                brew|*) echo "" ;;
            esac
            ;;
        *) echo "$generic_name" ;;
    esac
}

# fastfetch 兜底：apt/dnf/yum 源里常常没有，改从 GitHub Releases 下 .deb/.rpm 安装
# 镜像策略复用 $GH_PREFIX（国内 xget.pp.ua / 国外 github.com）
install_fastfetch_from_github() {
    if command_exists fastfetch; then return 0; fi
    if [ -z "$ARCH_GNU" ]; then
        log_warn "架构未知，跳过 fastfetch 的 GitHub 兜底安装"
        return 1
    fi

    local arch_tag pkg_ext installer
    # fastfetch 的 deb 和 rpm 资产都用 amd64/aarch64 命名（非 x86_64）
    case "$ARCH_GNU" in
        x86_64)  arch_tag="amd64" ;;
        aarch64) arch_tag="aarch64" ;;
    esac
    case "$PACKAGE_MANAGER" in
        apt)
            pkg_ext="deb"
            installer="dpkg"
            ;;
        yum|dnf)
            pkg_ext="rpm"
            installer="rpm"
            ;;
        *)
            log_warn "包管理器 $PACKAGE_MANAGER 不支持 fastfetch 的 GitHub 兜底"
            return 1
            ;;
    esac

    local file="fastfetch-linux-${arch_tag}.${pkg_ext}"
    local url="${GH_PREFIX}/fastfetch-cli/fastfetch/releases/latest/download/${file}"
    local tmp="/tmp/${file}"

    log_info "从 GitHub 下载 fastfetch: $url"
    if ! curl -fsSL --connect-timeout 10 -o "$tmp" "$url"; then
        log_warn "fastfetch 下载失败，跳过"
        return 1
    fi

    case "$installer" in
        dpkg)
            if [ "$IS_ROOT" = "true" ]; then dpkg -i "$tmp" || apt -f install -y; else sudo dpkg -i "$tmp" || sudo apt -f install -y; fi
            ;;
        rpm)
            if [ "$IS_ROOT" = "true" ]; then rpm -Uvh --force "$tmp"; else sudo rpm -Uvh --force "$tmp"; fi
            ;;
    esac
    rm -f "$tmp"

    command_exists fastfetch && log_info "fastfetch 安装成功" || log_warn "fastfetch 安装未生效"
}

# Starship 兜底：官方 install.sh 会去 GitHub Releases 拉二进制，国内会卡。
# 国外直连仍用官方脚本；国内改为直接从 $GH_PREFIX 下载 tar.gz 解压到 /usr/local/bin
install_starship() {
    if command_exists starship; then return 0; fi
    log_info "正在全局安装 Starship..."

    if [ "$USE_MIRROR" != "true" ]; then
        curl -sS https://starship.rs/install.sh | sh -s -- -y \
            || log_warn "Starship 安装失败，部分样式可能无法显示"
        return 0
    fi

    # 镜像模式：自行下载二进制
    if [ -z "$ARCH_GNU" ]; then
        log_warn "架构未知，Starship 镜像安装跳过"
        return 1
    fi
    local target="${ARCH_GNU}-unknown-linux-musl"
    local file="starship-${target}.tar.gz"
    local url="${GH_PREFIX}/starship/starship/releases/latest/download/${file}"
    local tmp="/tmp/${file}"

    log_info "从镜像下载 Starship: $url"
    if ! curl -fsSL --connect-timeout 10 -o "$tmp" "$url"; then
        log_warn "Starship 下载失败，部分样式可能无法显示"
        return 1
    fi
    if [ "$IS_ROOT" = "true" ]; then
        tar -xzf "$tmp" -C /usr/local/bin starship
    else
        sudo tar -xzf "$tmp" -C /usr/local/bin starship
    fi
    rm -f "$tmp"
    command_exists starship && log_info "Starship 安装成功" || log_warn "Starship 安装未生效"
}

install_system_packages() {
    log_info "检查并安装必要的软件包..."

    local generic_packages=("zsh" "git" "curl" "wget" "fonts-powerline" "fzf" "bat" "fontconfig" "fastfetch")
    local to_install=()  

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

    # fastfetch 在多数 apt/yum 源缺失，包管理器装不上则走 GitHub 兜底
    if ! command_exists fastfetch && [[ "$OS_TYPE" == "linux" ]]; then
        install_fastfetch_from_github || true
    fi

    install_starship
}  

# ================================================================
# 用户安装函数
# ================================================================  

get_target_users() {
    if [[ "$OS_TYPE" == "macos" ]]; then
        echo "$USER:$HOME:$SHELL"
    elif [ "$IS_ROOT" = "true" ]; then
        echo "root:/root:/bin/bash"  
        local min_uid=1000
        local max_uid=60000
        awk -F: -v min=$min_uid -v max=$max_uid '
            $3 >= min && $3 <= max && 
            $6 != "" && 
            $7 !~ /(false|nologin)$/ {
                print $1":"$6":"$7
            }
        ' /etc/passwd | while read -r line; do
            local username="${line%%:*}"
            local skip=false  
            for skip_user in nobody systemd-network systemd-resolve daemon bin sys; do
                if [[ "$username" == "$skip_user" ]]; then
                    skip=true
                    break
                fi
            done  
            [[ "$skip" == "false" ]] && echo "$line"
        done
    else
        echo "$USER:$HOME:$SHELL"
    fi
}  

# 检测是否处于国内网络环境：直连 github.com 超时则判定受限，启用 xget.pp.ua 镜像
detect_china() {
    log_info "检测 GitHub 直连情况..."
    # 给 github.com 一个较短的探测超时；连得上就用官方源，连不上就走镜像
    if curl -fsS --connect-timeout 5 --max-time 8 -o /dev/null "https://github.com" 2>/dev/null; then
        USE_MIRROR="false"
        GH_PREFIX="https://github.com"
        RAW_PREFIX="https://raw.githubusercontent.com"
        log_info "GitHub 直连正常，使用官方源"
    else
        USE_MIRROR="true"
        GH_PREFIX="https://xget.pp.ua/gh"
        # xget.pp.ua 的 raw 形态同样走 /gh/USER/REPO/...，无需 raw 子域
        RAW_PREFIX="https://xget.pp.ua/gh"
        log_warn "GitHub 直连受限，已启用 xget.pp.ua 镜像加速"
    fi
}

check_network() {
    local test_urls
    if [ "$USE_MIRROR" = "true" ]; then
        test_urls=("https://xget.pp.ua")
    else
        test_urls=(
            "https://github.com"
            "https://raw.githubusercontent.com"
            "https://api.github.com"
        )
    fi
    for url in "${test_urls[@]}"; do
        if curl -fsS --connect-timeout 5 -o /dev/null "$url" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

install_for_user() {
    local username="$1"
    local user_home="$2"
    local user_shell="$3"  

    log_info "========================================="
    log_info "为用户 $username 配置 Zsh 环境"
    log_info "主目录: $user_home"
    log_info "========================================="  

    if [ ! -d "$user_home" ]; then
        log_warn "用户 $username 的主目录不存在，跳过"
        return
    fi

    local temp_script="/tmp/zsh_install_${username}_$$.sh"

    # 使用强引用的 Here-Doc，防止外部变量干扰
    cat > "$temp_script" << 'USERSCRIPT'
#!/bin/bash
set -euo pipefail

# 接收传入的参数
USERNAME="$1"
USER_HOME="$2"
GH_PREFIX="${3:-https://github.com}"
RAW_PREFIX="${4:-https://raw.githubusercontent.com}"
export HOME="$USER_HOME"
cd "$HOME"

init_terminal_colors() {
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
        COLOR_RESET='\033[0m'
        COLOR_SUCCESS='\033[1;38;5;28m'
        COLOR_WARN='\033[1;38;5;130m'
        COLOR_ERROR='\033[1;38;5;124m'
        COLOR_INFO='\033[1;38;5;25m'
    else
        COLOR_RESET=''
        COLOR_SUCCESS=''
        COLOR_WARN=''
        COLOR_ERROR=''
        COLOR_INFO=''
    fi

    RED="$COLOR_ERROR"
    GREEN="$COLOR_SUCCESS"
    YELLOW="$COLOR_WARN"
    BLUE="$COLOR_INFO"
    NC="$COLOR_RESET"
}
init_terminal_colors

echo -e "${BLUE}[INFO]${NC} 开始为用户 ${USERNAME} 安装..."

if [ ! -d "$HOME/.oh-my-zsh" ]; then
    echo -e "${BLUE}[INFO]${NC} 安装 Oh My Zsh..."
    export RUNZSH=no
    export CHSH=no
    # 让 install.sh 内部的 git clone 也走镜像
    export REMOTE="${GH_PREFIX}/ohmyzsh/ohmyzsh.git"
    sh -c "$(curl -fsSL ${RAW_PREFIX}/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended || {
        echo -e "${RED}[ERROR]${NC} Oh My Zsh 安装失败"
        exit 1
    }
else
    echo -e "${YELLOW}[WARN]${NC} Oh My Zsh 已安装"
fi

install_plugin() {
    local plugin_name="$1"
    local plugin_url="$2"
    local plugin_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/$plugin_name"
    if [ ! -d "$plugin_dir" ]; then
        echo -e "${BLUE}[INFO]${NC} 安装 $plugin_name 插件..."
        git clone "$plugin_url" "$plugin_dir" || {
            echo -e "${YELLOW}[WARN]${NC} $plugin_name 插件安装失败" 
            return 1
        }
    else
        echo -e "${YELLOW}[WARN]${NC} $plugin_name 插件已安装" 
    fi
}

install_plugin "zsh-syntax-highlighting" "${GH_PREFIX}/zsh-users/zsh-syntax-highlighting.git"
install_plugin "zsh-autosuggestions" "${GH_PREFIX}/zsh-users/zsh-autosuggestions"
install_plugin "fzf-tab" "${GH_PREFIX}/Aloxaf/fzf-tab"

if [ -f "$HOME/.zshrc" ]; then
    echo -e "${BLUE}[INFO]${NC} 发现已存在的 .zshrc，开始备份..."
    ls -t "$HOME"/.zshrc.backup.* 2>/dev/null | tail -n +2 | xargs -r rm -f -- || true
    cp "$HOME/.zshrc" "$HOME/.zshrc.backup.$(date +%Y%m%d_%H%M%S)"
fi

cat > "$HOME/.zshrc" << 'EOF'
export ZSH="$HOME/.oh-my-zsh"

# Plugins 
plugins=(
    git
    fzf-tab
    zsh-autosuggestions
    zsh-syntax-highlighting
    command-not-found
    history-substring-search
    colored-man-pages
    extract
    sudo
    catimg
    copybuffer
    copyfile
    copypath
    cp
)

# 1984 Light 友好配色：为浅色背景选择深色、高对比的提示、补全和语法颜色。
export LS_COLORS='di=1;38;5;25:ln=38;5;31:so=38;5;90:pi=38;5;130:ex=1;38;5;28:bd=38;5;124:cd=38;5;124:su=1;38;5;124:sg=1;38;5;90:tw=1;38;5;130:ow=1;38;5;25:*.tar=38;5;124:*.tgz=38;5;124:*.zip=38;5;124:*.gz=38;5;124:*.xz=38;5;124:*.jpg=38;5;90:*.jpeg=38;5;90:*.png=38;5;90:*.gif=38;5;90:*.mp4=38;5;25:*.mkv=38;5;25:*.mp3=38;5;28:*.flac=38;5;28'
FZF_1984_LIGHT_COLORS='--color=fg:#182845,hl:#005f87,fg+:#102033,bg+:#f3dfb0,hl+:#8b1e1e,info:#7a4b00,prompt:#005f73,pointer:#8b1e1e,marker:#0b6b3a,spinner:#5b3f8c,header:#5b3f8c,border:#7a4b00'
if [[ " ${FZF_DEFAULT_OPTS:-} " != *" --color=fg:#182845,hl:#005f87,"* ]]; then
    export FZF_DEFAULT_OPTS="${FZF_DEFAULT_OPTS:+$FZF_DEFAULT_OPTS }$FZF_1984_LIGHT_COLORS"
fi
unset FZF_1984_LIGHT_COLORS
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=31'
typeset -A ZSH_HIGHLIGHT_STYLES
ZSH_HIGHLIGHT_STYLES[comment]='fg=31'
ZSH_HIGHLIGHT_STYLES[command]='fg=25,bold'
ZSH_HIGHLIGHT_STYLES[alias]='fg=28,bold'
ZSH_HIGHLIGHT_STYLES[builtin]='fg=25,bold'
ZSH_HIGHLIGHT_STYLES[function]='fg=25,bold'
ZSH_HIGHLIGHT_STYLES[path]='fg=90'
ZSH_HIGHLIGHT_STYLES[globbing]='fg=130,bold'
ZSH_HIGHLIGHT_STYLES[single-hyphen-option]='fg=130'
ZSH_HIGHLIGHT_STYLES[double-hyphen-option]='fg=130'
ZSH_HIGHLIGHT_STYLES[unknown-token]='fg=124,bold'
ZSH_HIGHLIGHT_STYLES[reserved-word]='fg=90,bold'

# Source oh-my-zsh
source $ZSH/oh-my-zsh.sh

# === CUSTOM CONFIGURATION ===

# fzf-tab configuration
zstyle ':completion:*:git-checkout:*' sort false
zstyle ':completion:*:descriptions' format '[%d]'
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls -1 --color=always $realpath 2>/dev/null || echo "No preview"'
zstyle ':fzf-tab:complete:kill:argument-rest' fzf-preview 'ps aux | grep $word'

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
alias ip='ip -c'
alias dmesg='dmesg --color=always -T'
alias tree='tree -C'
export LESS='-R --use-color'
alias less='less -R'
alias watch='watch --color'

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

# bat 配置：bat 正常调用，cat 走 bat -p -P（plain + 不分页）
if command -v batcat &> /dev/null; then
    alias bat='batcat'
    alias cat='batcat -p -P'
    export BAT_THEME="${BAT_THEME:-GitHub}"
elif command -v bat &> /dev/null; then
    alias cat='bat -p -P'
    export BAT_THEME="${BAT_THEME:-GitHub}"
fi

# Custom functions
mkcd() { mkdir -p "$@" && cd "$_"; }

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
            *)           echo "'$1' cannot be extracted" ;;
        esac
    else
        echo "'$1' is not a valid file"
    fi
}

# 快速查找文件
ff() {
    find / -type f -iname "*$1*" 2>/dev/null
}

# 快速查找目录
fd() {
    find / -type d -iname "*$1*" 2>/dev/null
}

# === END CUSTOM CONFIGURATION ===
fastfetch
eval "$(starship init zsh)"
EOF

mkdir -p "$HOME/.config/fastfetch"

echo -e "${BLUE}[INFO]${NC} 生成 Starship 配置..."
cat > "$HOME/.config/starship.toml" << 'EOF'
add_newline = false

format = """
$directory$character"""

right_format = """
$cmd_duration$git_branch$git_status$username$hostname\
"""

[character]
success_symbol = "[❯](bold fg:#0b6b3a)"
error_symbol = "[❯](bold fg:#8b1e1e)"
vicmd_symbol = "[❮](bold fg:#7a4b00)"

[directory]
style = "bold fg:#005f73"
truncation_length = 3
truncate_to_repo = true
read_only = " 🔒"

[username]
show_always = true
style_root = "bold fg:#8b1e1e"
style_user = "bold fg:#1f4e79"
format = "[$user]($style)"

[hostname]
ssh_only = false
style = "bold fg:#7a4b00"
format = "[@$hostname]($style)"

[git_branch]
symbol = "🌱 "
style = "bold fg:#5b3f8c"
format = " [$symbol$branch]($style)"

[git_status]
style = "bold fg:#8b1e1e"
format = '([ \[$all_status$ahead_behind\]]($style))'

[cmd_duration]
min_time = 2000
style = "bold fg:#7a4b00"
format = " [⏱ $duration]($style) "

[package]
disabled = true

[nodejs]
disabled = false
format = " [🤖 $version](bold fg:#0b6b3a) "

[python]
disabled = false
format = " [🐍 $version](bold fg:#7a4b00) "
EOF

echo -e "${BLUE}[INFO]${NC} 生成 Fastfetch 配置..."
cat > "$HOME/.config/fastfetch/config.jsonc" << 'EOF'
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json", // 用于IDE补全提示，不需要改动

  "logo": {
    "type": "Small", // 系统Logo样式。可以换成 "ubuntu_small", "arch_small", "linux", "tux" 等简单的图标，或者 "debian" 恢复完整大版
    "position": "top", // Logo显示位置。手机端强烈推荐 "top" (顶部居中)，如果你横屏空间很大，可以改回 "left" (左侧) 或 "right" (右侧)
    "color": {
      "1": "blue" // 浅色主题下使用深蓝作为主色，避免亮黄/亮绿发白
    },
    "padding": {
      "top": 0, // 顶部留白行数。如果觉得距离屏幕顶端太近，可以改成 2 或 3
      "left": 0, // 左侧边缘留白字符数。手机端推荐 1 节省空间
      "right": 1 // 右侧边缘留白字符数。手机端推荐 1 节省空间
    }
  },

  "display": {
    //"color": "blue", // 模块图标和进度条的全局强调色。浅色主题推荐 blue/green，避免 yellow
    "color": {
        "keys": "blue",
        "title": "red"
    },
    "separator": ":", // 左侧Key和右侧Value之间的分隔符。可以改成 " ➜ ", " : ", " = " 增加设计感
    "percent": {
      "type": 3 // 进度条样式。3为经典方块[███  ]；9为紧凑圆点 󰪥󰪣；11为圆环饼图；1为极简模式仅显示数字%。如果在手机上因为方块太长导致换行，强烈建议改为 9 或 1
    }
  },

  "modules": [
    {
      "type": "custom", // 自定义模块，通常用来做分类标题或空行
      "format": "\u001b[1;38;5;24m=[ 系统信息 ]=\u001b[0m"
    },
    {
      "type": "os",
      "key": "  系    统" // 左侧显示的名称，可以自由增删空格来控制对齐，或者删掉 Nerd 图标
    },
    {
      "type": "kernel",
      "key": "  内    核"
    },
    {
      "type": "title",
      "key": " 󰌢 主 机 名",
      "format": "{2}"
    },
    {
      "type": "command",
      "key": "  用 户 名",
      "text": "u=$(whoami); if [ \"$u\" = \"root\" ]; then printf '\\033[1;38;5;124m%s\\033[0m' \"$u\"; else printf '\\033[1;38;5;28m%s\\033[0m' \"$u\"; fi"
    },
    {
      "type": "uptime",
      "key": " 󰅐 运行时间", // 原来的"运行"改成了更完整的中文
      "format": "{1}天{2}时{3}分" // 强制使用中文格式输出
    },
    {
      "type": "loadavg",
      "key": "  负    载"
    },
    {
      "type": "localip",
      "key": " 󰩟 IPv4地址",
      "showIpv4": true,
      "showIpv6": false, // 是否显示 IPv6。如果你的机器有且你需要看 IPv6，可以改成 true/false
      "defaultRouteOnly": true // 推荐加上，只显示主要联网网卡的IP，避免输出一堆虚拟网卡
    },
    {
      "type": "localip",
      "key": " 󰩟 IPv6地址",
      "showIpv4": false,
      "showIpv6": true, // 是否显示 IPv6。如果你的机器有且你需要看 IPv6，可以改成 true/false
      "defaultRouteOnly": true // 推荐加上，只显示主要联网网卡的IP，避免输出一堆虚拟网卡
    },
    "break", // 强制插入一个空行。如果觉得太占屏幕，可以直接把这行删掉
    {
      "type": "custom",
      "format": "\u001b[1;38;5;130m=[ 资源使用 ]=\u001b[0m"
    },
    {
      "type": "cpu",
      "key": "  处 理 器",
      "format": "{1} ({4} × {5} cores)" // 自定义 CPU 显示格式。{1}是型号，{4}是架构，{5}是核心数。如果手机屏幕显示不下这一长串，可以直接改成 "{1}" 或删掉 format 这一行
    },
    {
      "type": "cpuusage",
      "key": "  占 用 率",
      "waitTime": 500,
      "format": "{avg-bar} {avg}"
    },
    {
      "type": "memory",
      "key": "  内    存"
    },
    {
      "type": "swap",
      "key": " 󰓡 交换分区",
      "separate": true
    },
    {
      "type": "disk",
      "key": "  磁    盘"
    },
    {
      "type": "processes",
      "key": "  进 程 数"
    },
    "break" // 底部收尾空行，不需要可以删去
  ]
}
EOF

FONT_DIR="$HOME/.local/share/fonts"
mkdir -p "$FONT_DIR"  

echo -e "${BLUE}[INFO]${NC} 安装 Nerd 字体..."
fonts=(
    "${GH_PREFIX}/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Regular.ttf"
    "${GH_PREFIX}/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold.ttf"
    "${GH_PREFIX}/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Italic.ttf"
    "${GH_PREFIX}/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold%20Italic.ttf"
)

for font_url in "${fonts[@]}"; do
    font_name=$(basename "$font_url" | sed 's/%20/ /g')
    if [ ! -f "$FONT_DIR/$font_name" ]; then
        curl -fsSL "$font_url" -o "$FONT_DIR/$font_name" || echo -e "${YELLOW}[WARN]${NC} 无法下载 $font_name"
    fi
done  

if command -v fc-cache &> /dev/null; then
    fc-cache -f "$FONT_DIR" 2>/dev/null || true
fi  

echo -e "${GREEN}[INFO]${NC} 用户 ${USERNAME} 的配置完成！"
USERSCRIPT

    chmod +x "$temp_script"

    # 将用户名、目录及镜像前缀作为参数传递给临时脚本执行
    if [ "$username" == "$USER" ] || ([ "$username" == "root" ] && [ "$IS_ROOT" == "true" ]); then
        bash "$temp_script" "$username" "$user_home" "$GH_PREFIX" "$RAW_PREFIX"
    else
        su - "$username" -c "bash $temp_script '$username' '$user_home' '$GH_PREFIX' '$RAW_PREFIX'"
    fi

    rm -f "$temp_script"  

    if [[ "$user_shell" != */zsh ]]; then
        log_info "为用户 $username 设置默认 shell 为 zsh"  

        local zsh_path=""
        if command_exists zsh; then zsh_path=$(command -v zsh); fi  

        if [ -n "$zsh_path" ]; then
            if [[ "$OS_TYPE" == "macos" ]]; then
                if [ "$username" == "$USER" ]; then chsh -s "$zsh_path"; fi
            elif [ "$IS_ROOT" = "true" ]; then
                usermod -s "$zsh_path" "$username"
            else
                if [ "$username" == "$USER" ]; then chsh -s "$zsh_path"; fi
            fi
        fi
    fi
}  

# ================================================================
# 新用户模板配置（仅限Linux）
# ================================================================  

setup_skel() {
    if [[ "$OS_TYPE" == "macos" ]] || [ "$IS_ROOT" != "true" ]; then return; fi  

    log_info "配置新用户默认模板..."

    # 弱引用 here-doc：把当前判定的镜像前缀固化进生成的脚本；
    # 脚本自身的变量（$HOME 等）需转义以延迟到运行时展开
    cat > /usr/local/bin/auto-setup-zsh << EOF
#!/bin/bash
if [ ! -d "\$HOME/.oh-my-zsh" ] && [ -x /usr/bin/zsh ]; then
    echo "正在为您自动配置 Zsh 环境..."
    export REMOTE="${GH_PREFIX}/ohmyzsh/ohmyzsh.git"
    curl -fsSL ${RAW_PREFIX}/ohmyzsh/ohmyzsh/master/tools/install.sh | sh -s -- --unattended
    echo "配置完成！请重新登录以使用 Zsh。"
fi
EOF

    chmod +x /usr/local/bin/auto-setup-zsh  

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
    echo "║     Zsh 环境自动配置脚本 v$SCRIPT_VERSION        ║"
    echo "║     Enhanced with Oh My Zsh & Starship       ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
}  

show_summary() {
    echo -e "\n${GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              安装完成！                      ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"  

    echo -e "\n${COLOR_SECTION}系统信息：${NC}"
    echo "  • 操作系统: $OS_TYPE"
    echo "  • 包管理器: $PACKAGE_MANAGER"
    echo "  • 安装模式: $([ "$IS_ROOT" = "true" ] && echo "所有用户" || echo "当前用户")"

    echo -e "\n${COLOR_SECTION}已安装组件：${NC}"
    echo "  ✓ Zsh Shell"
    echo "  ✓ Oh My Zsh 框架"
    echo "  ✓ Starship 终端提示符"
    echo "  ✓ Fastfetch 系统信息"
    echo "  ✓ 语法高亮 / 自动建议 / FZF Tab"
    echo "  ✓ MesloLGS NF 字体"
    if command_exists batcat || command_exists bat; then
        echo "  ✓ bat (彩色 cat)"
    fi  

    echo -e "\n${COLOR_SECTION}后续步骤：${NC}"  
    echo -e "1. 重启终端或运行: ${GREEN}exec zsh${NC}"
    echo -e "2. 请确保在终端的偏好设置中将字体改为: ${GREEN}MesloLGS NF${NC}"
    echo "更多插件前往 https://github.com/ohmyzsh/ohmyzsh 查看"

    echo -e "\n${COLOR_SECTION}实用命令：${NC}"
    echo -e "• 编辑 Starship: ${GREEN}nano ~/.config/starship.toml${NC}"
    echo -e "• 更新 Oh My Zsh: ${GREEN}omz update${NC}"  

    if command_exists batcat; then
        echo -e "• 彩色查看文件: ${GREEN}cat <file>${NC} 或 ${GREEN}batcat <file>${NC}"
    elif command_exists bat; then
        echo -e "• 彩色查看文件: ${GREEN}cat <file>${NC} 或 ${GREEN}bat <file>${NC}"
    fi  
}

main() {
    show_banner
    log_info "正在清理旧的日志文件..."
    ls -t "$HOME"/.zsh_install_*.log 2>/dev/null | tail -n +3 | xargs -r rm -f --
    log_info "开始安装 (版本: $SCRIPT_VERSION)"
    log_info "运行用户: $(whoami) (UID: $EUID)"
    log_info "日志文件: $LOG_FILE"

    log_info "=== 系统检测 ==="
    detect_os
    detect_package_manager
    detect_arch

    log_info "=== 网络检测 ==="
    detect_china
    if ! check_network; then
        log_error "无法连接到 GitHub${USE_MIRROR:+ 镜像}，请检查网络连接"
        exit 1
    fi
    log_info "网络连接正常"

    log_info "=== 安装系统包 ==="
    install_system_packages

    log_info "=== 用户配置 ==="
    log_debug "IS_ROOT=$IS_ROOT, OS_TYPE=$OS_TYPE"  

    local users_temp_file="/tmp/zsh_users_$$"
    get_target_users > "$users_temp_file" 2>/dev/null  

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

    while IFS= read -r user_info; do
        if [[ -n "$user_info" ]]; then
            IFS=: read -r username home shell <<< "$user_info"  
            if [[ -n "$username" && -n "$home" && -n "$shell" ]]; then
                log_debug "处理用户: $username"
                install_for_user "$username" "$home" "$shell"
            else
                log_warn "跳过无效的用户信息: $user_info"
            fi
        fi
    done < "$users_temp_file"  

    rm -f "$users_temp_file"

    if [ "$IS_ROOT" = "true" ] && [[ "$OS_TYPE" == "linux" ]]; then
        setup_skel
    fi  

    show_summary
    log_info "所有操作完成！"
}

# ================================================================
# 脚本入口
# ================================================================  

while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            echo "用法: $0 [选项]"
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

main
