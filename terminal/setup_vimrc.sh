#!/usr/bin/env bash
# ==========================================
# Vim / NeoVim 配置文件自动化部署脚本
# 兼容: Debian/Ubuntu, RHEL/CentOS/Rocky/Alma,
#        Arch, openSUSE, Alpine, macOS(Homebrew)
# ==========================================

set -euo pipefail

# ---------- 版本 ----------
SCRIPT_VERSION="2.2.0"

# ---------- 颜色与输出 ----------
if [ -t 1 ] && command -v tput &>/dev/null && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    C_RED=$(tput setaf 1)
    C_GREEN=$(tput setaf 2)
    C_YELLOW=$(tput setaf 3)
    C_CYAN=$(tput setaf 6)
    C_RESET=$(tput sgr0)
else
    C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_RESET=""
fi

info()  { printf '%s[INFO]%s  %s\n'  "$C_CYAN"   "$C_RESET" "$*"; }
ok()    { printf '%s[ OK ]%s  %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf '%s[WARN]%s  %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()   { printf '%s[ERR ]%s  %s\n'  "$C_RED"    "$C_RESET" "$*" >&2; }

# ---------- 全局变量 ----------
MARKER_BEGIN='" === BEGIN DEVOPS VIMRC ==='
MARKER_END='" === END DEVOPS VIMRC ==='
DRY_RUN=0
DO_UNINSTALL=0
FORCE_SCOPE=""   # user | global
ALSO_NEOVIM=0
TARGET_FILE=""

# ---------- 帮助 ----------
usage() {
    cat <<HELP
用法: $(basename "$0") [选项]

选项:
  -h, --help       显示本帮助信息
  -v, --version    显示脚本版本
  -u, --uninstall  卸载（移除自定义配置块）
  -n, --dry-run    模拟运行，不实际修改文件
  --user           强制安装到当前用户 (~/.vimrc)
  --global         强制安装到全局 vimrc（需要 root）
  --neovim         同时为 NeoVim 部署配置

示例:
  sudo $(basename "$0")            # root 全局部署
  $(basename "$0")                 # 普通用户部署
  $(basename "$0") --neovim        # 同时部署 NeoVim
  $(basename "$0") --uninstall     # 卸载自定义配置
HELP
}

# ---------- 参数解析 ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)      usage; exit 0 ;;
        -v|--version)   echo "$SCRIPT_VERSION"; exit 0 ;;
        -u|--uninstall) DO_UNINSTALL=1 ;;
        -n|--dry-run)   DRY_RUN=1 ;;
        --user)         FORCE_SCOPE="user" ;;
        --global)       FORCE_SCOPE="global" ;;
        --neovim)       ALSO_NEOVIM=1 ;;
        *)              err "未知选项: $1"; usage; exit 1 ;;
    esac
    shift
done

# ---------- 检测 vim 是否安装 ----------
check_vim_installed() {
    if ! command -v vim &>/dev/null && ! command -v nvim &>/dev/null; then
        err "未检测到 vim 或 nvim，请先安装。"
        exit 1
    fi
}

# ---------- 检测操作系统 ----------
detect_os() {
    if [[ "$OSTYPE" == darwin* ]]; then
        echo "macos"
    elif [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        case "${ID:-unknown}" in
            ubuntu|debian|linuxmint|pop|kali|raspbian|deepin|uos)  echo "debian" ;;
            rhel|centos|rocky|almalinux|ol|fedora|amzn|anolis|openEuler) echo "rhel" ;;
            arch|manjaro|endeavouros|garuda)          echo "arch" ;;
            opensuse*|sles|suse)                      echo "suse" ;;
            alpine)                                   echo "alpine" ;;
            *)                                        echo "unknown" ;;
        esac
    elif [ -f /etc/redhat-release ]; then
        echo "rhel"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/arch-release ]; then
        echo "arch"
    elif [ -f /etc/alpine-release ]; then
        echo "alpine"
    else
        echo "unknown"
    fi
}

