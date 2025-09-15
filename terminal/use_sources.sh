#!/bin/bash

# 软件源管理脚本
# 作者: Airskotex
# 功能: 管理系统软件源，支持备份和还原，支持自删除

# 获取脚本自身的完整路径
SCRIPT_PATH="$(realpath "$0")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"

# 配置文件路径
SOURCES_FILE="/etc/apt/sources.list"
SOURCES_DIR="/etc/apt/sources.list.d"
BACKUP_SUFFIX=".backup"
RESTORE_INFO_FILE="/tmp/sources_restore_info"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# 打印带颜色的消息
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_menu() {
    echo -e "${CYAN}$1${NC}"
}

print_config() {
    echo -e "${MAGENTA}$1${NC}"
}

# 清理函数 - 删除脚本自身
cleanup_script() {
    if [[ "$SCRIPT_NAME" == "use_sources.sh" ]]; then
        print_info "正在清理脚本文件..."
        
        # 使用后台进程延迟删除
        (sleep 1 && rm -f "$SCRIPT_PATH" 2>/dev/null) &
        
        # 如果是从当前目录执行，也尝试删除当前目录下的文件
        if [[ -f "./use_sources.sh" && "$PWD/use_sources.sh" != "$SCRIPT_PATH" ]]; then
            (sleep 1 && rm -f "./use_sources.sh" 2>/dev/null) &
        fi
        
        print_success "脚本文件将在退出后自动清理"
    fi
}

# 设置退出时的清理
setup_cleanup() {
    trap cleanup_script EXIT
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要root权限运行"
        exit 1
    fi
}

# 检测系统发行版
detect_system() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        DISTRO="$ID"
        VERSION="$VERSION_ID"
        CODENAME="$VERSION_CODENAME"
    elif [[ -f /etc/lsb-release ]]; then
        source /etc/lsb-release
        DISTRO="$DISTRIB_ID"
        VERSION="$DISTRIB_RELEASE"
        CODENAME="$DISTRIB_CODENAME"
    else
        print_error "无法检测系统发行版"
        exit 1
    fi
    
    # 转换为小写
    DISTRO=$(echo "$DISTRO" | tr '[:upper:]' '[:lower:]')
    
    print_info "检测到系统: $DISTRO $VERSION ($CODENAME)"
}

# 显示主菜单
show_main_menu() {
    clear
    echo "========================================"
    print_menu "       软件源管理脚本"
    echo "========================================"
    echo
    print_menu "请选择操作："
    echo "1) 配置国内镜像源"
    echo "2) 还原原始软件源"
    echo "3) 查看当前软件源状态"
    echo "4) 测试软件源连通性"
    echo "5) 更新软件包列表"
    echo "6) 显示帮助信息"
    echo "0) 退出并关闭终端"
    echo
    
    # 显示自删除状态
    if [[ "$SCRIPT_NAME" == "use_sources.sh" ]]; then
        print_warning "注意: 退出时将自动删除脚本文件 ($SCRIPT_NAME)"
    fi
    echo
}

