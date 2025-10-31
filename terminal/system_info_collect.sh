#!/bin/bash

################################################################################
# 系统硬件信息采集脚本
# 用途: 收集服务器硬件配置和状态信息
# 作者: 运维工程师
# 日期: 2025-10-30
################################################################################

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# 检测操作系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
    else
        OS="unknown"
    fi
    log_debug "检测到操作系统: $OS"
}

# 安装工具函数
install_tool() {
    local tool=$1
    local package=$2
    
    log_info "正在安装 $tool ($package)..."
    
    case $OS in
        ubuntu|debian)
            sudo apt-get update -qq
            sudo apt-get install -y $package
            ;;
        centos|rhel|rocky|almalinux)
            if command -v dnf &> /dev/null; then
                sudo dnf install -y $package
            else
                sudo yum install -y $package
            fi
            ;;
        fedora)
            sudo dnf install -y $package
            ;;
        arch|manjaro)
            sudo pacman -S --noconfirm $package
            ;;
        *)
            log_error "不支持的操作系统,无法自动安装 $package"
            return 1
            ;;
    esac
    
    if [ $? -eq 0 ]; then
        log_info "$tool 安装成功"
        return 0
    else
        log_error "$tool 安装失败"
        return 1
    fi
}

# 检查并安装必要工具
check_and_install_tools() {
    log_info "开始检查必要工具..."
    
    # 定义工具与包名的映射关系
    declare -A TOOL_PACKAGE_MAP=(
        ["dmidecode"]="dmidecode"
        ["lscpu"]="util-linux"
        ["lsblk"]="util-linux"
        ["smartctl"]="smartmontools"
        ["bc"]="bc"
    )
    
    local missing_tools=()
    
    # 检查每个工具
    for tool in "${!TOOL_PACKAGE_MAP[@]}"; do
        if ! command -v $tool &> /dev/null; then
            log_warn "$tool 未安装"
            missing_tools+=("$tool")
        else
            log_debug "$tool 已安装"
        fi
    done
    
    # 如果有缺失的工具,询问是否安装
    if [ ${#missing_tools[@]} -gt 0 ]; then
        echo ""
        log_warn "检测到以下工具未安装: ${missing_tools[*]}"
        
        # 检查是否有root权限
        if [ "$EUID" -ne 0 ]; then
            log_error "安装工具需要root权限,请使用sudo运行此脚本"
            read -p "是否继续执行(部分信息可能无法采集)? [y/N]: " choice
            if [[ ! $choice =~ ^[Yy]$ ]]; then
                log_info "用户取消执行"
                exit 0
            fi
            return 1
        fi
        
        read -p "是否自动安装缺失的工具? [Y/n]: " choice
        choice=${choice:-Y}
        
        if [[ $choice =~ ^[Yy]$ ]]; then
            for tool in "${missing_tools[@]}"; do
                install_tool "$tool" "${TOOL_PACKAGE_MAP[$tool]}"
            done
        else
            log_warn "跳过工具安装,部分信息可能无法采集"
        fi
    else
        log_info "所有必要工具已安装"
    fi
    
    echo ""
}

# 检查命令是否存在
check_command() {
    if ! command -v $1 &> /dev/null; then
        return 1
    fi
    return 0
}

# 初始化结果数组
declare -A RESULTS

################################################################################
# 1. ServerUUID - 服务器唯一标识
################################################################################
get_server_uuid() {
    log_info "采集 ServerUUID..."
    if [ -f /sys/class/dmi/id/product_uuid ]; then
        RESULTS["ServerUUID"]=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null | tr '[:upper:]' '[:lower:]')
    else
        RESULTS["ServerUUID"]="N/A"
    fi
}

################################################################################
# 2. CPU_Model - CPU型号
################################################################################
get_cpu_model() {
    log_info "采集 CPU_Model..."
    RESULTS["CPU_Model"]=$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || echo "N/A")
}

