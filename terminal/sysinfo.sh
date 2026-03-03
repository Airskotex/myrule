#!/bin/bash
# /etc/profile.d/motd.sh
# 登录后显示系统资源信息（支持 Ubuntu / Debian / OpenEuler / FreeBSD）

# ========== 颜色定义 ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
RESET='\033[0m'

# ========== 检测操作系统 ==========
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
        OS_NAME="$PRETTY_NAME"
    elif [ "$(uname)" = "FreeBSD" ]; then
        OS_ID="freebsd"
        OS_NAME="$(freebsd-version)"
    else
        OS_ID="unknown"
        OS_NAME="$(uname -s) $(uname -r)"
    fi
}

# ========== ASCII LOGO ==========
print_logo() {
    case "$OS_ID" in
        ubuntu)
            echo -e "${YELLOW}"
            cat << 'EOF'
             _
         ---(_)
     _/  ---  \
    (_) |   |
      \  --- _/
         ---(_)
EOF
            echo -e "${RESET}"
            ACCENT_COLOR="$YELLOW"
            ;;
        debian)
            echo -e "${RED}"
            cat << 'EOF'
       _____
      /  __ \
     |  /    |
     |  \___-
     -_
       --_
EOF
            echo -e "${RESET}"
            ACCENT_COLOR="$RED"
            ;;
        openeuler|openEuler)
            echo -e "${BLUE}"
            cat << 'EOF'
               __
          ____/ /
         / __  /
        / /_/ /___
        \____/ __ \
          / / / / /
         / / / / /
        /_/ /_/ /
           \___/    openEuler
EOF
            echo -e "${RESET}"
            ACCENT_COLOR="$BLUE"
            ;;
        freebsd)
            echo -e "${RED}"
            cat << 'EOF'
  ,        ,
 /(        )`
 \ \___   / |
 /- _  `-/  '