# 备份现有源配置
backup_sources() {
    local backup_count=0
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    
    print_info "备份现有软件源配置..."
    
    # 记录备份信息
    echo "# 软件源备份信息 - $(date)" > "$RESTORE_INFO_FILE"
    echo "SOURCES_FILE=$SOURCES_FILE" >> "$RESTORE_INFO_FILE"
    echo "SOURCES_DIR=$SOURCES_DIR" >> "$RESTORE_INFO_FILE"
    echo "BACKUP_FILES=(" >> "$RESTORE_INFO_FILE"
    
    # 备份主sources.list文件
    if [[ -f "$SOURCES_FILE" ]]; then
        local backup_file="${SOURCES_FILE}${BACKUP_SUFFIX}_${timestamp}"
        cp "$SOURCES_FILE" "$backup_file"
        print_success "备份主配置文件: $(basename "$SOURCES_FILE") -> $(basename "$backup_file")"
        echo "    \"$(basename "$backup_file")\"" >> "$RESTORE_INFO_FILE"
        ((backup_count++))
    fi
    
    # 备份sources.list.d目录下的文件
    if [[ -d "$SOURCES_DIR" ]]; then
        for file in "$SOURCES_DIR"/*.list; do
            if [[ -f "$file" && ! "$file" =~ \.backup_ ]]; then
                local backup_file="${file}${BACKUP_SUFFIX}_${timestamp}"
                cp "$file" "$backup_file"
                print_success "备份源文件: $(basename "$file") -> $(basename "$backup_file")"
                echo "    \"$(basename "$backup_file")\"" >> "$RESTORE_INFO_FILE"
                ((backup_count++))
            fi
        done
    fi
    
    echo ")" >> "$RESTORE_INFO_FILE"
    echo "TIMESTAMP=$timestamp" >> "$RESTORE_INFO_FILE"
    
    print_success "共备份 $backup_count 个文件"
}

# 获取镜像源选择
get_mirror_choice() {
    echo
    print_info "请选择国内镜像源："
    echo "1) 阿里云镜像 (推荐)"
    echo "2) 清华大学镜像"
    echo "3) 中科大镜像"
    echo "4) 华为云镜像"
    echo "5) 腾讯云镜像"
    echo "6) 网易163镜像"
    
    while true; do
        echo
        read -p "请选择 (1-6, 默认为1): " choice
        
        case "$choice" in
            ""|"1")
                MIRROR_URL="mirrors.aliyun.com"
                MIRROR_NAME="阿里云"
                break
                ;;
            "2")
                MIRROR_URL="mirrors.tuna.tsinghua.edu.cn"
                MIRROR_NAME="清华大学"
                break
                ;;
            "3")
                MIRROR_URL="mirrors.ustc.edu.cn"
                MIRROR_NAME="中科大"
                break
                ;;
            "4")
                MIRROR_URL="mirrors.huaweicloud.com"
                MIRROR_NAME="华为云"
                break
                ;;
            "5")
                MIRROR_URL="mirrors.cloud.tencent.com"
                MIRROR_NAME="腾讯云"
                break
                ;;
            "6")
                MIRROR_URL="mirrors.163.com"
                MIRROR_NAME="网易163"
                break
                ;;
            *)
                print_error "无效选择，请输入1-6之间的数字"
                ;;
        esac
    done
    
    print_success "选择的镜像源: $MIRROR_NAME ($MIRROR_URL)"
}

# 生成Ubuntu/Debian源配置
generate_ubuntu_sources() {
    local sources_content=""
    
    case "$DISTRO" in
        "ubuntu")
            sources_content="# Ubuntu $VERSION ($CODENAME) 软件源配置
# 由软件源管理脚本生成 - $(date)

# 主要软件源
deb http://$MIRROR_URL/ubuntu/ $CODENAME main restricted universe multiverse
deb-src http://$MIRROR_URL/ubuntu/ $CODENAME main restricted universe multiverse

# 更新源
deb http://$MIRROR_URL/ubuntu/ ${CODENAME}-updates main restricted universe multiverse
deb-src http://$MIRROR_URL/ubuntu/ ${CODENAME}-updates main restricted universe multiverse

# 安全更新源
deb http://$MIRROR_URL/ubuntu/ ${CODENAME}-security main restricted universe multiverse
deb-src http://$MIRROR_URL/ubuntu/ ${CODENAME}-security main restricted universe multiverse

# 预发布软件源
deb http://$MIRROR_URL/ubuntu/ ${CODENAME}-proposed main restricted universe multiverse
deb-src http://$MIRROR_URL/ubuntu/ ${CODENAME}-proposed main restricted universe multiverse

# 补丁源
deb http://$MIRROR_URL/ubuntu/ ${CODENAME}-backports main restricted universe multiverse
deb-src http://$MIRROR_URL/ubuntu/ ${CODENAME}-backports main restricted universe multiverse"
            ;;
        "debian")
            sources_content="# Debian $VERSION ($CODENAME) 软件源配置
# 由软件源管理脚本生成 - $(date)

# 主要软件源
deb http://$MIRROR_URL/debian/ $CODENAME main contrib non-free
deb-src http://$MIRROR_URL/debian/ $CODENAME main contrib non-free

# 更新源
deb http://$MIRROR_URL/debian/ ${CODENAME}-updates main contrib non-free
deb-src http://$MIRROR_URL/debian/ ${CODENAME}-updates main contrib non-free

# 安全更新源
deb http://$MIRROR_URL/debian-security/ ${CODENAME}-security main contrib non-free
deb-src http://$MIRROR_URL/debian-security/ ${CODENAME}-security main contrib non-free"
            ;;
        *)
            print_error "不支持的发行版: $DISTRO"
            return 1
            ;;
    esac
    
    echo "$sources_content"
}

# 配置镜像源
configure_mirror_sources() {
    echo "========================================"
    print_info "配置国内镜像源"
    echo "========================================"
    
    # 检测系统
    detect_system
    
    # 检查是否支持的系统
    if [[ "$DISTRO" != "ubuntu" && "$DISTRO" != "debian" ]]; then
        print_error "当前系统 ($DISTRO) 暂不支持自动配置"
        echo
        read -p "按回车键返回主菜单..."
        return 1
    fi
    
    # 备份现有配置
    backup_sources
    
    # 获取镜像选择
    get_mirror_choice
    
    # 生成新的源配置
    print_info "生成新的软件源配置..."
    local new_sources
    new_sources=$(generate_ubuntu_sources)
    
    if [[ -z "$new_sources" ]]; then
        print_error "生成源配置失败"
        return 1
    fi
    
    # 写入新配置
    echo "$new_sources" > "$SOURCES_FILE"
    print_success "已更新软件源配置"
    
    # 显示新配置
    echo
    print_info "新的软件源配置:"
    echo "----------------------------------------"
    cat "$SOURCES_FILE"
    echo "----------------------------------------"
    
    # 询问是否更新软件包列表
    echo
    read -p "是否现在更新软件包列表？(y/N): " update_now
    
    if [[ "$update_now" =~ ^[Yy]$ ]]; then
        update_package_list
    else
        print_warning "请记得手动更新软件包列表: apt update"
    fi
    
    echo
    print_success "镜像源配置完成！"
    print_info "备份信息已保存，可以使用还原功能恢复原始配置"
    echo
    read -p "按回车键返回主菜单..."
}

# 还原原始软件源
restore_sources() {
    echo "========================================"
    print_info "还原原始软件源"
    echo "========================================"
    
    if [[ ! -f "$RESTORE_INFO_FILE" ]]; then
        print_error "没有找到备份信息文件，无法还原"
        echo "可能原因："
        echo "• 没有执行过镜像源配置操作"
        echo "• 备份信息文件被删除"
        echo
        read -p "按回车键返回主菜单..."
        return 1
    fi
    
    source "$RESTORE_INFO_FILE"
    
    print_info "发现备份信息，准备还原软件源配置..."
    echo
    print_warning "还原操作将："
    echo "• 恢复所有备份的软件源文件"
    echo "• 覆盖当前的软件源配置"
    echo
    
    read -p "确定要继续吗？(y/N): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "还原操作已取消"
        echo
        read -p "按回车键返回主菜单..."
        return 0
    fi
    
    # 还原备份文件
    local restore_count=0
    if [[ ${#BACKUP_FILES[@]} -gt 0 ]]; then
        for backup_file in "${BACKUP_FILES[@]}"; do
            # 找到对应的原文件路径
            if [[ "$backup_file" == *"sources.list"* ]]; then
                original_file="$SOURCES_FILE"
                full_backup_path="${SOURCES_FILE}${BACKUP_SUFFIX}_${TIMESTAMP}"
            else
                original_file="$SOURCES_DIR/${backup_file%${BACKUP_SUFFIX}_${TIMESTAMP}}"
                full_backup_path="$SOURCES_DIR/$backup_file"
            fi
            
            if [[ -f "$full_backup_path" ]]; then
                cp "$full_backup_path" "$original_file"
                print_success "已还原: $(basename "$original_file")"
                ((restore_count++))
                
                # 删除备份文件
                rm -f "$full_backup_path"
            fi
        done
    fi
    
    if [[ $restore_count -gt 0 ]]; 键，然后
        print_success "已还原 $restore_count 个文件"
    else
        print_warning "没有找到需要还原的备份文件"
    fi
    
    # 清理还原信息文件
    rm -f "$RESTORE_INFO_FILE"
    print_success "清理备份信息文件"
    
    # 询问是否更新软件包列表
    echo
    read -p "是否现在更新软件包列表？(y/N): " update_now
    
    if [[ "$update_now" =~ ^[Yy]$ ]]; then
        update_package_list
    fi
    
    echo
    print_success "还原操作完成！"
    read -p "按回车键返回主菜单..."
}

# 查看当前软件源状态
check_sources_status() {
    clear
    echo "========================================"
    print_info "当前软件源状态"
    echo "========================================"
    
    # 显示主配置文件
    if [[ -f "$SOURCES_FILE" ]]; then
        print_success "主配置文件: $SOURCES_FILE"
        echo
        print_info "主配置文件内容:"
        echo "----------------------------------------"
        # 过滤掉注释和空行，只显示有效配置
        grep -v '^#' "$SOURCES_FILE" | grep -v '^$' | while read -r line; do
            echo "  $line"
        done
        echo "----------------------------------------"
    else
        print_error "主配置文件不存在: $SOURCES_FILE"
    fi
    
    echo
    
    # 显示额外配置文件
    if [[ -d "$SOURCES_DIR" ]]; then
        print_info "额外配置文件目录: $SOURCES_DIR"
        local extra_count=0
        for file in "$SOURCES_DIR"/*.list; do
            if [[ -f "$file" && ! "$file" =~ \.backup_ ]]; then
                print_success "发现配置文件: $(basename "$file")"
                ((extra_count++))
            fi
        done
        
        if [[ $extra_count -eq 0 ]]; then
            print_warning "没有额外的配置文件"
        fi
    fi
    
    echo
    
    # 显示备份状态
    print_info "备份状态:"
    if [[ -f "$RESTORE_INFO_FILE" ]]; then
        print_success "发现备份信息，可以进行还原操作"
        
        # 显示备份文件列表
        local backup_count=0
        for file in "$SOURCES_FILE"${BACKUP_SUFFIX}_* "$SOURCES_DIR"/*${BACKUP_SUFFIX}_*; do
            if [[ -f "$file" ]]; then
                print_info "备份文件: $(basename "$file")"
                ((backup_count++))
            fi
        done
        
        if [[ $backup_count -gt 0 ]]; then
            print_info "共找到 $backup_count 个备份文件"
        fi
    else
        print_warning "没有备份信息文件"
    fi
    
    echo
    read -p "按回车键返回主菜单..."
}

# 测试软件源连通性
test_sources_connectivity() {
    echo "========================================"
    print_info "测试软件源连通性"
    echo "========================================"
    
    if [[ ! -f "$SOURCES_FILE" ]]; then
        print_error "软件源配置文件不存在"
        echo
        read -p "按回车键返回主菜单..."
        return 1
    fi
    
    # 提取所有deb源URL
    local urls=()
    while read -r line; do
        if [[ "$line" =~ ^deb[[:space:]]+([^[:space:]]+) ]]; then
            local url="${BASH_REMATCH[1]}"
            # 去掉协议部分，只保留域名
            local domain=$(echo "$url" | sed 's|^https\?://||' | cut -d'/' -f1)
            urls+=("$domain")
        fi
    done < <(grep '^deb ' "$SOURCES_FILE")
    
    # 去重
    local unique_urls=($(printf '%s\n' "${urls[@]}" | sort -u))
    
    if [[ ${#unique_urls[@]} -eq 0 ]]; then
        print_warning "没有找到可测试的源地址"
        echo
        read -p "按回车键返回主菜单..."
        return 1
    fi
    
    print_info "开始测试 ${#unique_urls[@]} 个源地址的连通性..."
    echo
    
    local success_count=0
    local total_count=${#unique_urls[@]}
    
    for url in "${unique_urls[@]}"; do
        echo -n "测试 $url ... "
        
        if timeout 5 ping -c 1 "$url" >/dev/null 2>&1; then
            print_success "连通"
            ((success_count++))
        else
            print_error "失败"
        fi
    done
    
    echo
    print_info "连通性测试完成"
    print_config "成功: $success_count/$total_count"
    
    if [[ $success_count -eq $total_count ]]; then
        print_success "所有软件源连通性正常"
    elif [[ $success_count -gt 0 ]]; then
        print_warning "部分软件源连通性存在问题"
    else
        print_error "所有软件源连通性都存在问题"
    fi
    
    echo
    read -p "按回车键返回主菜单..."
}

# 更新软件包列表
update_package_list() {
    print_info "更新软件包列表..."
    
    if apt update; then
        print_success "软件包列表更新成功"
    else
        print_error "软件包列表更新失败"
        print_info "可能的原因："
        echo "• 网络连接问题"
        echo "• 软件源配置错误"
        echo "• DNS解析问题"
    fi
}

# 显示帮助信息
show_help() {
    clear
    echo "========================================"
    print_menu "软件源管理脚本 - 帮助信息"
    echo "========================================"
    echo
    print_info "脚本功能："
    echo "• 一键配置国内镜像源(支持Ubuntu/Debian)"
    echo "• 自动备份现有软件源配置"
    echo "• 支持完全还原到原始配置"
    echo "• 测试软件源连通性"
    echo "• 更新软件包列表"
    echo "• 自动清理脚本文件(适合一次性使用)"
    echo
    print_info "支持的镜像源："
    echo "• 阿里云镜像 (mirrors.aliyun.com)"
    echo "• 清华大学镜像 (mirrors.tuna.tsinghua.edu.cn)"
    echo "• 中科大镜像 (mirrors.ustc.edu.cn)"
    echo "• 华为云镜像 (mirrors.huaweicloud.com)"
    echo "• 腾讯云镜像 (mirrors.cloud.tencent.com)"
    echo "• 网易163镜像 (mirrors.163.com)"
    echo
    print_info "支持的系统："
    echo "• Ubuntu (所有LTS版本和最新版本)"
    echo "• Debian (stable/testing/unstable)"
    echo
    print_info "使用建议："
    echo "• 建议选择地理位置较近的镜像源"
    echo "• 配置前会自动备份原始配置"
    echo "• 可以随时还原到原始状态"
    echo "• 建议配置后测试连通性"
    echo
    print_warning "注意事项："
    echo "• 需要root权限运行"
    echo "• 备份文件会保存在原配置文件同目录"
    echo "• 还原后备份文件会被自动清理"
    echo "• 脚本退出时会自动删除自身(use_sources.sh)"
    echo
    read -p "按回车键返回主菜单..."
}

# 退出并关闭终端(支持自删除)
exit_and_close() {
    print_info "感谢使用软件源管理脚本！"
    echo
    
    # 显示自删除提示
    if [[ "$SCRIPT_NAME" == "use_sources.sh" ]]; then
        print_warning "将清理脚本文件: $SCRIPT_NAME"
    fi
    
    print_warning "3秒后将关闭终端..."
    
    for i in {3..1}; do
        echo -ne "\r关闭倒计时: ${i}秒 "
        sleep 1
    done
    
    echo -e "\n再见！"
    
    # 尝试关闭终端
    if [[ -n "$DISPLAY" ]]; then
        # 图形环境
        pkill -f "$(ps -p $PPID -o comm=)" 2>/dev/null || exit 0
    else
        # 命令行环境
        exit 0
    fi
}

# 主程序循环
main() {
    # 设置清理trap
    setup_cleanup
    
    check_root
    
    while true; do
        show_main_menu
        read -p "请选择操作 (0-6): " choice
        
        case "$choice" in
            1)
                configure_mirror_sources
                ;;
            2)
                restore_sources
                ;;
            3)
                check_sources_status
                ;;
            4)
                test_sources_connectivity
                ;;
            5)
                update_package_list
                echo
                read -p "按回车键返回主菜单..."
                ;;
            6)
                show_help
                ;;
            0)
                exit_and_close
                ;;
            *)
                print_error "无效选择，请输入0-6之间的数字"
                sleep 2
                ;;
        esac
    done
}

# 执行主函数
main
