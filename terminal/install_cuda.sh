#!/bin/bash

# ==============================================================================
#
# NVIDIA CUDA Toolkit 全自动安装脚本 (支持自动禁用 Nouveau 并断点续传)
#
# 功能:
#   1. 自动检测系统信息。
#   2. 获取 NVIDIA 官网所有 CUDA 版本。
#   3. 支持完整安装 CUDA Toolkit，或仅安装 NVIDIA Driver。
#   4. [核心功能] 自动检测 Nouveau 驱动：
#      - 如存在，自动写入黑名单，生成状态文件，并提示重启。
#      - 重启后再次运行脚本，会自动读取状态，跳过选单，继续安装。
#   5. 静默安装 CUDA Toolkit 和可选的 NVIDIA Driver。
#   6. 配置环境变量。
#
# ==============================================================================

# --- 全局配置 ---
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WORK_DIR="${CUDA_INSTALL_WORK_DIR:-${SCRIPT_DIR}}"
DOWNLOAD_DIR="${CUDA_DOWNLOAD_DIR:-${WORK_DIR}}"
STATE_FILE="${CUDA_STATE_FILE:-${WORK_DIR}/.cuda_install_state.conf}" # 用于存储重启前状态的文件
RELEASE_NOTES_CACHE_DIR="${WORK_DIR}/.cuda_release_notes_cache"
RELEASE_NOTES_CACHE_TTL_DAYS="${RELEASE_NOTES_CACHE_TTL_DAYS:-7}" # release notes 缓存有效期(天)，过期后重新拉取
NVIDIA_BLACKLIST_FILE="/etc/modprobe.d/blacklist-nouveau.conf"
SYMLINK_PATH="/usr/local/cuda"
CUDA_ARCHIVE_URL="https://developer.nvidia.com/cuda-toolkit-archive"
NVIDIA_DRIVER_BASE_URL="https://download.nvidia.com/XFree86"
MIN_CUDA_TOOLKIT_VERSION="11.0" # 低于该版本的 CUDA Toolkit 默认视为过旧不显示；设为空则显示全部
DRIVER_SELECT_TIMEOUT="${DRIVER_SELECT_TIMEOUT:-180}" # 选择 NVIDIA Driver 超过该秒数后默认安装 CUDA 自带驱动
ARIA2_CONNECTIONS="${ARIA2_CONNECTIONS:-16}" # aria2c 单服务器连接数
ARIA2_SPLIT="${ARIA2_SPLIT:-16}" # aria2c 分片数
ARIA2_MIN_SPLIT_SIZE="${ARIA2_MIN_SPLIT_SIZE:-1M}"
DOWNLOAD_RETRIES="${DOWNLOAD_RETRIES:-5}"
DOWNLOAD_TIMEOUT="${DOWNLOAD_TIMEOUT:-30}"
METADATA_TIMEOUT="${METADATA_TIMEOUT:-15}" # 版本列表/release notes 等元数据请求的单次超时(秒)
METADATA_TRIES="${METADATA_TRIES:-2}" # 元数据请求重试次数(wget 默认 900 秒 x20 次，网络停滞会挂住极久)
REBOOT_CONFIRM_TIMEOUT="${REBOOT_CONFIRM_TIMEOUT:-120}" # 重启确认等待秒数，超时默认不自动重启
CUDA_INSTALL_TMPDIR="${CUDA_INSTALL_TMPDIR:-}" # 非空时传给 runfile --tmpdir，用于避开容量不足的 /tmp
CUDA_DOWNLOAD_NEED_MB="${CUDA_DOWNLOAD_NEED_MB:-6144}" # CUDA runfile 下载目录最低可用空间(MB)
CUDA_TMP_NEED_MB="${CUDA_TMP_NEED_MB:-10240}" # CUDA 安装解压临时目录最低可用空间(MB)
DRIVER_DOWNLOAD_NEED_MB="${DRIVER_DOWNLOAD_NEED_MB:-1024}" # Driver runfile 下载目录最低可用空间(MB)
DRIVER_TMP_NEED_MB="${DRIVER_TMP_NEED_MB:-2048}" # Driver 安装解压临时目录最低可用空间(MB)
AUTO_INSTALL_ARIA2="${AUTO_INSTALL_ARIA2:-1}" # 设为 0 时不自动安装 aria2，仅使用系统已有下载器
SKIP_DRIVER_PREFLIGHT="${SKIP_DRIVER_PREFLIGHT:-0}" # 设为 1 时跳过 NVIDIA Driver 安装前依赖检查
INSTALL_CUDA_SAMPLES="${INSTALL_CUDA_SAMPLES:-0}" # 设为 1 时安装 CUDA Samples
UNLOAD_NVIDIA_MODULES="${UNLOAD_NVIDIA_MODULES:-1}" # 设为 0 时不自动卸载已加载的 NVIDIA 内核模块
REMOVE_CONFLICTING_DKMS="${REMOVE_CONFLICTING_DKMS:-ask}" # ask/1/0：runfile 装驱动前如何处理版本不同的 DKMS 驱动
FIX_FABRICMANAGER="${FIX_FABRICMANAGER:-ask}" # ask/1/0：fabricmanager 与驱动版本不一致时是否自动修复
DKMS_CONFIRM_TIMEOUT="${DKMS_CONFIRM_TIMEOUT:-60}" # 移除冲突 DKMS 驱动的确认等待秒数，超时默认执行
FABRICMANAGER_CONFIRM_TIMEOUT="${FABRICMANAGER_CONFIRM_TIMEOUT:-60}" # 修复 fabricmanager 的确认等待秒数，超时默认执行
ALLOW_CONTAINER_DRIVER_INSTALL="${ALLOW_CONTAINER_DRIVER_INSTALL:-0}" # 设为 1 时允许在容器内尝试安装驱动
NVIDIA_KERNEL_MODULE_TYPE="${NVIDIA_KERNEL_MODULE_TYPE:-}" # open 或 proprietary；留空则由安装器默认选择

# --- 辅助函数 ---
log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${BOLD}${RED}[ERROR]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_debug() { echo -e "${BLUE}[DEBUG]${NC} $1"; }
print_section() { echo -e "\n${BOLD}${BLUE}==>${NC} ${BOLD}$1${NC}"; }
print_kv() { echo -e "  ${CYAN}$1:${NC} ${GREEN}$2${NC}"; }
print_hint() { echo -e "  ${YELLOW}$1${NC}"; }

# 元数据请求统一使用短超时+少量重试，避免网络停滞时脚本在出菜单前长时间挂住。
metadata_wget() {
    wget --timeout="${METADATA_TIMEOUT}" --tries="${METADATA_TRIES}" "$@"
}

get_free_space_mb() {
    df -Pm "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

check_disk_space() {
    local path=$1
    local need_mb=$2
    local label=$3
    local free_mb

    free_mb=$(get_free_space_mb "$path")
    if ! [[ "$free_mb" =~ ^[0-9]+$ ]]; then
        log_warn "无法检测 ${label} (${path}) 的可用空间，跳过空间检查。"
        return 0
    fi

    if (( free_mb < need_mb )); then
        log_error "${label} 可用空间不足: ${path} 剩余 ${free_mb}MB，预计需要 ${need_mb}MB。"
        return 1
    fi

    return 0
}

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

set -e
set -o pipefail

SUDO_CMD=()

init_privilege() {
    if [[ "$(id -u)" -eq 0 ]]; then
        SUDO_CMD=()
        return 0
    fi

    if ! command -v sudo &> /dev/null; then
        log_error "当前用户不是 root，且系统未安装 sudo。请以 root 运行脚本，或先安装 sudo。"
        exit 1
    fi

    if ! sudo -v; then
        log_error "sudo 授权失败，无法继续执行需要系统权限的安装步骤。"
        exit 1
    fi

    SUDO_CMD=(sudo)
}

run_privileged() {
    "${SUDO_CMD[@]}" "$@"
}

prepare_work_dirs() {
    local state_dir

    state_dir="$(dirname -- "$STATE_FILE")"
    mkdir -p "$state_dir" "$DOWNLOAD_DIR" "$RELEASE_NOTES_CACHE_DIR"

    if [[ ! -w "$state_dir" ]]; then
        log_error "状态文件目录不可写: ${state_dir}"
        exit 1
    fi

    if [[ ! -w "$DOWNLOAD_DIR" ]]; then
        log_error "下载目录不可写: ${DOWNLOAD_DIR}"
        exit 1
    fi
}

install_aria2_if_missing() {
    if command -v aria2c &> /dev/null; then
        return 0
    fi

    if [[ "$AUTO_INSTALL_ARIA2" != "1" ]]; then
        log_warn "未检测到 aria2c，且 AUTO_INSTALL_ARIA2=${AUTO_INSTALL_ARIA2}，跳过 aria2 自动安装。"
        return 0
    fi

    print_section "配置下载加速"
    log_warn "未检测到 aria2c，正在尝试自动安装 aria2 以启用多线程分片下载。"

    if command -v apt-get &> /dev/null; then
        if run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y aria2 || \
            { run_privileged apt-get update && run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y aria2; }; then
            :
        fi
    elif command -v dnf &> /dev/null; then
        run_privileged dnf install -y aria2 || true
    elif command -v yum &> /dev/null; then
        run_privileged yum install -y aria2 || true
    elif command -v zypper &> /dev/null; then
        run_privileged zypper --non-interactive install aria2 || true
    elif command -v pacman &> /dev/null; then
        run_privileged pacman -Sy --noconfirm aria2 || true
    else
        log_warn "未识别可用的包管理器，跳过 aria2 自动安装。"
    fi

    if command -v aria2c &> /dev/null; then
        log_success "aria2 安装完成，将使用多线程分片下载。"
    else
        log_warn "aria2 自动安装未成功，将继续使用 wget 断点续传。"
    fi
}

echo -e "${BOLD}${BLUE}=====================================================${NC}"
echo -e "${BOLD}${BLUE}    NVIDIA CUDA Toolkit 智能安装脚本 (含驱动处理)   ${NC}"
echo -e "${BOLD}${BLUE}=====================================================${NC}"
echo -e "${DIM}    先选择 CUDA Toolkit，再选择兼容的 NVIDIA Driver${NC}"
echo

# --- 1. 依赖与权限检查 ---
if ! command -v wget &> /dev/null; then
    log_error "'wget' 未安装。请先安装: sudo apt install wget 或 sudo yum install wget"
    exit 1
fi

init_privilege
prepare_work_dirs
print_kv "工作目录" "$WORK_DIR"
print_kv "下载目录" "$DOWNLOAD_DIR"
print_kv "状态文件" "$STATE_FILE"

install_aria2_if_missing

if command -v aria2c &> /dev/null; then
    log_info "检测到 aria2c，将优先使用多线程分片下载。"
else
    log_warn "未检测到 aria2c，将使用 wget 断点续传下载。"
fi

# --- 2. 判断系统版本 ---
if [ -f /etc/os-release ]; then
    . /etc/os-release
    print_kv "操作系统" "${PRETTY_NAME:-${NAME:-unknown}}"
else
    log_error "无法确定操作系统版本。"
    exit 1
fi

# ==============================================================================
# 核心逻辑：断点续传与状态检测
# ==============================================================================

# 函数：识别 Jetson/Tegra 平台。它们也是 aarch64，但不使用 SBSA runfile。
is_jetson_platform() {
    [[ -f /etc/nv_tegra_release ]] && return 0

    if [[ -r /proc/device-tree/model ]]; then
        tr -d '\0' < /proc/device-tree/model | grep -qiE 'jetson|tegra'
        return $?
    fi

    return 1
}

is_nouveau_loaded() {
    local modules

    if [[ -r /proc/modules ]]; then
        awk '$1 == "nouveau" { found = 1 } END { exit !found }' /proc/modules
        return $?
    fi

    if command -v lsmod &> /dev/null; then
        if ! modules=$(lsmod 2>/dev/null); then
            log_error "lsmod 执行失败，无法确认 Nouveau 状态。"
            exit 1
        fi

        printf "%s\n" "$modules" | awk '$1 == "nouveau" { found = 1 } END { exit !found }'
        return $?
    fi

    log_error "无法检测 Nouveau 状态：/proc/modules 不可读且 lsmod 不可用。"
    exit 1
}

# 函数：获取当前架构对应的 CUDA/Driver 安装器命名
detect_nvidia_driver_arch() {
    case "$(uname -m)" in
        x86_64|amd64)
            CUDA_ARCH_LABEL="Linux x86_64"
            CUDA_RUNFILE_SUFFIX="linux"
            NVIDIA_DRIVER_DIR="Linux-x86_64"
            NVIDIA_DRIVER_FILE_ARCH="x86_64"
            ;;
        aarch64|arm64)
            if is_jetson_platform; then
                log_error "检测到 Jetson/Tegra ARM64 平台。此脚本支持 ARM64 SBSA 服务器，不支持 Jetson/L4T；Jetson 请使用 JetPack、SDK Manager 或厂商提供的 apt 源安装 CUDA。"
                exit 1
            fi
            CUDA_ARCH_LABEL="Linux ARM64 SBSA"
            CUDA_RUNFILE_SUFFIX="linux_sbsa"
            NVIDIA_DRIVER_DIR="Linux-aarch64"
            NVIDIA_DRIVER_FILE_ARCH="aarch64"
            ;;
        ppc64le)
            CUDA_ARCH_LABEL="Linux ppc64le"
            CUDA_RUNFILE_SUFFIX="linux_ppc64le"
            NVIDIA_DRIVER_DIR="Linux-ppc64le"
            NVIDIA_DRIVER_FILE_ARCH="ppc64le"
            ;;
        armv7l|armv6l|armhf)
            log_error "当前为 32-bit ARM 架构 ($(uname -m))，NVIDIA CUDA runfile 不支持该架构。请使用 ARM64 SBSA 平台或 Jetson/厂商提供的安装方式。"
            exit 1
            ;;
        *)
            log_error "不支持的 CPU 架构: $(uname -m)。NVIDIA CUDA runfile 仅提供 x86_64、ARM64 SBSA 与 ppc64le 安装包。"
            exit 1
            ;;
    esac
}

require_safe_runfile_name() {
    local filename=$1
    local label=${2:-runfile 文件名}

    if [[ ! "$filename" =~ ^[A-Za-z0-9._+-]+\.run$ ]]; then
        log_error "${label} 不合法: ${filename}"
        exit 1
    fi
}

runfile_path() {
    local filename=$1

    require_safe_runfile_name "$filename"
    printf "%s/%s" "$DOWNLOAD_DIR" "$filename"
}

# 函数：获取 NVIDIA 归档页中的所有 CUDA Toolkit 版本
fetch_all_cuda_versions() {
    metadata_wget -qO- "$CUDA_ARCHIVE_URL" | \
        grep -oE "CUDA Toolkit [0-9]+\.[0-9]+(\.[0-9]+)?" | \
        sed 's/CUDA Toolkit //' | \
        sort -rV | \
        awk '!seen[$0]++'
}

# 函数：获取 CUDA Toolkit 版本，过滤特别老旧的版本
fetch_cuda_versions() {
    fetch_all_cuda_versions | \
        while read -r version; do
            if version_ge "$version" "$MIN_CUDA_TOOLKIT_VERSION"; then
                echo "$version"
            fi
        done
}

