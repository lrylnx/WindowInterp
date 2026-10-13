// clicktest.swift — 合成一次真实的鼠标左键点击（发到 HID 系统层）
//
// 用法: clicktest <CG全局x> <CG全局y>
// 坐标系：CG 全局坐标（主屏左上为原点，y 向下）——和 CGWindowList 的窗口矩形同一套。
// 注意：往 HID 层投事件需要本进程被辅助功能信任；没被信任时事件不会被派发。
import CoreGraphics
import Foundation

let a = CommandLine.arguments
guard a.count >= 3, let x = Double(a[1]), let y = Double(a[2]) else {
    fputs("用法: clicktest <CG全局x> <CG全局y>\n", stderr)
    exit(2)
}
let pt = CGPoint(x: x, y: y)
let src = CGEventSource(stateID: .hidSystemState)
let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left)!
let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left)!
down.post(tap: .cghidEventTap)
usleep(60000)
up.post(tap: .cghidEventTap)
print("POSTED \(x),\(y)")
