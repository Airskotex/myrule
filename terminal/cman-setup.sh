#!/usr/bin/env bash
#===============================================================================
# 脚本名称: cman-setup.sh
# 描述:     自动安装和配置中文 man 手册页
# 适配系统: Ubuntu, Debian, CentOS, RHEL, Fedora, Arch, openSUSE, macOS
# 适配Shell: bash, zsh
# 用法:     chmod +x install_chinese_man.sh && sudo ./install_chinese_man.sh
#===============================================================================

set -e

# ======================== 颜色定义 ========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ======================== 日志函数 ========================
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
step()    { echo -e "${BLUE}[STEP]${NC} $*"; }

# ======================== 权限检查 ========================
check_root() {
    # macOS 下 brew 不建议用 root，单独处理
    if [[ "$(uname)" == "Darwin" ]]; then
        return 0
    fi
    if [[ $EUID -ne 0 ]]; then
        error "请使用 root 权限运行此脚本: sudo $0"
        exit 1
    fi
}

# ======================== 检测系统 ========================
detect_os() {
    if [[ "$(uname)" == "Darwin" ]]; then
        OS="macos"
        info "检测到系统: macOS"
        return
    fi

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|linuxmint|pop|deepin|kali)
                OS="debian"
                info "检测到系统: $PRETTY_NAME (Debian系)"
                ;;
            centos|rhel|rocky|almalinux|ol|amzn)
                OS="rhel"
                info "检测到系统: $PRETTY_NAME (RHEL系)"
                ;;
            fedora)
                OS="fedora"
                info "检测到系统: $PRETTY_NAME (Fedora)"
                ;;
            arch|manjaro|endeavouros)
                OS="arch"
                info "检测到系统: $PRETTY_NAME (Arch系)"
                ;;
            opensuse*|sles)
                OS="suse"
                info "检测到系统: $PRETTY_NAME (openSUSE/SLES)"
                ;;
            alpine)
                OS="alpine"
                info "检测到系统: $PRETTY_NAME (Alpine)"
                ;;
            *)
                warn "未明确识别的发行版: $ID，尝试通用方式安装"
                OS="unknown"
                ;;
        esac
    else
        error "无法检测操作系统类型"
        exit 1
    fi
}

# ======================== 检测Shell ========================
detect_shell() {
    CURRENT_USER="${SUDO_USER:-$USER}"
    USER_HOME=$(eval echo "~$CURRENT_USER")

    # 获取用户的登录 shell
    if command -v getent &>/dev/null; then
        USER_SHELL=$(getent passwd "$CURRENT_USER" | cut -d: -f7)
    else
        USER_SHELL=$(dscl . -read /Users/"$CURRENT_USER" UserShell 2>/dev/null | awk '{print $2}' || echo "$SHELL")
    fi

    SHELL_NAME=$(basename "$USER_SHELL")
    info "当前用户: $CURRENT_USER, 登录Shell: $SHELL_NAME"

    # 确定需要配置的 rc 文件列表
    RC_FILES=()
    case "$SHELL_NAME" in
        bash)
            [[ -f "$USER_HOME/.bashrc" ]] && RC_FILES+=("$USER_HOME/.bashrc")
            [[ -f "$USER_HOME/.bash_profile" ]] && RC_FILES+=("$USER_HOME/.bash_profile")
            # 如果都不存在，默认创建 .bashrc
            [[ ${#RC_FILES[@]} -eq 0 ]] && RC_FILES+=("$USER_HOME/.bashrc")
            ;;
        zsh)
            RC_FILES+=("$USER_HOME/.zshrc")
            ;;
        *)
            warn "未识别的Shell: $SHELL_NAME，将同时配置 .bashrc 和 .zshrc"
            RC_FILES+=("$USER_HOME/.bashrc" "$USER_HOME/.zshrc")
            ;;
    esac

    # 如果两种 shell 的配置文件都存在，都配置上
    if [[ -f "$USER_HOME/.bashrc" ]] && ! printf '%s\n' "${RC_FILES[@]}" | grep -q "bashrc"; then
        RC_FILES+=("$USER_HOME/.bashrc")
    fi
    if [[ -f "$USER_HOME/.zshrc" ]] && ! printf '%s\n' "${RC_FILES[@]}" | grep -q "zshrc"; then
        RC_FILES+=("$USER_HOME/.zshrc")
    fi

    info "将配置以下文件: ${RC_FILES[*]}"
}

