#!/usr/bin/env bash
set -euo pipefail

# Cross-platform server/shell init v2
# Supports: Debian / Ubuntu / macOS
# Goals:
#   1) Install and configure fish + starship + fastfetch
#   2) Reuse the current Linux-oriented style while fixing cross-platform incompatibilities
#   3) Backup first, then modify, then verify
#
# Optional environment variables:
#   TARGET_USER=alice             # Target user to configure; defaults to sudo invoker/current user, else root
#   SET_DEFAULT_SHELL=0           # Set to 0 to skip changing login shell to fish; default is to enable
#   FORCE_INSTALL_STARSHIP=1      # Reinstall/upgrade starship even if already present
#   FORCE_INSTALL_FASTFETCH=1     # Reinstall/upgrade fastfetch even if already present
#   SKIP_LOCALE=1                 # Skip Linux locale generation/update

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$*"; }
ok()   { printf '%b[ OK ]%b %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*"; }
die()  { printf '%b[ERR ]%b %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

OS_FAMILY=''
OS_ID=''
OS_NAME=''
PKG_MANAGER=''
SUDO_CMD=''
TARGET_USER="${TARGET_USER:-}"
TARGET_GROUP="${TARGET_GROUP:-}"
TARGET_HOME="${TARGET_HOME:-}"
CONFIG_ROOT=''
FISH_CONFIG_DIR=''
FASTFETCH_DIR=''
FISH_CONFIG_FILE=''
STARSHIP_CONFIG_FILE=''
FASTFETCH_CONFIG_FILE=''
BACKUP_ROOT=''
BACKUP_DIR=''
RESTORE_SCRIPT=''
TIMESTAMP=''
FISH_BIN=''

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

run_privileged() {
    if [ -n "$SUDO_CMD" ]; then
        "$SUDO_CMD" "$@"
    else
        "$@"
    fi
}

require_root_or_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        SUDO_CMD=''
        return 0
    fi

    if command -v sudo >/dev/null 2>&1; then
        SUDO_CMD='sudo'
        return 0
    fi

    die "当前不是 root，且未找到 sudo，无法继续"
}

detect_os() {
    case "$(uname -s)" in
        Linux)
            [ -f /etc/os-release ] || die "Linux 系统缺少 /etc/os-release，无法识别发行版"
            # shellcheck disable=SC1091
            . /etc/os-release
            case "${ID:-}" in
                debian|ubuntu)
                    OS_FAMILY='linux'
                    OS_ID="${ID}"
                    OS_NAME="${PRETTY_NAME:-$ID}"
                    PKG_MANAGER='apt'
                    ;;
                *)
                    die "当前 Linux 发行版暂不支持：${PRETTY_NAME:-${ID:-unknown}}"
                    ;;
            esac
            ;;
        Darwin)
            OS_FAMILY='macos'
            OS_ID='macos'
            OS_NAME="macOS $(sw_vers -productVersion 2>/dev/null || echo unknown)"
            PKG_MANAGER='brew'
            ;;
        *)
            die "暂不支持的操作系统：$(uname -s)"
            ;;
    esac

    ok "检测到系统：$OS_NAME"
}

detect_target_user() {
    if [ -n "${TARGET_USER:-}" ]; then
        TARGET_USER="${TARGET_USER}"
    elif [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != 'root' ]; then
        TARGET_USER="$SUDO_USER"
    else
        TARGET_USER="$(id -un)"
    fi

    if [ -n "${TARGET_HOME:-}" ]; then
        TARGET_HOME="${TARGET_HOME}"
        if [ "$OS_FAMILY" = 'linux' ]; then
            TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")"
        else
            TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || echo 'staff')"
        fi
    elif [ "$OS_FAMILY" = 'linux' ]; then
        TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
        TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")"
    else
        TARGET_HOME="$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
        TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || echo 'staff')"
    fi

    [ -n "$TARGET_HOME" ] || die "找不到目标用户 home：$TARGET_USER"

    CONFIG_ROOT="$TARGET_HOME/.config"
    FISH_CONFIG_DIR="$CONFIG_ROOT/fish"
    FASTFETCH_DIR="$CONFIG_ROOT/fastfetch"
    FISH_CONFIG_FILE="$FISH_CONFIG_DIR/config.fish"
    STARSHIP_CONFIG_FILE="$CONFIG_ROOT/starship.toml"
    FASTFETCH_CONFIG_FILE="$FASTFETCH_DIR/config.jsonc"

    TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
    BACKUP_ROOT="$TARGET_HOME/.config/hermes-server-init-backups"
    BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"
    RESTORE_SCRIPT="$BACKUP_DIR/restore.sh"

    log "目标用户：$TARGET_USER"
    log "目标组：$TARGET_GROUP"
    log "目标家目录：$TARGET_HOME"
}

