#!/bin/bash

# ==============================================================================
# Ubuntu Server 初始化配置脚本
# 作者: Airskotex 
# 日期: 2025-09-30
# 功能:
#   0. 升级并配置 GCC (根据系统版本自动选择)
#   1. 更换为阿里云软件源
#   2. 升级内核 (自动检测最适版本)
#   3. 安装 NVIDIA 闭源驱动 (.run 文件)
#   4. 安装 GNOME 桌面和 XRDP 服务
#   5. [高风险] 配置允许 root 用户进行图形和远程登录
#   6. 添加中文语言支持
#   7. 脚本执行完毕后自动删除
#
# ** 警告 **: 此脚本包含高风险操作 (特别是 root 登录)，请仅在完全了解
#            其后果的情况下运行。
# ==============================================================================

set -e # 如果任何命令失败，脚本将立即退出

# --- 获取脚本自身路径 ---
SCRIPT_PATH="$(realpath "$0")"
SCRIPT_NAME="$(basename "$0")"

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

# --- 可配置变量 ---
# 内核版本将由脚本自动检测，无需手动指定
KERNEL_VERSION=""

# NVIDIA 驱动文件名将由脚本自动检测
# ** 脚本执行前，请确保此文件与本脚本位于同一目录下 **
NVIDIA_RUNFILE=""

# --- 颜色定义 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

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

# 检查网络连通性
check_network() {
	log_info "检查网络连通性..."
	if ! ping -c 1 -W 5 mirrors.aliyun.com >/dev/null 2>&1; then
		log_error "无法连接到阿里云镜像服务器，请检查网络连接"
		exit 1
	fi
	log_info "网络连接正常"
}

# 检查系统版本
check_system_version() {
	log_info "检查系统版本..."
	if [[ ! -f /etc/os-release ]]; then
		log_error "无法检测系统版本"
		exit 1
	fi
	
	source /etc/os-release
    UBUNTU_CODENAME="${VERSION_CODENAME}"
    UBUNTU_VERSION="${VERSION_ID}"  
    SYSTEM_ARCH="$(uname -m)"
    
    log_info "检测到系统信息："
    log_info "  - 发行版: $NAME"
    log_info "  - 版本号: $VERSION_ID"
    log_info "  - 代号: $VERSION_CODENAME"
    log_info "  - 架构: $SYSTEM_ARCH"
    
    # 验证是否为Ubuntu
    if [[ "$ID" != "ubuntu" ]]; then
        log_error "此脚本仅支持 Ubuntu 系统，当前系统: $ID"
        exit 1
    fi
    
    # 检查最低版本要求
    if [[ $(echo "$UBUNTU_VERSION < 20.04" | bc) -eq 1 ]]; then
        log_error "此脚本需要 Ubuntu 20.04 或更高版本，当前版本: $UBUNTU_VERSION"
        exit 1
    fi
	
	log_info "系统版本检查通过: Ubuntu $VERSION_CODENAME ($VERSION_ID)"
}
# apt-fast 自动安装和配置
use_apt_fast(){
	# 检测 Ubuntu 版本
	echo -e "${GREEN}正在检测系统版本...${NC}"
	UBUNTU_VERSION=$(lsb_release -r | grep -oP '\d+\.\d+')        
	UBUNTU_CODENAME=$(lsb_release -c | cut -f2)    

	# 显示检测到的版本
	echo -e "${GREEN}检测到系统版本: Ubuntu ${UBUNTU_VERSION} (${UBUNTU_CODENAME})${NC}"        

	# 根据版本设置参数
	case "$UBUNTU_VERSION" in
    	"20.04")
        	echo -e "${GREEN}配置 Ubuntu 20.04 LTS (Focal Fossa) 专用设置${NC}"
        	MAX_CONNECTIONS=16
        	MAX_PER_SERVER=10
        	MIRROR_LIST='http://archive.ubuntu.com/ubuntu,http://us.archive.ubuntu.com/ubuntu,http://uk.archive.ubuntu.com/ubuntu,http://de.archive.ubuntu.com/ubuntu,http://fr.archive.ubuntu.com/ubuntu,http://jp.archive.ubuntu.com/ubuntu,http://in.archive.ubuntu.com/ubuntu,http://br.archive.ubuntu.com/ubuntu'
        	APT_MANAGER="apt-get"
        	EXTRA_CONFIG=""
        	;;
    	"22.04")    
        	echo -e "${GREEN}配置 Ubuntu 22.04 LTS (Jammy Jellyfish) 专用设置${NC}"  
        	MAX_CONNECTIONS=20    
        	MAX_PER_SERVER=10
        	MIRROR_LIST='http://archive.ubuntu.com/ubuntu,http://us.archive.ubuntu.com/ubuntu,http://uk.archive.ubuntu.com/ubuntu,http://de.archive.ubuntu.com/ubuntu,http://fr.archive.ubuntu.com/ubuntu,http://jp.archive.ubuntu.com/ubuntu,http://sg.archive.ubuntu.com/ubuntu,http://au.archive.ubuntu.com/ubuntu,http://ca.archive.ubuntu.com/ubuntu,http://mirrors.digitalocean.com/ubuntu'
        	APT_MANAGER="apt-get"  
        	EXTRA_CONFIG="# 启用 Ubuntu 22.04 的并行下载特性
	APT_FAST_NO_PARALLEL=0"    
        	;;
    	"24.04")
        	echo -e "${GREEN}配置 Ubuntu 24.04 LTS (Noble Numbat) 专用设置${NC}"
        	MAX_CONNECTIONS=24
        	MAX_PER_SERVER=12
        	MIRROR_LIST='http://archive.ubuntu.com/ubuntu,http://us.archive.ubuntu.com/ubuntu,http://uk.archive.ubuntu.com/ubuntu,http://de.archive.ubuntu.com/ubuntu,http://fr.archive.ubuntu.com/ubuntu,http://jp.archive.ubuntu.com/ubuntu,http://sg.archive.ubuntu.com/ubuntu,http://au.archive.ubuntu.com/ubuntu,http://ca.archive.ubuntu.com/ubuntu,http://mirrors.digitalocean.com/ubuntu,http://mirror.hetzner.com/ubuntu/packages,http://azure.archive.ubuntu.com/ubuntu'  
        	APT_MANAGER="apt"
        	EXTRA_CONFIG="# 启用 Ubuntu 24.04 的增强特性
	APT_FAST_NO_PARALLEL=0
	APT_FAST_TIMEOUT=300
	APT_FAST_COMPRESSION=true"
        	;;
    	*)
        	echo -e "${RED}错误: 不支持的 Ubuntu 版本 ${UBUNTU_VERSION}${NC}"
        	echo -e "${YELLOW}此脚本仅支持 Ubuntu 20.04, 22.04 和 24.04 LTS${NC}"
        	exit 1
        	;;
	esac

	# 检查是否已安装 apt-fast
	if ! command -v apt-fast &> /dev/null; then
    	echo -e "${YELLOW}apt-fast 未安装，正在安装...${NC}"
    	sudo add-apt-repository -y ppa:apt-fast/stable
    	sudo apt-get update
    	sudo DEBIAN_FRONTEND=noninteractive apt-get install -y apt-fast
	else
    	echo -e "${GREEN}apt-fast 已安装${NC}"
	fi

	echo -e "${GREEN}正在优化 apt-fast 配置...${NC}"

	# 创建自定义配置文件
	sudo tee /etc/apt-fast.conf > /dev/null << 'EOF'