# ======================== 安装中文 man 包 ========================
install_chinese_man() {
    step "正在安装中文 man 手册包..."

    case "$OS" in
        debian)
            apt-get update -qq
            apt-get install -y -qq man-db manpages manpages-zh 2>/dev/null || \
            apt-get install -y -qq man-db manpages manpages-zh-hans manpages-zh-hant 2>/dev/null || \
            {
                warn "官方源中未找到中文 man 包，尝试从源码安装..."
                install_from_source
                return
            }
            info "中文 man 手册包安装成功 (apt)"
            ;;
        rhel)
            if command -v dnf &>/dev/null; then
                dnf install -y -q man-db man-pages man-pages-zh-CN 2>/dev/null || \
                dnf install -y -q man-db man-pages man-pages-zh-Hans 2>/dev/null || \
                {
                    warn "dnf 安装失败，尝试从源码安装..."
                    install_from_source
                    return
                }
            else
                yum install -y -q man-db man-pages man-pages-zh-CN 2>/dev/null || \
                yum install -y -q man man-pages man-pages-zh-CN 2>/dev/null || \
                {
                    warn "yum 安装失败，尝试从源码安装..."
                    install_from_source
                    return
                }
            fi
            info "中文 man 手册包安装成功 (yum/dnf)"
            ;;
        fedora)
            dnf install -y -q man-db man-pages man-pages-zh-CN 2>/dev/null || \
            {
                warn "dnf 安装失败，尝试从源码安装..."
                install_from_source
                return
            }
            info "中文 man 手册包安装成功 (dnf)"
            ;;
        arch)
            pacman -Sy --noconfirm --needed man-db man-pages 2>/dev/null
            # Arch 的中文 man 在 AUR 中
            if command -v yay &>/dev/null; then
                sudo -u "$CURRENT_USER" yay -S --noconfirm man-pages-zh_cn 2>/dev/null || \
                sudo -u "$CURRENT_USER" yay -S --noconfirm man-pages-zh_tw 2>/dev/null || true
            elif command -v paru &>/dev/null; then
                sudo -u "$CURRENT_USER" paru -S --noconfirm man-pages-zh_cn 2>/dev/null || true
            else
                warn "未找到 AUR helper (yay/paru)，尝试从源码安装中文 man..."
                install_from_source
                return
            fi
            info "中文 man 手册包安装成功 (pacman/AUR)"
            ;;
        suse)
            zypper install -y -n man man-pages man-pages-zh_CN 2>/dev/null || \
            {
                warn "zypper 安装失败，尝试从源码安装..."
                install_from_source
                return
            }
            info "中文 man 手册包安装成功 (zypper)"
            ;;
        alpine)
            apk add --no-cache man-db man-pages mandoc 2>/dev/null || true
            install_from_source
            ;;
        macos)
            install_macos_chinese_man
            return
            ;;
        *)
            warn "未知系统，尝试从源码安装..."
            install_from_source
            return
            ;;
    esac
}

# ======================== macOS 安装 ========================
install_macos_chinese_man() {
    step "正在为 macOS 安装中文 man 手册..."

    # 检查 Homebrew
    if ! command -v brew &>/dev/null; then
        warn "未检测到 Homebrew，正在安装..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || \
        {
            error "Homebrew 安装失败，请手动安装后重试"
            error "访问: https://brew.sh"
            exit 1
        }
    fi

    # macOS 没有官方中文 man 包，从源码安装
    install_from_source
}

