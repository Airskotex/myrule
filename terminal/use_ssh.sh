#!/bin/bash

# SSH配置管理脚本
# 作者: Claude Sonnet 4
# 功能: 配置SSH设置，支持备份和还原，支持自删除

CONFIG_DIR="/etc/ssh/sshd_config.d"
CONFIG_FILE="01-cloudimg-settings.conf"
BACKUP_SUFFIX=".back"
RESTORE_INFO_FILE="/tmp/ssh_config_restore_info"

# 获取脚本自身的完整路径
SCRIPT_PATH="$(realpath "$0")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"

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
    if [[ "$SCRIPT_NAME" == "use_ssh.sh" ]]; then
        print_info "正在清理脚本文件..."
        
        # 方法1: 使用后台进程延迟删除
        (sleep 1 && rm -f "$SCRIPT_PATH" 2>/dev/null) &
        
        # 方法2: 如果是从当前目录执行，也尝试删除当前目录下的文件
        if [[ -f "./use_ssh.sh" && "$PWD/use_ssh.sh" != "$SCRIPT_PATH" ]]; then
            (sleep 1 && rm -f "./use_ssh.sh" 2>/dev/null) &
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

# 显示主菜单
show_main_menu() {
    clear
    echo "========================================"
    print_menu "       SSH 配置管理脚本"
    echo "========================================"
    echo
    print_menu "请选择操作："
    echo "1) 创建新的SSH配置"
    echo "2) 还原原始SSH配置"
    echo "3) 查看当前SSH配置汇总"
    echo "4) 显示帮助信息"
    echo "0) 退出并关闭终端"
    echo
    
    # 显示自删除状态
    if [[ "$SCRIPT_NAME" == "use_ssh.sh" ]]; then
        print_warning "注意: 退出时将自动删除脚本文件 ($SCRIPT_NAME)"
    fi
    echo
}