###################################################################
# apt-fast 配置文件
# Ubuntu ${UBUNTU_VERSION} LTS (${UBUNTU_CODENAME})  
# 生成时间: $(date)
###################################################################

# 使用的包管理器
_APTMGR=${APT_MANAGER}

# 跳过确认对话框
DOWNLOADBEFORE=true  

# 最大连接数
_MAXNUM=${MAX_CONNECTIONS}

# 每个服务器的最大连接数
_MAXCONPERSRV=${MAX_PER_SERVER}

# 下载管理器 (aria2c - 推荐的高性能选项)
_DOWNLOADER='aria2c --no-conf -c -j \${_MAXNUM} -x \${_MAXCONPERSRV} -s \${_MAXCONPERSRV} -k 1M --min-split-size=1M --file-allocation=none --console-log-level=warn --summary-interval=0'

# 备用下载管理器 (axel)
#_DOWNLOADER='axel -n \${_MAXNUM} -a -o \${DLDIR}'

# 备用下载管理器 (wget)
#_DOWNLOADER='wget -cN -P \${DLDIR}'  

# 下载目录
DLDIR=/var/cache/apt/apt-fast

# APT 缓存目录
APTCACHE=/var/cache/apt/archives  

# 中止时清理部分下载
DLLIST_CLEAN=true

# Ubuntu ${UBUNTU_VERSION} 镜像列表（全球优化）
MIRRORS=( '${MIRROR_LIST}' )    

# 彩色输出
COLOR=auto

${EXTRA_CONFIG}
EOF

	# 创建下载目录
	sudo mkdir -p /var/cache/apt/apt-fast
	sudo chmod 755 /var/cache/apt/apt-fast

	# 为 Ubuntu 24.04 添加额外的 APT 优化
	if [ "$UBUNTU_VERSION" = "24.04" ]; then
    	echo -e "${GREEN}为 Ubuntu 24.04 应用额外的 APT 优化...${NC}"
    	sudo tee /etc/apt/apt.conf.d/99-apt-fast-optimizations > /dev/null << 'EOF'
