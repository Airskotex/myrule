#!/bin/bash

# ==============================================================================
#
# NVIDIA CUDA Toolkit 全自动安装脚本 (支持自动禁用 Nouveau 并断点续传)
#
# 功能:
#   1. 自动检测系统信息。
#   2. 获取 NVIDIA 官网所有 CUDA 版本。
#   3. 先选择 CUDA 版本，再选择 NVIDIA Driver 版本。
#   4. [核心功能] 自动检测 Nouveau 驱动：
#      - 如存在，自动写入黑名单，生成状态文件，并提示重启。
#      - 重启后再次运行脚本，会自动读取状态，跳过选单，继续安装。
#   5. 静默安装 CUDA Toolkit 和可选的 NVIDIA Driver。
#   6. 配置环境变量。
#
# ==============================================================================

# --- 全局配置 ---
STATE_FILE="./.cuda_install_state.conf" # 用于存储重启前状态的文件
NVIDIA_BLACKLIST_FILE="/etc/modprobe.d/blacklist-nouveau.conf"
CUDA_ARCHIVE_URL="https://developer.nvidia.com/cuda-toolkit-archive"
NVIDIA_DRIVER_BASE_URL="https://download.nvidia.com/XFree86"
MIN_CUDA_TOOLKIT_VERSION="11.0" # 低于该版本的 CUDA Toolkit 默认视为过旧不显示；设为空则显示全部

# --- 辅助函数 ---
log_info() { echo -e "${GREEN}[INFO] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; }
log_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
log_debug() { echo -e "${BLUE}[DEBUG] $1${NC}"; }

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

# 函数：获取当前架构对应的 NVIDIA Driver 目录和安装器文件名前缀
detect_nvidia_driver_arch() {
    case "$(uname -m)" in
        x86_64|amd64)
            NVIDIA_DRIVER_DIR="Linux-x86_64"
            NVIDIA_DRIVER_FILE_ARCH="x86_64"
            ;;
        aarch64|arm64)
            NVIDIA_DRIVER_DIR="Linux-aarch64"
            NVIDIA_DRIVER_FILE_ARCH="aarch64"
            ;;
        ppc64le)
            NVIDIA_DRIVER_DIR="Linux-ppc64le"
            NVIDIA_DRIVER_FILE_ARCH="ppc64le"
            ;;
        *)
            log_warn "未知 CPU 架构 $(uname -m)，将按 Linux x86_64 驱动归档尝试。"
            NVIDIA_DRIVER_DIR="Linux-x86_64"
            NVIDIA_DRIVER_FILE_ARCH="x86_64"
            ;;
    esac
}

# 函数：获取 CUDA Toolkit 版本，过滤特别老旧的版本
fetch_cuda_versions() {
    wget -qO- "$CUDA_ARCHIVE_URL" | \
        grep -oE "CUDA Toolkit [0-9]+\.[0-9]+(\.[0-9]+)?" | \
        sed 's/CUDA Toolkit //' | \
        sort -rV | \
        awk '!seen[$0]++' | \
        while read -r version; do
            if version_ge "$version" "$MIN_CUDA_TOOLKIT_VERSION"; then
                echo "$version"
            fi
        done
}

# 函数：比较版本号，判断 candidate 是否不低于 minimum
version_ge() {
    local candidate=$1
    local minimum=$2
    local first

    [[ -z "$minimum" ]] && return 0
    first=$(printf "%s\n%s\n" "$minimum" "$candidate" | sort -V | head -n1)
    [[ "$first" == "$minimum" ]]
}

# 函数：判断 release notes 表格行是否匹配当前 CUDA 版本
row_matches_cuda_version() {
    local row_text=$1
    local cuda_version=$2
    local cuda_major_minor
    local cuda_major

    cuda_major_minor=$(echo "$cuda_version" | awk -F. '{print $1"."$2}')
    cuda_major=$(echo "$cuda_version" | awk -F. '{print $1}')

    [[ "$row_text" == *"CUDA ${cuda_version}"* ]] && return 0
    [[ "$row_text" == *"CUDA ${cuda_major_minor}.x"* ]] && return 0
    [[ "$row_text" == *"CUDA ${cuda_major_minor} "* ]] && return 0
    [[ "$row_text" == *"CUDA ${cuda_major_minor}("* ]] && return 0
    [[ "$row_text" == *"CUDA ${cuda_major_minor}."* ]] && return 0
    [[ "$row_text" == *"CUDA ${cuda_major}.x"* ]] && return 0
    return 1
}

