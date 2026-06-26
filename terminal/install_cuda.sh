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
AUTO_INSTALL_ARIA2="${AUTO_INSTALL_ARIA2:-1}" # 设为 0 时不自动安装 aria2，仅使用系统已有下载器
SKIP_DRIVER_PREFLIGHT="${SKIP_DRIVER_PREFLIGHT:-0}" # 设为 1 时跳过 NVIDIA Driver 安装前依赖检查
INSTALL_CUDA_SAMPLES="${INSTALL_CUDA_SAMPLES:-0}" # 设为 1 时安装 CUDA Samples

# --- 辅助函数 ---
log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${BOLD}${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_debug() { echo -e "${BLUE}[DEBUG]${NC} $1"; }
print_section() { echo -e "\n${BOLD}${BLUE}==>${NC} ${BOLD}$1${NC}"; }
print_kv() { echo -e "  ${CYAN}$1:${NC} ${GREEN}$2${NC}"; }
print_hint() { echo -e "  ${YELLOW}$1${NC}"; }

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
            log_warn "未知 CPU 架构 $(uname -m)，将按 Linux x86_64 驱动归档尝试。"
            CUDA_ARCH_LABEL="Linux x86_64 (fallback)"
            CUDA_RUNFILE_SUFFIX="linux"
            NVIDIA_DRIVER_DIR="Linux-x86_64"
            NVIDIA_DRIVER_FILE_ARCH="x86_64"
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
    wget -qO- "$CUDA_ARCHIVE_URL" | \
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
version_ge() {
    local candidate=$1
    local minimum=$2
    local first

    [[ -z "$minimum" ]] && return 0
    first=$(printf "%s\n%s\n" "$minimum" "$candidate" | sort -V | head -n1)
    [[ "$first" == "$minimum" ]]
}

get_release_notes() {
    local cuda_version=$1
    local cache_key="${cuda_version//./_}"
    local cache_file="${RELEASE_NOTES_CACHE_DIR}/cuda-${cache_key}.html"
    local temp_file="${cache_file}.download"
    local release_notes_url="https://docs.nvidia.com/cuda/archive/${cuda_version}/cuda-toolkit-release-notes/index.html"

    if [[ -s "$cache_file" ]]; then
        cat "$cache_file"
        return 0
    fi

    if wget -qO "$temp_file" "$release_notes_url" 2>/dev/null; then
        mv -f "$temp_file" "$cache_file"
        cat "$cache_file"
    else
        rm -f "$temp_file"
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

    filename=$(wget -qO- "https://developer.nvidia.com/${archive_slug}" 2>/dev/null | \
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

    filename=$(wget -qO- "https://developer.nvidia.com/${archive_slug}" 2>/dev/null | \
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
        read -r -p "$(echo -e "${BOLD}${CYAN}请输入选项编号:${NC} ")" INSTALL_MODE_INPUT
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
        read -r -p "$(echo -e "${BOLD}${CYAN}请输入选项编号:${NC} ")" DRIVER_INPUT

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
            read -r -p "$(echo -e "${BOLD}是否更新 ${link_path} 指向新版本?${NC} ${YELLOW}(Y/n): ${NC}")" update_answer
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
        if [[ "$nvcc_cuda_version" == "$smi_cuda_version" ]]; then
            log_success "nvcc -V 与 nvidia-smi 显示的 CUDA 版本一致。"
        else
            log_warn "nvcc -V 显示 CUDA ${nvcc_cuda_version}，nvidia-smi 显示 CUDA ${smi_cuda_version}。如刚安装或更新驱动，请重启后再验证。"
        fi
    fi
}

verify_nvidia_driver_installation() {
    local smi_path
    local smi_output
    local smi_cuda_version=""

    print_section "验证 NVIDIA Driver"

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

preflight_nvidia_driver_install() {
    local failed=0
    local kernel_release

    if [[ "$SKIP_DRIVER_PREFLIGHT" == "1" ]]; then
        log_warn "SKIP_DRIVER_PREFLIGHT=1，跳过 NVIDIA Driver 安装前检查。"
        return 0
    fi

    print_section "NVIDIA Driver 安装前检查"
    kernel_release=$(uname -r)

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

    if nvidia_modules_loaded; then
        log_warn "检测到 NVIDIA 内核模块已加载。升级驱动时可能需要停止 GPU 相关进程或重启后生效。"
    fi

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

    driver_file=$(wget -qO- "$driver_url" 2>/dev/null | \
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

    help_text=$("$(runfile_path "$filename")" --help 2>&1 || true)
    CUDA_INSTALL_ARGS=(--silent --toolkit)

    if [[ "$help_text" == *"--toolkitpath"* ]]; then
        CUDA_INSTALL_ARGS+=(--toolkitpath="${install_path}")
    elif [[ "$help_text" == *"--installpath"* ]]; then
        log_warn "当前 CUDA runfile 未显示 --toolkitpath，退回使用 --installpath。"
        CUDA_INSTALL_ARGS+=(--installpath="${install_path}")
    else
        log_error "无法从 CUDA runfile 帮助信息确认安装路径参数。请手动执行 $(runfile_path "$filename") --help 检查支持的选项。"
        exit 1
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

        corrupt_file="${filename}.corrupt.$(date +%Y%m%d%H%M%S)"
        log_warn "${label} 校验失败，可能下载不完整或文件损坏，将重新下载。"
        mv -f "$target_file" "${DOWNLOAD_DIR}/${corrupt_file}" || true
        log_warn "已将旧文件保留为: ${corrupt_file}"
    fi

    print_section "开始下载 ${label}"
    print_kv "下载地址" "$url"
    download_file "${url}" "${temp_file}"
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
    
    read -r -p "$(echo -e "${BOLD}是否立即重启?${NC} ${YELLOW}(y/N): ${NC}")" REBOOT_NOW
    if [[ "$REBOOT_NOW" =~ ^[yY] ]]; then
        run_privileged reboot
    else
        print_hint "请稍后手动重启，并在重启后再次运行 ./install_cuda.sh"
        exit 0
    fi
}

# 变量初始化
INSTALL_MODE="cuda"
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
    download_runfile "${DOWNLOAD_URL}" "${FILENAME}" "CUDA Toolkit 安装器 ${FILENAME}"
fi

# --- 安装 NVIDIA Driver ---
DRIVER_MSG="无驱动"
if [[ "$CONFIRM_DRIVER" == "yes" ]]; then
    DRIVER_MSG="NVIDIA Driver ${SELECTED_DRIVER_VERSION}"
    preflight_nvidia_driver_install

    if [[ "$SELECTED_DRIVER_SOURCE" == "cuda" ]]; then
        log_info "将使用 CUDA Toolkit 安装器内置的 NVIDIA Driver ${SELECTED_DRIVER_VERSION}。"
    elif [[ -z "$SELECTED_DRIVER_FILE" ]]; then
        SELECTED_DRIVER_FILE=$(resolve_nvidia_driver_file "$SELECTED_DRIVER_VERSION")
    fi

    if [[ "$SELECTED_DRIVER_SOURCE" != "cuda" && -z "$SELECTED_DRIVER_URL" ]]; then
        SELECTED_DRIVER_URL="${NVIDIA_DRIVER_BASE_URL}/${NVIDIA_DRIVER_DIR}/${SELECTED_DRIVER_VERSION}/${SELECTED_DRIVER_FILE}"
    fi

    if [[ "$SELECTED_DRIVER_SOURCE" != "cuda" ]]; then
        download_runfile "${SELECTED_DRIVER_URL}" "${SELECTED_DRIVER_FILE}" "NVIDIA Driver ${SELECTED_DRIVER_VERSION} 安装器"

        print_section "静默安装 NVIDIA Driver ${SELECTED_DRIVER_VERSION}"
        if ! run_privileged "$(runfile_path "$SELECTED_DRIVER_FILE")" --silent --no-questions; then
            log_error "NVIDIA Driver 安装失败。请查看 /var/log/nvidia-installer.log"
            exit 1
        fi
    fi
fi

if [[ "$INSTALL_MODE" == "driver_only" ]]; then
    verify_nvidia_driver_installation

    if [ -f "$STATE_FILE" ]; then
        rm -f -- "$STATE_FILE"
        log_debug "已清理安装状态文件。"
    fi

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

# 执行安装
build_cuda_install_args "$FILENAME" "$INSTALL_PATH"
if ! run_privileged "$(runfile_path "$FILENAME")" "${CUDA_INSTALL_ARGS[@]}"; then
    log_error "CUDA Toolkit 安装失败。请查看 /var/log/cuda-installer.log"
    # 注意：如果失败了，我们不删除状态文件，以便用户排查后重新运行
    exit 1
fi

log_success "CUDA Toolkit 安装成功。"

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
echo -e "手动复验: ${GREEN}source /etc/profile.d/cuda.sh && nvcc -V && nvidia-smi${NC}"