################################################################################
# 3. CPU_Frequency - CPU最大频率 (Hz)
################################################################################
get_cpu_frequency() {
    log_info "采集 CPU_Frequency..."
    if check_command dmidecode; then
        local freq=$(sudo dmidecode -t processor 2>/dev/null | grep "Max Speed" | head -n 1 | awk '{print $3}')
        # 转换为Hz (假设输入单位为MHz)
        if [[ $freq =~ ^[0-9]+$ ]]; then
            RESULTS["CPU_Frequency"]=$((freq * 1000000))
        else
            RESULTS["CPU_Frequency"]="N/A"
        fi
    else
        RESULTS["CPU_Frequency"]="N/A"
    fi
}

################################################################################
# 4. CPU_Arch - CPU架构
################################################################################
get_cpu_arch() {
    log_info "采集 CPU_Arch..."
    RESULTS["CPU_Arch"]=$(uname -m 2>/dev/null || echo "N/A")
}

################################################################################
# 5. CPU_CoreCount - 每个Socket的核心数
################################################################################
get_cpu_corecount() {
    log_info "采集 CPU_CoreCount..."
    if check_command lscpu; then
        RESULTS["CPU_CoreCount"]=$(lscpu 2>/dev/null | grep "Core(s) per socket:" | awk '{print $4}' || echo "N/A")
    else
        RESULTS["CPU_CoreCount"]="N/A"
    fi
}

################################################################################
# 6. Memory_Model - 内存类型
################################################################################
get_memory_model() {
    log_info "采集 Memory_Model..."
    if check_command dmidecode; then
        RESULTS["Memory_Model"]=$(sudo dmidecode -t memory 2>/dev/null | grep -E "Type: DDR" | head -n 1 | awk '{print $2}' || echo "N/A")
    else
        RESULTS["Memory_Model"]="N/A"
    fi
}

################################################################################
# 7. Memory_Size - 单条内存容量
################################################################################
get_memory_size() {
    log_info "采集 Memory_Size..."
    if check_command dmidecode; then
        RESULTS["Memory_Size"]=$(sudo dmidecode -t memory 2>/dev/null | grep "^\s*Size:" | grep -v "No Module" | head -n 1 | awk '{print $2$3}' || echo "N/A")
    else
        RESULTS["Memory_Size"]="N/A"
    fi
}

################################################################################
# 8. Memory_Count - 内存插槽数量
################################################################################
get_memory_count() {
    log_info "采集 Memory_Count..."
    if check_command dmidecode; then
        RESULTS["Memory_Count"]=$(sudo dmidecode -t memory 2>/dev/null | grep "Number Of Devices:" | awk '{print $4}' || echo "N/A")
    else
        RESULTS["Memory_Count"]="N/A"
    fi
}

