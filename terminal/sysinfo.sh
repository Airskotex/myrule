#!/bin/bash
# /etc/profile.d/sysinfo.sh
# 登录后显示系统资源信息（最终修复版）

# ========== 仅在交互式 shell 中执行 ==========
if [[ $- != *i* ]]; then
    return 0 2>/dev/null || exit 0
fi

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
            command cat << 'EOF'
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
            command cat << 'EOF'
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
            command cat << 'EOF'
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
            command cat << 'EOF'
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
            command cat << 'EOF'
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

# ========== 进度条函数（动态宽度） ==========
progress_bar() {
    local percent=$1
    local term_width=$(tput cols 2>/dev/null || echo 80)
    local bar_len=$((term_width - 25))
    [ $bar_len -lt 10 ] && bar_len=10
    [ -n "$2" ] && bar_len=$2

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

# ========== 获取 CPU 使用率（快速） ==========
get_cpu_usage() {
    if [ -f /proc/stat ]; then
        # 第一次读取
        local prev_idle prev_total
        read -r _ _ _ _ idle _ < /proc/stat
        prev_idle=$idle
        read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
        prev_total=$((user + nice + system + idle + iowait + irq + softirq + steal))

        sleep 0.1

        # 第二次读取
        read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
        now_total=$((user + nice + system + idle + iowait + irq + softirq + steal))
        now_idle=$idle

        diff_total=$((now_total - prev_total))
        diff_idle=$((now_idle - prev_idle))

        if [ $diff_total -gt 0 ]; then
            usage=$((100 * (diff_total - diff_idle) / diff_total))
        else
            usage=0
        fi
        echo "$usage"
        return
    fi

    # 回退：使用 top
    if command -v top &>/dev/null; then
        if [ "$OS_ID" = "freebsd" ]; then
            top -b -d1 | grep 'CPU:' | head -1 | awk '{print int(100 - $NF)}'
        else
            top -bn1 | grep 'Cpu(s)' | awk '{print int($2 + $4)}'
        fi
    else
        echo "0"
    fi
}

# ========== 获取系统信息 ==========
get_system_info() {
    HOSTNAME_STR=$(hostname)
    KERNEL=$(uname -r)

    # 运行时间
    if command -v uptime &>/dev/null; then
        if [[ -f /proc/uptime ]]; then
            UPTIME_SECS=$(cut -d. -f1 /proc/uptime)
        else
            UPTIME_SECS=$(sysctl -n kern.boottime 2>/dev/null | awk '{print systime() - $4}' | tr -d ',')
        fi
        MONTHS=$((UPTIME_SECS / 2592000))
        DAYS=$(((UPTIME_SECS % 2592000) / 86400))
        HOURS=$(((UPTIME_SECS % 86400) / 3600))
        MINS=$(((UPTIME_SECS % 3600) / 60))
        UPTIME=""
        [[ $MONTHS -gt 0 ]] && UPTIME+="${MONTHS}月"
        [[ $DAYS -gt 0 ]] && UPTIME+="${DAYS}天"
        [[ $HOURS -gt 0 ]] && UPTIME+="${HOURS}小时"
        [[ $MINS -gt 0 ]] && UPTIME+="${MINS}分钟"
        [[ -z "$UPTIME" ]] && UPTIME="刚刚启动"
    fi

    USER_NAME=$(whoami)

    # CPU 信息
    if [ -f /proc/cpuinfo ]; then
        CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)
        CPU_CORES=$(grep -c '^processor' /proc/cpuinfo)
    elif [ "$OS_ID" = "freebsd" ]; then
        CPU_MODEL=$(sysctl -n hw.model 2>/dev/null)
        CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null)
    fi

    CPU_USAGE=$(get_cpu_usage)
    CPU_USAGE=${CPU_USAGE:-0}

    # 内存
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

    # SWAP（清理可能的单位字符）
	if command -v free &>/dev/null; then
		SWAP_TOTAL=$(free -m | awk '/Swap:/{print $2}')
		SWAP_USED=$(free -m | awk '/Swap:/{print $3}')
    # 确保是纯数字，去除可能存在的非数字字符（如换行、空格、单位字母等）
		SWAP_TOTAL=${SWAP_TOTAL//[^0-9]/}
		SWAP_USED=${SWAP_USED//[^0-9]/}
		if [ -n "$SWAP_TOTAL" ] && [ "$SWAP_TOTAL" -gt 0 ] 2>/dev/null; then
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
		SWAP_TOTAL=${SWAP_TOTAL//[^0-9]/}
		SWAP_USED=${SWAP_USED//[^0-9]/}
		if [ -n "$SWAP_TOTAL" ] && [ "$SWAP_TOTAL" -gt 0 ] 2>/dev/null; then
			SWAP_PERCENT=$(( SWAP_USED * 100 / SWAP_TOTAL ))
		else
			SWAP_PERCENT=0
			SWAP_TOTAL=0
			SWAP_USED=0
		fi
	fi

    # 磁盘
    DISK_INFO=$(df -h / 2>/dev/null | tail -1)
    DISK_TOTAL=$(echo "$DISK_INFO" | awk '{print $2}')
    DISK_USED=$(echo "$DISK_INFO" | awk '{print $3}')
    DISK_PERCENT=$(echo "$DISK_INFO" | awk '{print $5}' | tr -d '%')

    # 进程
    PROC_COUNT=$(ps aux 2>/dev/null | wc -l | xargs)

    # 负载（使用浮点运算）
    if [ -f /proc/loadavg ]; then
        read LOAD1 LOAD5 LOAD15 _ < /proc/loadavg
        CPU_CORES=${CPU_CORES:-$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)}
        # 使用 awk 计算负载百分比（保留一位小数）
        LOAD_PCT=$(awk "BEGIN {printf \"%.1f\", ($LOAD1/$CPU_CORES)*100}")
        # 将浮点数转换为整数用于比较（向下取整）
        LOAD_PCT_INT=${LOAD_PCT%.*}
        if [ -z "$LOAD_PCT_INT" ]; then
            LOAD_PCT_INT=0
        fi
        if [ "$LOAD_PCT_INT" -lt 70 ]; then
            LOAD_STATUS="正常"
        elif [ "$LOAD_PCT_INT" -lt 100 ]; then
            LOAD_STATUS="较高"
        else
            LOAD_STATUS="过载"
        fi
        LOAD_AVG="$LOAD1 $LOAD5 $LOAD15 (${LOAD_PCT}% - ${LOAD_STATUS})"
    fi

    # IP
    if command -v hostname &>/dev/null && hostname -I &>/dev/null 2>&1; then
        IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}')
    elif command -v ip &>/dev/null; then
        IP_ADDR=$(ip -4 addr show scope global 2>/dev/null | grep inet | head -1 | awk '{print $2}' | cut -d/ -f1)
    elif command -v ifconfig &>/dev/null; then
        IP_ADDR=$(ifconfig 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | head -1 | awk '{print $2}')
    fi
}

# ========== 格式化内存/磁盘大小为易读单位 ==========
fmt_size() {
    local size=$1
    local unit=$2
    if [ "$unit" = "M" ]; then
        if [ "$size" -ge 1024 ]; then
            printf "%.1fG" "$(awk "BEGIN {printf \"%.1f\", $size/1024}")"
        else
            echo "${size}M"
        fi
    else
        echo "${size}${unit}"
    fi
}

# ========== 主输出 ==========
main() {
    detect_os
    get_system_info
    echo   # 可选空行，若不需要可注释或删除
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
    printf "        ${BOLD}CPU:${RESET} "
    progress_bar "${CPU_USAGE:-0}"
    echo -e "            (${CPU_MODEL:-N/A} × ${CPU_CORES:-?} cores)"

    # 内存
    printf "     ${BOLD}内  存:${RESET} "
    progress_bar "${MEM_PERCENT:-0}"
    echo -e "            ($(fmt_size $MEM_USED_MB M) / $(fmt_size $MEM_TOTAL_MB M))"

    # SWAP
    printf "     ${BOLD}交换区:${RESET} "
    progress_bar "${SWAP_PERCENT:-0}"
    echo -e "            ($(fmt_size $SWAP_USED M) / $(fmt_size $SWAP_TOTAL M))"

    # 磁盘
    printf "     ${BOLD}磁  盘:${RESET} "
    progress_bar "${DISK_PERCENT:-0}"
    echo -e "            (${DISK_USED:-?} / ${DISK_TOTAL:-?})"

    # 进程
    echo -e "     ${BOLD}进程数:${RESET} ${PROC_COUNT}"

    echo ""
}

main