# 函数：比较版本号，判断 candidate 是否不低于 minimum
# 纯 bash 逐段数值比较，避免每次调用都 fork sort/head 子进程(大列表过滤时性能差距明显)。
version_ge() {
    local candidate=$1
    local minimum=$2
    local -a c_parts m_parts
    local i count c_seg m_seg

    [[ -z "$minimum" ]] && return 0

    IFS=. read -ra c_parts <<< "$candidate"
    IFS=. read -ra m_parts <<< "$minimum"

    # 段数对齐(缺失段补 0)，避免把 12.4 误判为小于 12.4.0
    count=${#c_parts[@]}
    (( ${#m_parts[@]} > count )) && count=${#m_parts[@]}

    for (( i = 0; i < count; i++ )); do
        # 去掉前导零并兜底空串为 0，按十进制整数逐段比较
        c_seg=$((10#${c_parts[i]:-0}))
        m_seg=$((10#${m_parts[i]:-0}))
        (( c_seg > m_seg )) && return 0
        (( c_seg < m_seg )) && return 1
    done

    return 0
}

# 函数：判断 release notes HTML 是否为有效内容(过滤占位/重定向/错误页)
release_notes_html_is_valid() {
    local file=$1

    [[ -s "$file" ]] || return 1
    grep -qiE "Driver Version|Display Driver|Linux Driver" "$file"
}

get_release_notes() {
    local cuda_version=$1
    local cache_key="${cuda_version//./_}"
    local cache_file="${RELEASE_NOTES_CACHE_DIR}/cuda-${cache_key}.html"
    local temp_file="${cache_file}.download"
    local release_notes_url="https://docs.nvidia.com/cuda/archive/${cuda_version}/cuda-toolkit-release-notes/index.html"

    # 缓存命中需同时满足：内容有效 + 未超过 TTL(过滤历史误存的占位/重定向页)
    if release_notes_html_is_valid "$cache_file" \
        && ! find "$cache_file" -mtime "+${RELEASE_NOTES_CACHE_TTL_DAYS}" 2>/dev/null | grep -q .; then
        cat "$cache_file"
        return 0
    fi

    if metadata_wget -qO "$temp_file" "$release_notes_url" 2>/dev/null && release_notes_html_is_valid "$temp_file"; then
        mv -f "$temp_file" "$cache_file"
        cat "$cache_file"
    else
        rm -f "$temp_file"
        # 下载失败或内容无效时，回退到旧缓存(若仍有效)，否则返回空让上层降级
        if release_notes_html_is_valid "$cache_file"; then
            cat "$cache_file"
        fi
        return 0
    fi
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
    # CUDA 13.x 起 "Minimum Required Driver Version" 表(Table 2)行去掉了 "CUDA" 前缀，
    # 形如 "13.x >= 580"，需额外匹配以主版本号开头的 "<major>.x" 行。
    [[ "$row_text" =~ (^|[^0-9.])${cuda_major}\.x([^0-9]|$) ]] && return 0
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
            # 优先提取完整版本号(如 525.60.13)；新格式只给主版本号(如 580)，作为兜底再取一次。
            driver_version=$(printf "%s\n" "$row_text" | \
                grep -oE ">= ?[0-9]+\.[0-9]+(\.[0-9]+)?" | \
                head -1 | \
                grep -oE "[0-9]+\.[0-9]+(\.[0-9]+)?" || true)

            if [[ -z "$driver_version" ]]; then
                driver_version=$(printf "%s\n" "$row_text" | \
                    grep -oE ">= ?[0-9]+" | \
                    head -1 | \
                    grep -oE "[0-9]+" || true)
            fi

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

    release_notes=$(get_release_notes "$cuda_version")
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

    get_release_notes "$cuda_version" | \
        grep -A4 -i "NVIDIA Linux Driver" | \
        grep -oE "[0-9]+\.[0-9]+(\.[0-9]+)?" | \
        head -1 || true
}

get_cuda_archive_runfile_driver_version() {
    local cuda_version=$1
    local escaped_cuda_version="${cuda_version//./\\.}"
    local archive_slug="cuda-${cuda_version//./-}-download-archive"
    local filename

    filename=$(metadata_wget -qO- "https://developer.nvidia.com/${archive_slug}" 2>/dev/null | \
        grep -oE "cuda_${escaped_cuda_version}_[0-9]+\.[0-9]+(\.[0-9]+)?_${CUDA_RUNFILE_SUFFIX}\.run" | \
        head -1 || true)

    if [[ -n "$filename" ]]; then
        echo "$filename" | awk -F_ '{print $3}'
    fi
}

extract_first_cuda_version_from_text() {
    grep -oE "[0-9]+\.[0-9]+(\.[0-9]+)?" | head -1 || true
}

normalize_cuda_version() {
    local version=$1

    if [[ "$version" =~ ^([0-9]+)\.([0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    fi
}

resolve_cuda_archive_version() {
    local cuda_version=$1
    local archive_version

    [[ -z "$cuda_version" ]] && return 0

    while IFS= read -r archive_version; do
        [[ -z "$archive_version" ]] && continue

        if [[ "$archive_version" == "$cuda_version" || "$archive_version" == "${cuda_version}."* ]]; then
            echo "$archive_version"
            return 0
        fi
    done < <(fetch_all_cuda_versions 2>/dev/null || true)

    echo "$cuda_version"
}

extract_normalized_cuda_version_from_text() {
    local version

    version=$(extract_first_cuda_version_from_text)
    normalize_cuda_version "$version"
}

detect_cuda_version_from_path() {
    local cuda_path=$1
    local resolved_path
    local version_file
    local basename_value
    local nvcc_output
    local version

    [[ -d "$cuda_path" ]] || return 1

    resolved_path=$(readlink -f "$cuda_path" 2>/dev/null || printf "%s" "$cuda_path")
    basename_value=$(basename -- "$resolved_path")
    if [[ "$basename_value" =~ ^cuda-([0-9]+\.[0-9]+(\.[0-9]+)?)$ ]]; then
        normalize_cuda_version "${BASH_REMATCH[1]}"
        return 0
    fi

    for version_file in "${cuda_path}/version.txt" "${cuda_path}/version.json" "${resolved_path}/version.txt" "${resolved_path}/version.json"; do
        [[ -r "$version_file" ]] || continue
        version=$(extract_normalized_cuda_version_from_text < "$version_file")
        if [[ -n "$version" ]]; then
            echo "$version"
            return 0
        fi
    done

    if [[ -x "${cuda_path}/bin/nvcc" ]]; then
        nvcc_output=$("${cuda_path}/bin/nvcc" -V 2>/dev/null || true)
        version=$(printf "%s\n" "$nvcc_output" | \
            grep -oE "release [0-9]+\.[0-9]+(\.[0-9]+)?" | \
            sed 's/release //' | \
            head -1)
        version=$(normalize_cuda_version "$version")
        if [[ -n "$version" ]]; then
            echo "$version"
            return 0
        fi
    fi

    return 1
}

detect_active_cuda_version() {
    local nvcc_output
    local version
    local cuda_path

    if command -v nvcc &> /dev/null; then
        nvcc_output=$(nvcc -V 2>/dev/null || true)
        version=$(printf "%s\n" "$nvcc_output" | \
            grep -oE "release [0-9]+\.[0-9]+(\.[0-9]+)?" | \
            sed 's/release //' | \
            head -1)
        version=$(normalize_cuda_version "$version")
        if [[ -n "$version" ]]; then
            echo "$version"
            return 0
        fi
    fi

    for cuda_path in "${CUDA_HOME:-}" "${CUDA_PATH:-}" /usr/local/cuda; do
        [[ -n "$cuda_path" ]] || continue
        version=$(detect_cuda_version_from_path "$cuda_path" || true)
        if [[ -n "$version" ]]; then
            echo "$version"
            return 0
        fi
    done

    return 1
}

cuda_is_latest_or_newer_than_archive() {
    local cuda_version=$1
    local latest_cuda
    local latest_major_minor

    latest_cuda=$(fetch_all_cuda_versions 2>/dev/null | head -1 || true)
    latest_major_minor=$(normalize_cuda_version "$latest_cuda")

    [[ -z "$latest_major_minor" ]] && return 2
    version_ge "$cuda_version" "$latest_major_minor"
}

prepare_driver_only_driver_versions() {
    local active_cuda
    local release_notes_cuda
    local minimum_driver
    local recommended_driver
    local archive_driver_version
    local required_driver=""
    local cuda_summary=""
    local driver_version
    local i
    local latest_check_status

    DRIVER_ONLY_MINIMUM_DRIVER=""
    DRIVER_ONLY_INSTALLED_CUDA=""
    DRIVER_LIST_RECOMMENDED_VERSION=""

    mapfile -t ARCHIVE_DRIVER_VERSIONS < <(fetch_nvidia_driver_versions)
    if [[ ${#ARCHIVE_DRIVER_VERSIONS[@]} -eq 0 ]]; then
        log_error "无法从 NVIDIA 官网获取 Driver 版本列表。"
        exit 1
    fi

    active_cuda=$(detect_active_cuda_version || true)
    if [[ -z "$active_cuda" ]]; then
        log_info "未检测到当前正在使用的 CUDA Toolkit，显示全部 NVIDIA Driver 版本。"
        DRIVER_DISPLAY_VERSIONS=("${ARCHIVE_DRIVER_VERSIONS[@]}")
        DRIVER_LIST_RECOMMENDED_VERSION="${DRIVER_DISPLAY_VERSIONS[0]}"
        apply_gpu_floor_to_driver_list || return 1
        return 0
    fi

    DRIVER_ONLY_INSTALLED_CUDA="$active_cuda"
    print_section "按当前 CUDA 过滤 NVIDIA Driver"
    print_kv "当前 CUDA" "$DRIVER_ONLY_INSTALLED_CUDA"

    release_notes_cuda=$(resolve_cuda_archive_version "$active_cuda")
    [[ -z "$release_notes_cuda" ]] && release_notes_cuda="$active_cuda"
    if [[ "$release_notes_cuda" != "$active_cuda" ]]; then
        print_kv "兼容信息来源" "当前 CUDA ${active_cuda} 系列，使用官网最新归档 ${release_notes_cuda} 的 release notes"
    fi

    recommended_driver=$(get_recommended_driver_version "$release_notes_cuda")
    minimum_driver=$(get_minimum_driver_version "$release_notes_cuda")

    if [[ -z "$recommended_driver" ]]; then
        archive_driver_version=$(get_cuda_archive_runfile_driver_version "$release_notes_cuda")
        if [[ "$archive_driver_version" =~ ^[0-9] ]]; then
            recommended_driver="$archive_driver_version"
        fi
    fi

    if [[ -z "$minimum_driver" && -n "$recommended_driver" ]]; then
        minimum_driver="$recommended_driver"
        log_warn "未能获取 CUDA ${active_cuda} 的最低驱动版本，将使用官方随包驱动版本作为过滤下限。"
    fi

    if [[ -z "$minimum_driver" ]]; then
        latest_check_status=0
        cuda_is_latest_or_newer_than_archive "$active_cuda" || latest_check_status=$?

        if [[ "$latest_check_status" -eq 0 ]]; then
            log_warn "CUDA ${active_cuda} 可能是官网最新或尚未完整发布的版本，暂未获取到最低 NVIDIA Driver 要求；将不按 CUDA 版本过滤驱动列表。"
        elif [[ "$latest_check_status" -eq 2 ]]; then
            log_warn "无法从 NVIDIA 官网确认最新 CUDA 版本，暂不按 CUDA ${active_cuda} 过滤驱动列表。"
        else
            log_warn "无法获取 CUDA ${active_cuda} 的最低 NVIDIA Driver 要求，无法按当前 CUDA 过滤驱动列表，将显示全部驱动版本。"
        fi

        DRIVER_DISPLAY_VERSIONS=("${ARCHIVE_DRIVER_VERSIONS[@]}")
        apply_gpu_floor_to_driver_list || return 1
        if [[ -n "$recommended_driver" ]] && driver_version_is_listed "$recommended_driver"; then
            DRIVER_LIST_RECOMMENDED_VERSION="$recommended_driver"
        fi
        return 0
    fi

    print_kv "最低兼容驱动" "$minimum_driver"
    if [[ -n "$recommended_driver" ]]; then
        print_kv "CUDA 自带驱动" "$recommended_driver"
    else
        log_warn "未能从 release notes 获取推荐驱动版本。"
    fi

    required_driver="$minimum_driver"
    cuda_summary="CUDA ${active_cuda}>=${minimum_driver}"

    required_driver=$(raise_minimum_with_gpu_floor "$minimum_driver")
    if [[ "$required_driver" != "$minimum_driver" ]]; then
        print_kv "本机 GPU 驱动下限" "${GPU_MINIMUM_DRIVER_VERSION}${DETECTED_GPU_NAMES:+ (${DETECTED_GPU_NAMES})}"
        cuda_summary="${cuda_summary}, GPU>=${GPU_MINIMUM_DRIVER_VERSION}"
    fi

    DRIVER_ONLY_MINIMUM_DRIVER="$required_driver"
    mapfile -t DRIVER_DISPLAY_VERSIONS < <(filter_compatible_driver_versions "$DRIVER_ONLY_MINIMUM_DRIVER" "${ARCHIVE_DRIVER_VERSIONS[@]}")

    if [[ ${#DRIVER_DISPLAY_VERSIONS[@]} -eq 0 ]]; then
        log_error "没有找到满足当前 CUDA 要求的 NVIDIA Driver 版本。"
        return 1
    fi

    if [[ -n "$recommended_driver" ]] && driver_version_is_listed "$recommended_driver"; then
        DRIVER_LIST_RECOMMENDED_VERSION="$recommended_driver"
    fi

    # 如果官方推荐驱动不在独立驱动归档中，则退回到不低于最低要求且最接近要求的版本。
    for ((i = ${#DRIVER_DISPLAY_VERSIONS[@]} - 1; i >= 0; i--)); do
        driver_version="${DRIVER_DISPLAY_VERSIONS[$i]}"
        if version_ge "$driver_version" "$DRIVER_ONLY_MINIMUM_DRIVER"; then
            [[ -z "$DRIVER_LIST_RECOMMENDED_VERSION" ]] && DRIVER_LIST_RECOMMENDED_VERSION="$driver_version"
            break
        fi
    done

    print_kv "兼容范围" "仅显示不低于 ${DRIVER_ONLY_MINIMUM_DRIVER} 的驱动"
    print_kv "过滤依据" "$cuda_summary"
    if [[ -n "$DRIVER_LIST_RECOMMENDED_VERSION" ]]; then
        if [[ "$DRIVER_LIST_RECOMMENDED_VERSION" == "$recommended_driver" ]]; then
            print_kv "推荐驱动" "${DRIVER_LIST_RECOMMENDED_VERSION} (CUDA 官方推荐)"
        else
            print_kv "推荐驱动" "${DRIVER_LIST_RECOMMENDED_VERSION} (最接近最低要求的独立驱动)"
        fi
    fi

    return 0
}

# 函数：获取 CUDA Toolkit runfile 文件名
get_cuda_runfile() {
    local cuda_version=$1
    local recommended_driver=$2
    local escaped_cuda_version="${cuda_version//./\\.}"
    local archive_slug="cuda-${cuda_version//./-}-download-archive"
    local filename

    filename=$(metadata_wget -qO- "https://developer.nvidia.com/${archive_slug}" 2>/dev/null | \
        grep -oE "cuda_${escaped_cuda_version}(_[0-9]+\.[0-9]+(\.[0-9]+)?)?_${CUDA_RUNFILE_SUFFIX}\.run" | \
        head -1 || true)

    if [[ -n "$filename" ]]; then
        echo "$filename"
    elif [[ -n "$recommended_driver" ]]; then
        echo "cuda_${cuda_version}_${recommended_driver}_${CUDA_RUNFILE_SUFFIX}.run"
    else
        echo "cuda_${cuda_version}_${CUDA_RUNFILE_SUFFIX}.run"
    fi
}

# 函数：尽可能从 NVIDIA 驱动归档目录获取所有版本
fetch_nvidia_driver_versions() {
    local index_url="${NVIDIA_DRIVER_BASE_URL}/${NVIDIA_DRIVER_DIR}/"

    metadata_wget -qO- "$index_url" 2>/dev/null | \
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

driver_version_is_listed() {
    local candidate=$1
    local driver_version

    for driver_version in "${DRIVER_DISPLAY_VERSIONS[@]}"; do
        [[ "$candidate" == "$driver_version" ]] && return 0
    done

    return 1
}

get_driver_direct_input_example() {
    local example="${DRIVER_LIST_RECOMMENDED_VERSION:-}"

    if [[ -z "$example" && -n "${RECOMMENDED_DRIVER_VERSION:-}" ]]; then
        example="$RECOMMENDED_DRIVER_VERSION"
    fi

    if [[ -z "$example" && ${#DRIVER_DISPLAY_VERSIONS[@]} -gt 0 ]]; then
        example="${DRIVER_DISPLAY_VERSIONS[0]}"
    fi

    echo "$example"
}

select_archive_driver() {
    local driver_version=$1

    CONFIRM_DRIVER="yes"
    SELECTED_DRIVER_VERSION="$driver_version"
    SELECTED_DRIVER_SOURCE="archive"
    SELECTED_DRIVER_FILE=$(resolve_nvidia_driver_file "$SELECTED_DRIVER_VERSION")
    SELECTED_DRIVER_URL="${NVIDIA_DRIVER_BASE_URL}/${NVIDIA_DRIVER_DIR}/${SELECTED_DRIVER_VERSION}/${SELECTED_DRIVER_FILE}"
}

print_driver_selection_result() {
    print_kv "已选择 NVIDIA Driver" "$SELECTED_DRIVER_VERSION"
    if [[ "$SELECTED_DRIVER_SOURCE" == "cuda" ]]; then
        print_kv "驱动来源" "CUDA Toolkit 安装器内置驱动"
    else
        print_kv "驱动安装器" "$SELECTED_DRIVER_FILE"
    fi
}

get_terminal_columns() {
    local cols="${COLUMNS:-}"

    if ! [[ "$cols" =~ ^[0-9]+$ ]] || (( cols < 40 )); then
        cols=$(tput cols 2>/dev/null || echo 100)
    fi

    if ! [[ "$cols" =~ ^[0-9]+$ ]] || (( cols < 40 )); then
        cols=100
    fi

    echo "$cols"
}

print_driver_version_columns() {
    local start_option=$1
    local total=${#DRIVER_DISPLAY_VERSIONS[@]}
    local term_cols
    local max_label_len=0
    local index_width
    local cell_width
    local col_count
    local row_count
    local row
    local col
    local idx
    local option_num
    local driver_version
    local driver_label

    (( total == 0 )) && return 0

    term_cols=$(get_terminal_columns)
    for driver_version in "${DRIVER_DISPLAY_VERSIONS[@]}"; do
        driver_label="$driver_version"
        if [[ -n "${DRIVER_LIST_RECOMMENDED_VERSION:-}" && "$driver_version" == "$DRIVER_LIST_RECOMMENDED_VERSION" ]]; then
            driver_label="${driver_label} (推荐)"
        fi
        (( ${#driver_label} > max_label_len )) && max_label_len=${#driver_label}
    done

    index_width=${#start_option}
    option_num=$((start_option + total - 1))
    (( ${#option_num} > index_width )) && index_width=${#option_num}

    cell_width=$((index_width + max_label_len + 6))
    col_count=$((term_cols / cell_width))
    (( col_count < 1 )) && col_count=1
    (( col_count > total )) && col_count=$total
    row_count=$(((total + col_count - 1) / col_count))

    for ((row = 0; row < row_count; row++)); do
        for ((col = 0; col < col_count; col++)); do
            idx=$((col * row_count + row))
            (( idx >= total )) && continue

            option_num=$((start_option + idx))
            driver_label="${DRIVER_DISPLAY_VERSIONS[$idx]}"
            if [[ -n "${DRIVER_LIST_RECOMMENDED_VERSION:-}" && "$driver_label" == "$DRIVER_LIST_RECOMMENDED_VERSION" ]]; then
                driver_label="${driver_label} (推荐)"
            fi
            printf "  ${CYAN}%*d)${NC} %-*s" "$index_width" "$option_num" "$max_label_len" "$driver_label"
            if (( col < col_count - 1 )); then
                printf "  "
            fi
        done
        printf "\n"
    done
}

print_driver_selection_menu() {
    local total_drivers=${#DRIVER_DISPLAY_VERSIONS[@]}
    local option_label
    local direct_input_example

    print_section "选择 NVIDIA Driver 版本"
    if [[ -n "$MINIMUM_DRIVER_VERSION" ]]; then
        print_kv "兼容范围" "仅显示不低于 ${MINIMUM_DRIVER_VERSION} 的驱动"
    fi
    print_hint "超过 ${DRIVER_SELECT_TIMEOUT} 秒未选择，将默认安装 CUDA Toolkit 安装器自带驱动。"

    if (( total_drivers > 0 )); then
        print_kv "独立驱动列表" "共 ${total_drivers} 个，按终端宽度横向排列"
    else
        log_warn "没有找到可选的独立 NVIDIA Driver 安装器版本。"
    fi

    printf "  ${CYAN}%2d)${NC} ${BLUE}%s${NC}\n" 1 "返回上级菜单 (重新选择 CUDA)"
    printf "  ${CYAN}%2d)${NC} ${YELLOW}%s${NC}\n" 2 "不安装 NVIDIA Driver (仅安装 CUDA Toolkit)"
    if [[ -n "$RECOMMENDED_DRIVER_VERSION" ]]; then
        option_label="使用 CUDA Toolkit 安装器自带驱动 (推荐: ${RECOMMENDED_DRIVER_VERSION})"
    else
        option_label="使用 CUDA Toolkit 安装器自带驱动 (推荐)"
    fi
    printf "  ${CYAN}%2d)${NC} ${BOLD}${GREEN}%s${NC}\n" 3 "$option_label"

    print_driver_version_columns 4
    if (( total_drivers > 0 )); then
        direct_input_example=$(get_driver_direct_input_example)
        print_hint "也可以直接输入完整驱动版本号，例如: ${direct_input_example}"
    fi
}

choose_install_mode() {
    print_section "选择安装模式"
    printf "  ${CYAN}%2d)${NC} %s\n" 1 "安装 CUDA Toolkit (可选安装/更新 NVIDIA Driver)"
    printf "  ${CYAN}%2d)${NC} %s\n" 2 "仅安装 NVIDIA Driver (不安装 CUDA Toolkit)"

    while true; do
        INSTALL_MODE_INPUT=""
        if ! read -r -p "$(echo -e "${BOLD}${CYAN}请输入选项编号:${NC} ")" INSTALL_MODE_INPUT; then
            echo
            log_error "未读取到输入（EOF），已退出。"
            exit 1
        fi
        case "$INSTALL_MODE_INPUT" in
            1)
                INSTALL_MODE="cuda"
                print_kv "已选择安装模式" "安装 CUDA Toolkit"
                return 0
                ;;
            2)
                INSTALL_MODE="driver_only"
                print_kv "已选择安装模式" "仅安装 NVIDIA Driver"
                return 0
                ;;
            *)
                log_error "无效选项，请重新输入。"
                ;;
        esac
    done
}

print_driver_only_selection_menu() {
    local total_drivers=${#DRIVER_DISPLAY_VERSIONS[@]}
    local direct_input_example

    print_section "选择 NVIDIA Driver 版本"
    print_hint "当前模式: 仅安装 NVIDIA Driver，不安装 CUDA Toolkit。"
    if [[ -n "${DRIVER_ONLY_INSTALLED_CUDA:-}" ]]; then
        print_kv "当前 CUDA" "$DRIVER_ONLY_INSTALLED_CUDA"
    fi
    if [[ -n "${DRIVER_ONLY_MINIMUM_DRIVER:-}" ]]; then
        print_kv "兼容范围" "仅显示不低于 ${DRIVER_ONLY_MINIMUM_DRIVER} 的驱动"
    fi

    if (( total_drivers > 0 )); then
        print_kv "独立驱动列表" "共 ${total_drivers} 个，按终端宽度横向排列"
    else
        log_warn "没有找到可选的独立 NVIDIA Driver 安装器版本。"
    fi

    printf "  ${CYAN}%2d)${NC} ${BLUE}%s${NC}\n" 1 "返回安装模式选择"
    print_driver_version_columns 2
    if (( total_drivers > 0 )); then
        direct_input_example=$(get_driver_direct_input_example)
        print_hint "也可以直接输入完整驱动版本号，例如: ${direct_input_example}"
    fi
}

select_driver_only_flow() {
    print_section "获取 NVIDIA Driver 版本列表"
    if ! prepare_driver_only_driver_versions; then
        log_warn "无法生成仅兼容的 NVIDIA Driver 版本列表。"
        return 1
    fi

    while true; do
        print_driver_only_selection_menu

        DRIVER_INPUT=""
        if ! read -r -p "$(echo -e "${BOLD}${CYAN}请输入选项编号:${NC} ")" DRIVER_INPUT; then
            echo
            log_error "未读取到输入（EOF），已退出。"
            exit 1
        fi

        if driver_version_is_listed "$DRIVER_INPUT"; then
            select_archive_driver "$DRIVER_INPUT"
            print_driver_selection_result
            CONFIRM_DRIVER="yes"
            CUDA_VERSION=""
            FILENAME=""
            RECOMMENDED_DRIVER_VERSION=""
            MINIMUM_DRIVER_VERSION=""
            return 0
        fi

        if ! [[ "$DRIVER_INPUT" =~ ^[0-9]+$ ]]; then
            log_error "无效选项，请重新输入。"
            continue
        fi

        if (( DRIVER_INPUT == 1 )); then
            echo
            return 1
        elif (( DRIVER_INPUT >= 2 && DRIVER_INPUT < 2 + ${#DRIVER_DISPLAY_VERSIONS[@]} )); then
            DRIVER_SELECT_INDEX=$((DRIVER_INPUT - 2))
            select_archive_driver "${DRIVER_DISPLAY_VERSIONS[$DRIVER_SELECT_INDEX]}"
            print_driver_selection_result
            CONFIRM_DRIVER="yes"
            CUDA_VERSION=""
            FILENAME=""
            RECOMMENDED_DRIVER_VERSION=""
            MINIMUM_DRIVER_VERSION=""
            return 0
        else
            log_error "无效选项，请重新输入。"
        fi
    done
}

write_state_field() {
    local key=$1
    local value=$2

    value="${value//$'\r'/}"
    value="${value//$'\n'/}"
    printf "%s=%s\n" "$key" "$value"
}

save_install_state() {
    local filename=$1
    local driver_choice=$2
    local cuda_version=$3
    local driver_version=$4
    local driver_file=$5
    local driver_url=$6
    local recommended_driver=$7
    local driver_source=$8
    local minimum_driver=$9
    local install_mode=${10:-cuda}
    local temp_state="${STATE_FILE}.tmp"

    (
        umask 077
        {
            printf "# CUDA Install State Saved\n"
            write_state_field "SAVED_INSTALL_MODE" "$install_mode"
            write_state_field "SAVED_CUDA_VERSION" "$cuda_version"
            write_state_field "SAVED_FILENAME" "$filename"
            write_state_field "SAVED_DRIVER_CHOICE" "$driver_choice"
            write_state_field "SAVED_DRIVER_VERSION" "$driver_version"
            write_state_field "SAVED_DRIVER_FILE" "$driver_file"
            write_state_field "SAVED_DRIVER_URL" "$driver_url"
            write_state_field "SAVED_RECOMMENDED_DRIVER" "$recommended_driver"
            write_state_field "SAVED_DRIVER_SOURCE" "$driver_source"
            write_state_field "SAVED_MINIMUM_DRIVER" "$minimum_driver"
        } > "$temp_state"
    )

    chmod 600 "$temp_state"
    mv -f "$temp_state" "$STATE_FILE"
}

strip_legacy_state_quotes() {
    local value=$1

    if [[ "$value" == \"*\" ]]; then
        value="${value#\"}"
        value="${value%\"}"
    elif [[ "$value" == \'*\' ]]; then
        value="${value#\'}"
        value="${value%\'}"
    fi

    printf "%s" "$value"
}

load_install_state() {
    local key
    local value

    SAVED_INSTALL_MODE=""
    SAVED_CUDA_VERSION=""
    SAVED_FILENAME=""
    SAVED_DRIVER_CHOICE=""
    SAVED_DRIVER_VERSION=""
    SAVED_DRIVER_FILE=""
    SAVED_DRIVER_URL=""
    SAVED_RECOMMENDED_DRIVER=""
    SAVED_DRIVER_SOURCE=""
    SAVED_MINIMUM_DRIVER=""

    if [[ ! -r "$STATE_FILE" ]]; then
        log_error "状态文件不可读: ${STATE_FILE}"
        exit 1
    fi

    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        value="$(strip_legacy_state_quotes "$value")"

        case "$key" in
            SAVED_INSTALL_MODE) SAVED_INSTALL_MODE="$value" ;;
            SAVED_CUDA_VERSION) SAVED_CUDA_VERSION="$value" ;;
            SAVED_FILENAME) SAVED_FILENAME="$value" ;;
            SAVED_DRIVER_CHOICE) SAVED_DRIVER_CHOICE="$value" ;;
            SAVED_DRIVER_VERSION) SAVED_DRIVER_VERSION="$value" ;;
            SAVED_DRIVER_FILE) SAVED_DRIVER_FILE="$value" ;;
            SAVED_DRIVER_URL) SAVED_DRIVER_URL="$value" ;;
            SAVED_RECOMMENDED_DRIVER) SAVED_RECOMMENDED_DRIVER="$value" ;;
            SAVED_DRIVER_SOURCE) SAVED_DRIVER_SOURCE="$value" ;;
            SAVED_MINIMUM_DRIVER) SAVED_MINIMUM_DRIVER="$value" ;;
            *) log_warn "忽略未知状态字段: ${key}" ;;
        esac
    done < "$STATE_FILE"
}

validate_driver_source() {
    local source=$1

    [[ -z "$source" || "$source" == "cuda" || "$source" == "archive" ]]
}

validate_nvidia_driver_url() {
    local url=$1
    local expected_prefix="${NVIDIA_DRIVER_BASE_URL}/${NVIDIA_DRIVER_DIR}/"

    [[ -z "$url" || "$url" == "${expected_prefix}"* ]]
}

os_matches() {
    local expected=$1
    local os_tokens=" ${ID:-} ${ID_LIKE:-} "

    [[ "$os_tokens" == *" ${expected} "* ]]
}

refresh_initramfs() {
    if command -v update-initramfs &> /dev/null && { os_matches debian || os_matches ubuntu; }; then
        run_privileged update-initramfs -u
    elif command -v dracut &> /dev/null && { os_matches rhel || os_matches fedora || os_matches centos || os_matches ol || os_matches rocky || os_matches almalinux || os_matches suse; }; then
        run_privileged dracut --force
    elif command -v mkinitcpio &> /dev/null && os_matches arch; then
        run_privileged mkinitcpio -P
    elif command -v update-initramfs &> /dev/null; then
        log_warn "未能从 /etc/os-release 确认发行版族，使用已检测到的 update-initramfs。"
        run_privileged update-initramfs -u
    elif command -v dracut &> /dev/null; then
        log_warn "未能从 /etc/os-release 确认发行版族，使用已检测到的 dracut。"
        run_privileged dracut --force
    else
        log_error "无法找到 update-initramfs、dracut 或 mkinitcpio，请手动重新生成 initramfs 后再运行脚本。"
        exit 1
    fi
}

update_cuda_symlink() {
    local target=$1
    local link_path=$2
    local current_target
    local update_answer

    if [[ -e "$link_path" && ! -L "$link_path" ]]; then
        log_error "${link_path} 已存在且不是符号链接，自动覆盖可能破坏已有 CUDA 安装。请手动处理后重新运行。"
        exit 1
    fi

    if [[ -L "$link_path" ]]; then
        current_target=$(readlink -f "$link_path" 2>/dev/null || readlink "$link_path")
        print_kv "当前 CUDA 符号链接" "$current_target"
        print_kv "新的 CUDA 符号链接" "$target"

        if [[ "$current_target" != "$target" && -t 0 ]]; then
            if ! read -r -p "$(echo -e "${BOLD}是否更新 ${link_path} 指向新版本?${NC} ${YELLOW}(Y/n): ${NC}")" update_answer; then
                echo
                update_answer=""
                log_warn "未读取到输入，默认更新符号链接指向。"
            fi
            if [[ "$update_answer" =~ ^[nN] ]]; then
                log_warn "已保留现有 ${link_path} 指向。"
                return 0
            fi
        fi
    fi
    run_privileged ln -sfnT "$target" "$link_path"
}

cuda_env_block() {
    cat <<EOF
# Added by CUDA installer script
if [ -d "${SYMLINK_PATH}/bin" ]; then
    case ":\${PATH}:" in
        *":${SYMLINK_PATH}/bin:"*) ;;
        *) export PATH="${SYMLINK_PATH}/bin\${PATH:+:\${PATH}}" ;;
    esac
fi
if [ -d "${SYMLINK_PATH}/lib64" ]; then
    case ":\${LD_LIBRARY_PATH:-}:" in
        *":${SYMLINK_PATH}/lib64:"*) ;;
        *) export LD_LIBRARY_PATH="${SYMLINK_PATH}/lib64\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}" ;;
    esac
fi
EOF
}

get_login_shell_user() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        printf "%s" "$SUDO_USER"
    else
        id -un
    fi
}

get_user_home() {
    local user=$1
    local home_dir

    home_dir=$(getent passwd "$user" 2>/dev/null | awk -F: '{print $6}' || true)
    if [[ -n "$home_dir" ]]; then
        printf "%s" "$home_dir"
    elif [[ "$user" == "$(id -un)" ]]; then
        printf "%s" "${HOME:-}"
    fi
}

get_user_shell() {
    local user=$1
    local shell_path

    shell_path=$(getent passwd "$user" 2>/dev/null | awk -F: '{print $7}' || true)
    if [[ -n "$shell_path" ]]; then
        printf "%s" "$shell_path"
    else
        printf "%s" "${SHELL:-}"
    fi
}

append_cuda_env_to_rc() {
    local rc_file=$1
    local owner=${2:-}
    local marker="# Added by CUDA installer script"
    local rc_dir
    local owner_group

    rc_dir="$(dirname -- "$rc_file")"
    if [[ ! -d "$rc_dir" ]]; then
        log_warn "Shell 配置目录不存在，跳过写入: ${rc_dir}"
        return 0
    fi

    if [[ ! -e "$rc_file" ]]; then
        touch "$rc_file"
        if [[ "$(id -u)" -eq 0 && -n "$owner" ]]; then
            owner_group=$(id -gn "$owner" 2>/dev/null || true)
            if [[ -n "$owner_group" ]]; then
                chown "$owner:$owner_group" "$rc_file" || true
            fi
        fi
    fi

    if grep -qF "$marker" "$rc_file" && \
        grep -qF "${SYMLINK_PATH}/bin" "$rc_file" && \
        grep -qF "${SYMLINK_PATH}/lib64" "$rc_file"; then
        return 0
    fi

    {
        printf "\n"
        cuda_env_block
    } >> "$rc_file"
}

configure_cuda_environment() {
    local profile_file="/etc/profile.d/cuda.sh"
    local shell_user
    local shell_home
    local shell_path

    cuda_env_block | run_privileged tee "$profile_file" >/dev/null
    run_privileged chmod 644 "$profile_file"

    shell_user=$(get_login_shell_user)
    shell_home=$(get_user_home "$shell_user")
    shell_path=$(get_user_shell "$shell_user")

    if [[ -n "$shell_home" ]]; then
        print_kv "用户 Shell 配置目标" "${shell_user}:${shell_home}"
        append_cuda_env_to_rc "$shell_home/.bashrc" "$shell_user"
        if [[ "$shell_path" == */zsh || -f "$shell_home/.zshrc" ]]; then
            append_cuda_env_to_rc "$shell_home/.zshrc" "$shell_user"
        fi
    else
        log_warn "无法确定 ${shell_user} 的 home 目录，已跳过用户级 shell 配置；系统级 ${profile_file} 已写入。"
    fi
}

print_command_output() {
    local output=$1

    printf "%s\n" "$output" | sed 's/^/    /'
}

extract_nvcc_cuda_version() {
    local output=$1

    printf "%s\n" "$output" | \
        grep -oE "release [0-9]+\.[0-9]+" | \
        head -1 | \
        grep -oE "[0-9]+\.[0-9]+" || true
}

extract_nvidia_smi_cuda_version() {
    local output=$1

    printf "%s\n" "$output" | \
        grep -oE "CUDA Version:[[:space:]]*[0-9]+\.[0-9]+" | \
        head -1 | \
        grep -oE "[0-9]+\.[0-9]+" || true
}

verify_cuda_installation() {
    local profile_file="/etc/profile.d/cuda.sh"
    local nvcc_path
    local nvcc_output
    local nvcc_cuda_version=""
    local smi_path
    local smi_output
    local smi_cuda_version=""

    print_section "验证 CUDA 安装"

    if [[ -r "$profile_file" ]]; then
        # shellcheck source=/dev/null
        if source "$profile_file"; then
            hash -r 2>/dev/null || true
            log_success "已主动加载环境变量: source ${profile_file}"
        else
            log_warn "加载 ${profile_file} 失败，请手动执行 source ${profile_file} 后再验证。"
        fi
    else
        log_warn "未找到 ${profile_file}，请手动 source 对应 shell 配置后再验证。"
    fi

    if nvcc_path=$(command -v nvcc 2>/dev/null); then
        print_kv "nvcc 路径" "$nvcc_path"
        if nvcc_output=$("$nvcc_path" -V 2>&1); then
            log_success "nvcc -V 执行成功。"
            print_command_output "$nvcc_output"
            nvcc_cuda_version=$(extract_nvcc_cuda_version "$nvcc_output")
            [[ -n "$nvcc_cuda_version" ]] && print_kv "nvcc CUDA" "$nvcc_cuda_version"
        else
            log_warn "nvcc 已找到但无法执行。请重新下载并安装 CUDA Toolkit，或检查 ${SYMLINK_PATH}/bin 是否完整。"
            print_command_output "$nvcc_output"
        fi
    else
        log_warn "nvcc 无法执行或未在 PATH 中找到。请重新下载并安装 CUDA Toolkit，或执行 source ${profile_file} 后重试。"
    fi

    if smi_path=$(command -v nvidia-smi 2>/dev/null); then
        print_kv "nvidia-smi 路径" "$smi_path"
        if smi_output=$("$smi_path" 2>&1); then
            log_success "nvidia-smi 执行成功，NVIDIA 驱动已主动加载。"
            smi_cuda_version=$(extract_nvidia_smi_cuda_version "$smi_output")
            [[ -n "$smi_cuda_version" ]] && print_kv "nvidia-smi CUDA" "$smi_cuda_version"
        else
            log_warn "nvidia-smi 无法执行，NVIDIA 驱动可能尚未生效。请重启后再验证。"
            print_command_output "$smi_output"
        fi
    else
        log_warn "未找到 nvidia-smi。若本次需要安装 NVIDIA Driver，请确认驱动安装成功并重启后再验证。"
    fi

    if [[ -n "$nvcc_cuda_version" && -n "$smi_cuda_version" ]]; then
        # nvidia-smi 的 "CUDA Version" 是驱动支持的最高 CUDA 版本上限，
        # 而 nvcc -V 是实际安装的 Toolkit 版本，两者不同是正常现象（Toolkit 版本 <= 驱动上限）。
        # 只有在同次安装了驱动+Toolkit 后 Toolkit 版本应相同时，才需要重启重验证。
        # 因此这里只做提示性对比，不再误报 WARN。
        if [[ "$nvcc_cuda_version" == "$smi_cuda_version" ]]; then
            log_success "nvcc -V 与 nvidia-smi 显示的 CUDA 版本一致 (${nvcc_cuda_version})。"
        else
            # nvcc 版本低于驱动支持上限属于正常情况，仅作信息展示
            log_info "nvcc CUDA Toolkit: ${nvcc_cuda_version}，nvidia-smi 驱动支持上限: ${smi_cuda_version}（Toolkit 版本低于驱动上限属正常）。"
        fi
    fi
}

# 函数：读取内存中已加载的驱动版本。
# /proc/driver/nvidia/version 的实际格式为：
#   NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  580.65.06  Release Build ...
# 版本号前的措辞随驱动分支变化（Open Kernel Module / Kernel Module / x86_64 等），
# 因此不按固定措辞匹配，直接取该行首个 N.N 形式的版本号。
detect_loaded_driver_version() {
    local version=""

    if [[ -r /proc/driver/nvidia/version ]]; then
        version=$(grep -m1 -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' /proc/driver/nvidia/version 2>/dev/null | head -1)
    fi

    [[ -n "$version" ]] && echo "$version"
}

# 函数：检查磁盘上的 .ko 版本与内存中已加载驱动是否一致。
# 换驱动后若旧模块被重新加载，会出现 "Driver/library version mismatch"，
# 此时磁盘是新版、内存是旧版，必须重启才能生效。
check_driver_version_consistency() {
    local disk_version=""
    local loaded_version=""
    local ko_path

    ko_path=$(find "/lib/modules/$(uname -r)" -name 'nvidia.ko*' 2>/dev/null | head -1)
    [[ -z "$ko_path" ]] && return 0
    command -v modinfo &> /dev/null || return 0

    disk_version=$(modinfo -F version "$ko_path" 2>/dev/null || true)
    [[ -z "$disk_version" ]] && return 0

    loaded_version=$(detect_loaded_driver_version || true)

    # 模块未加载时无需比较，重启或首次 nvidia-smi 会加载新版
    [[ -z "$loaded_version" ]] && return 0

    if [[ "$disk_version" == "$loaded_version" ]]; then
        log_success "磁盘与内存中的驱动版本一致 (${disk_version})。"
        return 0
    fi

    log_warn "驱动版本不一致：磁盘 ${disk_version}，内存中仍是 ${loaded_version}。"
    print_hint "安装本身已完成，但旧模块仍驻留内存，nvidia-smi 会报 Driver/library version mismatch。"
    print_hint "必须重启系统才能加载新驱动: reboot"
    return 1
}

verify_nvidia_driver_installation() {
    local smi_path
    local smi_output
    local smi_cuda_version=""

    print_section "验证 NVIDIA Driver"

    check_driver_version_consistency || true

    if smi_path=$(command -v nvidia-smi 2>/dev/null); then
        print_kv "nvidia-smi 路径" "$smi_path"
        if smi_output=$("$smi_path" 2>&1); then
            log_success "nvidia-smi 执行成功，NVIDIA 驱动已主动加载。"
            smi_cuda_version=$(extract_nvidia_smi_cuda_version "$smi_output")
            [[ -n "$smi_cuda_version" ]] && print_kv "驱动支持的 CUDA" "$smi_cuda_version"
        else
            log_warn "nvidia-smi 无法执行，NVIDIA 驱动可能尚未生效。请重启后再验证。"
            print_command_output "$smi_output"
        fi
    else
        log_warn "未找到 nvidia-smi。请确认驱动安装成功并重启后再验证。"
    fi
}

kernel_headers_available() {
    local kernel_release

    kernel_release=$(uname -r)
    [[ -d "/lib/modules/${kernel_release}/build" ]] && return 0
    [[ -d "/usr/src/kernels/${kernel_release}" ]] && return 0
    [[ -d "/usr/src/linux-headers-${kernel_release}" ]] && return 0
    return 1
}

secure_boot_enabled() {
    local sb_state

    command -v mokutil &> /dev/null || return 1
    sb_state=$(mokutil --sb-state 2>/dev/null || true)
    [[ "$sb_state" =~ [Ee]nabled ]]
}

nvidia_modules_loaded() {
    [[ -r /proc/modules ]] || return 1
    awk '$1 ~ /^nvidia/ { found = 1 } END { exit !found }' /proc/modules
}

# 函数：识别容器环境。容器共享宿主机内核，内部无法安装/替换 NVIDIA 内核模块。
running_in_container() {
    local cgroup_content
    local virt_type

    [[ -f /.dockerenv ]] && return 0
    [[ -f /run/.containerenv ]] && return 0

    if [[ -r /proc/1/cgroup ]]; then
        cgroup_content=$(cat /proc/1/cgroup 2>/dev/null || true)
        if [[ "$cgroup_content" =~ (docker|lxc|kubepods|containerd|podman|/machine\.slice/) ]]; then
            return 0
        fi
    fi

    if command -v systemd-detect-virt &> /dev/null; then
        virt_type=$(systemd-detect-virt --container 2>/dev/null || true)
        [[ -n "$virt_type" && "$virt_type" != "none" ]] && return 0
    fi

    return 1
}

# 函数：仅凭 lspci 判断 NVIDIA 设备不可靠。精简镜像常缺少 pci.ids，
# 设备名会退化成裸 ID（A100 为 10de:20b0/20b1/20f1），字符串 nvidia 匹配不到。
nvidia_pci_device_present() {
    local lspci_output

    command -v lspci &> /dev/null || return 2

    lspci_output=$(lspci -nn 2>/dev/null || lspci 2>/dev/null || true)
    [[ -z "$lspci_output" ]] && return 2

    grep -qiE 'nvidia|\[10de:' <<< "$lspci_output" && return 0
    return 1
}

# 函数：GPU 已能用但 PCI 总线里看不到设备，基本只出现在容器直通/vGPU 场景。
gpu_visible_without_pci_device() {
    local pci_status=0

    nvidia_modules_loaded || return 1
    [[ -e /dev/nvidia0 || -e /dev/nvidiactl ]] || return 1

    nvidia_pci_device_present || pci_status=$?
    # 0=找到设备，2=无法判断，两种情况都不作为容器判据。
    [[ "$pci_status" -eq 1 ]]
}

DETECTED_GPU_NAMES=""
GPU_MINIMUM_DRIVER_VERSION=""
DETECTED_GPU_FLOOR_REASON=""

# GPU 架构驱动下限表：每行 "正则|驱动下限|说明"。
# 取值为该架构首个正式支持的 Linux 驱动分支，低于此版本装上后 nvidia-smi 认不出卡。
# 正则同时匹配 nvidia-smi 的型号名和 lspci -nn 的裸设备 ID（缺 pci.ids 时只有裸 ID）。
GPU_DRIVER_FLOOR_TABLE=(
    'A100|A800|10de:20(b0|b1|b2|b5|f1)~450.80.02~Ampere 数据中心 (A100/A800)'
    'A30|A40|A10[ -]|A16|A2[ -]|10de:20(b7|f0)|10de:2235|10de:2237~450.80.02~Ampere 数据中心 (A30/A40/A10)'
    'H100|H200|H800|10de:23(00|01|10|21|30|31|35)~525.60.13~Hopper (H100/H200/H800)'
    'L40|L40S|L4[ -]|10de:26(b5|b8|b9)~525.60.13~Ada 数据中心 (L40/L4)'
    'B100|B200|GB200|10de:29(00|01|41)~550.54.14~Blackwell 数据中心 (B100/B200)'
    'RTX 50[0-9][0-9]|10de:2b(85|87)|10de:2c(02|05)~570.86.16~Blackwell 消费级 (RTX 50 系)'
)

# 函数：在拿不到 CUDA 下限（不过滤）的分支里，至少按本机 GPU 架构下限过滤驱动列表。
apply_gpu_floor_to_driver_list() {
    [[ -z "$GPU_MINIMUM_DRIVER_VERSION" ]] && return 0

    mapfile -t DRIVER_DISPLAY_VERSIONS < <(filter_compatible_driver_versions "$GPU_MINIMUM_DRIVER_VERSION" "${DRIVER_DISPLAY_VERSIONS[@]}")
    DRIVER_ONLY_MINIMUM_DRIVER="$GPU_MINIMUM_DRIVER_VERSION"

    if [[ ${#DRIVER_DISPLAY_VERSIONS[@]} -eq 0 ]]; then
        log_error "没有找到满足本机 GPU 要求 (>=${GPU_MINIMUM_DRIVER_VERSION}) 的 NVIDIA Driver 版本。"
        return 1
    fi

    print_kv "本机 GPU 驱动下限" "${GPU_MINIMUM_DRIVER_VERSION}${DETECTED_GPU_NAMES:+ (${DETECTED_GPU_NAMES})}"
    return 0
}

# 函数：取 CUDA 通用下限与本机 GPU 下限中的较大值。
# CUDA release notes 的下限是全系通用值（CUDA 12.8 给 525.60.13），
# 数据中心卡自身的架构下限可能更高，直接用 CUDA 下限会把认不出卡的驱动也列出来。
raise_minimum_with_gpu_floor() {
    local cuda_minimum=$1

    if [[ -z "$GPU_MINIMUM_DRIVER_VERSION" ]]; then
        echo "$cuda_minimum"
        return 0
    fi

    if [[ -z "$cuda_minimum" ]]; then
        echo "$GPU_MINIMUM_DRIVER_VERSION"
        return 0
    fi

    if version_ge "$GPU_MINIMUM_DRIVER_VERSION" "$cuda_minimum"; then
        echo "$GPU_MINIMUM_DRIVER_VERSION"
    else
        echo "$cuda_minimum"
    fi
}

# 函数：识别本机 GPU 型号，并给出该型号的驱动版本下限。
# 数据中心卡的下限高于 CUDA release notes 的通用下限：CUDA 12.x 允许 525.60.13，
# 但 A100 需要 R450+、H100 需要 R525+，装低了 nvidia-smi 直接认不出卡。
detect_gpu_driver_floor() {
    local smi_names=""
    local lspci_output=""
    local combined=""
    local entry pattern rest floor label

    DETECTED_GPU_NAMES=""
    GPU_MINIMUM_DRIVER_VERSION=""
    DETECTED_GPU_FLOOR_REASON=""

    if command -v nvidia-smi &> /dev/null; then
        smi_names=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | sort -u | paste -sd', ' - || true)
    fi

    if command -v lspci &> /dev/null; then
        lspci_output=$(lspci -nn 2>/dev/null || true)
    fi

    combined="${smi_names} ${lspci_output}"
    DETECTED_GPU_NAMES="$smi_names"

    # 混插机器（如 A100 + H100）按最高下限取值，保证所有卡都能被识别。
    for entry in "${GPU_DRIVER_FLOOR_TABLE[@]}"; do
        pattern="${entry%%~*}"
        rest="${entry#*~}"
        floor="${rest%%~*}"
        label="${rest#*~}"

        grep -qiE "$pattern" <<< "$combined" || continue

        if [[ -z "$GPU_MINIMUM_DRIVER_VERSION" ]] || version_ge "$floor" "$GPU_MINIMUM_DRIVER_VERSION"; then
            GPU_MINIMUM_DRIVER_VERSION="$floor"
            DETECTED_GPU_FLOOR_REASON="$label"
        fi
    done

    return 0
}

# 函数：A100 SXM/HGX 通过 NVSwitch 互联，必须运行 nvidia-fabricmanager 且版本与驱动严格一致。
# 版本不匹配时 nvidia-smi 看着正常，但 CUDA 初始化会失败。
nvswitch_present() {
    local lspci_output

    [[ -d /proc/driver/nvidia-nvswitch/devices ]] && \
        [[ -n "$(ls -A /proc/driver/nvidia-nvswitch/devices 2>/dev/null || true)" ]] && return 0

    if command -v lspci &> /dev/null; then
        lspci_output=$(lspci -nn 2>/dev/null || true)
        grep -qiE 'nvswitch|10de:(1af1|22a3|22a4)' <<< "$lspci_output" && return 0
    fi

    return 1
}

fabricmanager_hint() {
    local driver_version=$1

    nvswitch_present || return 0

    local fm_service
    fm_service=$(detect_fabricmanager_service || echo "nvidia-fabricmanager")

    log_warn "检测到 NVSwitch（SXM/HGX 机型）。驱动变更后必须同步 fabricmanager，且版本要与驱动完全一致。"
    print_hint "版本不一致时 nvidia-smi 正常但 CUDA 初始化失败。参考命令:"
    print_hint "  systemctl stop ${fm_service}"
    if [[ -n "$driver_version" ]]; then
        print_hint "  apt-cache madison nvidia-fabricmanager-${driver_version%%.*}   # 先查源里的实际版本号"
        print_hint "  apt-get install -y nvidia-fabricmanager-${driver_version%%.*}=<上一步查到的版本>"
        print_hint "  dnf install -y nvidia-fabric-manager-${driver_version}         # RHEL 系"
    fi
    print_hint "  systemctl enable --now ${fm_service}"
    print_hint "  nvidia-smi -q | grep -i fabric   # 应显示 Success/Completed"
}

# 函数：列出正在占用 GPU 的进程，供卸载模块失败时定位。
list_gpu_processes() {
    local pids=""

    if command -v nvidia-smi &> /dev/null; then
        pids=$(nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader 2>/dev/null || true)
    fi

    if [[ -z "$pids" ]] && command -v lsof &> /dev/null; then
        pids=$(lsof -t /dev/nvidia* 2>/dev/null | sort -u | paste -sd' ' - || true)
    fi

    [[ -n "$pids" ]] && print_command_output "$pids"
}

# 函数：卸载已加载的 NVIDIA 内核模块。
# runfile 在检测到模块已加载时会追问"是否跳过完整性检查"，--silent 下该问题默认取
# Abort installation，安装直接失败。必须先把模块卸掉。
# 函数：带超时的确认提示，超时/无输入流时默认执行（返回 0）。
# read -t 超时返回 >128，EOF 返回 1，两者都按默认 yes 处理，
# 但分别给出不同提示，避免非交互运行时看不懂为什么自动继续了。
confirm_with_timeout() {
    local prompt=$1
    local timeout=$2
    local answer=""
    local rc=0

    read -r -t "$timeout" -p "$(echo -e "${BOLD}${prompt}${NC} ${YELLOW}(Y/n, ${timeout}秒后默认 Y): ${NC}")" answer || rc=$?

    if (( rc > 128 )); then
        echo
        log_warn "超过 ${timeout} 秒未确认，按默认继续。"
        return 0
    elif (( rc != 0 )); then
        echo
        log_warn "未读取到输入（非交互运行），按默认继续。"
        return 0
    fi

    # 直接回车也视为同意
    [[ -z "$answer" || "$answer" =~ ^[yY] ]]
}

# 函数：读取磁盘上已注册的 DKMS NVIDIA 驱动版本。
# runfile 装的驱动放在 /lib/modules/<kernel>/kernel/drivers/video/，
# DKMS 装的放在 /lib/modules/<kernel>/updates/dkms/ 且优先级更高。
# 两者版本不同时，新编的 nvidia.ko 会与残留的旧 nvidia-modeset.ko 冲突，
# 表现为 "Version mismatch" + "Kernel module load error: Device or resource busy"。
detect_dkms_nvidia_version() {
    local status_line

    command -v dkms &> /dev/null || return 1

    status_line=$(dkms status 2>/dev/null | grep -E '^nvidia/' | head -1 || true)
    [[ -z "$status_line" ]] && return 1

    # 形如 "nvidia/610.57.04, 6.8.0-88-generic, x86_64: installed"
    sed -E 's#^nvidia/([^,]+),.*#\1#' <<< "$status_line"
}

# 函数：runfile 安装驱动前，移除版本不同的 DKMS 注册，避免模块版本冲突。
remove_conflicting_dkms_driver() {
    local target_version=$1
    local dkms_version

    [[ -z "$target_version" || ! "$target_version" =~ ^[0-9] ]] && return 0

    dkms_version=$(detect_dkms_nvidia_version) || return 0
    [[ -z "$dkms_version" ]] && return 0

    if [[ "$dkms_version" == "$target_version" ]]; then
        log_info "DKMS 已注册同版本驱动 ${dkms_version}，无需处理。"
        return 0
    fi

    print_section "检测到 DKMS 驱动版本冲突"
    print_kv "DKMS 已注册" "$dkms_version"
    print_kv "本次要安装" "$target_version"
    log_warn "DKMS 模块位于 updates/dkms/ 且优先级高于 runfile 安装位置。"
    print_hint "不移除会导致新模块加载失败: Version mismatch + Device or resource busy。"

    case "$REMOVE_CONFLICTING_DKMS" in
        0)
            log_warn "REMOVE_CONFLICTING_DKMS=0，保留 DKMS 注册。驱动安装大概率失败。"
            return 0
            ;;
        1) ;;
        *)
            print_hint "移除 DKMS 注册会删除现有 ${dkms_version} 驱动的内核模块，期间 GPU 不可用。"
            print_hint "不移除则本次驱动安装必定失败，因此超时默认选择移除。"
            if ! confirm_with_timeout "是否移除 DKMS 驱动 ${dkms_version}?" "$DKMS_CONFIRM_TIMEOUT"; then
                log_error "已取消。请先手动处理 DKMS 驱动，或改用与 DKMS 相同的驱动版本。"
                print_hint "手动移除: dkms remove -m nvidia -v ${dkms_version} --all"
                exit 1
            fi
            ;;
    esac

    log_info "移除 DKMS 驱动: nvidia/${dkms_version}"
    if ! run_privileged dkms remove -m nvidia -v "$dkms_version" --all; then
        log_error "dkms remove 失败。请手动执行: dkms remove -m nvidia -v ${dkms_version} --all"
        exit 1
    fi

    log_success "DKMS 驱动 ${dkms_version} 已移除。"
}

# 函数：探测 fabricmanager 的 systemd 服务名。
# 各发行版命名不一致：nvidia-fabricmanager.service / nvidia-fabric-manager.service。
detect_fabricmanager_service() {
    local unit

    command -v systemctl &> /dev/null || return 1

    for unit in nvidia-fabricmanager nvidia-fabric-manager; do
        if systemctl list-unit-files "${unit}.service" &>/dev/null && \
           systemctl cat "${unit}.service" &>/dev/null; then
            echo "$unit"
            return 0
        fi
    done

    return 1
}

# 函数：探测已安装的 fabricmanager 版本。
# 包名在各发行版不统一，需要逐一尝试：
#   Ubuntu/Debian: nvidia-fabricmanager 或 nvidia-fabricmanager-<major>
#   RHEL 系:       nvidia-fabric-manager
# 版本号统一归一化为纯数字点分形式（剥掉 -1 / -0ubuntu0.24.04.1 之类后缀）。
detect_installed_fabricmanager_version() {
    local version=""
    local pkg

    if command -v dpkg-query &> /dev/null; then
        # 排除 -dev 包：它与主包版本相同，但主包才是服务的提供者
        for pkg in $(dpkg-query -W -f='${Package} ${Status}\n' 'nvidia-fabricmanager*' 2>/dev/null | \
                     awk '$NF == "installed" && $1 !~ /-dev/ {print $1}'); do
            version=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)
            [[ -n "$version" ]] && break
        done
    fi

    if [[ -z "$version" ]] && command -v rpm &> /dev/null; then
        version=$(rpm -q --qf '%{VERSION}\n' nvidia-fabric-manager 2>/dev/null | head -1 || true)
        [[ "$version" == *"not installed"* ]] && version=""
    fi

    [[ -z "$version" ]] && return 1

    # 归一化：580.65.06-1 -> 580.65.06；595.71.05-0ubuntu0.24.04.1 -> 595.71.05
    sed -E 's/^([0-9]+(\.[0-9]+)*).*/\1/' <<< "$version"
}

# 函数：在 apt 源里查出某个包实际可用的版本号。
# 各发行版/源的版本号格式差异很大，不能硬编码：
#   NVIDIA CUDA 源:      595.45.04-1
#   Ubuntu 官方 multiverse: 595.71.05-0ubuntu0.24.04.1
#   Debian 官方:          595.71.05-1~deb12u1
# 因此按"驱动版本前缀"匹配，取第一个候选。
apt_find_package_version() {
    local package=$1
    local version_prefix=$2
    local escaped

    command -v apt-cache &> /dev/null || return 1
    escaped="${version_prefix//./\\.}"

    # 只允许 Debian 版本修订分隔符（- ~ +）跟在完整版本号后，不含 '.'。
    # 否则传入 "580" 会误匹配 "580.105.08-1"，装上版本不符的包。
    apt-cache madison "$package" 2>/dev/null | \
        awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' | \
        grep -E "^${escaped}([-~+].*)?$" | \
        head -1
}

# 函数：列出某个 fabricmanager 包在源里的所有可用版本，便于报错时提示。
apt_list_package_versions() {
    local package=$1

    command -v apt-cache &> /dev/null || return 0
    apt-cache madison "$package" 2>/dev/null | \
        awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' | \
        head -5 | paste -sd', ' -
}

# 函数：读取 /usr/bin/nv-fabricmanager 二进制自报的版本。
# 这才是服务实际运行的版本。dpkg 包版本不可信：
# Ubuntu multiverse 的 nvidia-fabricmanager-<major> 新版本是空壳元包，
# 硬依赖 nvidia-fabricmanager-<更高major>，真正的二进制由后者提供。
# 例如 nvidia-fabricmanager-570=570.211.01 只含 changelog，
# 二进制来自 nvidia-fabricmanager-580=580.173.02，
# 而 fabricmanager 启动时严格校验接口版本，导致 570 驱动下必然失败。
detect_fabricmanager_binary_version() {
    local fm_bin="/usr/bin/nv-fabricmanager"
    local version=""

    [[ -x "$fm_bin" ]] || return 1

    version=$("$fm_bin" --version 2>/dev/null | \
        grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)

    [[ -n "$version" ]] && echo "$version"
}

# 函数：校验 fabricmanager 二进制版本是否与驱动一致。
# 一致返回 0；不一致返回 1 并说明原因，供调用方决定是否改走 .deb 直装。
fabricmanager_binary_matches_driver() {
    local driver_version=$1
    local bin_version

    bin_version=$(detect_fabricmanager_binary_version) || return 1
    [[ -z "$bin_version" ]] && return 1

    if [[ "$bin_version" == "$driver_version" ]]; then
        return 0
    fi

    log_warn "fabricmanager 二进制版本 ${bin_version} 与驱动 ${driver_version} 不一致。"
    print_hint "包管理器报告的版本可能只是元包版本；实际运行的是 ${bin_version}。"
    return 1
}

# 函数：apt 系统上安装 fabricmanager。
# 优先精确匹配完整驱动版本，其次匹配主版本分支，最后退回分支最新版。
install_fabricmanager_apt() {
    local driver_version=$1
    local driver_major=$2
    local package=""
    local candidate=""
    local available=""
    local try_pkg

    run_privileged apt-get update -qq || log_warn "apt-get update 失败，继续尝试安装。"

    # 包名两种形式都要试。NVIDIA CUDA 源用不带主版本号的 nvidia-fabricmanager
    # （版本形如 595.45.04-1ubuntu1），Ubuntu 官方源用 nvidia-fabricmanager-<major>
    # （版本形如 580.173.02-0ubuntu0.22.04.1）。CUDA 源版本更贴合 runfile 驱动，故优先。
    for try_pkg in "nvidia-fabricmanager" "nvidia-fabricmanager-${driver_major}"; do
        candidate=$(apt_find_package_version "$try_pkg" "$driver_version" || true)
        if [[ -n "$candidate" ]]; then
            package="$try_pkg"
            break
        fi
        [[ -z "$available" ]] && available=$(apt_list_package_versions "$try_pkg")
    done

    if [[ -z "$candidate" ]]; then
        if [[ -z "$available" ]]; then
            log_error "apt 源中找不到 fabricmanager 包（已尝试 nvidia-fabricmanager-${driver_major} 与 nvidia-fabricmanager）。"
            print_hint "该分支可能需要 NVIDIA CUDA apt 源，请先配置对应发行版的仓库。"
            return 1
        fi
        log_warn "源索引中没有与驱动 ${driver_version} 版本一致的 fabricmanager。"
        print_kv "源中可用版本" "$available"
        # 源索引只收录部分版本，但仓库里往往仍保留对应 .deb 直链，
        # 因此索引查不到时再尝试直接下载安装，而不是直接放弃。
        if install_fabricmanager_deb "$driver_version"; then
            return 0
        fi
        log_error "无法获得与驱动 ${driver_version} 匹配的 fabricmanager。"
        print_hint "fabricmanager 与驱动必须严格同版本，装不一致的版本仍会导致 CUDA 初始化失败。"
        print_hint "两个可行方向："
        print_hint "  1) 改装与源中 fabricmanager 版本一致的驱动版本；"
        print_hint "  2) 手动下载对应 .deb 后执行 dpkg -i 安装。"
        return 1
    fi

    log_info "源中匹配到 ${package} = ${candidate}"
    if ! run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --allow-downgrades "${package}=${candidate}"; then
        log_error "安装 ${package}=${candidate} 失败。"
        return 1
    fi

    # 关键校验：包版本对上不代表二进制对上。
    # Ubuntu multiverse 的 nvidia-fabricmanager-<major> 新版是空壳元包，
    # 硬依赖更高 major 的包来提供 /usr/bin/nv-fabricmanager，
    # 装完后实际二进制版本与驱动不符，服务启动时接口校验必然失败。
    if fabricmanager_binary_matches_driver "$driver_version"; then
        log_success "fabricmanager ${candidate} 安装成功，二进制版本与驱动一致。"
        return 0
    fi

    log_warn "apt 安装的 fabricmanager 二进制版本与驱动不匹配，改从 NVIDIA 官方仓库直装 .deb。"
    print_hint "原因：发行版源里的 ${package} 可能是空壳元包，二进制由更高版本的依赖包提供。"

    if install_fabricmanager_deb "$driver_version" && \
       fabricmanager_binary_matches_driver "$driver_version"; then
        log_success "已从 NVIDIA 官方仓库获得与驱动 ${driver_version} 一致的 fabricmanager。"
        return 0
    fi

    log_error "无法获得与驱动 ${driver_version} 二进制版本一致的 fabricmanager。"
    print_hint "当前二进制版本: $(detect_fabricmanager_binary_version || echo 未知)"
    print_hint "fabricmanager 启动时严格校验驱动接口版本，不一致时 NVLink 不可用。"
    print_hint "两个可行方向："
    print_hint "  1) 改装与 fabricmanager 二进制版本一致的驱动版本；"
    print_hint "  2) 从 https://developer.download.nvidia.com/compute/cuda/repos/ 手动下载对应 .deb。"
    return 1
}

# 函数：推导本机对应的 NVIDIA CUDA 仓库路径（如 ubuntu2204/x86_64）。
# 仅支持官方实际提供的组合：Ubuntu 有 x86_64/sbsa/arm64，Debian 无 arm64。
nvidia_repo_path() {
    local distro=""
    local arch=""

    [[ -r /etc/os-release ]] || return 1
    # shellcheck disable=SC1091
    . /etc/os-release

    case "${ID:-}" in
        ubuntu) distro="ubuntu${VERSION_ID//./}" ;;
        debian) distro="debian${VERSION_ID%%.*}" ;;
        *) return 1 ;;
    esac

    case "$(uname -m)" in
        x86_64) arch="x86_64" ;;
        aarch64)
            # Ubuntu 同时提供 sbsa 与 arm64，服务器卡走 sbsa；Debian 只有 sbsa
            arch="sbsa"
            ;;
        *) return 1 ;;
    esac

    echo "${distro}/${arch}"
}

# 函数：从 NVIDIA 仓库的 Packages 索引里查出指定驱动版本对应的 .deb 相对路径。
# 不能靠拼后缀猜文件名：实际仓库里后缀至少有 -1、-1ubuntu1、-0ubuntu1、-2ubuntu1 四种，
# 且同一分支内混用（如 580.126.20-1 与 580.159.03-1ubuntu1）。
# 包名也有 nvidia-fabricmanager 与 nvidia-fabricmanager-<major> 两种形式。
# 因此直接解析索引取权威的 Filename 字段。
nvidia_repo_find_deb() {
    local repo_path=$1
    local driver_version=$2
    local driver_major="${driver_version%%.*}"
    local index_url="https://developer.download.nvidia.com/compute/cuda/repos/${repo_path}/Packages.gz"
    local index_file="${DOWNLOAD_DIR}/.nvidia-repo-Packages.gz"
    local result=""

    # 索引约 3MB，缓存复用避免重复下载
    if [[ ! -s "$index_file" ]]; then
        if ! metadata_wget -qO "$index_file" "$index_url" 2>/dev/null; then
            rm -f -- "$index_file"
            return 1
        fi
    fi

    # 按 stanza 解析：只认包名精确匹配且版本号以目标版本开头（后缀任意）的条目，
    # 并排除 -dev 包。优先不带主版本号后缀的包名。
    result=$(gzip -dc "$index_file" 2>/dev/null | awk -v ver="$driver_version" -v maj="$driver_major" '
        /^Package:/ { pkg = $2; version = ""; fname = "" }
        /^Version:/ { version = $2 }
        /^Filename:/ {
            fname = $2
            if (pkg !~ /-dev/ && (pkg == "nvidia-fabricmanager" || pkg == "nvidia-fabricmanager-" maj)) {
                # 版本必须是 <ver> 或 <ver><Debian修订分隔符>，不能是 <ver>.<更多数字>
                if (version == ver || index(version, ver "-") == 1 || \
                    index(version, ver "~") == 1 || index(version, ver "+") == 1) {
                    prio = (pkg == "nvidia-fabricmanager") ? 1 : 2
                    if (best == "" || prio < bestprio) { best = fname; bestprio = prio; bestver = version }
                }
            }
        }
        END { if (best != "") print best "\t" bestver }
    ')

    [[ -z "$result" ]] && return 1
    echo "$result"
}

# 函数：源索引查不到精确版本时，直接从 NVIDIA 仓库下载 .deb 安装。
# 新包 Conflicts/Replaces 旧的 nvidia-fabricmanager-<major>，dpkg -i 会自动替换。
install_fabricmanager_deb() {
    local driver_version=$1
    local repo_path
    local found=""
    local deb_rel=""
    local deb_ver=""
    local deb_file
    local deb_url
    local deb_path

    command -v dpkg &> /dev/null || return 1

    repo_path=$(nvidia_repo_path) || {
        log_warn "无法推导本机对应的 NVIDIA 仓库路径，跳过 .deb 安装。"
        return 1
    }

    print_section "尝试从 NVIDIA 仓库直接安装 fabricmanager .deb"
    print_kv "仓库路径" "$repo_path"

    found=$(nvidia_repo_find_deb "$repo_path" "$driver_version") || {
        log_warn "仓库索引中找不到驱动 ${driver_version} 对应的 fabricmanager .deb，尝试直接拼接 URL 下载。"
        # 索引可能有缓存延迟或条目缺失，按惯例命名规则直接尝试下载。
        # NVIDIA 官方仓库命名规则：nvidia-fabricmanager-<major>_<version>-1_amd64.deb
        local driver_major_fb="${driver_version%%.*}"
        local direct_deb="nvidia-fabricmanager-${driver_major_fb}_${driver_version}-1_amd64.deb"
        local direct_url="https://developer.download.nvidia.com/compute/cuda/repos/${repo_path}/${direct_deb}"
        local direct_path="${DOWNLOAD_DIR}/${direct_deb}"
        log_info "尝试直接下载: ${direct_url}"
        if download_file "$direct_url" "$direct_deb"; then
            found="${direct_deb}"$'\t'"${driver_version}-1"
            log_success "直接下载成功，将使用该文件安装。"
        else
            rm -f -- "$direct_path" 2>/dev/null || true
            return 1
        fi
    }

    deb_rel="${found%%$'\t'*}"
    deb_ver="${found##*$'\t'}"
    deb_rel="${deb_rel#./}"
    deb_file="$(basename -- "$deb_rel")"
    deb_url="https://developer.download.nvidia.com/compute/cuda/repos/${repo_path}/${deb_rel}"

    if [[ -f "${DOWNLOAD_DIR}/${deb_file}" ]]; then
        print_kv "匹配到" "${deb_file} (版本 ${deb_ver})"
    else
        print_kv "索引中匹配到" "${deb_file} (版本 ${deb_ver})"
    fi

    deb_path="${DOWNLOAD_DIR}/${deb_file}"
    if ! download_file "$deb_url" "$deb_file"; then
        log_warn "下载 ${deb_file} 失败。"
        return 1
    fi

    if run_privileged dpkg -i "$deb_path"; then
        log_success "fabricmanager ${deb_ver} 安装成功（.deb 直装）。"
        rm -f -- "$deb_path"
        return 0
    fi

    # dpkg -i 失败时，检查是否因为发行版源安装的"空壳+高 major 依赖"包与真包冲突。
    # 典型场景：ubuntu multiverse 的 nvidia-fabricmanager-570=570.211.01 依赖
    # nvidia-fabricmanager-580，后者声明 Provides/Conflicts: nvidia-fabricmanager，
    # 而官方真包 nvidia-fabricmanager-570_570.211.01-1 也 Provides nvidia-fabricmanager，
    # dpkg 报 "conflicts with nvidia-fabricmanager"（虚拟包名）。
    # 必须找出当前 Provides nvidia-fabricmanager 的已装实包，移除后再重装。
    local conflicting_pkg=""
    conflicting_pkg=$(dpkg -l 'nvidia-fabricmanager-*' 2>/dev/null | \
        awk '/^ii/{print $2}' | \
        while read -r pkg; do
            # 排除目标包自身（可能已装了旧版本）
            [[ "$pkg" == "$(dpkg -I "$deb_path" 2>/dev/null | grep '^Package' | awk '{print $2}')" ]] && continue
            # 检查该包是否声明 Provides: nvidia-fabricmanager
            if dpkg -s "$pkg" 2>/dev/null | grep -qE "^Provides:.*nvidia-fabricmanager([, ]|$)"; then
                echo "$pkg"
            fi
        done | head -1 || true)

    if [[ -n "$conflicting_pkg" ]]; then
        log_info "检测到冲突包 ${conflicting_pkg}（Provides: nvidia-fabricmanager），先移除再安装正确版本。"
        if run_privileged env DEBIAN_FRONTEND=noninteractive apt-get remove -y "$conflicting_pkg"; then
            if run_privileged dpkg -i "$deb_path"; then
                log_success "fabricmanager ${deb_ver} 安装成功（移除冲突包后直装）。"
                rm -f -- "$deb_path"
                return 0
            fi
        else
            log_warn "移除冲突包 ${conflicting_pkg} 失败，尝试 apt-get -f install 修复依赖。"
        fi
    fi

    log_warn "dpkg -i 失败，尝试用 apt-get -f install 修复依赖。"
    if run_privileged env DEBIAN_FRONTEND=noninteractive apt-get -f install -y; then
        log_success "依赖修复完成，fabricmanager ${deb_ver} 已安装。"
        rm -f -- "$deb_path"
        return 0
    fi

    rm -f -- "$deb_path"
    return 1
}

# 函数：RHEL 系上安装 fabricmanager。
install_fabricmanager_rpm() {
    local driver_version=$1
    local driver_major=$2
    local pkg_mgr="dnf"
    local candidate=""

    command -v dnf &> /dev/null || pkg_mgr="yum"

    # RHEL 系包名为 nvidia-fabric-manager（带连字符），版本形如 595.45.04-1
    candidate=$($pkg_mgr list --showduplicates nvidia-fabric-manager 2>/dev/null | \
        awk '/nvidia-fabric-manager/ {print $2}' | \
        grep -E "^${driver_version//./\\.}" | head -1 || true)

    if [[ -n "$candidate" ]]; then
        log_info "源中匹配到版本: ${candidate}"
        if run_privileged "$pkg_mgr" install -y "nvidia-fabric-manager-${candidate}"; then
            log_success "fabricmanager ${candidate} 安装成功。"
            return 0
        fi
        log_warn "按精确版本安装失败，改用版本号直接指定。"
    fi

    if ! run_privileged "$pkg_mgr" install -y "nvidia-fabric-manager-${driver_version}"; then
        log_error "fabricmanager 安装失败。"
        print_hint "手动执行: ${pkg_mgr} install -y nvidia-fabric-manager-${driver_version}"
        print_hint "若源中无此版本，可能需要配置 NVIDIA CUDA 仓库。"
        return 1
    fi

    log_success "fabricmanager ${driver_version} 安装成功。"
}

# 函数：安装与驱动版本匹配的 fabricmanager。
install_matching_fabricmanager() {
    local driver_version=$1
    local driver_major=$2

    print_section "安装匹配的 nvidia-fabricmanager ${driver_version}"

    if command -v apt-get &> /dev/null; then
        install_fabricmanager_apt "$driver_version" "$driver_major" || return 1
    elif command -v dnf &> /dev/null || command -v yum &> /dev/null; then
        install_fabricmanager_rpm "$driver_version" "$driver_major" || return 1
    else
        log_warn "未识别的包管理器，无法自动安装 fabricmanager。"
        print_hint "请手动安装与驱动 ${driver_version} 版本一致的 fabricmanager。"
        return 1
    fi

    local fm_service
    fm_service=$(detect_fabricmanager_service || true)

    if [[ -n "$fm_service" ]] && command -v systemctl &> /dev/null; then
        # prerm 脚本（deb-systemd-invoke）在移除旧包时可能会重新 mask 服务，
        # enable/start 前必须先 unmask，否则会报 "Unit file is masked"。
        run_privileged systemctl unmask "$fm_service" 2>/dev/null || true
        run_privileged systemctl enable "$fm_service" || log_warn "enable ${fm_service} 失败。"
        if run_privileged systemctl start "$fm_service"; then
            log_success "${fm_service} 已启动。"
        else
            log_warn "启动 ${fm_service} 失败。"
            diagnose_fabricmanager_failure "$fm_service"
        fi
    fi
}

# 函数：fabricmanager 启动失败时，从日志里提取根因给出可执行建议。
# 最常见的失败是驱动接口版本不匹配，且只能通过重启解决。
diagnose_fabricmanager_failure() {
    local fm_service=$1
    local log_tail=""

    command -v journalctl &> /dev/null || {
        print_hint "请检查: systemctl status ${fm_service}"
        return 0
    }

    log_tail=$(journalctl -u "$fm_service" -n 20 --no-pager 2>/dev/null || true)
    [[ -z "$log_tail" ]] && { print_hint "请检查: systemctl status ${fm_service}"; return 0; }

    if grep -q "don't match with driver version" <<< "$log_tail"; then
        log_error "fabricmanager 与内存中的驱动接口版本不匹配。"
        print_command_output "$(grep -m1 "don't match with driver version" <<< "$log_tail")"
        print_hint "这是因为新驱动已装到磁盘，但旧驱动模块仍驻留内存。"
        print_hint "重启系统后 fabricmanager 会自动启动成功: reboot"
        DRIVER_NEEDS_REBOOT=1
        return 0
    fi

    if grep -qiE "no such file|not found.*topology|failed to open" <<< "$log_tail"; then
        log_error "fabricmanager 缺少拓扑文件，通常是包与驱动版本不配套。"
        print_hint "请确认 fabricmanager 与驱动为同一版本。"
        return 0
    fi

    print_hint "服务日志尾部："
    print_command_output "$(tail -6 <<< "$log_tail")"
    print_hint "完整日志: journalctl -u ${fm_service} -n 50"
}

# 函数：NVLink 机型安装完成后，校验 NVLink 是否真正可用。
# 版本号一致、服务 active 都不等于 NVLink 通了，必须看实际链路状态。
verify_nvlink_operational() {
    local fm_service
    local nvlink_output=""
    local inactive_count=0

    nvswitch_present || return 0
    command -v nvidia-smi &> /dev/null || return 0

    print_section "校验 NVLink 工作状态"

    fm_service=$(detect_fabricmanager_service || true)
    if [[ -n "$fm_service" ]] && command -v systemctl &> /dev/null; then
        if systemctl is-active --quiet "$fm_service" 2>/dev/null; then
            log_success "${fm_service} 运行中。"
        else
            log_warn "${fm_service} 未运行，多卡 NVLink 通信不可用。"
            diagnose_fabricmanager_failure "$fm_service"
            return 1
        fi
    fi

    nvlink_output=$(nvidia-smi nvlink --status 2>&1 || true)

    if grep -qi "inactive\|error" <<< "$nvlink_output"; then
        inactive_count=$(grep -ci "inactive" <<< "$nvlink_output" || true)
        log_warn "检测到 ${inactive_count} 条 NVLink 链路未激活。"
        print_hint "完整状态: nvidia-smi nvlink --status"
        return 1
    fi

    if grep -qE 'Link [0-9]+: [0-9]' <<< "$nvlink_output"; then
        log_success "NVLink 链路已激活（$(grep -cE 'Link [0-9]+: [0-9]' <<< "$nvlink_output") 条）。"
        return 0
    fi

    log_warn "未能读取到 NVLink 链路状态，请手动确认: nvidia-smi nvlink --status"
    return 1
}

# 函数：检查 fabricmanager 与驱动版本是否一致，必要时自动修复。
# NVSwitch 机型上版本不一致会导致 nvidia-smi 正常但 CUDA 初始化失败。
verify_and_fix_fabricmanager() {
    local driver_version=$1
    local fm_version=""
    local driver_major
    local loaded_driver=""
    local fm_service_name=""

    nvswitch_present || return 0
    [[ -z "$driver_version" || ! "$driver_version" =~ ^[0-9] ]] && return 0

    fm_version=$(detect_installed_fabricmanager_version || true)
    driver_major="${driver_version%%.*}"
    fm_service_name=$(detect_fabricmanager_service || echo "nvidia-fabricmanager")

    # fabricmanager 校验的是"内存中驱动的接口版本"，不是 apt 包版本。
    # 包版本对上但旧模块仍驻留内存时，服务会以下面这句失败：
    #   fabric manager NVIDIA GPU driver interface version X don't match with driver version Y
    # 这种情况只能靠重启解决，先在这里明确指出，避免误判为包版本问题。
    loaded_driver=$(detect_loaded_driver_version || true)
    if [[ -n "$loaded_driver" && "$loaded_driver" != "$driver_version" ]]; then
        log_warn "内存中的驱动为 ${loaded_driver}，与本次安装的 ${driver_version} 不一致。"
        print_hint "fabricmanager 按内存中的驱动接口版本校验，重启前它无法启动成功。"
        print_hint "请先重启系统，再确认 fabricmanager 状态: systemctl status ${fm_service_name:-nvidia-fabricmanager}"
        DRIVER_NEEDS_REBOOT=1
    fi

    if [[ -z "$fm_version" ]]; then
        log_warn "检测到 NVSwitch 但未安装 fabricmanager，多卡 NVLink 通信将不可用。"
        case "$FIX_FABRICMANAGER" in
            0) print_hint "FIX_FABRICMANAGER=0，跳过安装。" ; return 0 ;;
            1) ;;
            *)
                if ! confirm_with_timeout "是否安装 fabricmanager ${driver_version}?" "$FABRICMANAGER_CONFIRM_TIMEOUT"; then
                    print_hint "已跳过。可稍后手动安装与驱动同版本的 fabricmanager。"
                    return 0
                fi
                ;;
        esac
        install_matching_fabricmanager "$driver_version" "$driver_major" || true
        return 0
    fi

    fm_version="${fm_version%%-*}"

    print_section "检查 fabricmanager 与驱动版本一致性"
    print_kv "fabricmanager 包版本" "$fm_version"
    print_kv "驱动版本" "$driver_version"

    # 即使包版本一致，也要校验实际二进制版本。
    # Ubuntu multiverse 的 nvidia-fabricmanager-<N> 新版可能是空壳元包，
    # 真正的 /usr/bin/nv-fabricmanager 二进制由更高 major 的依赖包提供，
    # fabricmanager 启动时严格校验接口版本，二进制版本 != 驱动版本时必然失败。
    local fm_bin_version=""
    fm_bin_version=$(detect_fabricmanager_binary_version || true)
    if [[ -n "$fm_bin_version" ]]; then
        print_kv "fabricmanager 二进制版本" "$fm_bin_version"
    fi

    if [[ "$fm_version" == "$driver_version" && \
          ( -z "$fm_bin_version" || "$fm_bin_version" == "$driver_version" ) ]]; then
        log_success "fabricmanager 与驱动版本一致。"
        # 确保服务未被历史运行残留的 mask 阻挡
        local fm_svc
        fm_svc=$(detect_fabricmanager_service || true)
        if [[ -n "$fm_svc" ]] && command -v systemctl &>/dev/null; then
            run_privileged systemctl unmask "$fm_svc" 2>/dev/null || true
            if ! systemctl is-active --quiet "$fm_svc" 2>/dev/null; then
                run_privileged systemctl enable "$fm_svc" 2>/dev/null || true
                if run_privileged systemctl start "$fm_svc" 2>/dev/null; then
                    log_success "${fm_svc} 已启动。"
                else
                    diagnose_fabricmanager_failure "$fm_svc"
                fi
            fi
        fi
        return 0
    fi

    # 包版本一致但二进制版本不符——空壳元包场景，需要重新安装
    if [[ "$fm_version" == "$driver_version" && -n "$fm_bin_version" && \
          "$fm_bin_version" != "$driver_version" ]]; then
        log_warn "fabricmanager 包版本 (${fm_version}) 与驱动一致，但实际二进制版本 (${fm_bin_version}) 不符。"
        print_hint "发行版包可能是元包，二进制由更高版本依赖包提供，将重新获取正确二进制。"
        case "$FIX_FABRICMANAGER" in
            0) print_hint "FIX_FABRICMANAGER=0，跳过修复。" ; return 0 ;;
            1) ;;
            *)
                if ! confirm_with_timeout "是否重新安装 fabricmanager ${driver_version} 正确二进制?" "$FABRICMANAGER_CONFIRM_TIMEOUT"; then
                    print_hint "已跳过。NVLink 通信将不可用直到二进制版本与驱动一致。"
                    return 0
                fi
                ;;
        esac
        install_matching_fabricmanager "$driver_version" "$driver_major" || true
        if [[ "$DRIVER_NEEDS_REBOOT" != "1" ]]; then
            verify_nvlink_operational || true
        fi
        return 0
    fi

    log_warn "fabricmanager (${fm_version}) 与驱动 (${driver_version}) 版本不一致，CUDA 初始化会失败。"

    case "$FIX_FABRICMANAGER" in
        0)
            print_hint "FIX_FABRICMANAGER=0，跳过修复。请手动处理。"
            return 0
            ;;
        1) ;;
        *)
            if ! confirm_with_timeout "是否自动安装匹配的 fabricmanager ${driver_version}?" "$FABRICMANAGER_CONFIRM_TIMEOUT"; then
                print_hint "已跳过。手动修复见上方提示。"
                return 0
            fi
            ;;
    esac

    install_matching_fabricmanager "$driver_version" "$driver_major" || true

    # 装完包不代表 NVLink 通了，实际校验一次
    if [[ "$DRIVER_NEEDS_REBOOT" != "1" ]]; then
        verify_nvlink_operational || true
    fi
}

STOPPED_NVIDIA_SERVICES=()
MASKED_NVIDIA_SERVICES=()
DISABLED_NVIDIA_SERVICES=()

# 函数：解除此前为防止服务自启而设置的 mask/disable。
unmask_nvidia_services() {
    local service

    command -v systemctl &> /dev/null || return 0

    for service in "${MASKED_NVIDIA_SERVICES[@]}"; do
        log_info "解除屏蔽: ${service}"
        run_privileged systemctl unmask "$service" || \
            log_warn "解除 ${service} 屏蔽失败，请手动执行: systemctl unmask ${service}"
    done
    MASKED_NVIDIA_SERVICES=()

    for service in "${DISABLED_NVIDIA_SERVICES[@]}"; do
        log_info "恢复自启: ${service}"
        run_privileged systemctl enable "$service" || \
            log_warn "恢复 ${service} 自启失败，请手动执行: systemctl enable ${service}"
    done
    DISABLED_NVIDIA_SERVICES=()
}

# 函数：恢复此前为卸载模块而停掉的服务。
# NVSwitch 机型上 fabricmanager 不运行会导致 CUDA 初始化失败，安装失败时必须还原。
restore_stopped_nvidia_services() {
    local service

    if [[ ${#STOPPED_NVIDIA_SERVICES[@]} -eq 0 && ${#MASKED_NVIDIA_SERVICES[@]} -eq 0 && \
          ${#DISABLED_NVIDIA_SERVICES[@]} -eq 0 ]]; then
        return 0
    fi
    command -v systemctl &> /dev/null || return 0

    print_section "恢复此前停止的 NVIDIA 服务"

    # 必须先 unmask，masked 状态下 start 会直接失败
    unmask_nvidia_services

    for service in "${STOPPED_NVIDIA_SERVICES[@]}"; do
        log_info "启动服务: ${service}"
        if ! run_privileged systemctl start "$service"; then
            log_warn "启动 ${service} 失败，请手动执行: systemctl start ${service}"
            print_hint "若刚更换驱动版本，该服务可能需要重启系统后才能启动。"
        fi
    done
    STOPPED_NVIDIA_SERVICES=()
}

# 函数：等待进程真正释放 /dev/nvidia* 句柄。
# systemctl stop 发出 SIGTERM 后，进程需要时间清理退出；
# nv-fabricmanager 在 A100 SXM HGX 上持有 8 张卡 + 6 块 NVSwitch 的句柄，
# 清理耗时可达 3-5 秒。stop 返回后立刻 rmmod 仍会遇到引用计数非零。
wait_nvidia_fds_released() {
    local timeout=${1:-30}
    local elapsed=0

    # 无 fuser 则跳过等待，直接依赖后续 rmmod 失败提示
    command -v fuser &> /dev/null || return 0

    while (( elapsed < timeout )); do
        if ! fuser /dev/nvidia* /dev/nvidiactl /dev/nvidia-nvswitch* \
                   /dev/nvidia-nvlink /dev/nvidia-uvm* \
                   /dev/nvidia-caps/* 2>/dev/null | grep -q .; then
            return 0
        fi
        sleep 1
        (( elapsed++ )) || true
    done

    log_warn "等待 ${timeout} 秒后仍有进程持有 /dev/nvidia* 句柄，尝试强制释放。"
    # 强杀所有还拿着句柄的进程（排除自身 $$）
    local pids
    pids=$(fuser /dev/nvidia* /dev/nvidiactl /dev/nvidia-nvswitch* \
                 /dev/nvidia-nvlink /dev/nvidia-uvm* \
                 /dev/nvidia-caps/* 2>/dev/null | tr ' ' '\n' | \
           grep -v "^$$\$" | sort -u || true)
    if [[ -n "$pids" ]]; then
        log_warn "强制终止以下进程: $(echo $pids)"
        echo "$pids" | xargs -r kill -9 2>/dev/null || true
        sleep 2
    fi
}

unload_nvidia_modules() {
    local service
    local module
    local remaining
    local udev_paused=0

    nvidia_modules_loaded || return 0

    if [[ "$UNLOAD_NVIDIA_MODULES" != "1" ]]; then
        log_warn "UNLOAD_NVIDIA_MODULES=0，跳过自动卸载。已加载的 NVIDIA 模块会导致 runfile 静默安装中止。"
        return 0
    fi

    print_section "卸载已加载的 NVIDIA 内核模块"
    print_hint "runfile 静默安装遇到已加载的模块会直接中止，需先卸载。"

    # 步骤0：最先暂停 udev 事件队列。
    # /lib/udev/rules.d/71-nvidia.rules 里有：
    #   ACTION=="add", DEVPATH=="/bus/pci/drivers/nvidia", RUN+="/sbin/modprobe nvidia-uvm"
    # 以及 fabricmanager 的 ExecStartPre 也会 modprobe nvidia-drm。
    # 任何 rmmod/stop 动作都可能触发 udev 事件或 Restart= 计时器，
    # 必须在所有操作之前就阻断自动重载，否则任何顺序都存在竞态窗口。
    if command -v udevadm &> /dev/null; then
        if run_privileged udevadm control --stop-exec-queue 2>/dev/null; then
            udev_paused=1
            log_info "已暂停 udev 事件队列，防止 rmmod 后模块被自动重新加载。"
        else
            log_warn "暂停 udev 事件队列失败，模块可能在 rmmod 后被自动重新加载。"
        fi
    fi

    if command -v systemctl &> /dev/null; then
        # 先 mask 再 stop：关闭 Restart= 竞态窗口。
        # 若先 stop 后 mask，systemd 的 Restart= 计时器会在两步之间触发重启，
        # fabricmanager 的 ExecStartPre 脚本会 modprobe nvidia-drm/nvidia-uvm，
        # 导致后续 rmmod 遇到引用计数非零而失败。
        for service in nvidia-fabricmanager nvidia-fabric-manager nvidia-persistenced \
                       nvidia-dcgm dcgm-exporter nvidia-gridd nvidia-imex; do
            # 未安装的单元直接跳过
            systemctl list-unit-files "${service}.service" &>/dev/null || continue
            systemctl cat "${service}.service" &>/dev/null || continue

            service_state=$(systemctl is-active "$service" 2>/dev/null || true)
            # inactive 且未 enabled 的服务不会自己起来，无需处理
            if [[ "$service_state" == "inactive" ]] && \
               ! systemctl is-enabled --quiet "$service" 2>/dev/null; then
                continue
            fi

            # 步骤1：先 mask（udev 已暂停，此刻 mask 生效前的窗口也已关闭）
            if run_privileged systemctl mask "$service" 2>/dev/null; then
                MASKED_NVIDIA_SERVICES+=("$service")
                log_info "已临时屏蔽 ${service}。"
            elif run_privileged systemctl disable "$service" 2>/dev/null; then
                DISABLED_NVIDIA_SERVICES+=("$service")
                log_info "mask 不可用，已临时禁用 ${service} 自启。"
            else
                log_warn "无法阻止 ${service} 自启，安装期间它可能重新加载旧模块。"
            fi

            # 步骤2：stop
            log_info "停止服务: ${service} (当前状态: ${service_state:-unknown})"
            if run_privileged systemctl stop "$service"; then
                STOPPED_NVIDIA_SERVICES+=("$service")
            else
                log_warn "停止 ${service} 失败，继续尝试卸载模块。"
            fi

            # 清掉 failed 状态
            run_privileged systemctl reset-failed "$service" 2>/dev/null || true
        done
    fi

    # 等待所有服务进程真正退出并释放 /dev/nvidia* 文件句柄。
    log_info "等待 NVIDIA 设备文件句柄完全释放..."
    wait_nvidia_fds_released 30
    log_info "设备句柄已释放，开始卸载内核模块。"

    # 依赖顺序：nvidia_uvm/nvidia_drm/nvidia_modeset 都引用 nvidia，必须先卸子模块。
    for module in nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia; do
        if awk -v m="$module" '$1 == m { found = 1 } END { exit !found }' /proc/modules 2>/dev/null; then
            log_info "卸载模块: ${module}"
            if ! run_privileged rmmod "$module" 2>/dev/null; then
                log_warn "rmmod ${module} 失败，可能仍有进程占用。"
            fi
        fi
    done

    # 注意：不在这里恢复 udev 队列。
    # rmmod nvidia 完成后 udev 有积压的 modprobe 事件（PCI 设备下线/上线触发），
    # 若此时恢复队列，udev 会立刻把 nvidia-uvm 等重新加载进来，
    # 紧接着的 nvidia_modules_loaded 检查就会误判为卸载失败。
    # 队列恢复放到检查通过之后，让安装器自行处理剩余 udev 事件。

    if nvidia_modules_loaded; then
        # 卸载失败，先恢复 udev 再退出，避免队列长时间阻塞
        if (( udev_paused == 1 )); then
            run_privileged udevadm control --start-exec-queue 2>/dev/null || true
            udev_paused=0
        fi
        remaining=$(awk '$1 ~ /^nvidia/ { printf "%s ", $1 }' /proc/modules 2>/dev/null || true)
        log_error "NVIDIA 内核模块仍在加载中: ${remaining}"
        print_hint "正在占用 GPU 的进程:"
        list_gpu_processes
        print_hint "请停止上述进程（或图形界面/容器）后重试；也可以重启系统再运行本脚本。"
        print_hint "确认要在模块加载状态下强行安装时，可设置 UNLOAD_NVIDIA_MODULES=0，但静默安装大概率仍会失败。"
        restore_stopped_nvidia_services
        exit 1
    fi

    # 卸载成功，现在恢复 udev 队列，安装器会接管后续 udev 操作
    if (( udev_paused == 1 )); then
        run_privileged udevadm control --start-exec-queue 2>/dev/null || \
            log_warn "恢复 udev 事件队列失败，请手动执行: udevadm control --start-exec-queue"
        udev_paused=0
    fi

    log_success "NVIDIA 内核模块已全部卸载。"
}

display_manager_active() {
    command -v systemctl &> /dev/null || return 1

    systemctl is-active --quiet display-manager 2>/dev/null && return 0
    systemctl is-active --quiet gdm 2>/dev/null && return 0
    systemctl is-active --quiet gdm3 2>/dev/null && return 0
    systemctl is-active --quiet lightdm 2>/dev/null && return 0
    systemctl is-active --quiet sddm 2>/dev/null && return 0
    systemctl is-active --quiet xdm 2>/dev/null && return 0
    return 1
}

# 函数：读取当前已加载/已装驱动的版本。
# /proc/driver/nvidia/version 只在模块已加载时存在，退回用 nvidia-smi 查询。
detect_installed_driver_version() {
    local version=""

    if [[ -r /proc/driver/nvidia/version ]]; then
        version=$(sed -nE 's/.*Kernel Module +([0-9][0-9.]*).*/\1/p' /proc/driver/nvidia/version 2>/dev/null | head -1)
    fi

    if [[ -z "$version" ]] && command -v nvidia-smi &> /dev/null; then
        version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
    fi

    [[ -n "$version" ]] && echo "$version"
}

preflight_nvidia_driver_install() {
    local failed=0
    local kernel_release
    local pci_status=0
    local installed_driver=""

    if [[ "$SKIP_DRIVER_PREFLIGHT" == "1" ]]; then
        log_warn "SKIP_DRIVER_PREFLIGHT=1，跳过 NVIDIA Driver 安装前检查。"
        return 0
    fi

    print_section "NVIDIA Driver 安装前检查"
    kernel_release=$(uname -r)

    if [[ "$ALLOW_CONTAINER_DRIVER_INSTALL" != "1" ]]; then
        if running_in_container; then
            log_error "检测到当前运行在容器内。容器共享宿主机内核，无法在容器里安装或替换 NVIDIA 内核模块。"
            print_hint "容器内的驱动由宿主机提供（nvidia-container-toolkit 注入），请在宿主机上安装驱动。"
            print_hint "容器内如需 nvcc，请选择安装模式 1 并跳过驱动（只装 CUDA Toolkit）。"
            print_hint "确认要强行尝试时可设置 ALLOW_CONTAINER_DRIVER_INSTALL=1。"
            exit 1
        fi

        if gpu_visible_without_pci_device; then
            log_error "检测到 NVIDIA 模块已加载且 /dev/nvidia* 存在，但 PCI 总线上找不到 NVIDIA 设备。"
            print_hint "这是容器 GPU 直通或 vGPU 的典型特征，驱动来自宿主机，容器内安装必定失败。"
            print_hint "容器内如需 nvcc，请选择安装模式 1 并跳过驱动（只装 CUDA Toolkit）。"
            print_hint "确认判断有误时可设置 ALLOW_CONTAINER_DRIVER_INSTALL=1 跳过此拦截。"
            exit 1
        fi
    fi

    if ! command -v gcc &> /dev/null; then
        log_error "未检测到 gcc，NVIDIA Driver runfile 通常需要编译内核模块。"
        failed=1
    fi

    if ! command -v make &> /dev/null; then
        log_error "未检测到 make，NVIDIA Driver runfile 通常需要编译内核模块。"
        failed=1
    fi

    if ! kernel_headers_available; then
        log_error "未检测到当前内核头文件/构建目录: ${kernel_release}"
        failed=1
    fi

    if secure_boot_enabled; then
        log_warn "检测到 Secure Boot 已启用。未签名的 NVIDIA 内核模块可能安装成功但无法加载。"
        print_hint "如安装后 nvidia-smi 失败，请关闭 Secure Boot 或按发行版流程签名内核模块。"
    fi

    nvidia_pci_device_present || pci_status=$?
    case "$pci_status" in
        1) log_warn "lspci 未发现 NVIDIA 设备。若本机确实没有 NVIDIA GPU（或虚机未直通显卡），驱动安装将失败。" ;;
        2) log_warn "lspci 不可用或无输出，跳过 NVIDIA GPU 存在性检查。" ;;
    esac

    detect_gpu_driver_floor
    if [[ -n "$DETECTED_GPU_NAMES" ]]; then
        print_kv "检测到 GPU" "$DETECTED_GPU_NAMES"
    fi

    # 已装驱动比本次要装的更新时提醒，避免无意义降级（降级还要拆 DKMS、停 GPU）。
    installed_driver=$(detect_installed_driver_version || true)
    if [[ -n "$installed_driver" && -n "$SELECTED_DRIVER_VERSION" && "$SELECTED_DRIVER_VERSION" =~ ^[0-9] ]]; then
        print_kv "当前已装驱动" "$installed_driver"
        if [[ "$installed_driver" != "$SELECTED_DRIVER_VERSION" ]] && version_ge "$installed_driver" "$SELECTED_DRIVER_VERSION"; then
            log_warn "已装驱动 ${installed_driver} 不低于本次要装的 ${SELECTED_DRIVER_VERSION}，这是一次降级。"
            print_hint "若只是为了装 CUDA Toolkit，通常无需动驱动：在驱动菜单选\"不安装 NVIDIA Driver\"即可。"
            print_hint "降级需要移除现有 DKMS 注册并卸载模块，期间 GPU 不可用。"
        fi
    fi

    if [[ -n "$GPU_MINIMUM_DRIVER_VERSION" && -n "$SELECTED_DRIVER_VERSION" && "$SELECTED_DRIVER_VERSION" =~ ^[0-9] ]]; then
        print_kv "本机 GPU 驱动下限" "$GPU_MINIMUM_DRIVER_VERSION"
        if ! version_ge "$SELECTED_DRIVER_VERSION" "$GPU_MINIMUM_DRIVER_VERSION"; then
            log_error "所选驱动 ${SELECTED_DRIVER_VERSION} 低于本机 GPU 要求的 ${GPU_MINIMUM_DRIVER_VERSION}，安装后无法识别显卡。"
            print_hint "CUDA release notes 给出的是通用下限，数据中心卡（A100/H100 等）下限更高，请改选更新的驱动。"
            failed=1
        fi
    fi

    if ! command -v dkms &> /dev/null; then
        log_warn "未检测到 dkms：驱动内核模块不会随内核升级自动重建，升级内核后需重新安装驱动。建议先安装 dkms 包。"
    fi

    if nvidia_modules_loaded; then
        log_warn "检测到 NVIDIA 内核模块已加载，安装前需要先卸载（脚本会自动处理）。"
    fi

    fabricmanager_hint "$SELECTED_DRIVER_VERSION"

    if display_manager_active; then
        log_warn "检测到图形登录服务可能正在运行。服务器安装/升级驱动时，如安装失败请切换到多用户模式或停止 display manager 后重试。"
    fi

    if (( failed != 0 )); then
        print_hint "请安装编译依赖和当前内核 headers 后重试；确认要自行处理时可设置 SKIP_DRIVER_PREFLIGHT=1 跳过此检查。"
        exit 1
    fi

    log_success "NVIDIA Driver 安装前检查通过。"
}

# 函数：选择 CUDA Toolkit runfile 自带的 NVIDIA Driver
select_cuda_bundled_driver() {
    CONFIRM_DRIVER="yes"
    SELECTED_DRIVER_SOURCE="cuda"
    SELECTED_DRIVER_VERSION="${RECOMMENDED_DRIVER_VERSION:-CUDA bundled driver}"
    SELECTED_DRIVER_FILE=""
    SELECTED_DRIVER_URL=""
}

# 函数：解析某个驱动版本实际对应的独立 runfile 文件名
resolve_nvidia_driver_file() {
    local driver_version=$1
    local driver_url="${NVIDIA_DRIVER_BASE_URL}/${NVIDIA_DRIVER_DIR}/${driver_version}/"
    local driver_file

    driver_file=$(metadata_wget -qO- "$driver_url" 2>/dev/null | \
        grep -oE "NVIDIA-Linux-${NVIDIA_DRIVER_FILE_ARCH}-${driver_version}[^'\"<> ]*\.run" | \
        head -1 || true)

    if [[ -n "$driver_file" ]]; then
        echo "$driver_file"
    else
        echo "NVIDIA-Linux-${NVIDIA_DRIVER_FILE_ARCH}-${driver_version}.run"
    fi
}

# 函数：校验 runfile 是否完整可用
validate_runfile() {
    local filename=$1
    local filepath

    filepath="$(runfile_path "$filename")"
    [[ -s "$filepath" ]] || return 1
    chmod +x "$filepath"
    "$filepath" --check >/dev/null 2>&1
}

build_cuda_install_args() {
    local filename=$1
    local install_path=$2
    local help_text
    local runfile_abs

    runfile_abs="$(runfile_path "$filename")"
    help_text=$("$runfile_abs" --help 2>&1 || true)
    CUDA_INSTALL_ARGS=(--silent --toolkit)

    if [[ "$help_text" == *"--toolkitpath"* ]]; then
        CUDA_INSTALL_ARGS+=(--toolkitpath="${install_path}")
    elif [[ "$help_text" == *"--installpath"* ]]; then
        log_warn "当前 CUDA runfile 未显示 --toolkitpath，退回使用 --installpath。"
        CUDA_INSTALL_ARGS+=(--installpath="${install_path}")
    else
        log_error "无法从 CUDA runfile 帮助信息确认安装路径参数。请手动执行 ${runfile_abs} --help 检查支持的选项。"
        exit 1
    fi

    if [[ -n "$CUDA_INSTALL_TMPDIR" ]]; then
        if [[ "$help_text" == *"--tmpdir"* ]]; then
            CUDA_INSTALL_ARGS+=(--tmpdir="${CUDA_INSTALL_TMPDIR}")
        else
            log_warn "当前 CUDA runfile 未显示 --tmpdir 选项，忽略 CUDA_INSTALL_TMPDIR 设置。"
        fi
    fi

    if [[ "$INSTALL_CUDA_SAMPLES" == "1" ]]; then
        if [[ "$help_text" == *"--samples"* ]]; then
            CUDA_INSTALL_ARGS+=(--samples)
        else
            log_warn "当前 CUDA runfile 未显示 --samples 选项，将跳过 CUDA Samples 安装。"
        fi
    else
        log_info "INSTALL_CUDA_SAMPLES=${INSTALL_CUDA_SAMPLES}，跳过 CUDA Samples 安装。"
    fi

    if [[ "$CONFIRM_DRIVER" == "yes" && "$SELECTED_DRIVER_SOURCE" == "cuda" ]]; then
        CUDA_INSTALL_ARGS+=(--driver)
        if command -v dkms &> /dev/null && [[ "$help_text" == *"--dkms"* ]]; then
            CUDA_INSTALL_ARGS+=(--dkms)
            log_info "检测到 dkms，内置驱动将以 DKMS 方式注册内核模块（内核升级后自动重建）。"
        fi
        if [[ -n "$NVIDIA_KERNEL_MODULE_TYPE" ]]; then
            if [[ "$help_text" == *"--kernel-module-type"* ]]; then
                case "$NVIDIA_KERNEL_MODULE_TYPE" in
                    open) CUDA_INSTALL_ARGS+=(--kernel-module-type=open) ;;
                    proprietary) CUDA_INSTALL_ARGS+=(--kernel-module-type=proprietary) ;;
                    *)
                        log_error "NVIDIA_KERNEL_MODULE_TYPE 取值无效: ${NVIDIA_KERNEL_MODULE_TYPE}（可选 open 或 proprietary）。"
                        exit 1
                        ;;
                esac
                log_info "内置驱动使用 ${NVIDIA_KERNEL_MODULE_TYPE} 内核模块。"
            else
                log_warn "当前 CUDA runfile 未显示 --kernel-module-type 选项，忽略 NVIDIA_KERNEL_MODULE_TYPE 设置。"
            fi
        fi
    fi
}

# 函数：为独立驱动 runfile 追加内核模块类型参数。
# 官方 README 里 --kernel-module-type 的写法自相矛盾（正文 -M=open，示例 -m=kernel-open），
# 因此不硬编码，改为读 runfile 自带的 -A 高级帮助来确认实际支持的形式。
# 若用户未手动设置 NVIDIA_KERNEL_MODULE_TYPE，则：
#   1. 先用 --print-recommended-kernel-module-type 查询 runfile 推荐值；
#   2. 再对比磁盘上现有 nvidia.ko 的 license 字段，两者一致时直接使用；
#   3. 都无法获取时才不传参（由安装器默认选择，但可能触发交互询问）。
detect_kernel_module_type() {
    local runfile_abs=$1
    local recommended=""
    local disk_license=""

    # 方法1：用 runfile 自带的推荐查询（R530+ 支持）
    if recommended=$("$runfile_abs" --print-recommended-kernel-module-type 2>/dev/null | \
                     grep -oE '^(open|proprietary)' | head -1); then
        [[ -n "$recommended" ]] && echo "$recommended" && return 0
    fi

    # 方法2：从磁盘上已有的 nvidia.ko license 字段推断
    local ko_path
    ko_path=$(find "/lib/modules/$(uname -r)" -name 'nvidia.ko*' 2>/dev/null | head -1)
    if [[ -n "$ko_path" ]] && command -v modinfo &>/dev/null; then
        disk_license=$(modinfo -F license "$ko_path" 2>/dev/null || true)
        if [[ "$disk_license" == *"MIT"* || "$disk_license" == *"GPL"* ]]; then
            echo "open" && return 0
        elif [[ -n "$disk_license" ]]; then
            echo "proprietary" && return 0
        fi
    fi

    return 1
}

append_driver_kernel_module_type() {
    local runfile_abs=$1
    local help_text
    local module_arg=""
    local effective_type="${NVIDIA_KERNEL_MODULE_TYPE:-}"

    # 用户未指定时自动探测，避免 --no-questions 下安装器因类型询问而中止
    if [[ -z "$effective_type" ]]; then
        effective_type=$(detect_kernel_module_type "$runfile_abs" || true)
        if [[ -n "$effective_type" ]]; then
            log_info "自动检测内核模块类型: ${effective_type}"
        fi
    fi

    [[ -z "$effective_type" ]] && return 0

    case "$effective_type" in
        open|proprietary) ;;
        *)
            log_error "NVIDIA_KERNEL_MODULE_TYPE 取值无效: ${effective_type}（可选 open 或 proprietary）。"
            exit 1
            ;;
    esac

    help_text=$("$runfile_abs" -A 2>&1 || true)

    if [[ "$help_text" == *"--kernel-module-type"* ]]; then
        module_arg="--kernel-module-type=${effective_type}"
    elif [[ "$help_text" == *"-m=kernel-open"* ]]; then
        if [[ "$effective_type" == "open" ]]; then
            module_arg="-m=kernel-open"
        else
            module_arg="-m=kernel"
        fi
    else
        log_warn "当前驱动 runfile 未显示内核模块类型选项，跳过参数传递（由安装器自行选择）。"
        return 0
    fi

    DRIVER_INSTALL_ARGS+=("$module_arg")
    log_info "内核模块类型: ${effective_type}（参数 ${module_arg}）。"
}

# 函数：清理磁盘上残留的旧版 nvidia *.ko 文件。
# nvidia-installer 测试加载阶段会 modprobe nvidia-modeset/nvidia-uvm，
# modprobe 从 /lib/modules 查找文件，若上一次安装遗留了不同版本的 .ko，
# 就会与 installer 刚编译好的 nvidia.ko 版本不符，报 "Version mismatch"。
# 解决：安装前把旧 .ko 移走，让 installer 写入自己编译的新版本。
remove_stale_nvidia_ko() {
    local target_version=$1
    local ko_dir="/lib/modules/$(uname -r)/kernel/drivers/video"
    local old_ko_found=0
    local ko_name f existing_ver

    [[ -d "$ko_dir" ]] || return 0
    command -v modinfo &>/dev/null || return 0

    for ko_name in nvidia nvidia-modeset nvidia-uvm nvidia-drm nvidia-peermem; do
        for f in "${ko_dir}/${ko_name}.ko" \
                  "${ko_dir}/${ko_name}.ko.zst" \
                  "${ko_dir}/${ko_name}.ko.xz"; do
            [[ -f "$f" ]] || continue
            existing_ver=$(modinfo -F version "$f" 2>/dev/null || true)
            if [[ -n "$existing_ver" && "$existing_ver" != "$target_version" ]]; then
                log_info "移除旧版 ${ko_name}.ko (${existing_ver} → ${target_version}): ${f}"
                run_privileged rm -f "$f"
                old_ko_found=1
            fi
        done
    done

    if (( old_ko_found )); then
        run_privileged depmod -a "$(uname -r)" 2>/dev/null || true
        log_info "已更新内核模块依赖表。"
    fi
}

# 函数：下载文件；优先 aria2c 多线程分片，失败后回退 wget 断点续传
download_file() {
    local url=$1
    local output=$2
    local output_path="${DOWNLOAD_DIR}/${output}"
    local aria2_control_path="${output_path}.aria2"
    local failed_stamp

    if command -v aria2c &> /dev/null; then
        print_kv "下载器" "aria2c (${ARIA2_CONNECTIONS} 连接 / ${ARIA2_SPLIT} 分片)"
        if aria2c \
            --continue=true \
            --max-connection-per-server="${ARIA2_CONNECTIONS}" \
            --split="${ARIA2_SPLIT}" \
            --min-split-size="${ARIA2_MIN_SPLIT_SIZE}" \
            --max-tries="${DOWNLOAD_RETRIES}" \
            --retry-wait=3 \
            --timeout="${DOWNLOAD_TIMEOUT}" \
            --connect-timeout="${DOWNLOAD_TIMEOUT}" \
            --summary-interval=10 \
            --file-allocation=none \
            --allow-overwrite=true \
            --auto-file-renaming=false \
            --dir="${DOWNLOAD_DIR}" \
            --out="${output}" \
            "${url}"; then
            return 0
        fi

        failed_stamp="$(date +%Y%m%d%H%M%S)"
        # 先清理历史隔离文件，只保留本次这一份，避免反复失败堆满磁盘
        rm -f -- "${output_path}".aria2_failed.* "${aria2_control_path}".failed.* 2>/dev/null || true
        if [[ -e "$output_path" ]]; then
            mv -f "$output_path" "${output_path}.aria2_failed.${failed_stamp}" || true
            log_warn "已隔离 aria2c 残留文件: $(basename -- "${output_path}.aria2_failed.${failed_stamp}")"
        fi
        if [[ -e "$aria2_control_path" ]]; then
            mv -f "$aria2_control_path" "${aria2_control_path}.failed.${failed_stamp}" || true
            log_warn "已隔离 aria2c 控制文件: $(basename -- "${aria2_control_path}.failed.${failed_stamp}")"
        fi
        log_warn "aria2c 下载失败，已清理回退路径，将使用 wget 重新下载。"
    else
        print_kv "下载器" "wget 断点续传"
    fi

    wget \
        --continue \
        --tries="${DOWNLOAD_RETRIES}" \
        --timeout="${DOWNLOAD_TIMEOUT}" \
        --read-timeout="${DOWNLOAD_TIMEOUT}" \
        --progress=bar:force \
        -O "${DOWNLOAD_DIR}/${output}" \
        "${url}"
}

# 函数：下载 runfile；如果文件已存在，先校验，损坏则重新下载
download_runfile() {
    local url=$1
    local filename=$2
    local label=$3
    local need_mb=${4:-0}
    local temp_file="${filename}.download"
    local target_file
    local temp_path
    local corrupt_file

    require_safe_runfile_name "$filename" "$label"
    target_file="$(runfile_path "$filename")"
    temp_path="${DOWNLOAD_DIR}/${temp_file}"

    if [ -f "$target_file" ]; then
        print_hint "${label} 已存在，正在校验完整性..."
        if validate_runfile "$filename"; then
            log_info "${label} 校验通过，跳过下载。"
            return 0
        fi

        rm -f -- "${DOWNLOAD_DIR}/${filename}".corrupt.* 2>/dev/null || true
        corrupt_file="${filename}.corrupt.$(date +%Y%m%d%H%M%S)"
        log_warn "${label} 校验失败，可能下载不完整或文件损坏，将重新下载。"
        mv -f "$target_file" "${DOWNLOAD_DIR}/${corrupt_file}" || true
        log_warn "已将旧文件保留为: ${corrupt_file}"
    fi

    print_section "开始下载 ${label}"
    if (( need_mb > 0 )) && ! check_disk_space "$DOWNLOAD_DIR" "$need_mb" "下载目录"; then
        print_hint "可通过 CUDA_DOWNLOAD_DIR 环境变量把下载目录指向更大的磁盘后重试。"
        exit 1
    fi
    print_kv "下载地址" "$url"
    if ! download_file "${url}" "${temp_file}"; then
        log_error "下载失败: ${label}。请检查网络连接、代理设置(http_proxy/https_proxy)与下载源可达性；已下载部分已保留，重新运行脚本会断点续传。"
        exit 1
    fi
    mv -f "$temp_path" "$target_file"
    chmod +x "$target_file"

    if ! validate_runfile "$filename"; then
        log_error "${label} 下载后校验仍失败。请检查 /tmp 空间、磁盘空间、网络连接或 NVIDIA 下载源。"
        exit 1
    fi
    log_success "${label} 下载完成并通过校验。"
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
    local install_mode=${10:-cuda}
    
    log_warn "检测到 Nouveau 驱动正在运行，必须将其禁用并重启系统才能安装 NVIDIA 驱动。"
    print_hint "正在创建黑名单文件: ${NVIDIA_BLACKLIST_FILE}"

    # 1. 写入黑名单
    run_privileged tee "$NVIDIA_BLACKLIST_FILE" >/dev/null <<EOF
blacklist nouveau
options nouveau modeset=0
EOF

    # 2. 更新内核 Initramfs (区分 OS)
    print_section "重新生成内核引导镜像 (initramfs)"
    print_hint "这可能需要一分钟。"
    refresh_initramfs

    # 3. 保存当前状态到文件
    print_hint "正在保存当前安装状态..."
    save_install_state "$filename" "$driver_choice" "$cuda_version" "$driver_version" "$driver_file" "$driver_url" "$recommended_driver" "$driver_source" "$minimum_driver" "$install_mode"

    log_success "配置已完成！"
    echo -e "${BOLD}${RED}======================================================${NC}"
    echo -e "${BOLD}${RED}系统必须重启以应用 Nouveau 禁用配置。${NC}"
    echo -e "${YELLOW}重启后重新运行此脚本，它会自动恢复进度并继续安装。${NC}"
    echo -e "${BOLD}${RED}======================================================${NC}"
    
    REBOOT_NOW=""
    if ! read -r -t "$REBOOT_CONFIRM_TIMEOUT" -p "$(echo -e "${BOLD}是否立即重启?${NC} ${YELLOW}(y/N): ${NC}")" REBOOT_NOW; then
        echo
        log_warn "超过 ${REBOOT_CONFIRM_TIMEOUT} 秒未确认或输入流已关闭，默认不自动重启。"
    fi
    if [[ "$REBOOT_NOW" =~ ^[yY] ]]; then
        run_privileged reboot
    else
        print_hint "请稍后手动重启，并在重启后再次运行 ./install_cuda.sh"
        exit 0
    fi
}

# 变量初始化
INSTALL_MODE="cuda"
DRIVER_NEEDS_REBOOT=0
CUDA_VERSION=""
FILENAME=""
CONFIRM_DRIVER=""
RECOMMENDED_DRIVER_VERSION=""
MINIMUM_DRIVER_VERSION=""
SELECTED_DRIVER_VERSION=""
SELECTED_DRIVER_FILE=""
SELECTED_DRIVER_URL=""
SELECTED_DRIVER_SOURCE=""
DRIVER_ONLY_MINIMUM_DRIVER=""
DRIVER_ONLY_INSTALLED_CUDA=""
DRIVER_LIST_RECOMMENDED_VERSION=""
CUDA_ARCH_LABEL=""
CUDA_RUNFILE_SUFFIX=""

detect_nvidia_driver_arch
print_kv "检测到系统架构" "$CUDA_ARCH_LABEL"

# 提前识别 GPU 架构下限，让驱动菜单只显示本机真正能用的版本。
detect_gpu_driver_floor
if [[ -n "$DETECTED_GPU_NAMES" ]]; then
    print_kv "检测到 GPU" "$DETECTED_GPU_NAMES"
fi
if [[ -n "$GPU_MINIMUM_DRIVER_VERSION" ]]; then
    print_kv "本机 GPU 驱动下限" "${GPU_MINIMUM_DRIVER_VERSION}${DETECTED_GPU_FLOOR_REASON:+ (${DETECTED_GPU_FLOOR_REASON})}"
fi

# --- 检查是否存在状态文件 (意味着这是重启后的运行) ---
if [ -f "$STATE_FILE" ]; then
    print_section "检测到未完成的安装状态"
    load_install_state
    
    INSTALL_MODE="${SAVED_INSTALL_MODE:-cuda}"
    FILENAME="$SAVED_FILENAME"
    CONFIRM_DRIVER="$SAVED_DRIVER_CHOICE"
    CUDA_VERSION="${SAVED_CUDA_VERSION:-$(echo "$FILENAME" | cut -d'_' -f2)}"
    SELECTED_DRIVER_VERSION="${SAVED_DRIVER_VERSION:-}"
    SELECTED_DRIVER_FILE="${SAVED_DRIVER_FILE:-}"
    SELECTED_DRIVER_URL="${SAVED_DRIVER_URL:-}"
    RECOMMENDED_DRIVER_VERSION="${SAVED_RECOMMENDED_DRIVER:-}"
    MINIMUM_DRIVER_VERSION="${SAVED_MINIMUM_DRIVER:-}"
    SELECTED_DRIVER_SOURCE="${SAVED_DRIVER_SOURCE:-}"

    if [[ "$INSTALL_MODE" != "cuda" && "$INSTALL_MODE" != "driver_only" ]]; then
        log_error "状态文件中的安装模式无效: ${INSTALL_MODE}"
        exit 1
    fi

    if [[ "$INSTALL_MODE" == "cuda" && -z "$FILENAME" ]]; then
        log_error "状态文件缺少 CUDA 安装器文件名。请删除 ${STATE_FILE} 后重新运行脚本。"
        exit 1
    fi

    if [[ -n "$FILENAME" ]]; then
        require_safe_runfile_name "$FILENAME" "恢复的 CUDA 安装器"
    fi
    if [[ -n "$SELECTED_DRIVER_FILE" ]]; then
        require_safe_runfile_name "$SELECTED_DRIVER_FILE" "恢复的 NVIDIA Driver 安装器"
    fi

    if [[ "$CONFIRM_DRIVER" != "yes" && "$CONFIRM_DRIVER" != "no" ]]; then
        log_error "状态文件中的驱动选项无效: ${CONFIRM_DRIVER}"
        exit 1
    fi

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

    if ! validate_driver_source "$SELECTED_DRIVER_SOURCE"; then
        log_error "状态文件中的驱动来源无效: ${SELECTED_DRIVER_SOURCE}"
        exit 1
    fi

    if [[ "$SELECTED_DRIVER_SOURCE" == "archive" && -n "$SELECTED_DRIVER_VERSION" ]] && \
        ! [[ "$SELECTED_DRIVER_VERSION" =~ ^[0-9][0-9A-Za-z._+-]*$ ]]; then
        log_error "状态文件中的 NVIDIA Driver 版本号不合法: ${SELECTED_DRIVER_VERSION}"
        exit 1
    fi

    if ! validate_nvidia_driver_url "$SELECTED_DRIVER_URL"; then
        log_error "状态文件中的 NVIDIA Driver URL 不在预期官网路径内: ${SELECTED_DRIVER_URL}"
        exit 1
    fi
    
    print_kv "恢复的安装模式" "$INSTALL_MODE"
    if [[ -n "$FILENAME" ]]; then
        print_kv "恢复的 CUDA 安装器" "$FILENAME"
    fi
    print_kv "恢复的驱动选项" "$CONFIRM_DRIVER"
    if [[ "$CONFIRM_DRIVER" == "yes" ]]; then
        print_kv "恢复的驱动版本" "$SELECTED_DRIVER_VERSION"
    fi
    
    # 再次检查 Nouveau 是否真的没了
    if is_nouveau_loaded; then
        log_error "Nouveau 驱动仍然存在！可能重启未成功或配置未生效。"
        print_hint "请检查 ${NVIDIA_BLACKLIST_FILE} 是否正确。"
        exit 1
    else
        log_success "Nouveau 已成功禁用。准备继续安装。"
    fi
    
else
    # ==============================================================================
    # 正常流程：如果没有状态文件，则执行正常的选择菜单
    # ==============================================================================

    while true; do
        INSTALL_MODE="cuda"
        choose_install_mode

        if [[ "$INSTALL_MODE" == "driver_only" ]]; then
            if select_driver_only_flow; then
                break
            else
                continue
            fi
        fi

    # --- 3. 获取所有可用的CUDA版本 ---
    print_section "获取 CUDA Toolkit 版本列表"

    mapfile -t CUDA_VERSIONS < <(fetch_cuda_versions)

    if [ ${#CUDA_VERSIONS[@]} -eq 0 ]; then
        log_error "无法从 NVIDIA 官网获取 CUDA Toolkit 版本列表。"
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
        DRIVER_LIST_RECOMMENDED_VERSION=""

        # --- 4. 提供选择菜单 ---
        print_section "选择 CUDA Toolkit 版本"
        PS3="$(echo -e "${BOLD}${CYAN}请输入选项编号:${NC} ")"
        select CUDA_SELECT in "${CUDA_VERSIONS[@]}"; do
            if [[ -n "$CUDA_SELECT" ]]; then
                CUDA_VERSION="$CUDA_SELECT"
                print_kv "已选择 CUDA Toolkit" "$CUDA_VERSION"
                break
            else
                log_error "无效选项，请重新输入。"
            fi
        done
        if [[ -z "$CUDA_VERSION" ]]; then
            log_error "未选择 CUDA Toolkit 版本（检测到 EOF/Ctrl+D），已退出。"
            exit 1
        fi
        echo

        # --- 5.1. 获取 CUDA 安装器、最低驱动和推荐驱动版本 ---
        print_section "获取 CUDA ${CUDA_VERSION} 的安装器和驱动兼容信息"
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
            print_kv "最低兼容驱动" "$MINIMUM_DRIVER_VERSION"
        else
            log_warn "未能获取最低驱动版本，无法按兼容性过滤驱动列表。"
        fi

        # 数据中心卡的架构下限可能高于 CUDA 通用下限，取较大值再过滤。
        CUDA_RELEASE_MINIMUM_DRIVER="$MINIMUM_DRIVER_VERSION"
        MINIMUM_DRIVER_VERSION=$(raise_minimum_with_gpu_floor "$MINIMUM_DRIVER_VERSION")
        if [[ "$MINIMUM_DRIVER_VERSION" != "$CUDA_RELEASE_MINIMUM_DRIVER" ]]; then
            print_kv "按本机 GPU 提升下限至" "${MINIMUM_DRIVER_VERSION}${DETECTED_GPU_NAMES:+ (${DETECTED_GPU_NAMES})}"
        fi

        if [[ -n "$RECOMMENDED_DRIVER_VERSION" ]]; then
            print_kv "CUDA 自带驱动" "$RECOMMENDED_DRIVER_VERSION"
        else
            log_warn "未能从 release notes 获取推荐驱动版本。"
        fi
        print_kv "CUDA Toolkit 安装器" "$FILENAME"
        echo

        # --- 5.2. 选择 NVIDIA Driver 版本 ---
        print_section "获取兼容的 NVIDIA Driver 版本"
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

        DRIVER_DISPLAY_VERSIONS=()
        for driver_version in "${DRIVER_VERSIONS[@]}"; do
            if [[ -n "$RECOMMENDED_DRIVER_VERSION" && "$driver_version" == "$RECOMMENDED_DRIVER_VERSION" ]]; then
                continue
            fi
            DRIVER_DISPLAY_VERSIONS+=("${driver_version}")
        done

        if [[ ${#DRIVER_VERSIONS[@]} -eq 0 ]]; then
            log_warn "没有找到与 CUDA ${CUDA_VERSION} 匹配的 NVIDIA Driver 版本。"
        fi

        while true; do
            print_driver_selection_menu

            DRIVER_INPUT=""
            if ! read -r -t "$DRIVER_SELECT_TIMEOUT" -p "$(echo -e "${BOLD}${CYAN}请输入选项编号:${NC} ")" DRIVER_INPUT; then
                echo
                log_warn "超过 ${DRIVER_SELECT_TIMEOUT} 秒未选择 NVIDIA Driver，默认安装 CUDA Toolkit 安装器自带驱动。"
                select_cuda_bundled_driver
                print_kv "默认选择 NVIDIA Driver" "$SELECTED_DRIVER_VERSION"
                print_kv "驱动来源" "CUDA Toolkit 安装器内置驱动"
                break
            fi

            if [[ -n "$RECOMMENDED_DRIVER_VERSION" && "$DRIVER_INPUT" == "$RECOMMENDED_DRIVER_VERSION" ]]; then
                select_cuda_bundled_driver
                print_driver_selection_result
                break
            elif driver_version_is_listed "$DRIVER_INPUT"; then
                select_archive_driver "$DRIVER_INPUT"
                print_driver_selection_result
                break
            fi

            if ! [[ "$DRIVER_INPUT" =~ ^[0-9]+$ ]]; then
                log_error "无效选项，请重新输入。"
                continue
            fi

            if (( DRIVER_INPUT == 1 )); then
                echo
                continue 2
            elif (( DRIVER_INPUT == 2 )); then
                CONFIRM_DRIVER="no"
                print_kv "已选择" "仅安装 CUDA Toolkit"
            elif (( DRIVER_INPUT == 3 )); then
                select_cuda_bundled_driver
                print_driver_selection_result
            elif (( DRIVER_INPUT >= 4 && DRIVER_INPUT < 4 + ${#DRIVER_DISPLAY_VERSIONS[@]} )); then
                DRIVER_SELECT_INDEX=$((DRIVER_INPUT - 4))
                select_archive_driver "${DRIVER_DISPLAY_VERSIONS[$DRIVER_SELECT_INDEX]}"
                print_driver_selection_result
            else
                log_error "无效选项，请重新输入。"
                continue
            fi
            break
        done
        echo
        break
    done

        break
    done

    # --- 检查 Nouveau 状态 (仅当用户选择安装驱动时) ---
    if [[ "$CONFIRM_DRIVER" == "yes" ]]; then
        if is_nouveau_loaded; then
            # 触发禁用逻辑，并退出脚本等待重启
            disable_nouveau_and_reboot "$FILENAME" "$CONFIRM_DRIVER" "$CUDA_VERSION" "$SELECTED_DRIVER_VERSION" "$SELECTED_DRIVER_FILE" "$SELECTED_DRIVER_URL" "$RECOMMENDED_DRIVER_VERSION" "$SELECTED_DRIVER_SOURCE" "$MINIMUM_DRIVER_VERSION" "$INSTALL_MODE"
        else
            log_info "Nouveau 未加载或已禁用，可以直接安装 NVIDIA Driver。"
        fi
    fi
fi

# ==============================================================================
# 安装执行阶段 (无论是首次运行还是重启后恢复，都会汇聚到这里)
# ==============================================================================

if [[ "$INSTALL_MODE" != "driver_only" ]]; then
    CUDA_MAJOR_VERSION="${CUDA_VERSION:-$(echo "$FILENAME" | cut -d'_' -f2)}"
    DOWNLOAD_URL="https://developer.download.nvidia.com/compute/cuda/${CUDA_MAJOR_VERSION}/local_installers/${FILENAME}"

    # --- 下载 ---
    download_runfile "${DOWNLOAD_URL}" "${FILENAME}" "CUDA Toolkit 安装器 ${FILENAME}" "$CUDA_DOWNLOAD_NEED_MB"
fi

# --- 安装 NVIDIA Driver ---
# 注意：无论用户选"CUDA 内置驱动"还是独立归档驱动，都统一走独立 runfile 路径安装。
# 原因：CUDA runfile 内部调用 nvidia-installer 时传的是 --no-questions，
# 遇到"nvidia 模块已加载"会直接 Abort，脚本无法二次介入。
# 改为先只装 Toolkit（build_cuda_install_args 不再传 --driver），
# 再用独立 runfile 装驱动，unload_nvidia_modules 的等待逻辑得以完整介入。
DRIVER_MSG="无驱动"
if [[ "$CONFIRM_DRIVER" == "yes" ]]; then
    DRIVER_MSG="NVIDIA Driver ${SELECTED_DRIVER_VERSION}"
    preflight_nvidia_driver_install

    # "cuda" 来源：CUDA runfile 自带驱动版本。下载同版本的独立驱动 runfile 来安装，
    # 避免把控制权交给 CUDA runfile 内部的 nvidia-installer。
    if [[ "$SELECTED_DRIVER_SOURCE" == "cuda" ]]; then
        log_info "将下载 NVIDIA Driver ${SELECTED_DRIVER_VERSION} 独立 runfile（替代 CUDA 内置驱动安装路径）。"
        SELECTED_DRIVER_FILE=$(resolve_nvidia_driver_file "$SELECTED_DRIVER_VERSION")
        SELECTED_DRIVER_URL="${NVIDIA_DRIVER_BASE_URL}/${NVIDIA_DRIVER_DIR}/${SELECTED_DRIVER_VERSION}/${SELECTED_DRIVER_FILE}"
        # 标记为独立 runfile，后续统一处理
        SELECTED_DRIVER_SOURCE="archive"
    fi

    if [[ -z "$SELECTED_DRIVER_FILE" ]]; then
        SELECTED_DRIVER_FILE=$(resolve_nvidia_driver_file "$SELECTED_DRIVER_VERSION")
    fi

    if [[ -z "$SELECTED_DRIVER_URL" ]]; then
        SELECTED_DRIVER_URL="${NVIDIA_DRIVER_BASE_URL}/${NVIDIA_DRIVER_DIR}/${SELECTED_DRIVER_VERSION}/${SELECTED_DRIVER_FILE}"
    fi

    download_runfile "${SELECTED_DRIVER_URL}" "${SELECTED_DRIVER_FILE}" "NVIDIA Driver ${SELECTED_DRIVER_VERSION} 安装器" "$DRIVER_DOWNLOAD_NEED_MB"

    if ! check_disk_space "${CUDA_INSTALL_TMPDIR:-/tmp}" "$DRIVER_TMP_NEED_MB" "驱动安装临时目录"; then
        print_hint "可设置 CUDA_INSTALL_TMPDIR 指向更大的目录后重试。"
        exit 1
    fi

    DRIVER_INSTALL_ARGS=(--silent --no-questions)
    if command -v dkms &> /dev/null; then
        DRIVER_INSTALL_ARGS+=(--dkms)
        log_info "检测到 dkms，驱动内核模块将以 DKMS 方式注册（内核升级后自动重建）。"
    fi
    if [[ -n "$CUDA_INSTALL_TMPDIR" ]]; then
        DRIVER_INSTALL_ARGS+=(--tmpdir="${CUDA_INSTALL_TMPDIR}")
    fi
    DRIVER_RUNFILE_ABS="$(runfile_path "$SELECTED_DRIVER_FILE")"
    append_driver_kernel_module_type "$DRIVER_RUNFILE_ABS"

    remove_conflicting_dkms_driver "$SELECTED_DRIVER_VERSION"
    unload_nvidia_modules

    remove_stale_nvidia_ko "$SELECTED_DRIVER_VERSION"

    # 二次保险：unload 完成到 installer 启动之间，systemd 的 Restart= 计时器
    # 或 udev 规则可能已重新加载模块。
    # 在 installer 入口前轻量扫一遍，如有残留再做一轮快速清理。
    if nvidia_modules_loaded; then
        log_info "检测到模块在 unload 后被重新加载，执行二次清理..."
        RETRY_UDEV_PAUSED=0
        if command -v udevadm &> /dev/null && \
           run_privileged udevadm control --stop-exec-queue 2>/dev/null; then
            RETRY_UDEV_PAUSED=1
        fi
        for module in nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia; do
            if awk -v m="$module" '$1==m{found=1}END{exit !found}' /proc/modules 2>/dev/null; then
                run_privileged rmmod "$module" 2>/dev/null || true
            fi
        done
        if (( RETRY_UDEV_PAUSED == 1 )); then
            run_privileged udevadm control --start-exec-queue 2>/dev/null || true
        fi
        wait_nvidia_fds_released 10
    fi

    print_section "静默安装 NVIDIA Driver ${SELECTED_DRIVER_VERSION}"
    if ! run_privileged "$DRIVER_RUNFILE_ABS" "${DRIVER_INSTALL_ARGS[@]}"; then
        log_error "NVIDIA Driver 安装失败。请查看 /var/log/nvidia-installer.log"
        print_hint "常见原因："
        print_hint "  1) 模块版本冲突 —— 日志出现 'Version mismatch' 或 'Device or resource busy'，"
        print_hint "     通常是磁盘上残留了其他版本的 DKMS 驱动，需先 dkms remove。"
        print_hint "  2) 内核模块仍被占用 —— 日志出现 'appears to be already loaded'，停掉 GPU 进程或重启后重试。"
        print_hint "  3) 内核模块类型选择 —— 日志出现 'Multiple kernel module types'，可设置 NVIDIA_KERNEL_MODULE_TYPE=open 或 proprietary。"
        print_hint "  4) 容器环境 —— 容器内无法安装驱动，请在宿主机安装。"
        restore_stopped_nvidia_services
        exit 1
    fi
fi

if [[ "$INSTALL_MODE" == "driver_only" ]]; then
    restore_stopped_nvidia_services
    verify_nvidia_driver_installation

    if [ -f "$STATE_FILE" ]; then
        rm -f -- "$STATE_FILE"
        log_debug "已清理安装状态文件。"
    fi

    verify_and_fix_fabricmanager "$SELECTED_DRIVER_VERSION"

    echo -e "${BOLD}${BLUE}=====================================================${NC}"
    echo -e "${BOLD}${GREEN}          NVIDIA Driver 安装流程已完成              ${NC}"
    echo -e "${BOLD}${BLUE}=====================================================${NC}"
    echo -e "手动复验: ${GREEN}nvidia-smi${NC}"
    exit 0
fi

CUDA_INSTALL_VERSION=$(echo "$CUDA_MAJOR_VERSION" | awk -F. '{print $1"."$2}')
INSTALL_PATH="/usr/local/cuda-${CUDA_INSTALL_VERSION}"

print_section "静默安装 CUDA Toolkit"
print_kv "安装路径" "$INSTALL_PATH"
print_kv "驱动策略" "$DRIVER_MSG"
print_hint "这可能需要几分钟，请不要关闭终端。"

if ! check_disk_space "${CUDA_INSTALL_TMPDIR:-/tmp}" "$CUDA_TMP_NEED_MB" "CUDA 安装临时目录"; then
    print_hint "CUDA runfile 解压需要较大临时空间；可设置 CUDA_INSTALL_TMPDIR 指向更大的目录后重试。"
    exit 1
fi

# 执行安装
build_cuda_install_args "$FILENAME" "$INSTALL_PATH"

CUDA_RUNFILE_ABS="$(runfile_path "$FILENAME")"
if ! run_privileged "$CUDA_RUNFILE_ABS" "${CUDA_INSTALL_ARGS[@]}"; then
    log_error "CUDA Toolkit 安装失败。请查看 /var/log/cuda-installer.log"
    # 注意：如果失败了，我们不删除状态文件，以便用户排查后重新运行
    restore_stopped_nvidia_services
    exit 1
fi

log_success "CUDA Toolkit 安装成功。"
restore_stopped_nvidia_services

if [[ "$CONFIRM_DRIVER" == "yes" ]]; then
    check_driver_version_consistency || DRIVER_NEEDS_REBOOT=1
    verify_and_fix_fabricmanager "$SELECTED_DRIVER_VERSION"
fi

# --- 7. 环境变量配置 ---
update_cuda_symlink "${INSTALL_PATH}" "${SYMLINK_PATH}"
configure_cuda_environment
verify_cuda_installation

# --- 8. 清理与完成 ---
# 安装成功，删除状态文件
if [ -f "$STATE_FILE" ]; then
    rm -f -- "$STATE_FILE"
    log_debug "已清理安装状态文件。"
fi

echo -e "${BOLD}${BLUE}=====================================================${NC}"
echo -e "${BOLD}${GREEN}                所有操作已成功完成                 ${NC}"
echo -e "${BOLD}${BLUE}=====================================================${NC}"

if [[ "${DRIVER_NEEDS_REBOOT:-0}" == "1" ]]; then
    echo -e "${BOLD}${YELLOW}注意: 驱动已更换但旧模块仍在内存中，需要重启后才能生效。${NC}"
    echo -e "${YELLOW}重启前 nvidia-smi 会报 Driver/library version mismatch，属预期现象。${NC}"
    echo -e "执行: ${GREEN}reboot${NC}"
    echo
fi

echo -e "手动复验: ${GREEN}source /etc/profile.d/cuda.sh && nvcc -V && nvidia-smi${NC}"
