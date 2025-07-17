好的，我已经分析了您提供的 `use_zsh.sh` 脚本。该脚本功能强大，结构清晰。根据您“优化显示和输出”的要求，我对脚本中的用户交互部分，特别是横幅（Banner）和总结（Summary）部分，进行了重新设计，使其更具视觉吸引力、信息结构更清晰、指引更明确。

以下是优化后的脚本。核心功能和安装逻辑保持不变，主要改进了输出的美观度和可读性。

### 主要优化点：

1.  **全新的视觉横幅 (`show_banner`)**:

      * 使用更具现代感的 ASCII 艺术字和线条，使脚本启动时的界面更加醒目和专业。

2.  **结构化和美化的总结信息 (`show_summary`)**:

      * **信息分组**: 将总结信息清晰地分为“系统信息”、“已安装组件”、“后续步骤”和“实用命令”四个部分，并使用 Emoji 图标引导，一目了然。
      * **增强可读性**: 大量使用颜色、粗体和缩进，突出关键信息（如需要用户操作的命令和字体名称），方便用户快速定位。
      * **清晰的操作指引**: “后续步骤”部分采用编号列表，为不同操作系统和权限的用户提供精确、易于遵循的指导。
      * **美化列表**: 使用 `✓` 符号表示已成功安装的组件，比简单的文字列表更直观。

3.  **突出的章节标题**:

      * 在 `main` 函数中，将 `log_info "=== ... ==="` 这种章节分隔符的输出，用更显眼的颜色（紫色）和格式进行包裹，使得脚本执行过程中的各个阶段划分更加清晰。

4.  **语言润色**:

      * 对所有面向用户的中文提示语进行了微调，使其表达更自然、更友好。

-----

### 优化后的脚本代码

您可以直接复制以下完整代码使用。

