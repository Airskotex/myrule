#!/bin/bash

# ==============================================================================
#
# NVIDIA CUDA Toolkit 全自动静默安装脚本
#
# 功能:
#   1. 自动检测系统信息。
#   2. 从 NVIDIA 官网获取所有可用的 CUDA Toolkit 版本。
#   3. 提供一个菜单供用户选择要安装的版本。
#   4. 下载选择的版本并以静默模式自动安装。
#      - 默认只安装 Toolkit 和 Samples，不安装驱动以避免冲突。
#   5. 自动将新安装的 CUDA 环境变量添加到 ~/.bashrc。
#
# 使用方法:
#   1. 保存此脚本为 install_cuda.sh
#   2. 赋予执行权限: chmod +x install_cuda.sh  
#   3. 运行脚本: ./install_cuda.sh   
#
# ==============================================================================
# --- 辅助函数 ---
log_info() {
	echo -e "${GREEN}[INFO] $1${NC}"
}

log_warn() {
	echo -e "${YELLOW}[WARN] $1${NC}"
}

log_error() {
	echo -e "${RED}[ERROR] $1${NC}"
}

log_debug() {
	echo -e "${BLUE}[DEBUG] $1${NC}"
}

log_step() {
	echo -e "${CYAN}[STEP] $1${NC}"
}
# --- 设置清理陷阱 ---
cleanup() {
	local exit_code=$?
	log_info "正在清理脚本文件..."
	
	# 删除脚本自身
	if [[ -f "$SCRIPT_PATH" ]]; then  
		rm -f "$SCRIPT_PATH" 2>/dev/null || log_warn "无法删除脚本文件 $SCRIPT_PATH"
		log_info "脚本文件已删除: $SCRIPT_NAME"
	fi
	
	exit $exit_code
}

# 设置陷阱：脚本退出时执行清理
trap cleanup EXIT

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 脚本初始化 ---
set -e # 如果任何命令失败，则立即退出

echo -e "${BLUE}=====================================================${NC}"
echo -e "${BLUE}    NVIDIA CUDA Toolkit 全自动静默安装脚本         ${NC}"
echo -e "${BLUE}=====================================================${NC}"
echo

# --- 1. 依赖与权限检查 ---
if ! command -v wget &> /dev/null; then
    echo -e "${RED}错误: 'wget' 未安装。请先安装 wget。${NC}"
    exit 1  
fi
#if [[ $EUID -eq 0 ]]; then    
#   echo -e "${RED}错误：请不要使用 root 用户或 'sudo' 来运行此脚本。${NC}"
#   echo "脚本会在需要时自动请求 sudo 密码。"
#   exit 1
#fi

# --- 2. 判断系统版本 ---
echo -e "${YELLOW}--- 正在检测系统信息 ---${NC}"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
    VER=$VERSION_ID
    echo -e "操作系统: ${GREEN}${OS} ${VER}${NC}"
else
    echo -e "${RED}无法确定操作系统版本。${NC}"
    exit 1
fi
echo

# --- 3. 获取所有可用的CUDA版本 ---
echo -e "${YELLOW}--- 正在从 NVIDIA 官网获取可用的 CUDA 版本列表... ---${NC}"
CUDA_ARCHIVE_URL="https://developer.nvidia.com/cuda-toolkit-archive"
mapfile -t CUDA_VERSIONS < <(
    wget -qO- https://developer.nvidia.com/cuda-toolkit-archive | \
    grep -oE "CUDA Toolkit [0-9]+\.[0-9]+(\.[0-9]+)?" | \
    sed 's/CUDA Toolkit //' | \
    sort -rV | uniq | \
    while read version; do
        driver_version=$(wget -qO- "https://docs.nvidia.com/cuda/archive/${version}/cuda-toolkit-release-notes/index.html" 2>/dev/null | \
            grep -A2 "NVIDIA Linux Driver" | \
            grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)
        if [[ -n "$driver_version" ]]; then
            echo "cuda_${version}_${driver_version}_linux.run"
        else
            echo "cuda_${version}_linux.run"
        fi
    done
)

