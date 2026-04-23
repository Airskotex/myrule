#!/bin/bash

# ==========================================
# 内存 ZRAM & SWAP 动态管理脚本 (修复版 v5)
# ==========================================

if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本 (sudo ./swap_manager.sh)"
  exit 1
fi

SWAP_FILE="/swapfile"
ZRAM_SERVICE="/etc/systemd/system/zram-swap.service"
ZRAM_SCRIPT="/usr/local/bin/zram-setup.sh"
SYSCTL_CONF="/etc/sysctl.d/99-zram-swap.conf"

remove_all() {
    echo "=> 正在检测并清理历史 ZRAM 和 SWAP 配置..."
    systemctl stop zram-swap.service 2>/dev/null
    systemctl disable zram-swap.service 2>/dev/null
    rm -f "$ZRAM_SERVICE" "$ZRAM_SCRIPT"
    systemctl daemon-reload

    for z in $(grep '^/dev/zram' /proc/swaps 2>/dev/null | awk '{print $1}'); do
        swapoff "$z" 2>/dev/null
    done
    grep -q "$SWAP_FILE" /proc/swaps 2>/dev/null && swapoff "$SWAP_FILE" 2>/dev/null

    if lsmod | grep -q zram; then
        for z in /sys/block/zram*; do
            [ -f "$z/reset" ] && echo 1 > "$z/reset" 2>/dev/null
        done
        modprobe -r zram 2>/dev/null
    fi

    [ -f "$SWAP_FILE" ] && rm -f "$SWAP_FILE"
    sed -i '/\/swapfile/d' /etc/fstab
    sed -i '/\/dev\/zram/d' /etc/fstab
    [ -f "$SYSCTL_CONF" ] && rm -f "$SYSCTL_CONF" && sysctl --system >/dev/null 2>&1
    echo "=> 清理完毕！"
}

# 读取内核编译配置中 ZRAM 的编译方式
get_zram_kernel_config() {
    local cfg="/boot/config-$(uname -r)"
    [ ! -f "$cfg" ] && echo "unknown" && return
    local val
    val=$(grep '^CONFIG_ZRAM=' "$cfg" | cut -d= -f2)
    case "$val" in
        y) echo "builtin" ;;
        m) echo "module"  ;;
        *) echo "unsupported" ;;
    esac
}

# 尝试直接 modprobe，成功返回 0
try_modprobe_zram() {
    modprobe zram 2>/dev/null || return 1
    for i in $(seq 1 10); do
        ls /sys/block/zram* &>/dev/null && return 0
        sleep 0.5
    done
    return 1
}

# 尝试安装 linux-modules-extra 后再 modprobe
# 适用于 Ubuntu/Debian 提供此包的场景；若包不存在则静默跳过
try_install_modules_extra() {
    local pkg="linux-modules-extra-$(uname -r)"
    echo "=> ZRAM .ko 文件缺失，尝试安装 ${pkg}..."

    # 先检查包是否存在于软件源，避免无意义等待
    if ! apt-cache show "$pkg" &>/dev/null; then
        echo "=> 软件源中未找到 ${pkg}，跳过安装。"
        return 1
    fi

    if apt-get install -y "$pkg" >/dev/null 2>&1; then
        echo "=> ✓ ${pkg} 安装完成，重新加载 ZRAM 模块..."
        try_modprobe_zram && return 0
    fi

    echo "=> ✗ 安装 ${pkg} 后仍无法加载 ZRAM 模块。"
    return 1
}

