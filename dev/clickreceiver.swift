// clickreceiver.swift — 输入穿透验证：一个会把每次 mouseDown 打到 stdout 的窗口
//
// 用法: clickreceiver [--x 300] [--y 400] [--width 600] [--height 400]
// 输出: CLICKRECEIVER_READY windowNumber=... frame=...
//       CLICK local=x,y clicks=n   ← 每被点到一次就打一行（这就是判据）
import Cocoa

let argv = CommandLine.arguments
func arg(_ k: String) -> String? {
    guard let i = argv.firstIndex(of: k), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}
let x = Double(arg("--x") ?? "") ?? 300
let y = Double(arg("--y") ?? "") ?? 400
let w = Double(arg("--width") ?? "") ?? 600
let h = Double(arg("--height") ?? "") ?? 400

let app = NSApplication.shared
app.setActivationPolicy(.regular)   // 要能当前台窗口，才能验证「点击到底给了谁」

final class ClickView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        print("CLICK local=\(Int(event.locationInWindow.x)),\(Int(event.locationInWindow.y)) clicks=\(event.clickCount)")
        fflush(stdout)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.15, alpha: 1).setFill()
        bounds.fill()
    }
}

let win = NSWindow(contentRect: NSRect(x: x, y: y, width: w, height: h),
                   styleMask: [.titled], backing: .buffered, defer: false)
win.title = "clickreceiver"
let v = ClickView(frame: NSRect(x: 0, y: 0, width: w, height: h))
win.contentView = v
win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
print("CLICKRECEIVER_READY windowNumber=\(win.windowNumber) frame=\(win.frame)")
fflush(stdout)
app.run()
