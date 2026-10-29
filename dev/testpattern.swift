// testpattern.swift — 动态测试源
//
// 目的：给「窗口插帧助手」提供一个**稳定、可复现**的画面源，用来量化功耗/GPU 占用。
// 用真实的浏览器/播放器做基准没法复现（视频内容、码率、帧率每次都不同），所以这里
// 造一个内容确定、帧帧都在变的窗口。
//
// 实现要点：
//   * 动画全部交给 Core Animation（CABasicAnimation），由 WindowServer 合成驱动，
//     本进程 CPU 占用接近 0 —— 测量到的负载能干净地归因给采集/插帧那一侧。
//   * 画面每一帧都在变（三个不同速度/高度的色块横向扫过 + 渐变背景呼吸），
//     否则 ScreenCaptureKit 在内容不变时不会送帧，就测不出真实吞吐。
//   * 窗口默认置顶且不进全屏空间，避免被别的窗口遮挡后系统停止刷新。
//
// 用法：
//   swiftc -O dev/testpattern.swift -o dev/testpattern
//   ./dev/testpattern --width 1710 --height 1069 [--seconds 60] [--fullscreen]

import Cocoa
import CoreText
import AVFoundation

let argv = CommandLine.arguments
func arg(_ key: String) -> String? {
    guard let i = argv.firstIndex(of: key), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}
func hasFlag(_ key: String) -> Bool { argv.contains(key) }

let wantW = Double(arg("--width") ?? "") ?? 1710
let wantH = Double(arg("--height") ?? "") ?? 1069
// 窗口位置（AppKit 坐标：原点在屏幕左下）。给延迟测量用，好把源窗口和
// 插帧输出窗口摆成互不遮挡。
let wantX = Double(arg("--x") ?? "") ?? 0
let wantY = Double(arg("--y") ?? "") ?? 0
let runSeconds = Double(arg("--seconds") ?? "") ?? 0
// --ruler：延迟标尺模式（见下方说明）
let rulerMode = hasFlag("--ruler")
// --static：**完全静止**的画面（只有一层不动的渐变，没有任何动画）。
// 用途：负向验证「源窗口没有帧率」这条路径 —— ScreenCaptureKit 只在内容变化时送帧，
// 所以静止窗口几乎不产生源帧，自动倍率应当判定「量不出源帧率」而保持 2×，
// 而不是硬猜一个倍率。没有这个开关就没法稳定复现该场景（真实静态窗口不好控制）。
let mediaPlayer: AVPlayer? = {
    guard let file = arg("--media-file"), !file.isEmpty else { return nil }
    let player=AVPlayer(url:URL(fileURLWithPath:file)); player.isMuted=true
    return player
}()
let staticMode = hasFlag("--static")
let steppedFPS = Double(arg("--stepped-fps") ?? "") ?? 0
// --soft：模拟「源 App 只按低分辨率渲染、被系统双线性放大到窗口尺寸」那种**糊**
// —— 正是「档 1」（输出重建）要治的东西。
//
// 做法：在**半分辨率**的位图上下文里画细字 / 1px 细线 / 中对比色块，再整张当
// CALayer.contents 用线性放大显示（就是 WindowServer 干的那件事）。
//
// 为什么要专门造这个源：现有的动画图案全是**硬边**（色块、圆角矩形），而 CAS 的设计
// 恰恰是「强边缘处自动不锐化」⇒ 拿硬边图案量 CAS 等于量了个零，会得出「CAS 没用」的
// 错误结论。**模糊的中对比细节**才是这一档的作用区，也才是用户肉眼判断的那个场景
// （「我是看窗口字体分辨的」）。
let softMode = hasFlag("--soft")
/// 扫描条走完一轮的秒数。延迟 = Δ相对位置 × 这个周期。
let rulerPeriod = 2.0

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 不占 Dock、不抢焦点

// --native-fs：把测试源做成**原生全屏**窗口（macOS 会为它新建一个独立 Space）。
// 用途：复现「源窗口在别的 Space」这个场景 —— 浏览器全屏视频就是这样，而
// 独立 Space 既装不下别的 App 的窗口、源窗口又会被 WindowServer 冻结内容。
let nativeFS = hasFlag("--native-fs")
let style: NSWindow.StyleMask = nativeFS ? [.titled, .resizable, .closable] : [.borderless]
let win = NSWindow(contentRect: NSRect(x: wantX, y: wantY, width: wantW, height: wantH),
                   styleMask: style, backing: .buffered, defer: false)
