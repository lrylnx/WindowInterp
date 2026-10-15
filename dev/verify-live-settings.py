#!/usr/bin/env python3
"""Exercise the real controller + injected LSFG workers using a deterministic animated source."""
import json
import os
from pathlib import Path
import queue
import re
import signal
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / '窗口插帧助手.app/Contents/MacOS/WindowInterp'
OUT = ROOT / 'dev/verification-live-settings'
OUT.mkdir(exist_ok=True)

def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False

def run():
    saved = subprocess.run(['defaults', 'export', 'local.windowinterp', '-'], capture_output=True)
    app = source = None
    workers = set()
    events = queue.Queue()
    log = (OUT / 'events.jsonl').open('w')
    history = []
    try:
        with (OUT/'source.log').open('w') as stream:
            source = subprocess.Popen([str(ROOT/'dev/testpattern'), '--width', '640', '--height', '400',
                                       '--x', '40', '--y', '60'], stdout=stream, stderr=stream)
        time.sleep(1)
        match = re.search(r'windowNumber=(\d+)', (OUT/'source.log').read_text())
        assert match, 'test source failed to create a window'
        app = subprocess.Popen([str(APP), '--window-id', match[1], '--autostart', '--test-window',
                                '--test-x', '740', '--test-y', '60', '--test-w', '640', '--test-h', '400',
                                '--multiplier', '2', '--quality', '--control-stdin'],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, bufsize=1)
        controller = app.pid
        def read():
            for line in app.stdout:
                if line.startswith('WI_EVENT '):
                    event = json.loads(line[9:])
                    event['time'] = time.monotonic()
                    history.append(event)
                    log.write(json.dumps(event, ensure_ascii=False)+'\n'); log.flush()
                    if 'worker' in event: workers.add(event['worker'])
                    events.put(event)
        threading.Thread(target=read, daemon=True).start()
        def send(command, **values):
            assert app.poll() is None, 'controller unexpectedly exited'
            app.stdin.write(json.dumps(dict(command=command, **values))+'\n'); app.stdin.flush()
        def wait(predicate, timeout=35, allow_error=False):
            deadline = time.monotonic()+timeout
            while time.monotonic() < deadline:
                assert app.poll() is None, f'controller exited: {app.returncode}'
                try: event = events.get(timeout=0.2)
                except queue.Empty: continue
                if event.get('event') == 'error' and not allow_error:
                    raise AssertionError(event)
                if predicate(event): return event
            raise AssertionError('timed out waiting for expected event; '+repr(history[-4:]))
        def applied(multiplier, performance):
            e = wait(lambda e: e.get('event') == 'applied' and e['multiplier'] == multiplier and e['performance'] == performance)
            assert e['controller'] == controller
            assert alive(e['worker'])
            return e['worker']
        worker = applied(2, False)
        wait(lambda e: e.get('event') == 'stats' and e['frames'] > 5 and e['outputFPS'] > 0)
        print('PASS real LSFG generation, controller', controller, flush=True)
        send('multiplier', value=3)
        replacement = applied(3, False)
        assert replacement != worker
        old_worker, worker = worker, replacement
        send('performance', value=True)
        replacement = applied(3, True)
        assert replacement != worker
        worker = replacement
        print('PASS multiplier and performance switch without controller restart', flush=True)
        # Clear telemetry already queued during warm-up.
        while not events.empty(): events.get_nowait()
        before = wait(lambda e: e.get('event') == 'stats')['frames']
        applied_count = sum(e.get('event') == 'applied' for e in history)
        send('quality', mode='cas', sharpness=0.4)
        wait(lambda e: e.get('event') == 'stats' and e['frames'] > before+10)
        assert alive(worker) and alive(controller)
        assert sum(e.get('event') == 'applied' for e in history) == applied_count
        print('PASS live quality update with same engine worker', flush=True)
        send('pause', value=True)
        paused = wait(lambda e: e.get('event') == 'stats' and e['paused'])
        again = wait(lambda e: e.get('event') == 'stats' and e['paused'])
        assert again['frames'] == paused['frames'], 'paused capture kept rendering'
        send('pause', value=False)
        wait(lambda e: e.get('event') == 'stats' and not e['paused'] and e['frames'] > 5)
        print('PASS pause stops work and resumes', flush=True)
        # Rapid writes must coalesce to the latest request.
        send('multiplier', value=2); send('multiplier', value=4); send('multiplier', value=2)
        worker = applied(2, True)
        wait(lambda e: e.get('event') == 'stats' and e['frames'] > 10)
        assert alive(controller)
        print('PASS rapid setting changes settle on last request', flush=True)
        send('mode', value=1)
        display = wait(lambda e: e.get('event') == 'applied' and e['mode'] == 1)
        worker = display['worker']
        wait(lambda e: e.get('event') == 'stats' and e['frames'] > 10)
        send('mode', value=0)
        worker = applied(2, True)
        print('PASS display/window capture settings apply while controller stays open', flush=True)
        # Kill only a warming engine; the working one must survive and settings roll back.
        while not events.empty(): events.get_nowait()
        send('multiplier', value=3)
        warming = wait(lambda e: e.get('event') == 'warming')
        os.kill(warming['worker'], signal.SIGKILL)
        wait(lambda e: e.get('event') == 'error', allow_error=True)
        assert alive(worker), 'failed replacement discarded the working engine'
        wait(lambda e: e.get('event') == 'stats' and e['frames'] > 10)
        print('PASS failed switch retains working engine', flush=True)
        # The extended binary is separate and must also work in the worker architecture.
        send('multiplier', value=12)
        worker = applied(12, True)
        wait(lambda e: e.get('event') == 'stats' and e['frames'] > 10)
        send('multiplier', value=2)
        worker = applied(2, True)
        print('PASS extended 12x engine switches back to standard 2x', flush=True)
        send('stop')
        deadline = time.monotonic()+6
        while time.monotonic() < deadline and any(alive(p) for p in workers): time.sleep(0.1)
        assert not any(alive(p) for p in workers), 'worker leaked after stop'
        assert app.poll() is None, 'stop closed controller'
        send('start'); worker = applied(2, True)
        send('quit'); app.wait(timeout=8)
        deadline = time.monotonic()+6
        while time.monotonic() < deadline and any(alive(p) for p in workers): time.sleep(0.1)
        assert not any(alive(p) for p in workers), 'worker leaked after quit'
        print('PASS stop/restart/quit clean up all workers', flush=True)
    finally:
        if app is not None and app.poll() is None:
            app.terminate()
            try: app.wait(timeout=5)
            except subprocess.TimeoutExpired: app.kill(); app.wait()
        if source is not None and source.poll() is None: source.terminate(); source.wait(timeout=5)
        for pid in workers:
            if alive(pid): os.kill(pid, signal.SIGKILL)
        log.close()
        if saved.returncode == 0:
            with tempfile.NamedTemporaryFile(suffix='.plist') as f:
                f.write(saved.stdout); f.flush()
                subprocess.run(['defaults', 'import', 'local.windowinterp', f.name], check=True, capture_output=True)
        else:
            subprocess.run(['defaults', 'delete', 'local.windowinterp'], capture_output=True)

if __name__ == '__main__': run()
