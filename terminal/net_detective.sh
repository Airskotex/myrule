#!/bin/bash

# ================= 变量配置区 (根据实际情况修改) =================
# iperf3 服务端地址
SERVER_IP="125.71.97.48"
SERVER_PORT="5201"

# 你的理论带宽 (Mbps)
EXPECTED_BW="100"

# 测试时长 (秒)
TEST_DURATION="10"

# AI 分析报告的文件名
AI_LOG="network_debug_data_for_ai.txt"
# ===============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0;m'

# 检查必要依赖
if ! command -v jq &> /dev/null; then
    echo -e "${RED}错误: 必须安装 'jq' 工具用于处理 JSON 数据 (apt install jq / yum install jq)${NC}"
    exit 1
fi

# 初始化 AI 日志文件
echo "==================================================" > "$AI_LOG"
echo "NETWORK DIAGNOSTIC RAW DATA FOR AI ANALYSIS" >> "$AI_LOG"
echo "Generated on: $(date)" >> "$AI_LOG"
echo "Target Server: $SERVER_IP" >> "$AI_LOG"
echo "Expected Bandwidth: $EXPECTED_BW Mbps" >> "$AI_LOG"
echo "==================================================" >> "$AI_LOG"

# 辅助函数：记录原始数据到 AI 日志
log_to_ai() {
    echo -e "\n>>> SECTION: $1" >> "$AI_LOG"
    cat "$2" >> "$AI_LOG" 2>&1
}

# 辅助函数：人类可读输出
print_human() {
    echo -e "$1"
}

# === 阶段 1: 系统与链路环境检查 ===
print_human "${CYAN}[1/4] 正在检查基础环境与链路质量...${NC}"

# 获取默认接口
DEFAULT_IF=$(ip route | grep default | awk '{print $5}' | head -n1)
echo "Interface Info: $DEFAULT_IF" > temp_sys.txt
if command -v ethtool &> /dev/null; then
    ethtool "$DEFAULT_IF" >> temp_sys.txt
fi
sysctl -a 2>/dev/null | grep "net.ipv4.tcp" >> temp_sys.txt
log_to_ai "SYSTEM & KERNEL & ETHTOOL" "temp_sys.txt"

# MTR / Ping 测试
print_human "      正在探测路由节点丢包 (MTR)..."
mtr -r -c 10 -n "$SERVER_IP" > temp_mtr.txt
log_to_ai "MTR ROUTE TRACE" "temp_mtr.txt"

# 提取 MTR 丢包率给用户看
LOSS=$(grep -w "$SERVER_IP" temp_mtr.txt | awk '{print $3}' | tr -d '%')
if [ -z "$LOSS" ]; then LOSS="0"; fi

if (( $(echo "$LOSS > 0" | bc -l) )); then
    print_human "${RED}      警告: 端到端丢包率为 ${LOSS}% (可能导致严重降速)${NC}"
else
    print_human "${GREEN}      链路正常: 0% 丢包${NC}"
fi

# 记录测试前的网卡计数
cat /sys/class/net/$DEFAULT_IF/statistics/rx_errors > rx_err_start.tmp
cat /sys/class/net/$DEFAULT_IF/statistics/rx_dropped > rx_drop_start.tmp

