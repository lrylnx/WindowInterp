#!/bin/zsh
# Actual source/shader checks. Requires Xcode command line tools; no screen permission needed.
set -eu
cd "$(dirname "$0")/.."
CHECK_DIR=$(mktemp -d /tmp/windowinterp-checks.XXXXXX)
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -O EngineSession.swift dev/verify-engine-session.swift -o "$CHECK_DIR/session-checks"
"$CHECK_DIR/session-checks"
python3 - "$CHECK_DIR/CASPass.swift" <<'PY'
from pathlib import Path
import sys
source = Path('main.swift').read_text()
start = source.index('final class CASPass {')
end = source.index('// MARK: - 采集 + 渲染管线', start)
Path(sys.argv[1]).write_text('import Metal\nimport CoreGraphics\n' + source[start:end])
PY
xcrun swiftc -O "$CHECK_DIR/CASPass.swift" dev/verify-quality.swift -o "$CHECK_DIR/quality-checks"
"$CHECK_DIR/quality-checks"
