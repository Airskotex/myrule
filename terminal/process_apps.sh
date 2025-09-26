#!/bin/bash

echo "正在检索 /Applications 目录下最近3小时内安装的应用..."

# 使用 find 命令查找应用，并将结果存入数组
# readarray (或 mapfile) 可以安全地将 find 的输出读入数组，即使文件名包含空格
readarray -t recent_apps < <(find "/Applications" -maxdepth 1 -name "*.app" -mmin -180)

# 检查是否找到了任何应用
if [ ${#recent_apps[@]} -eq 0 ]; then
  echo "未找到在最近3小时内安装的应用。"
  exit 0
fi

echo "----------------------------------------"
echo "请选择要处理的应用："

# 循环遍历数组，显示带编号的列表
for i in "${!recent_apps[@]}"; do
  # 使用 basename 仅显示应用名，更美观
  app_name=$(basename "${recent_apps[$i]}")
  printf "%d) %s\n" "$((i+1))" "$app_name"
done
echo "----------------------------------------"

# 循环提示用户输入，直到输入有效为止
while true; do
  read -p "请输入应用编号 (或输入 q 退出): " choice

  # 检查用户是否想退出
  if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
    echo "操作已取消。"
    exit 0
  fi

  # 检查输入是否为纯数字
  if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
    echo "无效输入，请输入列表中的数字。"
    continue
  fi

  # 将用户输入转换为数组索引 (数组从0开始)
  index=$((choice-1))

  # 检查编号是否在有效范围内
  if [ "$index" -ge 0 ] && [ "$index" -lt "${#recent_apps[@]}" ]; then
    # 获取用户选择的应用路径
    selected_app_path="${recent_apps[$index]}"
    
    echo "您选择了: $selected_app_path"
    echo "正在执行命令..."
    
    # 对选定的应用执行命令
    xattr -cr "$selected_app_path" && codesign -fs - "$selected_app_path"

    # 检查命令执行结果
    if [ $? -eq 0 ]; then
      echo "✅ 命令成功执行！"
    else
      echo "❌ 命令执行失败。"
    fi
    break # 成功处理后退出循环
  else
    echo "无效的编号，请输入 1 到 ${#recent_apps[@]} 之间的数字。"
  fi
done