copy_preserve() {
    local src="$1"
    local dst="$2"
    if cp -a "$src" "$dst" 2>/dev/null; then
        return 0
    fi
    cp -R "$src" "$dst"
}

prepare_backup() {
    mkdir -p "$BACKUP_DIR/files"

    cat > "$RESTORE_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
TARGET_USER=$(printf '%q' "$TARGET_USER")
TARGET_GROUP=$(printf '%q' "$TARGET_GROUP")
TARGET_HOME=$(printf '%q' "$TARGET_HOME")
BACKUP_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
copy_preserve() {
    local src="\$1"
    local dst="\$2"
    if cp -a "\$src" "\$dst" 2>/dev/null; then
        return 0
    fi
    cp -R "\$src" "\$dst"
}
restore_file() {
    local target="\$1"
    local backup="\$2"
    local existed="\$3"
    if [ "\$existed" = '1' ]; then
        mkdir -p "\$(dirname "\$target")"
        copy_preserve "\$backup" "\$target"
    else
        rm -f "\$target"
    fi
}
EOF

    printf 'created_at=%s\n' "$(date -Is 2>/dev/null || date)" > "$BACKUP_DIR/metadata.txt"
    printf 'os_name=%s\n' "$OS_NAME" >> "$BACKUP_DIR/metadata.txt"
    printf 'target_user=%s\n' "$TARGET_USER" >> "$BACKUP_DIR/metadata.txt"
    printf 'target_group=%s\n' "$TARGET_GROUP" >> "$BACKUP_DIR/metadata.txt"
    printf 'target_home=%s\n' "$TARGET_HOME" >> "$BACKUP_DIR/metadata.txt"

    ok "备份目录已创建：$BACKUP_DIR"
}

backup_file() {
    local target="$1"
    local key backup_path existed

    key="$(printf '%s' "$target" | sed 's#^/##; s#/#__#g')"
    backup_path="$BACKUP_DIR/files/$key"
    existed=0

    if [ -e "$target" ]; then
        existed=1
        copy_preserve "$target" "$backup_path"
        ok "已备份：$target"
    else
        warn "原文件不存在，恢复时将删除新建文件：$target"
    fi

    cat >> "$RESTORE_SCRIPT" <<EOF
restore_file $(printf '%q' "$target") $(printf '%q' "$backup_path") $existed
EOF
}

finish_restore_script() {
    cat >> "$RESTORE_SCRIPT" <<EOF
if id "${TARGET_USER}" >/dev/null 2>&1; then
    chown -R "${TARGET_USER}":"${TARGET_GROUP}" "${TARGET_HOME}/.config" 2>/dev/null || true
fi
echo "已恢复配置，备份目录：\$BACKUP_DIR"
EOF
    chmod +x "$RESTORE_SCRIPT"
}

apt_install() {
    run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

brew_ensure() {
    command -v brew >/dev/null 2>&1 || die "macOS 未检测到 Homebrew，请先安装 Homebrew：https://brew.sh"
}

map_common_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo 'x86_64' ;;
        aarch64|arm64) echo 'aarch64' ;;
        armv7l) echo 'armv7l' ;;
        armv6l) echo 'armv6l' ;;
        i386|i686) echo 'i686' ;;
        ppc64le) echo 'ppc64le' ;;
        riscv64) echo 'riscv64' ;;
        s390x) echo 's390x' ;;
        *) return 1 ;;
    esac
}

map_fastfetch_arch() {
    local arch
    arch="$(map_common_arch)" || return 1
    case "$arch" in
        x86_64) echo 'amd64' ;;
        *) echo "$arch" ;;
    esac
}

install_archive_binary() {
    local url="$1"
    local binary_name="$2"
    local tmp_dir archive_path extracted_path

    tmp_dir="$(mktemp -d)"
    archive_path="$tmp_dir/archive"

    curl -fL "$url" -o "$archive_path" || {
        rm -rf "$tmp_dir"
        return 1
    }

    case "$url" in
        *.tar.gz|*.tgz)
            tar -xzf "$archive_path" -C "$tmp_dir"
            ;;
        *.tar.xz)
            tar -xJf "$archive_path" -C "$tmp_dir"
            ;;
        *.zip)
            unzip -q "$archive_path" -d "$tmp_dir"
            ;;
        *)
            rm -rf "$tmp_dir"
            die "不支持的归档格式：$url"
            ;;
    esac

    extracted_path="$(find "$tmp_dir" -type f -name "$binary_name" | head -n 1 || true)"
    [ -n "$extracted_path" ] || {
        rm -rf "$tmp_dir"
        die "归档中未找到可执行文件：$binary_name"
    }

    run_privileged install -m 0755 "$extracted_path" "/usr/local/bin/$binary_name"
    rm -rf "$tmp_dir"
}


