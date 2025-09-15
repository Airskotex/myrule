#!/bin/bash

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 检查是否为root用户
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用root权限运行此脚本${NC}"
    exit 1
fi

# 检测操作系统
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION=$VERSION_ID
else
    echo -e "${RED}无法检测操作系统${NC}"
    exit 1
fi

# 检测当前软件源
check_current_source() {
    echo -e "${BLUE}当前使用的软件源：${NC}"
    case $OS in
        ubuntu|debian)
            if [ -f /etc/apt/sources.list ]; then
                echo -e "${YELLOW}主要软件源：${NC}"
                grep -v '^#' /etc/apt/sources.list | grep -v '^$' | head -n 1
                
                if grep -q "aliyun" /etc/apt/sources.list; then
                    echo -e "${GREEN}当前使用的是阿里源${NC}"
                elif grep -q "tuna.tsinghua" /etc/apt/sources.list; then
                    echo -e "${GREEN}当前使用的是清华源${NC}"
                elif grep -q "mirrors.ustc" /etc/apt/sources.list; then
                    echo -e "${GREEN}当前使用的是中科大源${NC}"
                elif grep -q "archive.ubuntu.com" /etc/apt/sources.list; then
                    echo -e "${GREEN}当前使用的是Ubuntu官方源${NC}"
                elif grep -q "deb.debian.org" /etc/apt/sources.list; then
                    echo -e "${GREEN}当前使用的是Debian官方源${NC}"
                else
                    echo -e "${YELLOW}使用的是其他源${NC}"
                fi
            fi
            ;;
        centos)
            if [ -f /etc/yum.repos.d/CentOS-Base.repo ]; then
                echo -e "${YELLOW}主要软件源：${NC}"
                grep "baseurl" /etc/yum.repos.d/CentOS-Base.repo | head -n 1
                
                if grep -q "aliyun" /etc/yum.repos.d/CentOS-Base.repo; then
                    echo -e "${GREEN}当前使用的是阿里源${NC}"
                elif grep -q "tuna.tsinghua" /etc/yum.repos.d/CentOS-Base.repo; then
                    echo -e "${GREEN}当前使用的是清华源${NC}"
                elif grep -q "mirrors.ustc" /etc/yum.repos.d/CentOS-Base.repo; then
                    echo -e "${GREEN}当前使用的是中科大源${NC}"
                elif grep -q "mirror.centos.org" /etc/yum.repos.d/CentOS-Base.repo; then
                    echo -e "${GREEN}当前使用的是CentOS官方源${NC}"
                else
                    echo -e "${YELLOW}使用的是其他源${NC}"
                fi
            fi
            ;;
    esac
}

# [原有的backup_sources函数保持不变]
backup_sources() {
    local sources_file=$1
    if [ -f "$sources_file" ]; then
        cp "$sources_file" "${sources_file}.backup.$(date +%Y%m%d)"
        echo -e "${GREEN}已备份原始源文件到 ${sources_file}.backup.$(date +%Y%m%d)${NC}"
    fi
}

# Ubuntu源选择菜单
ubuntu_menu() {
    check_current_source
    echo -e "\n${YELLOW}请选择要使用的Ubuntu源：${NC}"
    echo "1) 阿里源"
    echo "2) 清华源"
    echo "3) 中科大源"
    echo "4) 官方源"
    echo "5) 退出"
    
    read -p "请输入选择 [1-5]: " choice
    
    local sources_file="/etc/apt/sources.list"
    backup_sources "$sources_file"
    
    case $choice in
        1)
            echo "deb http://mirrors.aliyun.com/ubuntu/ $UBUNTU_CODENAME main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ $UBUNTU_CODENAME-security main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ $UBUNTU_CODENAME-updates main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ $UBUNTU_CODENAME-proposed main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ $UBUNTU_CODENAME-backports main restricted universe multiverse" > "$sources_file"
            ;;
        2)
            echo "deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $UBUNTU_CODENAME main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $UBUNTU_CODENAME-security main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $UBUNTU_CODENAME-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $UBUNTU_CODENAME-proposed main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $UBUNTU_CODENAME-backports main restricted universe multiverse" > "$sources_file"
            ;;
        3)
            echo "deb https://mirrors.ustc.edu.cn/ubuntu/ $UBUNTU_CODENAME main restricted universe multiverse
