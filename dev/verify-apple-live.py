#!/usr/bin/env python3
"""Verify native Apple 2x/4x generation and controller lifecycle using an animated source."""
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
APP = Path(os.environ.get('WI_APP_PATH', str(ROOT / '窗口插帧助手.app')))
MULTIPLIER = int(os.environ.get('WI_TEST_MULTIPLIER', '2'))
TARGET_FPS = int(os.environ.get('WI_TEST_TARGET_FPS', '60'))
OUT = ROOT / f'dev/native-verification/live-{MULTIPLIER}x-{TARGET_FPS}'
OUT.mkdir(parents=True, exist_ok=True)

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
    controller = None
    command_pipe = None
    ipc = tempfile.TemporaryDirectory(prefix='ipc-', dir=OUT)
    try:
        with (OUT/'source.log').open('w') as stream:
            source = subprocess.Popen([str(ROOT/'dev/testpattern'), '--width', os.environ.get('WI_TEST_WIDTH', '640'), '--height', os.environ.get('WI_TEST_HEIGHT', '400'),
                                       '--x', '40', '--y', '60'], stdout=stream, stderr=stream)
        time.sleep(1)
        match = re.search(r'windowNumber=(\d+)', (OUT/'source.log').read_text())
        assert match, 'test source failed to create a window'
        # LaunchServices uses the App's own screen-recording grant, like a Finder launch.
        # Directly spawning its executable inherits the terminal/agent's TCC identity.
        fifo = Path(ipc.name) / 'commands'
        os.mkfifo(fifo)
        output = OUT / 'controller.log'
        output.write_text('')
        pipe_fd = os.open(fifo, os.O_RDWR)
        command_pipe = os.fdopen(pipe_fd, 'w', buffering=1)
        app = subprocess.Popen(['open', '-n', '-W', '--stdin', str(fifo), '--stdout', str(output),
                                '--stderr', str(output), str(APP), '--args',
                                '--window-id', match[1], '--autostart', '--test-window',
                                '--test-x', '740', '--test-y', '60', '--test-w', '640', '--test-h', '400',
                                '--multiplier', str(MULTIPLIER), '--target-fps', str(TARGET_FPS), '--backend', 'apple', '--quality', '--control-stdin'],
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        def read():
            nonlocal controller
            with output.open() as stream:
                while True:
                    line = stream.readline()
                    if not line:
                        if app.poll() is not None: return
                        time.sleep(0.02)
                        continue
                    if line.startswith('WI_EVENT '):
                        event = json.loads(line[9:])
                        event['time'] = time.monotonic()
                        history.append(event)
                        if event.get('event') == 'controller': controller = event['controller']
                        log.write(json.dumps(event, ensure_ascii=False)+'\n'); log.flush()
                        if 'worker' in event: workers.add(event['worker'])
                        events.put(event)
        reader = threading.Thread(target=read, daemon=True)
        reader.start()
        def send(command, **values):
            assert app.poll() is None, 'controller unexpectedly exited'
            command_pipe.write(json.dumps(dict(command=command, **values))+'\n'); command_pipe.flush()
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
            nonlocal controller
            e = wait(lambda e: e.get('event') == 'applied' and e['multiplier'] == multiplier and e['performance'] == performance)
            if controller is None: controller = e['controller']
            assert e['controller'] == controller
            assert alive(e['worker'])
            return e['worker']
        worker = applied(MULTIPLIER, False)
        measured = wait(lambda e: e.get('event') == 'stats' and e.get('backend') == 'apple'
                        and e.get('generated', 0) > 60 and e['outputFPS'] > TARGET_FPS * 0.85, timeout=40)
        assert measured['sourceFPS'] > min(60, TARGET_FPS/MULTIPLIER) * 0.85, measured
        stable = [wait(lambda e: e.get('event') == 'stats' and e.get('generated', 0) > measured['generated']) for _ in range(8)]
        rates = sorted(e['outputFPS'] for e in stable)
        assert rates[len(rates)//2] > TARGET_FPS * 0.90, stable
        assert stable[-1]['presentationStalls'] - stable[0]['presentationStalls'] < max(20, TARGET_FPS // 2), stable
        (OUT/'cadence.json').write_text(json.dumps(stable, ensure_ascii=False, indent=2))
        print('PASS actual drawable cadence: median', rates[len(rates)//2], 'fps; stalls delta',
              stable[-1]['presentationStalls'] - stable[0]['presentationStalls'], flush=True)
        print('PASS native actual midpoint generation:', measured, flush=True)
        # Verify no LSFG library is loaded in the native worker.
        maps = subprocess.run(['vmmap', str(worker)], capture_output=True, text=True)
        assert maps.returncode == 0, maps.stderr
        assert 'liblsfg_' not in maps.stdout and 'libMoltenVK' not in maps.stdout
        print('PASS native worker has no LSFG/MoltenVK injection', flush=True)
        before = measured['frames']
        applied_count = sum(e.get('event') == 'applied' for e in history)
        send('quality', mode='cas', sharpness=0.4)
        wait(lambda e: e.get('event') == 'stats' and e['frames'] > before+60 and e.get('generated', 0) > 80)
        assert sum(e.get('event') == 'applied' for e in history) == applied_count
        print('PASS live CAS update without worker restart', flush=True)
        send('pause', value=True)
        paused = wait(lambda e: e.get('event') == 'stats' and e['paused'])
        again = wait(lambda e: e.get('event') == 'stats' and e['paused'])
        assert again['frames'] == paused['frames'] and again['generated'] == paused['generated']
        send('pause', value=False)
        wait(lambda e: e.get('event') == 'stats' and not e['paused'] and e.get('generated', 0) > 30)
        print('PASS pause/resume cancels scheduled output and rebuilds temporal history', flush=True)
        send('pause', value=True)
        wait(lambda e: e.get('event') == 'stats' and e['paused'])
        send('pause', value=False); send('pause', value=True)
        wait(lambda e: e.get('event') == 'stats' and e['paused'])
        paused = wait(lambda e: e.get('event') == 'stats' and e['paused'])
        again = wait(lambda e: e.get('event') == 'stats' and e['paused'])
        assert paused['frames'] == again['frames'], 'cancelled resume kept presenting'
        send('pause', value=False)
        wait(lambda e: e.get('event') == 'stats' and not e['paused'] and e.get('generated', 0) > 30)
        print('PASS rapid resume/pause honors final requested state', flush=True)
        send('mode', value=1)
        display = wait(lambda e: e.get('event') == 'applied' and e['mode'] == 1)
        worker = display['worker']
        wait(lambda e: e.get('event') == 'stats' and e.get('generated', 0) > 30)
        send('mode', value=0)
        worker = applied(MULTIPLIER, False)
        wait(lambda e: e.get('event') == 'stats' and e.get('generated', 0) > 30)
        print('PASS display/window capture switch', flush=True)
        if MULTIPLIER == 4:
            send('multiplier', value=2)
            worker = applied(2, False)
            wait(lambda e: e.get('event') == 'stats' and e.get('generated', 0) > 30)
            send('multiplier', value=4)
            worker = applied(4, False)
            wait(lambda e: e.get('event') == 'stats' and e.get('generated', 0) > 60)
            print('PASS native 4× → 2× → 4× switching', flush=True)
        send('stop')
        deadline = time.monotonic()+6
        while time.monotonic() < deadline and any(alive(p) for p in workers): time.sleep(0.1)
        assert not any(alive(p) for p in workers), 'worker leaked after stop'
        send('start'); worker = applied(MULTIPLIER, False)
        send('quit'); app.wait(timeout=8)
        deadline = time.monotonic()+6
        while time.monotonic() < deadline and any(alive(p) for p in workers): time.sleep(0.1)
        assert not any(alive(p) for p in workers), 'worker leaked after quit'
        print('PASS stop/restart/quit clean up all native workers', flush=True)
    finally:
        if controller is not None and alive(controller): os.kill(controller, signal.SIGTERM)
        if app is not None and app.poll() is None:
            app.terminate()
            try: app.wait(timeout=5)
            except subprocess.TimeoutExpired: app.kill(); app.wait()
        if source is not None and source.poll() is None: source.terminate(); source.wait(timeout=5)
        for pid in workers:
            if alive(pid): os.kill(pid, signal.SIGKILL)
        if command_pipe is not None: command_pipe.close()
        if 'reader' in locals(): reader.join(timeout=2)
        ipc.cleanup()
        log.close()
        if saved.returncode == 0:
            with tempfile.NamedTemporaryFile(suffix='.plist') as f:
                f.write(saved.stdout); f.flush()
                subprocess.run(['defaults', 'import', 'local.windowinterp', f.name], check=True, capture_output=True)
        else:
            subprocess.run(['defaults', 'delete', 'local.windowinterp'], capture_output=True)

if __name__ == '__main__': run()
