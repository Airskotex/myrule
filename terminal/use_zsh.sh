#!/bin/bash

# 1. 更新系统并安装必要软件包
sudo apt update && \
sudo apt install -y \
    zsh \
    git \
    curl \
    wget \
    fonts-powerline \
    fzf  # fzf-tab 的依赖

# 2. 安装 Oh My Zsh（无人值守模式）
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

# 3. 安装 Powerlevel10k 主题
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
    ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k

# 4. 安装插件
# 4.1 语法高亮插件
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git \
    ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting

# 4.2 自动建议插件
git clone https://github.com/zsh-users/zsh-autosuggestions \
    ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions

# 4.3 fzf-tab 插件
git clone https://github.com/Aloxaf/fzf-tab \
    ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/fzf-tab

# 5. 配置主题
sed -i 's/ZSH_THEME="robbyrussell"/ZSH_THEME="powerlevel10k\/powerlevel10k"/' ~/.zshrc

# 6. 配置插件（注意加载顺序）
sed -i 's/plugins=(git)/plugins=(\n    git\n    fzf-tab\n    zsh-autosuggestions\n    zsh-syntax-highlighting\n)/' ~/.zshrc

# 7. 添加自定义配置（fzf-tab 配置 + 实用别名）
cat >> ~/.zshrc << 'EOF'

# ===== fzf-tab 配置 =====
# 禁用排序（对 git checkout 等命令有用）
zstyle ':completion:*:git-checkout:*' sort false
# 设置描述格式以启用分组支持
zstyle ':completion:*:descriptions' format '[%d]'
# 设置颜色
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}
# 预览目录内容
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls -1 --color=always $realpath'
# kill 命令的进程预览
zstyle ':fzf-tab:complete:kill:argument-rest' fzf-preview 'ps aux | grep $word'

# ===== 彩色输出别名 =====
alias ls='ls --color=auto'
alias ll='ls -lh'
alias la='ls -lah'
alias grep='grep --color=auto'

# ===== 快捷命令别名 =====
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# ===== 其他实用别名 =====
# 文件操作
alias cp='cp -i'  # 交互式复制（防止覆盖）
alias mv='mv -i'  # 交互式移动（防止覆盖）
alias rm='rm -i'  # 交互式删除（防止误删）
alias mkdir='mkdir -pv'  # 创建目录时显示过程

# 系统信息
alias df='df -h'  # 人类可读的磁盘使用情况
alias du='du -h'  # 人类可读的目录大小
alias free='free -h'  # 人类可读的内存使用情况

# 网络
alias ports='netstat -tulanp'  # 显示所有端口

# 历史记录
alias h='history'  
alias hgrep='history | grep'

# 压缩/解压
alias tgz='tar -xzvf'  # 解压 tar.gz
alias tbz='tar -xjvf'  # 解压 tar.bz2

EOF

# 8. 下载并安装 MesloLGS NF 字体
mkdir -p ~/.local/share/fonts && \
cd ~/.local/share/fonts && \
wget -q https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Regular.ttf && \
wget -q https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold.ttf && \
wget -q https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Italic.ttf && \
wget -q https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold%20Italic.ttf && \
fc-cache -f && \
cd ~

# 9. 设置 Zsh 为默认 Shell
chsh -s $(which zsh)

# 10. 启动 Zsh
exec zsh
