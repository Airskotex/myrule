#!/bin/bash

# ==============================================================================
#
# NVIDIA CUDA Toolkit 全自动安装脚本 (支持自动禁用 Nouveau 并断点续传)
#
# 功能:
#   1. 自动检测系统信息。
#   2. 并行获取 NVIDIA 官网所有 CUDA 版本。
#   3. 用户菜单选择版本及是否安装驱动。
#   4. [核心功能] 自动检测 Nouveau 驱动：
#      - 如存在，自动写入黑名单，生成状态文件，并提示重启。
#      - 重启后再次运行脚本，会自动读取状态，跳过选单，继续安装。
#   5. 静默安装 CUDA 和 驱动。
#   6. 配置环境变量。
#
# ==============================================================================

# --- 全局配置 ---
STATE_FILE="./.cuda_install_state.conf" # 用于存储重启前状态的文件
NVIDIA_BLACKLIST_FILE="/etc/modprobe.d/blacklist-nouveau.conf"

# --- 辅助函数 ---
log_info() { echo -e "${GREEN}[INFO] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; }
log_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

set -e

echo -e "${BLUE}=====================================================${NC}"
echo -e "${BLUE}    NVIDIA CUDA Toolkit 智能安装脚本 (含驱动处理)   ${NC}"
echo -e "${BLUE}=====================================================${NC}"
echo

# --- 1. 依赖与权限检查 ---
if ! command -v wget &> /dev/null; then
    echo -e "${RED}错误: 'wget' 未安装。请先安装: sudo apt install wget 或 sudo yum install wget${NC}"
    exit 1
fi

# --- 2. 判断系统版本 ---
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
    VER=$VERSION_ID
else
    echo -e "${RED}无法确定操作系统版本。${NC}"
    exit 1
fi

# ==============================================================================
# 核心逻辑：断点续传与状态检测
# ==============================================================================

# 函数：禁用 Nouveau 并更新 Initramfs
disable_nouveau_and_reboot() {
    local filename=$1
    local driver_choice=$2
    
    log_warn "检测到 Nouveau 驱动正在运行，必须将其禁用并重启系统才能安装 NVIDIA 驱动。"
    echo -e "${YELLOW}正在创建黑名单文件: ${NVIDIA_BLACKLIST_FILE}...${NC}"

    # 1. 写入黑名单
    sudo bash -c "cat > ${NVIDIA_BLACKLIST_FILE}" <<EOF
blacklist nouveau
options nouveau modeset=0
EOF

    # 2. 更新内核 Initramfs (区分 OS)
    echo -e "${YELLOW}正在重新生成内核引导镜像 (initramfs)... 这可能需要一分钟...${NC}"
    if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
        sudo update-initramfs -u
    elif [[ "$ID" == "centos" || "$ID" == "rhel" || "$ID" == "fedora" || "$ID" == "ol" ]]; then
        sudo dracut --force
    else
        log_warn "未知的操作系统类型，尝试通用的 update-initramfs..."
        sudo update-initramfs -u || log_error "无法更新 initramfs，请手动执行！"
    fi

    # 3. 保存当前状态到文件
    echo -e "${YELLOW}正在保存当前安装状态...${NC}"
    cat > "${STATE_FILE}" <<EOF
# CUDA Install State Saved
SAVED_FILENAME="${filename}"
SAVED_DRIVER_CHOICE="${driver_choice}"
EOF

    log_success "配置已完成！"
    echo -e "${RED}======================================================${NC}"
    echo -e "${RED}系统必须立即重启以应用更改。${NC}"
    echo -e "${RED}重启后，请重新运行此脚本，它将自动检测进度并继续安装。${NC}"
    echo -e "${RED}======================================================${NC}"
    
    read -p "是否立即重启? (y/N): " REBOOT_NOW
    if [[ "$REBOOT_NOW" =~ ^[yY] ]]; then
        sudo reboot
    else
        echo "请稍后手动重启，并在重启后再次运行 ./install_cuda.sh"
        exit 0
    fi
}

# 变量初始化
FILENAME=""
CONFIRM_DRIVER=""

# --- 检查是否存在状态文件 (意味着这是重启后的运行) ---
if [ -f "$STATE_FILE" ]; then
    echo -e "${GREEN}检测到上次未完成的安装状态文件。${NC}"
    source "$STATE_FILE"
    
    FILENAME="$SAVED_FILENAME"
    CONFIRM_DRIVER="$SAVED_DRIVER_CHOICE"
    
    echo -e "恢复的目标版本: ${GREEN}${FILENAME}${NC}"
    echo -e "恢复的驱动选项: ${GREEN}${CONFIRM_DRIVER}${NC}"
    
    # 再次检查 Nouveau 是否真的没了
    if lsmod | grep -q nouveau; then
        log_error "Nouveau 驱动仍然存在！可能重启未成功或配置未生效。"
        echo "请检查 ${NVIDIA_BLACKLIST_FILE} 是否正确。"
        exit 1
    else
        log_success "Nouveau 已成功禁用。准备继续安装。"
    fi
    
else
    # ==============================================================================
    # 正常流程：如果没有状态文件，则执行正常的选择菜单
    # ==============================================================================

    # --- 3. 获取所有可用的CUDA版本 ---
    echo -e "${YELLOW}--- 正在从 NVIDIA 官网获取可用的 CUDA 版本列表... ---${NC}"
    CUDA_ARCHIVE_URL="https://developer.nvidia.com/cuda-toolkit-archive"

    # (优化版的并行获取逻辑保持不变)
    mapfile -t temp_versions < <(
        wget -qO- "$CUDA_ARCHIVE_URL" | \
        grep -oE "CUDA Toolkit [0-9]+\.[0-9]+(\.[0-9]+)?" | \
        sed 's/CUDA Toolkit //' | \
        uniq | \
        while read -r version; do
            (
                driver_version=$(wget -qO- "https://docs.nvidia.com/cuda/archive/${version}/cuda-toolkit-release-notes/index.html" 2>/dev/null | \
                    grep -A2 "NVIDIA Linux Driver" | \
                    grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)
                
                if [[ -n "$driver_version" ]]; then
                    echo -e "${version}\tcuda_${version}_${driver_version}_linux.run"
                else
                    echo -e "${version}\tcuda_${version}_linux.run"
                fi
            ) & 
        done
        wait
    )

    mapfile -t CUDA_VERSIONS < <(
        printf "%s\n" "${temp_versions[@]}" | \
        sort -rV -k1,1 -t $'\t' | \
        cut -f2- -d $'\t'
    )

    if [ ${#CUDA_VERSIONS[@]} -eq 0 ]; then
        echo -e "${RED}错误: 无法从 NVIDIA 官网获取版本列表。${NC}"
        exit 1
    fi

    # --- 4. 提供选择菜单 ---
    echo -e "${YELLOW}--- 请选择您要安装的 CUDA Toolkit 版本 ---${NC}"
    PS3="请输入选项编号: "
    select FILE_SELECT in "${CUDA_VERSIONS[@]}"; do
        if [[ -n "$FILE_SELECT" ]]; then
            FILENAME="$FILE_SELECT"
            echo -e "您选择了: ${GREEN}${FILENAME}${NC}" 
            break
        else
            echo -e "${RED}无效选项。${NC}"
        fi
    done
    echo

    # --- 5.1. 询问是否安装驱动 ---
    echo -e "${YELLOW}--- 是否安装 NVIDIA 驱动程序? ---${NC}"
    echo -e "注意：安装驱动通常需要禁用 Nouveau 并重启。"
    read -p "是否安装驱动? (y/N): " DRIVER_INPUT
    
    if [[ "$DRIVER_INPUT" =~ ^[yY] ]]; then
        CONFIRM_DRIVER="yes"
    else
        CONFIRM_DRIVER="no"
    fi

    # --- 检查 Nouveau 状态 (仅当用户选择安装驱动时) ---
    if [[ "$CONFIRM_DRIVER" == "yes" ]]; then
        if lsmod | grep -q nouveau; then
            # 触发禁用逻辑，并退出脚本等待重启
            disable_nouveau_and_reboot "$FILENAME" "$CONFIRM_DRIVER"
        else
            log_info "Nouveau 未加载或已禁用。可以直接安装。"
        fi
    fi
fi

# ==============================================================================
# 安装执行阶段 (无论是首次运行还是重启后恢复，都会汇聚到这里)
# ==============================================================================

CUDA_MAJOR_VERSION=$(echo "$FILENAME" | cut -d'_' -f2)
DOWNLOAD_URL="https://developer.download.nvidia.com/compute/cuda/${CUDA_MAJOR_VERSION}/local_installers/${FILENAME}"

# --- 下载 ---
if [ -f "./${FILENAME}" ]; then
    echo -e "${YELLOW}文件已存在，跳过下载。${NC}"
else
    echo -e "${YELLOW}--- 开始下载... ---${NC}"
    wget --progress=bar:force "${DOWNLOAD_URL}"
fi
chmod +x "${FILENAME}"

# --- 准备参数 ---
DRIVER_ARG=""
DRIVER_MSG="无驱动"
if [[ "$CONFIRM_DRIVER" == "yes" ]]; then
    DRIVER_ARG="--driver"
    DRIVER_MSG="包含驱动"
fi

CUDA_INSTALL_VERSION=$(echo "$CUDA_MAJOR_VERSION" | awk -F. '{print $1"."$2}') 
INSTALL_PATH="/usr/local/cuda-${CUDA_INSTALL_VERSION}"

echo -e "${YELLOW}--- 开始静默安装 (${DRIVER_MSG})... ---${NC}"
echo -e "这可能需要几分钟，请不要关闭终端..."

# 执行安装
sudo "./${FILENAME}" --silent --toolkit --samples ${DRIVER_ARG} --installpath="${INSTALL_PATH}"
INSTALL_EXIT_CODE=$?

if [ $INSTALL_EXIT_CODE -ne 0 ]; then
    echo -e "${RED}安装失败 (Code: $INSTALL_EXIT_CODE)。请查看 /var/log/cuda-installer.log${NC}"
    # 注意：如果失败了，我们不删除状态文件，以便用户排查后重新运行
    exit 1
fi

echo -e "${GREEN}CUDA 安装成功！${NC}"

# --- 7. 环境变量配置 (保持原逻辑) ---
BASHRC_FILE="$HOME/.bashrc"
SYMLINK_PATH="/usr/local/cuda"

sudo ln -sfn "${INSTALL_PATH}" "${SYMLINK_PATH}"

PATH_VAR="export PATH=${SYMLINK_PATH}/bin\${PATH:+:\${PATH}}"
LD_VAR="export LD_LIBRARY_PATH=${SYMLINK_PATH}/lib64\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"

if ! grep -q "export PATH=${SYMLINK_PATH}/bin" "$BASHRC_FILE"; then
    echo -e "\n# Added by CUDA installer script" >> "$BASHRC_FILE"
    echo "${PATH_VAR}" >> "$BASHRC_FILE"
fi

if ! grep -q "export LD_LIBRARY_PATH=${SYMLINK_PATH}/lib64" "$BASHRC_FILE"; then
    echo "${LD_VAR}" >> "$BASHRC_FILE"
fi

# --- 8. 清理与完成 ---
# 安装成功，删除状态文件
if [ -f "$STATE_FILE" ]; then
    rm "$STATE_FILE"
    log_debug "已清理安装状态文件。"
fi

echo -e "${BLUE}=====================================================${NC}"
echo -e "${GREEN}                所有操作已成功完成！               ${NC}"
echo -e "${BLUE}=====================================================${NC}"
echo -e "请执行: ${GREEN}source ~/.bashrc${NC} 并运行 ${GREEN}nvcc -V${NC} 验证。"
