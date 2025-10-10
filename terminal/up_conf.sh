#!/bin/bash

# ==============================================================================
# Ubuntu Server 初始化配置脚本 (兼容 20.04/22.04/24.04)
# 作者: Airskotex 
# 日期: 2025-10-10
# 功能:
#   0. 升级并配置 GCC (根据系统版本自动选择)
#   1. 更换为阿里云软件源
#   2. 升级内核 (自动检测最适版本)
#   3. 安装 NVIDIA 闭源驱动 (.run 文件)
#   4. 安装 GNOME 桌面 (ubuntu-desktop-minimal) 和 XRDP 服务
#   5. [高风险] 配置允许 root 用户进行图形和远程登录
#   6. 添加中文语言支持
#   7. 脚本执行完毕后自动删除
#
# ** 警告 **: 此脚本包含高风险操作 (特别是 root 登录)，请仅在完全了解
#            其后果的情况下运行。
# ==============================================================================

set -e # 如果任何命令失败，脚本将立即退出

# --- 全局变量 ---
UBUNTU_CODENAME=""
UBUNTU_VERSION=""
KERNEL_VERSION=""
NVIDIA_RUNFILE=""

# --- 脚本自身路径 ---
SCRIPT_PATH="$(realpath "$0")"

# --- 清理陷阱 ---
cleanup() {
    local exit_code=$?
    echo -e "\033[0;36m[INFO] 正在清理脚本文件...\033[0m"
    if [[ -f "$SCRIPT_PATH" ]]; then
        if rm -f "$SCRIPT_PATH"; then
            echo -e "\033[0;32m[INFO] 脚本文件已成功删除。\033[0m"
        else
            echo -e "\033[1;33m[WARN] 无法删除脚本文件 $SCRIPT_PATH\033[0m"
        fi
    fi
    exit $exit_code
}
trap cleanup EXIT

