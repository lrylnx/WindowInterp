#!/bin/zsh
# rec-run.sh — 输出重建（「档 1」）的自检跑批
#
# 对同一张**确定性测试源**（dev/testpattern --soft：半分辨率细字/细线，线性放大 2×）
# 反复跑几种重建档，每跑一次把「输出窗口的实际合成结果」截一张 PNG。
# 判据交给 dev/cmp-reconstruct.py（强度 0 必须与关闭档逐像素一致；锐化必须提升
# 边缘梯度且**不改变**尺度）。
#
# 用法： ./dev/rec-run.sh <输出目录> [额外参数…]
#   ./dev/rec-run.sh /tmp/rec                 # 输出=采集尺寸（纯锐化路径）
#   ./dev/rec-run.sh /tmp/rec --resolution 240 --output-scale fill   # 输出≠采集尺寸
set -u
cd "$(dirname "$0")/.."
OUT=${1:-/tmp/rec}
shift || true
# 额外参数**原样透传**给每个档位。用数组而不是字符串：早先写成 `${(z)1:-}` 只吃到了
# 第一个参数，`--resolution 240 --output-scale fill` 后半截被默默丢掉，判据看起来"全绿"
# 其实跑的还是默认档 —— 静默丢参数的坑。
EXTRA=("$@")

mkdir -p "$OUT"
rm -f "$OUT"/*.png(N) "$OUT"/*.log(N)   # `(N)` = zsh 空匹配不报错

APP="./窗口插帧助手.app/Contents/MacOS/WindowInterp"
# 两件必须做的事，否则判据量到的是"被二次重采样过的画面"而不是渲染本身：
#  ① `--test-window` 默认 900x560，与源窗口的 760x480 不符 ⇒ CAMetalLayer 会把纹理
#     拉伸一次（多一层重采样污染判据）。
#  ② 窗口是 `.titled`，**帧比内容大 12pt 宽、28pt 高**（实测：内容区 = 帧 −(12,28)）。
#     所以帧要开成 +12/+28，内容区才正好等于源尺寸 ⇒ 1:1 显示。
W=760; H=480

# 一次源、三种配置 —— 源必须是同一份（同一进程、同一位置），否则没法比较
./dev/testpattern --width 760 --height 480 --x 60 --y 60 --soft --seconds 40 > "$OUT/src.log" 2>&1 &
TP=$!
sleep 1.2
WID=$(grep -o 'windowNumber=[0-9]*' "$OUT/src.log" | head -1 | cut -d= -f2)
echo "源窗口 WID=$WID   ($(grep -o 'SOFT_PATTERN .*' "$OUT/src.log" | head -1))"
[ -z "$WID" ] && { echo "拿不到源窗口 id"; kill $TP 2>/dev/null; exit 1; }

run() {   # run <名字> [额外 app 参数…]
  local name=$1; shift
  echo "── 跑 $name : $*"
  local before=$(wc -l < ~/Library/Logs/WindowInterp/app.log 2>/dev/null || echo 0)
  $APP --test-window --off --window-id "$WID" --autostart --test-seconds 9 \
       --test-x 900 --test-y 60 --test-w $((W+12)) --test-h $((H+28)) \
       -showBadge NO \
       --dump-output "$OUT/$name" "$@" "${EXTRA[@]}" > "$OUT/$name.log" 2>&1
  tail -n +$((before + 1)) ~/Library/Logs/WindowInterp/app.log > "$OUT/$name.applog" 2>/dev/null
  grep -E "^start: 输出|reconstruct:|DUMP_DONE|dump window" "$OUT/$name.log" | sed 's/^/    /'
}

run off
run cas0   --reconstruct cas --reconstruct-sharp 0
run cas    --reconstruct cas --reconstruct-sharp 0.5
run lanczos --reconstruct lanczos

kill $TP 2>/dev/null
sleep 0.3
echo "── 截图 ──"
ls -la "$OUT"/*.png