# 主检测函数：确保 zram 设备就绪，返回 0=成功 1=失败
ensure_zram_ready() {
    # 设备已存在（built-in 或已加载）
    if ls /sys/block/zram* &>/dev/null; then
        echo "=> ZRAM 设备已就绪。"
        return 0
    fi

    local kconfig
    kconfig=$(get_zram_kernel_config)

    case "$kconfig" in
        builtin)
            echo "=> ✗ 内核内置了 ZRAM 但设备节点不存在，系统异常。"
            return 1
            ;;
        module)
            echo "=> ZRAM 编译为内核模块，尝试加载..."
            # 第一步：直接 modprobe
            if try_modprobe_zram; then
                echo "=> ✓ ZRAM 模块加载成功。"
                return 0
            fi
            # 第二步：.ko 缺失，尝试安装 linux-modules-extra（仅 Ubuntu/部分 Debian）
            if try_install_modules_extra; then
                echo "=> ✓ ZRAM 模块加载成功。"
                return 0
            fi
            # 两步均失败
            echo "=> ✗ 无法加载 ZRAM 模块。"
            echo "   当前内核: $(uname -r)"
            echo "   该内核的模块包可能不在官方源中（如 Debian cloud 内核）。"
            echo "   可尝试切换为标准内核后重试："
            echo "     apt install linux-image-amd64 linux-modules-extra-amd64"
            echo "     reboot"
            return 1
            ;;
        unsupported)
            echo "=> ✗ 当前内核 ($(uname -r)) 不支持 ZRAM（未编译）。"
            echo "   可尝试安装标准内核："
            echo "     apt install linux-image-generic linux-modules-extra-generic  # Ubuntu"
            echo "     apt install linux-image-amd64                                 # Debian"
            echo "     reboot"
            return 1
            ;;
        unknown)
            echo "=> 内核配置文件未找到，直接尝试加载 ZRAM 模块..."
            if try_modprobe_zram; then
                echo "=> ✓ ZRAM 模块加载成功。"
                return 0
            fi
            echo "=> ✗ 无法加载 ZRAM 模块。"
            return 1
            ;;
    esac
}

