#!/bin/zsh

# --- 脚本功能：查找并处理最近安装的应用 ---

echo "正在检索 /Applications 目录下最近3小时内安装或修改的应用..."
echo ""

# 使用 find 命令查找最近180分钟内修改过的 .app 文件，并将结果存入数组
# -maxdepth 2 避免深入 .app 包内部进行不必要的搜索
# "${(@f)...}" 是 zsh 的一种安全方式，可以正确处理带空格的文件名
apps_found=("${(@f)$(find /Applications -maxdepth 2 -name "*.app" -mmin -180)}")

# 检查是否找到了任何应用
if [ ${#apps_found[@]} -eq 0 ]; then
  echo "⚠️ 未找到在最近3小时内安装或修改的应用。"
  exit 0
fi

echo "----------------------------------------"
echo "🔍 请从以下列表中选择要处理的应用："
echo ""

# 循环遍历数组，显示带编号的列表
for i in {1..${#apps_found[@]}}; do
  # 使用 basename 仅显示应用名，让列表更整洁
  app_name=$(basename "${apps_found[$i]}")
  printf "  %d) %s\n" "$i" "$app_name"
done

echo ""
echo "----------------------------------------"

# 循环提示用户输入，直到输入有效或退出
while true; do
  # -p "prompt_string" 用于显示提示信息
  read -p "请输入应用编号 (或输入 q 退出): " choice

  # 检查用户是否想退出
  if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
    echo "操作已取消。"
    exit 0
  fi

  # 检查输入是否为纯数字
  if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
    echo "❌ 无效输入，请输入列表中的数字。"
    continue
  fi

  # 检查编号是否在有效范围内 (zsh 数组索引从1开始)
  if [ "$choice" -ge 1 ] && [ "$choice" -le "${#apps_found[@]}" ]; then
    # 获取用户选择的应用的完整路径
    selected_app_path="${apps_found[$choice]}"
    
    echo ""
    echo "➡️ 您选择了: $(basename "$selected_app_path")"
    echo "🚀 正在执行命令..."
    
    # 对选定的应用执行核心命令，并使用 &&确保第一条成功后才执行第二条
    xattr -cr "$selected_app_path" && codesign -fs - "$selected_app_path"

    # 检查上一条命令的执行结果
    if [ $? -eq 0 ]; then
      echo "✅ 命令成功执行！"
    else
      echo "❌ 命令执行失败。"
    fi
    break # 成功处理后退出循环
  else
    echo "❌ 无效的编号，请输入 1 到 ${#apps_found[@]} 之间的数字。"
  fi
done