deb https://mirrors.ustc.edu.cn/ubuntu/ $UBUNTU_CODENAME-security main restricted universe multiverse
deb https://mirrors.ustc.edu.cn/ubuntu/ $UBUNTU_CODENAME-updates main restricted universe multiverse
deb https://mirrors.ustc.edu.cn/ubuntu/ $UBUNTU_CODENAME-proposed main restricted universe multiverse
deb https://mirrors.ustc.edu.cn/ubuntu/ $UBUNTU_CODENAME-backports main restricted universe multiverse" > "$sources_file"
            ;;
        4)
            echo "deb http://archive.ubuntu.com/ubuntu/ $UBUNTU_CODENAME main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ $UBUNTU_CODENAME-security main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ $UBUNTU_CODENAME-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ $UBUNTU_CODENAME-proposed main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ $UBUNTU_CODENAME-backports main restricted universe multiverse" > "$sources_file"
            ;;
        5)
            exit 0
            ;;
        *)
            echo -e "${RED}无效的选择${NC}"
            exit 1
            ;;
    esac
    
    apt update
    echo -e "${GREEN}源已更新完成${NC}"
    check_current_source
}

# CentOS源选择菜单
centos_menu() {
    check_current_source
    echo -e "\n${YELLOW}请选择要使用的CentOS源：${NC}"
    echo "1) 阿里源"
    echo "2) 清华源"
    echo "3) 中科大源"
    echo "4) 官方源"
    echo "5) 退出"
    
    read -p "请输入选择 [1-5]: " choice
    
    local sources_file="/etc/yum.repos.d/CentOS-Base.repo"
    backup_sources "$sources_file"
    
    case $choice in
        1)
            curl -o "$sources_file" https://mirrors.aliyun.com/repo/Centos-"$VERSION_ID".repo
            ;;
        2)
            curl -o "$sources_file" https://mirrors.tuna.tsinghua.edu.cn/repo/centos"$VERSION_ID".repo
            ;;
        3)
            curl -o "$sources_file" https://mirrors.ustc.edu.cn/centos/"$VERSION_ID"/os/x86_64/
            ;;
        4)
            curl -o "$sources_file" http://mirror.centos.org/centos/"$VERSION_ID"/os/x86_64/
            ;;
        5)
            exit 0
            ;;
        *)
            echo -e "${RED}无效的选择${NC}"
            exit 1
            ;;
    esac
    
    yum clean all
    yum makecache
    echo -e "${GREEN}源已更新完成${NC}"
    check_current_source
}

# Debian源选择菜单
debian_menu() {
    check_current_source
    echo -e "\n${YELLOW}请选择要使用的Debian源：${NC}"
    echo "1) 阿里源"
    echo "2) 清华源"
    echo "3) 中科大源"
    echo "4) 官方源"
    echo "5) 退出"
    
    read -p "请输入选择 [1-5]: " choice
    
    local sources_file="/etc/apt/sources.list"
    backup_sources "$sources_file"
    
    case $choice in
        1)
            echo "deb http://mirrors.aliyun.com/debian/ $VERSION_CODENAME main contrib non-free
deb http://mirrors.aliyun.com/debian/ $VERSION_CODENAME-updates main contrib non-free
deb http://mirrors.aliyun.com/debian/ $VERSION_CODENAME-backports main contrib non-free
deb http://mirrors.aliyun.com/debian-security $VERSION_CODENAME-security main contrib non-free" > "$sources_file"
            ;;
        2)
            echo "deb https://mirrors.tuna.tsinghua.edu.cn/debian/ $VERSION_CODENAME main contrib non-free
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ $VERSION_CODENAME-updates main contrib non-free
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ $VERSION_CODENAME-backports main contrib non-free
deb https://mirrors.tuna.tsinghua.edu.cn/debian-security $VERSION_CODENAME-security main contrib non-free" > "$sources_file"
            ;;
        3)
            echo "deb https://mirrors.ustc.edu.cn/debian/ $VERSION_CODENAME main contrib non-free
deb https://mirrors.ustc.edu.cn/debian/ $VERSION_CODENAME-updates main contrib non-free
deb https://mirrors.ustc.edu.cn/debian/ $VERSION_CODENAME-backports main contrib non-free
deb https://mirrors.ustc.edu.cn/debian-security $VERSION_CODENAME-security main contrib non-free" > "$sources_file"
            ;;
        4)
            echo "deb http://deb.debian.org/debian $VERSION_CODENAME main contrib non-free
deb http://deb.debian.org/debian $VERSION_CODENAME-updates main contrib non-free
deb http://deb.debian.org/debian $VERSION_CODENAME-backports main contrib non-free
deb http://security.debian.org/debian-security $VERSION_CODENAME-security main contrib non-free" > "$sources_file"
            ;;
        5)
            exit 0
            ;;
        *)
            echo -e "${RED}无效的选择${NC}"
            exit 1
            ;;
    esac
    
    apt update
    echo -e "${GREEN}源已更新完成${NC}"
    check_current_source
}

# 主程序
echo -e "${GREEN}检测到的操作系统为: $OS $VERSION${NC}"

case $OS in
    ubuntu)
        ubuntu_menu
        ;;
    centos)
        centos_menu
        ;;
    debian)
        debian_menu
        ;;
    *)
        echo -e "${RED}暂不支持该操作系统${NC}"
        exit 1
        ;;
esac