# APT 优化设置 (Ubuntu 24.04)
Acquire::Languages "none";
Acquire::GzipIndexes "true";
Acquire::CompressionTypes::Order:: "gz";
Acquire::http::Pipeline-Depth "5";
APT::Acquire::Retries "3";
EOF

	fi
	# 添加便捷别名到用户配置
	if ! grep -q "alias apt='apt-fast'" ~/.bashrc; then
    	echo -e "${GREEN}添加 apt-fast 别名到 ~/.bashrc...${NC}"  
    	cat >> ~/.bashrc << 'EOF'

# apt-fast 别名 - 加速包管理
alias apt='apt-fast'
alias apt-get='apt-fast'
alias aptitude='apt-fast'
EOF
	fi

	# 创建系统级别的别名配置（对所有用户生效）
	sudo tee /etc/profile.d/apt-fast.sh > /dev/null << 'EOF'
# apt-fast 系统级别别名
alias apt='apt-fast'
alias apt-get='apt-fast'
EOF

}

# 检查和显示系统信息
show_system_info() {
	log_info "======== 系统信息与计划 ========"
	log_info "当前内核版本: $(uname -r)"
    if [[ -n "$KERNEL_VERSION" ]]; then
	    log_info "目标内核版本: $KERNEL_VERSION"
    else
        log_warn "目标内核版本: 未检测到合适的升级版本"
    fi
	log_info "系统架构: $(uname -m)"
	log_info "CPU信息: $(lscpu | grep 'Model name' | cut -d ':' -f2 | xargs)"  
	log_info "内存信息: $(free -h | awk '/^Mem:/ {print $2}') 总内存"
	
	# 检查是否有NVIDIA GPU
	if lspci | grep -i nvidia >/dev/null 2>&1; then
		log_info "检测到NVIDIA GPU:"
		lspci | grep -i nvidia | while read line; do
			log_info "  - $line"
		done
        log_info "将要安装驱动: $NVIDIA_RUNFILE"
	else
		log_warn "未检测到NVIDIA GPU，但仍将继续安装驱动"
	fi
	log_info "=================================="
}

# 终端关闭提示函数
terminal_close_warning() {
	log_warn "==============================================="  
	log_warn "警告：系统即将重启，终端将会关闭！"
	log_warn "请确保已保存所有重要工作。"
	log_warn "==============================================="
	
	for i in {3..1}; do
		echo -e "${RED}系统将在 $i 秒后重启...${NC}"
		sleep 1
	done
}