```bash
#!/bin/bash

# ================================================================
# Zsh 环境自动配置脚本 v0.5 (优化显示版)
# 支持：Debian/Ubuntu (apt)、RHEL/CentOS (yum/dnf)、macOS (brew)
# ================================================================

# 启用严格的错误处理
set -euo pipefail
trap 'error_handler $? $LINENO "$BASH_COMMAND"' ERR

# 全局变量
SCRIPT_VERSION="0.5"
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
CYAN='\033[0;36m'
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
            : # yum/dnf 通常不需要手动更新索引
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
                apt) echo "batcat" ;; # 在较新的 Debian/Ubuntu 中是 batcat
                yum|dnf|brew) echo "bat" ;;
                *) echo "" ;;
            esac
            ;;
        "fzf")
            echo "fzf"
            ;;
        "fonts-powerline")
            case "$PACKAGE_MANAGER" in
                apt) echo "fonts-powerline" ;;
                yum|dnf) echo "powerline-fonts" ;;
                brew) echo "" ;;
                *) echo "" ;;
            esac
            ;;
        "fontconfig")
            case "$PACKAGE_MANAGER" in
                apt|yum|dnf) echo "fontconfig" ;;
                brew) echo "" ;;
                *) echo "" ;;
            esac
            ;;
        *)
            echo "$generic_name"
            ;;
    esac
}

# 安装必要的软件包
install_system_packages() {
    log_info "检查并安装必要的软件包..."
    
    local generic_packages=("zsh" "git" "curl" "wget" "fonts-powerline" "fzf" "bat" "fontconfig")
    local to_install=()
    
    for generic_pkg in "${generic_packages[@]}"; do
        local actual_pkg=$(get_package_name "$generic_pkg")
        
        if [ -n "$actual_pkg" ]; then
            if ! is_package_installed "$actual_pkg" && ! command_exists "${generic_pkg%%-*}" && ! command_exists "batcat"; then
                to_install+=("$actual_pkg")
            else
                log_debug "包 '$actual_pkg' 或等效命令已安装。"
            fi
        fi
    done
    
    if [ ${#to_install[@]} -gt 0 ]; then
        log_info "将要安装的包: ${to_install[*]}"
        update_package_index
        
        for pkg in "${to_install[@]}"; do
            log_info "正在安装 $pkg..."
            if ! install_package "$pkg"; then
                log_warn "无法安装 $pkg，脚本将继续运行..."
            fi
        done
    else
        log_info "所有必要的系统软件包均已安装。"
    fi
}


# ================================================================
# 用户安装函数
# ================================================================

# 获取所有需要配置的用户
get_target_users() {
    if [[ "$OS_TYPE" == "macos" ]]; then
        # macOS：只为当前用户安装
        echo "$USER:$HOME:$SHELL"
    elif [ "$IS_ROOT" = "true" ]; then
        # 先输出 root 用户
        echo "root:/root:/bin/bash"
        
        # 然后输出普通用户 (UID >= 1000)
        awk -F: '$3 >= 1000 && $6 != "" && $7 !~ /(false|nologin)$/ {print $1":"$6":"$7}' /etc/passwd | while read -r line; do
            local username="${line%%:*}"
            local skip=false
            
            for skip_user in "${SKIP_USERS[@]}"; do
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

# 检查网络连接
check_network() {
    local test_urls=("https://github.com" "https://raw.githubusercontent.com")
    
    for url in "${test_urls[@]}"; do
        if curl -fsS --connect-timeout 5 -o /dev/null "$url" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# 为单个用户安装配置
install_for_user() {
    local username="$1"
    local user_home="$2"
    local user_shell="$3"
    
    echo -e "${CYAN}--------------------------------------------------${NC}"
    log_info "开始为用户 ${YELLOW}$username${NC} 配置Zsh环境..."
    echo -e "${CYAN}--------------------------------------------------${NC}"
    
    if [ ! -d "$user_home" ]; then
        log_warn "用户 $username 的主目录 '$user_home' 不存在，跳过。"
        return
    fi
    
    local temp_script="/tmp/zsh_install_${username}_$$.sh"
    
    # 使用heredoc创建用户安装脚本
    cat > "$temp_script" << USERSCRIPT
#!/bin/bash
set -euo pipefail

# 用户级别的安装脚本
export HOME="$user_home"
cd "\$HOME"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "\${GREEN}[INFO]\${NC} 在用户 ${YELLOW}${username}${NC} 环境内开始执行安装..."

# 安装 Oh My Zsh
if [ ! -d "\$HOME/.oh-my-zsh" ]; then
    echo -e "\${GREEN}[INFO]\${NC} 正在安装 Oh My Zsh..."
    export RUNZSH=no
    export CHSH=no
    sh -c "\$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended || {
        echo -e "\${RED}[ERROR]\${NC} Oh My Zsh 安装失败。"
        exit 1
    }
else
    echo -e "\${YELLOW}[WARN]\${NC} Oh My Zsh 已存在，跳过安装。"
fi

# 安装 Powerlevel10k 主题
P10K_DIR="\${ZSH_CUSTOM:-\$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
if [ ! -d "\$P10K_DIR" ]; then
    echo -e "\${GREEN}[INFO]\${NC} 正在安装 Powerlevel10k 主题..."
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "\$P10K_DIR" || {
        echo -e "\${RED}[ERROR]\${NC} Powerlevel10k 安装失败。"
        exit 1
    }
else
    echo -e "\${YELLOW}[WARN]\${NC} Powerlevel10k 已存在，跳过安装。"
fi

# 插件安装函数
install_plugin() {
    local plugin_name="\$1"
    local plugin_url="\$2"
    local plugin_dir="\${ZSH_CUSTOM:-\$HOME/.oh-my-zsh/custom}/plugins/\$plugin_name"
    
    if [ ! -d "\$plugin_dir" ]; then
        echo -e "\${GREEN}[INFO]\${NC} 正在安装插件: \$plugin_name..."
        git clone --depth=1 "\$plugin_url" "\$plugin_dir" || {
            echo -e "\${YELLOW}[WARN]\${NC} 插件 \$plugin_name 安装失败，请稍后手动尝试。"
            return 1
        }
    else
        echo -e "\${YELLOW}[WARN]\${NC} 插件 \$plugin_name 已存在，跳过安装。"
    fi
}

# 安装常用插件
install_plugin "zsh-syntax-highlighting" "https://github.com/zsh-users/zsh-syntax-highlighting.git"
install_plugin "zsh-autosuggestions" "https://github.com/zsh-users/zsh-autosuggestions.git"
install_plugin "fzf-tab" "https://github.com/Aloxaf/fzf-tab.git"

# 备份并创建 .zshrc
ZSHRC_FILE="\$HOME/.zshrc"
if [ -f "\$ZSHRC_FILE" ] && [ ! -f "\$ZSHRC_FILE.backup" ]; then
    echo -e "\${GREEN}[INFO]\${NC} 发现已存在的 .zshrc 文件，备份为 .zshrc.backup"
    mv "\$ZSHRC_FILE" "\$ZSHRC_FILE.backup"
fi

# 创建 .zshrc 配置文件
cat > "\$ZSHRC_FILE" << 'EOF'
# Oh My Zsh 路径
export ZSH="\$HOME/.oh-my-zsh"

# 主题设置 (Powerlevel10k)
ZSH_THEME="powerlevel10k/powerlevel10k"

# 插件列表
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

# 加载 Oh My Zsh
source \$ZSH/oh-my-zsh.sh

# --- 自定义配置 ---

# Powerlevel10k 即时提示 (Instant Prompt)
if [[ -r "\${XDG_CACHE_HOME:-\$HOME/.cache}/p10k-instant-prompt-\${(%):-%n}.zsh" ]]; then
  source "\${XDG_CACHE_HOME:-\$HOME/.cache}/p10k-instant-prompt-\${(%):-%n}.zsh"  
fi

# 历史记录配置
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt APPEND_HISTORY           # 追加历史
setopt EXTENDED_HISTORY         # 记录时间戳和执行时长
setopt HIST_EXPIRE_DUPS_FIRST   # 优先删除旧的重复项
setopt HIST_IGNORE_DUPS         # 不记录重复命令
setopt HIST_IGNORE_ALL_DUPS     # 删除所有重复项
setopt HIST_FIND_NO_DUPS        # 查找时不显示重复项
setopt HIST_IGNORE_SPACE        # 忽略空格开头的命令
setopt HIST_VERIFY              # 执行前显示历史命令
setopt SHARE_HISTORY            # 在所有终端间共享历史

# 别名 (Alias)
alias ls='ls --color=auto'
alias ll='ls -alhF'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias diff='diff --color=auto'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -i'
alias mkdir='mkdir -pv'
alias df='df -h'
alias du='du -h'
alias free='free -h'

# bat 命令配置 (如果存在)
if command -v batcat &> /dev/null; then
    alias cat='batcat'
    export BAT_THEME="TwoDark"
elif command -v bat &> /dev/null; then
    alias cat='bat'
    export BAT_THEME="TwoDark"
fi

# 加载 Powerlevel10k 配置文件 (如果存在)
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# --- 自定义配置结束 ---
EOF

# 安装推荐字体 (MesloLGS NF)
FONT_DIR="\$HOME/.local/share/fonts"
mkdir -p "\$FONT_DIR"

echo -e "\${GREEN}[INFO]\${NC} 正在下载并安装 MesloLGS Nerd Font..."
fonts=(
    "https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Regular.ttf"
    "https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold.ttf"
    "https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Italic.ttf"
    "https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold%20Italic.ttf"
)

for font_url in "\${fonts[@]}"; do
    font_name=\$(basename "\$font_url" | sed 's/%20/ /g')
    if [ ! -f "\$FONT_DIR/\$font_name" ]; then
        curl -fsSL -o "\$FONT_DIR/\$font_name" "\$font_url" || echo -e "\${YELLOW}[WARN]\${NC} 字体 \$font_name 下载失败。"
    fi
done

# 更新系统字体缓存
if command -v fc-cache &> /dev/null; then
    fc-cache -fv "\$FONT_DIR" >/dev/null 2>&1 || true
fi

echo -e "\${GREEN}[SUCCESS]\${NC} 用户 ${YELLOW}${username}${NC} 的 Zsh 环境配置完成！"
USERSCRIPT
    
    chmod +x "$temp_script"
    
    # 以对应用户身份执行脚本
    if [ "$username" == "$USER" ] || ([ "$username" == "root" ] && [ "$IS_ROOT" == "true" ]); then
        bash "$temp_script"
    else
        su - "$username" -c "bash $temp_script"
    fi
    
    rm -f "$temp_script"
    
    # 更改用户的默认 shell
    if [[ "$user_shell" != */zsh ]]; then
        log_info "正在为用户 ${YELLOW}$username${NC} 设置默认 shell 为 zsh..."
        if command_exists zsh; then
            local zsh_path=$(command -v zsh)
            if [ "$IS_ROOT" = "true" ]; then
                # root 用户可以为任何用户更改 shell
                usermod -s "$zsh_path" "$username"
            elif [ "$username" == "$USER" ]; then
                # 普通用户只能为自己更改 (需要输入密码)
                log_info "需要您输入密码来将 Zsh 设置为默认 Shell。"
                chsh -s "$zsh_path"
            fi
        else
            log_warn "未找到 zsh 命令，无法更改默认 shell。"
        fi
    fi
}

# ================================================================
# 新用户模板配置 (仅限Linux Root)
# ================================================================

setup_skel() {
    if [[ "$OS_TYPE" == "macos" ]] || [ "$IS_ROOT" != "true" ]; then
        return
    fi
    
    log_info "配置新用户环境模板 (/etc/skel)..."
    
    local skel_zshrc_path="/etc/skel/.zshrc"
    
    if [ -f "$HOME/.zshrc" ]; then
        cp "$HOME/.zshrc" "$skel_zshrc_path"
        # 修正模板中的 $HOME 为变量
        sed -i 's|export ZSH=".*"|export ZSH="$HOME/.oh-my-zsh"|g' "$skel_zshrc_path"
        log_info ".zshrc 模板已复制到 /etc/skel"
    else
        log_warn "Root 用户的 .zshrc 未找到，无法为新用户创建模板。"
    fi
}


# ================================================================
# 主函数
# ================================================================

show_banner() {
    echo -e "${PURPLE}"
    echo '  ███████╗██╗   ██╗███████╗██╗  ██╗'
    echo '  ╚══███╔╝██║   ██║██╔════╝██║  ██║'
    echo '   ███╔╝  ██║   ██║███████╗███████║'
    echo '  ███╔╝   ╚██╗ ██╔╝╚════██║██╔══██║'
    echo '  ███████╗ ╚████╔╝ ███████║██║  ██║'
    echo '  ╚══════╝  ╚═══╝  ╚══════╝╚═╝  ╚═╝'
    echo -e "${NC}"
    echo -e "${CYAN}--- Zsh & Oh My Zsh & Powerlevel10k 全自动配置脚本 v$SCRIPT_VERSION ---${NC}"
    echo
}

show_summary() {
    echo -e "\n${GREEN}============================================================${NC}"
    echo -e "${GREEN}      🎉 安装全部完成！下面是您的环境信息和后续步骤。 🎉      ${NC}"
    echo -e "${GREEN}============================================================${NC}"
    
    echo -e "\n${YELLOW}🖥️  系统信息${NC}"
    echo "  - 操作系统: $OS_TYPE"
    echo "  - 包管理器: $PACKAGE_MANAGER"
    echo "  - 安装模式: $([ "$IS_ROOT" = "true" ] && echo "全局 (所有用户)" || echo "仅限当前用户 ($USER)")"
    
    echo -e "\n${YELLOW}✅  已安装组件${NC}"
    echo "  ✓ Zsh Shell 环境"
    echo "  ✓ Oh My Zsh 管理框架"
    echo "  ✓ Powerlevel10k 高性能主题"
    echo "  ✓ zsh-syntax-highlighting (命令语法高亮)"
    echo "  ✓ zsh-autosuggestions (命令自动建议)"
    echo "  ✓ fzf-tab (交互式Tab补全)"
    echo "  ✓ MesloLGS NF 专用字体"
    if command_exists batcat || command_exists bat; then
        echo "  ✓ bat (一个更好的 'cat')"
    fi
    
    echo -e "\n${YELLOW}🚀  后续步骤${NC}"
    echo -e "  1. ${CYAN}请完全关闭并重新打开您的终端, 或在当前窗口输入 \`exec zsh\` 来加载新环境。${NC}"
    echo -e "  2. ${CYAN}首次启动时，Powerlevel10k 会自动运行配置向导。请根据提示完成个性化设置。${NC}"
    echo -e "     (如果向导未出现，可以手动运行 \`p10k configure\`)"
    echo -e "  3. ${CYAN}为了获得最佳视觉效果，请在您的终端设置中，将字体更改为 ${PURPLE}MesloLGS NF${NC}。${NC}"
    
    echo -e "\n${YELLOW}💡  实用命令${NC}"
    echo -e "  - ${GREEN}p10k configure${NC}  : 重新运行 Powerlevel10k 的配置向导。"
    echo -e "  - ${GREEN}omz update${NC}       : 更新 Oh My Zsh、插件和主题。"
    if command_exists batcat; then
        echo -e "  - ${GREEN}cat <文件名>${NC}      : 使用 batcat 彩色显示文件内容。"
    elif command_exists bat; then
        echo -e "  - ${GREEN}cat <文件名>${NC}      : 使用 bat 彩色显示文件内容。"
    fi
    echo -e "  - ${GREEN}omz plugin list${NC}  : 查看所有可用插件。更多信息请访问 Oh My Zsh 官网。"
    
    echo -e "\n安装日志已保存至: ${BLUE}$LOG_FILE${NC}"
}

main() {
    show_banner
    
    log_info "脚本启动 (版本: $SCRIPT_VERSION)，用户: $(whoami)，UID: $EUID"
    log_info "日志文件位于: $LOG_FILE"
    
    echo -e "${PURPLE}==> 1. 系统环境检测...${NC}"
    detect_os
    detect_package_manager
    
    echo -e "${PURPLE}==> 2. 网络连接检查...${NC}"
    if ! check_network; then
        log_error "无法连接到 GitHub。请检查您的网络连接或代理设置。"
        exit 1
    fi
    log_info "网络连接正常，可以访问 GitHub。"
    
    echo -e "${PURPLE}==> 3. 安装系统依赖包...${NC}"
    install_system_packages
    
    echo -e "${PURPLE}==> 4. 为用户配置环境...${NC}"
    local users_temp_file="/tmp/zsh_users_$$"
    get_target_users > "$users_temp_file"
    
    local user_count=$(wc -l < "$users_temp_file" | tr -d ' ')
    if [ "$user_count" -eq 0 ]; then
        log_error "未能找到任何符合条件的用户进行配置。"
        rm -f "$users_temp_file"
        exit 1
    fi
    
    log_info "检测到 $user_count 个目标用户，将逐一进行配置。"
    
    while IFS= read -r user_info || [[ -n "$user_info" ]]; do
        IFS=: read -r username home shell <<< "$user_info"
        if [[ -n "$username" && -n "$home" && -n "$shell" ]]; then
            install_for_user "$username" "$home" "$shell"
        else
            log_warn "检测到无效的用户行，跳过: $user_info"
        fi
    done < "$users_temp_file"
    
    rm -f "$users_temp_file"
    
    if [ "$IS_ROOT" = "true" ] && [[ "$OS_TYPE" == "linux" ]]; then
        echo -e "${PURPLE}==> 5. 配置新用户模板...${NC}"
        setup_skel
    fi
    
    show_summary
    
    log_info "所有任务执行完毕！"
}

# ================================================================
# 脚本入口
# ================================================================

# 处理 --help 参数
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "用法: bash $0"
    echo
    echo "Zsh 环境全自动配置脚本。"
    echo "它会自动检测操作系统和用户权限，并执行相应操作："
    echo "  - 以 root 用户运行时: 为系统中所有符合条件的普通用户和root用户安装。"
    echo "  - 以普通用户运行时: 仅为当前登录的用户安装。"
    echo
    echo "支持的系统:"
    echo "  - Debian / Ubuntu (及其衍生版)"
    echo "  - RHEL / CentOS / Fedora (及其衍生版)"
    echo "  - macOS (需要预先安装 Homebrew)"
    exit 0
fi

# 执行主函数
main

```
