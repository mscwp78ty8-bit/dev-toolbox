#!/bin/bash
cd "$(dirname "$0")" || exit 1

if ! command -v python3 >/dev/null 2>&1; then
    echo "缺少 python3，请先安装 Xcode 命令行工具：xcode-select --install"
    read -n 1 -s -r
    exit 1
fi

KILL="--kill-wine"
case "$*" in
    *--verify*|*--restore*|*--dry-run*) KILL="" ;;
esac

echo "======================================================"
echo "  11 平台 War3 · CrossOver 一键修复"
echo "    问题一：启动 / 进游戏 0xC0000005 崩溃"
echo "    问题二：高 DPI 下画面模糊 / 向下偏移 / 只剩声音"
echo "======================================================"
echo

if [ -n "$KILL" ]; then
    echo "将依次执行："
    echo "  1) 分辨率 / DPI 修复：RetinaMode、高 DPI 感知标记、游戏分辨率"
    echo "  2) DxRender 崩溃补丁：含 MD5 / DownloadList 同步，防止被平台还原"
    echo
    echo "注意：第 1 步会关闭该容器内所有 Wine 进程，11 平台和游戏都会退出。"
    read -r -p "按回车继续（Ctrl+C 取消）... " _
    echo
fi

python3 fix-war3-dpi.py $KILL "$@"
RC1=$?

echo
python3 fix-war3-dxrender.py "$@"
RC2=$?

echo
echo "======================================================"
if [ -z "$KILL" ]; then
    if [ $RC1 -eq 0 ] && [ $RC2 -eq 0 ]; then
        echo "  检查结束（本次没有改动任何文件）"
    else
        echo "  检查未全部通过，请查看上面的输出"
    fi
elif [ $RC1 -eq 0 ] && [ $RC2 -eq 0 ]; then
    echo "  全部完成：重新启动 11 平台即可"
else
    echo "  有步骤未通过，请查看上面的输出"
fi
echo "======================================================"
echo
echo "按任意键关闭窗口..."
read -n 1 -s -r
echo