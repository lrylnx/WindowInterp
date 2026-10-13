// probe-frames.swift — 只做一件事：以固定频率查**一个**窗口的 frame，打印。
//
// 用途：判定「覆盖层偶尔跳到错位置」到底是 CGWindowList 自己会抖，
// 还是我们的换算/逻辑错。同一时刻也查一次 SCShareableContent 做对照。
//
// ⚠️ **本探针第一版自己有测量伪影**（2026-10-12 修正）：
// 第一版是「先调 CG，再 await 昂贵的 SCK，然后直接比」。SCK 的全量枚举
// （`SCShareableContent.excludingDesktopWindows` 会去收集所有 App 的所有窗口）
// 在这台机器上要几十毫秒，比 50ms 的采样间隔还长 ⇒ 变成拿 `CG(t)` 跟
// `SCK(t+Δ)` 比。源窗口这时正在移动，两者当然不等 —— 于是打印出
// 「CG 与 SCK 不一致」，看起来像系统 API 在抖，**其实是我自己取样错位**。
//
// 修法：把 SCK 夹在两次 CG 之间采样，并给 SCK 计时。
//   cg1 = CG()  →  t_enum, sck = SCK()  →  cg2 = CG()
// 判据：
//   · cg1 != cg2  ⇒ 枚举期间源自己动了 ⇒ **这一拍的 CG/SCK 对比无效**（打印 `移动中`）
//   · cg1 == cg2 && sck != cg1 ⇒ 才是真正的不一致（系统 API 有分歧，值得追）
//
// 用法: probe-frames <windowID> <秒数> <频率Hz>
import CoreGraphics
import ScreenCaptureKit
import Foundation

let a = CommandLine.arguments
guard a.count >= 4, let wid = UInt32(a[1]), let secs = Double(a[2]), let hz = Double(a[3]) else {
    fputs("用法: probe-frames <windowID> <秒数> <频率Hz>\n", stderr); exit(2)
}
let t0 = Date()
let n = Int(secs * hz)
print("PROBE wid=\(wid) 采样 \(n) 次 @\(hz)Hz")

func fmt(_ r: CGRect?) -> String {
    guard let r else { return "nil" }
    return "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))"
}
func same(_ a: CGRect?, _ b: CGRect?) -> Bool {
    guard let a, let b else { return false }
    return abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1
        && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
}

@MainActor func cgFrame(_ id: CGWindowID) -> CGRect? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] else { return nil }
    for info in list {
        guard let num = info[kCGWindowNumber as String] as? NSNumber, num.uint32Value == id else { continue }
        guard let d = info[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: d) else { return nil }
        return r
    }
    return nil
}

@MainActor func sckFrame(_ id: CGWindowID) async -> CGRect? {
    guard let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return nil }
    return c.windows.first { $0.windowID == id }?.frame
}

@MainActor func run() async {
    var cg2NilWhileSckNonNil = 0
    var sckNilWhileCgNonNil = 0
    for i in 0..<n {
        let cg1 = cgFrame(CGWindowID(wid))
        // SCK 枚举很贵，只每 2 次取一次对照；并且**夹在两次 CG 之间**，
        // 这样能看出枚举期间源有没有动。
        var sck: CGRect? = nil
        var sckMS = 0.0
        var cg2: CGRect? = nil
        if i % 2 == 0 {
            let e0 = Date()
            sck = await sckFrame(CGWindowID(wid))
            sckMS = Date().timeIntervalSince(e0) * 1000
            cg2 = cgFrame(CGWindowID(wid))
        }
        let moved = cg2 != nil && !same(cg1, cg2)
        var verdict = ""
        if i % 2 == 0 {
            if moved {
                verdict = "  移动中(枚举 \(Int(sckMS))ms) → 本拍对比无效"
            } else {
                if sck == nil && cg1 != nil { verdict = "  ⚠️ SCK 无值而 CG 有"; sckNilWhileCgNonNil += 1 }
                else if sck != nil && cg1 == nil { verdict = "  ⚠️ CG 无值而 SCK 有"; cg2NilWhileSckNonNil += 1 }
                else if sck != nil && !same(cg1, sck) { verdict = "  ❗ 真不一致（两边都有值且不同）" }
            }
        }
        let t = Date().timeIntervalSince(t0)
        print(String(format: "t=%.3f %6.3fs  CG1 %-20@ CG2 %-20@ SCK %-20@%@",
                     Date().timeIntervalSince1970, t,
                     fmt(cg1) as NSString, (cg2 == nil ? "-" : fmt(cg2)) as NSString,
                     (sck == nil ? "-" : fmt(sck)) as NSString, verdict as NSString))
        fflush(stdout)
        try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 / hz))
    }
    print("=== 汇总: SCK无值而CG有=\(sckNilWhileCgNonNil) · CG无值而SCK有=\(cg2NilWhileSckNonNil) ===")
    fflush(stdout)
    exit(0)
}

Task { await run() }
RunLoop.main.run()
