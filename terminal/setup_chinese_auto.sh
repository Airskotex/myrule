#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 2>/dev/null || true)"
TARGET_HOME="${TARGET_HOME:-/root}"
BACKUP_ROOT="/root/.config/hermes-shell-backups"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/setup-chinese-auto-$TIMESTAMP"
MODE="${1:-auto}"
TARGET_SHELL=""
TARGET_SHELL_PATH=""
TARGET_RC_FILE=""

log() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }
err() { echo -e "${RED}$*${NC}"; }

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    err "错误：请用 root 运行此脚本"
    exit 1
  fi
}

usage() {
  cat <<'EOF'
用法：
  bash /root/setup_chinese_auto.sh           # 自动判断 shell
  bash /root/setup_chinese_auto.sh auto      # 自动判断 shell
  bash /root/setup_chinese_auto.sh fish      # 强制按 fish 配置
  bash /root/setup_chinese_auto.sh zsh       # 强制按 zsh 配置
  bash /root/setup_chinese_auto.sh bash      # 强制按 bash 配置
EOF
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

resolve_shell() {
  case "$MODE" in
    auto)
      TARGET_SHELL_PATH="$(getent passwd "$TARGET_USER" | cut -d: -f7 2>/dev/null || true)"
      case "$(basename "$TARGET_SHELL_PATH")" in
        fish|zsh|bash) TARGET_SHELL="$(basename "$TARGET_SHELL_PATH")" ;;
        *)
          if command -v fish >/dev/null 2>&1; then
            TARGET_SHELL="fish"
            TARGET_SHELL_PATH="$(command -v fish)"
          elif command -v zsh >/dev/null 2>&1; then
            TARGET_SHELL="zsh"
            TARGET_SHELL_PATH="$(command -v zsh)"
          else
            TARGET_SHELL="bash"
            TARGET_SHELL_PATH="$(command -v bash || echo /bin/bash)"
          fi
          ;;
      esac
      ;;
    fish|zsh|bash)
      TARGET_SHELL="$MODE"
      TARGET_SHELL_PATH="$(command -v "$MODE" 2>/dev/null || true)"
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      err "不支持的模式：$MODE"
      usage
      exit 1
      ;;
  esac

  case "$TARGET_SHELL" in
    fish)
      TARGET_RC_FILE="$TARGET_HOME/.config/fish/config.fish"
      ;;
    zsh)
      TARGET_RC_FILE="$TARGET_HOME/.zshrc"
      ;;
    bash)
      TARGET_RC_FILE="$TARGET_HOME/.bashrc"
      ;;
  esac

  log "目标用户: $TARGET_USER"
  log "目标 shell: $TARGET_SHELL (${TARGET_SHELL_PATH:-未安装})"
  log "目标配置文件: $TARGET_RC_FILE"
}

install_packages() {
  log "[1/6] 更新软件源..."
  apt update -y

  log "[2/6] 安装中文字体、man 手册、locale 和目标 shell..."
  apt install -y fonts-noto-cjk fonts-wqy-microhei fonts-wqy-zenhei manpages-zh locales

  case "$TARGET_SHELL" in
    fish) apt install -y fish ;;
    zsh) apt install -y zsh ;;
    bash) apt install -y bash ;;
  esac

  log "[3/6] 修复精简系统缺失的翻译文件..."
  if [ "$OS" = "ubuntu" ]; then
    apt install -y language-pack-zh-hans
    apt install --reinstall -y locales "$TARGET_SHELL"
  else
    apt install --reinstall -y locales bash coreutils grep sed
    [ "$TARGET_SHELL" = "fish" ] && apt install --reinstall -y fish || true
    [ "$TARGET_SHELL" = "zsh" ] && apt install --reinstall -y zsh || true
  fi
}

backup_files() {
  mkdir -p "$BACKUP_DIR/files"
  [ -f /etc/locale.gen ] && cp -a /etc/locale.gen "$BACKUP_DIR/files/locale.gen"
  [ -f /etc/default/locale ] && cp -a /etc/default/locale "$BACKUP_DIR/files/default-locale"
  [ -f /etc/ssh/sshd_config ] && cp -a /etc/ssh/sshd_config "$BACKUP_DIR/files/sshd_config"
  [ -f "$TARGET_RC_FILE" ] && cp -a "$TARGET_RC_FILE" "$BACKUP_DIR/files/target_rc"

  cat > "$BACKUP_DIR/restore.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
BACKUP_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
TARGET_RC_FILE="${TARGET_RC_FILE}"
mkdir -p "\$(dirname "\$TARGET_RC_FILE")"
if [ -f "\$BACKUP_DIR/files/locale.gen" ]; then cp -a "\$BACKUP_DIR/files/locale.gen" /etc/locale.gen; fi
if [ -f "\$BACKUP_DIR/files/default-locale" ]; then cp -a "\$BACKUP_DIR/files/default-locale" /etc/default/locale; fi
if [ -f "\$BACKUP_DIR/files/sshd_config" ]; then cp -a "\$BACKUP_DIR/files/sshd_config" /etc/ssh/sshd_config; fi
if [ -f "\$BACKUP_DIR/files/target_rc" ]; then
  cp -a "\$BACKUP_DIR/files/target_rc" "\$TARGET_RC_FILE"
else
  rm -f "\$TARGET_RC_FILE"
fi
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
printf '已恢复备份：%s\n' "\$BACKUP_DIR"
EOF
  chmod +x "$BACKUP_DIR/restore.sh"

  {
    printf 'created_at=%s\n' "$(date -Is)"
    printf 'target_user=%s\n' "$TARGET_USER"
    printf 'target_shell=%s\n' "$TARGET_SHELL"
    printf 'target_shell_path=%s\n' "$TARGET_SHELL_PATH"
    printf 'target_rc_file=%s\n' "$TARGET_RC_FILE"
  } > "$BACKUP_DIR/metadata.txt"
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
    sed -i 's/^AcceptEnv LANG LC_/## disabled by setup_chinese_auto: &/g' /etc/ssh/sshd_config || true
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
  fi
}