win.isReleasedWhenClosed = false
win.backgroundColor = .black
if nativeFS {
    win.collectionBehavior = [.fullScreenPrimary]
    win.title = "testpattern(全屏源)"
} else {
    // 必须用 normal 层级：采集侧只认 windowLayer == 0 的窗口，真实的全屏视频窗口
    // 也是 0 层；用 .floating 会让它变成 3 层而被过滤掉（踩过）。
    win.level = .normal
    win.collectionBehavior = [.fullScreenAuxiliary, .stationary]
    win.hasShadow = false
    win.ignoresMouseEvents = true        // 别挡住用户操作
}

let root = NSView(frame: NSRect(x: 0, y: 0, width: wantW, height: wantH))
root.wantsLayer = true
win.contentView = root
let host = root.layer!

// —— 延迟标尺模式 ——
// 画面只有三样东西：左边缘一根红色定标、右边缘一根蓝色定标、中间一根白色扫描条
// （匀速平移，周期 rulerPeriod 秒）。
//
// 用途：一次全屏截图里同时拍到「源窗口」和「插帧输出窗口」。只要比较扫描条在两根
// 定标之间的**相对位置**，就能算出两幅画面的时刻差 —— 相对位置天然免疫缩放和黑边
// （插帧输出窗口是 aspect-fit，肯定有黑边），不用去猜窗口摆在哪儿、缩放比是多少。
//
//      延迟秒数 = Δ相对位置 × rulerPeriod
//
// 为什么扫描条不糊：LSFG 生成的是两个源帧之间的**真实插值帧**，位置就是插值位置，
// 不是把两帧叠在一起，所以扫描条依然清晰、位置可精确读取。
if rulerMode {
    host.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
    let markerW: CGFloat = 20

    let leftMark = CALayer()
    leftMark.frame = CGRect(x: 0, y: 0, width: markerW, height: wantH)
    leftMark.backgroundColor = NSColor.systemRed.cgColor
    host.addSublayer(leftMark)

    let rightMark = CALayer()
    rightMark.frame = CGRect(x: wantW - markerW, y: 0, width: markerW, height: wantH)
    rightMark.backgroundColor = NSColor.systemBlue.cgColor
    host.addSublayer(rightMark)

    let scan = CALayer()
    scan.frame = CGRect(x: 0, y: 0, width: 26, height: wantH)
    scan.backgroundColor = NSColor.white.cgColor
    host.addSublayer(scan)

    // 从左定标中心走到右定标中心 ⇒ 相对位置刚好覆盖 [0, 1]
    let scanX = CABasicAnimation(keyPath: "position.x")
    scanX.fromValue = markerW / 2
    scanX.toValue = wantW - markerW / 2
    scanX.duration = rulerPeriod
    scanX.repeatCount = .infinity
    scanX.timingFunction = CAMediaTimingFunction(name: .linear)
    scan.add(scanX, forKey: "scanX")
}

