#!/bin/zsh
# Actual source/shader checks. Requires Xcode command line tools; no screen permission needed.
set -eu
cd "$(dirname "$0")/.."
CHECK_DIR=$(mktemp -d /tmp/windowinterp-checks.XXXXXX)
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -O EngineSession.swift dev/verify-engine-session.swift -o "$CHECK_DIR/session-checks"
"$CHECK_DIR/session-checks"
# 从 main.swift **就地抽取**真实的 CASPass / SpatialPass 源码来测 ——
# 测的必须是当前源码，不能是副本（否则改了实现而测试还在测旧逻辑，判据会假绿）。
python3 - "$CHECK_DIR/Passes.swift" <<'PY'
from pathlib import Path
import sys
source = Path('main.swift').read_text()
start = source.index('final class CASPass {')
end = source.index('// MARK: - 采集 + 渲染管线', start)
Path(sys.argv[1]).write_text('import Metal\nimport MetalFX\nimport CoreGraphics\n' + source[start:end])
PY
xcrun swiftc -O "$CHECK_DIR/Passes.swift" dev/verify-quality.swift -o "$CHECK_DIR/quality-checks"
"$CHECK_DIR/quality-checks"
xcrun swiftc -O "$CHECK_DIR/Passes.swift" dev/verify-metalfx.swift -o "$CHECK_DIR/metalfx-checks"
"$CHECK_DIR/metalfx-checks"
# 画质 A/B 测量：只报告特征指标 + 落对比图，**不做「哪个更好」的断言**（画质取决于内容）
xcrun swiftc -O "$CHECK_DIR/Passes.swift" dev/verify-metalfx-ab.swift -o "$CHECK_DIR/metalfx-ab"
"$CHECK_DIR/metalfx-ab"