# 解析配置文件并提取关键配置
parse_ssh_config() {
    local config_file="$1"
    local configs=()
    
    if [[ -f "$config_file" ]]; then
        # 读取配置文件，过滤注释和空行
        while IFS= read -r line; do
            # 去除行首尾空格
            line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            # 跳过空行和注释行
            if [[ -n "$line" && ! "$line" =~ ^# ]]; then
                configs+=("$line")
            fi
        done < "$config_file"
    fi
    
    printf '%s\n' "${configs[@]}"
}

# 汇总所有SSH配置
summarize_ssh_config() {
    declare -A config_summary
    local config_files=()
    local active_configs=()
    
    # 收集所有.conf文件
    if [[ -d "$CONFIG_DIR" ]]; then
        for file in "$CONFIG_DIR"/*.conf; do
            if [[ -f "$file" && ! "$file" =~ \.back$ ]]; then
                config_files+=("$file")
            fi
        done
    fi
    
    # 解析每个配置文件
    for config_file in "${config_files[@]}"; do
        print_info "解析配置文件: $(basename "$config_file")"
        
        # 获取配置内容
        local configs
        mapfile -t configs < <(parse_ssh_config "$config_file")
        
        if [[ ${#configs[@]} -gt 0 ]]; then
            echo "  配置内容:"
            for config in "${configs[@]}"; do
                echo "    $config"
                
                # 提取配置项名称和值
                if [[ "$config" =~ ^([^[:space:]]+)[[:space:]]+(.+)$ ]]; then
                    local param="${BASH_REMATCH[1]}"
                    local value="${BASH_REMATCH[2]}"
                    
                    # 存储到汇总中（后面的配置会覆盖前面的）
                    config_summary["$param"]="$value"
                    active_configs+=("$param $value")
                fi
            done
        else
            print_warning "  文件为空或只包含注释"
        fi
        echo
    done
    
    # 显示汇总配置
    if [[ ${#config_summary[@]} -gt 0 ]]; then
        echo "========================================"
        print_config "当前生效的SSH配置汇总"
        echo "========================================"
        
        # 按重要性排序显示主要配置项
        local important_params=("Port" "PermitRootLogin" "PubkeyAuthentication" "PasswordAuthentication" "AuthorizedKeysFile")
        
        for param in "${important_params[@]}"; do
            if [[ -n "${config_summary[$param]}" ]]; then
                printf "%-20s: %s\n" "$param" "${config_summary[$param]}"
            fi
        done
        
        # 显示其他配置项
        local has_others=false
        for param in "${!config_summary[@]}"; do
            local is_important=false
            for imp_param in "${important_params[@]}"; do
                if [[ "$param" == "$imp_param" ]]; then
                    is_important=true
                    break
                fi
            done
            
            if [[ "$is_important" == false ]]; then
                if [[ "$has_others" == false ]]; then
                    echo
                    print_info "其他配置项:"
                    has_others=true
                fi
                printf "%-20s: %s\n" "$param" "${config_summary[$param]}"
            fi
        done
        
        echo
        print_info "配置安全评估:"
        evaluate_ssh_security config_summary
        
    else
        print_warning "没有发现有效的SSH配置"
    fi
}

# SSH安全评估
evaluate_ssh_security() {
    local -n config_ref=$1
    local security_score=0
    local max_score=5
    local recommendations=()
    
    # 检查端口配置
    if [[ -n "${config_ref[Port]}" ]]; then
        if [[ "${config_ref[Port]}" != "22" ]]; then
            print_success "✓ 使用非标准端口 (${config_ref[Port]})，减少自动化攻击风险"
            ((security_score++))
        else
            print_warning "⚠ 使用默认端口22，建议更改为非标准端口"
            recommendations+=("建议修改SSH端口到非标准端口(如2222-65535)")
        fi
    fi
    
    # 检查root登录设置
    if [[ -n "${config_ref[PermitRootLogin]}" ]]; then
        case "${config_ref[PermitRootLogin]}" in
            "prohibit-password")
                print_success "✓ Root用户仅允许密钥登录，安全性良好"
                ((security_score++))
                ;;
            "no")
                print_success "✓ 完全禁止Root登录，安全性最高"
                ((security_score++))
                ;;
            "yes")
                print_error "✗ 允许Root密码登录，安全风险很高"
                recommendations+=("强烈建议将PermitRootLogin改为prohibit-password或no")
                ;;
        esac
    fi
    
    # 检查密码认证
    if [[ -n "${config_ref[PasswordAuthentication]}" ]]; then
        if [[ "${config_ref[PasswordAuthentication]}" == "no" ]]; then
            print_success "✓ 已禁用密码认证，强制使用密钥认证"
            ((security_score++))
        else
            print_warning "⚠ 启用了密码认证，存在暴力破解风险"
            recommendations+=("建议禁用密码认证(PasswordAuthentication no)")
        fi
    fi
    
    # 检查公钥认证
    if [[ -n "${config_ref[PubkeyAuthentication]}" ]]; then
        if [[ "${config_ref[PubkeyAuthentication]}" == "yes" ]]; then
            print_success "✓ 已启用公钥认证"
            ((security_score++))
        else
            print_error "✗ 未启用公钥认证"
            recommendations+=("建议启用公钥认证(PubkeyAuthentication yes)")
        fi
    fi
    
    # 检查AuthorizedKeysFile配置
    if [[ -n "${config_ref[AuthorizedKeysFile]}" ]]; then
        print_success "✓ 已配置授权密钥文件路径"
        ((security_score++))
    fi
    
    # 显示安全评分
    echo
    local security_percentage=$((security_score * 100 / max_score))
    print_config "安全评分: $security_score/$max_score ($security_percentage%)"
    
    if [[ $security_percentage -ge 80 ]]; then
        print_success "配置安全性: 优秀"
    elif [[ $security_percentage -ge 60 ]]; then
        print_warning "配置安全性: 良好"
    else
        print_error "配置安全性: 需要改进"
    fi
    
    # 显示建议
    if [[ ${#recommendations[@]} -gt 0 ]]; then
        echo
        print_warning "安全建议:"
        for rec in "${recommendations[@]}"; do
            echo "  • $rec"
        done
    fi
}

# 检查配置状态（增强版）
check_config_status() {
    clear
    echo "========================================"
    print_info "SSH配置详细分析"
    echo "========================================"
    
    # 检查配置目录
    if [[ ! -d "$CONFIG_DIR" ]]; then
        print_error "SSH配置目录不存在: $CONFIG_DIR"
        echo
        read -p "按回车键返回主菜单..."
        return 1
    fi
    
    # 显示配置文件列表
    print_info "扫描SSH配置目录: $CONFIG_DIR"
    local conf_count=0
    local backup_count=0
    
    for file in "$CONFIG_DIR"/*; do
        if [[ -f "$file" ]]; then
            if [[ "$file" =~ \.conf$ && ! "$file" =~ \.back$ ]]; then
                print_success "发现配置文件: $(basename "$file")"
                ((conf_count++))
            elif [[ "$file" =~ \.back$ ]]; then
                print_warning "发现备份文件: $(basename "$file")"
                ((backup_count++))
            fi
        fi
    done
    
    if [[ $conf_count -eq 0 ]]; then
        print_warning "没有发现活动的.conf配置文件"
    else
        print_success "共发现 $conf_count 个活动配置文件"
    fi
    
    if [[ $backup_count -gt 0 ]]; then
        print_info "共发现 $backup_count 个备份文件"
    fi
    
    echo
    
    # 汇总并分析配置
    summarize_ssh_config
    
    # 显示还原状态
    echo
    if [[ -f "$RESTORE_INFO_FILE" ]]; then
        print_info "还原信息文件存在，可以进行还原操作"
    else
        print_warning "没有还原信息文件"
    fi
    
    # 显示SSH服务状态
    echo
    print_info "SSH服务状态:"
    if systemctl is-active --quiet sshd; then
        print_success "SSH服务正在运行"
        local ssh_port=$(ss -tlnp | grep :22 | head -1)
        if [[ -n "$ssh_port" ]]; then
            print_info "监听端口: $ssh_port"
        fi
    else
        print_error "SSH服务未运行"
    fi
    
    echo
    read -p "按回车键返回主菜单..."
}

# 备份并移动现有文件
backup_and_move_files() {
    local backup_count=0
    
    if [[ -d "$CONFIG_DIR" ]]; then
        print_info "检查 $CONFIG_DIR 目录中的现有文件..."
        
        # 记录备份信息
        echo "# SSH配置备份信息 - $(date)" > "$RESTORE_INFO_FILE"
        echo "CONFIG_DIR=$CONFIG_DIR" >> "$RESTORE_INFO_FILE"
        echo "BACKUP_FILES=(" >> "$RESTORE_INFO_FILE"
        
        for file in "$CONFIG_DIR"/*.conf; do
            if [[ -f "$file" && ! "$file" =~ \.back$ ]]; then
                backup_file="${file}${BACKUP_SUFFIX}"
                print_warning "移动文件到备份: $(basename "$file") -> $(basename "$backup_file")"
                mv "$file" "$backup_file"
                echo "    \"$(basename "$file")\"" >> "$RESTORE_INFO_FILE"
                ((backup_count++))
            fi
        done
        
        echo ")" >> "$RESTORE_INFO_FILE"
        
        if [[ $backup_count -gt 0 ]]; then
            print_success "已备份并移动 $backup_count 个文件"
        else
            print_info "没有需要备份的文件"
        fi
    else
        print_warning "目录 $CONFIG_DIR 不存在，将创建它"
        mkdir -p "$CONFIG_DIR"
        echo "# SSH配置备份信息 - $(date)" > "$RESTORE_INFO_FILE"
        echo "CONFIG_DIR=$CONFIG_DIR" >> "$RESTORE_INFO_FILE"
        echo "BACKUP_FILES=()" >> "$RESTORE_INFO_FILE"
    fi
}

# 获取用户输入的端口号
get_port_input() {
    while true; do
        echo
        print_info "请输入SSH端口号 (默认: 22, 范围: 1-65535):"
        read -p "端口号: " port
        
        # 如果用户直接回车，使用默认值
        if [[ -z "$port" ]]; then
            port=22
            break
        fi
        
        # 验证端口号
        if [[ "$port" =~ ^[0-9]+$ ]] && [[ $port -ge 1 && $port -le 65535 ]]; then
            break
        else
            print_error "无效的端口号，请输入1-65535之间的数字"
        fi
    done
    
    print_success "选择的端口号: $port"
}

# 获取PermitRootLogin选项
get_permit_root_login() {
    echo
    print_info "请选择 PermitRootLogin 设置:"
    echo "1) prohibit-password (默认) - 禁止密码登录，仅允许密钥登录"
    echo "2) yes - 允许root用户登录（包括密码登录）"
    echo "3) no - 完全禁止root用户登录"
    echo "4) forced-commands-only - 仅允许强制命令"
    
    echo
    print_warning "安全建议："
    echo "• prohibit-password：最常用的安全选择，推荐用于生产环境"
    echo "• yes：安全性较低，容易受到暴力破解攻击"
    echo "• no：最安全但可能影响管理便利性"
    echo "• forced-commands-only：适合特定自动化场景"
    
    while true; do
        echo
        read -p "请选择 (1-4, 默认为1): " choice
        
        case "$choice" in
            ""|"1")
                permit_root_login="prohibit-password"
                print_info "选择: 禁止密码登录，仅允许密钥登录（推荐）"
                break
                ;;
            "2")
                permit_root_login="yes"
                print_warning "选择: 允许root用户登录（安全风险较高）"
                echo "注意: 建议配合强密码策略和防火墙使用"
                break
                ;;
            "3")
                permit_root_login="no"
                print_info "选择: 完全禁止root用户登录"
                break
                ;;
            "4")
                permit_root_login="forced-commands-only"
                print_info "选择: 仅允许强制命令"
                break
                ;;
            *)
                print_error "无效选择，请输入1-4之间的数字"
                ;;
        esac
    done
}

# 创建SSH配置文件
create_ssh_config() {
    local config_path="$CONFIG_DIR/$CONFIG_FILE"
    
    print_info "创建SSH配置文件: $config_path"
    
    cat > "$config_path" << EOF
# SSH配置文件 - 由脚本自动生成
# 生成时间: $(date)
# 配置说明: 
#   PermitRootLogin: 控制root用户登录方式
#   Port: SSH服务端口
#   PubkeyAuthentication: 启用公钥认证
#   AuthorizedKeysFile: 指定公钥文件位置
#   PasswordAuthentication: 禁用密码认证（提高安全性）

PermitRootLogin $permit_root_login
Port $port
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
EOF
    
    print_success "配置文件创建完成"
    echo
    print_info "新配置内容:"
    echo "----------------------------------------"
    cat "$config_path"
    echo "----------------------------------------"
}

# 创建配置流程
create_config_flow() {
    echo "========================================"
    print_info "创建新的SSH配置"
    echo "========================================"
    
    # 检查现有配置
    if [[ -f "$CONFIG_DIR/$CONFIG_FILE" ]]; then
        print_warning "检测到现有配置文件: $CONFIG_DIR/$CONFIG_FILE"
        echo
        read -p "是否继续？这将备份现有配置 (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_info "操作已取消"
            return 0
        fi
    fi
    
    # 备份现有文件
    backup_and_move_files
    
    # 获取用户输入
    get_port_input
    get_permit_root_login
    
    # 创建配置文件
    create_ssh_config
    
    # 询问是否重启服务
    restart_ssh_service
    
    echo
    print_success "配置创建完成！"
    print_info "备份信息已保存，可以使用还原功能恢复原始配置"
    echo
    read -p "按回车键返回主菜单..."
}

# 还原配置
restore_config_flow() {
    echo "========================================"
    print_info "还原原始SSH配置"
    echo "========================================"
    
    if [[ ! -f "$RESTORE_INFO_FILE" ]]; then
        print_error "没有找到备份信息文件，无法还原"
        echo "可能原因："
        echo "• 没有执行过配置创建操作"
        echo "• 备份信息文件被删除"
        echo
        read -p "按回车键返回主菜单..."
        return 1
    fi
    
    source "$RESTORE_INFO_FILE"
    
    print_info "发现备份信息，准备还原SSH配置..."
    echo
    print_warning "还原操作将："
    echo "• 删除当前的 $CONFIG_FILE"
    echo "• 恢复所有备份的配置文件"
    echo
    
    read -p "确定要继续吗？(y/N): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "还原操作已取消"
        echo
        read -p "按回车键返回主菜单..."
        return 0
    fi
    
    # 删除当前配置文件
    if [[ -f "$CONFIG_DIR/$CONFIG_FILE" ]]; then
        rm "$CONFIG_DIR/$CONFIG_FILE"
        print_success "已删除当前配置文件"
    fi
    
    # 还原备份文件
    local restore_count=0
    if [[ ${#BACKUP_FILES[@]} -gt 0 ]]; then
        for file in "${BACKUP_FILES[@]}"; do
            backup_file="$CONFIG_DIR/${file}${BACKUP_SUFFIX}"
            original_file="$CONFIG_DIR/$file"
            
            if [[ -f "$backup_file" ]]; then
                mv "$backup_file" "$original_file"
                print_success "已还原: $file"
                ((restore_count++))
            fi
        done
    fi
    
    if [[ $restore_count -gt 0 ]]; then
        print_success "已还原 $restore_count 个文件"
    else
        print_warning "没有找到需要还原的备份文件"
    fi
    
    # 清理还原信息文件
    rm -f "$RESTORE_INFO_FILE"
    print_success "清理备份信息文件"
    
    # 询问是否重启服务
    restart_ssh_service
    
    echo
    print_success "还原操作完成！"
    read -p "按回车键返回主菜单..."
}

# 重启SSH服务
restart_ssh_service() {
    echo
    read -p "是否现在重启SSH服务以应用更改？(y/N): " restart
    
    if [[ "$restart" =~ ^[Yy]$ ]]; then
        print_info "重启SSH服务..."
        if systemctl restart sshd; then
            print_success "SSH服务重启成功"
            print_info "SSH服务状态："
            systemctl status sshd --no-pager -l
        else
            print_error "SSH服务重启失败，请手动检查配置"
            print_info "可以使用以下命令检查配置语法："
            echo "  sshd -t"
        fi
    else
        print_warning "请记得手动重启SSH服务: systemctl restart sshd"
        print_info "重启前可以检查配置语法: sshd -t"
    fi
}

# 显示帮助信息
show_help() {
    clear
    echo "========================================"
    print_menu "SSH配置管理脚本 - 帮助信息"
    echo "========================================"
    echo
    print_info "脚本功能："
    echo "• 交互式创建SSH配置文件"
    echo "• 自动备份现有配置（移动到.back文件）"
    echo "• 支持完全还原到原始配置"
    echo "• 智能分析所有SSH配置文件"
    echo "• 提供安全评估和建议"
    echo "• 支持自定义SSH端口和登录方式"
    echo "• 自动清理脚本文件（适合一次性使用）"
    echo
    print_info "配置分析功能："
    echo "• 扫描 /etc/ssh/sshd_config.d/ 目录下所有.conf文件"
    echo "• 汇总生效的配置参数"
    echo "• 提供安全评分和改进建议"
    echo "• 显示SSH服务运行状态"
    echo
    print_info "PermitRootLogin 选项详解："
    echo "• prohibit-password: 最安全的常用选择，禁止密码登录"
    echo "• yes: 允许所有登录方式，安全性较低"
    echo "• no: 完全禁止root登录，安全性最高"
    echo "• forced-commands-only: 只允许预定义命令"
    echo
    print_info "安全建议："
    echo "• 建议使用非标准端口（避免自动化攻击）"
    echo "• 推荐使用 prohibit-password 选项"
    echo "• 确保已配置SSH密钥对"
    echo "• 定期检查SSH登录日志"
    echo
    print_warning "注意事项："
    echo "• 修改配置前会自动备份原文件"
    echo "• 备份文件会替代原文件（原文件被移动）"
    echo "• 可以随时还原到备份状态"
    echo "• 建议在修改前测试SSH密钥登录"
    echo "• 脚本退出时会自动删除自身（use_ssh.sh）"
    echo
    read -p "按回车键返回主菜单..."
}

# 退出并关闭终端（支持自删除）
exit_and_close() {
    print_info "感谢使用SSH配置管理脚本！"
    echo
    
    # 显示自删除提示
    if [[ "$SCRIPT_NAME" == "use_ssh.sh" ]]; then
        print_warning "将清理脚本文件: $SCRIPT_NAME"
    fi
    
    print_warning "3秒后将关闭终端..."
    
    for i in {3..1}; do
        echo -ne "\r关闭倒计时: ${i}秒 "
        sleep 1
    done
    
    echo -e "\n再见！"
    
    # 执行清理（trap会自动调用cleanup_script）
    
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
        read -p "请选择操作 (0-4): " choice
        
        case "$choice" in
            1)
                create_config_flow
                ;;
            2)
                restore_config_flow
                ;;
            3)
                check_config_status
                ;;
            4)
                show_help
                ;;
            0)
                exit_and_close
                ;;
            *)
                print_error "无效选择，请输入0-4之间的数字"
                sleep 2
                ;;
        esac
    done
}

# 执行主函数
main
