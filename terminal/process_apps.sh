#!/usr/bin/env bash
# 列出最近 3 小时新增/变更的 .app，供选择后执行：
#   xattr -cr "<app>" && codesign -fs - "<app>"

set -euo pipefail
IFS=$'\n'

# ===== 可调参数 =====
HOURS=3  # 近几小时
SEARCH_DIRS=(/Applications "$HOME/Applications" /System/Applications "$HOME/Downloads")
# ====================

# 计算时间阈值（秒）
now_epoch=$(date +%s)
cutoff_epoch=$(( now_epoch - HOURS*3600 ))

# 检查依赖
command -v stat >/dev/null 2>&1 || { echo "缺少 stat 命令"; exit 1; }
command -v find >/dev/null 2>&1 || { echo "缺少 find 命令"; exit 1; }
command -v codesign >/dev/null 2>&1 || { echo "缺少 codesign 命令（Command Line Tools）"; exit 1; }

# 收集候选 .app
apps=()
for dir in "${SEARCH_DIRS[@]}"; do
  [[ -d "$dir" ]] || continue
  # -prune 避免深入 .app 包体；-print0 兼容空格路径
  while IFS= read -r -d '' app; do
    # 取创建/修改/状态变更时间（秒）
    b=$(stat -f %B -- "$app" 2>/dev/null || echo 0)  # birth（创建）
    m=$(stat -f %m -- "$app" 2>/dev/null || echo 0)  # mtime（内容修改）
    c=$(stat -f %c -- "$app" 2>/dev/null || echo 0)  # ctime（元数据变更）
    t=$m; (( b>t )) && t=$b; (( c>t )) && t=$c
    if (( t >= cutoff_epoch )); then
      apps+=("$app")
    fi
  done < <(find "$dir" -type d -name "*.app" -prune -print0 2>/dev/null)
done

# 去重并按修改时间降序排序
if ((${#apps[@]}==0)); then
  echo "在以下目录中未发现最近 ${HOURS} 小时新增/变更的 .app："
  printf ' - %s\n' "${SEARCH_DIRS[@]}"
  exit 0
fi

tmpfile="$(mktemp)"
for app in "${apps[@]}"; do
  mt=$(stat -f %m -- "$app" 2>/dev/null || echo 0)
  printf "%s\t%s\n" "$mt" "$app" >> "$tmpfile"
done

# sort 去重并排序（按路径去重）
sorted_tmp="${tmpfile}.sorted"
sort -nr -k1,1 "$tmpfile" | awk -F'\t' '!seen[$2]++ {print $2}' > "$sorted_tmp"
apps=()
while IFS= read -r line; do apps+=("$line"); done < "$sorted_tmp"
rm -f "$tmpfile" "$sorted_tmp"

# 展示列表
printf "找到以下最近 %d 小时内新增/变更的应用：\n" "$HOURS"
idx=1
for app in "${apps[@]}"; do
  mt=$(stat -f %m -- "$app" 2>/dev/null || echo 0)
  mins=$(( (now_epoch - mt) / 60 ))
  human_time=$(date -r "$mt" "+%Y-%m-%d %H:%M:%S")
  printf "%2d) %s\n    路径: %s\n    修改: %s（约 %d 分钟前）\n" \
         "$idx" "$(basename "$app")" "$app" "$human_time" "$mins"
  ((idx++))
done
echo

# 选择项：编号（空格分隔）或 a 处理全部
read -rp "请输入要处理的编号（空格分隔多个，或输入 a 处理全部）： " -a choices

to_process=()
if [[ "${choices[0]:-}" =~ ^[aA]$ ]]; then
  to_process=("${apps[@]}")
else
  for n in "${choices[@]}"; do
    if [[ "$n" =~ ^[0-9]+$ ]] && (( n>=1 && n<=${#apps[@]} )); then
      to_process+=("${apps[$((n-1))]}")
    fi
  done
fi

if ((${#to_process[@]}==0)); then
  echo "未选择任何应用，已退出。"
  exit 0
fi

echo
echo "将对以下应用执行：xattr -cr <app> && codesign -fs - <app>"
printf ' - %s\n' "${to_process[@]}"
read -rp "确认执行？(y/N): " yn
if [[ ! "$yn" =~ ^[yY]$ ]]; then
  echo "已取消。"
  exit 0
fi

# 执行处理
for app in "${to_process[@]}"; do
  echo
  echo "处理：$app"
  if sudo xattr -cr "$app" && sudo codesign -fs - "$app"; then
    echo "✅ 完成：$app"
  else
    echo "❌ 失败：$app"
  fi
done

echo
echo "全部处理完成。"
