#!/bin/zsh
# orient-run.sh — 判定「输出窗口/覆盖层到底是正立还是上下颠倒」
#
# 背景（2026-10-12 第十五轮）：评估「档 1」时发现，**LSFG 引擎在呈现时会把 drawable
# 上下翻一次** —— 所以 `present()` 里那次翻转是拿来抵消它的。于是：
#   * 生产路径（引擎在）＝ 正立
#   * `--off`（无引擎）    ＝ 上下颠倒  ← 长期存在、没人注意（已在 1.1.1-rec1 修掉：
#                                            displayFlip 按 offMode 取反）
# 这个脚本就是把这条结论钉死：对同一张确定性源图（--soft：文字在顶、1px 细线在 52%、
# 灰块在右），逐个配置截「屏幕上的真实窗口」，再裁掉窗口阴影、按行/列剖面判定朝向。
#
# 用法： ./dev/orient-run.sh <输出目录>
# 注意：判据必须自动裁「内容区」—— `screencapture -l` 会把窗口阴影/透明边一起截进来
#      （外面是透明 → convert('L') 成黑），不裁的话每张图最上面都有一条窄暗边，
#      把所有配置都判成「文字在顶 = 正立」，零区分度（第一版就栽在这）。
set -u
cd "$(dirname "$0")/.."
OUT=${1:-/tmp/orient}
mkdir -p "$OUT"
rm -f "$OUT"/*.png(N) "$OUT"/*.log(N)   # `(N)` = zsh 空匹配不报错（目录还空时会炸）

APP="./窗口插帧助手.app/Contents/MacOS/WindowInterp"
LOG="$HOME/Library/Logs/WindowInterp/app.log"

./dev/testpattern --width 760 --height 480 --x 60 --y 60 --soft --seconds 70 > "$OUT/src.log" 2>&1 &
TP=$!
sleep 1.2
WID=$(grep -o 'windowNumber=[0-9]*' "$OUT/src.log" | head -1 | cut -d= -f2)
echo "源 WID=$WID"
[ -z "$WID" ] && { kill $TP 2>/dev/null; exit 1; }
screencapture -x -l "$WID" "$OUT/truth-src.png"   # 源窗口的真实样子（基准）

shot() {   # shot <名字> <是否覆盖层> [app 参数…]
  local name=$1 overlay=$2; shift 2
  local before=$(wc -l < "$LOG")
  $APP --window-id "$WID" --autostart --test-seconds 8 -showBadge NO "$@" > "$OUT/$name.log" 2>&1 &
  local pid=$!
  sleep 5
  local nid
  nid=$(tail -n +$((before + 1)) "$LOG" | grep -o 'output: 覆盖层 id=[0-9]*' | tail -1 | grep -o '[0-9]*$')
  if [ -z "$nid" ]; then nid=$(grep -o 'INTERP_WINDOW_ID=[0-9]*' "$OUT/$name.log" | head -1 | cut -d= -f2); fi
  screencapture -x -l "$nid" "$OUT/$name.png"
  kill $pid 2>/dev/null
  wait $pid 2>/dev/null
  sleep 0.6
  echo "  $name → 窗口 $nid"
}

echo "── 逐个配置截图 ──"
shot off-noengine       1 --off
shot eng-off            1 --multiplier 2
shot eng-lanczos        1 --multiplier 2 --reconstruct lanczos
shot eng-cas0           1 --multiplier 2 --reconstruct cas --reconstruct-sharp 0
shot eng-cas            1 --multiplier 2 --reconstruct cas --reconstruct-sharp 0.5
shot off-cas-noengine   1 --off --reconstruct cas --reconstruct-sharp 0.5

kill $TP 2>/dev/null
sleep 0.3

/Users/zxwzz/.workbuddy/binaries/python/envs/default/bin/python - "$OUT" <<'PY'
import sys, os, numpy as np
from PIL import Image
out = sys.argv[1]

def content_box(path):
    """截图里窗口**外面**是透明→黑，内容区就是中间那块。自动裁掉，别让窗口阴影/圆角
    边框混进剖面（第一版判据就是被这个坑了：每张图最上面都有一条窄暗边，于是所有
    配置都被判成"文字在顶=正立"，完全无区分度）。"""
    a = np.asarray(Image.open(path).convert('L')).astype(np.float64)
    def span(v, thr=100):
        idx = np.where(v > thr)[0]
        best = (0, 0); st = prev = idx[0]
        for i in idx[1:]:
            if i != prev + 1:
                if prev - st > best[1] - best[0]: best = (st, prev)
                st = i
            prev = i
        if prev - st > best[1] - best[0]: best = (st, prev)
        return best
    r0, r1 = span(a.mean(axis=1)); c0, c1 = span(a.mean(axis=0))
    return a[r0:r1+1, c0:c1+1]

def prof(path):
    sub = content_box(path)
    return sub.mean(axis=1), sub.mean(axis=0), sub.shape

def mae(x, y):
    n = min(len(x), len(y))
    return float(np.abs(x[:n] - y[:n]).mean())

rt, ct, shp = prof(f"{out}/truth-src.png")
print(f"基准（源窗口）内容区 {shp[1]}x{shp[0]}   "
      f"文字块在顶（行剖面最暗处 {int(np.argmin(rt)/len(rt)*100)}% 处）")
print()
print(f"{'配置':<20}{'内容区':>12}  行:原样/竖翻    判定        列:原样/镜像")
print('-' * 74)
OK = ["off-noengine", "eng-off", "eng-lanczos", "eng-cas0", "eng-cas", "off-cas-noengine"]
for name in OK:
    p = f"{out}/{name}.png"
    if not os.path.exists(p):
        print(f"{name:<20}{'（缺）':>12}"); continue
    r, c, shp = prof(p)
    vs, vf = mae(rt, r), mae(rt, r[::-1])       # 竖翻
    hs, hf = mae(ct, c), mae(ct, c[::-1])       # 水平镜像
    if vf < vs * 0.5:
        verv = "上下颠倒 ❌"
    elif vs < vf * 0.5:
        verv = "正立 ✅" if hs <= hf else "正立/左右镜像 ⚠️"
    else:
        verv = "方向不明 ⚠️"
    print(f"{name:<20}{f'{shp[1]}x{shp[0]}':>12}  {vs:6.2f}/{vf:6.2f}   {verv:<12} {hs:6.2f}/{hf:6.2f}")
print()
print("判据：行剖面「原样」明显小于「竖翻」= 与源同向（正立）。约 1700 倍裕度，无灰区。")
print("修复前（1.1.1-rec1 之前，关徽标实测）：eng-* ≈0.0/17.1（同向） / off-* 16.7/1.4（颠倒 ❌）")
print("修复后（displayFlip 按 offMode 取反）：off-* 0.01/17.14（同向）—— 数值干净反转。")
print("列剖面「原样」<「镜像」⇒ 没有左右镜像（图案本身左右不对称：文字在左、灰块在右）。")
print("注意 `-showBadge NO`：徽标上的 fps 数字每次都变，会把行剖面从 0.01 顶到 2.1。")
PY