# 自动检测NVIDIA驱动文件
detect_nvidia_driver() {
	log_info "自动检测NVIDIA驱动文件..."
	local driver_files=($(ls NVIDIA-Linux-x86_64-*.run 2>/dev/null))
	
	if [[ ${#driver_files[@]} -eq 0 ]]; then
		log_error "未找到NVIDIA驱动文件！请确保 .run 文件在当前目录"
		log_info "当前目录内容："
		ls -la
		exit 1
	elif [[ ${#driver_files[@]} -eq 1 ]]; then
		NVIDIA_RUNFILE="${driver_files[0]}"
		log_info "自动检测到驱动文件: $NVIDIA_RUNFILE"
	else
		log_warn "检测到多个NVIDIA驱动文件："
		for i in "${!driver_files[@]}"; do
			echo "  $((i+1)). ${driver_files[i]}"
		done
		read -p "请选择要使用的驱动文件 (1-${#driver_files[@]}): " choice
		if [[ "$choice" -ge 1 && "$choice" -le ${#driver_files[@]} ]]; then
			NVIDIA_RUNFILE="${driver_files[$((choice-1))]}"
			log_info "选择了驱动文件: $NVIDIA_RUNFILE"
		else
			log_error "无效选择"
			exit 1
		fi
	fi
}

# 步骤 0: 升级 GCC
upgrade_gcc() {
	log_step "开始检查并升级 GCC..."
    # 获取当前GCC版本
    current_gcc_version=$(gcc --version 2>/dev/null | head -n1 | grep -oP '\d+' | head -n1)
    # 根据Ubuntu版本决定目标GCC版本
    case "$UBUNTU_VERSION" in
        "20.04")
            target_gcc_version="11"
            log_info "Ubuntu 20.04 检测到，目标 GCC 版本: $target_gcc_version"
            ;;
        "22.04")
            target_gcc_version="12"
            log_info "Ubuntu 22.04 检测到，目标 GCC 版本: $target_gcc_version"
            ;;
        "24.04")
            target_gcc_version="13"
            log_info "Ubuntu 24.04 检测到，目标 GCC 版本: $target_gcc_version"
            ;;
        *)
            target_gcc_version="12"
            log_warn "未知的Ubuntu版本，默认使用 GCC 12"
            ;;
    esac
    # 检查是否需要升级
    if [[ -n "$current_gcc_version" ]] && [[ "$current_gcc_version" -ge "$target_gcc_version" ]]; then
        log_info "当前 GCC 版本 ($current_gcc_version) 已满足要求，跳过升级"
        return 0
    fi
	# 1. 添加 PPA
	log_info "确保 add-apt-repository 命令可用...升级 GCC 到版本 $target_gcc_version..."
	apt install -y software-properties-common

	log_info "正在添加 PPA: ppa:ubuntu-toolchain-r/test..."
	if ! add-apt-repository ppa:ubuntu-toolchain-r/test -y; then
		log_error "添加 PPA 失败"
		exit 1
	fi
	if ! apt update; then
		log_error "更新软件源失败"
		exit 1
	fi

    # 安装目标版本GCC
    if ! apt install -y gcc-${target_gcc_version} g++-${target_gcc_version}; then
        log_error "GCC ${target_gcc_version} 安装失败"
        exit 1
    fi

	# 3. 设置默认版本
	log_info "正在配置 update-alternatives 以设置 GCC ${target_gcc_version} 为默认版本..."
	if ! update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-${target_gcc_version} 100; then
		log_error "设置 gcc 默认版本失败"
		exit 1
	fi
	if ! update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-${target_gcc_version} 100; then
		log_error "设置 g++ 默认版本失败"
		exit 1
	fi

	# 4. 验证
	log_info "验证 GCC 版本..."
	if gcc --version | head -n1; then
		log_info "GCC 版本验证成功:"
		(gcc --version)
	else
		log_warn "GCC 版本验证失败或非预期版本"
		(gcc --version)
	fi

	log_info "GCC 升级完成。"
}

# 步骤 1: 换阿里云的源
change_sources() {
	log_step "为 Ubuntu $UBUNTU_VERSION ($UBUNTU_CODENAME) 配置软件源为阿里云..."
	log_info "正在备份原始 sources.list 文件..."
	cp /etc/apt/sources.list /etc/apt/sources.list.bak_$(date +%F_%H%M%S)

	log_info "正在写入新的阿里云 sources.list..."
	cat > /etc/apt/sources.list << 'EOF'
deb https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb-src https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse

deb https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
deb-src https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse

deb https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb-src https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse

# deb https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME}-proposed main restricted universe multiverse
# deb-src https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME}-proposed main restricted universe multiverse

deb https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
deb-src https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
EOF

	log_info "软件源更换完毕 (使用 $UBUNTU_CODENAME 仓库)，正在执行 apt update..."
	if ! apt update; then
		log_error "apt update 失败，请检查网络连接和软件源配置"
		exit 1
	fi
	log_info "软件源更新成功"
}

# [新增] 步骤 2 前置: 检测目标内核
detect_target_kernel() {
    log_step "正在检测最佳内核版本..."
    
    # 根据Ubuntu版本推荐内核
    case "$UBUNTU_VERSION" in
        "20.04")
            recommended_kernel_pattern="5.15.0"
            ;;
        "22.04"|"24.04")
            recommended_kernel_pattern="6.8.0"
            ;;
        *)
            log_warn "未知的Ubuntu版本，将直接查找可用的最新内核"
            recommended_kernel_pattern=""
            ;;
    esac

    log_info "正在搜索可用内核..."
    available_kernels=$(apt-cache search "^linux-image-[0-9]" | grep -E "linux-image-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic" | sort -V)
    
    if [[ -z "$available_kernels" ]]; then
        log_warn "在软件源中未找到任何可用的 linux-image-generic 内核包。"
        KERNEL_VERSION="" # 确保为空
        return
    fi
    
    local target_kernel=""

    # 1. 优先尝试从推荐版本中寻找
    if [[ -n "$recommended_kernel_pattern" ]]; then
        log_info "正在根据推荐模式 '$recommended_kernel_pattern' 查找最新内核..."
        target_kernel=$(echo "$available_kernels" | grep "$recommended_kernel_pattern" | tail -n1 | awk '{print $1}' | sed 's/linux-image-//')
        if [[ -n "$target_kernel" ]]; then
            log_info "找到推荐的内核版本: $target_kernel"
        else
            log_warn "未找到匹配推荐模式 '$recommended_kernel_pattern' 的内核。"
        fi
    fi

    # 2. 如果推荐版本未找到，则查找最新的可用内核
    if [[ -z "$target_kernel" ]]; then
        log_info "正在查找可用的最新版本内核..."
        target_kernel=$(echo "$available_kernels" | tail -n1 | awk '{print $1}' | sed 's/linux-image-//')
        if [[ -n "$target_kernel" ]]; then
            log_info "找到最新的可用内核版本: $target_kernel"
        else
            log_warn "无法确定任何可用的目标内核版本。"
        fi
    fi

    # 设置全局变量
    KERNEL_VERSION="$target_kernel"
}

# 步骤 2: 升级内核
upgrade_kernel() {
	log_step "开始内核升级流程..."

    if [[ -z "$KERNEL_VERSION" ]]; then
        log_warn "未检测到合适的目标内核版本，跳过内核升级。"
        return 0
    fi
    
    log_info "目标内核版本已确定为: ${KERNEL_VERSION}"
    
    local current_kernel
    current_kernel=$(uname -r)
    log_info "当前内核版本: $current_kernel"
    
    if [[ "$current_kernel" == "$KERNEL_VERSION" ]]; then
        log_info "当前内核已是目标版本，无需升级。"
        return 0
    fi

	if dpkg -l | grep -q "linux-image-${KERNEL_VERSION}"; then
		log_info "目标内核 ${KERNEL_VERSION} 已安装"
	else
		if ! apt-cache search "linux-image-${KERNEL_VERSION}" | grep -q "linux-image-${KERNEL_VERSION}"; then
			log_warn "在当前软件源中未找到内核 ${KERNEL_VERSION}。"
			log_info "正在添加 PPA: ppa:canonical-kernel-team/ppa 以获取新内核..."
			apt install -y software-properties-common
			add-apt-repository ppa:canonical-kernel-team/ppa -y
			if ! apt update; then
				log_error "更新软件源失败"
				exit 1  
			fi
		fi

		log_info "正在安装新内核及相关组件: ${KERNEL_VERSION}..."
		if ! apt install -y \
			"linux-image-${KERNEL_VERSION}" \
			"linux-headers-${KERNEL_VERSION}" \
			"linux-modules-extra-${KERNEL_VERSION}"; then
			log_error "内核安装失败"
			exit 1
		fi
	fi

	log_info "内核安装完毕。正在更新 GRUB 配置..."
	if ! update-grub; then
		log_error "GRUB 更新失败"
		exit 1
	fi

	log_info "内核升级流程完成。重启后将生效。"
}

# 步骤 3: 安装桌面
install_desktop() {
	log_step "开始安装 GNOME 桌面环境和 XRDP..."
	
	if dpkg -l | grep -q ubuntu-gnome-desktop; then
		log_info "GNOME 桌面已安装，跳过安装步骤"
	else
		log_info "正在安装 GNOME 桌面环境 (最小化安装)..."
		if ! apt install -y ubuntu-gnome-desktop --no-install-recommends; then
			log_error "GNOME 桌面安装失败"
			exit 1
		fi
	fi
	
	if dpkg -l | grep -q xrdp; then
		log_info "XRDP 已安装"
	else
		log_info "正在安装 XRDP..."
		if ! apt install -y xrdp; then
			log_error "XRDP 安装失败"
			exit 1
		fi
	fi
	
	log_info "桌面环境安装完毕。"
	log_info "正在安装 XRDP 依赖组件..."
	apt install -y dbus-x11 xorgxrdp xserver-xorg-core xserver-xorg-video-intel || log_warn "部分XRDP依赖组件安装失败，但可能不影响基本功能"
}

# 步骤 4: 驱动安装-直接覆盖安装
install_nvidia_driver() {
	log_step "开始安装 NVIDIA 驱动..."
	
	if [ ! -f "${NVIDIA_RUNFILE}" ]; then
		log_error "NVIDIA 驱动文件 ${NVIDIA_RUNFILE} 未找到！"
		exit 1
	fi
	
	log_info "当前内核版本: $(uname -r)"
	log_info "目标内核版本: ${KERNEL_VERSION}"
	log_info "驱动文件: ${NVIDIA_RUNFILE}"
	
	if [[ "$(uname -r)" != "${KERNEL_VERSION}" ]]; then
		log_warn "当前运行的内核与目标内核不同"
		log_warn "建议先重启到新内核再安装驱动以获得最佳兼容性"
		echo
		echo "选项："
		echo "1. 继续在当前内核下安装 (可能有兼容性警告)"
		echo "2. 现在重启到新内核，稍后手动运行驱动安装"
		echo "3. 退出脚本"
		read -p "请选择 (1/2/3): " choice
		case "$choice" in 
			1 ) log_info "继续在当前内核下安装...";;
			2 ) 
				log_info "准备重启到新内核..."
				terminal_close_warning
				reboot
				;;
			* ) log_info "退出脚本"; exit 0;;
		esac
	fi
	
	log_warn "这将使用 .run 文件直接安装驱动，可能导致系统不稳定。"
	
	log_info "正在安装构建工具和内核头文件..."
	if ! apt install -y build-essential dkms linux-headers-$(uname -r) gcc make; then
		log_error "构建工具安装失败"
		exit 1
	fi
	
	log_info "检查并禁用 nouveau 开源驱动..."
	if lsmod | grep -q nouveau; then
		log_warn "检测到正在使用的 nouveau 驱动，需要先禁用"
		echo "blacklist nouveau" >> /etc/modprobe.d/blacklist-nouveau.conf
		echo "options nouveau modeset=0" >> /etc/modprobe.d/blacklist-nouveau.conf
		update-initramfs -u
		log_warn "nouveau 驱动已禁用，需要重启后生效"
		read -p "是否现在重启？(建议选择 y) (y/n): " choice
		case "$choice" in 
			y|Y ) 
				terminal_close_warning
				reboot
				;;
			* ) log_warn "继续安装，但可能会有冲突...";;
		esac
	fi

	log_info "正在为驱动文件添加执行权限..."
	chmod +x "${NVIDIA_RUNFILE}"
	
	log_info "正在停止图形界面服务..."
	systemctl stop gdm3 2>/dev/null || log_warn "GDM3 服务未运行或停止失败"
	systemctl stop lightdm 2>/dev/null || log_debug "LightDM 服务未运行"

	log_info "正在执行驱动安装程序 (非交互模式)..."
	log_warn "安装过程中可能会出现编译器版本警告，这通常是正常的"
	
	if ! ./"${NVIDIA_RUNFILE}" \
		--accept-license \
		--no-questions \
		--no-backup \
		--dkms \
		--no-cc-version-check \
		--install-libglvnd \
		--no-nouveau-check \
		--silent; then
		
		log_error "NVIDIA 驱动安装失败"
		log_info "检查安装日志："
		if [[ -f /var/log/nvidia-installer.log ]]; then
			log_info "=== 安装日志的最后几行 ==="
			tail -20 /var/log/nvidia-installer.log
			log_info "=========================="
			log_info "完整日志位于: /var/log/nvidia-installer.log"
		fi
		
		log_info "正在尝试重启图形界面服务..."
		systemctl start gdm3 2>/dev/null || log_warn "无法启动GDM3服务"
		exit 1
	fi
	
	log_info "NVIDIA 驱动安装成功。"
	
	if command -v nvidia-smi >/dev/null 2>&1; then
		log_info "验证驱动安装："
		nvidia-smi --query-gpu=name,driver_version --format=csv,noheader,nounits || log_warn "无法查询GPU信息，可能需要重启"
	else
		log_warn "nvidia-smi 命令不可用，可能需要重启系统"
	fi
}

