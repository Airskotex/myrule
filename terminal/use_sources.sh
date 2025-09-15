#!/bin/bash
# 软件源配置脚本
# 作者: Airskotex
# 功能: 配置linux软件源设置，
# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 获取脚本自身的路径
SCRIPT_PATH="$0"

# 检查是否以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误: 此脚本需要 root 权限运行${NC}"
    exit 1
fi

# 检测系统版本
check_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
        # 确保 VERSION_CODENAME 被定义
        if [ -z "$VERSION_CODENAME" ]; then
            VERSION_CODENAME=$(grep -oP '(?<=^UBUNTU_CODENAME=).+' /etc/os-release 2>/dev/null || 
                              grep -oP '(?<=^DEBIAN_CODENAME=).+' /etc/os-release 2>/dev/null || 
                              echo "")
        fi
        echo -e "${BLUE}检测到系统: $OS $VERSION (${VERSION_CODENAME})${NC}"
    else
        echo -e "${RED}无法检测系统版本${NC}"
        exit 1
    fi
}

# 备份原始源文件
backup_sources() {
    local sources_file=$1
    if [ -f "$sources_file" ]; then
        local backup_file="${sources_file}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$sources_file" "$backup_file"
        echo -e "${GREEN}已备份原始源文件到: $backup_file${NC}"
    else
        echo -e "${YELLOW}警告: 源文件 $sources_file 不存在，将创建新文件${NC}"
    fi
}

# 更新 Ubuntu 源
update_ubuntu_sources() {
    local sources_file="/etc/apt/sources.list"
    backup_sources "$sources_file"
    
    echo -e "${BLUE}请选择 Ubuntu 镜像源:${NC}"
    echo -e "${YELLOW}1)${NC} 阿里云"
    echo -e "${YELLOW}2)${NC} 清华大学"
    echo -e "${YELLOW}3)${NC} 中国科技大学"
    echo -e "${YELLOW}4)${NC} 华为云"
    echo -e "${BLUE}请选择 (1-4):${NC}"
    read -r choice
    
    local mirror_url=""
    case $choice in
        1) mirror_url="mirrors.aliyun.com" ;;
        2) mirror_url="mirrors.tuna.tsinghua.edu.cn" ;;
        3) mirror_url="mirrors.ustc.edu.cn" ;;
        4) mirror_url="repo.huaweicloud.com" ;;
        *) 
            echo -e "${RED}无效的选择，使用阿里云源${NC}"
            mirror_url="mirrors.aliyun.com"
            ;;
    esac
    
    # 清空源文件
    > "$sources_file"
    
    # 写入新的源
    cat > "$sources_file" << EOF
deb http://$mirror_url/ubuntu/ $VERSION_CODENAME main restricted universe multiverse
deb http://$mirror_url/ubuntu/ $VERSION_CODENAME-updates main restricted universe multiverse
deb http://$mirror_url/ubuntu/ $VERSION_CODENAME-backports main restricted universe multiverse
deb http://$mirror_url/ubuntu/ $VERSION_CODENAME-security main restricted universe multiverse
EOF
    
    echo -e "${GREEN}Ubuntu 源已更新为: $mirror_url${NC}"
    apt update
}

# 更新 Debian 源
update_debian_sources() {
    local sources_file="/etc/apt/sources.list"
    backup_sources "$sources_file"
    
    echo -e "${BLUE}请选择 Debian 镜像源:${NC}"
    echo -e "${YELLOW}1)${NC} 阿里云"
    echo -e "${YELLOW}2)${NC} 清华大学"
    echo -e "${YELLOW}3)${NC} 中国科技大学"
    echo -e "${YELLOW}4)${NC} 华为云"
    echo -e "${BLUE}请选择 (1-4):${NC}"
    read -r choice
    
    local mirror_url=""
    local security_url=""
    
    case $choice in
        1) 
            mirror_url="mirrors.aliyun.com"
            security_url="mirrors.aliyun.com/debian-security"
            ;;
        2) 
            mirror_url="mirrors.tuna.tsinghua.edu.cn"
            security_url="mirrors.tuna.tsinghua.edu.cn/debian-security"
            ;;
        3) 
            mirror_url="mirrors.ustc.edu.cn"
            security_url="mirrors.ustc.edu.cn/debian-security"
            ;;
        4) 
            mirror_url="repo.huaweicloud.com"
            security_url="repo.huaweicloud.com/debian-security"
            ;;
        *) 
            echo -e "${RED}无效的选择，使用阿里云源${NC}"
            mirror_url="mirrors.aliyun.com"
            security_url="mirrors.aliyun.com/debian-security"
            ;;
    esac
    
    # 清空源文件
    > "$sources_file"
    
    # 写入新的源
    cat > "$sources_file" << EOF
