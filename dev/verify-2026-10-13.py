import subprocess, time, re
from pathlib import Path
root = Path(__file__).resolve().parent.parent
out = root / 'dev' / 'verification-2026-10-13'
out.mkdir(exist_ok=True)
with (out / 'source.log').open('w') as f:
    source = subprocess.Popen([str(root/'dev/testpattern'), '--x','60','--y','60','--width','640','--height','400','--seconds','45'],stdout=f,stderr=subprocess.STDOUT)
try:
    time.sleep(2)
    text = (out/'source.log').read_text()
    match = re.search(r'windowNumber=(\d+)',text)
    if not match: raise RuntimeError('动态测试窗口未创建：'+text)
    with (out/'app.log').open('w') as f:
        app = subprocess.Popen([str(root/'窗口插帧助手.app/Contents/MacOS/WindowInterp'),'--window-id',match[1],'--autostart','--test-window','--test-x','720','--test-y','60','--test-w','640','--test-h','400','--test-seconds','18','--test-pause','5','--multiplier','2','--no-auto-multiplier','--resolution','400'],stdout=f,stderr=subprocess.STDOUT)
        try: app.wait(timeout=30)
        finally:
            if app.poll() is None: app.terminate(); app.wait(timeout=5)
    text=(out/'app.log').read_text()
    for line in text.splitlines():
        if any(k in line for k in ['TEST_DONE','start: ok','capture:','fatal:','failed','pause','resume','Frame generation stats']): print(line)
    print('APP_EXIT',app.returncode)
    if 'TARGET_NOT_FOUND' in text or 'TEST_DONE' not in text:
        raise SystemExit('验证未通过：未实际进入采集；检查屏幕录制权限及目标窗口。')
finally:
    if source.poll() is None: source.terminate(); source.wait(timeout=5)