# 步骤 5: 配置 XRDP 和开放 root 登录
configure_system() {
	log_step "正在配置 XRDP 和系统设置..."
	
	check_and_ensure_file() {
		local file="$1"
		local create_if_missing="${2:-false}"
		local dir
        dir=$(dirname "$file")
		if [[ ! -d "$dir" ]]; then
			log_warn "目录 $dir 不存在，尝试创建..."
			if ! mkdir -p "$dir"; then log_error "无法创建目录 $dir"; return 1; fi
		fi
		if [[ ! -f "$file" ]] && [[ "$create_if_missing" == "true" ]]; then
			log_info "文件 $file 不存在，创建中..."
			if ! touch "$file"; then log_error "无法创建文件 $file"; return 1; fi
		fi
		if [[ ! -f "$file" ]]; then log_error "文件 $file 不存在"; return 1; fi
		if [[ ! -w "$file" ]]; then log_error "文件 $file 没有写入权限"; return 1; fi
		return 0
	}
	
	backup_file() {
		local file="$1"
		local backup_file="${file}.backup.$(date +%Y%m%d_%H%M%S)"
		if [[ -f "$file" ]]; then
			log_info "备份文件 $file 到 $backup_file"
			if ! cp "$file" "$backup_file"; then log_warn "备份文件 $file 失败"; return 1; fi
		fi
		return 0
	}

	log_info "检查并修改 XRDP 配置..."
	if check_and_ensure_file "/etc/xrdp/xrdp.ini" "false"; then
		backup_file "/etc/xrdp/xrdp.ini"
		sed -i 's/use_vsock=true/use_vsock=false/g' /etc/xrdp/xrdp.ini
		sed -i 's/tcp_nodelay=true/tcp_nodelay=true\ntcp_keepalive=true/' /etc/xrdp/xrdp.ini
		log_info "XRDP 配置文件修改完成"
	else
		log_error "无法访问 /etc/xrdp/xrdp.ini，跳过此步骤"
	fi

	log_info "检查并配置 XRDP 启动脚本..."
	if check_and_ensure_file "/etc/xrdp/startwm.sh" "true"; then
		backup_file "/etc/xrdp/startwm.sh"
		cat > /etc/xrdp/startwm.sh << 'EOF'
#!/bin/sh
if test -r /etc/profile; then . /etc/profile; fi
if [ -r /etc/default/locale ]; then
	. /etc/default/locale
	export LANG LANGUAGE LC_ALL LC_COLLATE LC_CTYPE LC_MESSAGES 
	export LC_MONETARY LC_NUMERIC LC_TIME
fi
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
export $(dbus-launch)
if [ -x /usr/bin/gnome-session ]; then exec /usr/bin/gnome-session;
elif [ -x /usr/bin/startxfce4 ]; then exec /usr/bin/startxfce4;
elif test -x /etc/X11/Xsession; then exec /etc/X11/Xsession;
else exec /bin/sh /etc/X11/Xsession; fi  
EOF

		chmod +x /etc/xrdp/startwm.sh
		log_info "XRDP 启动脚本配置完成"
	else
		log_error "无法访问 /etc/xrdp/startwm.sh，跳过此步骤"
	fi

	log_info "为 root 用户创建 .xsession 文件..."
	if check_and_ensure_file "/root/.xsession" "true"; then
		backup_file "/root/.xsession"
		cat > /root/.xsession << 'EOF'
#!/bin/bash
export XDG_SESSION_TYPE=x11
export GDK_BACKEND=x11
exec gnome-session --session=ubuntu
EOF

		chmod +x /root/.xsession  
		log_info ".xsession 文件创建完成"
	else
		log_error "无法创建 /root/.xsession，跳过此步骤"
	fi

	log_warn "=== 正在执行高风险操作：开放 root 图形登录 ==="

	log_info "修改 GDM 配置允许 root 登录..."
	if check_and_ensure_file "/etc/gdm3/custom.conf" "true"; then
		backup_file "/etc/gdm3/custom.conf"
		cat > /etc/gdm3/custom.conf << 'EOF'
# GDM configuration storage  
[daemon]
#WaylandEnable=false
AllowRoot=true
[security]
[xdmcp]
[chooser]
[debug]
#Enable=true
EOF

		log_info "GDM 配置文件更新完成"
	else
		log_error "无法访问 /etc/gdm3/custom.conf，跳过此步骤"
	fi

	log_info "修改 PAM 规则以允许 root 登录..."
	if check_and_ensure_file "/etc/pam.d/gdm-autologin" "false"; then
		backup_file "/etc/pam.d/gdm-autologin"
		sed -i 's/^auth\s*required\s*pam_succeed_if.so\s*user\s*!=\s*root.*$/#&/' /etc/pam.d/gdm-autologin
		log_info "已修改 gdm-autologin PAM 规则"
	else
		log_warn "无法访问 /etc/pam.d/gdm-autologin，跳过此步骤"
	fi
	
	if check_and_ensure_file "/etc/pam.d/gdm-password" "false"; then
		backup_file "/etc/pam.d/gdm-password"
		sed -i 's/^auth\s*required\s*pam_succeed_if.so\s*user\s*!=\s*root.*$/#&/' /etc/pam.d/gdm-password
		log_info "已修改 gdm-password PAM 规则"
	else
		log_warn "无法访问 /etc/pam.d/gdm-password，跳过此步骤"
	fi

	log_info "配置 XRDP 用户权限..."
	usermod -a -G ssl-cert xrdp 2>/dev/null || log_warn "无法将 xrdp 用户添加到 ssl-cert 组"
	
	log_info "正在配置系统服务..."
	systemctl stop gdm3 2>/dev/null || log_debug "GDM3 未运行"
	systemctl stop xrdp 2>/dev/null || log_debug "XRDP 未运行"
	
	if systemctl enable gdm3; then log_info "GDM3 服务已启用自启动"; else log_error "GDM3 服务启用失败"; fi
	if systemctl enable xrdp; then log_info "XRDP 服务已启用自启动"; else log_error "XRDP 服务启用失败"; fi
	if systemctl start xrdp; then log_info "XRDP 服务启动成功"; else log_error "XRDP 服务启动失败"; fi

	log_info "XRDP 配置完成！"
	log_info "备份文件位于各原文件同目录下，以 .backup.时间戳 结尾"
	log_info "XRDP 默认端口: 3389"
}

