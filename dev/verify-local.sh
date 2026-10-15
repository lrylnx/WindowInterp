#!/bin/zsh
# Actual source/shader checks. Requires Xcode command line tools; no screen permission needed.
set -eu
cd "$(dirname "$0")/.."
CHECK_DIR=$(mktemp -d /tmp/windowinterp-checks.XXXXXX)
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -O EngineSession.swift dev/verify-engine-session.swift -o "$CHECK_DIR/session-checks"
"$CHECK_DIR/session-checks"
# 「画质档必须真的能改画面」—— 源码级判据，不需要 GPU。
#
# ⚠️ 这条是拿真事故换来的（红线 119）：v1.4.0 里「Lanczos 重采样」和「MetalFX 空间放大」
# 两档**与「原始画质」逐像素完全相同** —— 因为采集尺寸恒等于输出尺寸（画面本来就是
# 1:1 原生像素），而这两档只在「输出 > 采集」时才会被走到，那个前提永远不成立。
# 当时**没有任何一条判据会因为它不存在而变红**，于是死档一路发到用户手上。
# 所以这里直接对枚举的**取值集合**下断言：能摆进「画质」下拉的，必须是在 1:1 下
# 也会改画面的档（目前只有 CAS 锐化）。谁要再往里加"放大档"，这条会当场变红。
python3 - <<'PY'
import re
from pathlib import Path

source = Path('main.swift').read_text(encoding='utf-8')
m = re.search(r'enum ReconstructMode: String, CaseIterable \{(.*?)\n\}', source, re.S)
assert m, '抽不到 ReconstructMode —— 枚举声明变了，这条判据自己失效了（要修判据！）'
cases = set(re.findall(r'^\s*case (\w+)', m.group(1), re.M))
allowed = {'off', 'cas'}
assert cases == allowed, (
    f'ReconstructMode 的取值集合变成了 {sorted(cases)}，期望 {sorted(allowed)}。\n'
    '只允许在 1:1 下也真的会改画面的档。'
    '新增"放大档"前先回答：本工具的「输出尺寸 > 采集尺寸」什么时候成立？'
    '（答案：永远不成立 —— 见 main.swift 里 ReconstructMode 的注释、dev/开发笔记.md 第二十三轮、红线 119）'
)
print(f'PASS 画质档取值集合 = {sorted(cases)}（都是 1:1 下真实生效的档）')

# ⚠️ 只看**代码行**（去掉 `//` / `///` 开头的注释行）再查这些名字。
#    注释里提到它们是对的（那是故意写给人看的"别再这么做"的说明），判据不该被自己写的说明绊倒
#    —— 这正是红线 112 说的"判据要找对作用域"，写这条时当场就踩了一次。
code = '\n'.join(l for l in source.split('\n') if not l.lstrip().startswith('//'))
for needle, why in [
    ('final class SpatialPass', 'SpatialPass 类又回来了'),
    ('import MetalFX', 'import MetalFX 又回来了'),
    ('"--output-scale"', '"--output-scale" 参数又回来了'),
    ('outputScaleFill', 'outputScaleFill 又回来了'),
    ('resolveOutputSize', 'resolveOutputSize 又回来了'),
    ('plannedOutputSize', 'plannedOutputSize 又回来了'),
]:
    assert needle not in code, (
        f'{why} —— "放大档 / 输出尺寸解耦"已证明在本工具里永远不生效（红线 119：'
        '先把「它在什么条件下才会被走到」找出来）'
    )
print('PASS 没有残留的放大档 / 输出尺寸解耦（只看代码行）')
PY
# 从 main.swift **就地抽取**真实的 CASPass 源码来测 ——
# 测的必须是当前源码，不能是副本（否则改了实现而测试还在测旧逻辑，判据会假绿）。
python3 - "$CHECK_DIR/Passes.swift" <<'PY'
from pathlib import Path
import sys
source = Path('main.swift').read_text()
start = source.index('final class CASPass {')
end = source.index('// MARK: - 采集 + 渲染管线', start)
Path(sys.argv[1]).write_text('import Metal\nimport CoreGraphics\n' + source[start:end])
PY
xcrun swiftc -O "$CHECK_DIR/Passes.swift" dev/verify-quality.swift -o "$CHECK_DIR/quality-checks"
"$CHECK_DIR/quality-checks"