if let player=mediaPlayer {
    let layer=AVPlayerLayer(player:player)
    layer.frame=root.bounds; layer.videoGravity = .resizeAspect
    host.addSublayer(layer)
    let start=Double(arg("--media-start") ?? "") ?? 300
    player.seek(to:CMTime(seconds:start,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero) { _ in player.play() }
} else if staticMode {
    // 静态背景 + 一个固定色块：整幅画面**永远不变**。
    // 不挂任何 CAAnimation ⇒ WindowServer 不会持续重绘 ⇒ SCK 不会送新帧。
    let bg = CAGradientLayer()
    bg.frame = root.bounds
    bg.startPoint = CGPoint(x: 0, y: 0.5)
    bg.endPoint = CGPoint(x: 1, y: 0.5)
    bg.colors = [NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.18, alpha: 1).cgColor,
                 NSColor(calibratedRed: 0.14, green: 0.08, blue: 0.14, alpha: 1).cgColor]
    host.addSublayer(bg)
    let box = CALayer()
    box.frame = CGRect(x: wantW * 0.3, y: wantH * 0.3, width: wantW * 0.4, height: wantH * 0.4)
    box.backgroundColor = NSColor.systemGray.cgColor
    box.cornerRadius = 16
    host.addSublayer(box)
} else if steppedFPS > 0 {
    let background = CAGradientLayer()
    background.frame = root.bounds
    background.colors = [NSColor.darkGray.cgColor, NSColor.black.cgColor]
    host.addSublayer(background)
    let block = CALayer()
    block.frame = CGRect(x:0,y:wantH*0.3,width:wantW*0.12,height:wantH*0.4)
    block.backgroundColor = NSColor.systemOrange.cgColor
    host.addSublayer(block)
    var frame = 0
    Timer.scheduledTimer(withTimeInterval:1/steppedFPS,repeats:true) { _ in
        frame += 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        block.position.x = (Double(frame)*wantW/(steppedFPS*3)).truncatingRemainder(dividingBy:wantW)
        CATransaction.commit()
    }
} else if softMode {
    // —— 低分辨率源（被线性放大 2×）——
    let dw = max(16, Int(wantW / 2)), dh = max(16, Int(wantH / 2))
    guard let ctx = CGContext(data: nil, width: dw, height: dh,
                              bitsPerComponent: 8, bytesPerRow: dw * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        FileHandle.standardError.write("SOFT_PATTERN_FAILED 建不出位图上下文\n".data(using: .utf8)!)
        exit(2)
    }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: dw, height: dh))

    // ① 细字（左上，占约 60%×40%）—— 用户就是拿字体判断清不清楚的，所以这是主判据区
    let family = "Helvetica"
    for (i, text) in ["窗口插帧 Sharpness 0123456789",
                      "abcdefg ABCDEFG 中文小字辨识",
                      "The quick brown fox jumps 12345"].enumerated() {
        let font = CTFontCreateWithName(family as CFString, 9, nil)
        let attrs = [kCTFontAttributeName: font,
                     kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1)] as CFDictionary
        guard let s = CFAttributedStringCreate(nil, text as CFString, attrs) else { continue }
        let line = CTLineCreateWithAttributedString(s)
        ctx.textPosition = CGPoint(x: 6, y: CGFloat(dh - 14 - i * 12))
        CTLineDraw(line, ctx)
    }

    // ② 1px 竖细线（中左）—— 放大后是低对比细纹，CAS 的作用区
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    let lineTop = CGFloat(dh) * 0.42, lineH = CGFloat(dh) * 0.10
    var x = 6
    while x < dw / 2 {
        ctx.fill(CGRect(x: CGFloat(x), y: lineTop, width: 1, height: lineH))
        x += 2
    }

    // ③ 中对比色块（30% 灰底上的 55% 灰块）+ 一个浅渐变 —— 用来看 CAS 会不会压出光晕/色偏
    ctx.setFillColor(CGColor(red: 0.30, green: 0.30, blue: 0.30, alpha: 1))
    ctx.fill(CGRect(x: CGFloat(dw) / 2 + 6, y: lineTop - 4, width: CGFloat(dw) / 4, height: lineH + 8))
    ctx.setFillColor(CGColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1))
    ctx.fill(CGRect(x: CGFloat(dw) / 2 + 6, y: lineTop + lineH * 0.3, width: CGFloat(dw) / 4, height: lineH * 0.5))

    let img = ctx.makeImage()
    let layer = CALayer()
    layer.frame = root.bounds
    layer.contents = img
    layer.magnificationFilter = .linear        // WindowServer 放大低分辨率内容就是这一条
    layer.minificationFilter = .linear
    layer.contentsGravity = .resize
    host.addSublayer(layer)

    // ④ 右下角一个 6×6 闪烁小点：只为让 SCK 持续送帧，**故意远离上面所有判据区**
    let dot = CALayer()
    dot.frame = CGRect(x: wantW - 12, y: 6, width: 6, height: 6)
    dot.backgroundColor = NSColor.systemRed.cgColor
    host.addSublayer(dot)
    let blink = CABasicAnimation(keyPath: "opacity")
    blink.fromValue = 1.0; blink.toValue = 0.0
    blink.duration = 0.4; blink.autoreverses = true; blink.repeatCount = .infinity
    dot.add(blink, forKey: "blink")

    print("SOFT_PATTERN \(dw)x\(dh) → 显示 \(Int(wantW))x\(Int(wantH))（线性放大 2×）")
} else if !rulerMode {

// —— 背景：横向滚动的渐变，保证整幅画面都在变（而不只是几个小色块）——
let bg = CAGradientLayer()
bg.frame = root.bounds
bg.startPoint = CGPoint(x: 0, y: 0.5)
bg.endPoint = CGPoint(x: 1, y: 0.5)
bg.colors = [NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.16, alpha: 1).cgColor,
             NSColor(calibratedRed: 0.16, green: 0.06, blue: 0.12, alpha: 1).cgColor,
             NSColor(calibratedRed: 0.05, green: 0.14, blue: 0.14, alpha: 1).cgColor]
host.addSublayer(bg)
let bgSweep = CABasicAnimation(keyPath: "startPoint.x")
bgSweep.fromValue = -0.4
bgSweep.toValue = 1.4
bgSweep.duration = 3.0
bgSweep.autoreverses = true
bgSweep.repeatCount = .infinity
bgSweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
bg.add(bgSweep, forKey: "sweep")

// —— 前景：不同速度/大小的色块（覆盖全高度，模拟视频里的运动）——
func sweepBlock(_ color: NSColor, w: CGFloat, h: CGFloat, y: CGFloat, duration: Double, round: Bool = true) {
    let l = CALayer()
    l.frame = CGRect(x: -w, y: y, width: w, height: h)
    l.backgroundColor = color.cgColor
    if round { l.cornerRadius = min(w, h) / 2 }
    host.addSublayer(l)
    let a = CABasicAnimation(keyPath: "position.x")
    a.fromValue = -w
    a.toValue = wantW + w
    a.duration = duration
    a.repeatCount = .infinity
    a.timingFunction = CAMediaTimingFunction(name: .linear)
    l.add(a, forKey: "x")
}

