#!/bin/zsh
# engine-probe.sh — 配置体检：不去测端到端延迟（那个公式已知），
# 只跑固定时长并收集**引擎侧统计**（生成帧数、late 比例、各环节耗时、
# 温度/功耗可另行用 dev/gpu-energy.swift）。
#
# 用法:
#   engine-probe.sh <标签> <倍率|off> <工作分辨率|0> <光流> <源宽> <源高> [额外 KEY=VALUE ...]
# 例:
#   dev/engine-probe.sh user5x 5 0 0.5 1280 720
#   dev/engine-probe.sh rec2x  2 0 1.0 1280 720
#
# 说明:
#   * 工作分辨率传 0 = 跟随源像素（工具里的「跟随面板像素」档）
#   * --test-window 会强制关掉游戏模式（贴源覆盖层），避免源/输出窗重合
#   * 第 7 参数起原样透传给 --engine-env，用来试引擎旋钮
set -u
cd "$(dirname "$0")/.."

TAG=$1 LOGMULT=$2 RES=$3 FLOW=$4 SW=$5 SH=$6
shift 6
EXTRA=("$@")

OUTLOG=/tmp/probe-$TAG.out
SECS=16
exec > >(tee "$OUTLOG") 2>&1

echo "### $(date '+%F %T') probe=$TAG mult=$LOGMULT res=$RES flow=$FLOW src=${SW}x${SH} extra=${EXTRA[*]:-无}"

nohup ./dev/testpattern --x 60 --y 60 --width "$SW" --height "$SH" --seconds $((SECS + 22)) >/tmp/tpp-$TAG.log 2>&1 &
TPPID=$!
sleep 1.5
TP_WIN=$(grep -o 'windowNumber=[0-9]*' /tmp/tpp-$TAG.log | head -1 | cut -d= -f2)
if [ -z "${TP_WIN:-}" ]; then echo "!! testpattern 没起来"; cat /tmp/tpp-$TAG.log; kill $TPPID 2>/dev/null; exit 1; fi

ARGS=(--window-id "$TP_WIN" --autostart --test-window
      --test-x 60 --test-y $((SH + 140)) --test-w "$SW" --test-h "$SH"
      --test-seconds "$SECS" --resolution "$RES")
if [ "$LOGMULT" = "off" ]; then
  ARGS+=(--off)
else
  ARGS+=(--multiplier "$LOGMULT" --engine-env "LSFGM_FLOW_SCALE=$FLOW")
fi
for kv in "${EXTRA[@]}"; do ARGS+=(--engine-env "$kv"); done

nohup ./窗口插帧助手.app/Contents/MacOS/WindowInterp "${ARGS[@]}" >/tmp/wip-$TAG.log 2>&1 &
WIPID=$!
sleep $((SECS + 5))
kill $WIPID $TPPID 2>/dev/null
sleep 0.4

ENG=$(ls -t ~/Library/Logs/WindowInterp/engine-*.log 2>/dev/null | head -1)
echo "== 引擎启动参数一瞥（app stdout）=="
grep -aE "launch v|Flow scale|Performance mode|Multiplier|Pacing|Unrecognized" /tmp/wip-$TAG.log | tail -12
echo "== 引擎统计（stdout）=="
grep -aE "Frame generation stats|generated|captured|late|Metal latency|display intervals|p50|p95" /tmp/wip-$TAG.log | tail -18
echo "== 引擎日志（$ENG）=="
grep -aE "Flow scale|Performance mode|Multiplier|Pacing|Frame generation stats|late|p50|p95|Unrecognized|skipped|disabled" "$ENG" 2>/dev/null | tail -22
echo "done $TAG"
