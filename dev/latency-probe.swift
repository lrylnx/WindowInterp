// latency-probe.swift — 端到端插帧延迟测量
//
// 干什么：
//   在一次全屏截图里同时定位「源窗口」和「插帧输出窗口」，各自算出白色扫描条在
//   红/蓝两根定标之间的相对位置，两者的差就换算成时间 —— 这就是从「源画面产生」
//   到「插帧画面显示出来」的端到端延迟。
//
// 为什么这么测（而不是靠感觉）：
//   * 用**相对位置**，所以输出窗口怎么缩放、有没有黑边、窗口摆在哪，全都不影响。
//   * 只统计 x 方向的像素重心（不扫行），所以截图里图像是正立还是倒立也无所谓。
//   * 红/蓝/白三色分离，避开标题栏、HUD 角标、黑边这些噪声。
//
// 用法：
//   screencapture -x -o /tmp/lat-1.png     # 由外壳循环截若干张
//   latency-probe <源窗口ID> <输出窗口ID> <扫描周期秒> <png>...<png>
//
// 判定规则：输出窗内容比源窗「晚」了多少。扫描条从左往右走，所以输出窗里条更靠左
// ⇒ 显示的是更早的画面 ⇒ 延迟 = Δ相对位置 × 周期。

import Foundation
import CoreGraphics
import AppKit

let argv = CommandLine.arguments
// 可选 --display <CGDirectDisplayID>：截图截的是哪块屏（非主屏时窗口全局坐标
// 要先减去那块屏的全局原点，否则两张窗口都找不到）。默认主屏。
var captureBounds = CGDisplayBounds(CGMainDisplayID())
if let di = argv.firstIndex(of: "--display"), di + 1 < argv.count, let did = UInt32(argv[di + 1]) {
    captureBounds = CGDisplayBounds(did)
    print("截屏区域：display \(did) @ \(Int(captureBounds.minX)),\(Int(captureBounds.minY)) \(Int(captureBounds.width))×\(Int(captureBounds.height))")
}
let positional = argv.filter { $0.hasPrefix("/") || ($0.first?.isNumber ?? false) }
let argvUse = positional
guard argvUse.count >= 5,
      let srcID = UInt32(argvUse[1]), let outID = UInt32(argvUse[2]),
      let period = Double(argvUse[3]) else {
    fputs("""
    用法: latency-probe [--display <CGDirectDisplayID>] <源窗口ID> <输出窗口ID> <扫描周期秒> <截图.png> [更多截图...]

    先截好图再调用，例如：
      screencapture -x -o /tmp/lat.png && ./dev/latency-probe 123 456 2.0 /tmp/lat.png
      screencapture -x -o -D 456789 /tmp/lat.png && ./dev/latency-probe --display 456789 123 456 2.0 /tmp/lat.png

    """, stderr)
    exit(2)
}
let pngPaths = Array(argvUse[4...])
guard !pngPaths.isEmpty else {
    fputs("至少给一张截图\n", stderr)
    exit(2)
}

// MARK: 窗口位置

/// 取窗口在屏幕上的矩形（左上原点、全局、单位是「点」）。
func windowBounds(_ id: CGWindowID) -> CGRect? {
    guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] else { return nil }
    for info in list {
        guard let num = info[kCGWindowNumber as String] as? NSNumber, num.uint32Value == id,
              let box = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
        return CGRect(x: box["X"] ?? 0, y: box["Y"] ?? 0,
                      width: box["Width"] ?? 0, height: box["Height"] ?? 0)
    }
    return nil
}

guard let srcRect = windowBounds(srcID), srcRect.width > 10 else {
    fputs("找不到源窗口 \(srcID)（窗口关闭了？或 ID 不对）\n", stderr); exit(3)
}
guard let outRect = windowBounds(outID), outRect.width > 10 else {
    fputs("找不到输出窗口 \(outID)\n", stderr); exit(3)
}

// MARK: 像素解析

struct Raster {
    let w: Int, h: Int
    let px: [UInt8]          // RGBA8
    func at(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * w + x) * 4
        return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
    }
}

func loadPNG(_ path: String) -> Raster? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard ok else { return nil }
    return Raster(w: w, h: h, px: buf)
}

