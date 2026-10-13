// 合成 ⌃⌥+按键 的 HID 事件，用来验证系统级热键（⌃⌥S/P/Q）真的能被收到。
// 用法: keytest s|p|q
// 注意：往 HID 层投事件需要本进程被辅助功能信任；没被信任时事件不会被派发。
import CoreGraphics
import Foundation

let keyCodes: [String: CGKeyCode] = ["s": 1, "p": 35, "q": 12]
let argv = CommandLine.arguments
guard argv.count >= 2, let vk = keyCodes[argv[1].lowercased()] else {
    fputs("用法: keytest s|p|q\n", stderr); exit(2)
}
let src = CGEventSource(stateID: .hidSystemState)
let flags = CGEventFlags.maskControl.union(.maskAlternate)

// 修饰键（L-Ctrl=0x3B, L-Opt=0x3A）先按下，再字母键，最后全部抬起
let ctrlDown = CGEvent(keyboardEventSource: src, virtualKey: 0x3B, keyDown: true)!
let optDown = CGEvent(keyboardEventSource: src, virtualKey: 0x3A, keyDown: true)!
let keyDown = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: true)!
let keyUp = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: false)!
let ctrlUp = CGEvent(keyboardEventSource: src, virtualKey: 0x3B, keyDown: false)!
let optUp = CGEvent(keyboardEventSource: src, virtualKey: 0x3A, keyDown: false)!

ctrlDown.flags = flags
optDown.flags = flags
keyDown.flags = flags
keyUp.flags = flags
for e in [ctrlDown, optDown] { e.post(tap: .cghidEventTap) }
usleep(40_000)
keyDown.post(tap: .cghidEventTap)
usleep(60_000)
keyUp.post(tap: .cghidEventTap)
usleep(40_000)
for e in [ctrlUp, optUp] { e.post(tap: .cghidEventTap) }
print("KEYTEST sent ⌃⌥\(argv[1].uppercased())")