install_base_packages() {
    case "$PKG_MANAGER" in
        apt)
            log "更新 apt 软件源"
            run_privileged apt-get update -y

            log "安装 Linux 基础依赖"
            apt_install ca-certificates curl locales bat tree unzip p7zip-full unrar-free procps xz-utils
            ;;
        brew)
            brew_ensure
            log "更新 Homebrew"
            brew update

            log "安装 macOS 基础依赖"
            brew install bat tree p7zip unar watch grep diffutils coreutils findutils gnu-sed
            ;;
        *)
            die "未知包管理器：$PKG_MANAGER"
            ;;
    esac

    ok "基础包安装完成"
}

install_fish_from_github_release() {
    local arch version url tmp_dir extracted_dir tmp_pkg

    arch="$(map_common_arch)" || die "fish GitHub fallback 不支持当前架构：$(uname -m)"

    case "$OS_FAMILY" in
        linux)
            case "$arch" in
                x86_64|aarch64) ;;
                *) die "fish GitHub fallback 暂不支持当前 Linux 架构：$(uname -m)" ;;
            esac

            version="$(python3 - <<'PY'
import json, urllib.request
with urllib.request.urlopen('https://api.github.com/repos/fish-shell/fish-shell/releases/latest', timeout=20) as r:
    print(json.load(r)['tag_name'])
PY
)"
            url="https://github.com/fish-shell/fish-shell/releases/download/${version}/fish-${version}-linux-${arch}.tar.xz"
            log "fish 包管理器安装失败，尝试 GitHub Release 回退安装：$(basename "$url")"

            tmp_dir="$(mktemp -d)"
            curl -fL "$url" -o "$tmp_dir/fish.tar.xz" || {
                rm -rf "$tmp_dir"
                die "GitHub Release fish 下载失败"
            }
            tar -xJf "$tmp_dir/fish.tar.xz" -C "$tmp_dir"
            extracted_dir="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d -name 'fish-*' | head -n 1 || true)"
            [ -n "$extracted_dir" ] || die "fish 归档解压失败"
            [ -d "$extracted_dir/bin" ] || die "fish 归档缺少 bin 目录"

            run_privileged cp -a "$extracted_dir"/. /usr/local/
            rm -rf "$tmp_dir"
            ;;
        macos)
            version="$(python3 - <<'PY'
import json, urllib.request
with urllib.request.urlopen('https://api.github.com/repos/fish-shell/fish-shell/releases/latest', timeout=20) as r:
    print(json.load(r)['tag_name'])
PY
)"
            url="https://github.com/fish-shell/fish-shell/releases/download/${version}/fish-${version}.pkg"
            log "brew 安装 fish 失败，尝试 GitHub Release pkg 回退安装：$(basename "$url")"
            tmp_pkg="$(mktemp -t fish-release).pkg"
            curl -fL "$url" -o "$tmp_pkg" || die "GitHub Release fish 下载失败"
            run_privileged installer -pkg "$tmp_pkg" -target /
            rm -f "$tmp_pkg"
            ;;
        *)
            die "未知系统类型：$OS_FAMILY"
            ;;
    esac
}

install_fish_if_needed() {
    if command -v fish >/dev/null 2>&1; then
        ok "fish 已存在：$(command -v fish)"
        return 0
    fi

    case "$PKG_MANAGER" in
        apt)
            log "安装 fish（apt）"
            apt_install fish || install_fish_from_github_release
            ;;
        brew)
            log "安装 fish（brew）"
            brew install fish || brew upgrade fish || install_fish_from_github_release
            ;;
        *)
            die "未知包管理器：$PKG_MANAGER"
            ;;
    esac

    command -v fish >/dev/null 2>&1 || die "fish 安装失败"
    ok "fish 可用：$(command -v fish)"
}

