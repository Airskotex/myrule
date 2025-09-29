	#!/bin/bash

	# ==============================================================================
	# Ubuntu Server 初始化配置脚本
	# 作者: Airskotex
	# 日期: 2025-09-17
	# 功能:
	#   0. 升级并配置 GCC 12
	#   1. 更换为阿里云软件源
	#   2. 升级内核
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
	# 请将要安装的内核版本填写在此处
	KERNEL_VERSION="6.8.0-60-generic"

	# 请将您下载的 NVIDIA 驱动文件名填写在此处
	# ** 脚本执行前，请确保此文件与本脚本位于同一目录下 **
	NVIDIA_RUNFILE="NVIDIA-Linux-x86_64-550.107.02.run"

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
		if [[ "$ID" != "ubuntu" ]]; then
			log_error "此脚本仅支持 Ubuntu 系统，当前系统: $ID"
			exit 1
		fi
		
		if [[ "$VERSION_CODENAME" != "jammy" ]]; then
			log_warn "此脚本专为 Ubuntu 22.04 (jammy) 设计，当前版本: $VERSION_CODENAME"
			read -p "是否继续？(y/N): " choice
			case "$choice" in 
				y|Y ) log_info "继续执行...";;
				* ) log_info "退出脚本"; exit 0;;
			esac
		fi
		
		log_info "系统版本检查通过: Ubuntu $VERSION_CODENAME ($VERSION_ID)"
	}

	# 检查和显示系统信息
	show_system_info() {
		log_info "======== 系统信息 ========"
		log_info "当前内核版本: $(uname -r)"
		log_info "目标内核版本: $KERNEL_VERSION"
		log_info "系统架构: $(uname -m)"
		log_info "CPU信息: $(lscpu | grep 'Model name' | cut -d ':' -f2 | xargs)"
		log_info "内存信息: $(free -h | awk '/^Mem:/ {print $2}') 总内存"
		
		# 检查是否有NVIDIA GPU
		if lspci | grep -i nvidia >/dev/null 2>&1; then
			log_info "检测到NVIDIA GPU:"
			lspci | grep -i nvidia | while read line; do
				log_info "  - $line"
			done
		else
			log_warn "未检测到NVIDIA GPU，但仍可继续安装驱动"
		fi
		log_info "=========================="
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

	# --- 脚本主逻辑 ---

	# 步骤 0: 检查 root 权限和系统环境
	if [ "$(id -u)" -ne 0 ]; then
	   log_error "此脚本需要以 root 权限运行。请使用 'sudo ./up_conf.sh'。"
	   exit 1
	fi

	# 系统检查
	log_step "========================================================"
	log_step "开始执行系统环境检查"
	log_step "========================================================"

	check_system_version
	check_network
	show_system_info
	detect_nvidia_driver

	log_info "环境检查完成，开始执行配置脚本..."

	# ==============================================================================
	# 升级 GCC
	# ==============================================================================
	upgrade_gcc() {
		log_step "开始升级 GCC 至版本 12..."

		# 1. 添加 PPA
		log_info "确保 add-apt-repository 命令可用..."
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

		# 2. 安装 GCC 12 和 G++ 12
		log_info "正在安装 gcc-12 和 g++-12..."
		if ! apt install -y gcc-12 g++-12; then
			log_error "GCC 12 安装失败"
			exit 1
		fi

		# 3. 设置默认版本
		log_info "正在配置 update-alternatives 以设置 GCC 12 为默认版本..."
		if ! update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 100; then
			log_error "设置 gcc 默认版本失败"
			exit 1
		fi
		if ! update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-12 100; then
			log_error "设置 g++ 默认版本失败"
			exit 1
		fi

		# 4. 验证
		log_info "验证 GCC 版本..."
		if gcc --version | grep -q "gcc (Ubuntu 12"; then
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
		log_step "开始更换 APT 软件源为阿里云..."
		log_info "正在备份原始 sources.list 文件..."
		cp /etc/apt/sources.list /etc/apt/sources.list.bak_$(date +%F_%H%M%S)

		log_info "正在写入新的阿里云 sources.list..."
		cat > /etc/apt/sources.list << EOF
	deb https://mirrors.aliyun.com/ubuntu/ jammy main restricted universe multiverse
	deb-src https://mirrors.aliyun.com/ubuntu/ jammy main restricted universe multiverse

	deb https://mirrors.aliyun.com/ubuntu/ jammy-security main restricted universe multiverse
	deb-src https://mirrors.aliyun.com/ubuntu/ jammy-security main restricted universe multiverse

	deb https://mirrors.aliyun.com/ubuntu/ jammy-updates main restricted universe multiverse
	deb-src https://mirrors.aliyun.com/ubuntu/ jammy-updates main restricted universe multiverse

	# deb https://mirrors.aliyun.com/ubuntu/ jammy-proposed main restricted universe multiverse
	# deb-src https://mirrors.aliyun.com/ubuntu/ jammy-proposed main restricted universe multiverse

	deb https://mirrors.aliyun.com/ubuntu/ jammy-backports main restricted universe multiverse
	deb-src https://mirrors.aliyun.com/ubuntu/ jammy-backports main restricted universe multiverse
EOF    

		log_info "软件源更换完毕，正在执行 apt update..."
		if ! apt update; then
			log_error "apt update 失败，请检查网络连接和软件源配置"
			exit 1
		fi
		log_info "软件源更新成功"
	}

	# 步骤 2: 升级内核
	upgrade_kernel() {
		log_step "开始升级内核至版本: ${KERNEL_VERSION}..."
		
		# 检查内核是否已安装
		if dpkg -l | grep -q "linux-image-${KERNEL_VERSION}"; then
			log_info "目标内核 ${KERNEL_VERSION} 已安装"
		else
			# 检查内核是否已在当前源中可用
			if ! apt-cache search "linux-image-${KERNEL_VERSION}" | grep -q "linux-image-${KERNEL_VERSION}"; then
				log_warn "在当前软件源中未找到内核 ${KERNEL_VERSION}。"
				log_info "正在添加 PPA: ppa:canonical-kernel-team/ppa 以获取新内核..."
				# 确保 add-apt-repository 命令可用
				apt install -y software-properties-common
				add-apt-repository ppa:canonical-kernel-team/ppa -y
				if ! apt update; then
					log_error "更新软件源失败"
					exit 1  
				fi
			fi

			log_info "正在安装新内核及相关组件..."
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
		
		# 检查是否已安装桌面环境
		if dpkg -l | grep -q ubuntu-gnome-desktop; then
			log_info "GNOME 桌面已安装，跳过安装步骤"
		else
			log_info "正在安装 GNOME 桌面环境 (最小化安装)..."
			# --no-install-recommends 保证最小化安装
			if ! apt install -y ubuntu-gnome-desktop --no-install-recommends; then
				log_error "GNOME 桌面安装失败"
				exit 1
			fi
		fi
		
		# 安装 XRDP
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
		
		# 显示当前系统信息
		log_info "当前内核版本: $(uname -r)"
		log_info "目标内核版本: ${KERNEL_VERSION}"
		log_info "驱动文件: ${NVIDIA_RUNFILE}"
		
		# 检查是否需要重启到新内核
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
		
		# 安装完整的构建环境
		log_info "正在安装构建工具和内核头文件..."
		if ! apt install -y build-essential dkms linux-headers-$(uname -r) gcc make; then
			log_error "构建工具安装失败"
			exit 1
		fi
		
		# 检查并禁用 nouveau 驱动
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
		
		# 使用更详细的选项来安装驱动
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
		
		# 验证安装
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
		
		# 函数：检查文件是否存在并可写，如果不存在则尝试创建
		check_and_ensure_file() {
			local file="$1"
			local create_if_missing="${2:-false}"
			
			# 检查目录是否存在
			local dir=$(dirname "$file")
			if [[ ! -d "$dir" ]]; then
				log_warn "目录 $dir 不存在，尝试创建..."
				if ! mkdir -p "$dir"; then
					log_error "无法创建目录 $dir"
					return 1
				fi
			fi
			
			# 如果文件不存在且允许创建，则创建空文件
			if [[ ! -f "$file" ]] && [[ "$create_if_missing" == "true" ]]; then
				log_info "文件 $file 不存在，创建中..."
				if ! touch "$file"; then
					log_error "无法创建文件 $file"
					return 1
				fi
			fi
			
			# 检查文件是否存在
			if [[ ! -f "$file" ]]; then
				log_error "文件 $file 不存在"
				return 1
			fi
			
			# 检查文件是否可写
			if [[ ! -w "$file" ]]; then
				log_error "文件 $file 没有写入权限"
				return 1
			fi
			
			return 0
		}
		
		# 函数：备份文件
		backup_file() {
			local file="$1"
			local backup_file="${file}.backup.$(date +%Y%m%d_%H%M%S)"
			
			if [[ -f "$file" ]]; then
				log_info "备份文件 $file 到 $backup_file"
				if ! cp "$file" "$backup_file"; then
					log_warn "备份文件 $file 失败"
					return 1
				fi
			fi
			return 0
		}

		# 1. 修改 XRDP 配置文件
		log_info "检查并修改 XRDP 配置..."
		if check_and_ensure_file "/etc/xrdp/xrdp.ini" "false"; then
			backup_file "/etc/xrdp/xrdp.ini"
			# 禁用 VSock，解决部分虚拟机中的兼容问题
			sed -i 's/use_vsock=true/use_vsock=false/g' /etc/xrdp/xrdp.ini
			# 优化 XRDP 性能设置
			sed -i 's/tcp_nodelay=true/tcp_nodelay=true\ntcp_keepalive=true/' /etc/xrdp/xrdp.ini
			log_info "XRDP 配置文件修改完成"
		else
			log_error "无法访问 /etc/xrdp/xrdp.ini，跳过此步骤"
		fi

		# 2. 配置 XRDP 启动脚本
		log_info "检查并配置 XRDP 启动脚本..."
		if check_and_ensure_file "/etc/xrdp/startwm.sh" "true"; then
			backup_file "/etc/xrdp/startwm.sh"
			
			# 清除旧的配置并写入新配置
			cat > /etc/xrdp/startwm.sh << 'EOF'
	#!/bin/sh
	# xrdp X session start script (c) 2015, 2017, 2021 mirabilos
	# published under The MirOS Licence

	# Rely on /etc/pam.d/xrdp-sesman using pam_env to load both
	# /etc/environment and /etc/default/locale to initialise the
	# locale and the user environment properly.
	if test -r /etc/profile; then
			. /etc/profile
	fi
	#启动 dbus
	export $(dbus-launch)
	test -x /etc/X11/Xsession && exec /etc/X11/Xsession
	exec /bin/sh /etc/X11/Xsession
	
	if [ -r /etc/default/locale ]; then
	  . /etc/default/locale
	  export LANG LANGUAGE LC_ALL LC_COLLATE LC_CTYPE LC_MESSAGES 
	  export LC_MONETARY LC_NUMERIC LC_TIME
	fi

	# 解决XRDP环境变量问题
	unset DBUS_SESSION_BUS_ADDRESS
	unset XDG_RUNTIME_DIR

	# 启动GNOME会话
	if [ -x /usr/bin/gnome-session ]; then
		exec /usr/bin/gnome-session
	fi

	# 备用启动选项
	if [ -x /usr/bin/startxfce4 ]; then
		exec /usr/bin/startxfce4
	fi

	# 最后备用选项
	exec /bin/sh /etc/xrdp/startwm.sh.distro
	EOF
			
			chmod +x /etc/xrdp/startwm.sh
			log_info "XRDP 启动脚本配置完成"
		else
			log_error "无法访问 /etc/xrdp/startwm.sh，跳过此步骤"
		fi

		# 3. 为 root 用户创建 .xsession 文件
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

		# 4. 修改 GDM 配置允许 root
		log_info "修改 GDM 配置允许 root 登录..."
		if check_and_ensure_file "/etc/gdm3/custom.conf" "true"; then
			backup_file "/etc/gdm3/custom.conf"
			
			# 创建完整的配置文件
			cat > /etc/gdm3/custom.conf << 'EOF'
	# GDM configuration storage

	[daemon]
	# Uncomment the line below to force the login screen to use Xorg
	#WaylandEnable=false
	AllowRoot=true

	# Enabling automatic login
	#  AutomaticLoginEnable = true
	#  AutomaticLogin = user1

	# Enabling timed login
	#  TimedLoginEnable = true
	#  TimedLogin = user1
	#  TimedLoginDelay = 10

	[security]

	[xdmcp]

	[chooser]

	[debug]
	# Uncomment the line below to turn on debugging
	# More verbose logs
	# Additionally lets the X server dump core if it crashes
	#Enable=true
	EOF
			log_info "GDM 配置文件更新完成"
		else
			log_error "无法访问 /etc/gdm3/custom.conf，跳过此步骤"
		fi

		# 5. 修改 PAM 配置
		log_info "修改 PAM 规则以允许 root 登录..."
		
		# 处理 gdm-autologin
		if check_and_ensure_file "/etc/pam.d/gdm-autologin" "false"; then
			backup_file "/etc/pam.d/gdm-autologin"
			sed -i 's/^auth\s*required\s*pam_succeed_if.so\s*user\s*!=\s*root.*$/#&/' /etc/pam.d/gdm-autologin
			log_info "已修改 gdm-autologin PAM 规则"
		else
			log_warn "无法访问 /etc/pam.d/gdm-autologin，跳过此步骤"
		fi
		
		# 处理 gdm-password
		if check_and_ensure_file "/etc/pam.d/gdm-password" "false"; then
			backup_file "/etc/pam.d/gdm-password"
			sed -i 's/^auth\s*required\s*pam_succeed_if.so\s*user\s*!=\s*root.*$/#&/' /etc/pam.d/gdm-password
			log_info "已修改 gdm-password PAM 规则"
		else
			log_warn "无法访问 /etc/pam.d/gdm-password，跳过此步骤"
		fi

		# 6. 配置 XRDP 用户和组
		log_info "配置 XRDP 用户权限..."
		# 将 xrdp 用户添加到必要的组
		usermod -a -G ssl-cert xrdp 2>/dev/null || log_warn "无法将 xrdp 用户添加到 ssl-cert 组"
		
		# 7. 重启并启用相关服务
		log_info "正在配置系统服务..."
		
		# 停止服务
		systemctl stop gdm3 2>/dev/null || log_debug "GDM3 未运行"
		systemctl stop xrdp 2>/dev/null || log_debug "XRDP 未运行"
		
		# 启用服务
		if systemctl enable gdm3; then
			log_info "GDM3 服务已启用自启动"
		else
			log_error "GDM3 服务启用失败"
		fi
		
		if systemctl enable xrdp; then
			log_info "XRDP 服务已启用自启动"
		else
			log_error "XRDP 服务启用失败"
		fi
		
		# 启动服务
		if systemctl start xrdp; then
			log_info "XRDP 服务启动成功"
		else
			log_error "XRDP 服务启动失败"
		fi

		log_info "XRDP 配置完成！"
		log_info "备份文件位于各原文件同目录下，以 .backup.时间戳 结尾"
		log_info "XRDP 默认端口: 3389"
	}

	# 步骤 6: 安装中文支持
	install_chinese_support() {
		log_step "正在安装中文语言包和字体..."
		
		if ! apt install -y language-pack-zh-hans language-pack-zh-hans-base fonts-noto-cjk fonts-noto-cjk-extra; then
			log_error "中文语言包安装失败"
			exit 1
		fi
		
		log_info "正在生成中文 locale..."
		if ! locale-gen zh_CN.UTF-8; then
			log_error "中文 locale 生成失败"
			exit 1
		fi
		
		log_info "将系统默认语言设置为中文..."
		if ! update-locale LANG=zh_CN.UTF-8; then
			log_error "系统语言设置失败"
			exit 1
		fi
		
		# 为 root 用户设置中文环境，先匹配删除再追加避免重复
		sed -i '/^export LANG=zh_CN.UTF-8$/d' /root/.bashrc
		echo 'export LANG=zh_CN.UTF-8' >> /root/.bashrc    
		sed -i '/^export LC_ALL=zh_CN.UTF-8$/d' /root/.bashrc
		echo 'export LC_ALL=zh_CN.UTF-8' >> /root/.bashrc
		log_info "中文支持配置完成。"
		log_info "重启后将显示中文界面。"
	}

	# 最终系统检查和建议
	final_system_check() {
		log_step "======== 系统配置完成检查 ========"
		
		# 检查关键服务状态
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
		
		# 检查NVIDIA驱动
		if command -v nvidia-smi >/dev/null 2>&1; then
			log_info "✓ NVIDIA 驱动已安装"
		else
			log_warn "⚠ NVIDIA 驱动可能未正确安装"
		fi
		
		# 检查内核版本
		current_kernel=$(uname -r)
		if [[ "$current_kernel" == "$KERNEL_VERSION" ]]; then
			log_info "✓ 当前内核版本正确: $current_kernel"
		else
			log_warn "⚠ 当前内核 ($current_kernel) 与目标内核 ($KERNEL_VERSION) 不同"
		fi
		
		log_info "=================================="
		
		# 提供连接信息
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
		change_sources
		
		upgrade_kernel
		install_desktop
		# 驱动需要桌面环境的一些组件，所以在桌面之后安装
		install_nvidia_driver
		configure_system
		install_chinese_support
		
		# 清理系统
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

	# 执行主函数
	main
