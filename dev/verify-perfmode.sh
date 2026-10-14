#!/bin/zsh
# dev/verify-perfmode.sh — 「性能模式（轻量着色器）」开关的判据。
#
# 判什么：**界面写进去的那个偏好，真的走到了引擎的 performance_mode 上**。
# 这是这条链路上唯一容易静默出错的环节 —— 如果偏好没生效，引擎会一声不吭地
# 用默认（画质优先）着色器，功耗数字照旧，用户却以为自己开了省电模式。
#
# 所以这里不测功耗（那个看 dev/gpu-energy，且受机器状态影响），只测两件事：
#   ① 引擎启动回声里 Performance mode 的值 = 我们写的偏好值（能区分 A/B，不是"跑通了"）
#   ② 同一轮里 generated 必须还在涨 —— 红线：「插帧失效」会伪装成「优化成功」。
#
# 用法: dev/verify-perfmode.sh [源宽] [源高]
# 退出码 0 = 两项都过；非 0 = 有判据红了（并打印是哪一条）。
set -u
cd "$(dirname "$0")/.."

SW=${1:-1280}
SH=${2:-720}
DOMAIN=local.windowinterp

# 备份用户原来的偏好，跑完原样还回去（绝不改用户设置后不管）。
# ⚠️ `defaults read` 会把布尔读成 1/0，而 `defaults write -bool 1` 是**非法**的
# （只认 true/false）—— 不归一化就会打印一段 usage 还没还原成功。
ORIG=$(defaults read "$DOMAIN" performanceMode 2>/dev/null || echo "__unset__")
case "$ORIG" in
  1|true|yes) ORIG_BOOL=true ;;
  0|false|no) ORIG_BOOL=false ;;
  *) ORIG_BOOL="" ;;
esac
restore() {
  if [ -z "$ORIG_BOOL" ]; then defaults delete "$DOMAIN" performanceMode 2>/dev/null || true
  else defaults write "$DOMAIN" performanceMode -bool "$ORIG_BOOL"; fi
  echo "→ 已还原 performanceMode=${ORIG_BOOL:-（原本没设过，已删除）}"
}
trap restore EXIT INT TERM

PASS=0; FAIL=0
check() { # check <说明> <期望> <实际>
  if [ "$2" = "$3" ]; then echo "  ✅ $1：$3"; PASS=$((PASS+1))
  else echo "  ❌ $1：期望 $2，实际 $3"; FAIL=$((FAIL+1)); fi
}

probe_once() { # probe_once <标签> <偏好值>
  local tag=$1 want=$2
  defaults write "$DOMAIN" performanceMode -bool "$want"
  echo "── 轮次 $tag：偏好 performanceMode=$want ──"
  ./dev/engine-probe.sh "pmverify-$tag" 3 0 1.0 "$SW" "$SH" >/dev/null 2>&1
  local out=/tmp/probe-pmverify-$tag.out
  local echo_val gen_prev gen_last
  echo_val=$(grep -a "Performance mode:" "$out" | head -1 | awk '{print $NF}')
  gen_prev=$(grep -a "Frame generation stats" "$out" | tail -2 | head -1 | sed -n 's/.*generated=\([0-9]*\).*/\1/p')
  gen_last=$(grep -a "Frame generation stats" "$out" | tail -1 | sed -n 's/.*generated=\([0-9]*\).*/\1/p')
  check "$tag 引擎回声" "$want" "$echo_val"
  if [ -n "${gen_prev:-}" ] && [ -n "${gen_last:-}" ] && [ "$gen_last" -gt "$gen_prev" ]; then
    echo "  ✅ $tag 插帧真的在跑：generated $gen_prev → $gen_last"
    PASS=$((PASS+1))
  else
    echo "  ❌ $tag 插帧没在跑（generated 没涨：${gen_prev:-空} → ${gen_last:-空}）—— 功耗再低也不能算通过"
    FAIL=$((FAIL+1))
  fi
}

echo "### 性能模式判据 $(date '+%F %T') 源 ${SW}x${SH}"
probe_once on  true
probe_once off false

echo "──────────────────────────────"
echo "通过 $PASS 项，失败 $FAIL 项"
[ "$FAIL" -eq 0 ] || exit 1