# --- 颜色定义 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- 辅助函数 ---
log_info() { echo -e "${GREEN}[INFO] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; }
log_debug() { echo -e "${BLUE}[DEBUG] $1${NC}"; }
log_step() { echo -e "\n${CYAN}>>> $1${NC}"; }

# 检查网络连通性
check_network() {
    log_info "检查网络连通性..."
    if ! ping -c 1 -W 5 mirrors.aliyun.com >/dev/null 2>&1; then
        log_error "无法连接到阿里云镜像服务器，请检查网络连接。"
        exit 1
    fi
    log_info "网络连接正常。"
}

# 检查系统版本
check_system_version() {
    log_info "检查系统版本..."
    if [[ ! -f /etc/os-release ]]; then
        log_error "无法检测系统版本，/etc/os-release 文件不存在。"
        exit 1
    fi

    source /etc/os-release
    UBUNTU_CODENAME="${VERSION_CODENAME}"
    UBUNTU_VERSION="${VERSION_ID}"

    log_info "检测到系统信息："
    log_info "  - 发行版: $NAME"
    log_info "  - 版本号: $VERSION_ID"
    log_info "  - 代号:   $VERSION_CODENAME"
    log_info "  - 架构:   $(uname -m)"

    if [[ "$ID" != "ubuntu" ]]; then
        log_error "此脚本仅支持 Ubuntu 系统，当前系统为: $ID。"
        exit 1
    fi

    # 预安装 bc 用于版本比较
    if ! command -v bc &> /dev/null; then
        log_info "正在安装版本比较工具 'bc'..."
        apt update && apt install -y bc
    fi

    if [[ $(echo "$UBUNTU_VERSION < 20.04" | bc) -eq 1 ]]; then
        log_error "此脚本需要 Ubuntu 20.04 或更高版本，当前版本: $UBUNTU_VERSION。"
        exit 1
    fi
    log_info "系统版本检查通过: Ubuntu $UBUNTU_VERSION ($UBUNTU_CODENAME)"
}

# 自动检测NVIDIA驱动文件
detect_nvidia_driver() {
    log_info "自动检测 NVIDIA 驱动文件 (.run)..."
    local driver_files
    driver_files=($(ls NVIDIA-Linux-x86_64-*.run 2>/dev/null))

    if [[ ${#driver_files[@]} -eq 0 ]]; then
        log_error "未找到 NVIDIA 驱动文件！请确保 .run 文件与本脚本位于同一目录下。"
        exit 1
    elif [[ ${#driver_files[@]} -eq 1 ]]; then
        NVIDIA_RUNFILE="${driver_files[0]}"
        log_info "自动检测到驱动文件: $NVIDIA_RUNFILE"
    else
        log_warn "检测到多个 NVIDIA 驱动文件："
        for i in "${!driver_files[@]}"; do
            echo "  $((i+1)). ${driver_files[i]}"
        done
        read -p "请选择要使用的驱动文件 (1-${#driver_files[@]}): " choice
        if [[ "$choice" -ge 1 && "$choice" -le ${#driver_files[@]} ]]; then
            NVIDIA_RUNFILE="${driver_files[$((choice-1))]}"
            log_info "选择了驱动文件: $NVIDIA_RUNFILE"
        else
            log_error "无效选择。"
            exit 1
        fi
    fi
}

# 检查和显示系统信息
show_system_info() {
    log_info "======== 系统信息与计划 ========"
    log_info "当前内核版本: $(uname -r)"
    if [[ -n "$KERNEL_VERSION" ]]; then
        log_info "目标内核版本: $KERNEL_VERSION"
    else
        log_warn "目标内核版本: 未检测到合适的升级版本"
    fi
    log_info "系统架构: $(uname -m)"
    log_info "CPU信息: $(lscpu | grep 'Model name' | cut -d ':' -f2 | xargs)"
    log_info "内存信息: $(free -h | awk '/^Mem:/ {print $2}') 总内存"

    if lspci | grep -qi 'VGA compatible controller: NVIDIA'; then
        log_info "检测到 NVIDIA GPU:"
        lspci | grep -i nvidia | while read -r line; do log_info "  - $line"; done
        log_info "将要安装驱动: $NVIDIA_RUNFILE"
    else
        log_warn "未检测到 NVIDIA GPU，但仍将按计划继续安装驱动。"
    fi
    log_info "=================================="
}

# 步骤 0: 升级 GCC
upgrade_gcc() {
    log_step "步骤 0: 检查并配置 GCC..."
    local target_gcc_version
    current_gcc_version=$(gcc --version 2>/dev/null | head -n1 | grep -oP '\d+' | head -n1 || echo "0")

    case "$UBUNTU_VERSION" in
        "20.04") target_gcc_version="11" ;;
        "22.04") target_gcc_version="12" ;;
        "24.04") target_gcc_version="13" ;;
        *) target_gcc_version="13"; log_warn "未知的 Ubuntu 版本，默认目标为 GCC 13" ;;
    esac
    log_info "当前系统版本 $UBUNTU_VERSION, 目标 GCC 版本: $target_gcc_version"

    if [[ "$current_gcc_version" -ge "$target_gcc_version" ]]; then
        log_info "当前 GCC 版本 ($current_gcc_version) 已满足要求，跳过升级。"
        return 0
    fi

    log_info "准备安装 GCC $target_gcc_version..."
    apt install -y software-properties-common
    log_info "正在添加 PPA: ppa:ubuntu-toolchain-r/test..."
    add-apt-repository ppa:ubuntu-toolchain-r/test -y
    apt update

    log_info "正在安装 gcc-${target_gcc_version} g++-${target_gcc_version}..."
    apt install -y "gcc-${target_gcc_version}" "g++-${target_gcc_version}"

    log_info "正在配置 update-alternatives 以设置默认版本..."
    update-alternatives --install /usr/bin/gcc gcc "/usr/bin/gcc-${target_gcc_version}" 100
    update-alternatives --install /usr/bin/g++ g++ "/usr/bin/g++-${target_gcc_version}" 100

    log_info "验证 GCC 版本..."
    gcc --version
    log_info "GCC 配置完成。"
}

# 步骤 1: 换阿里云的源
change_sources() {
    log_step "步骤 1: 配置阿里云软件源..."
    log_info "正在备份原始 sources.list 文件..."
    cp /etc/apt/sources.list "/etc/apt/sources.list.bak_$(date +%F_%H%M%S)"

    log_info "正在为 Ubuntu $UBUNTU_VERSION ($UBUNTU_CODENAME) 写入新的阿里云源..."
    cat > /etc/apt/sources.list << EOF
deb https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb-src https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse

deb https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
deb-src https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse

deb https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb-src https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse

deb https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
deb-src https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
EOF

    log_info "软件源更换完毕，正在执行 apt update..."
    apt update
}

# 步骤 2 前置: 检测目标内核
detect_target_kernel() {
    log_step "步骤 2 (准备): 检测可升级的内核版本..."
    local recommended_kernel_pattern available_kernels target_kernel
    
    case "$UBUNTU_VERSION" in
        "20.04") recommended_kernel_pattern="5.15" ;;
        "22.04") recommended_kernel_pattern="6.5" ;;
        "24.04") recommended_kernel_pattern="6.8" ;;
        *) recommended_kernel_pattern="" ;;
    esac

    log_info "正在搜索可用的内核..."
    available_kernels=$(apt-cache search "^linux-image-[0-9]" | grep --color=never -E "generic" | grep -v "lowlatency" | awk '{print $1}' | sort -V)
    if [[ -z "$available_kernels" ]]; then
        log_warn "在软件源中未找到任何可用的 linux-image-generic 内核包。"
        return
    fi
    
    if [[ -n "$recommended_kernel_pattern" ]]; then
        log_info "正在根据推荐模式 '$recommended_kernel_pattern' 查找最新内核..."
        target_kernel=$(echo "$available_kernels" | grep "$recommended_kernel_pattern" | tail -n1 | sed 's/linux-image-//')
    fi

    if [[ -z "$target_kernel" ]]; then
        log_info "未找到推荐内核，将选择可用的最新稳定版内核..."
        target_kernel=$(echo "$available_kernels" | tail -n1 | sed 's/linux-image-//')
    fi

    if [[ -n "$target_kernel" ]]; then
        KERNEL_VERSION="$target_kernel"
        log_info "检测到最佳目标内核版本: $KERNEL_VERSION"
    else
        log_warn "无法确定任何可用的目标内核版本。"
    fi
}

# 步骤 2: 升级内核
upgrade_kernel() {
    log_step "步骤 2: 执行内核升级..."
    if [[ -z "$KERNEL_VERSION" ]]; then
        log_warn "未检测到合适的目标内核版本，跳过内核升级。"
        return
    fi

    local current_kernel
    current_kernel=$(uname -r)
    log_info "当前内核版本: $current_kernel"
    log_info "目标内核版本: $KERNEL_VERSION"
    
    if [[ "$current_kernel" == "$KERNEL_VERSION" ]]; then
        log_info "当前内核已是目标版本，无需升级。"
        return
    fi

    log_info "正在安装新内核及相关组件: ${KERNEL_VERSION}..."
    if ! apt install -y \
        "linux-image-${KERNEL_VERSION}" \
        "linux-headers-${KERNEL_VERSION}" \
        "linux-modules-extra-${KERNEL_VERSION}"; then
        log_error "内核安装失败，请检查 apt 输出。"
        exit 1
    fi

    log_info "内核安装完毕。正在更新 GRUB 配置..."
    update-grub
    log_info "内核升级流程完成。重启后将生效。"
}

# 步骤 3: 安装桌面
install_desktop() {
    log_step "步骤 3: 安装 GNOME 桌面环境和 XRDP..."
    
    log_info "正在安装 GNOME 桌面环境 (minimal)..."
    apt install -y ubuntu-desktop-minimal
    
    log_info "正在安装 XRDP 及依赖组件..."
    apt install -y xrdp dbus-x11 xorgxrdp
    
    log_info "桌面环境及 XRDP 安装完毕。"
}

# 步骤 4: 驱动安装
install_nvidia_driver() {
    log_step "步骤 4: 安装 NVIDIA 驱动..."
    log_warn "此脚本使用 .run 文件安装驱动，该方法较为脆弱。在生产环境中，强烈推荐使用 'sudo ubuntu-drivers autoinstall' 命令进行安装。"
    
    if [[ ! -f "${NVIDIA_RUNFILE}" ]]; then
        log_error "NVIDIA 驱动文件 ${NVIDIA_RUNFILE} 未找到！"
        exit 1
    fi
    
    if [[ -n "$KERNEL_VERSION" && "$(uname -r)" != "${KERNEL_VERSION}" ]]; then
        log_warn "检测到内核已升级，但当前运行的仍是旧内核。"
        log_warn "强烈建议您先重启到新内核 (${KERNEL_VERSION}) 再安装驱动，以确保最佳兼容性。"
        read -p "是否继续在当前内核 ($(uname -r)) 下安装？ (y/n): " choice
        if [[ "$choice" != "y" && "$choice" != "Y" ]]; then
            log_info "操作已取消。请重启后再次运行脚本（或手动安装驱动）。"
            exit 0
        fi
    fi
    
    log_info "正在安装构建工具和内核头文件..."
    apt install -y build-essential dkms linux-headers-"$(uname -r)" gcc make

    if lsmod | grep -q nouveau; then
        log_warn "检测到 nouveau 驱动正在使用，将禁用它。"
        cat > /etc/modprobe.d/blacklist-nouveau.conf << 'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
        update-initramfs -u
        log_warn "nouveau 驱动已禁用，需要重启以生效。强烈建议重启后重新运行此脚本。"
        read -p "是否现在重启？ (y/n): " choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            reboot
        fi
        log_warn "继续安装，但可能会因 nouveau 冲突而失败。"
    fi

    chmod +x "${NVIDIA_RUNFILE}"
    
    log_info "正在停止图形界面服务..."
    systemctl stop gdm3 2>/dev/null || log_debug "GDM3 服务未运行或停止失败。"

    log_info "正在执行驱动安装程序 (非交互模式)..."
    log_warn "安装过程中可能会出现编译器版本不匹配的警告，已设置忽略。"
    
    ./"${NVIDIA_RUNFILE}" \
        --accept-license \
        --no-questions \
        --no-backup \
        --dkms \
        --no-cc-version-check \
        --install-libglvnd \
        --no-nouveau-check \
        --silent || {
        log_error "NVIDIA 驱动安装失败！"
        log_info "请检查安装日志: /var/log/nvidia-installer.log"
        tail -20 /var/log/nvidia-installer.log
        log_info "正在尝试重启图形界面服务..."
        systemctl start gdm3 2>/dev/null
        exit 1
    }
    
    log_info "NVIDIA 驱动安装成功。"
    if command -v nvidia-smi &> /dev/null; then
        log_info "驱动验证信息:"
        nvidia-smi
    else
        log_warn "nvidia-smi 命令尚不可用，请重启系统后再次验证。"
    fi
}

# 步骤 5: 配置 XRDP 和开放 root 登录
configure_system() {
    log_step "步骤 5: 配置 XRDP 和系统（高风险操作）..."

    backup_file() {
        local file="$1"
        if [[ -f "$file" ]]; then
            log_info "备份文件: $file -> ${file}.bak.$(date +%F)"
            cp -a "$file" "${file}.bak.$(date +%F)"
        fi
    }

    # 配置 XRDP 使用 GNOME Session
    log_info "为 root 用户创建 .xsession 文件以启动 GNOME..."
    cat > /root/.xsession << 'EOF'
export GNOME_SHELL_SESSION_MODE=ubuntu
exec /usr/bin/gnome-session --session=ubuntu
EOF
    chmod +x /root/.xsession

    # 允许所有用户连接 XRDP (解决 modern GNOME 的 color profile 权限问题)
    log_info "配置 Polkit 规则以允许 XRDP 会话正常初始化..."
    cat > /etc/polkit-1/rules.d/02-allow-colord.rules <<EOF
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.color-manager.create-device" ||
        action.id == "org.freedesktop.color-manager.create-profile" ||
        action.id == "org.freedesktop.color-manager.delete-device" ||
        action.id == "org.freedesktop.color-manager.delete-profile" ||
        action.id == "org.freedesktop.color-manager.modify-device" ||
        action.id == "org.freedesktop.color-manager.modify-profile") {
        if (subject.isInGroup("users")) {
            return polkit.Result.YES;
        }
    }
});
EOF

    log_warn "=== 正在执行高风险操作：开放 root 图形登录 ==="
    log_info "修改 GDM 配置..."
    local gdm_config="/etc/gdm3/custom.conf"
    backup_file "$gdm_config"
    sed -i '/^AllowRoot/d' "$gdm_config"
    sed -i '/\[daemon\]/a AllowRoot=true' "$gdm_config"

    log_info "修改 PAM 规则以允许 root 登录..."
    local pam_file="/etc/pam.d/gdm-password"
    local rule_to_comment='auth\s*required\s*pam_succeed_if.so\s*user\s*!=\s*root.*'
    if [[ -f "$pam_file" ]] && grep -qE "$rule_to_comment" "$pam_file"; then
        backup_file "$pam_file"
        sed -i -E "s/^($rule_to_comment)/#\1/" "$pam_file"
        log_info "已修改 gdm-password PAM 规则。"
    else
        log_warn "未找到适用于 root 限制的 PAM 规则于 $pam_file，跳过。"
    fi

    log_info "将 xrdp 用户添加到 ssl-cert 组..."
    adduser xrdp ssl-cert

    log_info "重启并启用相关服务..."
    systemctl enable gdm3
    systemctl enable xrdp
    systemctl restart xrdp

    log_info "XRDP 配置完成！默认端口: 3389"
}