/// 在窗口矩形里分别找红/蓝/白三根竖条的 x 重心。
///
/// 裁剪掉顶部 18% 和底部 4%：
///   * 输出窗口是 .titled，顶部有标题栏文字（白的，会被当成扫描条）；
///   * 右上角有常驻 HUD 角标（也是白的）；
///   * 底部黑边对颜色判定无影响，但裁掉一点更干净。
/// 源窗口是 borderless，裁掉顶部也不会损失定标（定标是贯穿全高的）。
func findBars(_ raster: Raster, rect: CGRect, scale: CGFloat) -> (red: CGFloat, blue: CGFloat, white: CGFloat)? {
    let x0 = max(0, Int(rect.minX * scale)), x1 = min(raster.w - 1, Int((rect.maxX) * scale))
    let top = Int((rect.minY + rect.height * 0.18) * scale)
    let bottom = Int((rect.maxY - rect.height * 0.04) * scale)
    guard x1 > x0 + 4, bottom > top + 4 else { return nil }

    var redSum = 0.0, redN = 0.0
    var blueSum = 0.0, blueN = 0.0
    var whiteSum = 0.0, whiteN = 0.0

    // 纵向抽样（每 4 行取一行）就够 —— 定标是竖直的，重心在 x 上与行无关
    var y = top
    while y < bottom {
        for x in x0...x1 {
            let (r, g, b) = raster.at(x, y)
            if r > 110, r - g > 60, r - b > 60 {
                redSum += Double(x); redN += 1
            } else if b > 110, b - r > 60, b - g > 40 {
                blueSum += Double(x); blueN += 1
            } else if r > 165, g > 165, b > 165, abs(r - g) < 40, abs(g - b) < 40 {
                whiteSum += Double(x); whiteN += 1
            }
        }
        y += 4
    }
    guard redN > 20, blueN > 20, whiteN > 20 else { return nil }
    return (CGFloat(redSum / redN), CGFloat(blueSum / blueN), CGFloat(whiteSum / whiteN))
}

/// 扫描条在两根定标之间的相对位置 [0,1]
func relativePosition(_ bars: (red: CGFloat, blue: CGFloat, white: CGFloat)) -> CGFloat? {
    let span = bars.blue - bars.red
    guard span > 20 else { return nil }        // 定标没找全
    return (bars.white - bars.red) / span
}

// MARK: 主流程

/// 全屏截图的像素宽度 ÷ 截屏区域的逻辑宽度 = 截图相对「点」的缩放
var scale: CGFloat = 2
if let first = loadPNG(pngPaths[0]) {
    if captureBounds.width > 10 { scale = CGFloat(first.w) / captureBounds.width }
}

print("源窗口 \(srcID) @ \(Int(srcRect.minX)),\(Int(srcRect.minY)) \(Int(srcRect.width))×\(Int(srcRect.height))")
print("输出窗口 \(outID) @ \(Int(outRect.minX)),\(Int(outRect.minY)) \(Int(outRect.width))×\(Int(outRect.height))")
print("截图缩放 ×\(String(format: "%.2f", scale)) · 扫描周期 \(period)s → 相对位置差 0.01 相当于 \(Int(period * 10))ms")
print("")

var samples: [Double] = []
// 窗口矩形是全局坐标；截图原点在 captureBounds 左上 —— 先平移到截图坐标系
let srcLocal = srcRect.offsetBy(dx: -captureBounds.minX, dy: -captureBounds.minY)
let outLocal = outRect.offsetBy(dx: -captureBounds.minX, dy: -captureBounds.minY)
for path in pngPaths {
    guard let raster = loadPNG(path) else { print("\(path): 读不了"); continue }
    guard let sb = findBars(raster, rect: srcLocal, scale: scale),
          let ob = findBars(raster, rect: outLocal, scale: scale),
          let rs = relativePosition(sb), let ro = relativePosition(ob) else {
        print("\((path as NSString).lastPathComponent): 找不到三根定标（窗口被遮挡？或画面还没起来）")
        continue
    }
    var dr = rs - ro
    if dr > 0.5 { dr -= 1 } else if dr < -0.5 { dr += 1 }
    let ms = Double(dr) * period * 1000
    samples.append(ms)
    print(String(format: "%@: 源 %.3f · 插帧 %.3f · Δ %.3f → %.0f ms",
                 (path as NSString).lastPathComponent, Double(rs), Double(ro), Double(dr), ms))
}

guard !samples.isEmpty else {
    print("\n没有任何有效样本")
    exit(4)
}
let sorted = samples.sorted()
let median = sorted[sorted.count / 2]
let mean = samples.reduce(0, +) / Double(samples.count)
print("")
print(String(format: "样本 %d · 中位数 %.0f ms · 均值 %.0f ms · 范围 %.0f–%.0f ms",
             samples.count, median, mean, sorted.first!, sorted.last!))