# ---------- 确定目标文件路径 ----------
resolve_target() {
    local scope="$FORCE_SCOPE"
    local distro
    distro=$(detect_os)

    # 如果未指定 scope，按 EUID 自动判断
    if [ -z "$scope" ]; then
        if [ "${EUID:-$(id -u)}" -eq 0 ]; then
            scope="global"
        else
            scope="user"
        fi
    fi

    if [ "$scope" = "global" ]; then
        if [ "${EUID:-$(id -u)}" -ne 0 ]; then
            err "全局部署需要 root 权限，请使用 sudo 运行。"
            exit 1
        fi
        case "$distro" in
            debian)  TARGET_FILE="/etc/vim/vimrc" ;;
            rhel)    TARGET_FILE="/etc/vimrc" ;;
            arch)    TARGET_FILE="/etc/vimrc" ;;
            suse)    TARGET_FILE="/etc/vimrc" ;;
            alpine)  TARGET_FILE="/etc/vim/vimrc" ;;
            macos)   TARGET_FILE="/usr/local/etc/vimrc" ;;  # Homebrew vim
            *)       TARGET_FILE="/etc/vimrc" ;;
        esac
        info "全局部署 ($distro) -> $TARGET_FILE"
    else
        TARGET_FILE="${HOME}/.vimrc"
        info "用户部署 -> $TARGET_FILE"
    fi
}