# 函数：从 HTML 表格片段中提取匹配 CUDA 的第一个 Linux Driver 版本
extract_driver_version_from_rows() {
    local html=$1
    local cuda_version=$2
    local row
    local row_text
    local driver_version

    while IFS= read -r row; do
        row_text=$(printf "%s" "$row" | \
            sed -E 's/<[^>]+>/ /g; s/&gt;=/>=/g; s/&nbsp;/ /g; s/[[:space:]]+/ /g')

        if row_matches_cuda_version "$row_text" "$cuda_version"; then
            driver_version=$(printf "%s\n" "$row_text" | \
                grep -oE ">= ?[0-9]+\.[0-9]+(\.[0-9]+)?" | \
                head -1 | \
                grep -oE "[0-9]+\.[0-9]+(\.[0-9]+)?" || true)

            if [[ -n "$driver_version" ]]; then
                echo "$driver_version"
                return 0
            fi
        fi
    done < <(printf "%s" "$html" | tr '\n' ' ' | sed 's#</tr>#</tr>\n#g')
}

# 函数：获取某个 CUDA 版本要求的最低 NVIDIA Linux Driver 版本
get_minimum_driver_version() {
    local cuda_version=$1
    local release_notes
    local minimum_section
    local driver_version

    release_notes=$(wget -qO- "https://docs.nvidia.com/cuda/archive/${cuda_version}/cuda-toolkit-release-notes/index.html" 2>/dev/null || true)
    [[ -z "$release_notes" ]] && return 0

    minimum_section=$(printf "%s" "$release_notes" | sed -n '/Minimum Required Driver Version/,/Corresponding Driver Versions/p')
    driver_version=$(extract_driver_version_from_rows "$minimum_section" "$cuda_version")

    if [[ -z "$driver_version" ]]; then
        # 旧版 CUDA release notes 没有单独的 minimum 表，退回到 compatible/corresponding driver 表。
        driver_version=$(extract_driver_version_from_rows "$release_notes" "$cuda_version")
    fi

    echo "$driver_version"
}

# 函数：获取某个 CUDA 版本随官方安装包发布的 NVIDIA Linux Driver 版本
get_recommended_driver_version() {
    local cuda_version=$1

    wget -qO- "https://docs.nvidia.com/cuda/archive/${cuda_version}/cuda-toolkit-release-notes/index.html" 2>/dev/null | \
        grep -A4 -i "NVIDIA Linux Driver" | \
        grep -oE "[0-9]+\.[0-9]+(\.[0-9]+)?" | \
        head -1 || true
}

# 函数：获取 CUDA Toolkit runfile 文件名
get_cuda_runfile() {
    local cuda_version=$1
    local recommended_driver=$2
    local escaped_cuda_version="${cuda_version//./\\.}"
    local archive_slug="cuda-${cuda_version//./-}-download-archive"
    local filename

    filename=$(wget -qO- "https://developer.nvidia.com/${archive_slug}" 2>/dev/null | \
        grep -oE "cuda_${escaped_cuda_version}(_[0-9]+\.[0-9]+(\.[0-9]+)?)?_linux\.run" | \
        head -1 || true)

    if [[ -n "$filename" ]]; then
        echo "$filename"
    elif [[ -n "$recommended_driver" ]]; then
        echo "cuda_${cuda_version}_${recommended_driver}_linux.run"
    else
        echo "cuda_${cuda_version}_linux.run"
    fi
}

# 函数：尽可能从 NVIDIA 驱动归档目录获取所有版本
fetch_nvidia_driver_versions() {
    local index_url="${NVIDIA_DRIVER_BASE_URL}/${NVIDIA_DRIVER_DIR}/"

    wget -qO- "$index_url" 2>/dev/null | \
        grep -oE "href=['\"][0-9][0-9A-Za-z._+-]*/['\"]" | \
        sed -E "s#href=['\"]##; s#/['\"]##" | \
        sort -rV | \
        awk '!seen[$0]++'
}

# 函数：只保留不低于 CUDA 最低要求的 NVIDIA Driver 版本
filter_compatible_driver_versions() {
    local minimum_driver=$1
    shift

    for driver_version in "$@"; do
        if version_ge "$driver_version" "$minimum_driver"; then
            echo "$driver_version"
        fi
    done
}