# 步骤 6: 安装中文支持
install_chinese_support() {
    log_step "步骤 6: 安装中文语言支持..."
    
    apt install -y language-pack-zh-hans fonts-noto-cjk
    
    log_info "正在生成并设置中文 locale..."
    locale-gen zh_CN.UTF-8
    update-locale LANG=zh_CN.UTF-8
    
    {
        echo 'export LANG=zh_CN.UTF-8'
        echo 'export LC_ALL=zh_CN.UTF-8'
    } >> /etc/profile
    
    log_info "中文支持配置完成。重启后系统界面将变为中文。"
}

# 最终系统检查和建议
final_system_check() {
    log_step "======== 系统配置完成检查 ========"
    
    log_info "检查关键服务状态..."
    for service in xrdp gdm3; do
        if systemctl is-active --quiet "$service"; then
            log_info "✓ $service: 已运行"
        else
            log_warn "⚠ $service: 未运行"
        fi
    done
    
    if command -v nvidia-smi &> /dev/null; then log_info "✓ NVIDIA 驱动命令可用"; else log_warn "⚠ NVIDIA 驱动命令 (nvidia-smi) 不可用，请重启后检查"; fi
    
    local current_kernel
    current_kernel=$(uname -r)
    if [[ -n "$KERNEL_VERSION" && "$current_kernel" != "$KERNEL_VERSION" ]]; then
        log_warn "⚠ 当前内核 ($current_kernel) 与目标内核 ($KERNEL_VERSION) 不同。重启后将应用新内核。"
    else
        log_info "✓ 内核版本正确或未执行升级。"
    fi
    
    log_info "=================================="
    log_info "远程连接信息："
    log_info "- RDP 端口: 3389"
    log_info "- 用户名: root"
    log_warn "安全提醒: 生产环境中强烈不建议启用 root 远程登录。"
}