install_all() {
    remove_all

    echo "=> 正在分析系统内存..."
    TOTAL_MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    [ -z "$TOTAL_MEM_MB" ] && TOTAL_MEM_MB=4096

    if [ "$TOTAL_MEM_MB" -le 1536 ]; then
        ZRAM_SIZE=512;  SWAP_SIZE=1024
    elif [ "$TOTAL_MEM_MB" -le 2560 ]; then
        ZRAM_SIZE=1024; SWAP_SIZE=2048
    elif [ "$TOTAL_MEM_MB" -le 3584 ]; then
        ZRAM_SIZE=1536; SWAP_SIZE=3072
    elif [ "$TOTAL_MEM_MB" -le 4608 ]; then
        ZRAM_SIZE=2048; SWAP_SIZE=4096
    elif [ "$TOTAL_MEM_MB" -le 6656 ]; then
        ZRAM_SIZE=3072; SWAP_SIZE=6144
    elif [ "$TOTAL_MEM_MB" -le 8704 ]; then
        ZRAM_SIZE=4096; SWAP_SIZE=8192
    elif [ "$TOTAL_MEM_MB" -le 12800 ]; then
        ZRAM_SIZE=4096; SWAP_SIZE=8192
    else
        ZRAM_SIZE=4096; SWAP_SIZE=8192
    fi

    echo "检测到物理内存: ${TOTAL_MEM_MB}MB"
    echo "计划分配 ZRAM: ${ZRAM_SIZE}MB (高优先级 100)"
    echo "计划分配 SWAP: ${SWAP_SIZE}MB (低优先级 10)"

    # ── 磁盘 SWAP ──
    echo "=> 正在创建磁盘 SWAP (${SWAP_SIZE}MB) 文件..."
    dd if=/dev/zero of=$SWAP_FILE bs=1M count=$SWAP_SIZE status=none
    chmod 600 $SWAP_FILE
    mkswap $SWAP_FILE >/dev/null
    swapon -p 10 $SWAP_FILE
    echo "$SWAP_FILE none swap sw,pri=10 0 0" >> /etc/fstab

    # ── 检测并确保 ZRAM 可用 ──
    echo "=> 正在检测 ZRAM 内核支持..."
    if ! ensure_zram_ready; then
        echo "=========================================="
        echo "⚠ 警告：ZRAM 不可用，仅启用磁盘 SWAP。"
        echo "=========================================="
    else
        # 卸载，交由 systemd 服务统一管理
        modprobe -r zram 2>/dev/null || true

        # ── 生成 ZRAM 启动脚本 ──
        echo "=> 正在生成 ZRAM 配置脚本..."
        cat > "$ZRAM_SCRIPT" <<SCRIPT
#!/bin/bash
set -e

_zram_ready() {
    ls /sys/block/zram* &>/dev/null
}

_wait_device() {
    for i in \$(seq 1 10); do
        [ -b /dev/zram0 ] && return 0
        sleep 0.5
    done
    return 1
}

# 若设备不存在则尝试加载模块
if ! _zram_ready; then
    if ! modprobe zram 2>/dev/null; then
        # 尝试安装 linux-modules-extra（仅在包存在时）
        PKG="linux-modules-extra-\$(uname -r)"
        if apt-cache show "\$PKG" &>/dev/null; then
            apt-get install -y "\$PKG" >/dev/null 2>&1 || true
        fi
        modprobe zram || { echo "ERROR: 无法加载 zram 模块" >&2; exit 1; }
    fi
    _wait_device || { echo "ERROR: /dev/zram0 设备未就绪" >&2; exit 1; }
fi

if [ ! -b /dev/zram0 ]; then
    echo "ERROR: /dev/zram0 设备未就绪" >&2
    exit 1
fi

# 设置压缩算法（优先 zstd > lz4 > 内核默认）
ALGO_FILE=/sys/block/zram0/comp_algorithm
if [ -f "\$ALGO_FILE" ]; then
    if grep -qw zstd "\$ALGO_FILE"; then
        echo zstd > "\$ALGO_FILE"
    elif grep -qw lz4 "\$ALGO_FILE"; then
        echo lz4 > "\$ALGO_FILE"
    fi
fi

echo ${ZRAM_SIZE}M > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon -p 100 /dev/zram0

echo "ZRAM 启动成功: \$(grep zram /proc/swaps)"
SCRIPT
        chmod +x "$ZRAM_SCRIPT"

        # ── Systemd 服务 ──
        echo "=> 正在配置 ZRAM systemd 自启服务..."
        cat > "$ZRAM_SERVICE" <<EOF
[Unit]
Description=ZRAM Swap Setup
After=local-fs.target

[Service]
Type=oneshot
ExecStart=$ZRAM_SCRIPT
ExecStop=/bin/bash -c 'swapoff /dev/zram0 2>/dev/null; echo 1 > /sys/block/zram0/reset 2>/dev/null; modprobe -r zram 2>/dev/null; true'
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable zram-swap.service

        echo "=> 正在启动 ZRAM 服务..."
        if systemctl start zram-swap.service; then
            echo "=> ✓ ZRAM 服务启动成功！"
        else
            echo "=> ✗ ZRAM 服务启动失败，日志如下："
            journalctl -u zram-swap.service --no-pager -n 20
        fi
    fi

    # ── Sysctl 优化 ──
    echo "=> 正在写入 Sysctl 优化参数..."
    cat > "$SYSCTL_CONF" <<EOF
vm.swappiness = 100
vm.page-cluster = 0
vm.vfs_cache_pressure = 50
EOF
    sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1

    echo "=========================================="
    echo "=> 部署完成！当前 SWAP 状态如下："
    LC_ALL=C swapon --show
    echo "=========================================="

    if grep -q zram /proc/swaps; then
        echo "✓ ZRAM 配置成功！"
    else
        echo "✗ ZRAM 未生效，诊断命令："
        echo "  journalctl -u zram-swap.service --no-pager"
    fi
}

case "$1" in
    install) install_all ;;
    remove)
        remove_all
        echo "=========================================="
        echo "已彻底清理所有 ZRAM 和 SWAP 设置。"
        echo "=========================================="
        ;;
    *)
        echo "用法: $0 {install|remove}"
        exit 1
esac