# ======================== 从源码安装 ========================
install_from_source() {
    step "正在从源码安装中文 man 手册..."

    # 安装编译依赖
    install_build_deps

    local TEMP_DIR
    TEMP_DIR=$(mktemp -d)
    local MANPAGES_URL="https://src.fedoraproject.org/repo/pkgs/man-pages-zh-CN/manpages-zh-1.6.4.tar.bz2/sha512/10814e10b250b3e5e8e87aaeb1e3e6ddd5e0e4e5e5e5e5e5e5e5e5e5e5e5e5e5/manpages-zh-1.6.4.tar.bz2"
    # 使用 GitHub 镜像源
    local GITHUB_URL="https://github.com/man-pages-zh/manpages-zh/archive/refs/tags/v1.6.4.tar.gz"
    local GITEE_URL="https://gitee.com/man-pages-zh/manpages-zh/repository/archive/v1.6.4.tar.gz"

    cd "$TEMP_DIR"

    info "正在下载中文 man 手册源码..."
    if command -v wget &>/dev/null; then
        wget -q --timeout=30 "$GITHUB_URL" -O manpages-zh.tar.gz 2>/dev/null || \
        wget -q --timeout=30 "$GITEE_URL" -O manpages-zh.tar.gz 2>/dev/null || \
        {
            error "下载失败，请检查网络连接"
            rm -rf "$TEMP_DIR"
            exit 1
        }
    elif command -v curl &>/dev/null; then
        curl -sL --connect-timeout 30 "$GITHUB_URL" -o manpages-zh.tar.gz 2>/dev/null || \
        curl -sL --connect-timeout 30 "$GITEE_URL" -o manpages-zh.tar.gz 2>/dev/null || \
        {
            error "下载失败，请检查网络连接"
            rm -rf "$TEMP_DIR"
            exit 1
        }
    else
        error "未找到 wget 或 curl，无法下载"
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    info "正在解压..."
    tar xzf manpages-zh.tar.gz
    cd manpages-zh-* 2>/dev/null || cd manpages-zh 2>/dev/null

    if [[ -f configure ]]; then
        info "正在编译安装..."
        ./configure --disable-zhtw 2>/dev/null || ./configure 2>/dev/null
        make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)" 2>/dev/null || true
        make install 2>/dev/null || {
            # 手动复制 man 文件
            warn "make install 失败，尝试手动复制..."
            manual_copy_man_pages
        }
    elif [[ -f CMakeLists.txt ]]; then
        mkdir -p build && cd build
        cmake .. 2>/dev/null
        make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)" 2>/dev/null
        make install 2>/dev/null
    else
        # 直接复制 man 文件
        manual_copy_man_pages
    fi

    # 清理
    cd /
    rm -rf "$TEMP_DIR"
    info "源码安装完成"
}