install_starship_from_github_release() {
    local arch target triple url

    arch="$(map_common_arch)" || die "starship GitHub fallback 不支持当前架构：$(uname -m)"

    case "$OS_FAMILY" in
        linux)
            case "$arch" in
                x86_64) target='x86_64' ;;
                aarch64) target='aarch64' ;;
                armv7l) target='arm' ;;
                i686) target='i686' ;;
                *) die "starship GitHub fallback 暂不支持当前 Linux 架构：$(uname -m)" ;;
            esac
            triple='unknown-linux-gnu'
            ;;
        macos)
            case "$arch" in
                x86_64) target='x86_64' ;;
                aarch64) target='aarch64' ;;
                *) die "starship GitHub fallback 暂不支持当前 macOS 架构：$(uname -m)" ;;
            esac
            triple='apple-darwin'
            ;;
        *)
            die "未知系统类型：$OS_FAMILY"
            ;;
    esac

    url="https://github.com/starship/starship/releases/latest/download/starship-${target}-${triple}.tar.gz"
    log "尝试 GitHub Release 回退安装 starship：$(basename "$url")"
    install_archive_binary "$url" starship
    command -v starship >/dev/null 2>&1 || ln -sf /usr/local/bin/starship /usr/bin/starship 2>/dev/null || true
}

install_starship_if_needed() {
    if command -v starship >/dev/null 2>&1 && [ "${FORCE_INSTALL_STARSHIP:-0}" != '1' ]; then
        ok "starship 已存在：$(command -v starship)"
        return 0
    fi

    case "$PKG_MANAGER" in
        apt)
            log "安装/更新 starship（官方安装脚本）"
            local installer
            installer="$(mktemp)"
            if curl -fsSL https://starship.rs/install.sh -o "$installer"; then
                if ! run_privileged sh "$installer" -y -b /usr/local/bin; then
                    warn "starship 官方安装脚本执行失败，改用 GitHub Release"
                    install_starship_from_github_release
                fi
            else
                warn "starship 官方安装脚本下载失败，改用 GitHub Release"
                install_starship_from_github_release
            fi
            rm -f "$installer"
            ;;
        brew)
            log "安装/更新 starship（brew）"
            if ! brew install starship && ! brew upgrade starship; then
                warn "brew 安装 starship 失败，改用 GitHub Release"
                install_starship_from_github_release
            fi
            ;;
        *)
            die "未知包管理器：$PKG_MANAGER"
            ;;
    esac

    command -v starship >/dev/null 2>&1 || die "starship 安装失败"
    ok "starship 可用：$(command -v starship)"
}

install_fastfetch_from_github_release() {
    local arch url
    arch="$(map_fastfetch_arch)" || die "fastfetch GitHub fallback 不支持当前架构：$(uname -m)"

    case "$OS_FAMILY" in
        linux)
            local tmp_deb
            tmp_deb="$(mktemp --suffix=.deb)"
            url="https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-${arch}.deb"

            log "尝试 GitHub Release 回退安装 fastfetch：$(basename "$url")"
            if ! curl -fL "$url" -o "$tmp_deb"; then
                url="https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-${arch}-polyfilled.deb"
                log "普通包下载失败，尝试 polyfilled 包：$(basename "$url")"
                curl -fL "$url" -o "$tmp_deb" || die "GitHub Release fastfetch 下载失败"
            fi

            run_privileged dpkg -i "$tmp_deb" || run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -f -y
            rm -f "$tmp_deb"
            ;;
        macos)
            case "$arch" in
                amd64|aarch64) ;;
                *) die "fastfetch GitHub fallback 暂不支持当前 macOS 架构：$(uname -m)" ;;
            esac
            url="https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-macos-${arch}.tar.gz"
            log "尝试 GitHub Release 回退安装 fastfetch：$(basename "$url")"
            install_archive_binary "$url" fastfetch
            ;;
        *)
            die "未知系统类型：$OS_FAMILY"
            ;;
    esac
}

install_fastfetch_if_needed() {
    if command -v fastfetch >/dev/null 2>&1 && [ "${FORCE_INSTALL_FASTFETCH:-0}" != '1' ]; then
        ok "fastfetch 已存在：$(command -v fastfetch)"
        return 0
    fi

    case "$PKG_MANAGER" in
        apt)
            if apt-cache show fastfetch >/dev/null 2>&1; then
                log "安装/更新 fastfetch（apt）"
                if ! apt_install fastfetch; then
                    warn "apt 安装 fastfetch 失败，改用 GitHub Release"
                    install_fastfetch_from_github_release
                fi
            else
                install_fastfetch_from_github_release
            fi
            ;;
        brew)
            log "安装/更新 fastfetch（brew）"
            if ! brew install fastfetch && ! brew upgrade fastfetch; then
                warn "brew 安装 fastfetch 失败，改用 GitHub Release"
                install_fastfetch_from_github_release
            fi
            ;;
        *)
            die "未知包管理器：$PKG_MANAGER"
            ;;
    esac

    command -v fastfetch >/dev/null 2>&1 || die "fastfetch 安装失败"
    ok "fastfetch 可用：$(command -v fastfetch)"
}