# 步骤 6: 安装中文支持
install_chinese_support() {
	log_step "正在安装中文语言包和字体..."
	
	if ! apt install -y language-pack-zh-hans language-pack-zh-hans-base fonts-noto-cjk fonts-noto-cjk-extra; then
		log_error "中文语言包安装失败"; exit 1;
	fi
	
	log_info "正在生成中文 locale..."
	if ! locale-gen zh_CN.UTF-8; then log_error "中文 locale 生成失败"; exit 1; fi
	
	log_info "将系统默认语言设置为中文..."
	if ! update-locale LANG=zh_CN.UTF-8; then log_error "系统语言设置失败"; exit 1; fi
	
	sed -i '/^export LANG=zh_CN.UTF-8$/d' /root/.bashrc
	echo 'export LANG=zh_CN.UTF-8' >> /root/.bashrc    
	sed -i '/^export LC_ALL=zh_CN.UTF-8$/d' /root/.bashrc
	echo 'export LC_ALL=zh_CN.UTF-8' >> /root/.bashrc
	log_info "中文支持配置完成。重启后将显示中文界面。"
}

# 最终系统检查和建议
final_system_check() {
	log_step "======== 系统配置完成检查 ========"
	
	log_info "检查关键服务状态..."
	services=("xrdp" "gdm3")
	for service in "${services[@]}"; do  
		if systemctl is-enabled "$service" >/dev/null 2>&1; then
			if systemctl is-active "$service" >/dev/null 2>&1; then
				log_info "✓ $service: 已启用并运行中"
			else
				log_warn "⚠ $service: 已启用但未运行"
			fi
		else
			log_error "✗ $service: 未启用"
		fi
	done
	
	if command -v nvidia-smi >/dev/null 2>&1; then log_info "✓ NVIDIA 驱动已安装"; else log_warn "⚠ NVIDIA 驱动可能未正确安装"; fi
	
	local current_kernel
    current_kernel=$(uname -r)
	if [[ "$current_kernel" == "$KERNEL_VERSION" ]]; then
		log_info "✓ 当前内核版本正确: $current_kernel"
	else
		log_warn "⚠ 当前内核 ($current_kernel) 与目标内核 ($KERNEL_VERSION) 不同。重启后将应用新内核。"
	fi
	
	log_info "=================================="
	
	log_info "远程连接信息："
	log_info "- RDP 端口: 3389"
	log_info "- 用户名: root"
	log_warn "安全提醒: 生产环境中不建议启用 root 远程登录"
}