remove_old_block() {
  local file="$1"
  local begin="$2"
  local end="$3"
  local tmp
  tmp="$(mktemp)"
  if [ -f "$file" ]; then
    awk -v b="$begin" -v e="$end" '
      $0==b {skip=1; next}
      $0==e {skip=0; next}
      !skip {print}
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
  fi
}

write_shell_config() {
  mkdir -p "$(dirname "$TARGET_RC_FILE")"

  case "$TARGET_SHELL" in
    fish)
      local begin="# >>> setup_chinese_auto_fish >>>"
      local end="# <<< setup_chinese_auto_fish <<<"
      remove_old_block "$TARGET_RC_FILE" "$begin" "$end"
      cat >> "$TARGET_RC_FILE" <<'EOF'
# >>> setup_chinese_auto_fish >>>
set -gx LANG zh_CN.UTF-8
set -gx LANGUAGE zh_CN:zh
set -gx LC_ALL zh_CN.UTF-8
set -gx LC_MESSAGES zh_CN.UTF-8

if command -q man
    alias cman='man -L zh_CN'
end
# <<< setup_chinese_auto_fish <<<
EOF
      ;;
    zsh)
      local begin="# >>> setup_chinese_auto_zsh >>>"
      local end="# <<< setup_chinese_auto_zsh <<<"
      remove_old_block "$TARGET_RC_FILE" "$begin" "$end"
      cat >> "$TARGET_RC_FILE" <<'EOF'
# >>> setup_chinese_auto_zsh >>>
export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN:zh
export LC_ALL=zh_CN.UTF-8
export LC_MESSAGES=zh_CN.UTF-8
alias cman='man -L zh_CN'
# <<< setup_chinese_auto_zsh <<<
EOF
      ;;
    bash)
      local begin="# >>> setup_chinese_auto_bash >>>"
      local end="# <<< setup_chinese_auto_bash <<<"
      remove_old_block "$TARGET_RC_FILE" "$begin" "$end"
      cat >> "$TARGET_RC_FILE" <<'EOF'
# >>> setup_chinese_auto_bash >>>
export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN:zh
export LC_ALL=zh_CN.UTF-8
export LC_MESSAGES=zh_CN.UTF-8
alias cman='man -L zh_CN'
# <<< setup_chinese_auto_bash <<<
EOF
      ;;
  esac
}

validate_config() {
  case "$TARGET_SHELL" in
    fish)
      fish -n "$TARGET_RC_FILE"
      fish -c "source '$TARGET_RC_FILE'; printf 'LANG=%s\n' \"\$LANG\"; printf 'LC_ALL=%s\n' \"\$LC_ALL\"; functions -q cman; and echo CMAN_OK"
      ;;
    zsh)
      zsh -n "$TARGET_RC_FILE"
      zsh -c "source '$TARGET_RC_FILE'; printf 'LANG=%s\n' \"\$LANG\"; printf 'LC_ALL=%s\n' \"\$LC_ALL\"; alias cman >/dev/null; echo CMAN_OK"
      ;;
    bash)
      bash -n "$TARGET_RC_FILE"
      bash -c "source '$TARGET_RC_FILE'; printf 'LANG=%s\n' \"\$LANG\"; printf 'LC_ALL=%s\n' \"\$LC_ALL\"; alias cman >/dev/null; echo CMAN_OK"
      ;;
  esac
}

main() {
  if [ "$MODE" = "--help" ] || [ "$MODE" = "-h" ] || [ "$MODE" = "help" ]; then
    usage
    exit 0
  fi

  log "=== 开始自动配置中文环境 ==="
  require_root
  resolve_shell
  detect_os
  backup_files
  install_packages
  configure_locale
  configure_ssh
  write_shell_config
  validate_config
  log "[6/6] 完成。"
  echo -e "${GREEN}已配置 shell：${NC}$TARGET_SHELL"
  echo -e "${GREEN}已写入配置：${NC}$TARGET_RC_FILE"
  echo -e "${GREEN}备份目录：${NC}$BACKUP_DIR"
  echo -e "${GREEN}恢复命令：${NC}bash $BACKUP_DIR/restore.sh"
  echo -e "${YELLOW}提示：重新登录后中文环境会完整生效。${NC}"
}

main "$@"