if [ ${#CUDA_VERSIONS[@]} -eq 0 ]; then
    echo -e "${RED}错误: 无法从 NVIDIA 官网获取 CUDA 版本列表。${NC}"
    exit 1
fi
echo -e "${GREEN}成功获取版本列表！${NC}"
echo

# --- 4. 提供选择菜单 ---
echo -e "${YELLOW}--- 请选择您要安装的 CUDA Toolkit 版本 ---${NC}"
PS3="请输入选项编号: "
select FILENAME in "${CUDA_VERSIONS[@]}"; do
    if [[ -n "$FILENAME" ]]; then
        echo -e "您选择了: ${GREEN}${FILENAME}${NC}"
        break
    else
        echo -e "${RED}无效选项，请重新输入。${NC}"
    fi
done
echo

# --- 5. 下载并准备安装 ---
CUDA_MAJOR_VERSION=$(echo "$FILENAME" | cut -d'_' -f2)
DOWNLOAD_URL="https://developer.download.nvidia.com/compute/cuda/${CUDA_MAJOR_VERSION}/local_installers/${FILENAME}"

if [ -f "./${FILENAME}" ]; then
    echo -e "${YELLOW}文件 '${FILENAME}' 已存在。跳过下载。${NC}"
else
    echo -e "${YELLOW}--- 开始下载 (这可能需要一些时间)... ---${NC}"
    wget --progress=bar:force "${DOWNLOAD_URL}"
    echo -e "${GREEN}下载完成！${NC}"
fi
echo

echo -e "${YELLOW}--- 添加执行权限 ---${NC}"
chmod +x "${FILENAME}"
echo -e "${GREEN}权限添加成功！${NC}"
echo

# --- 6. 执行静默安装 ---
# 从文件名中提取版本号，例如 "cuda_12.5.1_..." -> "12.5"
CUDA_INSTALL_VERSION=$(echo "$CUDA_MAJOR_VERSION" | awk -F. '{print $1"."$2}')
INSTALL_PATH="/usr/local/cuda-${CUDA_INSTALL_VERSION}"

echo -e "${RED}===================== 最终确认 =======================${NC}"
echo -e "${YELLOW}脚本即将以静默模式进行安装，这将不会有任何交互提示。${NC}"
echo
echo -e "将要安装的版本: ${GREEN}${CUDA_MAJOR_VERSION}${NC}"
echo -e "预计安装路径:   ${GREEN}${INSTALL_PATH}${NC}"
echo -e "安装的组件:     ${GREEN}Toolkit, Samples (无驱动程序)${NC}"
echo -e "${YELLOW}环境变量将被自动添加到: ${GREEN}~/.bashrc${NC}"
echo -e "${RED}========================================================${NC}"
echo

read -p "您确定要继续吗？ (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[yY]([eE][sS])?$ ]]; then
    echo -e "${YELLOW}安装已取消。${NC}"
    exit 0
fi

echo -e "${GREEN}开始静默安装，请稍候...${NC}"
# 使用 sudo 权限执行静默安装
# --silent: 完整静默模式
# --toolkit: 安装CUDA Toolkit
# --samples: 安装示例代码
# --no-driver: 明确不安装驱动程序
# --installpath: 指定安装目录
sudo "./${FILENAME}" --silent --toolkit --samples --no-driver --installpath="${INSTALL_PATH}"
INSTALL_EXIT_CODE=$?

if [ $INSTALL_EXIT_CODE -ne 0 ]; then
    echo -e "${RED}NVIDIA 安装程序执行失败 (退出码: $INSTALL_EXIT_CODE)。请检查日志。${NC}"
    exit 1
fi

echo -e "${GREEN}CUDA Toolkit ${CUDA_MAJOR_VERSION} 静默安装成功！${NC}"
echo

# --- 7. 自动配置环境变量 ---
echo -e "${YELLOW}--- 正在配置环境变量... ---${NC}"
BASHRC_FILE="$HOME/.bashrc"
SYMLINK_PATH="/usr/local/cuda"

# 创建或更新 /usr/local/cuda 符号链接，指向新安装的版本
echo "正在创建符号链接 ${SYMLINK_PATH} -> ${INSTALL_PATH}"
sudo ln -sfn "${INSTALL_PATH}" "${SYMLINK_PATH}"

# 要添加的配置行
PATH_VAR="export PATH=${SYMLINK_PATH}/bin\${PATH:+:\${PATH}}"
LD_VAR="export LD_LIBRARY_PATH=${SYMLINK_PATH}/lib64\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"

# 检查并添加 PATH
if grep -q "export PATH=${SYMLINK_PATH}/bin" "$BASHRC_FILE"; then
    echo "PATH 变量已存在于 ${BASHRC_FILE}，无需更改。"
else
    echo "Adding PATH to ${BASHRC_FILE}"
    echo -e "\n# Added by CUDA installer script" >> "$BASHRC_FILE"
    echo "${PATH_VAR}" >> "$BASHRC_FILE"
fi

# 检查并添加 LD_LIBRARY_PATH
if grep -q "export LD_LIBRARY_PATH=${SYMLINK_PATH}/lib64" "$BASHRC_FILE"; then
    echo "LD_LIBRARY_PATH 变量已存在于 ${BASHRC_FILE}，无需更改。"
else
    echo "Adding LD_LIBRARY_PATH to ${BASHRC_FILE}"
    # 如果是第一次添加，也加上注释
    if ! grep -q "# Added by CUDA installer script" "$BASHRC_FILE"; then
        echo -e "\n# Added by CUDA installer script" >> "$BASHRC_FILE"
    fi
    echo "${LD_VAR}" >> "$BASHRC_FILE"
fi

echo -e "${GREEN}环境变量配置完成！${NC}"
echo

# --- 8. 最终总结 ---
echo -e "${BLUE}=====================================================${NC}"
echo -e "${GREEN}                所有操作已成功完成！               ${NC}"
echo -e "${BLUE}=====================================================${NC}"
echo
echo -e "文件 ${YELLOW}${BASHRC_FILE}${NC} 已被更新。"
echo -e "${RED}请务必执行以下命令，或重新打开一个新的终端来使配置生效:${NC}"
echo
echo -e "   ${GREEN}source ~/.bashrc${NC}"
echo
echo "然后，您可以通过运行以下命令来验证 CUDA 是否安装成功:"
echo -e "   ${GREEN}nvcc -V${NC}"
echo

# 恢复正常退出
set +e
