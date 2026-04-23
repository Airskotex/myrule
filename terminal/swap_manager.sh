#!/bin/bash

# ==========================================
# 内存 ZRAM & SWAP 动态管理脚本 (修复版)
# ==========================================

# 确保以 root 身份运行
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本 (sudo ./swap_manager.sh)"
  exit 1
fi

SWAP_FILE="/swapfile"
ZRAM_SERVICE="/etc/systemd/system/zram-swap.service"
SYSCTL_CONF="/etc/sysctl.d/99-zram-swap.conf"

# 清理与卸载函数（彻底删除）
remove_all() {
    echo "=> 正在检测并清理历史 ZRAM 和 SWAP 配置..."

    if systemctl is-active --quiet zram-swap.service; then
        systemctl stop zram-swap.service
    fi
    if systemctl is-enabled --quiet zram-swap.service 2>/dev/null; then
        systemctl disable zram-swap.service
    fi
    rm -f "$ZRAM_SERVICE"
    systemctl daemon-reload

    for z in $(grep '^/dev/zram' /proc/swaps 2>/dev/null | awk '{print $1}'); do
        swapoff "$z" 2>/dev/null
    done
    
    if grep -q "$SWAP_FILE" /proc/swaps 2>/dev/null; then
        swapoff "$SWAP_FILE" 2>/dev/null
    fi

    if lsmod | grep -q zram; then
        for z in /sys/block/zram*; do
            echo 1 > "$z/reset" 2>/dev/null
        done
        modprobe -r zram 2>/dev/null
    fi

    if [ -f "$SWAP_FILE" ]; then
        rm -f "$SWAP_FILE"
    fi

    sed -i '/\/swapfile/d' /etc/fstab
    sed -i '/\/dev\/zram/d' /etc/fstab

    if [ -f "$SYSCTL_CONF" ]; then
        rm -f "$SYSCTL_CONF"
        sysctl --system >/dev/null 2>&1
    fi

    echo "=> 清理完毕！"
}

# 安装与配置函数
install_all() {
    # 强制先清理，避免冲突和重复配置
    remove_all

    echo "=> 正在分析系统内存..."
    
    # 修复：直接从 /proc/meminfo 读取，无视系统语言环境
    TOTAL_MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    
    # 防止读取失败的兜底逻辑
    if [ -z "$TOTAL_MEM_MB" ]; then
        echo "无法读取系统内存，默认按 4G 计算..."
        TOTAL_MEM_MB=4096
    fi
    
    # 动态匹配逻辑
    if [ "$TOTAL_MEM_MB" -le 1536 ]; then      # ~1G
        ZRAM_SIZE=512
        SWAP_SIZE=1024
    elif [ "$TOTAL_MEM_MB" -le 2560 ]; then    # ~2G
        ZRAM_SIZE=1024
        SWAP_SIZE=2048
    elif [ "$TOTAL_MEM_MB" -le 3584 ]; then    # ~3G
        ZRAM_SIZE=1536
        SWAP_SIZE=3072
    elif [ "$TOTAL_MEM_MB" -le 4608 ]; then    # ~4G
        ZRAM_SIZE=2048
        SWAP_SIZE=4096
    elif [ "$TOTAL_MEM_MB" -le 6656 ]; then    # ~6G
        ZRAM_SIZE=3072
        SWAP_SIZE=6144
    elif [ "$TOTAL_MEM_MB" -le 8704 ]; then    # ~8G
        ZRAM_SIZE=4096
        SWAP_SIZE=8192
    elif [ "$TOTAL_MEM_MB" -le 12800 ]; then   # ~12G
        ZRAM_SIZE=4096
        SWAP_SIZE=8192
    else                                       # >=16G
        ZRAM_SIZE=4096
        SWAP_SIZE=8192
    fi

    echo "检测到物理内存: ${TOTAL_MEM_MB}MB"
    echo "计划分配 ZRAM: ${ZRAM_SIZE}MB (高优先级 100)"
    echo "计划分配 SWAP: ${SWAP_SIZE}MB (低优先级 10)"

    echo "=> 正在创建磁盘 SWAP (${SWAP_SIZE}MB) 文件，可能需要几秒钟..."
    dd if=/dev/zero of=$SWAP_FILE bs=1M count=$SWAP_SIZE status=none
    chmod 600 $SWAP_FILE
    mkswap $SWAP_FILE >/dev/null 2>&1
    swapon -p 10 $SWAP_FILE
    
    echo "$SWAP_FILE none swap sw,pri=10 0 0" >> /etc/fstab

    echo "=> 正在配置 ZRAM systemd 自启服务..."
    cat > "$ZRAM_SERVICE" <<EOF
[Unit]
Description=ZRAM Swap Setup
After=local-fs.target

[Service]
Type=oneshot
ExecStartPre=-/sbin/modprobe zram
ExecStart=/bin/bash -c 'echo zstd > /sys/block/zram0/comp_algorithm || echo lz4 > /sys/block/zram0/comp_algorithm; echo ${ZRAM_SIZE}M > /sys/block/zram0/disksize; mkswap /dev/zram0; swapon -p 100 /dev/zram0'
ExecStop=/bin/bash -c 'swapoff /dev/zram0; echo 1 > /sys/block/zram0/reset'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now zram-swap.service >/dev/null 2>&1

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
}

case "$1" in
    install)
        install_all
        ;;
    remove)
        remove_all
        echo "=========================================="
        echo "已彻底销毁并清理所有 ZRAM 和 SWAP 设置。"
        echo "=========================================="
        ;;
    *)
        echo "用法: $0 {install|remove}"
        exit 1
esac