# --- 执行流程 ---
main() {
	log_step "========================================================"
	log_step "开始执行 Ubuntu 服务器初始化配置"
	log_step "========================================================"
	
	upgrade_gcc
	upgrade_kernel
	install_desktop
	install_nvidia_driver
	configure_system
	install_chinese_support
	
	log_info "正在清理系统缓存..."
	apt autoremove -y >/dev/null 2>&1
	apt autoclean >/dev/null 2>&1
	
	final_system_check

	log_step "========================================================"  
	log_step "所有操作已成功完成！"
	log_info "脚本将在退出时自动删除自身文件: $SCRIPT_NAME"
	log_warn "强烈建议重启系统以应用所有更改："
	log_warn "- 新内核将生效"
	log_warn "- NVIDIA 驱动将完全加载"
	log_warn "- 中文界面将显示"
	log_warn "- 所有服务将正常启动"
	log_step "========================================================"
	
	echo
	read -p "是否立即重启系统? (强烈推荐) (y/n): " choice
	case "$choice" in 
	  y|Y ) 
		terminal_close_warning
		log_info "正在重启..."
		reboot
		;;
	  * ) 
		log_warn "您选择了不立即重启。"
		log_warn "请记住稍后手动执行 'reboot' 命令重启系统。"
		log_info "脚本执行完毕，即将删除脚本文件..."
		;;
	esac
}


# --- 脚本启动入口 ---
if [ "$(id -u)" -ne 0 ]; then
   log_error "此脚本需要以 root 权限运行。请使用 'sudo ./update_conf.sh'。"
   exit 1
fi

# 1. 基础环境检查
log_step "======== 1. 环境检查 ========"
check_system_version
check_network

# 2. 更新软件源并检测目标
log_step "======== 2. 更新源与检测目标 ========"
change_sources
detect_target_kernel
detect_nvidia_driver

# 3. 显示计划并请求确认
log_step "======== 3. 计划预览与确认 ========"
show_system_info
echo
read -p "检查以上计划。是否继续执行安装和配置? (y/n): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    log_info "操作已由用户取消。"
    exit 0
fi

# 4. 执行主函数
main