# 函数：解析某个驱动版本实际对应的独立 runfile 文件名
resolve_nvidia_driver_file() {
    local driver_version=$1
    local driver_url="${NVIDIA_DRIVER_BASE_URL}/${NVIDIA_DRIVER_DIR}/${driver_version}/"
    local driver_file

    driver_file=$(wget -qO- "$driver_url" 2>/dev/null | \
        grep -oE "NVIDIA-Linux-${NVIDIA_DRIVER_FILE_ARCH}-${driver_version}[^'\"<> ]*\.run" | \
        head -1 || true)

    if [[ -n "$driver_file" ]]; then
        echo "$driver_file"
    else
        echo "NVIDIA-Linux-${NVIDIA_DRIVER_FILE_ARCH}-${driver_version}.run"
    fi
}

# 函数：禁用 Nouveau 并更新 Initramfs
disable_nouveau_and_reboot() {
    local filename=$1
    local driver_choice=$2
    local cuda_version=$3
    local driver_version=$4
    local driver_file=$5
    local driver_url=$6
    local recommended_driver=$7
    local driver_source=$8
    local minimum_driver=$9
    
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
SAVED_CUDA_VERSION="${cuda_version}"
SAVED_FILENAME="${filename}"
SAVED_DRIVER_CHOICE="${driver_choice}"
SAVED_DRIVER_VERSION="${driver_version}"
SAVED_DRIVER_FILE="${driver_file}"
SAVED_DRIVER_URL="${driver_url}"
SAVED_RECOMMENDED_DRIVER="${recommended_driver}"
SAVED_DRIVER_SOURCE="${driver_source}"
SAVED_MINIMUM_DRIVER="${minimum_driver}"
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
CUDA_VERSION=""
FILENAME=""
CONFIRM_DRIVER=""
RECOMMENDED_DRIVER_VERSION=""
MINIMUM_DRIVER_VERSION=""
SELECTED_DRIVER_VERSION=""
SELECTED_DRIVER_FILE=""
SELECTED_DRIVER_URL=""
SELECTED_DRIVER_SOURCE=""

detect_nvidia_driver_arch

# --- 检查是否存在状态文件 (意味着这是重启后的运行) ---
if [ -f "$STATE_FILE" ]; then
    echo -e "${GREEN}检测到上次未完成的安装状态文件。${NC}"
    source "$STATE_FILE"
    
    FILENAME="$SAVED_FILENAME"
    CONFIRM_DRIVER="$SAVED_DRIVER_CHOICE"
    CUDA_VERSION="${SAVED_CUDA_VERSION:-$(echo "$FILENAME" | cut -d'_' -f2)}"
    SELECTED_DRIVER_VERSION="${SAVED_DRIVER_VERSION:-}"
    SELECTED_DRIVER_FILE="${SAVED_DRIVER_FILE:-}"
    SELECTED_DRIVER_URL="${SAVED_DRIVER_URL:-}"
    RECOMMENDED_DRIVER_VERSION="${SAVED_RECOMMENDED_DRIVER:-}"
    MINIMUM_DRIVER_VERSION="${SAVED_MINIMUM_DRIVER:-}"
    SELECTED_DRIVER_SOURCE="${SAVED_DRIVER_SOURCE:-}"

    if [[ "$CONFIRM_DRIVER" == "yes" && -z "$SELECTED_DRIVER_VERSION" ]]; then
        LEGACY_DRIVER_VERSION=$(echo "$FILENAME" | awk -F_ '{print $3}')
        if [[ "$LEGACY_DRIVER_VERSION" =~ ^[0-9] ]]; then
            SELECTED_DRIVER_VERSION="$LEGACY_DRIVER_VERSION"
            SELECTED_DRIVER_SOURCE="cuda"
            log_warn "检测到旧格式状态文件，已从 CUDA 安装器文件名恢复驱动版本 ${SELECTED_DRIVER_VERSION}。"
        else
            log_warn "旧格式状态文件缺少驱动版本，恢复为仅安装 CUDA Toolkit。"
            CONFIRM_DRIVER="no"
        fi
    fi

    if [[ "$CONFIRM_DRIVER" == "yes" && -z "$SELECTED_DRIVER_SOURCE" ]]; then
        SELECTED_DRIVER_SOURCE="archive"
    fi
    
    echo -e "恢复的目标版本: ${GREEN}${FILENAME}${NC}"
    echo -e "恢复的驱动选项: ${GREEN}${CONFIRM_DRIVER}${NC}"
    if [[ "$CONFIRM_DRIVER" == "yes" ]]; then
        echo -e "恢复的驱动版本: ${GREEN}${SELECTED_DRIVER_VERSION}${NC}"
    fi
    
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

    mapfile -t CUDA_VERSIONS < <(fetch_cuda_versions)

    if [ ${#CUDA_VERSIONS[@]} -eq 0 ]; then
        echo -e "${RED}错误: 无法从 NVIDIA 官网获取版本列表。${NC}"
        exit 1
    fi

    while true; do
        CUDA_VERSION=""
        FILENAME=""
        CONFIRM_DRIVER=""
        RECOMMENDED_DRIVER_VERSION=""
        MINIMUM_DRIVER_VERSION=""
        SELECTED_DRIVER_VERSION=""
        SELECTED_DRIVER_FILE=""
        SELECTED_DRIVER_URL=""
        SELECTED_DRIVER_SOURCE=""

        # --- 4. 提供选择菜单 ---
        echo -e "${YELLOW}--- 请选择您要安装的 CUDA Toolkit 版本 ---${NC}"
        PS3="请输入选项编号: "
        select CUDA_SELECT in "${CUDA_VERSIONS[@]}"; do
            if [[ -n "$CUDA_SELECT" ]]; then
                CUDA_VERSION="$CUDA_SELECT"
                echo -e "您选择了 CUDA Toolkit: ${GREEN}${CUDA_VERSION}${NC}"
                break
            else
                echo -e "${RED}无效选项。${NC}"
            fi
        done
        echo

        # --- 5.1. 获取 CUDA 安装器、最低驱动和推荐驱动版本 ---
        echo -e "${YELLOW}--- 正在获取 CUDA ${CUDA_VERSION} 的安装器和驱动兼容信息... ---${NC}"
        RECOMMENDED_DRIVER_VERSION=$(get_recommended_driver_version "$CUDA_VERSION")
        MINIMUM_DRIVER_VERSION=$(get_minimum_driver_version "$CUDA_VERSION")
        FILENAME=$(get_cuda_runfile "$CUDA_VERSION" "$RECOMMENDED_DRIVER_VERSION")

        if [[ -z "$RECOMMENDED_DRIVER_VERSION" ]]; then
            RUNFILE_DRIVER_VERSION=$(echo "$FILENAME" | awk -F_ '{print $3}')
            if [[ "$RUNFILE_DRIVER_VERSION" =~ ^[0-9] ]]; then
                RECOMMENDED_DRIVER_VERSION="$RUNFILE_DRIVER_VERSION"
            fi
        fi

        if [[ -z "$MINIMUM_DRIVER_VERSION" && -n "$RECOMMENDED_DRIVER_VERSION" ]]; then
            MINIMUM_DRIVER_VERSION="$RECOMMENDED_DRIVER_VERSION"
            log_warn "未能获取最低驱动版本，将使用官方随包驱动版本作为过滤下限。"
        fi

        if [[ -n "$MINIMUM_DRIVER_VERSION" ]]; then
            echo -e "CUDA ${CUDA_VERSION} 最低兼容驱动: ${GREEN}${MINIMUM_DRIVER_VERSION}${NC}"
        else
            log_warn "未能获取最低驱动版本，无法按兼容性过滤驱动列表。"
        fi

        if [[ -n "$RECOMMENDED_DRIVER_VERSION" ]]; then
            echo -e "CUDA ${CUDA_VERSION} 官方随包驱动: ${GREEN}${RECOMMENDED_DRIVER_VERSION}${NC}"
        else
            log_warn "未能从 release notes 获取推荐驱动版本。"
        fi
        echo -e "CUDA Toolkit 安装器: ${GREEN}${FILENAME}${NC}"
        echo

        # --- 5.2. 选择 NVIDIA Driver 版本 ---
        echo -e "${YELLOW}--- 正在获取 NVIDIA Driver 版本列表... ---${NC}"
        mapfile -t ARCHIVE_DRIVER_VERSIONS < <(fetch_nvidia_driver_versions)
        mapfile -t DRIVER_VERSIONS < <(filter_compatible_driver_versions "$MINIMUM_DRIVER_VERSION" "${ARCHIVE_DRIVER_VERSIONS[@]}")

        RECOMMENDED_DRIVER_FROM_ARCHIVE="no"
        if [[ -n "$RECOMMENDED_DRIVER_VERSION" ]]; then
            for driver_version in "${DRIVER_VERSIONS[@]}"; do
                if [[ "$driver_version" == "$RECOMMENDED_DRIVER_VERSION" ]]; then
                    RECOMMENDED_DRIVER_FROM_ARCHIVE="yes"
                    break
                fi
            done

            if [[ "$RECOMMENDED_DRIVER_FROM_ARCHIVE" == "no" ]]; then
                if version_ge "$RECOMMENDED_DRIVER_VERSION" "$MINIMUM_DRIVER_VERSION"; then
                    DRIVER_VERSIONS=("$RECOMMENDED_DRIVER_VERSION" "${DRIVER_VERSIONS[@]}")
                else
                    log_warn "官方随包驱动 ${RECOMMENDED_DRIVER_VERSION} 低于最低要求 ${MINIMUM_DRIVER_VERSION}，不会显示。"
                fi
            fi
        fi

        DRIVER_OPTIONS=("返回上级菜单 (重新选择 CUDA)" "不安装 NVIDIA Driver (仅安装 CUDA Toolkit)")
        for driver_version in "${DRIVER_VERSIONS[@]}"; do
            if [[ "$driver_version" == "$RECOMMENDED_DRIVER_VERSION" ]]; then
                DRIVER_OPTIONS+=("${driver_version} (推荐)")
            else
                DRIVER_OPTIONS+=("${driver_version}")
            fi
        done

        if [[ ${#DRIVER_VERSIONS[@]} -eq 0 ]]; then
            log_warn "没有找到与 CUDA ${CUDA_VERSION} 匹配的 NVIDIA Driver 版本。"
        fi

        echo -e "${YELLOW}--- 请选择 NVIDIA Driver 版本 ---${NC}"
        if [[ -n "$MINIMUM_DRIVER_VERSION" ]]; then
            echo -e "仅显示不低于 ${GREEN}${MINIMUM_DRIVER_VERSION}${NC} 的兼容驱动版本。"
        fi
        PS3="请输入选项编号: "
        select DRIVER_SELECT in "${DRIVER_OPTIONS[@]}"; do
            if [[ -n "$DRIVER_SELECT" ]]; then
                if [[ "$DRIVER_SELECT" == "返回上级菜单 (重新选择 CUDA)" ]]; then
                    echo
                    continue 2
                elif [[ "$DRIVER_SELECT" == "不安装 NVIDIA Driver (仅安装 CUDA Toolkit)" ]]; then
                    CONFIRM_DRIVER="no"
                    echo -e "您选择了: ${GREEN}仅安装 CUDA Toolkit${NC}"
                else
                    CONFIRM_DRIVER="yes"
                    SELECTED_DRIVER_VERSION="${DRIVER_SELECT%% *}"
                    if [[ "$SELECTED_DRIVER_VERSION" == "$RECOMMENDED_DRIVER_VERSION" && "$RECOMMENDED_DRIVER_FROM_ARCHIVE" == "no" ]]; then
                        SELECTED_DRIVER_SOURCE="cuda"
                        SELECTED_DRIVER_FILE=""
                        SELECTED_DRIVER_URL=""
                    else
                        SELECTED_DRIVER_SOURCE="archive"
                        SELECTED_DRIVER_FILE=$(resolve_nvidia_driver_file "$SELECTED_DRIVER_VERSION")
                        SELECTED_DRIVER_URL="${NVIDIA_DRIVER_BASE_URL}/${NVIDIA_DRIVER_DIR}/${SELECTED_DRIVER_VERSION}/${SELECTED_DRIVER_FILE}"
                    fi
                    echo -e "您选择了 NVIDIA Driver: ${GREEN}${SELECTED_DRIVER_VERSION}${NC}"
                    if [[ "$SELECTED_DRIVER_SOURCE" == "cuda" ]]; then
                        echo -e "驱动来源: ${GREEN}CUDA Toolkit 安装器内置驱动${NC}"
                    else
                        echo -e "驱动安装器: ${GREEN}${SELECTED_DRIVER_FILE}${NC}"
                    fi
                fi
                break
            else
                echo -e "${RED}无效选项。${NC}"
            fi
        done
        echo
        break
    done

    # --- 检查 Nouveau 状态 (仅当用户选择安装驱动时) ---
    if [[ "$CONFIRM_DRIVER" == "yes" ]]; then
        if lsmod | grep -q nouveau; then
            # 触发禁用逻辑，并退出脚本等待重启
            disable_nouveau_and_reboot "$FILENAME" "$CONFIRM_DRIVER" "$CUDA_VERSION" "$SELECTED_DRIVER_VERSION" "$SELECTED_DRIVER_FILE" "$SELECTED_DRIVER_URL" "$RECOMMENDED_DRIVER_VERSION" "$SELECTED_DRIVER_SOURCE" "$MINIMUM_DRIVER_VERSION"
        else
            log_info "Nouveau 未加载或已禁用。可以直接安装。"
        fi
    fi
fi

# ==============================================================================
# 安装执行阶段 (无论是首次运行还是重启后恢复，都会汇聚到这里)
# ==============================================================================

CUDA_MAJOR_VERSION="${CUDA_VERSION:-$(echo "$FILENAME" | cut -d'_' -f2)}"
DOWNLOAD_URL="https://developer.download.nvidia.com/compute/cuda/${CUDA_MAJOR_VERSION}/local_installers/${FILENAME}"

# --- 下载 ---
if [ -f "./${FILENAME}" ]; then
    echo -e "${YELLOW}文件已存在，跳过下载。${NC}"
else
    echo -e "${YELLOW}--- 开始下载... ---${NC}"
    wget --progress=bar:force "${DOWNLOAD_URL}"
fi
chmod +x "${FILENAME}"

# --- 安装 NVIDIA Driver ---
DRIVER_MSG="无驱动"
if [[ "$CONFIRM_DRIVER" == "yes" ]]; then
    DRIVER_MSG="NVIDIA Driver ${SELECTED_DRIVER_VERSION}"

    if [[ "$SELECTED_DRIVER_SOURCE" == "cuda" ]]; then
        log_info "将使用 CUDA Toolkit 安装器内置的 NVIDIA Driver ${SELECTED_DRIVER_VERSION}。"
    elif [[ -z "$SELECTED_DRIVER_FILE" ]]; then
        SELECTED_DRIVER_FILE=$(resolve_nvidia_driver_file "$SELECTED_DRIVER_VERSION")
    fi

    if [[ "$SELECTED_DRIVER_SOURCE" != "cuda" && -z "$SELECTED_DRIVER_URL" ]]; then
        SELECTED_DRIVER_URL="${NVIDIA_DRIVER_BASE_URL}/${NVIDIA_DRIVER_DIR}/${SELECTED_DRIVER_VERSION}/${SELECTED_DRIVER_FILE}"
    fi

    if [[ "$SELECTED_DRIVER_SOURCE" != "cuda" ]]; then
        if [ -f "./${SELECTED_DRIVER_FILE}" ]; then
            echo -e "${YELLOW}驱动安装器已存在，跳过下载。${NC}"
        else
            echo -e "${YELLOW}--- 开始下载 NVIDIA Driver ${SELECTED_DRIVER_VERSION}... ---${NC}"
            wget --progress=bar:force "${SELECTED_DRIVER_URL}"
        fi
        chmod +x "${SELECTED_DRIVER_FILE}"

        echo -e "${YELLOW}--- 开始静默安装 NVIDIA Driver ${SELECTED_DRIVER_VERSION}... ---${NC}"
        if ! sudo "./${SELECTED_DRIVER_FILE}" --silent --no-questions; then
            echo -e "${RED}NVIDIA Driver 安装失败。请查看 /var/log/nvidia-installer.log${NC}"
            exit 1
        fi
    fi
fi

CUDA_INSTALL_VERSION=$(echo "$CUDA_MAJOR_VERSION" | awk -F. '{print $1"."$2}') 
INSTALL_PATH="/usr/local/cuda-${CUDA_INSTALL_VERSION}"

echo -e "${YELLOW}--- 开始静默安装 CUDA Toolkit (${DRIVER_MSG})... ---${NC}"
echo -e "这可能需要几分钟，请不要关闭终端..."

# 执行安装
CUDA_INSTALL_ARGS=(--silent --toolkit --samples --installpath="${INSTALL_PATH}")
if [[ "$CONFIRM_DRIVER" == "yes" && "$SELECTED_DRIVER_SOURCE" == "cuda" ]]; then
    CUDA_INSTALL_ARGS+=(--driver)
fi

if ! sudo "./${FILENAME}" "${CUDA_INSTALL_ARGS[@]}"; then
    echo -e "${RED}CUDA Toolkit 安装失败。请查看 /var/log/cuda-installer.log${NC}"
    # 注意：如果失败了，我们不删除状态文件，以便用户排查后重新运行
    exit 1
fi

echo -e "${GREEN}CUDA 安装成功！${NC}"

# --- 7. 环境变量配置 (保持原逻辑) ---
BASHRC_FILE="$HOME/.bashrc"
SYMLINK_PATH="/usr/local/cuda"

sudo ln -sfn "${INSTALL_PATH}" "${SYMLINK_PATH}"
touch "$BASHRC_FILE"

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