# --- 主执行流程 ---
main() {
    log_step "========================================================"
    log_step "开始执行 Ubuntu 服务器初始化配置"
    log_step "========================================================"

    upgrade_gcc
    upgrade_kernel
    install_desktop
    install_nvidia_driver
    configure_system
    install_chinese_support

    log_info "正在清理系统缓存..."
    apt autoremove -y >/dev/null 2>&1
    apt clean >/dev/null 2>&1
    
    final_system_check

    log_step "========================================================"
    log_step "所有操作已成功完成！"
    log_warn "强烈建议重启系统以应用所有更改："
    log_warn "- 新内核将生效"
    log_warn "- NVIDIA 驱动将完全加载"
    log_warn "- 中文界面将正确显示"
    log_step "========================================================"
    
    echo
    read -p "是否立即重启系统? (y/n): " choice
    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        log_info "系统将在 3 秒后重启..."
        sleep 3
        reboot
    else
        log_info "您选择了不立即重启。请稍后手动执行 'reboot' 命令。"
    fi
}

# --- 脚本启动入口 ---
if [[ "$(id -u)" -ne 0 ]]; then
   log_error "此脚本需要以 root 权限运行。请使用 'sudo ./your_script_name.sh'。"
   exit 1
fi

# 1. 基础环境检查
log_step "======== 1. 环境检查 ========"
check_system_version
check_network

# 2. 更新软件源并检测目标
log_step "======== 2. 更新源与检测目标 ========"
change_sources
detect_target_kernel
detect_nvidia_driver

# 3. 显示计划并请求确认
log_step "======== 3. 计划预览与确认 ========"
show_system_info
echo
read -p "检查以上计划。是否继续执行安装和配置? (y/n): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    log_info "操作已由用户取消。"
    exit 0
fi

# 4. 执行主函数
main