configure_locale_if_needed() {
    if [ "${SKIP_LOCALE:-0}" = '1' ]; then
        warn "已跳过 locale 配置"
        return 0
    fi

    if [ "$OS_FAMILY" = 'macos' ]; then
        warn "macOS 不做系统级 locale 改写，只在 fish 中设置兼容性更好的语言环境变量"
        return 0
    fi

    log "配置 Linux 的 zh_CN.UTF-8 locale"
    [ -f /etc/locale.gen ] || run_privileged touch /etc/locale.gen

    if ! grep -Eq '^zh_CN\.UTF-8 UTF-8$' /etc/locale.gen; then
        printf '%s\n' 'zh_CN.UTF-8 UTF-8' | run_privileged tee -a /etc/locale.gen >/dev/null
    fi
    if ! grep -Eq '^en_US\.UTF-8 UTF-8$' /etc/locale.gen; then
        printf '%s\n' 'en_US.UTF-8 UTF-8' | run_privileged tee -a /etc/locale.gen >/dev/null
    fi

    run_privileged sed -i 's/^#\s*zh_CN\.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen
    run_privileged sed -i 's/^#\s*en_US\.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    run_privileged locale-gen zh_CN.UTF-8 en_US.UTF-8

    if command -v update-locale >/dev/null 2>&1; then
        run_privileged update-locale LANG=zh_CN.UTF-8 LANGUAGE=zh_CN:zh LC_MESSAGES=zh_CN.UTF-8 || true
    fi

    ok "locale 已生成并更新：zh_CN.UTF-8"
}