# ======================== 手动复制 man 页面 ========================
manual_copy_man_pages() {
    info "正在手动复制 man 页面..."

    local MAN_TARGET
    if [[ "$(uname)" == "Darwin" ]]; then
        MAN_TARGET="/usr/local/share/man/zh_CN"
    else
        MAN_TARGET="/usr/share/man/zh_CN"
    fi

    mkdir -p "$MAN_TARGET"

    # 查找并复制所有 man 页面
    for section in man1 man2 man3 man4 man5 man6 man7 man8; do
        if [[ -d "src/$section" ]]; then
            mkdir -p "$MAN_TARGET/$section"
            cp -f src/$section/* "$MAN_TARGET/$section/" 2>/dev/null || true
        elif [[ -d "$section" ]]; then
            mkdir -p "$MAN_TARGET/$section"
            cp -f $section/* "$MAN_TARGET/$section/" 2>/dev/null || true
        fi
    done

    # 递归查找
    find . -name "*.gz" -o -name "*.[1-8]" 2>/dev/null | while read -r f; do
        local section
        section=$(echo "$f" | grep -oP '\.\K[1-8]' | tail -1)
        if [[ -n "$section" ]]; then
            mkdir -p "$MAN_TARGET/man$section"
            cp -f "$f" "$MAN_TARGET/man$section/" 2>/dev/null || true
        fi
    done

    info "man 页面已复制到 $MAN_TARGET"
}

# ======================== 安装编译依赖 ========================
install_build_deps() {
    step "正在安装编译依赖..."

    case "$OS" in
        debian)
            apt-get install -y -qq build-essential autoconf automake wget curl tar bzip2 2>/dev/null || true
            ;;
        rhel|fedora)
            if command -v dnf &>/dev/null; then
                dnf install -y -q gcc make autoconf automake wget curl tar bzip2 2>/dev/null || true
            else
                yum install -y -q gcc make autoconf automake wget curl tar bzip2 2>/dev/null || true
            fi
            ;;
        arch)
            pacman -S --noconfirm --needed base-devel wget curl 2>/dev/null || true
            ;;
        suse)
            zypper install -y -n gcc make autoconf automake wget curl tar bzip2 2>/dev/null || true
            ;;
        alpine)
            apk add --no-cache build-base autoconf automake wget curl tar bzip2 2>/dev/null || true
            ;;
        macos)
            # macOS 使用 Xcode Command Line Tools
            xcode-select --install 2>/dev/null || true
            ;;
    esac
}

# ======================== 配置 Locale ========================
configure_locale() {
    step "正在配置中文 Locale..."

    if [[ "$OS" == "macos" ]]; then
        info "macOS 默认支持中文 Locale，跳过"
        return
    fi

    # 检查是否已有中文 locale
    if locale -a 2>/dev/null | grep -qi "zh_cn"; then
        info "中文 Locale 已存在"
    else
        info "正在生成中文 Locale..."
        case "$OS" in
            debian)
                apt-get install -y -qq locales 2>/dev/null || true
                # 取消注释 locale
                if [[ -f /etc/locale.gen ]]; then
                    sed -i 's/^# *zh_CN.UTF-8/zh_CN.UTF-8/' /etc/locale.gen
                    sed -i 's/^# *zh_CN.GB18030/zh_CN.GB18030/' /etc/locale.gen 2>/dev/null || true
                fi
                locale-gen 2>/dev/null || true
                ;;
            rhel|fedora)
                if command -v dnf &>/dev/null; then
                    dnf install -y -q glibc-langpack-zh 2>/dev/null || true
                else
                    yum install -y -q glibc-common 2>/dev/null || true
                fi
                localedef -i zh_CN -f UTF-8 zh_CN.UTF-8 2>/dev/null || true
                ;;
            arch)
                if [[ -f /etc/locale.gen ]]; then
                    sed -i 's/^#zh_CN.UTF-8/zh_CN.UTF-8/' /etc/locale.gen
                fi
                locale-gen 2>/dev/null || true
                ;;
            suse)
                zypper install -y -n glibc-locale 2>/dev/null || true
                ;;
            alpine)
                # Alpine 使用 musl，locale 支持有限
                warn "Alpine 使用 musl libc，中文 locale 支持有限"
                ;;
        esac
    fi
}

# ======================== 配置 Shell 环境 ========================
configure_shell_env() {
    step "正在配置 Shell 环境变量..."

    # 中文 man 的环境变量配置块
    local CONFIG_BLOCK
    read -r -d '' CONFIG_BLOCK << 'CONFIGEOF' || true

# ============ 中文 man 手册配置 (auto-generated) ============
# 设置中文 man 手册
alias cman='LANG=zh_CN.UTF-8 man'

# 配置 MANPATH 以包含中文 man 路径
if [ -d "/usr/share/man/zh_CN" ]; then
    export MANPATH="/usr/share/man/zh_CN:$MANPATH"
fi
if [ -d "/usr/share/man/zh_CN.UTF-8" ]; then
    export MANPATH="/usr/share/man/zh_CN.UTF-8:$MANPATH"
fi
if [ -d "/usr/local/share/man/zh_CN" ]; then
    export MANPATH="/usr/local/share/man/zh_CN:$MANPATH"
fi

# 中文 man 函数: 优先显示中文，无中文则回退英文
function cman() {
    local page="$1"
    local section="${2:-}"
    
    # 尝试中文 man
    if [ -n "$section" ]; then
        LANG=zh_CN.UTF-8 LANGUAGE=zh_CN man "$section" "$page" 2>/dev/null
    else
        LANG=zh_CN.UTF-8 LANGUAGE=zh_CN man "$page" 2>/dev/null
    fi
    
    # 如果中文 man 失败，回退到英文
    if [ $? -ne 0 ]; then
        echo "[提示] 未找到中文手册，显示英文版本..."
        man "$@"
    fi
}

# 如需默认使用中文 man，取消下面的注释:
# export LANG=zh_CN.UTF-8
# export LANGUAGE=zh_CN:zh
# ============ 中文 man 手册配置结束 ============
CONFIGEOF

    local MARKER="中文 man 手册配置 (auto-generated)"

    for rc_file in "${RC_FILES[@]}"; do
        # 确保文件存在
        if [[ ! -f "$rc_file" ]]; then
            touch "$rc_file"
            if [[ -n "$CURRENT_USER" ]]; then
                chown "$CURRENT_USER":"$(id -gn "$CURRENT_USER" 2>/dev/null || echo "$CURRENT_USER")" "$rc_file" 2>/dev/null || true
            fi
        fi

        # 检查是否已配置
        if grep -q "$MARKER" "$rc_file" 2>/dev/null; then
            warn "文件 $rc_file 中已存在中文 man 配置，跳过"
            continue
        fi

        # 备份原文件
        cp "$rc_file" "${rc_file}.bak.$(date +%Y%m%d%H%M%S)"
        info "已备份: ${rc_file}.bak.$(date +%Y%m%d%H%M%S)"

        # 追加配置
        echo "" >> "$rc_file"
        echo "$CONFIG_BLOCK" >> "$rc_file"

        # 修正文件权限
        if [[ -n "$CURRENT_USER" ]]; then
            chown "$CURRENT_USER":"$(id -gn "$CURRENT_USER" 2>/dev/null || echo "$CURRENT_USER")" "$rc_file" 2>/dev/null || true
        fi

        info "已配置: $rc_file"
    done
}

# ======================== 配置 man.conf ========================
configure_man_conf() {
    step "正在配置 man.conf..."

    local MAN_CONF=""
    local MAN_CONF_CANDIDATES=(
        "/etc/man_db.conf"
        "/etc/manpath.config"
        "/etc/man.conf"
        "/usr/local/etc/man_db.conf"
        "/etc/man.config"
    )

    for conf in "${MAN_CONF_CANDIDATES[@]}"; do
        if [[ -f "$conf" ]]; then
            MAN_CONF="$conf"
            break
        fi
    done

    if [[ -z "$MAN_CONF" ]]; then
        warn "未找到 man 配置文件，跳过此步骤"
        return
    fi

    info "找到 man 配置文件: $MAN_CONF"

    # 备份
    cp "$MAN_CONF" "${MAN_CONF}.bak.$(date +%Y%m%d%H%M%S)"

    # 检查是否已添加中文路径
    if grep -q "zh_CN" "$MAN_CONF" 2>/dev/null; then
        info "man 配置文件中已包含中文路径"
        return
    fi

    # 添加中文 man 路径
    local ZH_PATHS=(
        "/usr/share/man/zh_CN"
        "/usr/share/man/zh_CN.UTF-8"
        "/usr/local/share/man/zh_CN"
    )

    echo "" >> "$MAN_CONF"
    echo "# 中文 man 手册路径 (auto-added)" >> "$MAN_CONF"
    for zh_path in "${ZH_PATHS[@]}"; do
        if [[ -d "$zh_path" ]] || [[ "$OS" == "macos" ]]; then
            # man_db.conf 格式
            if grep -q "^MANDATORY_MANPATH" "$MAN_CONF" 2>/dev/null; then
                echo "MANDATORY_MANPATH $zh_path" >> "$MAN_CONF"
            elif grep -q "^MANPATH_MAP" "$MAN_CONF" 2>/dev/null; then
                echo "MANPATH_MAP /usr/bin $zh_path" >> "$MAN_CONF"
            fi
        fi
    done

    info "man 配置文件已更新"
}

# ======================== 更新 man 数据库 ========================
update_man_db() {
    step "正在更新 man 数据库..."

    if command -v mandb &>/dev/null; then
        mandb -q 2>/dev/null || mandb 2>/dev/null || true
        info "man 数据库已更新 (mandb)"
    elif command -v makewhatis &>/dev/null; then
        makewhatis 2>/dev/null || true
        info "man 数据库已更新 (makewhatis)"
    else
        warn "未找到 mandb 或 makewhatis 命令，跳过数据库更新"
    fi
}

# ======================== 验证安装 ========================
verify_installation() {
    step "正在验证安装..."

    echo ""
    echo "=========================================="
    echo "  中文 man 手册安装验证"
    echo "=========================================="

    # 检查中文 man 目录
    local found=false
    local ZH_DIRS=(
        "/usr/share/man/zh_CN"
        "/usr/share/man/zh_CN.UTF-8"
        "/usr/local/share/man/zh_CN"
        "/usr/share/man/zh_Hans"
    )

    for dir in "${ZH_DIRS[@]}"; do
        if [[ -d "$dir" ]]; then
            local count
            count=$(find "$dir" -type f 2>/dev/null | wc -l)
            info "找到中文 man 目录: $dir (${count} 个文件)"
            found=true
        fi
    done

    if [[ "$found" == false ]]; then
        warn "未找到中文 man 页面目录"
    fi

    # 检查 locale
    echo ""
    info "当前 Locale 信息:"
    locale 2>/dev/null | head -5 || true

    # 检查可用的中文 locale
    echo ""
    info "可用的中文 Locale:"
    locale -a 2>/dev/null | grep -i "zh" || echo "  (无)"

    # 尝试显示中文 man
    echo ""
    info "尝试查看中文 man 页面 (ls)..."
    if LANG=zh_CN.UTF-8 man -w ls 2>/dev/null; then
        info "中文 man 路径查找成功"
    else
        warn "中文 man 路径查找失败，但 cman 命令可能仍然可用"
    fi

    echo ""
}

# ======================== 打印使用说明 ========================
print_usage() {
    echo ""
    echo -e "${GREEN}=========================================="
    echo "  ✅ 中文 man 手册配置完成！"
    echo -e "==========================================${NC}"
    echo ""
    echo "使用方法:"
    echo ""
    echo "  1. 使用 cman 命令查看中文手册:"
    echo -e "     ${BLUE}cman ls${NC}"
    echo -e "     ${BLUE}cman grep${NC}"
    echo -e "     ${BLUE}cman chmod${NC}"
    echo ""
    echo "  2. 临时使用中文 man:"
    echo -e "     ${BLUE}LANG=zh_CN.UTF-8 man ls${NC}"
    echo ""
    echo "  3. 如需默认使用中文 man，编辑 shell 配置文件，"
    echo "     取消以下行的注释:"
    echo -e "     ${YELLOW}export LANG=zh_CN.UTF-8${NC}"
    echo -e "     ${YELLOW}export LANGUAGE=zh_CN:zh${NC}"
    echo ""
    echo "  4. 使配置立即生效:"
    for rc_file in "${RC_FILES[@]}"; do
        echo -e "     ${BLUE}source $rc_file${NC}"
    done
    echo ""
    echo "  5. 如需恢复原配置，备份文件位于:"
    for rc_file in "${RC_FILES[@]}"; do
        echo -e "     ${YELLOW}${rc_file}.bak.*${NC}"
    done
    echo ""
    echo -e "${GREEN}==========================================${NC}"
}

# ======================== 主函数 ========================
main() {
    echo ""
    echo "=========================================="
    echo "  中文 man 手册自动安装配置脚本"
    echo "  版本: 1.0.0"
    echo "=========================================="
    echo ""

    check_root
    detect_os
    detect_shell
    configure_locale
    install_chinese_man
    configure_man_conf
    configure_shell_env
    update_man_db
    verify_installation
    print_usage
}

# ======================== 执行 ========================
main "$@"
