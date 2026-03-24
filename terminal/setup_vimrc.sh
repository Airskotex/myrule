#!/bin/bash

# ==========================================
# Vim 配置文件自动化部署脚本
# ==========================================

# 1. 确定目标文件路径 (区分 Root 与普通用户)
if [ "$EUID" -eq 0 ]; then
    # 不同的 Linux 发行版全局 vimrc 路径可能不同
    if [ -f /etc/vim/vimrc ]; then
        TARGET_FILE="/etc/vim/vimrc"  # Debian / Ubuntu 族
    elif [ -f /etc/vimrc ]; then
        TARGET_FILE="/etc/vimrc"      # RHEL / CentOS / Rocky 族
    else
        TARGET_FILE="/etc/vimrc"      # 默认 fallback
    fi
    echo "🔍 检测到当前为 Root 用户，将为所有用户应用全局配置: $TARGET_FILE"
else
    TARGET_FILE="$HOME/.vimrc"
    echo "🔍 检测到当前为普通用户，将仅为当前用户应用配置: $TARGET_FILE"
fi

# 确保目标文件存在，避免后续 sed 执行报错
touch "$TARGET_FILE"

# 2. 清理历史旧配置 (防止重复写入)
# 匹配我们自定义的 BEGIN 和 END 标记，将这之间的内容全部删除
echo "⚙️ 正在清理可能存在的旧配置块以防止冲突..."
sed -i.bak -e '/^" === BEGIN DEVOPS VIMRC ===/,/^" === END DEVOPS VIMRC ===/d' "$TARGET_FILE"

# 3. 写入最新配置
echo "✍️ 正在写入最新 Vim 配置..."

cat << 'EOF' >> "$TARGET_FILE"
" === BEGIN DEVOPS VIMRC ===
""""""""""""""""""""""""""""""""""""""
" vim 运维服务器最小修正版 ~/.vimrc
" by leonshaw 2024.10.12
" 适合 Kubernetes / Ansible / Shell
""""""""""""""""""""""""""""""""""""""

" 编码设置释义
" vim 内部使用的字符编码方式
"set encoding=编码
"set enc=编码
" vim 当前编辑的文件的字符编码方式，保存文件时也使用
"set fileencoding=编码
"set fenc=编码
" vim 打开的文件的字符编码方式，按顺序，最前面的优先
"fileencodings 是一个用逗号分隔的列表，简写 fencs
"set fileencodings=编码
" vim 所工作的终端的字符编码方式
"set termencoding=编码

" 编码设置
set encoding=utf-8
set fileencoding=utf-8
set fencs=utf-8,gb18030,gbk,cp936,gb2312,big5
set termencoding=utf-8

" 语言设置
set langmenu=zh_CN.UTF-8
set helplang=cn,en

" 去掉 vi 的一致性
set nocompatible

" 打开文件类型检测、插件和缩进
filetype plugin indent on

" 显示行号
set number

" 开启语法高亮
syntax on

" 设置字体
"set guifont=Monaco:h13
" solarized 主题设置在终端下的设置
"let g:solarized_termcolors=256

" 设置不自动换行
set nowrap

" 设置以 unix 的格式保存文件（UNIX 系统下默认）
set fileformat=unix
" 打开 dos 文件时可自动识别
set fileformats=unix,dos

" 自动缩进
set autoindent

" Tab 键的宽度 = 4 个空格
set tabstop=4
" 统一缩进为 4
set softtabstop=4
set shiftwidth=4
" expandtab：缩进用空格来表示，noexpandtab：用制表符表示一个缩进
set expandtab

" 不同文件类型缩进
augroup my_vimrc_filetype
  autocmd!
  autocmd FileType yaml         setlocal tabstop=2 shiftwidth=2 softtabstop=2 expandtab
  autocmd FileType json         setlocal tabstop=2 shiftwidth=2 softtabstop=2 expandtab
  autocmd FileType html,css     setlocal tabstop=2 shiftwidth=2 softtabstop=2 expandtab
  autocmd FileType python       setlocal tabstop=4 shiftwidth=4 softtabstop=4 expandtab
  autocmd FileType sh,bash,zsh  setlocal tabstop=4 shiftwidth=4 softtabstop=4 expandtab
  autocmd FileType go           setlocal noexpandtab tabstop=4 shiftwidth=4 softtabstop=4
  autocmd FileType make         setlocal noexpandtab tabstop=8 shiftwidth=8 softtabstop=0
  " Kubernetes / Ansible / Shell 中，回车时不自动延续注释
  autocmd FileType yaml,sh,bash,zsh setlocal formatoptions-=cro
augroup END

" 高亮显示匹配的括号
set showmatch
" 匹配括号高亮的时间（单位是十分之一秒）
set matchtime=5

" 光标移动到 buffer 的顶部和底部时保持 3 行距离
set scrolloff=3

" 启动显示状态行 (1), 总是显示状态行 (2)
set laststatus=2

" 使退格键（backspace）正常处理 indent, eol, start 等
set backspace=indent,eol,start

" 服务器 / SSH 场景下为了方便复制，默认关闭鼠标
" 如需开启可改回：set mouse=a
set mouse=a

" 搜索忽略大小写
set ignorecase
" 搜索中有大写字母时自动区分大小写
set smartcase
" 高亮显示匹配字符（回车后）
set hlsearch
" 搜索实时高亮显示所有匹配的字符
set incsearch

" 设置当文件被改动时自动载入
set autoread

" 突出显示当前行
set cursorline

" 打开标尺，在屏幕右下角显示当前光标所处位置（设置了 statusline 可以忽略）
set ruler
" 状态行显示的内容
set statusline=\ %<%F[%1*%M%*%n%R%H]%=\ %y\ %0(%{&fileformat}\ %{strlen(&fenc)?&fenc:&enc}\ %l,%c%)\ %p%%

" 显示 Tab 键和行尾空格
set list
set listchars=tab:→·,trail:□

" 粘贴 Kubernetes YAML / Ansible Playbook / Shell 脚本时很好用
set pastetoggle=<F2>

" 服务器安全场景下，不启用 modeline
set nomodeline
" === END DEVOPS VIMRC ===
EOF

# 4. 验证写入结果
if grep -q '" === BEGIN DEVOPS VIMRC ===' "$TARGET_FILE"; then
    echo "✅ 配置部署成功！"
    echo "💡 提示：原文件备份已保存为 ${TARGET_FILE}.bak"
else
    echo "❌ 错误：配置写入失败，请检查文件权限。"
    exit 1
fi