################################################################################
# 9-13. GPU相关信息
################################################################################
get_gpu_info() {
    log_info "采集 GPU 相关信息..."
    if check_command nvidia-smi; then
        local nvidia_output=$(nvidia-smi --query-gpu=name,count,memory.total,driver_version --format=csv,noheader 2>/dev/null)
        
        if [ $? -eq 0 ] && [ -n "$nvidia_output" ]; then
            # GPU型号
            RESULTS["GPU_Model"]=$(echo "$nvidia_output" | head -n 1 | awk -F',' '{print $1}' | xargs)
            
            # GPU品牌 (从型号中提取)
            RESULTS["GPU_Brand"]=$(echo "${RESULTS["GPU_Model"]}" | awk '{print $1}')
            
            # GPU数量
            RESULTS["GPU_Count"]=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
            
            # 显存大小 (转换为GiB并向上取整)
            local vram_mib=$(echo "$nvidia_output" | head -n 1 | awk -F',' '{print $3}' | xargs | awk '{print $1}')
            if [[ $vram_mib =~ ^[0-9]+$ ]]; then
                # 将MiB转换为GiB并向上取整 (使用bc的ceiling函数)
                if check_command bc; then
                    local vram_gib=$(echo "scale=0; ($vram_mib + 1023) / 1024" | bc)
                    RESULTS["GPU_VRAMInfo"]="${vram_gib}GiB"
                else
                    # 如果bc不可用,使用bash整数除法(自动向下取整,需要手动向上)
                    local vram_gib=$(( ($vram_mib + 1023) / 1024 ))
                    RESULTS["GPU_VRAMInfo"]="${vram_gib}GiB"
                fi
            else
                RESULTS["GPU_VRAMInfo"]="N/A"
            fi
            
            # 驱动版本
            RESULTS["GPUdriverVersion"]=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1 | xargs)
            
            # CUDA版本
            RESULTS["CUDAVersion"]=$(nvidia-smi 2>/dev/null | grep "CUDA Version" | awk '{print $9}' || echo "N/A")
        else
            RESULTS["GPU_Model"]="N/A"
            RESULTS["GPU_Brand"]="N/A"
            RESULTS["GPU_Count"]="0"
            RESULTS["GPU_VRAMInfo"]="N/A"
            RESULTS["GPUdriverVersion"]="N/A"
            RESULTS["CUDAVersion"]="N/A"
        fi
    else
        log_warn "nvidia-smi 不可用,跳过GPU信息采集"
        RESULTS["GPU_Model"]="N/A"
        RESULTS["GPU_Brand"]="N/A"
        RESULTS["GPU_Count"]="0"
        RESULTS["GPU_VRAMInfo"]="N/A"
        RESULTS["GPUdriverVersion"]="N/A"
        RESULTS["CUDAVersion"]="N/A"
    fi
}

################################################################################
# 14-16. Storage存储信息 (排除loop设备)
################################################################################
get_storage_info() {
    log_info "采集 Storage 相关信息..."
    if check_command lsblk; then
        # 排除loop设备
        local lsblk_output=$(lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,ROTA,MOUNTPOINT -d -n 2>/dev/null | grep -v "^loop")
        
        # 存储型号 (多个用逗号分隔)
        RESULTS["Storage_Model"]=$(echo "$lsblk_output" | awk '{print $3}' | grep -v "^$" | paste -sd "," || echo "N/A")
        
        # 存储容量 (多个用逗号分隔)
        RESULTS["Storage_Capacity"]=$(echo "$lsblk_output" | awk '{print $2}' | paste -sd "," || echo "N/A")
        
        # 存储类型 (根据ROTA字段判断: 0=SSD, 1=HDD)
        local storage_types=""
        while read -r line; do
            local rota=$(echo "$line" | awk '{print $6}')
            local name=$(echo "$line" | awk '{print $1}')
            if [ "$rota" = "0" ]; then
                if [[ "$name" == nvme* ]]; then
                    storage_types="${storage_types}NVME SSD,"
                else
                    storage_types="${storage_types}SATA SSD,"
                fi
            elif [ "$rota" = "1" ]; then
                storage_types="${storage_types}HDD,"
            fi
        done <<< "$lsblk_output"
        RESULTS["Storage_Type"]=$(echo "$storage_types" | sed 's/,$//' || echo "N/A")
    else
        RESULTS["Storage_Model"]="N/A"
        RESULTS["Storage_Capacity"]="N/A"
        RESULTS["Storage_Type"]="N/A"
    fi
}

################################################################################
# 17. Storage_Count - 物理CPU插槽数量
################################################################################
get_storage_count() {
    log_info "采集 Storage_Count (物理CPU数量)..."
    RESULTS["Storage_Count"]=$(grep "physical id" /proc/cpuinfo 2>/dev/null | sort -u | wc -l || echo "N/A")
}

################################################################################
# 18. Storage_UsageHours - 存储使用时长
################################################################################
get_storage_usage_hours() {
    log_info "采集 Storage_UsageHours..."
    if check_command smartctl; then
        # 尝试获取第一个NVMe设备的使用时长
        local nvme_devices=$(ls /dev/nvme?n1 2>/dev/null | head -n 1)
        if [ -n "$nvme_devices" ]; then
            RESULTS["Storage_UsageHours"]=$(sudo smartctl -a $nvme_devices 2>/dev/null | grep -i "power on" | awk '{print $4}' | sed 's/,//g' || echo "N/A")
        else
            RESULTS["Storage_UsageHours"]="N/A"
        fi
    else
        log_warn "smartctl 不可用"
        RESULTS["Storage_UsageHours"]="N/A"
    fi
}