deb http://$mirror_url/debian/ $VERSION_CODENAME main contrib non-free non-free-firmware
deb http://$mirror_url/debian/ $VERSION_CODENAME-updates main contrib non-free non-free-firmware
deb http://$mirror_url/debian/ $VERSION_CODENAME-backports main contrib non-free non-free-firmware
deb http://$security_url $VERSION_CODENAME-security main contrib non-free non-free-firmware
EOF
    
    echo -e "${GREEN}Debian 源已更新为: $mirror_url${NC}"
    apt update
}

# 更新 CentOS 源
update_centos_sources() {
    local backup_dir="/etc/yum.repos.d/backup"
    mkdir -p "$backup_dir"
    
    # 备份原始源文件
    cp /etc/yum.repos.d/*.repo "$backup_dir/"
    echo -e "${GREEN}已备份原始源文件到: $backup_dir${NC}"
    
    echo -e "${BLUE}请选择 CentOS 镜像源:${NC}"
    echo -e "${YELLOW}1)${NC} 阿里云"
    echo -e "${YELLOW}2)${NC} 清华大学"
    echo -e "${YELLOW}3)${NC} 中国科技大学"
    echo -e "${YELLOW}4)${NC} 华为云"
    echo -e "${BLUE}请选择 (1-4):${NC}"
    read -r choice
    
    # 安装必要的工具
    yum install -y yum-utils
    
    # 清除所有源
    rm -f /etc/yum.repos.d/*.repo
    
    # CentOS 8 已结束生命周期警告
    if [ "$VERSION_ID" == "8" ]; then
        echo -e "${YELLOW}警告: CentOS 8 已于 2021 年底结束生命周期，建议使用 CentOS Stream 8、Rocky Linux 8 或 AlmaLinux 8${NC}"
        read -p "是否继续? (y/n): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            # 恢复备份
            cp "$backup_dir"/*.repo /etc/yum.repos.d/
            echo -e "${GREEN}已恢复原始源文件${NC}"
            exit 1
        fi
    fi
    
    # 下载新的源文件
    case $choice in
        1) # 阿里云
            if [ "$VERSION_ID" == "8" ]; then
                curl -o /etc/yum.repos.d/CentOS-Base.repo https://mirrors.aliyun.com/repo/Centos-vault-8.5.2111.repo
            elif [ "$VERSION_ID" == "7" ]; then
                curl -o /etc/yum.repos.d/CentOS-Base.repo https://mirrors.aliyun.com/repo/Centos-7.repo
            else
                echo -e "${RED}不支持的 CentOS 版本: $VERSION_ID${NC}"
                # 恢复备份
                cp "$backup_dir"/*.repo /etc/yum.repos.d/
                exit 1
            fi
            echo -e "${GREEN}CentOS 源已更新为: 阿里云${NC}"
            ;;
        2) # 清华大学
            if [ "$VERSION_ID" == "8" ]; then
                curl -o /etc/yum.repos.d/CentOS-Base.repo https://mirrors.tuna.tsinghua.edu.cn/help/centos/centos-vault-8.repo
            elif [ "$VERSION_ID" == "7" ]; then
                curl -o /etc/yum.repos.d/CentOS-Base.repo https://mirrors.tuna.tsinghua.edu.cn/help/centos/centos7-base.repo
            else
                echo -e "${RED}不支持的 CentOS 版本: $VERSION_ID${NC}"
                # 恢复备份
                cp "$backup_dir"/*.repo /etc/yum.repos.d/
                exit 1
            fi
            echo -e "${GREEN}CentOS 源已更新为: 清华大学${NC}"
            ;;
        3) # 中国科技大学
            if [ "$VERSION_ID" == "8" ]; then
                curl -o /etc/yum.repos.d/CentOS-Base.repo https://mirrors.ustc.edu.cn/centos-vault/8.5.2111/centos-vault-8.repo
            elif [ "$VERSION_ID" == "7" ]; then
                curl -o /etc/yum.repos.d/CentOS-Base.repo https://mirrors.ustc.edu.cn/centos/7/os/x86_64/Packages/centos-release-7-9.2009.0.el7.centos.x86_64.rpm
                rpm -Uvh --force centos-release-7-9.2009.0.el7.centos.x86_64.rpm
                sed -i 's/^#baseurl/baseurl/g' /etc/yum.repos.d/CentOS-*.repo
                sed -i 's/^mirrorlist=/#mirrorlist=/g' /etc/yum.repos.d/CentOS-*.repo
                sed -i 's@http://mirror.centos.org@https://mirrors.ustc.edu.cn@g' /etc/yum.repos.d/CentOS-*.repo
            else
                echo -e "${RED}不支持的 CentOS 版本: $VERSION_ID${NC}"
                # 恢复备份
                cp "$backup_dir"/*.repo /etc/yum.repos.d/
                exit 1
            fi
            echo -e "${GREEN}CentOS 源已更新为: 中国科技大学${NC}"
            ;;
        4) # 华为云
            if [ "$VERSION_ID" == "8" ]; then
                curl -o /etc/yum.repos.d/CentOS-Base.repo https://repo.huaweicloud.com/repository/conf/CentOS-8-reg.repo
            elif [ "$VERSION_ID" == "7" ]; then
                curl -o /etc/yum.repos.d/CentOS-Base.repo https://repo.huaweicloud.com/repository/conf/CentOS-7-reg.repo
            else
                echo -e "${RED}不支持的 CentOS 版本: $VERSION_ID${NC}"
                # 恢复备份
                cp "$backup_dir"/*.repo /etc/yum.repos.d/
                exit 1
            fi
            echo -e "${GREEN}CentOS 源已更新为: 华为云${NC}"
            ;;
        *)
            echo -e "${RED}无效的选择，使用阿里云源${NC}"
            if [ "$VERSION_ID" == "8" ]; then
                curl -o /etc/yum.repos.d/CentOS-Base.repo https://mirrors.aliyun.com/repo/Centos-vault-8.5.2111.repo
            elif [ "$VERSION_ID" == "7" ]; then
                curl -o /etc/yum.repos.d/CentOS-Base.repo https://mirrors.aliyun.com/repo/Centos-7.repo
            else
                echo -e "${RED}不支持的 CentOS 版本: $VERSION_ID${NC}"
                # 恢复备份
                cp "$backup_dir"/*.repo /etc/yum.repos.d/
                exit 1
            fi
            echo -e "${GREEN}CentOS 源已更新为: 阿里云${NC}"
            ;;
    esac
    
    yum clean all
    yum makecache
}

# 更新 Rocky Linux/AlmaLinux 源
update_el_sources() {
    local backup_dir="/etc/yum.repos.d/backup"
    mkdir -p "$backup_dir"
    
    # 备份原始源文件
    cp /etc/yum.repos.d/*.repo "$backup_dir/"
    echo -e "${GREEN}已备份原始源文件到: $backup_dir${NC}"
    
    echo -e "${BLUE}请选择 ${OS^} 镜像源:${NC}"
    echo -e "${YELLOW}1)${NC} 阿里云"
    echo -e "${YELLOW}2)${NC} 清华大学"
    echo -e "${YELLOW}3)${NC} 中国科技大学"
    echo -e "${YELLOW}4)${NC} 华为云"
    echo -e "${BLUE}请选择 (1-4):${NC}"
    read -r choice
    
    # 安装必要的工具
    dnf install -y dnf-utils
    
    # 备份并移除当前的repo文件
    mkdir -p /etc/yum.repos.d/bak
    mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/bak/
    
    case $choice in
        1) # 阿里云
            if [ "$OS" == "rocky" ]; then
                dnf install -y https://mirrors.aliyun.com/rocky/${VERSION_ID}/BaseOS/x86_64/os/Packages/rocky-release-${VERSION_ID}-*.el${VERSION_ID}.noarch.rpm
                dnf install -y https://mirrors.aliyun.com/rocky/${VERSION_ID}/BaseOS/x86_64/os/Packages/rocky-repos-${VERSION_ID}-*.el${VERSION_ID}.noarch.rpm
                sed -i 's|^mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/rocky*.repo
                sed -i 's|^#baseurl=http://dl.rockylinux.org/$contentdir|baseurl=https://mirrors.aliyun.com/rocky|g' /etc/yum.repos.d/rocky*.repo
            elif [ "$OS" == "almalinux" ]; then
                dnf install -y https://mirrors.aliyun.com/almalinux/${VERSION_ID}/BaseOS/x86_64/os/Packages/almalinux-release-${VERSION_ID}-*.el${VERSION_ID}.noarch.rpm
                sed -i 's|^mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/almalinux*.repo
                sed -i 's|^#baseurl=https://repo.almalinux.org|baseurl=https://mirrors.aliyun.com/almalinux|g' /etc/yum.repos.d/almalinux*.repo
            fi
            echo -e "${GREEN}${OS^} 源已更新为: 阿里云${NC}"
            ;;
        2) # 清华大学
            if [ "$OS" == "rocky" ]; then
                dnf install -y https://mirrors.tuna.tsinghua.edu.cn/rocky/${VERSION_ID}/BaseOS/x86_64/os/Packages/rocky-release-${VERSION_ID}-*.el${VERSION_ID}.noarch.rpm
                dnf install -y https://mirrors.tuna.tsinghua.edu.cn/rocky/${VERSION_ID}/BaseOS/x86_64/os/Packages/rocky-repos-${VERSION_ID}-*.el${VERSION_ID}.noarch.rpm
                sed -i 's|^mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/rocky*.repo
                sed -i 's|^#baseurl=http://dl.rockylinux.org/$contentdir|baseurl=https://mirrors.tuna.tsinghua.edu.cn/rocky|g' /etc/yum.repos.d/rocky*.repo
            elif [ "$OS" == "almalinux" ]; then
                dnf install -y https://mirrors.tuna.tsinghua.edu.cn/almalinux/${VERSION_ID}/BaseOS/x86_64/os/Packages/almalinux-release-${VERSION_ID}-*.el${VERSION_ID}.noarch.rpm
                sed -i 's|^mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/almalinux*.repo
                sed -i 's|^#baseurl=https://repo.almalinux.org|baseurl=https://mirrors.tuna.tsinghua.edu.cn/almalinux|g' /etc/yum.repos.d/almalinux*.repo
            fi
            echo -e "${GREEN}${OS^} 源已更新为: 清华大学${NC}"
            ;;
        3) # 中国科技大学
            if [ "$OS" == "rocky" ]; then
                dnf install -y https://mirrors.ustc.edu.cn/rocky/${VERSION_ID}/BaseOS/x86_64/os/Packages/rocky-release-${VERSION_ID}-*.el${VERSION_ID}.noarch.rpm
                dnf install -y https://mirrors.ustc.edu.cn/rocky/${VERSION_ID}/BaseOS/x86_64/os/Packages/rocky-repos-${VERSION_ID}-*.el${VERSION_ID}.noarch.rpm
                sed -i 's|^mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/rocky*.repo
                sed -i 's|^#baseurl=http://dl.rockylinux.org/$contentdir|baseurl=https://mirrors.ustc.edu.cn/rocky|g' /etc/yum.repos.d/rocky*.repo
            elif [ "$OS" == "almalinux" ]; then
                dnf install -y https://mirrors.ustc.edu.cn/almalinux/${VERSION_ID}/BaseOS/x86_64/os/Packages/almalinux-release-${VERSION_ID}-*.el${VERSION_ID}.noarch.rpm
                sed -i 's|^mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/almalinux*.repo
                sed -i 's|^#baseurl=https://repo.almalinux.org|baseurl=https://mirrors.ustc.edu.cn/almalinux|g' /etc/yum.repos.d/almalinux*.repo
            fi
            echo -e "${GREEN}${OS^} 源已更新为: 中国科技大学${NC}"
            ;;
        4) # 华为云
            if [ "$OS" == "rocky" ]; then
                dnf install -y https://repo.huaweicloud.com/rocky/${VERSION_ID}/BaseOS/x86_64/os/Packages/rocky-release-${VERSION_ID}-*.el${VERSION_ID}.noarch.rpm
                dnf install -y https://repo.huaweicloud.com/rocky/${VERSION_ID}/BaseOS/x86_64/os/Packages/rocky-repos-${VERSION_ID}-*.el${VERSION_ID}.noarch.rpm
                sed -i 's|^mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/rocky*.repo
                sed -i 's|^#baseurl=http://dl.rockylinux.org/$contentdir|baseurl=https://repo.huaweicloud.com/rocky|g' /etc/yum.repos.d/rocky*.repo
            elif [ "$OS" == "almalinux" ]; then
                dnf install -y https://repo.huaweicloud.com/almalinux/${VERSION_ID}/BaseOS/x86_64/os/Packages/almalinux-release-${VERSION_ID}-*.el${VERSION_ID}.noarch.rpm
                sed -i 's|^mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/almalinux*.repo
                sed -i 's|^#baseurl=https://repo.almalinux.org|baseurl=https://repo.huaweicloud.com/almalinux|g' /etc/yum.repos.d/almalinux*.repo
            fi
            echo -e "${GREEN}${OS^} 源已更新为: 华为云${NC}"
            ;;
        *)
            echo -e "${RED}无效的选择，使用阿里云源${NC}"
            if [ "$OS" == "rocky" ]; then
                dnf install -y https://mirrors.aliyun.com/rocky/${VERSION_ID}/BaseOS/x86_64/os/Packages/rocky-release-${VERSION_ID}-*.el${VERSION_ID}.noarch.rpm
                dnf install -y https://mirrors.aliyun.com/rocky/${VERSION_ID}/BaseOS/x86_64/os/Packages/rocky-repos-${VERSION_ID}-*.el${VERSION_ID}.noarch.rpm
                sed -i 's|^mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/rocky*.repo
                sed -i 's|^#baseurl=http://dl.rockylinux.org/$contentdir|baseurl=https://mirrors.aliyun.com/rocky|g' /etc/yum.repos.d/rocky*.repo
            elif [ "$OS" == "almalinux" ]; then
                dnf install -y https://mirrors.aliyun.com/almalinux/${VERSION_ID}/BaseOS/x86_64/os/Packages/almalinux-release-${VERSION_ID}-*.el${VERSION_ID}.noarch.rpm
                sed -i 's|^mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/almalinux*.repo
                sed -i 's|^#baseurl=https://repo.almalinux.org|baseurl=https://mirrors.aliyun.com/almalinux|g' /etc/yum.repos.d/almalinux*.repo
            fi
            echo -e "${GREEN}${OS^} 源已更新为: 阿里云${NC}"
            ;;
    esac
    
    dnf clean all
    dnf makecache
}

# 删除脚本自身
delete_self() {
    echo -e "${YELLOW}正在删除脚本文件...${NC}"
    # 使用 rm 命令删除脚本自身
    rm -f "$SCRIPT_PATH"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}脚本文件已成功删除${NC}"
    else
        echo -e "${RED}脚本文件删除失败${NC}"
    fi
}

# 主函数
main() {
    check_system
    
    case $OS in
        ubuntu)
            update_ubuntu_sources
            ;;
        debian)
            update_debian_sources
            ;;
        centos|rhel)
            update_centos_sources
            ;;
        rocky|almalinux)
            update_el_sources
            ;;
        *)
            echo -e "${RED}不支持的系统: $OS${NC}"
            exit 1
            ;;
    esac
    
    echo -e "${GREEN}源已成功更新，3秒后退出脚本...${NC}"
    for i in {3..1}; do
        echo -ne "${YELLOW}$i...${NC}"
        sleep 1
    done
    echo -e "\n${GREEN}再见!${NC}"
    
    # 退出前删除脚本自身
    delete_self
}

main
