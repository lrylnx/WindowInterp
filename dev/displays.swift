// displays.swift — 列出在线显示器（CGDirectDisplayID / 全局 bounds / 刷新率）
import CoreGraphics

var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var count: UInt32 = 0
CGGetOnlineDisplayList(16, &ids, &count)
for id in ids.prefix(Int(count)) {
    let b = CGDisplayBounds(id)
    let m = CGDisplayCopyDisplayMode(id)
    print("id=\(id) main=\(CGDisplayIsMain(id)) builtin=\(CGDisplayIsBuiltin(id)) "
          + "x=\(Int(b.minX)) y=\(Int(b.minY)) w=\(Int(b.width)) h=\(Int(b.height)) "
          + "hz=\(Int(m?.refreshRate ?? 0))")
}