################################################################################
# 19. Uptime - 系统运行时间
################################################################################
get_uptime() {
    log_info "采集 Uptime..."
    local uptime_str=$(uptime 2>/dev/null | awk '{print $3" "$4}' | sed 's/,$//')
    RESULTS["Uptime"]=${uptime_str:-"N/A"}
}

################################################################################
# 主函数
################################################################################
main() {
    echo "========================================"
    echo "    系统硬件信息采集脚本"
    echo "========================================"
    echo ""
    
    # 检测操作系统
    detect_os
    
    # 检查并安装必要工具
    check_and_install_tools
    
    # 检查是否有sudo权限
    if [ "$EUID" -ne 0 ]; then 
        log_warn "部分命令需要root权限,建议使用sudo运行此脚本以获取完整信息"
        echo ""
    fi
    
    # 执行所有采集函数
    get_server_uuid
    get_cpu_model
    get_cpu_frequency
    get_cpu_arch
    get_cpu_corecount
    get_memory_model
    get_memory_size
    get_memory_count
    get_gpu_info
    get_storage_info
    get_storage_count
    get_storage_usage_hours
    get_uptime
    
    echo ""
    echo "========================================"
    echo "           采集结果"
    echo "========================================"
    echo ""
    
    # 输出结果
    printf "%-25s : %s\n" "ServerUUID" "${RESULTS["ServerUUID"]}"
    printf "%-25s : %s\n" "CPU_Model" "${RESULTS["CPU_Model"]}"
    printf "%-25s : %s\n" "CPU_Frequency" "${RESULTS["CPU_Frequency"]}"
    printf "%-25s : %s\n" "CPU_Arch" "${RESULTS["CPU_Arch"]}"
    printf "%-25s : %s\n" "CPU_CoreCount" "${RESULTS["CPU_CoreCount"]}"
    printf "%-25s : %s\n" "Memory_Model" "${RESULTS["Memory_Model"]}"  
    printf "%-25s : %s\n" "Memory_Size" "${RESULTS["Memory_Size"]}"
    printf "%-25s : %s\n" "Memory_Count" "${RESULTS["Memory_Count"]}"
    printf "%-25s : %s\n" "GPU_Model" "${RESULTS["GPU_Model"]}"
    printf "%-25s : %s\n" "GPU_Brand" "${RESULTS["GPU_Brand"]}"
    printf "%-25s : %s\n" "GPU_Count" "${RESULTS["GPU_Count"]}"
    printf "%-25s : %s\n" "GPU_VRAMInfo" "${RESULTS["GPU_VRAMInfo"]}"
    printf "%-25s : %s\n" "CUDAVersion" "${RESULTS["CUDAVersion"]}"
    printf "%-25s : %s\n" "GPUdriverVersion" "${RESULTS["GPUdriverVersion"]}"
    printf "%-25s : %s\n" "Storage_Model" "${RESULTS["Storage_Model"]}"
    printf "%-25s : %s\n" "Storage_Capacity" "${RESULTS["Storage_Capacity"]}"
    printf "%-25s : %s\n" "Storage_Type" "${RESULTS["Storage_Type"]}"
    printf "%-25s : %s\n" "Storage_Count" "${RESULTS["Storage_Count"]}"
    printf "%-25s : %s\n" "Storage_UsageHours" "${RESULTS["Storage_UsageHours"]}"
    printf "%-25s : %s\n" "Uptime" "${RESULTS["Uptime"]}"
    
    echo ""
    echo "========================================"
    echo "           采集完成"
    echo "========================================"
}

# 执行主函数
main
