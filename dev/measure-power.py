#!/usr/bin/env python3
"""dev/measure-power.py — 整机实时功耗采样

用电池放电电流 × 电池电压估算整机功耗（瓦）。这是不需要 root 就能拿到「瓦特」
的唯一途径（powermetrics 要 root）。

注意：读到的是**整机**功耗（屏幕 + CPU + GPU + 动态壁纸全都在里面），
所以只能做 A/B 差值对比 —— 但差值正好就是我们要归因的那部分。

InstantAmperage 是无符号表示的负数（放电为负），需要转成有符号。
Apple 电池计的更新频率约 1Hz，所以采样间隔取 1s，多采几次取均值。

用法: ./dev/measure-power.py <秒数> [标签]
"""

import re
import subprocess
import sys
import time

IOREG = ["ioreg", "-r", "-c", "AppleSmartBattery", "-d", "1"]


def read_once():
    out = subprocess.run(IOREG, capture_output=True, text=True).stdout
    amp = re.search(r'"InstantAmperage"\s*=\s*(\d+)', out)
    volt = re.search(r'"Voltage"\s*=\s*(\d+)', out)
    ext = re.search(r'"ExternalConnected"\s*=\s*(\w+)', out)
    if not amp or not volt:
        return None
    a = int(amp.group(1))
    if a > 2**63:          # 无符号补码 → 有符号
        a -= 2**64
    v = int(volt.group(1))  # mV
    # mA × mV = µW → /1e6 = W
    return a * v / 1e6, (ext.group(1) == "Yes" if ext else False)


def main():
    dur = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    label = sys.argv[2] if len(sys.argv) > 2 else "未命名"

    vals = []
    on_ac = False
    for _ in range(dur):
        r = read_once()
        if r:
            w, ext = r
            on_ac = ext
            if not ext:        # 接电源时电流不代表整机功耗，跳过
                vals.append(w)
        time.sleep(1)

    if not vals:
        if on_ac:
            print(f"{label:34s} 接了电源，电池电流无法反映整机功耗（请拔掉电源再测）")
        else:
            print(f"{label:34s} 采样失败")
        return

    vals.sort()
    avg = sum(vals) / len(vals)
    med = vals[len(vals) // 2]
    print(f"{label:34s} 整机 {avg:5.2f} W（中位 {med:5.2f} W，最低 {vals[0]:5.2f}，最高 {vals[-1]:5.2f}，n={len(vals)}）")


if __name__ == "__main__":
    main()