render_fish_config() {
    cat <<'EOF'
# Generated by Hermes
# Cross-platform fish config v2 for Debian / Ubuntu / macOS

set current_os (uname)

fish_add_path -m $HOME/.local/bin

# Locale / language handling
# Linux: use GNU locale variables directly.
# macOS: avoid forcing LANGUAGE / LC_ALL globally; prefer LANG + LC_CTYPE.
if test "$current_os" = 'Darwin'
    set -gx LANG zh_CN.UTF-8
    set -gx LC_CTYPE zh_CN.UTF-8
    if set -q LANGUAGE
        set -e LANGUAGE
    end
    if set -q LC_MESSAGES
        set -e LC_MESSAGES
    end
    if set -q LC_ALL
        set -e LC_ALL
    end
else
    set -gx LANG zh_CN.UTF-8
    set -gx LANGUAGE zh_CN:zh
    set -gx LC_MESSAGES zh_CN.UTF-8
    set -gx LC_ALL zh_CN.UTF-8
end

set -gx LESS '-R --use-color'
set -gx HISTSIZE 10000
set -gx SAVEHIST 10000

if command -q batcat
    set -gx BAT_THEME 'TwoDark'
    alias cat='batcat'
    alias bat='batcat'
else if command -q bat
    set -gx BAT_THEME 'TwoDark'
    alias cat='bat'
end

# Common aliases
alias ll='ls -lh'
alias la='ls -lah'
alias tree='tree -C'
alias less='less -R'
alias df='df -h'
alias du='du -h'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -i'
alias ln='ln -i'
alias mkdir='mkdir -pv'

# Platform-specific aliases
if test "$current_os" = 'Darwin'
    if command -q gls
        alias ls='gls --color=auto'
    else
        alias ls='ls -G'
    end

    if command -q ggrep
        alias grep='ggrep --color=auto'
    end

    if command -q gdiff
        alias diff='gdiff --color=auto'
    else
        alias diff='diff'
    end

    alias ps='ps aux'

    if command -q watch
        alias watch='watch'
    end

    if command -q vm_stat
        function free --description 'Show memory info on macOS'
            echo 'memory_pressure:'
            if command -q memory_pressure
                memory_pressure
            end
            echo ''
            echo 'vm_stat:'
            vm_stat
        end
    end
else
    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
    alias diff='diff --color=auto'
    alias watch='watch --color'
    alias free='free -h'
    alias ps='ps auxf'

    if command -q ip
        alias ip='ip -c'
    end

    if command -q dmesg
        alias dmesg='dmesg --color=always -T'
    end
end

function mkcd --description 'Create directory and cd into it'
    if test (count $argv) -eq 0
        echo 'mkcd: missing directory name' >&2
        return 1
    end
    mkdir -p -- $argv; and cd -- $argv[-1]
end

function extract --description 'Extract common archive formats'
    if test (count $argv) -eq 0
        echo 'extract: missing file operand' >&2
        return 1
    end

    set file $argv[1]
    if not test -f "$file"
        echo "'$file' is not a valid file"
        return 1
    end

    switch $file
        case '*.tar.bz2' '*.tbz2'
            tar xjf "$file"
        case '*.tar.gz' '*.tgz'
            tar xzf "$file"
        case '*.bz2'
            bunzip2 "$file"
        case '*.rar'
            if command -q unrar
                unrar e "$file"
            else if command -q unar
                unar "$file"
            else
                echo 'extract: unrar/unar not installed' >&2
                return 1
            end
        case '*.gz'
            gunzip "$file"
        case '*.tar'
            tar xf "$file"
        case '*.zip'
            unzip "$file"
        case '*.Z'
            uncompress "$file"
        case '*.7z'
            7z x "$file"
        case '*'
            echo "'$file' cannot be extracted"
            return 1
    end
end

function ff --description 'Find files by name from root'
    if test (count $argv) -eq 0
        echo 'ff: missing search term' >&2
        return 1
    end
    find / -type f -iname "*$argv[1]*" 2>/dev/null
end

function fd --description 'Find directories by name from root'
    if test (count $argv) -eq 0
        echo 'fd: missing search term' >&2
        return 1
    end
    find / -type d -iname "*$argv[1]*" 2>/dev/null
end

function cman --description 'Open man with Chinese-friendly locale settings'
    if not command -q man
        echo 'cman: man not found' >&2
        return 1
    end

    if test "$current_os" = 'Darwin'
        env LANG=zh_CN.UTF-8 LC_CTYPE=zh_CN.UTF-8 man $argv
    else
        man -L zh_CN $argv
    end
end

if status is-interactive
    bind '\\e[A' history-search-backward
    bind '\\e[B' history-search-forward

    set -l should_show_fastfetch 1

    if set -q FASTFETCH_SHOWN_IN_SESSION
        set should_show_fastfetch 0
    else if set -q SSH_TTY; or set -q SSH_CONNECTION; or set -q SSH_CLIENT
        set -gx FASTFETCH_SHOWN_IN_SESSION 1
    end

    if test $should_show_fastfetch -eq 1
        if command -q fastfetch
            fastfetch --config $HOME/.config/fastfetch/config.jsonc
            set -gx FASTFETCH_SHOWN_IN_SESSION 1
        end
    end

    if command -q starship
        starship init fish | source
    end
end
EOF
}

render_starship_config() {
    cat <<'EOF'
add_newline = false

format = """
$directory$character"""

right_format = """
$cmd_duration$git_branch$git_status$username$hostname\
"""

[character]
success_symbol = "[❯](bold green)"
error_symbol = "[❯](bold red)"
vicmd_symbol = "[❮](bold yellow)"

[directory]
style = "bold cyan"
truncation_length = 3
truncate_to_repo = true
read_only = " 🔒"

[username]
show_always = true
style_root = "bold red"
style_user = "bold blue"
format = "[$user]($style)"

[hostname]
ssh_only = false
style = "bold yellow"
format = "[@$hostname]($style)"

[git_branch]
symbol = "🌱 "
style = "bold purple"
format = " [$symbol$branch]($style)"

[git_status]
style = "bold red"
format = '([ \[$all_status$ahead_behind\]]($style))'

[cmd_duration]
min_time = 2000
style = "bold yellow"
format = " [⏱ $duration]($style) "

[package]
disabled = true

[nodejs]
disabled = false
format = " [🤖 $version](bold green) "

[python]
disabled = false
format = " [🐍 $version](bold yellow) "
EOF
}