# ---------- 安全地创建文件及父目录 ----------
ensure_file() {
    local f="$1"
    local dir
    dir=$(dirname "$f")

    # 跟随符号链接
    if [ -L "$f" ]; then
        local real
        real=$(readlink -f "$f" 2>/dev/null || readlink "$f")
        warn "$f 是符号链接 -> $real，将操作实际文件。"
        f="$real"
        dir=$(dirname "$f")
    fi

    if [ ! -d "$dir" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            info "[dry-run] 将创建目录 $dir"
        else
            mkdir -p "$dir"
        fi
    fi

    if [ ! -f "$f" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            info "[dry-run] 将创建文件 $f"
        else
            touch "$f"
        fi
    fi

    # 检查可写
    if [ "$DRY_RUN" -eq 0 ] && [ ! -w "$f" ]; then
        err "文件不可写: $f"
        exit 1
    fi

    # 导出实际路径（可能因符号链接而变化）
    TARGET_FILE="$f"
}

# ---------- 备份 ----------
backup_file() {
    local f="$1"
    if [ ! -f "$f" ] || [ ! -s "$f" ]; then
        return
    fi
    local bak="${f}.bak.$(date +%Y%m%d%H%M%S)"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[dry-run] 将备份 $f -> $bak"
    else
        cp -a "$f" "$bak"
        ok "已备份: $bak"
    fi
}

# ---------- 清理旧配置块（兼容 BSD / GNU sed） ----------
remove_block() {
    local f="$1"
    if ! grep -qF "$MARKER_BEGIN" "$f" 2>/dev/null; then
        return 0
    fi
    info "清理旧配置块..."
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[dry-run] 将从 $f 中删除旧配置块"
        return 0
    fi

    # 使用兼容 BSD sed 和 GNU sed 的方式
    if sed --version 2>/dev/null | grep -q 'GNU'; then
        # GNU sed
        sed -i "/^${MARKER_BEGIN//\//\\/}$/,/^${MARKER_END//\//\\/}$/d" "$f"
    else
        # BSD sed (macOS)
        sed -i '' "/^${MARKER_BEGIN//\//\\/}$/,/^${MARKER_END//\//\\/}$/d" "$f"
    fi

    # 清理末尾多余空行
    if sed --version 2>/dev/null | grep -q 'GNU'; then
        sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$f"
    fi
}

# ---------- 生成配置内容 ----------
generate_config() {
cat << 'VIMCFG'
" === BEGIN DEVOPS VIMRC ===
""""""""""""""""""""""""""""""""""""""
" vim 运维服务器最小修正版
" by leonshaw 2024.10.12
" 适合 Kubernetes / Ansible / Shell
""""""""""""""""""""""""""""""""""""""

" -------- 编码 --------
set encoding=utf-8
set fileencoding=utf-8
set fileencodings=utf-8,gb18030,gbk,cp936,gb2312,big5,latin1
set termencoding=utf-8

" -------- 语言 --------
silent! set langmenu=zh_CN.UTF-8
silent! set helplang=cn,en

" -------- 基础 --------
set nocompatible
filetype plugin indent on
syntax on
set number
set nowrap
set fileformat=unix
set fileformats=unix,dos,mac
set autoread
set hidden
set wildmenu
set wildmode=longest:full,full

" -------- 缩进 --------
set autoindent
set smartindent
set tabstop=4
set softtabstop=4
set shiftwidth=4
set expandtab

" -------- 文件类型缩进 --------
augroup devops_vimrc_ft
  autocmd!
  " 2-空格缩进
  autocmd FileType yaml,yml         setlocal ts=2 sw=2 sts=2 et
  autocmd FileType json,jsonc       setlocal ts=2 sw=2 sts=2 et
  autocmd FileType html,css,scss    setlocal ts=2 sw=2 sts=2 et
  autocmd FileType javascript,typescript,vue,jsx,tsx setlocal ts=2 sw=2 sts=2 et
  autocmd FileType xml,toml         setlocal ts=2 sw=2 sts=2 et
  autocmd FileType terraform,tf,hcl setlocal ts=2 sw=2 sts=2 et
  autocmd FileType ruby,erb         setlocal ts=2 sw=2 sts=2 et
  autocmd FileType lua              setlocal ts=2 sw=2 sts=2 et
  autocmd FileType markdown         setlocal ts=2 sw=2 sts=2 et wrap

  " 4-空格缩进
  autocmd FileType python           setlocal ts=4 sw=4 sts=4 et
  autocmd FileType sh,bash,zsh      setlocal ts=4 sw=4 sts=4 et
  autocmd FileType dockerfile       setlocal ts=4 sw=4 sts=4 et
  autocmd FileType java,groovy      setlocal ts=4 sw=4 sts=4 et
  autocmd FileType c,cpp            setlocal ts=4 sw=4 sts=4 et

  " Tab 缩进（不可转空格）
  autocmd FileType go               setlocal noet ts=4 sw=4 sts=4
  autocmd FileType make             setlocal noet ts=8 sw=8 sts=0
  autocmd FileType gitconfig        setlocal noet ts=4 sw=4 sts=4

  " 运维特殊处理：回车时不自动延续注释
  autocmd FileType yaml,yml,sh,bash,zsh,dockerfile setlocal formatoptions-=cro
augroup END

" -------- 保存时自动创建不存在的父目录 --------
" 示例:
"   vim /tmp/a/b/c/test.yaml
"   :w
" 如果 /tmp/a/b/c 不存在，保存时会自动 mkdir -p 创建。
function! s:DevopsAutoMkdirForWrite(file) abort
    " 非普通文件缓冲区跳过，例如 help、terminal、nofile 等
    if &buftype !=# ''
        return
    endif

    " 空文件名跳过
    if empty(a:file)
        return
    endif

    " 跳过远程路径，例如 scp://、ftp://、http:// 等
    if a:file =~# '^\w\+://'
        return
    endif

    let l:dir = fnamemodify(a:file, ':p:h')

    " 根目录、当前目录或目录已存在时跳过
    if empty(l:dir) || l:dir ==# '.' || l:dir ==# '/' || isdirectory(l:dir)
        return
    endif

    " 自动创建父目录
    silent! call mkdir(l:dir, 'p', 0755)

    " 创建失败时给出提示，后续 :w 会继续报错
    if !isdirectory(l:dir)
        echohl ErrorMsg
        echom '无法自动创建目录: ' . l:dir
        echohl None
    endif
endfunction

augroup devops_vimrc_auto_mkdir
  autocmd!
  autocmd BufWritePre * call <SID>DevopsAutoMkdirForWrite(expand('<afile>'))
augroup END

" -------- 搜索 --------
set ignorecase
set smartcase
set hlsearch
set incsearch

" -------- 显示 / UI --------
set showmatch
set matchtime=3
set scrolloff=3
set sidescrolloff=5
set laststatus=2
set ruler
set cursorline
set showcmd
set list
set listchars=tab:→·,trail:□,extends:»,precedes:«,nbsp:⣿

" 状态栏
set statusline=\ %<%F[%1*%M%*%n%R%H]%=\ %y\ %0(%{&fileformat}\ %{strlen(&fenc)?&fenc:&enc}\ %l,%c%)\ %p%%

" -------- 操作 --------
set backspace=indent,eol,start
set mouse=a
if !has('nvim') && has('mouse_sgr')
    set ttymouse=sgr
endif
set pastetoggle=<F2>

" -------- 安全 --------
set nomodeline
set noswapfile
set history=500

" -------- 撤销持久化 (如目录可创建) --------
if has('persistent_undo')
    let s:undo_dir = expand('~/.vim/undodir')
    if !isdirectory(s:undo_dir)
        silent! call mkdir(s:undo_dir, 'p', 0700)
    endif
    execute 'set undodir=' . s:undo_dir
    set undofile
endif

" -------- 大文件保护 (> 10 MB 时精简) --------
augroup devops_vimrc_large
  autocmd!
  autocmd BufReadPre * if getfsize(expand('%')) > 10 * 1024 * 1024
        \ | setlocal noswapfile nobackup nowritebackup noundofile
        \ | syntax off
        \ | setlocal eventignore+=FileType
        \ | endif
augroup END
" === END DEVOPS VIMRC ===
VIMCFG
}

# ---------- 写入配置 ----------
write_config() {
    local f="$1"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[dry-run] 将写入配置到 $f"
        return 0
    fi
    generate_config >> "$f"
}

# ---------- 验证 ----------
verify() {
    local f="$1"
    if grep -qF "$MARKER_BEGIN" "$f" 2>/dev/null; then
        ok "配置已成功部署到 $f"
    else
        err "配置写入失败: $f，请检查文件权限。"
        return 1
    fi
}

# ---------- NeoVim 配置 ----------
deploy_neovim() {
    local nvim_init
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        nvim_init="/etc/xdg/nvim/init.vim"
    else
        nvim_init="${XDG_CONFIG_HOME:-$HOME/.config}/nvim/init.vim"
    fi

    info "同时部署 NeoVim 配置 -> $nvim_init"

    ensure_file "$nvim_init"
    local saved_target="$TARGET_FILE"
    TARGET_FILE="$nvim_init"

    backup_file "$TARGET_FILE"
    remove_block "$TARGET_FILE"

    if [ "$DO_UNINSTALL" -eq 0 ]; then
        write_config "$TARGET_FILE"
        verify "$TARGET_FILE"
    else
        ok "已从 $TARGET_FILE 卸载自定义配置"
    fi

    TARGET_FILE="$saved_target"
}

# ==========================================
#                   主流程
# ==========================================
main() {
    info "Vim 配置部署脚本 v${SCRIPT_VERSION}"
    [ "$DRY_RUN" -eq 1 ] && warn ">>> 模拟运行模式，不会修改任何文件 <<<"

    check_vim_installed
    resolve_target
    ensure_file "$TARGET_FILE"
    backup_file "$TARGET_FILE"
    remove_block "$TARGET_FILE"

    if [ "$DO_UNINSTALL" -eq 1 ]; then
        ok "已从 $TARGET_FILE 卸载自定义配置"
    else
        write_config "$TARGET_FILE"
        verify "$TARGET_FILE"
    fi

    # NeoVim
    if [ "$ALSO_NEOVIM" -eq 1 ]; then
        if command -v nvim &>/dev/null; then
            deploy_neovim
        else
            warn "未检测到 nvim，跳过 NeoVim 配置。"
        fi
    fi

    info "全部完成。"
}

main "$@"