# === 阶段 2: iperf3 测试逻辑 ===
run_test() {
    TYPE=$1      # 描述
    DIR_FLAG=$2  # -R 或 空
    STREAMS=$3   # 并发数
    
    print_human "${CYAN}[Step] 开始测试: $TYPE (并发: $STREAMS)${NC}"
    print_human "       正在跑流量，请稍候 ($TEST_DURATION 秒)..."
    
    # 执行 iperf3 并输出 JSON 到临时文件
    iperf3 -c "$SERVER_IP" -p "$SERVER_PORT" -t "$TEST_DURATION" -P "$STREAMS" $DIR_FLAG -J > temp_iperf.json
    
    # 存入 AI 日志
    log_to_ai "IPERF3 TEST: $TYPE (Streams: $STREAMS)" "temp_iperf.json"
    
    # 解析 JSON 给用户看
    # 获取实际吞吐量 (bps -> Mbps)
    BPS=$(jq -r '.end.sum_received.bits_per_second' temp_iperf.json)
    MBPS=$(echo "scale=2; $BPS / 1000000" | bc)
    
    # 获取重传数 (Sender side retransmits)
    RETR=$(jq -r '.end.sum_sent.retransmits' temp_iperf.json)
    
    # 获取 CPU 利用率
    CPU_HOST=$(jq -r '.end.cpu_utilization_percent.host_total' temp_iperf.json)
    
    # 计算达标率
    RATIO=$(echo "scale=2; ($MBPS / $EXPECTED_BW) * 100" | bc)
    
    # --- 用户输出格式化 ---
    if (( $(echo "$RATIO < 80" | bc -l) )); then
        SPEED_COLOR=$RED
    else
        SPEED_COLOR=$GREEN
    fi
    
    echo -e "       -> 速度: ${SPEED_COLOR}${MBPS} Mbps${NC} (达标率: $RATIO%)"
    
    if [ "$RETR" != "null" ] && [ "$RETR" -gt 10 ]; then
        echo -e "       -> ${RED}警告: TCP重传 $RETR 次 (链路拥塞或物理信号差)${NC}"
    else
        echo -e "       -> TCP重传: $RETR 次 (正常)"
    fi
    
    echo -e "       -> CPU负载: $CPU_HOST% (本机)"
    echo ""
}

# === 阶段 3: 执行具体测试 ===

print_human "${CYAN}[2/4] 测试下载 (Server -> Client)${NC}"
# 1. 单线程下载 (测试窗口/延迟影响)
run_test "下载-单线程" "-R" "1"
# 2. 多线程下载 (测试最大带宽容量)
run_test "下载-多线程(5并发)" "-R" "5"

print_human "${CYAN}[3/4] 测试上传 (Client -> Server)${NC}"
# 3. 多线程上传
run_test "上传-多线程(5并发)" "" "5"

# === 阶段 4: 硬件健康度复查 ===
print_human "${CYAN}[4/4] 验证本地网卡硬件错误...${NC}"
RX_ERR_END=$(cat /sys/class/net/$DEFAULT_IF/statistics/rx_errors)
RX_DROP_END=$(cat /sys/class/net/$DEFAULT_IF/statistics/rx_dropped)
RX_ERR_START=$(cat rx_err_start.tmp)
RX_DROP_START=$(cat rx_drop_start.tmp)

ERR_DIFF=$((RX_ERR_END - RX_ERR_START))
DROP_DIFF=$((RX_DROP_END - RX_DROP_START))

log_to_ai "HARDWARE STATISTICS CHECK" <(echo "RX Errors Delta: $ERR_DIFF, RX Dropped Delta: $DROP_DIFF")

if [ "$ERR_DIFF" -gt 0 ] || [ "$DROP_DIFF" -gt 0 ]; then
    print_human "${RED}!!! 严重警告 !!! 测试期间检测到本地网卡硬件丢包/错误 (Errors: $ERR_DIFF, Drops: $DROP_DIFF)${NC}"
    print_human "${RED}    这通常意味着：网线坏了、接口接触不良或性能不足，而不是运营商问题。${NC}"
else
    print_human "${GREEN}    本地网卡硬件计数正常，无物理层丢包。${NC}"
fi

# 清理临时文件
rm -f temp_sys.txt temp_mtr.txt temp_iperf.json rx_err_start.tmp rx_drop_start.tmp

print_human "--------------------------------------------------"
print_human "${GREEN}测试完成。${NC}"
print_human "1. 简报如上所示。"
print_human "2. 详细日志已生成: ${YELLOW}$AI_LOG${NC}"
print_human "   (请将该文件内容发送给 AI 进行深度诊断)"