render_fastfetch_config() {
    cat <<'EOF'
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json", // 用于IDE补全提示，不需要改动
  
  "logo": {
    "type": "Small", // 系统Logo样式。可以换成 "ubuntu_small", "arch_small", "linux", "tux" 等简单的图标，或者 "debian" 恢复完整大版
    "position": "top", // Logo显示位置。手机端强烈推荐 "top" (顶部居中)，如果你横屏空间很大，可以改回 "left" (左侧) 或 "right" (右侧)
    "color": {
      "1": "red" // Logo主色调。可以换成 "blue"(蓝), "green"(绿), "yellow"(黄), "magenta"(洋红/紫), "cyan"(青色)
    },
    "padding": {
      "top": 1, // 顶部留白行数。如果觉得距离屏幕顶端太近，可以改成 2 或 3
      "left": 1, // 左侧边缘留白字符数。手机端推荐 1 节省空间
      "right": 1 // 右侧边缘留白字符数。手机端推荐 1 节省空间
    }
  },

  "display": {
    "color": "red", // 模块图标和进度条的全局强调色。可以换成 "blue", "green", "yellow", "cyan" 等
    "separator": " ", // 左侧Key和右侧Value之间的分隔符。可以改成 " ➜ ", " : ", " = " 增加设计感
    "percent": {
      "type": 3 // 进度条样式。3为经典方块[███  ]；9为紧凑圆点 󰪥󰪣；11为圆环饼图；1为极简模式仅显示数字%。如果在手机上因为方块太长导致换行，强烈建议改为 9 或 1
    }
  },

  "modules": [
    {
      "type": "custom", // 自定义模块，通常用来做分类标题或空行
      "format": "\u001b[1m\u001b[31m=[ 系统信息 ]=\u001b[0m" // \u001b[31m 代表红色。如果想换颜色，32m是绿，33m是黄，34m是蓝，35m是紫，36m是青
    },
    {
      "type": "os",
      "key": "  系    统:", // 左侧显示的名称，可以自由增删空格来控制对齐，或者删掉 Nerd 图标
      "keyColor": "black" // 标题文本颜色。如果你用的终端背景是纯黑色的，"black"可能会看不清，建议改成 "white"(白), "default"(默认) 或 "dark_gray"(深灰)
    },
    {
      "type": "kernel",
      "key": "  内    核:", // 可以改成 "  Linux内核:" 
      "keyColor": "black" // 同上，可替换为 "white", "blue" 等
    },
    {
      "type": "title",
      "key": " 󰌢 主 机 名:", // 可以改成 "  设 备 名:"
      "keyColor": "black",
      "format": "{2}"
    },
    {
      "type": "command",
      "key": "  用 户 名:", // 可以改成 "  当前用户:"
      "text": "u=$(whoami); if [ \"$u\" = \"root\" ]; then printf '\\033[1;31m%s\\033[0m' \"$u\"; else printf '\\033[1;32m%s\\033[0m' \"$u\"; fi",
      "keyColor": "black"
      //"format": "{1}"
    },
    {
      "type": "uptime",
      "key": " 󰅐 运行时间:", // 原来的"运行"改成了更完整的中文
      "keyColor": "black",
      "format": "{1}天{2}时{3}分" // 强制使用中文格式输出
    },
    {
      "type": "loadavg",
      "key": "  负    载:", // 可以改成 "  系统压力:"
      "keyColor": "black"
    },
    {
      "type": "localip",
      "key": " 󰩟 IPv4地址:", // 可以改成 "  局域网IP:"
      "keyColor": "black",
      "showIpv4": true,
      "showIpv6": false, // 是否显示 IPv6。如果你的机器有且你需要看 IPv6，可以改成 true/false
      "defaultRouteOnly": true // 推荐加上，只显示主要联网网卡的IP，避免输出一堆虚拟网卡
    },
    {
      "type": "localip",
      "key": " 󰩟 IPv6地址:", // 可以改成 "  局域网IP:"
      "keyColor": "black",
      "showIpv4": false,
      "showIpv6": true, // 是否显示 IPv6。如果你的机器有且你需要看 IPv6，可以改成 true/false
      "defaultRouteOnly": true // 推荐加上，只显示主要联网网卡的IP，避免输出一堆虚拟网卡
    },
    "break", // 强制插入一个空行。如果觉得太占屏幕，可以直接把这行删掉
    {
      "type": "custom",
      "format": "\u001b[1m\u001b[31m=[ 资源使用 ]=\u001b[0m" // \u001b[31m 为红色。同上可改颜色代码
    },
    {
      "type": "cpu",
      "key": "  C  P  U:", 
      "keyColor": "black",
      "format": "{1} ({4} × {5} cores)" // 自定义 CPU 显示格式。{1}是型号，{4}是架构，{5}是核心数。如果手机屏幕显示不下这一长串，可以直接改成 "{1}" 或删掉 format 这一行
    },
    {
      "type": "cpuusage",
      "key": "  占 用 率:",
      "waitTime": 500,
      "keyColor": "black",
      "format": "{avg-bar} {avg}"
    },
    {
      "type": "memory",
      "key": "  内    存:", // 可以改成 "  物理内存:"
      "keyColor": "black"
    },
    {
      "type": "swap",
      "key": " 󰓡 交 换 区:", // 可以改成 "  虚拟内存:"
      "keyColor": "black"
    },
    {
      "type": "disk",
      "key": "  磁    盘:", // 可以改成 "  存储空间:"
      "keyColor": "black"
    },
    {
      "type": "processes",
      "key": "  进 程 数:", // 可以改成 "  活跃进程:"
      "keyColor": "black"
    },
    "break" // 底部收尾空行，不需要可以删去
  ]
}
EOF
}