(/\/ \ \   /\
/ /   | `    \
O O   ) /    |
`-^--'`<     '
(_.)  _  )   /
 `.___/`    /
   `-----' /
<----.     __/ __   \
<----|====O)))==)  \) /====
<----'    `--' `.__,' \
            |        |
             \       /
       ______( (_  / \______
     ,'  ,-----'   |        \
     `--{__________)        \/
EOF
            echo -e "${RESET}"
            ACCENT_COLOR="$RED"
            ;;
        *)
            echo -e "${GREEN}"
            cat << 'EOF'
    ___
   (.. |
   (<> |
  / __  \
 ( /  \ /|
_/\ __)/_)
\/-____\/
EOF
            echo -e "${RESET}"
            ACCENT_COLOR="$GREEN"
            ;;
    esac
}

# ========== 进度条函数 ==========
# 参数: $1=已用百分比(整数)  $2=条形总长度
progress_bar() {
    local percent=$1
    local bar_len=${2:-37}
    local filled=$(( percent * bar_len / 100 ))
    local empty=$(( bar_len - filled ))

    local bar=""
    local color=""

    if [ "$percent" -lt 50 ]; then
        color="$GREEN"
    elif [ "$percent" -lt 80 ]; then
        color="$YELLOW"
    else
        color="$RED"
    fi

    bar+="["
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+=" "; done
    bar+="]"

    echo -e "${color}${bar}${RESET} ${BOLD}${percent}%${RESET}"
}

# ========== 获取系统信息 ==========
get_system_info() {
    # 主机名
    HOSTNAME_STR=$(hostname)

    # 内核版本
    KERNEL=$(uname -r)

    # 运行时间
    # 运行时间（转换为月/天/小时/分钟格式）
    if command -v uptime &>/dev/null; then
    # 获取运行秒数
        if [[ -f /proc/uptime ]]; then
            UPTIME_SECS=$(cut -d. -f1 /proc/uptime)
        else
            # macOS 兼容
            UPTIME_SECS=$(sysctl -n kern.boottime | awk '{print systime() - $4}' | tr -d ',')
        fi
    
        # 计算各时间单位
        MONTHS=$((UPTIME_SECS / 2592000))      # 30天算1月
        DAYS=$(((UPTIME_SECS % 2592000) / 86400))
        HOURS=$(((UPTIME_SECS % 86400) / 3600))
        MINS=$(((UPTIME_SECS % 3600) / 60))
    
        # 拼接显示字符串（只显示非零部分）
        UPTIME=""
        [[ $MONTHS -gt 0 ]] && UPTIME+="${MONTHS}月"
        [[ $DAYS -gt 0 ]] && UPTIME+="${DAYS}天"
        [[ $HOURS -gt 0 ]] && UPTIME+="${HOURS}小时"
        [[ $MINS -gt 0 ]] && UPTIME+="${MINS}分钟"
        [[ -z "$UPTIME" ]] && UPTIME="刚刚启动"
    fi

    # 登录用户
    USER_NAME=$(whoami)

    # 最后登录
    LAST_LOGIN=$(last -1 "$USER_NAME" 2>/dev/null | head -1 | awk '{for(i=3;i<=NF;i++) printf $i" "; print ""}' | sed 's/still logged in.*//')

    # CPU 信息
    if [ -f /proc/cpuinfo ]; then
        CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)
        CPU_CORES=$(grep -c '^processor' /proc/cpuinfo)
    elif [ "$OS_ID" = "freebsd" ]; then
        CPU_MODEL=$(sysctl -n hw.model 2>/dev/null)
        CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null)
    fi

    # CPU 使用率
    if command -v mpstat &>/dev/null; then
        CPU_IDLE=$(mpstat 1 1 2>/dev/null | tail -1 | awk '{print $NF}')
        CPU_USAGE=$(echo "100 - ${CPU_IDLE:-0}" | bc 2>/dev/null | cut -d. -f1)
    elif command -v top &>/dev/null; then
        if [ "$OS_ID" = "freebsd" ]; then
            CPU_USAGE=$(top -b -d1 | grep 'CPU:' | head -1 | awk '{print 100-$NF}' | cut -d. -f1)
        else
            CPU_USAGE=$(top -bn1 | grep 'Cpu(s)' | awk '{print int($2 + $4)}')
        fi
    fi
    CPU_USAGE=${CPU_USAGE:-0}

    # 内存信息
    if [ -f /proc/meminfo ]; then
        MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        MEM_AVAIL_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
        if [ -z "$MEM_AVAIL_KB" ]; then
            MEM_FREE_KB=$(grep MemFree /proc/meminfo | awk '{print $2}')
            MEM_AVAIL_KB=$MEM_FREE_KB
        fi
        MEM_USED_KB=$(( MEM_TOTAL_KB - MEM_AVAIL_KB ))
        MEM_TOTAL_MB=$(( MEM_TOTAL_KB / 1024 ))
        MEM_USED_MB=$(( MEM_USED_KB / 1024 ))
        MEM_PERCENT=$(( MEM_USED_KB * 100 / MEM_TOTAL_KB ))
    elif [ "$OS_ID" = "freebsd" ]; then
        MEM_TOTAL_BYTES=$(sysctl -n hw.physmem 2>/dev/null)
        MEM_FREE_PAGES=$(sysctl -n vm.stats.vm.v_free_count 2>/dev/null)
        PAGE_SIZE=$(sysctl -n hw.pagesize 2>/dev/null)
        MEM_TOTAL_MB=$(( MEM_TOTAL_BYTES / 1024 / 1024 ))
        MEM_FREE_MB=$(( MEM_FREE_PAGES * PAGE_SIZE / 1024 / 1024 ))
        MEM_USED_MB=$(( MEM_TOTAL_MB - MEM_FREE_MB ))
        MEM_PERCENT=$(( MEM_USED_MB * 100 / MEM_TOTAL_MB ))
    fi

    # SWAP 信息
    if command -v free &>/dev/null; then
        SWAP_TOTAL=$(free -m | awk '/Swap:/{print $2}')
        SWAP_USED=$(free -m | awk '/Swap:/{print $3}')
        if [ "${SWAP_TOTAL:-0}" -gt 0 ]; then
            SWAP_PERCENT=$(( SWAP_USED * 100 / SWAP_TOTAL ))
        else
            SWAP_PERCENT=0
            SWAP_TOTAL=0
            SWAP_USED=0
        fi
    elif [ "$OS_ID" = "freebsd" ]; then
        SWAP_INFO=$(swapinfo -m 2>/dev/null | tail -1)
        SWAP_TOTAL=$(echo "$SWAP_INFO" | awk '{print $2}')
        SWAP_USED=$(echo "$SWAP_INFO" | awk '{print $3}')
        if [ "${SWAP_TOTAL:-0}" -gt 0 ]; then
            SWAP_PERCENT=$(( SWAP_USED * 100 / SWAP_TOTAL ))
        else
            SWAP_PERCENT=0
        fi
    fi

    # 磁盘信息
    DISK_INFO=$(df -h / 2>/dev/null | tail -1)
    DISK_TOTAL=$(echo "$DISK_INFO" | awk '{print $2}')
    DISK_USED=$(echo "$DISK_INFO" | awk '{print $3}')
    DISK_PERCENT=$(echo "$DISK_INFO" | awk '{print $5}' | tr -d '%')

    # 进程数
    PROC_COUNT=$(ps aux 2>/dev/null | wc -l | xargs)
    PROC_MAX=$(ulimit -u 2>/dev/null || echo "N/A")

    # 负载
    if [ -f /proc/loadavg ]; then
        LOAD_AVG=$(cat /proc/loadavg | awk '{print $1, $2, $3}')
    else
        LOAD_AVG=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')
    fi

    # 网络 IP
    if command -v ip &>/dev/null; then
        IP_ADDR=$(ip -4 addr show scope global 2>/dev/null | grep inet | head -1 | awk '{print $2}' | cut -d/ -f1)
    elif command -v ifconfig &>/dev/null; then
        IP_ADDR=$(ifconfig 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | head -1 | awk '{print $2}')
    fi
}

# ========== 格式化输出函数 ==========
fmt_mb() {
    local mb=$1
    if [ "$mb" -ge 1024 ]; then
        echo "$(echo "scale=1; $mb/1024" | bc)G"
    else
        echo "${mb}M"
    fi
}

# ========== 主输出 ==========
main() {
    detect_os
    get_system_info
    echo ""
    print_logo

    echo -e " ${ACCENT_COLOR}${BOLD}=[ 系统信息 ]=${RESET}"
    echo -e "         ${BOLD}系统:${RESET} ${OS_NAME}"
    echo -e "         ${BOLD}内核:${RESET} ${KERNEL}"
    echo -e "       ${BOLD}主机名:${RESET} ${HOSTNAME_STR}"
    echo -e "       ${BOLD}用户名:${RESET} ${USER_NAME}"
    echo -e "     ${BOLD}运行时间:${RESET} ${UPTIME}"
    echo -e "       ${BOLD}负  载:${RESET} ${LOAD_AVG}"
    [ -n "$IP_ADDR" ] && echo -e "      ${BOLD}IP 地址:${RESET} ${IP_ADDR}"
    echo ""

    echo -e " ${ACCENT_COLOR}${BOLD}=[ 资源使用 ]=${RESET}"

    # CPU
    printf "       ${BOLD}CPU:${RESET} "
    progress_bar "${CPU_USAGE:-0}"
    echo -e "            (${CPU_MODEL:-N/A} × ${CPU_CORES:-?} cores)"

    # 内存
    printf "     ${BOLD}内  存:${RESET} "
    progress_bar "${MEM_PERCENT:-0}"
    echo -e "            ($(fmt_mb ${MEM_USED_MB:-0}) / $(fmt_mb ${MEM_TOTAL_MB:-0}))"

    # SWAP
    printf "     ${BOLD}交换区:${RESET} "
    progress_bar "${SWAP_PERCENT:-0}"
    echo -e "            (${SWAP_USED:-0}M / ${SWAP_TOTAL:-0}M)"

    # 磁盘
    printf "     ${BOLD}磁  盘:${RESET} "
    progress_bar "${DISK_PERCENT:-0}"
    echo -e "            (${DISK_USED:-?} / ${DISK_TOTAL:-?})"

    # 进程
    echo -e "     ${BOLD}进程数:${RESET} ${PROC_COUNT}"

    echo ""
}

main