sweepBlock(NSColor.systemOrange.withAlphaComponent(0.95), w: 220, h: 220, y: wantH * 0.66, duration: 1.1)
sweepBlock(NSColor.systemTeal.withAlphaComponent(0.9), w: 150, h: 150, y: wantH * 0.44, duration: 0.7)
sweepBlock(NSColor.systemPink.withAlphaComponent(0.85), w: 320, h: 320, y: wantH * 0.10, duration: 1.7)
// 一条细长条反向走，给画面加高频变化
let bar = CALayer()
bar.frame = CGRect(x: 0, y: wantH * 0.35, width: wantW, height: 6)
bar.backgroundColor = NSColor.white.withAlphaComponent(0.55).cgColor
host.addSublayer(bar)
let barX = CABasicAnimation(keyPath: "position.x")
barX.fromValue = wantW + wantW / 2
barX.toValue = -wantW / 2
barX.duration = 0.9
barX.repeatCount = .infinity
bar.add(barX, forKey: "barX")

// —— 角上一个心跳方块：用来肉眼确认画面在动 / 是不是卡住了 ——
let beat = CALayer()
beat.frame = CGRect(x: 24, y: wantH - 96, width: 72, height: 72)
beat.backgroundColor = NSColor.white.cgColor
beat.cornerRadius = 12
host.addSublayer(beat)
let pulse = CABasicAnimation(keyPath: "opacity")
pulse.fromValue = 1.0
pulse.toValue = 0.05
pulse.duration = 0.5
pulse.autoreverses = true
pulse.repeatCount = .infinity
beat.add(pulse, forKey: "pulse")
}   // end of !rulerMode

win.orderFrontRegardless()
// Continuously changing corner UI, outside the interior video sampling tiles.
if hasFlag("--browser-noise") {
    let indicator=CALayer()
    indicator.frame=CGRect(x:wantW-20,y:wantH-20,width:12,height:12)
    indicator.backgroundColor=NSColor.systemTeal.cgColor
    host.addSublayer(indicator)
    let blink=CABasicAnimation(keyPath:"opacity")
    blink.fromValue=0.1;blink.toValue=1.0;blink.duration=0.3
    blink.autoreverses=true;blink.repeatCount = .infinity
    indicator.add(blink,forKey:"browser-noise")
}

if nativeFS {
    // 走一次真正的原生全屏：macOS 会给它建独立 Space（正是我们要复现的场景）
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.toggleFullScreen(nil)
    }
}
print("TESTPATTERN_READY \(Int(wantW))x\(Int(wantH)) windowNumber=\(win.windowNumber)")
if rulerMode { print("RULER_PERIOD \(rulerPeriod)") }

// --move-demo [间隔秒]：让测试源**自己周期性移动/缩放**，用来验证「覆盖层是否实时跟随源窗口」。
//
// 为什么不用合成鼠标拖拽：这个窗口是 `.borderless` 且 `ignoresMouseEvents`，根本没标题栏可拖；
// 而合成拖拽还要辅助功能授权 + 依赖时序。自移动是**确定性、可复现**的，跟 `--static` 一个思路。
let moveDemo = hasFlag("--move-demo") ? (Double(arg("--move-demo") ?? "") ?? 2.0) : 0
if moveDemo > 0 {
    var step = 0
    Timer.scheduledTimer(withTimeInterval: moveDemo, repeats: true) { _ in
        step += 1
        var f = win.frame
        // 每第 4 拍往左回一段 + 缩放一次，其余拍往右下走 —— 移动与缩放两条路径都覆盖
        if step % 4 == 0 {
            f.origin.x -= 80
            f.size.width += 40
            f.size.height += 30
        } else {
            f.origin.x += 30
            f.origin.y -= 14      // AppKit 原点在左下，减 y = 往下走
        }
        win.setFrame(f, display: true)
        // t= 是 epoch 秒（3 位小数）：探针也打同一个时基，才能把「源刚移动」和
        // 「探针读到旧值」严格对齐，而不是靠猜。
        print(String(format: "MOVED step=%d t=%.3f %d,%d %dx%d", step,
                     Date().timeIntervalSince1970,
                     Int(f.origin.x), Int(f.origin.y), Int(f.width), Int(f.height)))
        fflush(stdout)
    }
}
fflush(stdout)

if runSeconds > 0 {
    DispatchQueue.main.asyncAfter(deadline: .now() + runSeconds) { NSApplication.shared.terminate(nil) }
}
app.run()
