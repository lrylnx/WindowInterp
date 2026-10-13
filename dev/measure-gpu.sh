#!/bin/zsh
# dev/measure-gpu.sh — 采样 GPU 利用率
#
# 为什么不用 powermetrics：它要 root，在自动化环境里拿不到。Apple Silicon 上
# IOAccelerator 的 "Device Utilization %" 不需要特权，且与真实功耗高度相关
# （插帧是纯 GPU 负载），足够做 A/B 对比。
#
# 用法: ./dev/measure-gpu.sh <秒数> [标签]

dur=${1:-15}
label=${2:-未命名}

samples=()
for i in $(seq 1 $dur); do
    v=$(ioreg -r -d 1 -c IOAccelerator 2>/dev/null | grep -o '"Device Utilization %"=[0-9]*' | head -1 | grep -o '[0-9]*$')
    [ -n "$v" ] && samples+=($v)
    sleep 1
done

if [ ${#samples[@]} -eq 0 ]; then
    echo "$label: 采样失败"
    exit 1
fi

printf "%s\n" "${samples[@]}" | awk -v label="$label" '
    { s += $1; n += 1; if ($1 > mx) mx = $1; if (mn == "" || $1 < mn) mn = $1 }
    END { printf "%-34s GPU 利用率 均值 %5.1f%%  峰值 %3d%%  最低 %3d%%  (n=%d)\n", label, s/n, mx, mn, n }
'
