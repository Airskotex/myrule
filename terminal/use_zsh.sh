#!/bin/bash

# 启用错误处理
set -euo pipefail
trap 'echo "错误发生在第 $LINENO 行，命令: $BASH_COMMAND"' ERR

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# 检查命令是否存在
check_command() {
    if ! command -v "$1" &> /dev/null; then
        return 1
    fi
    return 0
}

# 1. 检查是否已经是 Zsh
if [[ "$SHELL" == *"zsh"* ]]; then
    log_warn "已经在使用 Zsh"
fi

# 2. 更新系统并安装必要软件包
log_info "检查并安装必要的软件包..."
packages=("zsh" "git" "curl" "wget" "fonts-powerline" "fzf")
to_install=()

for pkg in "${packages[@]}"; do
    if ! dpkg -l | grep -q "^ii  $pkg "; then
        to_install+=("$pkg")
    else
        log_info "$pkg 已安装"
    fi
done

if [ ${#to_install[@]} -gt 0 ]; then
    log_info "安装: ${to_install[*]}"
    sudo apt update && sudo apt install -y "${to_install[@]}"
else
    log_info "所有必要软件包已安装"
fi

# 3. 检查并安装 Oh My Zsh
if [ -d "$HOME/.oh-my-zsh" ]; then
    log_warn "Oh My Zsh 已安装，跳过安装"
else
    log_info "安装 Oh My Zsh..."
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi

# 4. 检查并安装 Powerlevel10k 主题
P10K_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
if [ -d "$P10K_DIR" ]; then
    log_warn "Powerlevel10k 已安装，更新中..."
    cd "$P10K_DIR" && git pull
else
    log_info "安装 Powerlevel10k..."
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_DIR"
fi

# 5. 安装插件函数
install_plugin() {
    local plugin_name="$1"
    local plugin_url="$2"
    local plugin_dir="${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/$plugin_name"
    
    if [ -d "$plugin_dir" ]; then
        log_warn "$plugin_name 插件已安装，更新中..."
        cd "$plugin_dir" && git pull
    else
        log_info "安装 $plugin_name 插件..."
        git clone "$plugin_url" "$plugin_dir"
    fi
}

# 安装各插件
install_plugin "zsh-syntax-highlighting" "https://github.com/zsh-users/zsh-syntax-highlighting.git"
install_plugin "zsh-autosuggestions" "https://github.com/zsh-users/zsh-autosuggestions"
install_plugin "fzf-tab" "https://github.com/Aloxaf/fzf-tab"

# 6. 备份原始 .zshrc
if [ -f "$HOME/.zshrc" ] && [ ! -f "$HOME/.zshrc.backup" ]; then
    log_info "备份原始 .zshrc..."
    cp "$HOME/.zshrc" "$HOME/.zshrc.backup"
fi

# 7. 配置主题（只修改一次）
if ! grep -q "ZSH_THEME=\"powerlevel10k/powerlevel10k\"" "$HOME/.zshrc"; then
    log_info "配置 Powerlevel10k 主题..."
    sed -i 's/ZSH_THEME=".*"/ZSH_THEME="powerlevel10k\/powerlevel10k"/' "$HOME/.zshrc"
else
    log_warn "主题已配置"
fi

# 8. 配置插件（检查避免重复）
if ! grep -q "zsh-syntax-highlighting" "$HOME/.zshrc"; then
    log_info "配置插件..."
    # 查找 plugins=() 行并替换
    sed -i '/^plugins=/c\plugins=(\n    git\n    fzf-tab\n    zsh-autosuggestions\n    zsh-syntax-highlighting\n)' "$HOME/.zshrc"
else
    log_warn "插件已配置"
fi

# 9. 添加自定义配置（检查标记避免重复）
if ! grep -q "# === CUSTOM ZSH CONFIG START ===" "$HOME/.zshrc"; then
    log_info "添加自定义配置..."
    cat >> "$HOME/.zshrc" << 'EOF'

# === CUSTOM ZSH CONFIG START ===
# fzf-tab 配置
zstyle ':completion:*:git-checkout:*' sort false
zstyle ':completion:*:descriptions' format '[%d]'
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls -1 --color=always $realpath'
zstyle ':fzf-tab:complete:kill:argument-rest' fzf-preview 'ps aux | grep $word'

# 彩色输出别名
alias ls='ls --color=auto'
alias ll='ls -lh'
alias la='ls -lah'
alias grep='grep --color=auto'

# 快捷命令别名
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# 其他实用别名
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -i'
alias mkdir='mkdir -pv'
alias df='df -h'
alias du='du -h'
alias free='free -h'
# === CUSTOM ZSH CONFIG END ===
EOF
else
    log_warn "自定义配置已存在"
fi

# 10. 安装字体（检查避免重复下载）
FONT_DIR="$HOME/.local/share/fonts"
mkdir -p "$FONT_DIR"

install_font() {
    local font_url="$1"
    local font_name=$(basename "$font_url" | sed 's/%20/ /g')
    
    if [ -f "$FONT_DIR/$font_name" ]; then
        log_warn "字体 $font_name 已存在"
    else
        log_info "下载字体 $font_name..."
        wget -q "$font_url" -O "$FONT_DIR/$font_name"
    fi
}

# 安装各字体
install_font "https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Regular.ttf"
install_font "https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold.ttf"
install_font "https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Italic.ttf"
install_font "https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold%20Italic.ttf"

# 更新字体缓存
log_info "更新字体缓存..."
fc-cache -f

# 11. 设置 Zsh 为默认 Shell（如果需要）
CURRENT_SHELL=$(basename "$SHELL")
if [ "$CURRENT_SHELL" != "zsh" ]; then
    log_info "设置 Zsh 为默认 Shell..."
    if chsh -s $(which zsh); then
        log_info "默认 Shell 已更改为 Zsh"
    else
        log_error "无法更改默认 Shell，请手动运行: chsh -s $(which zsh)"
    fi
else
    log_warn "Zsh 已经是默认 Shell"
fi

# 12. 完成提示
echo -e "\n${GREEN}======================================${NC}"
echo -e "${GREEN}安装完成！${NC}"
echo -e "${GREEN}======================================${NC}"
echo -e "\n请执行以下操作："
echo -e "1. 重新启动终端或运行: ${YELLOW}exec zsh${NC}"
echo -e "2. 首次启动时会运行 Powerlevel10k 配置向导"
echo -e "3. 记得在终端设置中将字体改为 ${YELLOW}MesloLGS NF${NC}"
echo -e "\n如需重新配置主题，运行: ${YELLOW}p10k configure${NC}"
