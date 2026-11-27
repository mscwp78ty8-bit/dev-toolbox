#!/bin/bash
cd "$(dirname "$0")" || exit 1
if ! command -v python3 >/dev/null 2>&1; then
    echo "缺少 python3，请先安装 Xcode 命令行工具：xcode-select --install"
    read -n 1 -s -r
    exit 1
fi
python3 fix-war3-dxrender.py "$@"
echo
echo "按任意键关闭窗口..."
read -n 1 -s -r
echo