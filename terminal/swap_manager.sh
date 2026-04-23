#!/bin/bash

# ==========================================
# 内存 ZRAM & SWAP 动态管理脚本 (修复版 v4)
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

# 检测 ZRAM 内核配置类型
get_zram_kernel_config() {
    local cfg="/boot/config-$(uname -r)"
    if [ ! -f "$cfg" ]; then
        echo "unknown"
        return
    fi
    local val
    val=$(grep '^CONFIG_ZRAM=' "$cfg" | cut -d= -f2)
    case "$val" in
        y) echo "builtin" ;;
        m) echo "module" ;;
        *) echo "unsupported" ;;
    esac
}

# 确保 zram 模块可用，返回 0=成功 1=失败
ensure_zram_ready() {
    # 已经有设备节点，直接返回成功
    if ls /sys/block/zram* &>/dev/null; then
        echo "=> ZRAM 设备已就绪。"
        return 0
    fi

    local kconfig
    kconfig=$(get_zram_kernel_config)

    case "$kconfig" in
        builtin)
            # 内置但设备不存在，异常情况
            echo "=> ✗ 内核内置了 ZRAM 但设备节点不存在，系统异常。"
            return 1
            ;;
        module)
            # 是模块，尝试 modprobe
            echo "=> ZRAM 编译为内核模块，尝试加载..."
            if modprobe zram 2>/dev/null; then
                sleep 1
                if ls /sys/block/zram* &>/dev/null; then
                    echo "=> ✓ ZRAM 模块加载成功。"
                    return 0
                fi
            fi

            # modprobe 失败，说明 .ko 文件缺失，尝试安装 linux-modules-extra
            local pkg="linux-modules-extra-$(uname -r)"
            echo "=> ZRAM .ko 文件缺失，尝试安装 ${pkg}..."
            if ! apt-get install -y "$pkg" >/dev/null 2>&1; then
                echo "=> ✗ 安装 ${pkg} 失败，请检查网络或软件源。"
                return 1
            fi
            echo "=> ✓ ${pkg} 安装完成，重新加载 ZRAM 模块..."
            if modprobe zram 2>/dev/null; then
                sleep 1
                if ls /sys/block/zram* &>/dev/null; then
                    echo "=> ✓ ZRAM 模块加载成功。"
                    return 0
                fi
            fi

            echo "=> ✗ 安装后仍无法加载 ZRAM 模块。"
            return 1
            ;;
        unsupported)
            echo "=> ✗ 当前内核 ($(uname -r)) 不支持 ZRAM（未编译）。"
            echo "   建议安装标准内核："
            echo "     apt install linux-image-generic linux-modules-extra-generic"
            echo "     reboot"
            return 1
            ;;
        unknown)
            # 找不到内核配置文件，直接试 modprobe
            echo "=> 内核配置文件未找到，直接尝试加载 ZRAM 模块..."
            if modprobe zram 2>/dev/null; then
                sleep 1
                ls /sys/block/zram* &>/dev/null && return 0
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
        # ── 卸载 zram 让 systemd 服务来管理 ──
        if ls /sys/block/zram* &>/dev/null; then
            modprobe -r zram 2>/dev/null || true
        fi

        # ── 生成 ZRAM 启动脚本 ──
        echo "=> 正在生成 ZRAM 配置脚本..."
        cat > "$ZRAM_SCRIPT" <<SCRIPT
#!/bin/bash
set -e

KERNEL_PKG="linux-modules-extra-\$(uname -r)"

# 如果设备不存在，尝试加载模块
if ! ls /sys/block/zram* &>/dev/null; then
    if ! modprobe zram 2>/dev/null; then
        echo "modprobe zram 失败，尝试安装 \${KERNEL_PKG}..." >&2
        apt-get install -y "\$KERNEL_PKG" >/dev/null 2>&1 || true
        modprobe zram || { echo "ERROR: 无法加载 zram 模块" >&2; exit 1; }
    fi
    # 等待设备节点就绪（最多5秒）
    for i in \$(seq 1 10); do
        [ -b /dev/zram0 ] && break
        sleep 0.5
    done
fi

if [ ! -b /dev/zram0 ]; then
    echo "ERROR: /dev/zram0 设备未就绪" >&2
    exit 1
fi

# 设置压缩算法（读取支持列表后再写，优先 zstd > lz4 > 默认）
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
