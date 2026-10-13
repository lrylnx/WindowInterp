// dev/list-modes.swift — 列出显示器所有显示模式（点尺寸 / 渲染像素尺寸 / 刷新率）
// 用来搞清楚「逻辑尺寸、渲染分辨率、面板物理分辨率」三者的关系。
import AppKit
import CoreGraphics
import Foundation

let id = CGMainDisplayID()
print("main display id = \(id)")
if let cur = CGDisplayCopyDisplayMode(id) {
    print("current: points=\(cur.width)x\(cur.height)  pixels=\(cur.pixelWidth)x\(cur.pixelHeight)  hz=\(cur.refreshRate)")
}
if let all = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] {
    print("all modes: \(all.count)")
    for m in all.sorted(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }) {
        let mark = (m.pixelWidth == CGDisplayCopyDisplayMode(id)?.pixelWidth
                    && m.width == CGDisplayCopyDisplayMode(id)?.width) ? "  <== 当前" : ""
        print("  points=\(m.width)x\(m.height)  pixels=\(m.pixelWidth)x\(m.pixelHeight)  hz=\(m.refreshRate)\(mark)")
    }
}
print("NSScreen.main: \(NSScreen.main?.frame ?? .zero)  backingScaleFactor=\(NSScreen.main?.backingScaleFactor ?? 0)")
