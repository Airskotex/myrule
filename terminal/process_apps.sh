#!/bin/bash

# --- 新增功能 ---
# 设置一个陷阱(trap)，无论脚本是正常执行完毕还是被中断，
# 在退出(EXIT)时都会执行 'rm -- "$0"' 命令，即删除脚本自身。
# '--' 是为了防止文件名被误认为是选项，增加安全性。
trap 'rm -- "$0"' EXIT
# --- 功能结束 ---

echo "正在检索 /Applications 目录下最近3小时内安装的应用..."

# 使用兼容旧版Bash的 while 循环来代替 readarray
recent_apps=()
while IFS= read -r app_path; do
  recent_apps+=("$app_path")
done < <(find "/Applications" -maxdepth 1 -name "*.app" -mmin -180)

# 检查数组是否为空
if [ ${#recent_apps[@]} -eq 0 ]; then
  echo "未找到在最近3小时内安装的应用。"
  # 脚本在这里退出，也会触发上面的trap命令
  exit 0
fi

echo "----------------------------------------"
echo "请选择要处理的应用："

# 循环遍历数组，显示带编号的列表
for i 在 "${!recent_apps[@]}"; do
  app_name=$(basename "${recent_apps[$i]}")
  printf "%d) %s\n" "$((i+1))" "$app_name"
done
echo "----------------------------------------"

# 循环提示用户输入
while true; do
  read -p "请输入应用编号 (或输入 q 退出): " choice

  if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
    echo "操作已取消。"
    # 脚本在这里退出，也会触发trap
    exit 0
  fi

  if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
    echo "无效输入，请输入列表中的数字。"
    continue
  fi

  index=$((choice-1))

  if [ "$index" -ge 0 ] && [ "$index" -lt "${#recent_apps[@]}" ]; then
    selected_app_path="${recent_apps[$index]}"
    
    echo "您选择了: $selected_app_path"
    echo "正在执行命令..."
    
    xattr -cr "$selected_app_path" && codesign -fs - "$selected_app_path"

    if [ $? -eq 0 ]; then
      echo "✅ 命令成功执行！"
    else
      echo "❌ 命令执行失败。"
    fi
    # break会结束循环，脚本继续往下执行直到结束，然后触发trap
    break
  else
    echo "无效的编号，请输入 1 到 ${#recent_apps[@]} 之间的数字。"
  fi
done

# 脚本正常执行到末尾，即将退出，此时也会触发trap
echo "脚本执行完毕，将自动删除..."