write_configs() {
    mkdir -p "$FISH_CONFIG_DIR" "$FASTFETCH_DIR"

    backup_file "$FISH_CONFIG_FILE"
    backup_file "$STARSHIP_CONFIG_FILE"
    backup_file "$FASTFETCH_CONFIG_FILE"

    render_fish_config > "$FISH_CONFIG_FILE"
    render_starship_config > "$STARSHIP_CONFIG_FILE"
    render_fastfetch_config > "$FASTFETCH_CONFIG_FILE"

    chown -R "$TARGET_USER":"$TARGET_GROUP" "$CONFIG_ROOT" 2>/dev/null || true
    ok "配置文件已写入"
}

set_default_shell_if_needed() {
    if [ "${SET_DEFAULT_SHELL:-1}" = '0' ]; then
        warn "已按设置跳过默认 shell 修改；如需切换，请保持 SET_DEFAULT_SHELL 不为 0"
        return 0
    fi

    FISH_BIN="$(command -v fish || true)"
    [ -n "$FISH_BIN" ] || die "fish 未安装成功"

    if ! grep -qx "$FISH_BIN" /etc/shells 2>/dev/null; then
        if [ -w /etc/shells ]; then
            echo "$FISH_BIN" >> /etc/shells
        else
            printf '%s\n' "$FISH_BIN" | run_privileged tee -a /etc/shells >/dev/null
        fi
    fi

    if [ "$(id -u)" -eq 0 ]; then
        chsh -s "$FISH_BIN" "$TARGET_USER"
    else
        chsh -s "$FISH_BIN"
    fi

    ok "默认 shell 已切换为 fish：$TARGET_USER -> $FISH_BIN"
}

verify_result() {
    log "开始验证"

    require_command fish
    require_command starship
    require_command fastfetch

    HOME="$TARGET_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" fish -n "$FISH_CONFIG_FILE"

    HOME="$TARGET_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" fish -c "source '$FISH_CONFIG_FILE'; functions -q mkcd; and functions -q extract; and functions -q ff; and functions -q fd; and functions -q cman; and echo FISH_OK" | grep -q '^FISH_OK$'

    STARSHIP_CONFIG="$STARSHIP_CONFIG_FILE" starship prompt --status 0 --cmd-duration 1234 >/dev/null
    fastfetch --config "$FASTFETCH_CONFIG_FILE" >/dev/null 2>&1

    ok "fish 配置语法验证通过"
    ok "fish 函数加载验证通过"
    ok "starship 配置加载验证通过"
    ok "fastfetch 配置加载验证通过"
}

print_summary() {
    cat <<EOF

初始化完成。

- 系统：$OS_NAME
- 目标用户：$TARGET_USER
- fish 配置：$FISH_CONFIG_FILE
- starship 配置：$STARSHIP_CONFIG_FILE
- fastfetch 配置：$FASTFETCH_CONFIG_FILE
- 备份目录：$BACKUP_DIR
- 恢复命令：bash $RESTORE_SCRIPT

关键增强：
1. Linux / macOS alias 已分离，避免 ls/grep/ps/watch/dmesg 参数冲突
2. Linux fastfetch 支持 apt -> GitHub Release .deb fallback
3. macOS locale/shell 处理已改为兼容模式，不再强推 Linux 风格 LC_ALL/LANGUAGE

建议验证：
1. 重新登录终端，或直接执行：fish
2. 确认提示符已变为 starship 风格
3. 确认进入交互式 shell 后自动显示 fastfetch
4. 在 macOS 上执行：type cman; cman ls
5. 在 Linux 上执行：type ip; type dmesg; cman bash
EOF
}

main() {
    require_root_or_sudo
    detect_os
    detect_target_user
    prepare_backup
    install_base_packages
    install_fish_if_needed
    install_starship_if_needed
    install_fastfetch_if_needed
    configure_locale_if_needed
    write_configs
    finish_restore_script
    set_default_shell_if_needed
    verify_result
    print_summary
}

main "$@"
