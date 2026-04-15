#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ZSHRC="/root/.zshrc"
BACKUP_ROOT="/root/.config/hermes-shell-backups"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/setup-chinese-zsh-$TIMESTAMP"

log() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }
err() { echo -e "${RED}$*${NC}"; }

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    err "错误：请用 root 运行此脚本"
    exit 1
  fi
}

ensure_backup() {
  mkdir -p "$BACKUP_DIR/files"
  [ -f /etc/locale.gen ] && cp -a /etc/locale.gen "$BACKUP_DIR/files/locale.gen"
  [ -f /etc/default/locale ] && cp -a /etc/default/locale "$BACKUP_DIR/files/default-locale"
  [ -f /etc/ssh/sshd_config ] && cp -a /etc/ssh/sshd_config "$BACKUP_DIR/files/sshd_config"
  [ -f "$ZSHRC" ] && cp -a "$ZSHRC" "$BACKUP_DIR/files/.zshrc"

  cat > "$BACKUP_DIR/restore.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
BACKUP_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$BACKUP_DIR/files/locale.gen" ]; then cp -a "$BACKUP_DIR/files/locale.gen" /etc/locale.gen; fi
if [ -f "$BACKUP_DIR/files/default-locale" ]; then cp -a "$BACKUP_DIR/files/default-locale" /etc/default/locale; fi
if [ -f "$BACKUP_DIR/files/sshd_config" ]; then cp -a "$BACKUP_DIR/files/sshd_config" /etc/ssh/sshd_config; fi
if [ -f "$BACKUP_DIR/files/.zshrc" ]; then
  cp -a "$BACKUP_DIR/files/.zshrc" /root/.zshrc
else
  rm -f /root/.zshrc
fi
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
printf '已恢复备份：%s\n' "$BACKUP_DIR"
EOF
  chmod +x "$BACKUP_DIR/restore.sh"
  printf 'created_at=%s\n' "$(date -Is)" > "$BACKUP_DIR/metadata.txt"
  printf 'target_shell=zsh\n' >> "$BACKUP_DIR/metadata.txt"
}

detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS="${ID:-debian}"
  else
    OS="debian"
  fi
  log "检测到系统: $OS"
}

install_packages() {
  log "[1/6] 更新软件源..."
  apt update -y

  log "[2/6] 安装中文字体、man 手册、locale、zsh..."
  apt install -y fonts-noto-cjk fonts-wqy-microhei fonts-wqy-zenhei manpages-zh locales zsh

  log "[3/6] 修复精简系统缺失的翻译文件..."
  if [ "$OS" = "ubuntu" ]; then
    apt install -y language-pack-zh-hans
    apt install --reinstall -y locales zsh
  else
    apt install --reinstall -y locales bash coreutils grep sed zsh
  fi
}

configure_locale() {
  log "[4/6] 生成中文 Locale..."
  [ -f /etc/locale.gen ] || touch /etc/locale.gen
  grep -Eq '^zh_CN\.UTF-8 UTF-8' /etc/locale.gen || echo 'zh_CN.UTF-8 UTF-8' >> /etc/locale.gen
  grep -Eq '^en_US\.UTF-8 UTF-8' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
  sed -i 's/^# *zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/g' /etc/locale.gen
  sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g' /etc/locale.gen
  locale-gen zh_CN.UTF-8
  locale-gen en_US.UTF-8

  log "[5/6] 设置系统语言环境..."
  update-locale LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 LANGUAGE=zh_CN:zh
}

configure_ssh() {
  if [ -f /etc/ssh/sshd_config ]; then
    warn "正在调整 SSH 配置，避免客户端语言覆盖服务器设置..."
    sed -i 's/^AcceptEnv LANG LC_\*/#AcceptEnv LANG LC_*/g' /etc/ssh/sshd_config || true
    sed -i 's/^AcceptEnv LANG LC_/## disabled by setup_chinese_zsh: &/g' /etc/ssh/sshd_config || true
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
  fi
}

ensure_zsh_block() {
  local begin="# >>> setup_chinese_zsh >>>"
  local end="# <<< setup_chinese_zsh <<<"
  local tmp
  tmp="$(mktemp)"

  if [ -f "$ZSHRC" ]; then
    awk -v b="$begin" -v e="$end" '
      $0==b {skip=1; next}
      $0==e {skip=0; next}
      !skip {print}
    ' "$ZSHRC" > "$tmp"
  fi

  cat >> "$tmp" <<'EOF'
# >>> setup_chinese_zsh >>>
export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN:zh
export LC_ALL=zh_CN.UTF-8
export LC_MESSAGES=zh_CN.UTF-8
alias cman='man -L zh_CN'
# <<< setup_chinese_zsh <<<
EOF

  mv "$tmp" "$ZSHRC"
}

validate_zsh() {
  zsh -n "$ZSHRC"
  zsh -c "source '$ZSHRC'; printf 'LANG=%s\n' \"\$LANG\"; printf 'LC_ALL=%s\n' \"\$LC_ALL\"; alias cman >/dev/null; echo CMAN_OK"
}

main() {
  log "=== 开始配置 zsh 中文环境 ==="
  require_root
  ensure_backup
  detect_os
  install_packages
  configure_locale
  configure_ssh
  ensure_zsh_block
  validate_zsh
  log "[6/6] 完成。"
  echo -e "${GREEN}zsh 中文环境已写入：${NC}$ZSHRC"
  echo -e "${GREEN}备份目录：${NC}$BACKUP_DIR"
  echo -e "${GREEN}恢复命令：${NC}bash $BACKUP_DIR/restore.sh"
  echo -e "${YELLOW}提示：重新登录 zsh 会话后，语言环境会完整生效。${NC}"
}

main "$@"
