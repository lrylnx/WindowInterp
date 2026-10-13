#!/bin/zsh
# lat-round.sh — 一轮端到端延迟测量（整轮必须在同一条命令里跑完：源窗口、插帧 App
# 都是 nohup 起的进程，跨命令就没了）
#
# 用法: lat-round.sh <screencapture序号> <CGDirectDisplayID> <mult|off> <srcX> <srcY> <outX> <outY> <期望截图宽> <期望截图高> <标签> [额外的 KEY=VALUE 引擎环境变量...]
#   screencapture -D 用的是「在线屏枚举序号」（实测：1=主屏外接，2=内建），不是 CGDirectDisplayID；
#   latency-probe --display 才吃 CGDirectDisplayID。两者都要传，并用期望尺寸校验截对了屏。
#   第 11 个参数起是**额外的引擎环境变量**（原样交给 --engine-env），用来做旋钮 A/B：
#     dev/lat-round.sh 1 2 2 60 300 700 300 2560 1440 lat-on LSFGM_LATENCY=1
# 固定条件（与 60Hz 历史测量可比）: 光流 0.5、queueDepth 3（默认）、工作分辨率 400p。
set -u
cd "$(dirname "$0")/.."
IDX=$1; DID=$2; MULT=$3; SX=$4; SY=$5; OX=$6; OY=$7; EW=$8; EH=$9; TAG=${10}
shift 10
EXTRA_ENVS=("$@")          # 可能为空数组
SRCW=640; SRCH=400; OUTW=620; OUTH=400
PERIOD=2.0
# BIN 可用环境变量覆盖（拿另一份 App 做对照，例如桌面那份官方 build.sh 产物）
BIN="${BIN_OVERRIDE:-./窗口插帧助手.app/Contents/MacOS/WindowInterp}"
# 整轮输出同时落盘 —— 跑一组 A/B 时经常只 tail 了最后几行，把中位数那行弄丢（踩过）。
OUTLOG=/tmp/lat-round-$TAG.out
exec > >(tee "$OUTLOG") 2>&1
echo "### $(date '+%F %T') lat-round tag=$TAG mult=$MULT extra=${EXTRA_ENVS[*]:-无} → $OUTLOG"

nohup ./dev/testpattern --ruler --x "$SX" --y "$SY" --width $SRCW --height $SRCH --seconds 55 >/tmp/tp-$TAG.log 2>&1 &
TPPID=$!
sleep 1.5
TP_WIN=$(grep -o 'windowNumber=[0-9]*' /tmp/tp-$TAG.log | head -1 | cut -d= -f2)
if [ -z "${TP_WIN:-}" ]; then echo "!! testpattern 没起来"; cat /tmp/tp-$TAG.log; kill $TPPID 2>/dev/null; exit 1; fi

ARGS=(--window-id "$TP_WIN" --autostart --test-window --test-x "$OX" --test-y "$OY" --test-w $OUTW --test-h $OUTH --test-seconds 50 --resolution 400 --engine-env LSFGM_FLOW_SCALE=0.5)
for kv in "${EXTRA_ENVS[@]}"; do ARGS+=(--engine-env "$kv"); done
if [ "$MULT" = "off" ]; then ARGS+=(--off); else ARGS+=(--multiplier "$MULT"); fi
nohup "$BIN" "${ARGS[@]}" >/tmp/wi-$TAG.log 2>&1 &
WIPID=$!
sleep 7
OUT_WIN=$(grep -o 'INTERP_WINDOW_ID=[0-9]*' /tmp/wi-$TAG.log | head -1 | cut -d= -f2)

rm -f /tmp/lat-$TAG-*.png
screencapture -x -o -D "$IDX" /tmp/lat-$TAG-check.png
GW=$(sips -g pixelWidth /tmp/lat-$TAG-check.png 2>/dev/null | awk '/pixelWidth/{print $2}')
GH=$(sips -g pixelHeight /tmp/lat-$TAG-check.png 2>/dev/null | awk '/pixelHeight/{print $2}')
if [ "$GW" != "$EW" ] || [ "$GH" != "$EH" ]; then
  echo "!! 截错屏了：得到 ${GW}x${GH}，期望 ${EW}x${EH}（screencapture -D 序号变了？）"
  kill $WIPID $TPPID 2>/dev/null; exit 1
fi
echo "== $TAG (屏$DID · ${MULT}×) src=$TP_WIN out=$OUT_WIN 截图=${GW}x${GH}"

for i in $(seq 1 14); do screencapture -x -o -D "$IDX" /tmp/lat-$TAG-$i.png; sleep 1.4; done

./dev/latency-probe --display "$DID" "$TP_WIN" "$OUT_WIN" $PERIOD /tmp/lat-$TAG-*.png
echo "—— 引擎状态（核对 generated 在涨，防「假低延迟」）:"
grep -E "Flow scale|Pacing|Multiplier|Frame generation stats" /tmp/wi-$TAG.log | tail -5
echo "—— 引擎侧自带延迟统计（LSFGM_LATENCY / LSFGM_STATS）:"
grep -E "Metal latency|Metal display intervals|display intervals|p50_ms|p95_ms|Unrecognized" /tmp/wi-$TAG.log | tail -8
kill $WIPID $TPPID 2>/dev/null
sleep 0.5
echo "done $TAG"
