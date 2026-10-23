// 窗口插帧助手 — ScreenCaptureKit → Apple VTLowLatencyFrameInterpolation 2× → Metal 覆盖层。
// 控制界面常驻，后台进程管理捕获、插帧与呈现；--backend lsfg 保留旧路径。
// 锐化、角标与 Metal HUD 通过私有管道实时更新。

import AppKit
import ApplicationServices
import ScreenCaptureKit
import Metal
import QuartzCore
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Carbon.HIToolbox   // 系统级全局热键（RegisterEventHotKey）

/// 版本标识 —— 「功能不好使」排查第一步永远是问版本（红线），所以把它打进
/// 启动日志和菜单栏菜单头部，谁都能报出自己跑的是哪一版。
let appVersion = "1.5.2"

// MARK: - 引擎注入（与 LSFG 视频播放器同一套路）

signal(SIGPIPE, SIG_IGN)
setvbuf(stdout, nil, _IONBF, 0)   // 自检时 stdout 走管道，不留缓冲
setvbuf(stderr, nil, _IONBF, 0)

let arguments = CommandLine.arguments
func argument(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}
func hasFlag(_ name: String) -> Bool { arguments.contains(name) }

/// 同一个开关可以出现多次，全部收集（`--engine-env A=1 --engine-env B=2`）。
func arguments(named name: String) -> [String] {
    var out: [String] = []
    for (i, a) in arguments.enumerated() where a == name && i + 1 < arguments.count {
        out.append(arguments[i + 1])
    }
    return out
}

let resources = Bundle.main.resourceURL
    ?? URL(fileURLWithPath: arguments[0]).deletingLastPathComponent().appendingPathComponent("Resources")
let native = resources.appendingPathComponent("Native")
let preferences = UserDefaults.standard
let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WindowInterp")
try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
let engineLog = logs.appendingPathComponent("engine-\(getpid()).log")
let appLogURL = logs.appendingPathComponent("app.log")

// 每个后台引擎都会写一个 engine-<pid>.log，保留最近一周。
// 顺手清掉一周前的旧文件，免得日志目录无限膨胀。
if let old = try? FileManager.default.contentsOfDirectory(at: logs,
                                                         includingPropertiesForKeys: [.contentModificationDateKey]) {
    let cutoff = Date().addingTimeInterval(-7 * 86_400)
    for f in old where f.lastPathComponent.hasPrefix("engine-") && f.pathExtension == "log" {
        if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < cutoff {
            try? FileManager.default.removeItem(at: f)
        }
    }
}

// Native Apple 2× is the default; --backend lsfg retains the previous diagnostic path.
let appleBackend = argument("--backend") != "lsfg"
let supportedMultipliers = appleBackend ? [2] : [2, 3, 4, 5, 6, 8, 10, 12]
let isEngineWorker = hasFlag("--engine-worker")
let usesEngineWorker = !isEngineWorker && !hasFlag("--in-process")
let offMode = hasFlag("--off")
let savedMultiplier = preferences.integer(forKey: "multiplier")
// ⚠️ 这里以前是「解析不了就静默回落偏好」——脚本里把 --multiplier 传成空串/写错时，
// App 会一声不吭地跑成用户偏好里那个倍率（实测踩过：zsh 不 word-split ⇒ `--multiplier ""`
// ⇒ 悄悄跑成 5×，四轮对照全是废数据）。现在只要**显式传了却解析不了**就喊一声。
// （完全没传 --multiplier 才算「按偏好启动」，那种情况是正常用法，不报。）
let rawMultiplier = argument("--multiplier")
if let raw = rawMultiplier, Int(raw) == nil {
    logLine("warn: --multiplier \"\(raw)\" 解析不了 → 回落到偏好 \(supportedMultipliers.contains(savedMultiplier) ? savedMultiplier : 2)×；脚本做 A/B 时这很危险，倍率写错会被静默吞掉")
}
let askedMultiplier = Int(rawMultiplier ?? "") ?? (supportedMultipliers.contains(savedMultiplier) ? savedMultiplier : 2)
let manualMultiplier = supportedMultipliers.contains(askedMultiplier) ? askedMultiplier : 2

var multiplier = offMode ? 1 : manualMultiplier

// —— 引擎级省电开关（都是进程级环境变量，改了必须重启进程）——
//
// LSFG 的算力大头是「光流」：在相邻两帧之间估算每个像素怎么动。计算量大致随
// 分辨率**平方**增长，所以 flow scale（光流的工作分辨率缩放）是仅次于分辨率的
// 省电开关：1.0 = 满分辨率（最贵），0.5 / 0.25 能省掉成倍算力，而视频上肉眼
// 差别很小（文字/细密纹理场景才看得出来）。
//
// 另一个省电开关是 `performance_mode`（= 小黄鸭 LSFG 3.1 的 Performance mode，
// 官方口径「GPU 负载最多减半」）：引擎换一套轻量着色器，画质略有让步。
// 实测本工具 3× 插帧下 GPU 功耗 3.40 W → 0.99 W，**生成帧数一张不少**
// （输出被 vblank 限住，省下的是纯算力）⇒ 笔记本上很值。默认关，界面上可勾。
let flowScale = "1.0"
var performanceMode = !appleBackend && !hasFlag("--quality") && (hasFlag("--performance") || preferences.bool(forKey: "performanceMode"))
// 目标帧率默认 = 屏幕刷新率：生成帧超过这个数屏幕上根本显示不出来，算了也白算。
let targetFPS: Int = {
    if let v = argument("--target-fps"), let n = Int(v), n > 0 { return n }
    let saved = preferences.integer(forKey: "targetFPS")
    if saved > 0 { return saved }
    let hz = CGDisplayCopyDisplayMode(CGMainDisplayID())?.refreshRate ?? 0
    return Int(hz > 1 ? hz.rounded() : 60)
}()

// 注入只发生在引擎进程；控制窗口不会随引擎参数变化而重启。
if !appleBackend && !usesEngineWorker && getenv("WINDOW_INTERP_BOOT") == nil {
    setenv("WINDOW_INTERP_BOOT", "1", 1)
    if !offMode {
        let engine = multiplier > 4 ? "liblsfg_extended.dylib" : "liblsfg_metal.dylib"
        setenv("DYLD_INSERT_LIBRARIES", native.appendingPathComponent(engine).path, 1)
        setenv("LSFGM_ENV", "1", 1)
        setenv("LSFGM_METAL", "1", 1)
        setenv("LSFGM_MULTIPLIER", String(multiplier), 1)
        setenv("LSFGM_DLL_PATH", native.appendingPathComponent("lsfg-vk.dll").path, 1)
        setenv("LSFGM_GENERATOR_MOLTENVK", native.appendingPathComponent("libMoltenVK.dylib").path, 1)
        setenv("LSFGM_STATS", "1", 1)
        setenv("LSFGM_LOG_LEVEL", "info", 1)
        // 光流分辨率缩放：默认 1.0（画质优先）。菜单里可调低换省电。
        setenv("LSFGM_FLOW_SCALE", flowScale, 1)
        if performanceMode { setenv("LSFGM_PERFORMANCE_MODE", "1", 1) }
        // 明确告诉引擎输出上限 = 屏幕刷新率
        setenv("LSFGM_TARGET_FPS", String(targetFPS), 1)
        setenv("LSFGM_LOG_FILE", engineLog.path, 1)
        // 引擎级开关的原样透传（诊断/调优用）：引擎不认识的值它自己会在日志里
        // 报 "Unrecognized ..."，所以这里不做白名单校验 —— 免得把引擎新加的
        // 开关挡在外面。放在最后设置，命令行覆盖代码里的默认值。
        for kv in arguments(named: "--engine-env") {
            let parts = kv.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            setenv(parts[0], parts[1], 1)
        }
    } else {
        unsetenv("DYLD_INSERT_LIBRARIES")
    }
    setenv("LSFGM_FLOW_SCALE", "1.0", 1)
    let argv = arguments.map { strdup($0) } + [nil]
    argv.withUnsafeBufferPointer { _ = execv(arguments[0], $0.baseAddress!) }
    fputs("无法启动: \(String(cString: strerror(errno)))\n", stderr)
    exit(1)
}

/// 只读文件尾部若干字节。
/// 引擎日志随运行一直增长（每 60 个源帧写一条统计），而状态栏每秒都要看最后一行。
/// 整份读进来会随运行时长越来越贵 —— 跑几小时后每秒读几百 KB 纯属浪费。
func tailOfFile(_ url: URL, maxBytes: UInt64 = 64 * 1024) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: size > maxBytes ? size - maxBytes : 0)
    guard let data = try? handle.readToEnd() else { return nil }
    return String(data: data, encoding: .utf8)
}

func logLine(_ text: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp) \(text)\n"
    if let handle = try? FileHandle(forWritingTo: appLogURL) {
        handle.seekToEndOfFile(); handle.write(line.data(using: .utf8)!); try? handle.close()
    } else {
        FileManager.default.createFile(atPath: appLogURL.path, contents: line.data(using: .utf8))
    }
}

// MARK: - 系统级全局热键（Carbon RegisterEventHotKey）

/// ⌃⌥S / ⌃⌥P / ⌃⌥Q 的注册中心。
///
/// ⚠️ 教训（2026-10-12 实测翻车）：上一版用 `NSEvent.addGlobalMonitorForEvents(.keyDown)`
/// 实现全局快捷键 —— **键盘类**全局监听需要「辅助功能」授权，没授权时**静默收不到
/// 任何事件**（不报错、不打日志）。用户按 ⌃⌥S 没反应 → 游戏模式下 HUD 已隐藏、
/// Esc 又归游戏 → 三条退出路径全断，只能盲点菜单栏。
/// Carbon 热键是**系统级注册**，不需要任何权限，游戏全屏 / 焦点在别的 App 时同样触发。
enum SystemHotkeys {
    /// 全局动作表（@convention(c) 回调里不能捕获，只能走全局存储）
    private static var actions: [UInt32: () -> Void] = [:]
    private static var installed = false

    static func register(key: String, action: @escaping () -> Void) {
        let keyCodes: [String: Int] = ["s": 1, "p": 35, "q": 12]
        guard let keyCode = keyCodes[key] else { return }
        installHandlerIfNeeded()
        let id = UInt32(actions.count + 1)
        actions[id] = action
        let hotKeyID = EventHotKeyID(signature: 0x57494E54 /* 'WINT' */, id: id)
        var ref: EventHotKeyRef?
        let rc = RegisterEventHotKey(UInt32(keyCode),
                                     UInt32(controlKey | optionKey),
                                     hotKeyID,
                                     GetApplicationEventTarget(),
                                     0,
                                     &ref)
        logLine(rc == noErr ? "hotkey: ⌃⌥\(key.uppercased()) 已注册（系统级，无需辅助权限）"
                            : "hotkey: ⌃⌥\(key.uppercased()) 注册失败 rc=\(rc)")
    }

    private static func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        let handler: EventHandlerUPP = { _, event, _ in
            var hotKeyID = EventHotKeyID()
            guard GetEventParameter(event,
                                    EventParamName(kEventParamDirectObject),
                                    EventParamType(typeEventHotKeyID),
                                    nil,
                                    MemoryLayout<EventHotKeyID>.size,
                                    nil,
                                    &hotKeyID) == noErr else { return noErr }
            guard let action = SystemHotkeys.actions[hotKeyID.id] else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { action() }
            return noErr   // 已处理：按键不再漏给前台 App（比如游戏里的 ⌃⌥ 绑键）
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        var handlerRef: EventHandlerRef?
        // InstallApplicationEventHandler 是 C 宏，Swift 里直接调底层的 InstallEventHandler
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &spec,
                            UnsafeMutableRawPointer(bitPattern: 0), &handlerRef)
    }
}

// MARK: - 主线程看门狗
// 绝不静默卡死：主线程一旦被卡住就留证（sample 抓栈）并在 30 秒后自行退出。
// （本项目真的踩到过：NSScrollView + NSStackView 约束死循环 ⇒ 主线程永久卡在
//  rebuildList()，进程既不退出也不报错，只能靠外部 kill。）

final class Watchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var beat = 0
    func tick() { lock.lock(); beat &+= 1; lock.unlock() }
    func read() -> Int { lock.lock(); defer { lock.unlock() }; return beat }
}
let watchdog = Watchdog()

func startWatchdog() {
    DispatchQueue(label: "windowinterp.watchdog").async {
        var last = -1
        var stalled = 0
        var reported = false
        while true {
            Thread.sleep(forTimeInterval: 1.0)
            let now = watchdog.read()
            if now == last {
                stalled += 1
                if stalled == 5 && !reported {
                    reported = true
                    let path = logs.appendingPathComponent("stall-\(Int(Date().timeIntervalSince1970)).txt")
                    logLine("watchdog: 主线程卡住 5 秒，正在抓栈 → \(path.lastPathComponent)")
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                    process.arguments = [String(getpid()), "3", "-file", path.path]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try? process.run()
                    process.waitUntilExit()
                    logLine("watchdog: 栈已保存")
                }
                if stalled >= 30 {
                    logLine("watchdog: 主线程卡死 30 秒，强制退出（诊断栈见 stall-*.txt）")
                    fputs("WATCHDOG_STALL 主线程卡死 30 秒，诊断栈已写入 \(logs.path)\n", stderr)
                    exit(3)
                }
            } else {
                if reported { logLine("watchdog: 主线程已恢复") }
                stalled = 0; reported = false; last = now
            }
        }
    }
}

// MARK: - 目标窗口

struct CaptureTarget {
    var windowID: CGWindowID
    var pid: pid_t
    var appName: String
    var title: String
    var frame: CGRect          // CG 坐标（左上原点，全局）
    var onscreen: Bool
    var area: CGFloat
    var looksFullscreen: Bool

    var display: String {
        let t = title.isEmpty ? "(无标题)" : title
        let size = "\(Int(frame.width))×\(Int(frame.height))"
        return "\(appName) — \(t)   [\(size)]\(looksFullscreen ? "  ★全屏" : "")\(onscreen ? "" : "  · 其他空间")"
    }
}

enum CaptureMode: Int { case window = 0, display = 1 }

// MARK: - 采集诊断（黑屏 / 画面卡住的第一手证据）

func frameStatusName(_ raw: Int) -> String {
    guard let s = SCFrameStatus(rawValue: raw) else { return "none(\(raw))" }
    switch s {
    case .complete:  return "complete"
    case .idle:      return "idle"
    case .blank:     return "blank"
    case .suspended: return "suspended"
    case .started:   return "started"
    case .stopped:   return "stopped"
    default:         return "other(\(raw))"
    }
}

/// 源窗口此刻在系统眼里的可见性。
/// `onscreen=false` 或「不在当前 Space」时，源应用会停止为其渲染 ——
/// Chrome 尤其激进（窗口被完全遮挡就 backgrounding renderer），
/// 采集端随后只能拿到黑帧或 .idle 帧。这是我们这个工具最根本的天敌。
func windowVisibility(_ id: CGWindowID) -> String {
    guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
        return "取不到窗口列表"
    }
    for w in list {
        guard let num = w[kCGWindowNumber as String] as? UInt32, num == id else { continue }
        let onscreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
        let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
        let alpha = (w[kCGWindowAlpha as String] as? Double) ?? -1
        let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let bw = Int((bounds["Width"] as? NSNumber)?.doubleValue ?? 0)
        let bh = Int((bounds["Height"] as? NSNumber)?.doubleValue ?? 0)
        return "onscreen=\(onscreen) layer=\(layer) alpha=\(String(format: "%.2f", alpha)) \(bw)x\(bh)"
    }
    return "已不在窗口列表"
}

// MARK: - Space 控制（SkyLight 私有 API）
//
// 为什么必须做这件事：源窗口如果在**别的 Space**（Chrome 按 Ctrl+Cmd+F 全屏就是
// 这样），WindowServer 会冻结它的内容 —— 采集端只剩 `.idle` 帧，用户看到的就是
// 「开头一两秒有画面，之后不动/黑」。系统没有公开 API 能把「某个窗口所在的 Space」
// 带到前台，只能用 SkyLight 里这几个函数。
//
// 全部走 dlsym 动态查找：找不到（未来系统改符号）就安静降级成「提示用户自己滑过去」，
// 绝不因为私有 API 失效而崩掉主流程。

enum SpacePrivate {
    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    private typealias MainConnFn = @convention(c) () -> Int32
    private typealias GetWindowWorkspaceFn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> Int32
    private typealias GetActiveSpaceFn = @convention(c) (Int32) -> Int32
    private typealias CopyDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias SetCurrentSpaceFn = @convention(c) (Int32, CFString, Int32) -> Int32

    private static func symbol<T>(_ name: String, as: T.Type) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    private static let mainConn = symbol("CGSMainConnectionID", as: MainConnFn.self)
    private static let getWindowWorkspace = symbol("CGSGetWindowWorkspace", as: GetWindowWorkspaceFn.self)
    private static let getActiveSpace = symbol("CGSGetActiveSpace", as: GetActiveSpaceFn.self)
    private static let copyDisplaySpaces = symbol("CGSCopyManagedDisplaySpaces", as: CopyDisplaySpacesFn.self)
    private static let setCurrentSpace = symbol("CGSManagedDisplaySetCurrentSpace", as: SetCurrentSpaceFn.self)

    /// 源窗口所在的 Space id（取不到返回 0）。
    static func workspace(ofWindow wid: CGWindowID) -> Int32 {
        guard let mainConn, let getWindowWorkspace else { return 0 }
        var ws: Int32 = 0
        guard getWindowWorkspace(mainConn(), UInt32(wid), &ws) == 0 else { return 0 }
        return ws
    }

    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?
    private typealias AddWindowsToSpacesFn = @convention(c) (Int32, CFArray, CFArray) -> Int32
    private typealias RemoveWindowsFromSpacesFn = @convention(c) (Int32, CFArray, CFArray) -> Int32
    private typealias SpaceGetTypeFn = @convention(c) (Int32, Int32) -> Int32

    private static let copySpacesForWindows = symbol("CGSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)
    private static let addWindowsToSpaces = symbol("CGSAddWindowsToSpaces", as: AddWindowsToSpacesFn.self)
    private static let removeWindowsFromSpaces = symbol("CGSRemoveWindowsFromSpaces", as: RemoveWindowsFromSpacesFn.self)
    private static let spaceGetType = symbol("CGSSpaceGetType", as: SpaceGetTypeFn.self)

    /// 某个窗口归属的全部 Space id（mask 0x7 = 当前 + 其它 + 全部）。
    /// 比 `CGSGetWindowWorkspace` 可靠：原生全屏窗口在后者里常常返回 0。
    static func spaces(ofWindow wid: CGWindowID) -> [Int32] {
        guard let mainConn, let copySpacesForWindows else { return [] }
        let wins = [NSNumber(value: UInt32(wid))] as CFArray
        guard let arr = copySpacesForWindows(mainConn(), 0x7, wins)?.takeRetainedValue() as? [Any] else {
            return []
        }
        return arr.compactMap { ($0 as? NSNumber)?.int32Value }
    }

    /// 全屏 Space 的类型（0 = 普通桌面，2 = 原生全屏；取不到 -1）。
    static func spaceType(_ space: Int32) -> Int32 {
        guard let mainConn, let spaceGetType else { return -1 }
        return spaceGetType(mainConn(), space)
    }

    private static func numberArray(_ values: [Int], wide: Bool) -> CFArray {
        let nums: [NSNumber] = values.map { wide ? NSNumber(value: Int64($0)) : NSNumber(value: Int32($0)) }
        return nums as CFArray
    }

    /// 把一批窗口**加入**指定 Space（窗口会同时存在于原 Space 与该 Space）。
    /// 这是让我们的覆盖层出现在「另一个 App 的原生全屏 Space」里的唯一可行手段：
    /// collectionBehavior 的 `.canJoinAllSpaces / .fullScreenAuxiliary` 跨 App 无效（实测）。
    ///
    /// CFNumber 的位宽实测有讲究（32 位那版返回过 kCGErrorFailure=1），所以两条都试，
    /// 并且把结果写进日志 —— 以后系统改行为时能一眼看出是哪条路的锅。
    @discardableResult
    static func addWindows(_ wids: [CGWindowID], toSpace space: Int32) -> Int32 {
        guard let mainConn, let addWindowsToSpaces else { return -99 }
        let cid = mainConn()
        let wins = wids.map { Int($0) }
        for wide in [false, true] {
            let rc = addWindowsToSpaces(cid, numberArray(wins, wide: wide), numberArray([Int(space)], wide: wide))
            if rc == 0 { return 0 }
            logLine("space: addWindows 宽=\(wide ? 64 : 32) rc=\(rc) space=\(space) wins=\(wins)")
        }
        return 1
    }

    @discardableResult
    static func removeWindows(_ wids: [CGWindowID], fromSpace space: Int32) -> Int32 {
        guard let mainConn, let removeWindowsFromSpaces else { return -99 }
        let cid = mainConn()
        let wins = wids.map { Int($0) }
        for wide in [false, true] {
            let rc = removeWindowsFromSpaces(cid, numberArray(wins, wide: wide), numberArray([Int(space)], wide: wide))
            if rc == 0 { return 0 }
        }
        return 1
    }

    /// 把「这个窗口所在的 Space」切到前台。已经在那个 Space 直接算成功。
    @discardableResult
    static func revealSpace(ofWindow wid: CGWindowID) -> Bool {
        guard let mainConn, let getActiveSpace, let copyDisplaySpaces, let setCurrentSpace else {
            return false
        }
        let cid = mainConn()
        // ⚠️ 优先用 CGSCopySpacesForWindows：`CGSGetWindowWorkspace` 对**原生全屏**窗口
        // 稳定返回 0（全屏 Space 不是普通 workspace），只靠它的话这条路径永远失败 ——
        // 现象就是「从桌面点开始插帧，Space 不切过去，用户还看着桌面」。
        var targets = spaces(ofWindow: wid).filter { $0 > 0 }
        if targets.isEmpty {
            let ws = workspace(ofWindow: wid)
            if ws > 0 { targets = [ws] }
        }
        guard !targets.isEmpty else { return false }
        if targets.contains(getActiveSpace(cid)) { return true }   // 已经在这个 Space
        guard let displays = copyDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else {
            return false
        }
        for display in displays {
            guard let uuid = display["Display Identifier"] as? String else { continue }
            let spaces = display["Spaces"] as? [[String: Any]] ?? []
            let ids = spaces.compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.int32Value }
            for want in targets where ids.contains(want) {
                let rc = setCurrentSpace(cid, uuid as CFString, want)
                logLine("space: 切换 display=\(uuid) space=\(want) rc=\(rc)")
                if rc == 0 { return true }
            }
        }
        logLine("space: 找不到目标 Space \(targets) 所在显示器（displaySpaces=\(displays.count)）")
        return false
    }
}

// MARK: - 源窗口的辅助功能（AX）小工具
//
// ⚠️ 这里曾经有一整套「把源窗口请出原生全屏」的机制（发 Ctrl+Cmd+F、AX 改 AXFullScreen、
// 再把它铺满屏幕）。**那是错误方向，已删除**：把 Chrome 请出原生全屏 = 地址栏/书签/
// 网页元素全露出来，用户要的是「满屏只剩视频」。正确做法是源窗口一个字不动，
// 把**我们的覆盖层**搬进它所在的 Space（见 openInterpWindow 里的 SpacePrivate）。
//
// 现在这里只剩排查用的小工具（`--ax-probe`）。

enum SourceWindow {
    static func trusted() -> Bool { AXIsProcessTrusted() }

    private static func frame(of w: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let pv = posRef, let sv = sizeRef,
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// Chromium / Safari 系默认**不构建** AX 树（省电），于是 `AXWindows` 会稳定返回
    /// 空数组（实测 Chrome：rc=0 但 windows=0）。必须先声明「有 AX 客户端在用」，
    /// Chrome 才会把窗口暴露出来。这两个属性是它们各自的私有开关，都设一遍。
    @discardableResult
    static func wakeAccessibility(pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        let a = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        let b = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        logLine("ax: 唤醒 pid=\(pid) enhanced=\(a.rawValue) manual=\(b.rawValue)")
        return app
    }

    /// `--ax-probe <pid>`：只打印该进程的 AX 窗口情况，用于排查。
    static func dump(pid: pid_t) {
        let app = wakeAccessibility(pid: pid)
        var value: CFTypeRef?
        let rc = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        let windows = (value as? [AXUIElement]) ?? []
        print("AX_PROBE pid=\(pid) rc=\(rc.rawValue) windows=\(windows.count)")
        for (i, w) in windows.enumerated() {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &title)
            var fs: CFTypeRef?
            AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &fs)
            print("  [\(i)] frame=\(frame(of: w).map { String(describing: $0) } ?? "?") title=\((title as? String) ?? "") fullscreen=\((fs as? Bool).map(String.init) ?? "?")")
        }
    }
}

// MARK: - 画质（后处理档）：目前只有锐化。别再往里加"放大档"，理由见 ReconstructMode

/// 输出链尾用哪套重采样 / 锐化。
///
/// 背景：用户 2026-10-12 问「能不能像小黄鸭那样做 FSR / Anime4K 缩放」，
/// 评估见 `dev/缩放与画质增强-可行性-2026-10-12.md`。结论是整条链**只缺这一环**：
/// 原来 `present()` 的最后一步是「双线性缩放 + 直接写 drawable」，也就是**GPU 驱动的
/// 双线性**——正是小黄鸭的 CAS/FSR 档要替掉的那个东西。
///
/// ⚠️ **这一档不改窗口尺寸、不动输入**：覆盖层仍然精确贴住源窗口、仍然点击穿透。
/// 它只决定「这张画用什么滤镜」。所以不存在「画面放大了但点到别处」那类风险
/// （那是档 3a / 3b 的问题，见报告 §3）。
enum ReconstructMode: String, CaseIterable {
    /// 现状：双线性直通。**默认值**，与 1.1.0 的行为逐像素一致。
    case off
    /// CAS（对比度自适应锐化）。多一张中间纹理 + 一个片元 pass。
    ///
    /// ⚠️ **这里只剩两档，而且别再往回加「Lanczos 重采样」和「MetalFX 空间放大」。**
    ///
    /// 原因：本工具的采集尺寸**恒等于**输出尺寸（= 源矩形 × 屏幕缩放因子，上限是面板物理像素），
    /// 也就是画面**已经是 1:1 原生像素、根本没有放大空间**。而那两档都只在「输出 > 采集」时
    /// 才会被走到 —— 这个前提**永远不成立** ⇒ 它们与「原始画质」**逐像素完全相同**，
    /// 纯粹让 UI 多两个骗人的选项。v1.4.0 发出去后用户实测「完全没区别」才发现
    /// （`dev/开发笔记.md` 第二十三轮，红线 119）。
    ///
    /// 只有 CAS 在 1:1 下也真的会改画面（纯锐化，不需要放大）。
    /// 内部尺寸不匹配时（SCK 回帧与我们请求的差 1px）仍会走一次 Lanczos 做归一化，
    /// 但那是**兜底**、不是用户可选的档。
    case cas

    var title: String {
        switch self {
        case .off: return "关闭（双线性直通）"
        case .cas: return "对比度自适应锐化（CAS）"
        }
    }
    /// 状态栏/日志用的一行说明。
    var shortName: String {
        switch self {
        case .off: return "关"
        case .cas: return "CAS"
        }
    }
    /// 控制窗下拉里显示的名字。
    ///
    /// ⚠️ 下拉项是**从 `allCases` 生成的**（见 `reconstructPopup.addItems`），不是手写的
    /// 字符串数组 —— 否则新增一档时下拉与枚举会**错位**，而 `reconstructionChanged()` 是
    /// 按下标取 `allCases[index]` 的：错位会静默选到**别的档**，界面上看起来"选了却没生效"。
    /// 新增档次只改这个 switch 一处。
    var uiTitle: String {
        switch self {
        case .off: return "原始画质"
        case .cas: return "自适应锐化"
        }
    }
}

/// CAS（AMD Contrast Adaptive Sharpening 的那套「对比度自适应」思路）的**片元 pass**。
///
/// 为什么不用 Core Image 的内置滤镜：`CIUnsharpMask` / `CISharpenLuminance` 是**固定强度**
/// 的高通增强，在强边缘上必然出黑边白边（光晕）；CAS 的要点是**按局部对比度自动把强度压下去**
/// —— 纯色区域几乎不动、低对比（其实就是「被放大糊掉」）的区域才用力。内置滤镜没有这个
/// 自适应项，所以只能自己写。
///
/// 三条实现要点（都是踩过才定的，别随手改）：
///   ① CAS 要读一圈邻居，而**同一张纹理不能既当输入又当输出**（读写冲突）⇒ 必须先把
///      Core Image 的结果画进一张**中间纹理**，再用一次全屏 pass 采样它、写出另一张。
///   ② `CAMetalLayer` 的 drawable 纹理**没有 `.shaderWrite`**（只有 `.shaderRead` +
///      `.renderTarget`）⇒ CAS 只能是**片元**（写 renderTarget），不能是 compute
///      （compute 需要 shaderWrite，会在别处直接失败）。
///   ③ ⚠️ **最后一步写 drawable 的必须是 Core Image，不能是我们这个 pass。**
///      这是 2026-10-12 实测出来的硬约束，看起来莫名其妙但它就是会翻车：
///      「关闭」档的 drawable 由 `context.render(...)` 写；如果 CAS 改成自己写 drawable，
///      **插帧引擎在呈现时的上下翻转就不发生了**（实测：`eng-cas` 与「无引擎直出」逐像素
///      同向，MAE 0.6；而 `eng-off` 是它的垂直翻转，MAE 2.7），于是生产路径上多翻或少翻
///      一次、画面整个倒过来。改回「CI 收尾」之后两者又一致了。
///      判据：`dev/orient-run.sh`（真屏幕截图，不靠推理）。
final class CASPass {
    private let device: MTLDevice
    private var pipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?
    private var bufs: [MTLTexture] = []
    private var bufSize = CGSize.zero

    /// shader 编译失败时就一直是 nil —— 由调用方降级到原始画质。
    private(set) var disabledReason: String?

    var enabled: Bool { pipeline != nil && sampler != nil }

    init(device: MTLDevice) {
        self.device = device
        do {
            let lib = try device.makeLibrary(source: Self.shaderSource, options: MTLCompileOptions())
            guard let vs = lib.makeFunction(name: "cas_vs"), let fs = lib.makeFunction(name: "cas_fs") else {
                disabledReason = "shader 里找不到 cas_vs / cas_fs"
                return
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vs
            desc.fragmentFunction = fs
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm   // 与 metal.pixelFormat 一致
            pipeline = try device.makeRenderPipelineState(descriptor: desc)

            let sd = MTLSamplerDescriptor()
            sd.minFilter = .linear; sd.magFilter = .linear
            sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
            sampler = device.makeSamplerState(descriptor: sd)
            if sampler == nil { disabledReason = "建不出采样器" }
        } catch {
            disabledReason = error.localizedDescription
        }
    }

    /// 两张中间纹理：`src` 给 CI 写、`dst` 给 CAS 写（**都必须能被 CI 采样**，
    /// 因为收尾那一步是 CI 把 dst 拷进 drawable）。按需分配 + 复用 ——
    /// **别每帧分配**（2560×1440×4 字节 ×144fps 会把分配器和显存带宽一起打满）。
    func buffers(width: Int, height: Int) -> (src: MTLTexture, dst: MTLTexture)? {
        if bufs.count == 2, Int(bufSize.width) == width, Int(bufSize.height) == height {
            return (bufs[0], bufs[1])
        }
        var made: [MTLTexture] = []
        for _ in 0..<2 {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: width, height: height, mipmapped: false)
            // renderTarget + shaderWrite 都给上：CI 往它写用哪个通道由 CI 自己挑，
            // 少给一个就可能静默失败（CI 会退回 CPU 路径，慢到看不出原因）。
            d.usage = [.shaderRead, .renderTarget, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { return nil }
            made.append(t)
        }
        bufs = made
        bufSize = CGSize(width: width, height: height)
        return (made[0], made[1])
    }

    /// `src` → CAS → `dst`。必须与 CI 用**同一条 commandBuffer**。
    @discardableResult
    func encode(commandBuffer: MTLCommandBuffer, src: MTLTexture, dst: MTLTexture, sharpness: Float) -> Bool {
        guard let pipeline, let sampler else { return false }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = dst
        rp.colorAttachments[0].loadAction = .dontCare   // 全屏三角形铺满，不需要旧内容
        rp.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { return false }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(src, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        var texel = SIMD2<Float>(1.0 / Float(src.width), 1.0 / Float(src.height))
        var sharp = sharpness
        enc.setFragmentBytes(&texel, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        enc.setFragmentBytes(&sharp, length: MemoryLayout<Float>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        return true
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VSOut { float4 pos [[position]]; float2 uv; };

    // 全屏三角形。
    //
    // ⚠️ uv 的取向**只能靠实测定**（`dev/orient-run.sh` / `dev/cmp-reconstruct.py`），
    // 别按「道理上应该怎样」去推 —— 这里推错过两次，而推错的后果是**整个画面上下颠倒**，
    // 且在某些组合下恰好被别的翻转抵消、看起来还挺正常。
    //
    // 当前取值 `(1.0 - pos.y) * 0.5` 是与「CI 收尾」结构（见 CASPass 的 ③）**配套**的：
    // 结构一改（比如让 CAS 自己写 drawable 而不是让 CI 收尾），这个取向就要重新定。
    // 定它的办法是把「CAS 强度 0」与「关闭」档逐像素比，必须一致（MAE ≈ 0）。
    //
    // 三个顶点故意超出屏幕（-1..3），省掉两个三角形的接缝。
    vertex VSOut cas_vs(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        float2 pos = p[vid];
        VSOut o;
        o.pos = float4(pos, 0.0, 1.0);
        o.uv = float2((pos.x + 1.0) * 0.5, (1.0 - pos.y) * 0.5);
        return o;
    }

    struct FSIn { float4 pos [[position]]; float2 uv; };

    fragment float4 cas_fs(FSIn in [[stage_in]],
                           texture2d<float> src [[texture(0)]],
                           sampler smp [[sampler(0)]],
                           constant float2 &texel [[buffer(0)]],
                           constant float &sharpness [[buffer(1)]]) {
        float3 c = src.sample(smp, in.uv).rgb;
        float2 t = texel;
        // 3x3 八邻域（CAS 用的是「中心 + 一圈」，不是只有十字）
        float3 n  = src.sample(smp, in.uv + float2( 0.0, -t.y)).rgb;
        float3 s  = src.sample(smp, in.uv + float2( 0.0,  t.y)).rgb;
        float3 w  = src.sample(smp, in.uv + float2(-t.x,  0.0)).rgb;
        float3 e  = src.sample(smp, in.uv + float2( t.x,  0.0)).rgb;
        float3 nw = src.sample(smp, in.uv + float2(-t.x, -t.y)).rgb;
        float3 ne = src.sample(smp, in.uv + float2( t.x, -t.y)).rgb;
        float3 sw = src.sample(smp, in.uv + float2(-t.x,  t.y)).rgb;
        float3 se = src.sample(smp, in.uv + float2( t.x,  t.y)).rgb;

        float3 mn = min(min(min(n, s), min(w, e)), min(min(nw, ne), min(sw, se)));
        float3 mx = max(max(max(n, s), max(w, e)), max(max(nw, ne), max(sw, se)));
        mn = min(mn, c);
        mx = max(mx, c);

        // 对比度自适应项：局部已经全黑（mn→0）或全白（mx→1）⇒ 这是强边缘/纯色区域，
        // 在这里用力锐化只会出光晕，于是自动压到 0。这就是 CAS 与「固定强度 unsharp」的分水岭。
        // 中间调（被放大糊掉的那种）amp→1，锐化全开。
        float3 amp = sqrt(saturate(min(mn, 1.0 - mx) / max(mx, 1e-5)));

        float3 avg = (n + s + w + e + nw + ne + sw + se) * (1.0 / 8.0);
        float3 outc = c + amp * sharpness * (c - avg);
        return float4(saturate(outc), 1.0);
    }
    """
}

// MARK: - 采集 + 渲染管线（非 MainActor，所有状态归 renderQueue / frameQueue）

final class CapturePipeline: NSObject, SCStreamOutput, SCStreamDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let context: CIContext
    private let frameQueue = DispatchQueue(label: "windowinterp.capture", qos: .userInteractive)
    private let renderQueue = DispatchQueue(label: "windowinterp.render", qos: .userInteractive)
    private let lock = NSLock()

    private var appleStream: AppleInterpolationStream?
    private var nativeScheduled = 0
    private var nativeEpoch = 0
    private var nativePresentedGenerated = 0
    private var latestGenerated = false
    private var latestDeadline = 0.0
    private var displayedFPS = 0.0
    private var displayedFrames = 0
    private var displayWindowStart = 0.0
    private var lastPresentedTime = 0.0
    private var slowPresentations = 0
    var displayFPS: Double { lock.withLock { CACurrentMediaTime() - lastPresentedTime < 2 ? displayedFPS : 0 } }
    var presentationStalls: Int { lock.withLock { slowPresentations } }
    var appleStats: (generated: Int, replaced: Int, processingMS: Double, size: CGSize, inputFPS: Double)? { appleStream?.stats }
    var presentedGeneratedCount: Int { lock.withLock { nativePresentedGenerated } }
    private var latest: CIImage?
    private var renderScheduled = false
    private var stopped = false
    private var stream: SCStream?

    private var renderedFrames = 0
    private var replacedFrames = 0
    private var measuredFPS: Double = 0
    private var lastFrameTime: Double = 0
    var frameCount: Int { lock.lock(); defer { lock.unlock() }; return renderedFrames }
    var droppedCount: Int { lock.withLock { replacedFrames } + (appleStream?.stats.replaced ?? 0) }
    var feedFPS: Double {
        lock.lock(); defer { lock.unlock() }
        return CACurrentMediaTime() - lastFrameTime < 2 ? measuredFPS : 0
    }
    private var lastLumaSampleTime: Double = 0
    private var fpsWindowStart = CACurrentMediaTime()
    private var fpsWindowFrames = 0

    // MARK: 诊断（「画面只有开头几秒 / 黑屏」这类问题的必备证据）
    // 原实现只认 .complete 帧，其它状态**直接 return**：源窗口被完全遮挡或不在当前
    // Space 时，系统会改发 .idle / .blank，画面就冻在最后一帧，日志上却完全看不出来。
    private let statLock = NSLock()
    private var statusCounts: [String: Int] = [:]
    private var lastLuma: Double = -1
    private var lastPixelFormat = 0
    private var diagTimer: DispatchSourceTimer?
    private var diagTargetWindow: CGWindowID = 0
    private var diagLastFrames = 0

    var onFatal: ((String) -> Void)?

    // 渲染层由主线程在开始前设定一次，之后只读。
    var metal: CAMetalLayer
    /// **期望的输出尺寸**（与采集尺寸一致，单位是像素）。
    /// `present()` 里以 **drawable 纹理的真实尺寸**为准（那是唯一真相），这个值只做记账。
    private let settingsLock = NSLock()
    private var expectedRenderSize: CGSize
    var renderSize: CGSize {
        get { settingsLock.lock(); defer { settingsLock.unlock() }; return expectedRenderSize }
        set { settingsLock.lock(); expectedRenderSize = newValue; settingsLock.unlock() }
    }
    var flipVertical: Bool
    /// 输出重建档 + CAS 强度。**每帧读取** ⇒ 改设置立刻生效，不用重启进程。
    private var reconstructionMode: ReconstructMode = .off
    private var sharpness: Float = 0.5
    var reconstruct: ReconstructMode {
        get { settingsLock.lock(); defer { settingsLock.unlock() }; return reconstructionMode }
        set { settingsLock.lock(); reconstructionMode = newValue; settingsLock.unlock() }
    }
    var sharpenAmount: Float {
        get { settingsLock.lock(); defer { settingsLock.unlock() }; return sharpness }
        set { settingsLock.lock(); sharpness = newValue; settingsLock.unlock() }
    }
    /// CAS 的中间纹理与管线。惰性创建（shader 要现场编译，别在主线程上做）。
    private var casPass: CASPass?
    /// shader 编译失败过一次就不再重试（别每帧撞一次）。
    private var casUnavailable = false
    /// 重采样兜底上次处理过的尺寸组合。**只在它变了时记一次日志** ——
    /// "兜底悄悄在跑"正是最难查的那类问题（红线 119：要看得见分支有没有被走到）。
    private var lastResampleKey = ""
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    // Bound submitted GPU work as well as the CPU mailbox. Drop stale input instead of queueing latency.
    private let inFlight = DispatchSemaphore(value: 2)
    var onFirstFrame: (() -> Void)?
    private var firstFrameSent = false
    @MainActor private var configuredSize = CGSize.zero
    @MainActor private var configuredFPS: Double = 0
    @MainActor private var pendingSizeUpdate: (width: Int, height: Int, fps: Double)?
    @MainActor private var sizeUpdateTask: Task<Void, Never>?
    /// 诊断档：强制走「CI → 中间纹理 → CI → drawable」（跳过 CAS shader）。
    var thruMid = false
    /// SCStream 的缓冲深度：WindowServer 最多替我们压几帧还没被取走的画面。
    /// 它**直接算进端到端延迟**（20fps 时每帧 50ms，3 帧就是 150ms），所以这里
    /// 是延迟与「抗抖动」之间的取舍：数字越小越跟手，越小也越容易丢帧。
    var queueDepth = 3

    init(device: MTLDevice, metal: CAMetalLayer, renderSize: CGSize, flipVertical: Bool) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        // cacheIntermediates: false 避免 CI 在中间结果上占显存（播放器同款设置）
        self.context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        self.metal = metal
        self.expectedRenderSize = renderSize
        self.flipVertical = flipVertical
        super.init()
    }

    @MainActor func start(filter: SCContentFilter, targetWindowID: CGWindowID, width: Int, height: Int, captureFPS: Double) async throws {
        if appleBackend && !offMode {
            guard WIAppleSupported() else { throw AppleFrameInterpolator.error("当前系统或芯片不支持苹果低延迟插帧，需要 macOS 26 或更新系统") }
            let nativeStream = AppleInterpolationStream()
            nativeStream.onOutput = { [weak self] image, deadline, generated in
                self?.scheduleNative(image, deadline: deadline, generated: generated)
            }
            nativeStream.onError = { [weak self] message in self?.onFatal?(message) }
            nativeStream.onTimelineReset = { [weak self] in
                guard let self else { return }
                self.lock.withLock { self.nativeEpoch += 1; self.latest = nil }
            }
            nativeStream.onConfiguration = { [weak self] text in
                guard let self else { return }
                self.lock.withLock { self.nativeEpoch += 1; self.latest = nil }
                logLine(text)
            }
            appleStream = nativeStream
        }
        let config = makeConfiguration(width: width, height: height, captureFPS: captureFPS)
        configuredSize = CGSize(width: width, height: height)
        configuredFPS = captureFPS
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        self.stream = stream
        try await stream.startCapture()
        let cancelled = lock.withLock { stopped }
        if cancelled { try? await stream.stopCapture(); return }
        startDiag(targetWindowID: targetWindowID)
    }

    private func makeConfiguration(width: Int, height: Int, captureFPS: Double) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        // queueDepth 只影响「最多压几帧不处理」，不影响吞吐；原来给 6 等于让
        // WindowServer 替我们多缓冲 5 帧（每帧都是 W×H×4 字节的 IOSurface）。
        // 渲染侧本来就是「只保留最新帧」，缓冲纯属浪费内存带宽。
        config.queueDepth = queueDepth
        config.scalesToFit = false
        config.preservesAspectRatio = true
        config.capturesAudio = false
        config.minimumFrameInterval = CMTime(seconds: 1 / captureFPS, preferredTimescale: 60_000)
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        config.includeChildWindows = false

        return config
    }

    @MainActor func stop() {
        sizeUpdateTask?.cancel(); sizeUpdateTask = nil; pendingSizeUpdate = nil
        lock.lock(); stopped = true; latest = nil; capturedImage = nil; lock.unlock()
        appleStream?.stop()
        diagTimer?.cancel(); diagTimer = nil
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
    }

    @MainActor func updateSize(width: Int, height: Int, captureFPS: Double) {
        guard let stream else { return }
        let size = CGSize(width: width, height: height)
        guard size != configuredSize || captureFPS != configuredFPS || sizeUpdateTask != nil else { return }
        pendingSizeUpdate = (width, height, captureFPS)
        guard sizeUpdateTask == nil else { return }
        sizeUpdateTask = Task { [weak self] in
            guard let self else { return }
            defer { self.sizeUpdateTask = nil }
            while !Task.isCancelled, let update = self.pendingSizeUpdate {
                self.pendingSizeUpdate = nil
                let config = self.makeConfiguration(width: update.width, height: update.height, captureFPS: update.fps)
                do {
                    try await stream.updateConfiguration(config)
                    self.configuredSize = CGSize(width: update.width, height: update.height)
                    self.configuredFPS = update.fps
                } catch { logLine("capture: updateConfiguration failed: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        lock.lock(); let isStopped = stopped; lock.unlock()
        guard !isStopped else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let statusRaw = attachments?.first?[.status] as? Int ?? -1
        let status = SCFrameStatus(rawValue: statusRaw)
        statLock.lock()
        statusCounts[frameStatusName(statusRaw), default: 0] += 1
        statLock.unlock()
        // 只有 .complete 的帧带新画面。其它状态（.idle / .blank / .suspended）意味着
        // 「这一拍系统没有给我们新内容」，保留上一帧即可 —— 但必须记进日志，
        // 否则「画面冻在开头几秒」在日志上和「一切正常」长得一模一样。
        guard status == .complete, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // 诊断只需每秒两次；避免每帧锁定 IOSurface、迫使 CPU 读取 GPU 资源。
        let now = CACurrentMediaTime()
        if hasFlag("--diagnostics"), now - lastLumaSampleTime >= 0.5 {
            lastLumaSampleTime = now
            let luma = sampleLuma(buffer)
            statLock.lock(); lastLuma = luma; statLock.unlock()
        }

        if let appleStream {
            appleStream.submit(buffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            return
        }
        let image = CIImage(cvPixelBuffer: buffer)
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        if latest != nil { replacedFrames += 1 }   // 渲染跟不上时只保留最新帧
        latest = image
        let needSchedule = !renderScheduled
        renderScheduled = true
        lock.unlock()
        if needSchedule { renderQueue.async { [weak self] in self?.drain() } }
    }

    // Bound retained IOSurfaces and reject stale output instead of accumulating delay.
    private func scheduleNative(_ image: CIImage, deadline: Double, generated: Bool) {
        lock.lock()
        guard !stopped, nativeScheduled < 16 else {
            replacedFrames += 1; lock.unlock(); return
        }
        nativeScheduled += 1
        let epoch = nativeEpoch
        lock.unlock()
        renderQueue.asyncAfter(deadline: .now() + max(0, deadline - CACurrentMediaTime() - 0.004)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.nativeScheduled -= 1
            guard !self.stopped, epoch == self.nativeEpoch,
                  CACurrentMediaTime() - deadline < 0.05 else {
                self.replacedFrames += 1; self.lock.unlock(); return
            }
            if self.latest != nil { self.replacedFrames += 1 }
            self.latest = image
            self.latestGenerated = generated
            self.latestDeadline = deadline
            let needsDrain = !self.renderScheduled
            self.renderScheduled = true
            self.lock.unlock()
            if needsDrain { self.drain() }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); let intentionalStop = stopped; lock.unlock()
        guard !intentionalStop else { return }
        onFatal?("捕获流中断：\(error.localizedDescription)")
    }

    // MARK: 渲染

    private func drain() {
        while true {
            let hasFrame = lock.withLock {
                if stopped || latest == nil { renderScheduled = false; return false }
                return true
            }
            guard hasFrame else { return }
            // 等 GPU 的时候仍让采集队列覆盖邮箱。旧实现先取走一帧再等 drawable，
            // 会呈现已经过期的帧；GPU 繁忙时还会丢掉最后一帧且无人重新唤醒。
            // 等待只发生在专用渲染队列，定时检查 stop，不阻塞 UI 或采集。
            guard inFlight.wait(timeout: .now() + 0.05) == .success else { continue }
            autoreleasepool { presentLatest() }
        }
    }

    private var presentCount = 0
    private var capturedImage: CIImage?
    var lastImage: CIImage? { lock.lock(); defer { lock.unlock() }; return capturedImage }
    /// 「期望输出尺寸 ≠ drawable 实际尺寸」的去重键，别每帧刷一行日志。
    private var lastSizeMismatchKey = ""

    private func presentLatest() {
        var submitted = false
        defer { if !submitted { inFlight.signal() } }
        guard !lock.withLock({ stopped }) else { return }
        guard let drawable = metal.nextDrawable(), let command = commandQueue.makeCommandBuffer() else {
            // 不可见图层可能立即返回 nil，避免持续重试占满 CPU。
            Thread.sleep(forTimeInterval: 0.01)
            return
        }
        // nextDrawable 也可能等垂直同步；拿到真正可写的 drawable 后才取最新帧。
        var frameGenerated = false
        var frameDeadline = 0.0
        let frame: CIImage? = lock.withLock {
            guard !stopped else { return nil }
            let image = latest
            frameGenerated = latestGenerated
            frameDeadline = latestDeadline
            latestGenerated = false
            latest = nil
            capturedImage = image
            return image
        }
        guard let image = frame else { return }
        let limiter = inFlight
        // 保持输入 IOSurface 活到 GPU 完成，不能让下一帧覆盖 capturedImage 后过早回收。
        command.addCompletedHandler { [weak self, image] completed in
            withExtendedLifetime(image) {}
            limiter.signal()
            if completed.status == .error {
                guard let self, !self.lock.withLock({ self.stopped }) else { return }
                self.onFatal?("GPU 渲染失败：\(completed.error?.localizedDescription ?? "未知错误")")
            }
        }
        let extent = image.extent
        // 输出尺寸以 **drawable 纹理的真实尺寸**为准（唯一真相）。
        // `renderSize` 只是调用方的期望值；两者不一致说明哪边算错了，下面只记一次日志。
        let W = drawable.texture.width
        let H = drawable.texture.height
        guard W > 1, H > 1 else { return }
        if Int(renderSize.width.rounded()) != W || Int(renderSize.height.rounded()) != H {
            if lastSizeMismatchKey != "\(W)x\(H)" {
                lastSizeMismatchKey = "\(W)x\(H)"
                logLine("reconstruct: ⚠️ 期望输出 \(Int(renderSize.width))x\(Int(renderSize.height)) "
                        + "但 drawable 是 \(W)x\(H)（按 drawable 走）")
            }
        } else {
            lastSizeMismatchKey = ""
        }
        var normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))

        // ① 重采样 —— **兜底路径，不是"画质档"**。
        //    正常情况下采集尺寸**恒等于** drawable 尺寸（画面本来就是 1:1 原生像素），
        //    所以这一段整段跳过；只有 SCK 回帧的尺寸和我们请求的差 ≥1px 时才归一化一次。
        //    ⚠️ 别再把它当"放大档"搬回 UI：那需要「输出 > 采集」这个前提，而本工具
        //    **永远没有**那个前提（见 `ReconstructMode` 的注释 / 红线 119）。
        let mode = reconstruct
        let needResample = abs(normalized.extent.width - CGFloat(W)) > 0.5
            || abs(normalized.extent.height - CGFloat(H)) > 0.5
        if needResample {
            // 这条兜底**不该**在正常运行时触发。真触发了就记一次（按尺寸去重，别刷屏）——
            // 让人能看见它到底有没有被走到（红线 119）。
            let key = "\(Int(normalized.extent.width))x\(Int(normalized.extent.height))->\(W)x\(H)"
            if lastResampleKey != key {
                lastResampleKey = key
                logLine("reconstruct: 采集 \(Int(normalized.extent.width))x\(Int(normalized.extent.height)) "
                        + "≠ drawable \(W)x\(H) → Lanczos 归一化（兜底路径）")
            }
            // 等比缩放（非等比会被拉变形），再居中；空出来的边用黑底合上，
            // 否则未覆盖的纹素会留着上一帧的内容（表现为边缘花屏）。
            let s = min(CGFloat(W) / normalized.extent.width, CGFloat(H) / normalized.extent.height)
            normalized = normalized.applyingFilter("CILanczosScaleTransform",
                                                   parameters: ["inputScale": s, "inputAspectRatio": 1.0])
            let e = normalized.extent
            normalized = normalized.transformed(by: CGAffineTransform(translationX: (CGFloat(W) - e.width) / 2 - e.minX,
                                                                     y: (CGFloat(H) - e.height) / 2 - e.minY))
            let bg = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
            // 最后 crop 一次：Lanczos 的卷积核会把 extent 撑大几像素，不裁掉的话
            // 后面那步「缩放到 W×H」会按一个偏大的 extent 算 ⇒ 画面被轻微缩小。
            normalized = normalized.composited(over: bg).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        }

        // ② Core Image 原点在左下，CAMetalLayer 纹理行序从上往下：在显示边界翻转一次。
        // （与 LSFG 视频播放器同一段代码，播放器已用截图验证过方向）
        let yScale = flipVertical ? -CGFloat(H) / normalized.extent.height : CGFloat(H) / normalized.extent.height
        var transformed = normalized.transformed(by: CGAffineTransform(scaleX: CGFloat(W) / normalized.extent.width, y: yScale))
        if flipVertical {
            transformed = transformed.transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(H)))
        }

        // ③ 写进 drawable。CAS 档要先落到中间纹理 —— 它要读一圈邻居，
        //    而同一张纹理不能既当输入又当输出（理由见 CASPass 的注释）。
        //    ⚠️ 最后一步**必须仍由 Core Image 写 drawable**：让引擎那边的呈现行为
        //    与「关闭」档完全一致（多翻/少翻一次 = 整个画面倒过来，实测踩过）。
        let bounds = CGRect(x: 0, y: 0, width: W, height: H)
        let colorSpace = outputColorSpace
        var casSharp: Float = -1
        if mode == .cas, sharpenAmount > 0, !thruMid, !casUnavailable {
            if casPass == nil { casPass = CASPass(device: device) }
            if let pass = casPass, pass.enabled, pass.buffers(width: W, height: H) != nil {
                casSharp = min(max(sharpenAmount, 0), 1)
            } else {
                casUnavailable = true
                let why = casPass?.disabledReason ?? "拿不到中间纹理"
                logLine("reconstruct: ⚠️ CAS 不可用（\(why)）→ 退回原始画质（不再重试）")
            }
        }
        let wantMid = thruMid || casSharp >= 0
        if wantMid {
            if casPass == nil { casPass = CASPass(device: device) }
        }
        // ③-A 中间纹理路径（CAS / 诊断档 `--reconstruct-thru-mid`）：
        //     「第一跳把方向定好 → 中间一道 GPU pass → 最后一跳读回来直接写 drawable」。
        //     这条约定是 `dev/orient-run.sh` 实测定的，别随手挪。
        if wantMid, let pass = casPass, let bufs = pass.buffers(width: W, height: H) {
            // ① CI 渲染（重采样 + 翻转）→ 中间纹理
            context.render(transformed, to: bufs.src, commandBuffer: command, bounds: bounds, colorSpace: colorSpace)
            // ② CAS（诊断档 `--reconstruct-thru-mid` 会跳过这一步）
            let sharpened = casSharp >= 0 && pass.encode(commandBuffer: command, src: bufs.src, dst: bufs.dst, sharpness: casSharp)
            // ③ CI 把结果拷进 drawable —— **收尾这一步是硬约束**
            let midTex = sharpened ? bufs.dst : bufs.src
            if let outImage = CIImage(mtlTexture: midTex, options: [.colorSpace: colorSpace]) {
                context.render(outImage, to: drawable.texture, commandBuffer: command, bounds: bounds, colorSpace: colorSpace)
            } else {
                context.render(transformed, to: drawable.texture, commandBuffer: command, bounds: bounds, colorSpace: colorSpace)
            }
        } else {
            context.render(transformed, to: drawable.texture, commandBuffer: command, bounds: bounds, colorSpace: colorSpace)
        }
        if appleStream != nil {
            let generated = frameGenerated
            drawable.addPresentedHandler { [weak self] shown in
                self?.recordNativePresentation(shown.presentedTime, generated: generated)
            }
            command.present(drawable, atTime: max(CACurrentMediaTime(), frameDeadline))
        } else {
            command.present(drawable)
        }
        submitted = true
        command.commit()
        if !firstFrameSent {
            firstFrameSent = true
            onFirstFrame?()
        }

        presentCount += 1
        lock.lock()
        renderedFrames += 1
        lastFrameTime = CACurrentMediaTime()
        fpsWindowFrames += 1
        let now = CACurrentMediaTime()
        if now - fpsWindowStart >= 1.0 {
            measuredFPS = Double(fpsWindowFrames) / (now - fpsWindowStart)
            fpsWindowFrames = 0; fpsWindowStart = now
        }
        lock.unlock()
    }

    private func recordNativePresentation(_ time: Double, generated: Bool) {
        guard time > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        if generated { nativePresentedGenerated += 1 }
        if lastPresentedTime > 0, time - lastPresentedTime > 1.5 / Double(targetFPS) { slowPresentations += 1 }
        lastPresentedTime = time
        if displayWindowStart == 0 { displayWindowStart = time }
        displayedFrames += 1
        if time - displayWindowStart >= 1 {
            displayedFPS = Double(displayedFrames) / (time - displayWindowStart)
            displayedFrames = 0; displayWindowStart = time
        }
    }

    // MARK: 诊断

    /// 采样一帧的平均亮度（0-255）。用来把「系统给了黑帧」和「只是没有新帧」分开：
    /// 源窗口被清空时 SCK 会稳定地按采集帧率送**全黑帧**，看起来一切正常。
    private func sampleLuma(_ pixelBuffer: CVPixelBuffer) -> Double {
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        statLock.lock(); lastPixelFormat = Int(fmt); statLock.unlock()
        guard fmt == kCVPixelFormatType_32BGRA || fmt == kCVPixelFormatType_32ARGB else { return -1 }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return -1 }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard w > 0, h > 0 else { return -1 }
        let stepX = max(1, w / 40), stepY = max(1, h / 40)
        var sum = 0.0, n = 0
        var y = 0
        while y < h {
            let row = base.advanced(by: y * rowBytes)
            var x = 0
            while x < w {
                let p = row.advanced(by: x * 4).assumingMemoryBound(to: UInt8.self)
                // BGRA：byte0=B byte1=G byte2=R
                let offset = fmt == kCVPixelFormatType_32ARGB ? 1 : 0
                let b = Double(p[offset == 0 ? 0 : 3]), g = Double(p[offset == 0 ? 1 : 2]), r = Double(p[offset == 0 ? 2 : 1])
                sum += ((0.114 * b) + (0.587 * g) + (0.299 * r))
                n += 1
                x += stepX
            }
            y += stepY
        }
        return n > 0 ? sum / Double(n) : -1
    }

    private func startDiag(targetWindowID: CGWindowID) {
        diagTargetWindow = targetWindowID
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "windowinterp.diag"))
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.emitDiag() }
        timer.resume()
        diagTimer = timer
    }

    private func emitDiag() {
        statLock.lock()
        let counts = statusCounts
        let luma = lastLuma
        let fmt = lastPixelFormat
        statLock.unlock()
        let rendered = frameCount
        let drawn = rendered - diagLastFrames
        diagLastFrames = rendered
        let detail = counts.keys.sorted().map { "\($0)=\(counts[$0]!)" }.joined(separator: " ")
        var line = "capture: 渲染=\(drawn)/s (累计 \(rendered)) dropped=\(droppedCount)"
        line += " luma=\(String(format: "%.1f", luma)) fmt=\(fmt)"
        line += " 帧状态[\(detail)]"
        if diagTargetWindow != 0 { line += " 源窗口[\(windowVisibility(diagTargetWindow))]" }
        logLine(line)
    }
}

// MARK: - 显示视图

final class VideoView: NSView {
    var onKey: ((NSEvent) -> Void)?
    var movieLayer: CAMetalLayer?
    var movieAspect: CGFloat = 16.0 / 9.0
    override var acceptsFirstResponder: Bool { true }
    /// 覆盖层平时不是活跃窗口：必须接受首次点击，否则用户「点一下画面」拿不到键盘。
    /// （贴源覆盖层是点击穿透的，这条只在 `--test-window` 那个普通窗口路径上起作用。）
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
    override func layout() {
        super.layout()
        let w = min(bounds.width, bounds.height * movieAspect)
        let h = w / movieAspect
        CATransaction.begin(); CATransaction.setDisableActions(true)
        movieLayer?.frame = CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
        CATransaction.commit()
    }
    override func keyDown(with event: NSEvent) { onKey?(event) }
}

final class InterpWindow: NSWindow {
    var closingForReal = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 覆盖层里的小按钮。默认 NSButton 不接受「非激活窗口上的第一次点击」，
/// 用户点一下只会把窗口激活、按钮毫无反应 —— 观感就是「什么都点不了」。
/// 覆盖层常年不是活跃窗口（前台留给源窗口），所以必须接受首次点击。
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - 应用

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    lazy var device = MTLCreateSystemDefaultDevice()!

    var statusItem: NSStatusItem!
    var controlWindow: NSWindow!
    var interpWindow: InterpWindow!
    var video: VideoView!
    var metal: CAMetalLayer!
    var pipeline: CapturePipeline?

    // 控制窗控件
    var table: NSTableView!
    var tableScroll: NSScrollView!
    var hintLabel = NSTextField(labelWithString: "")
    var statusLabel = NSTextField(labelWithString: "")
    private var starting = false
    private var startGeneration = 0
    private var pauseTestScheduled = false
    var startButton = NSButton(title: "开始插帧", target: nil, action: nil)
    var multiplierPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    var modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// 「性能模式（轻量着色器）」复选框。菜单栏也要能改它，所以留成属性好同步状态。
    var perfModeCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    // 输出 HUD
    var hud: NSView!
    var hudLabel = NSTextField(labelWithString: "")
    var badge: NSView!
    var badgeLabel = NSTextField(labelWithString: "")
    var hudTimer: Timer?
    var mouseActivityTimer: Timer?
    var lastMousePosition = NSEvent.mouseLocation
    var floatingControlsVisible = true
    var metalHUDEnabled = preferences.bool(forKey: "metalHUDEnabled")
    var metalHUDCheck = NSButton(checkboxWithTitle: "Metal HUD（帧率 / GPU 性能）", target: nil, action: nil)
    var pauseButton: FirstMouseButton!
    var stopButton: FirstMouseButton!

    // 游戏模式 HUD：**独立小悬浮窗**（不跟着覆盖层一起穿透，可点、可见）。
    // 上一版把 HUD 藏掉、退出全押在 ⌃⌥S/P/Q 上 —— 而热键用 NSEvent 键盘全局监听
    // 实现（需辅助权限，未授权时静默失效）⇒ HUD 点不了（穿透）、Esc 归游戏、热键
    // 没反应，三条路全断，只能盲点菜单栏。这面板是修复主体。
    // 用 nonactivatingPanel：点它的按钮不会把本 App 拉成前台，游戏不丢 key。
    var gameHUD: NSPanel?
    var gameHUDLabel = NSTextField(labelWithString: "")
    var gameHUDPause: NSButton?
    var gameHUDStop: NSButton?
    /// 引擎实际输出帧率与源帧率（每秒从引擎日志的 Frame generation stats 估算）。
    /// 角标/游戏 HUD 显示「源 40 → 输出 120」，别再只亮采集帧率让人误以为没插帧。
    var engineOutFPS: Double = 0
    var engineSrcFPS: Double = 0
    /// 引擎每源帧实际生成了几张（Δtotal/Δsource，正常值 = 倍率本身）。
    var engineGenRatio: Double = 0
    var targets: [CaptureTarget] = []
    var selected: CaptureTarget?
    var enumerateInFlight: Task<Void, Never>?
    var permissionRequested = false
    var running = false
    /// 暂停：管线和采集都停掉（画面定格在最后一帧、立刻省电），覆盖层保持显示，
    /// 这样 HUD 上的「继续」按钮还在原地，用户随时能恢复。
    var paused = false
    // Only telemetry acknowledging the latest pause request may update the controller.
    // A warming worker inherits this revision when it takes over.
    var pauseRevision = 0
    var mode: CaptureMode = {
        if let m = argument("--mode"), m == "display" { return .display }
        if let m = argument("--mode"), m == "window" { return .window }
        return CaptureMode(rawValue: UserDefaults.standard.integer(forKey: "mode")) ?? .window
    }()
    // MARK: 输出方式（2026-10-12 第十三轮：只剩这一种，旧的「铺满整屏覆盖层」已删）
    //
    /// 输出覆盖层**精确贴住源窗口**（不是铺满整屏）+ **点击穿透**（ignoresMouseEvents）
    /// + **不激活本 App、不抢 key** —— 键盘/鼠标/光标全部直达源窗口。
    /// 这是「跟手」的正确解法：小黄鸭在 Windows 上就是这么做的 —— 输入路径与画面
    /// 路径分离。光标由系统合成在所有窗口之上，从不经过插帧管线，天然跟手；
    /// 画面（准星/视角）仍会多 1-2 帧延迟，这是插帧的本质代价（小黄鸭同样如此）。
    ///
    /// **它取代了旧的「非游戏模式」**。旧模式是「覆盖层铺满整块屏 + 抢 key」，
    /// 只在「源窗口本来就是整屏」这一种情形下有优势，却带了一堆代价：抢 key 之后
    /// Esc 归我们（源 App 吃不到自己的快捷键）、要跟 Chrome 抢光标显隐、
    /// 还要维护一整套 HUD/右键兜底菜单。贴源窗口在整屏源上也等价（覆盖层同样是整屏），
    /// 所以那个模式被证明是多余的第二条代码路径 —— 已整体删除。
    ///
    /// ⚠️ **仍然必须绕开它的一种场景**（写在表达式里，别删）：
    ///   `--test-window`（自检/延迟测量）：贴源覆盖层会让源窗口和输出窗口完全重叠，
    ///   而延迟测量用相对位置法、要求两者在同一次截图里各占一块地方 ——
    ///   重叠会把延迟恒测成 0（踩过：`源 0.387 · 插帧 0.387`）。
    ///   `dev/lat-round.sh` 与 `dev/engine-probe.sh` 都靠这条路，删了测量能力就没了。
    ///
    /// 控制走全局热键 ⌃⌥S（开始/停止）· ⌃⌥P（暂停/继续）· ⌃⌥Q（退出）+ 菜单栏 + 控制窗。
    ///
    /// 实现上**不再有 `gameMode` 变量**：贴源覆盖层就是唯一的输出方式，相关分支全部
    /// 无条件化了。唯一还存在的判据是 `useOverlay`（见 openInterpWindow）里的
    /// `--test-window` / `--native-fullscreen` 两个开发用逃逸舱。
    let captureFPS = 60.0
    // 插帧工作分辨率上限（像素高度）。0 = 跟随屏幕，不做额外缩放。
    // 和播放器的「720p / 1080p」是同一个思路 —— 引擎的工作量正比于像素数。
    let workResolution = 0
    /// 输出重建档（「档 1」，见 `ReconstructMode`）。
    ///
    /// ⚠️ 解析失败**要喊一声**，别静默回落 —— 这条红线的教训来自 `--multiplier`：
    /// 脚本里写错值被静默吞掉，四轮对照全是废数据。
    var reconstruct: ReconstructMode = {
        ReconstructMode(rawValue: argument("--reconstruct") ?? preferences.string(forKey: "reconstruct") ?? "off") ?? .off
    }()
    var reconstructPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    var sharpnessSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    var sharpnessValue = NSTextField(labelWithString: "50%")
    var engineSession: EngineSession?
    var pendingSession: EngineSession?
    var activeTarget: CaptureTarget?
    var engineSwitchWork: DispatchWorkItem?
    var workerOutputAlpha: CGFloat = 1
    var workerActivated = false
    var workerHasFrame = false
    var workerReportedReady = false
    var pendingTimeout: DispatchWorkItem?
    var settingsError = ""
    var workerOutputWindow = 0
    var remoteFrames = 0
    var remoteDropped = 0
    var remoteFPS: Double = 0
    var appliedMultiplier = multiplier
    var appliedPerformance = performanceMode
    var appliedMode: CaptureMode = .window
    /// CAS 强度 0…1（只有 `.cas` 档用到）。0 = 与关闭档逐像素一致（自检用）。
    var sharpenAmount: Float = {
        if let v = argument("--reconstruct-sharp"), let f = Float(v) { return min(max(f, 0), 1) }
        if UserDefaults.standard.object(forKey: "reconstructSharp") != nil {
            return min(max(UserDefaults.standard.float(forKey: "reconstructSharp"), 0), 1)
        }
        return 0.5
    }()
    /// **诊断档**：强制走「CI 渲染到中间纹理 → CI 再把中间纹理拷回 drawable」这条路
    /// （`reconstruct == .cas` 的结构，但**完全不碰 CAS 那个片元 shader**）。
    ///
    /// 用途：把「中间纹理/多一个 pass 本身会不会改变引擎的呈现行为」与
    /// 「CAS shader 有没有写错」这两件事分开 —— 2026-10-12 排查「CAS 档下画面上下
    /// 颠倒」时加的。结论见 `dev/orient-run.sh` 的注释。
    var reconstructThruMid = hasFlag("--reconstruct-thru-mid")
    // 自动把采集帧率压到「屏幕刷新率 ÷ 倍率」上。
    // 60Hz 屏 + 2× 时源只要能到 30fps 就够，多采的部分引擎生成出来也显示不出来。
    //
    // ⚠️ 实测提醒：这条策略**看着像延迟的元凶，其实不是**。
    // 试过 --no-auto-fps --capture-fps 60（放开采集上限），引擎日志里的 source_fps
    // 依然稳在「屏幕刷新率 ÷ 倍率」——因为引擎要 present 倍率个帧才把控制权还给
    // 我们，采集端天然被限速。实测延迟：2× ≈ 50ms、3× ≈ 185ms、4× ≈ 285ms，
    // 也就是延迟大致随**倍率的立方**增长。详见 README 的「延迟」章节。
    let autoMatchFPS = false
    /// SCStream 缓冲深度（见 CapturePipeline.queueDepth）。命令行可覆盖，便于测延迟。
    /// 实测：给 1 会让 SCK 大面积丢帧（画面一顿一顿，比 3 更糟），所以下限锁 2。
    var captureQueueDepth = max(2, min(4, Int(argument("--queue-depth") ?? "") ?? 3))
    /// 输出层 drawable 池大小。
    /// ⚠️ 实测 `CAMetalLayer.maximumDrawableCount` 只能是 2 或 3 —— 设 4 以上画面
    /// 一帧都出不来（nextDrawable 永远拿不到），所以这里钳在 2…3。
    /// 而 2 与 3 的端到端延迟**没有可测差别**（184ms vs 186ms），瓶颈不在这。
    var drawableCount = max(2, min(3, Int(argument("--drawable-count") ?? "") ?? 3))
    /// 输出层是否等垂直同步再显示。
    /// 实测关掉（--no-display-sync）对延迟**没有任何改善**（186ms vs 184ms），
    /// 只会牺牲画面整齐度，所以固定开启。
    var displaySync = true
    // 诊断用：关掉「面板物理像素」封顶，用来复现旧版本的工作分辨率做对比测量。
    var ignorePixelCap = !hasFlag("--limit-capture-pixels")
    var showBadge = UserDefaults.standard.object(forKey: "showBadge") == nil ? true : UserDefaults.standard.bool(forKey: "showBadge")
    // 输出到 CAMetalLayer 时要不要在显示边界翻转一次 —— 取决于**引擎在不在**。
    //
    // 实测（dev/orient-run.sh，第十五轮）：LSFG 引擎在 `Metal presentation` hook 里
    // 会把 drawable **上下翻一次**。所以：
    //   * 引擎在（默认 / 插帧）  → 我们翻一次去**抵消**它   ⇒ displayFlip = true
    //   * 引擎不在（`--off` 原帧模式）→ 没人翻了，我们一翻就倒 ⇒ displayFlip = false
    // 判据：对同一张确定性源图（--soft：文字在顶、细线在 52%）截屏做行剖面 ——
    //   eng-* 与源 原样 MAE 2.1 / 竖翻 19.3（同向）；off-* 原样 16.7 / 竖翻 1.4（颠倒）。
    // 「引擎在 = 正立」是 1.1.0 之前就成立的行为，`--off` 一直是倒的、长期无人发现。
    //
    // 两条路径都成立 —— 所以它必须在两侧取相反的值。
    var displayFlip: Bool { !appleBackend && !offMode }
    var statTimer: Timer?
    var refreshTimer: Timer?
    /// 正在被插帧的那个窗口 id（用于检测它是否还在当前 Space）。
    var interpTargetID: CGWindowID = 0
    var interpTargetPID: pid_t = 0
    var sourceOffscreen = false
    var spaceFixAttempts = 0
    var runningSince: CFAbsoluteTime = 0
    /// 覆盖层窗口 id + 被搬进过的 Space 列表（停止时要撤掉，免得它赖在视频那个 Space 上）。
    var overlayWindowID: CGWindowID = 0
    var overlaySpaces: [Int32] = []
    /// 当前是否真的在用「贴源覆盖层」输出。
    ///
    /// ⚠️ **跟随逻辑必须看这个标志**：`--test-window` / `--native-fullscreen` 走的是普通窗口，
    /// 输出窗要停在用户指定的位置（延迟测量要求源窗和输出窗各占一块地方）。少了这个判断，
    /// 4Hz 的跟随会把测量窗拖到源窗口上 ⇒ 两窗重合 ⇒ 相对位置法恒测出 `0 ms`
    /// —— 工具不报错、只是静默给出假数据。（第十三轮真的这么犯过一次，被
    /// `IS_FULLSCREEN=… WINDOW=(等于源窗口)` 那行自检输出抓到。）
    var overlayActive = false
    var followTimer: Timer?
    /// 上一拍被判定为「屏外垃圾帧」并拒绝的那个 frame 的键（用于日志去重）。
    var lastOverlayRejectKey = ""
    var lastEngineLine = ""
    var lastEngineSource = 0
    var lastEngineGenerated = 0
    var lastEngineTotal = 0
    var lastEngineStamp = 0.0
    var exitAfter = Double(argument("--test-seconds") ?? "0") ?? 0
    var bootTime = CACurrentMediaTime()

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !isEngineWorker { buildStatusItem(); registerHotkeys() }
        if isEngineWorker || hasFlag("--control-stdin") {
            readWorkerCommands { [weak self] command in
                MainActor.assumeIsolated { self?.receiveWorkerCommand(command) }
            }
        }
        if hasFlag("--control-stdin") { emitWorkerEvent(["event": "controller", "controller": getpid()]) }
        if exitAfter > 0 { emitWorkerEvent(["event": "testProcess", "pid": getpid()]) }
        // 覆盖层的**实时跟随**：4Hz，只查源窗口一个 frame（便宜），
        // 拖动/缩放源窗口时覆盖层立刻贴上去。以前只有 5 秒一次的兜底，
        // 贴源覆盖层一旦通用所有场景，那个延迟就成了硬伤。
        if !usesEngineWorker {
            followTimer = Timer(timeInterval: 0.25, target: self, selector: #selector(followTick), userInfo: nil, repeats: true)
            RunLoop.main.add(followTimer!, forMode: .common)
        }
        statTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { watchdog.tick(); self?.tickStatus() } }
        RunLoop.main.add(statTimer!, forMode: .common)
        // 每 5 秒检查运行中的源窗口；不做窗口列表的后台枚举。
        if !usesEngineWorker {
            refreshTimer = Timer(timeInterval: 5, target: self, selector: #selector(periodicRefresh), userInfo: nil, repeats: true)
            RunLoop.main.add(refreshTimer!, forMode: .common)
        }
        startWatchdog()
        logLine("launch v\(appVersion) pid=\(getpid()) multiplier=\(multiplier) off=\(offMode) args=\(arguments.dropFirst().joined(separator: " "))")

        // 排查用：`--ax-probe <pid>` 打印某进程的 AX 窗口情况
        if let probe = argument("--ax-probe"), let probePid = pid_t(probe) {
            print("ACCESSIBILITY_PERMISSION=\(SourceWindow.trusted())")
            SourceWindow.dump(pid: probePid)
            NSApplication.shared.terminate(nil)
            return
        }
        if hasFlag("--list-windows") {            let granted = CGPreflightScreenCaptureAccess()
            print("SCREEN_RECORDING_PERMISSION=\(granted)")
            print("ACCESSIBILITY_PERMISSION=\(SourceWindow.trusted())")
            guard granted else { print("WINDOWS=-1"); NSApplication.shared.terminate(nil); return }
            Task {
                await performEnumerate()
                for (i, t) in targets.enumerated() { print("[\(i)] id=\(t.windowID) pid=\(t.pid) \(t.display)") }
                print("WINDOWS=\(targets.count)")
                NSApplication.shared.terminate(nil)
            }
            return
        }

        if !isEngineWorker { buildControlWindow(); scheduleControlDump() }

        if let idText = argument("--window-id"), let id = UInt32(idText) {
            Task {
                await refreshTargets()
                if let t = targets.first(where: { $0.windowID == id }) {
                    select(t)
                    if hasFlag("--autostart") { startInterpolation() }
                } else {
                    logLine("start: 找不到 window-id=\(id)")
                    print("TARGET_NOT_FOUND \(id)")
                    if isEngineWorker { emitWorkerEvent(["event": "error", "message": "目标窗口已不存在，请刷新列表"]) }
                    if exitAfter > 0 || isEngineWorker { NSApplication.shared.terminate(nil) }
                }
            }
        } else if !isEngineWorker {
            NSApplication.shared.activate(ignoringOtherApps: true)
            controlWindow.makeKeyAndOrderFront(nil)
        }

        if exitAfter > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + exitAfter) {
                print("TEST_DONE frames=\(self.pipeline?.frameCount ?? self.remoteFrames) dropped=\(self.pipeline?.droppedCount ?? self.remoteDropped) running=\(self.running)")
                print("IS_FULLSCREEN=\(self.interpWindow?.styleMask.contains(.fullScreen) ?? false) WINDOW=\(self.interpWindow?.frame ?? .zero) LAYER=\(self.metal?.frame ?? .zero)")
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: 控制窗

    func buildControlWindow() {
        controlWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 720),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                 backing: .buffered, defer: false)
        controlWindow.title = "窗口插帧助手"
        controlWindow.titlebarAppearsTransparent = true
        controlWindow.minSize = CGSize(width: 600, height: 700)
        controlWindow.delegate = self
        controlWindow.isReleasedWhenClosed = false
        controlWindow.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        controlWindow.center()
        controlWindow.setFrameAutosaveName("control-v2")

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        controlWindow.contentView = root

        func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
                   color: NSColor = .labelColor) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = .systemFont(ofSize: size, weight: weight)
            field.textColor = color
            return field
        }
        func vertical(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = spacing
            return stack
        }
        func card(_ content: NSView) -> NSView {
            let box = NSView()
            box.wantsLayer = true
            box.layer?.cornerRadius = 12
            box.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            box.layer?.borderColor = NSColor.separatorColor.cgColor
            box.layer?.borderWidth = 0.5
            content.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
                content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
                content.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
                content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14)
            ])
            return box
        }

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "bolt.circle.fill", accessibilityDescription: "窗口插帧")
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .medium)
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let titles = vertical([
            label("窗口插帧助手", size: 24, weight: .bold),
            label("选一个窗口，让画面更流畅。", size: 13, color: .secondaryLabelColor)
        ], spacing: 4)
        let header = NSStackView(views: [icon, titles])
        header.spacing = 14
        header.alignment = .centerY

        buildTable()
        let refresh = NSButton(title: "刷新列表", target: self, action: #selector(refreshClicked))
        refresh.bezelStyle = .rounded
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")
        refresh.imagePosition = .imageLeading
        let sourceTitle = label("目标窗口", size: 14, weight: .semibold)
        let spacer = NSView()
        let sourceHeader = NSStackView(views: [sourceTitle, spacer, refresh])
        sourceHeader.alignment = .centerY
        hintLabel = label("正在读取窗口列表…", size: 11, color: .secondaryLabelColor)
        hintLabel.maximumNumberOfLines = 2
        let sources = vertical([sourceHeader, tableScroll, hintLabel], spacing: 10)
        let sourceCard = card(sources)
        for view in [sourceHeader, tableScroll!, hintLabel] {
            view.widthAnchor.constraint(equalTo: sources.widthAnchor).isActive = true
        }
        tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        tableScroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        multiplierPopup.removeAllItems()
        multiplierPopup.addItems(withTitles: supportedMultipliers.map { "\($0)× 插帧" })
        multiplierPopup.selectItem(at: supportedMultipliers.firstIndex(of: multiplier) ?? 0)
        multiplierPopup.target = self
        multiplierPopup.action = #selector(multiplierChanged)
        modePopup.removeAllItems()
        modePopup.addItems(withTitles: ["窗口（推荐）", "整屏"])
        modePopup.selectItem(at: mode.rawValue)
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        for popup in [multiplierPopup, modePopup] { popup.controlSize = .large }
        let multiplierColumn = vertical([label("插帧倍数", size: 11, weight: .medium, color: .secondaryLabelColor), multiplierPopup])
        let modeColumn = vertical([label("抓取方式", size: 11, weight: .medium, color: .secondaryLabelColor), modePopup])
        multiplierPopup.widthAnchor.constraint(equalTo: multiplierColumn.widthAnchor).isActive = true
        modePopup.widthAnchor.constraint(equalTo: modeColumn.widthAnchor).isActive = true
        let options = NSStackView(views: [multiplierColumn, modeColumn])
        options.distribution = .fillEqually
        options.spacing = 20
        let optionsCard = card(options)
        optionsCard.heightAnchor.constraint(equalToConstant: 88).isActive = true

        perfModeCheck = NSButton(checkboxWithTitle: "性能模式", target: self, action: #selector(perfModeChanged(_:)))
        perfModeCheck.state = performanceMode ? .on : .off
        perfModeCheck.toolTip = appleBackend ? "苹果原生 2× 使用独立插帧处理器，此项仅适用于 LSFG。" : "使用轻量着色器降低 GPU 开销；后台切换引擎，控制窗口保持打开。"
        perfModeCheck.isEnabled = !appleBackend
        if appleBackend { perfModeCheck.title = "苹果原生 2×"; perfModeCheck.state = .on }
        let badgeCheck = NSButton(checkboxWithTitle: "显示右上角插帧角标", target: self, action: #selector(badgeChanged))
        badgeCheck.state = showBadge ? .on : .off
        badgeCheck.toolTip = "鼠标静止 3 秒后隐藏，在输出区域移动后恢复。"
        metalHUDCheck.title = "Metal HUD"
        metalHUDCheck.target = self
        metalHUDCheck.action = #selector(toggleMetalHUD)
        metalHUDCheck.state = metalHUDEnabled ? .on : .off
        metalHUDCheck.toolTip = "实时查看帧率、GPU 耗时等性能数据。"
        let switches = NSStackView(views: [perfModeCheck, badgeCheck, metalHUDCheck])
        switches.spacing = 22
        // ⚠️ 从 `allCases` 生成，**不要手写字符串数组** —— 手写数组与枚举一旦错位，
        //    `reconstructionChanged()` 会按下标选到**别的档**，界面上看起来"选了却没生效"。
        reconstructPopup.addItems(withTitles: ReconstructMode.allCases.map(\.uiTitle))
        reconstructPopup.selectItem(at: ReconstructMode.allCases.firstIndex(of: reconstruct) ?? 0)
        reconstructPopup.target = self
        reconstructPopup.action = #selector(reconstructionChanged)
        sharpnessSlider.doubleValue = Double(sharpenAmount)
        sharpnessSlider.target = self
        sharpnessSlider.action = #selector(reconstructionChanged)
        sharpnessSlider.isContinuous = true
        sharpnessSlider.isEnabled = reconstruct == .cas
        sharpnessSlider.toolTip = "锐化强度 0–100%，实时预览；建议从 20–40% 开始，过高可能放大噪点。"
        sharpnessSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        sharpnessValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sharpnessValue.stringValue = "\(Int((sharpenAmount * 100).rounded()))%"
        sharpnessValue.widthAnchor.constraint(equalToConstant: 36).isActive = true
        let qualityRow = NSStackView(views: [label("画质", size: 11), reconstructPopup, label("锐化", size: 11), sharpnessSlider, sharpnessValue])
        qualityRow.spacing = 10
        let note = label("设置自动生效 · 倍率/性能模式在后台切换 · 画质实时预览", size: 11, color: .secondaryLabelColor)
        let switchesContent = vertical([switches, qualityRow, note], spacing: 10)
        let switchesCard = card(switchesContent)
        switchesCard.heightAnchor.constraint(equalToConstant: 120).isActive = true
        switches.widthAnchor.constraint(equalTo: switchesContent.widthAnchor).isActive = true
        note.widthAnchor.constraint(equalTo: switchesContent.widthAnchor).isActive = true

        startButton = NSButton(title: "开始插帧", target: self, action: #selector(startStopClicked))
        startButton.bezelStyle = .rounded
        startButton.controlSize = .large
        startButton.bezelColor = .controlAccentColor
        startButton.font = .systemFont(ofSize: 14, weight: .semibold)
        startButton.keyEquivalent = "\r"
        startButton.isEnabled = false
        startButton.widthAnchor.constraint(equalToConstant: 150).isActive = true
        startButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let shortcut = label("⌃⌥S 开始 / 停止    ⌃⌥P 暂停 / 继续", size: 11, color: .secondaryLabelColor)
        let footer = NSStackView(views: [shortcut, NSView(), startButton])
        footer.alignment = .centerY
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.stringValue = "选择目标窗口后开始插帧"

        let stack = vertical([header, sourceCard, optionsCard, switchesCard, footer, statusLabel], spacing: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)
        ])
        for view in [header, sourceCard, optionsCard, switchesCard, footer, statusLabel] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        Task { await refreshTargets() }
    }

    /// 窗口列表用 NSTableView：NSScrollView 里塞 NSStackView 再互相约束宽度
    /// 会触发 AppKit 布局死循环（实测主线程永久卡在 rebuildList()）。
    func buildTable() {
        table = NSTableView()
        table.headerView = nil
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.rowHeight = 34
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("window"))
        column.resizingMask = .autoresizingMask
        column.width = 540
        table.addTableColumn(column)
        table.target = self
        table.action = #selector(tableClicked)
        tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .noBorder
        tableScroll.drawsBackground = true
        tableScroll.documentView = table
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc func tableClicked() {
        let row = table.selectedRow
        guard row >= 0, row < targets.count else { return }
        select(targets[row])
    }

    @objc func refreshClicked() { Task { await refreshTargets() } }

    /// 4Hz 的便宜跟随（拖动/缩放源窗口时覆盖层实时贴住）。理由见 `followOverlayFrame`。
    @objc func followTick() { followOverlayFrame() }

    @objc func periodicRefresh() {
        // 窗口枚举按需执行；运行中只检查已有源窗口，避免后台全量枚举。
        guard running else { return }
        if mode == .window { followTargetSize() }
        checkSourceSpace()
    }

    /// 源窗口一旦不在当前 Space，WindowServer 会**冻结它的内容**：采集端只剩 `.idle` 帧，
    /// 画面看起来就是「开头一两秒有画面，之后卡住/黑」。
    ///
    /// 修法不是把源窗口搬回来（那是上一版的错误方向：把 Chrome 请出原生全屏 = 露出地址栏），
    /// 而是**把我们的覆盖层搬进源窗口所在的 Space**。所以这里只做两件事：
    ///   ① 发现覆盖层掉了（例如源窗口又切了 Space），把它重新搬过去；
    ///   ② 实在搬不过去就明说 —— 绝不假装成功。
    func checkSourceSpace() {
        guard mode == .window, interpTargetID != 0 else { return }
        let vis = windowVisibility(interpTargetID)
        let off = vis.contains("onscreen=false")
        if off != sourceOffscreen {
            sourceOffscreen = off
            logLine("source-space: onscreen=\(!off) \(vis) 覆盖层=\(windowVisibility(overlayWindowID))")
        }
        guard off else { return }
        // 覆盖层已经不在源窗口那个 Space 了：把它重新搬过去并切过去。只在启动后
        // 20 秒内自愈 —— 之后还出问题通常是用户自己滑走了，硬抢很讨厌。
        if overlayWindowID != 0, spaceFixAttempts < 4, CACurrentMediaTime() - runningSince < 20 {
            spaceFixAttempts += 1
            let spaces = SpacePrivate.spaces(ofWindow: interpTargetID)
            var rc: Int32 = 0
            for s in spaces where s > 0 { rc += SpacePrivate.addWindows([overlayWindowID], toSpace: s) }
            let ok = SpacePrivate.revealSpace(ofWindow: interpTargetID)
            logLine("source-space: 自愈 #\(spaceFixAttempts) 搬入 rc=\(rc) 切Space=\(ok) "
                    + "覆盖层=\(windowVisibility(overlayWindowID))")
        } else {
            hintLabel.stringValue = "⚠️ 覆盖层不在被插帧窗口所在的空间了 —— 四指滑到视频那个空间，"
                + "或重新点一次「开始插帧」"
        }
    }
    @objc func badgeChanged(_ sender: NSButton) { showBadge.toggle(); preferences.set(showBadge, forKey: "showBadge"); badge?.isHidden = !showBadge || !floatingControlsVisible; if showBadge { flashHUD() }; sendLiveSettings() }

    @objc func multiplierChanged() {
        let index = multiplierPopup.indexOfSelectedItem
        guard supportedMultipliers.indices.contains(index) else { return }
        let chosen = supportedMultipliers[index]
        guard chosen != multiplier else { return }
        preferences.set(chosen, forKey: "multiplier")
        applyEngineSettings(multiplier: chosen)
    }

    @objc func modeChanged() {
        mode = CaptureMode(rawValue: modePopup.indexOfSelectedItem) ?? .window
        preferences.set(mode.rawValue, forKey: "mode")
        scheduleEngineSwitch()
    }
    @objc func perfModeChanged(_ sender: NSButton) {
        performanceMode = sender.state == .on
        preferences.set(performanceMode, forKey: "performanceMode")
        scheduleEngineSwitch()
    }

    @objc func reconstructionChanged() {
        let index = reconstructPopup.indexOfSelectedItem
        guard ReconstructMode.allCases.indices.contains(index) else { return }
        reconstruct = ReconstructMode.allCases[index]
        sharpenAmount = Float(sharpnessSlider.doubleValue)
        sharpnessValue.stringValue = "\(Int((sharpenAmount * 100).rounded()))%"
        sharpnessSlider.isEnabled = reconstruct == .cas
        preferences.set(reconstruct.rawValue, forKey: "reconstruct")
        preferences.set(sharpenAmount, forKey: "reconstructSharp")
        pipeline?.reconstruct = reconstruct
        pipeline?.sharpenAmount = sharpenAmount
        sendLiveSettings()
    }

    // MARK: 窗口枚举

    func refreshTargets() async {
        // Public screenshots use explicit demo data and never enumerate personal window titles.
        if hasFlag("--demo-targets") {
            targets = [
                CaptureTarget(windowID: 1, pid: 0, appName: "Safari", title: "视频播放", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), onscreen: true, area: 2073600, looksFullscreen: true),
                CaptureTarget(windowID: 2, pid: 0, appName: "IINA", title: "示例视频.mp4", frame: CGRect(x: 0, y: 0, width: 1280, height: 720), onscreen: true, area: 921600, looksFullscreen: false),
                CaptureTarget(windowID: 3, pid: 0, appName: "游戏", title: "窗口化游戏", frame: CGRect(x: 0, y: 0, width: 1600, height: 900), onscreen: true, area: 1440000, looksFullscreen: false)
            ]
            rebuildList()
            hintLabel.stringValue = "演示窗口列表 · 修改设置自动生效"
            return
        }
        // 同一时刻只跑一次枚举；后来的调用等它跑完再返回（否则会出现
        // "并发调用 → 第二个直接早退 → 拿到空列表" 的假象）
        if let existing = enumerateInFlight {
            logLine("refresh: 已有枚举在跑，等待")
            await existing.value
            logLine("refresh: 等待结束")
            return
        }
        let task = Task { @MainActor in await self.performEnumerate() }
        enumerateInFlight = task
        await task.value
        enumerateInFlight = nil
    }

    func performEnumerate() async {
        hintLabel.stringValue = "正在读取窗口列表…"

        guard CGPreflightScreenCaptureAccess() else {
            // 只请求一次：每 5 秒的列表预热如果反复调用，会不停弹系统提示
            if !permissionRequested {
                permissionRequested = true
                CGRequestScreenCaptureAccess()
                logLine("diag: 无屏幕录制权限（已请求一次）")
            }
            hintLabel.stringValue = "⚠️ 需要「屏幕录制」权限：菜单栏 ⚡ → 打开权限设置，勾选「窗口插帧助手」后重新打开本应用"
            statusLabel.stringValue = "未获得屏幕录制权限，无法枚举/采集窗口"
            return
        }
        if permissionRequested { permissionRequested = false; logLine("diag: 已获得屏幕录制权限") }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let myPID = ProcessInfo.processInfo.processIdentifier
            let myBundle = Bundle.main.bundleIdentifier ?? ""
            let noisy: Set<String> = ["Window Server", "Dock", "Control Center", "Notification Center",
                                      "SystemUIServer", "Spotlight", "WindowManager"]
            var out: [CaptureTarget] = []
            let displays = content.displays.map { $0.frame }
            for w in content.windows {
                guard let app = w.owningApplication else { continue }
                guard w.windowLayer == 0 else { continue }
                guard app.processID != myPID, app.bundleIdentifier != myBundle else { continue }
                guard !noisy.contains(app.applicationName) else { continue }
                let f = w.frame
                guard f.width >= 320, f.height >= 240 else { continue }
                let full = displays.contains { d in
                    f.width >= d.width - 4 && f.height >= d.height - 4
                }
                out.append(CaptureTarget(windowID: w.windowID,
                                         pid: app.processID,
                                         appName: app.applicationName,
                                         title: w.title ?? "",
                                         frame: f,
                                         onscreen: w.isOnScreen,
                                         area: f.width * f.height,
                                         looksFullscreen: full))
            }
            out.sort { a, b in
                if a.looksFullscreen != b.looksFullscreen { return a.looksFullscreen }
                if a.onscreen != b.onscreen { return a.onscreen }
                if a.area != b.area { return a.area > b.area }
                return a.appName < b.appName
            }
            targets = out
            logLine("diag: windows=\(out.count) raw=\(content.windows.count) apps=\(content.applications.count) displays=\(content.displays.count)")
            logLine("enumerate: 准备 rebuildList")
            rebuildList()
            logLine("enumerate: rebuildList 完成")
        } catch {
            hintLabel.stringValue = "读取窗口失败：\(error.localizedDescription)"
            logLine("diag: enumerate failed \(error.localizedDescription)")
        }
    }

    func rebuildList() {
        table?.reloadData()
        if targets.isEmpty {
            hintLabel.stringValue = "没有找到可采集的窗口。先让目标窗口进入全屏，再点「刷新窗口列表」。"
            startButton.isEnabled = running || starting
        } else {
            hintLabel.stringValue = "共 \(targets.count) 个窗口（★全屏 优先排序；列出的窗口包括其他桌面空间的）"
            startButton.isEnabled = selected != nil || running || starting
        }
        if let selected, let row = targets.firstIndex(where: { $0.windowID == selected.windowID }) {
            table?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        startButton.title = starting ? "取消启动" : (running ? "停止插帧" : "开始插帧")
    }

    func select(_ target: CaptureTarget) {
        selected = target
        statusLabel.stringValue = "已选中：\(target.display)"
        startButton.isEnabled = true
        startButton.title = starting ? "取消启动" : (running ? "停止插帧" : "开始插帧")
        if let row = targets.firstIndex(where: { $0.windowID == target.windowID }) {
            table?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    // MARK: 开始 / 停止

    @objc func startStopClicked() { (running || starting) ? stopInterpolation() : startInterpolation() }

    func startInterpolation(resuming: Bool = false) {
        if usesEngineWorker { startEngineSession(); return }
        guard !starting, (!running || resuming) else { return }
        guard let target = selected else { logLine("start: 没有选中窗口"); return }
        logLine("start: 请求 target=\(target.windowID) \(target.appName) mode=\(mode) fps=\(captureFPS)")
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            statusLabel.stringValue = "需要屏幕录制权限，授权后请重新打开本应用"
            if isEngineWorker { emitWorkerEvent(["event": "error", "message": statusLabel.stringValue]) }
            return
        }
        // 这里**不再**索要辅助功能权限了。上一版是为了「把浏览器原生全屏的源窗口请出
        // 独立 Space」才要的，而那条路本身就是错的（请出全屏 = Chrome 露出地址栏/书签/
        // 弹幕，等于窗口化插帧）。现在的做法是：源窗口一个字不动，把**我们的覆盖层**
        // 搬进它所在的 Space（见 openInterpWindow）。
        starting = true
        startGeneration += 1
        let generation = startGeneration
        startButton.title = "取消启动"
        statusLabel.stringValue = "正在准备采集 \(target.display)…"

        Task { [self] in
            defer {
                if self.startGeneration == generation {
                    self.starting = false
                    self.startButton.title = self.running ? "停止插帧" : "开始插帧"
                }
            }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard self.startGeneration == generation else { return }
                logLine("start: 已拿到 shareableContent")
                let filter: SCContentFilter
                guard let scw = content.windows.first(where: { $0.windowID == target.windowID }) else {
                    let message = "目标窗口已不存在，请刷新列表"
                    self.statusLabel.stringValue = message
                    if isEngineWorker { emitWorkerEvent(["event": "error", "message": message]) }
                    return
                }
                // The window can move/resize between enumeration, resume and engine warm-up.
                // Choose both capture size and display from the fresh ScreenCaptureKit snapshot.
                var sourceFrame = scw.frame

                if mode == .window {
                    filter = SCContentFilter(desktopIndependentWindow: scw)
                } else {
                    guard let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)) }) ?? content.displays.first else {
                        self.statusLabel.stringValue = "找不到目标所在的显示器"
                        return
                    }
                    let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                    filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                    // 整屏捕获按「这块显示器」算尺寸，而不是按那个窗口的 frame
                    sourceFrame = display.frame
                }

                // 采集尺寸 = 渲染尺寸（**不再有"输出与采集解耦"这回事**：那套只对
                // 「放大铺满屏幕」那档有意义，而本工具不做那档。见 `plannedCaptureSize`）。
                let planned = self.plannedCaptureSize(for: sourceFrame)
                let captureWidth = Int(planned.width)
                let captureHeight = Int(planned.height)
                let captureSize = CGSize(width: captureWidth, height: captureHeight)
                let fps = self.effectiveCaptureFPS
                logLine("start: 源 \(sourceFrame) → 采集=输出 \(captureWidth)x\(captureHeight) @\(Int(fps))fps "
                        + "(物理上限 \(self.physicalPixelSize(for: sourceFrame)) autoFPS=\(self.autoMatchFPS))")
                logLine("start: 重建档=\(self.reconstruct.rawValue) 强度=\(self.sharpenAmount)")

                var outputTarget = target
                outputTarget.frame = sourceFrame
                self.openInterpWindow(target: outputTarget, captureSize: captureSize)

                let pipeline = CapturePipeline(device: self.device, metal: self.metal,
                                               renderSize: captureSize,
                                               flipVertical: self.displayFlip)
                pipeline.queueDepth = self.captureQueueDepth
                pipeline.reconstruct = self.reconstruct
                pipeline.sharpenAmount = self.sharpenAmount
                pipeline.thruMid = self.reconstructThruMid
                pipeline.onFatal = { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.startGeneration == generation else { return }
                        if isEngineWorker { emitWorkerEvent(["event": "error", "message": message]) }
                        self.stopInterpolation()
                        self.statusLabel.stringValue = "⚠️ \(message)"
                        logLine("fatal: \(message)")
                    }
                }
                pipeline.onFirstFrame = { [weak self] in
                    DispatchQueue.main.async {
                        guard let self, self.startGeneration == generation, isEngineWorker else { return }
                        self.workerHasFrame = true
                        self.reportWorkerReadiness()
                    }
                }
                self.pipeline = pipeline
                self.interpTargetID = target.windowID
                self.interpTargetPID = target.pid
                self.sourceOffscreen = false
                self.spaceFixAttempts = 0
                self.runningSince = CACurrentMediaTime()
                logLine("start: 准备启动 SCStream \(captureWidth)x\(captureHeight) @\(Int(fps))fps")
                try await pipeline.start(filter: filter, targetWindowID: target.windowID,
                                         width: captureWidth, height: captureHeight, captureFPS: fps)
                guard self.startGeneration == generation else { pipeline.stop(); return }
                logLine("start: SCStream 已启动")
                self.running = true
                self.startButton.title = "停止插帧"
                let modeText = offMode ? "原帧模式" : (appleBackend ? "苹果原生 2×" : "LSFG \(multiplier)×")
                self.statusLabel.stringValue = "插帧中 · 采集 \(captureWidth)×\(captureHeight) @\(Int(fps))fps · \(modeText)"
                self.hintLabel.stringValue = "正在插帧 · 鼠标静止 3 秒后隐藏悬浮控件"
                logLine("start: ok target=\(target.windowID) \(target.appName) capture=\(captureWidth)x\(captureHeight) fps=\(Int(fps)) mode=\(self.mode) off=\(offMode)")
                // 自检用：`--test-pause <秒>` 在 N 秒时暂停、N+4 秒时继续。
                // 「暂停/继续」这条路径必须能自证 —— 否则用户报「暂停之后回不来」时无从判断。
                if !self.pauseTestScheduled, let s = argument("--test-pause"), let sec = Double(s) {
                    self.pauseTestScheduled = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, self.running else { return }
                            self.setPaused(true)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                                MainActor.assumeIsolated { self.setPaused(false) }
                            }
                        }
                    }
                }
                // 尺寸跟随由 periodicRefresh（5 秒一次、按需）统一负责，不再另开轮询
            } catch {
                guard self.startGeneration == generation else { return }
                self.stopInterpolation()
                self.statusLabel.stringValue = "启动失败：\(error.localizedDescription)"
                if isEngineWorker { emitWorkerEvent(["event": "error", "message": self.statusLabel.stringValue]) }
                logLine("start: failed \(error.localizedDescription)")
            }
        }
    }

    func stopInterpolation() {
        if usesEngineWorker {
            engineSwitchWork?.cancel(); engineSwitchWork = nil
            pendingTimeout?.cancel(); pendingTimeout = nil
            pendingSession?.stop(); pendingSession = nil
            engineSession?.stop(); engineSession = nil
            activeTarget = nil
        }
        if isEngineWorker { emitWorkerEvent(["event": "stopped"]) }
        startGeneration += 1
        starting = false
        pipeline?.stop()
        pipeline = nil
        running = false
        paused = false
        interpTargetID = 0
        interpTargetPID = 0
        sourceOffscreen = false
        spaceFixAttempts = 0
        overlayActive = false     // 关掉跟随（否则停止后它还会去搬那个已经不用的窗口）
        startButton.title = "开始插帧"
        pauseButton?.title = "暂停"
        statusLabel.stringValue = "已停止"
        hintLabel.stringValue = ""
        logLine("stop")
        // 把覆盖层从「源窗口所在的那些 Space」里撤掉，否则它会赖在视频那个 Space 上，
        // 用户停止插帧之后还会看到一块黑窗盖在视频上。
        if overlayWindowID != 0, !overlaySpaces.isEmpty {
            var rc: Int32 = 0
            for s in overlaySpaces where s > 0 { rc += SpacePrivate.removeWindows([overlayWindowID], fromSpace: s) }
            logLine("stop: 覆盖层撤出 Space rc=\(rc)")
        }
        overlayWindowID = 0
        overlaySpaces = []
        mouseActivityTimer?.invalidate()
        mouseActivityTimer = nil
        hudTimer?.invalidate()
        hudTimer = nil
        gameHUD?.orderOut(nil)
        gameHUD = nil
        if let w = interpWindow {
            w.closingForReal = true
            if w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
            w.orderOut(nil)
        }
        // 不强制把控制窗拉到前台：退出插帧通常是想回到原来那个全屏窗口
    }

    // MARK: 输出全屏窗口

    func openInterpWindow(target: CaptureTarget, captureSize: CGSize) {
        if interpWindow == nil {
            let w = InterpWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                 backing: .buffered, defer: false)
            w.title = "窗口插帧"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.appearance = NSAppearance(named: .darkAqua)
            w.delegate = self
            w.isReleasedWhenClosed = false
            w.collectionBehavior.insert(.fullScreenPrimary)
            w.acceptsMouseMovedEvents = true
            w.backgroundColor = .black
            if isEngineWorker { w.alphaValue = 0.01 }
            let root = NSView(); root.wantsLayer = true; root.layer?.backgroundColor = NSColor.black.cgColor
            w.contentView = root

            video = VideoView(frame: .zero)
            metal = CAMetalLayer()
            applyMetalHUD()
            metal.device = device
            metal.pixelFormat = .bgra8Unorm
            metal.framebufferOnly = false
            metal.maximumDrawableCount = drawableCount
            // displaySync 开启时，present 要排队等下一个垂直同步才显示 —— 画面更整齐，
            // 但会让「已经渲染好的帧」多等一个刷新周期。关掉可以少等，代价是可能撕裂。
            metal.displaySyncEnabled = displaySync
            // 注意：绝不能设 presentsWithTransaction —— 它会把 drawable 押到 CA commit，
            // 3 个 drawable 池耗尽后 LSFG 的 present hook 被静默旁路（引擎 generated=0）。
            metal.contentsScale = w.backingScaleFactor
            metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            video.layer?.backgroundColor = NSColor.black.cgColor
            video.layer?.masksToBounds = true
            video.layer?.addSublayer(metal)
            video.movieLayer = metal
            video.translatesAutoresizingMaskIntoConstraints = false
            video.onKey = { [weak self] in self?.keyPressed($0) }
            root.addSubview(video)
            NSLayoutConstraint.activate([
                video.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                video.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                video.topAnchor.constraint(equalTo: root.topAnchor),
                video.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
            buildHUD(in: root)
            let menu = NSMenu()
            let exitTitle = hasFlag("--native-fullscreen") ? "退出全屏（Esc）" : "退出插帧（Esc）"
            menu.addItem(withTitle: exitTitle, action: #selector(exitFullscreen), keyEquivalent: "").target = self
            if hasFlag("--native-fullscreen") {
                menu.addItem(withTitle: "停止插帧", action: #selector(startStopClicked), keyEquivalent: "").target = self
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "显示控制窗口", action: #selector(showControl), keyEquivalent: "").target = self
            w.contentView?.menu = nil
            interpWindow = w
        }
        interpWindow.title = "窗口插帧 · \(target.appName)"
        video.movieAspect = captureSize.width / captureSize.height
        metal.drawableSize = captureSize
        metal.contentsScale = interpWindow.backingScaleFactor
        video.needsLayout = true
        startMouseActivityTracking()

        // 输出方式：**贴住源窗口的穿透覆盖层**（唯一方式）—— 一个无边框窗口，
        // 精确盖在源窗口上（不是铺满整屏）。
        //
        // 三条硬约束（全部是 2026-10-12 实测出来的，改代码前先读完）：
        //   ① 源窗口必须待在**当前 Space**。源一旦不在当前 Space（原生全屏 Space 被切走），
        //      WindowServer 会冻结它的内容：采集端只剩 `.idle` 帧，用户看到「开头一两秒
        //      有画面，之后卡住/黑」。
        //   ② 覆盖层会**完全盖住**源窗口，Chrome 会因此停渲染 ⇒ 必须同时
        //      isOpaque=false **且** alphaValue<1，且经 8-bit 量化后要 <255
        //      （0.999 → 254 ✅；0.9999 → 255 = 不透明 ❌，实测失效）。缺一不可。
        //   ③ 覆盖层本身用 `.canJoinAllSpaces` 就能出现在源窗口那个 Space 里 ——
        //      **前提是当前 Space 就是源窗口的那个**。所以真正关键的动**是把源窗口所在的
        //      Space 切到前台**（见下面 ②）。这里踩过一个整条失效的坑：旧代码用
        //      `CGSGetWindowWorkspace` 取 Space，而它对**原生全屏**窗口稳定返回 0，
        //      于是切 Space 静默失败、覆盖层留在桌面 Space —— 用户看到的正是
        //      「Chrome 全屏界面里没有插帧，切到桌面又只有一张冻结画面」。
        //
        // ⚠️ 绝不要把源窗口请出原生全屏（上一版就是那么干的）：那样 Chrome 会把地址栏、
        // 书签、网页元素全露出来，等于「窗口化插帧」。用户要的是**满屏只剩视频**。
        let useOverlay = !hasFlag("--native-fullscreen") && !hasFlag("--test-window")
        overlayActive = useOverlay     // 只有真在铺覆盖层时才允许跟随，见 overlayActive 声明处
        if useOverlay {
            interpWindow.styleMask = [.borderless]
            interpWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            // `.floating`（3，盖过普通窗口即可）：我们只需要压住源窗口，
            // 不需要压过菜单栏 —— 源窗口本来也不会伸到菜单栏底下。
            interpWindow.level = .floating
            // 覆盖层**精确贴住源窗口**。窗口挪动/缩放后由 followOverlayFrame() 实时跟随
            // （4Hz，纯 CGWindowList 查询，不用枚举，见那里的说明）。
            interpWindow.setFrame(appkitRect(fromCG: target.frame), display: true)
            if !hasFlag("--solid") {
                // ⚠️ 这套属性的**设置顺序**是实验验证过的，别随手重排：
                // isOpaque → alphaValue → metal.isOpaque → video.layer.isOpaque
                interpWindow.isOpaque = false
                let a = Double(argument("--overlay-alpha") ?? "") ?? 0.999
                workerOutputAlpha = CGFloat(a)
                interpWindow.alphaValue = isEngineWorker && !workerActivated ? 0.01 : CGFloat(a)
                metal.isOpaque = false
                video.layer?.isOpaque = false
            }
            interpWindow.acceptsMouseMovedEvents = true

            // ① 先把覆盖层显示出来（此时还在用户当前那个 Space）。
            if let below = argument("--below-window"), let number = Int(below) {
                interpWindow.order(.below, relativeTo: number)
            } else { interpWindow.orderFrontRegardless() }

            let ownID = CGWindowID(interpWindow.windowNumber)
            let srcID = CGWindowID(target.windowID)
            let srcSpaces = SpacePrivate.spaces(ofWindow: srcID)
            logLine("output: 覆盖层 id=\(ownID) frame=\(interpWindow.frame) alpha=\(interpWindow.alphaValue) "
                    + "源Space=\(srcSpaces) 类型=\(srcSpaces.map { SpacePrivate.spaceType($0) })")

            // ② 让覆盖层出现在源窗口那个 Space。主路径是**把那个 Space 切到前台** ——
            //    用户点「开始插帧」之后本来就该直接看到插帧画面。
            //    ⚠️ 这一步曾经整条失效：`CGSGetWindowWorkspace` 对原生全屏窗口返回 0，
            //    于是切 Space 静默失败、覆盖层留在桌面 Space ⇒ 用户看到的是「Chrome 全屏
            //    界面里没有插帧，切到桌面又只有一张冻结画面」。现在改用
            //    `CGSCopySpacesForWindows` 取 Space（见 SpacePrivate.revealSpace）。
            //    切不动才退而求其次：用 SkyLight 私有 API 把窗口显式搬进去（实测这条路
            //    在原生全屏 Space 上常返回 kCGErrorFailure，只当兜底，不当主路径）。
            let switched = (hasFlag("--no-space-switch") || hasFlag("--warm-switch")) ? false : SpacePrivate.revealSpace(ofWindow: srcID)
            var moved: Int32 = -1
            if !switched {
                for s in srcSpaces where s > 0 {
                    moved = SpacePrivate.addWindows([ownID], toSpace: s)
                    if moved == 0 { break }
                }
            }
            overlayWindowID = ownID
            overlaySpaces = srcSpaces
            logLine("output: 切到源 Space switched=\(switched) 搬窗rc=\(moved) "
                    + "覆盖层=\(windowVisibility(ownID)) 源=\(windowVisibility(srcID))")

            // ③ **不激活本 App、不抢 key** —— 前台/键盘/鼠标全留给源窗口。
            //    键鼠根本不经过我们（覆盖层 ignoresMouseEvents=true，点击穿透到
            //    下面的源窗口）；系统光标本来就合成在所有窗口之上，天然跟手。
            //    ⚠️ 事件转发（CGEventPostToPid）是错误路线：目标不在前台就不处理
            //    键盘事件 —— 让事件「根本不经过我们」才是正解。
            interpWindow.ignoresMouseEvents = true
            hud.isHidden = true     // HUD 按钮在穿透窗口上点不了，亮出来只会误导
            if !isEngineWorker { showGameHUD(overlayFrame: interpWindow.frame) }
            logLine("output: 输入穿透已开启 ignoresMouseEvents=true "
                    + "覆盖层=\(interpWindow.frame) 源=\(target.frame) "
                    + "appActive=\(NSApplication.shared.isActive)")
            // 用户可能是点了控制窗的「开始」才到这里的 —— 那一下会把本 App 拉成前台，
            // 源窗口会丢 key。把前台还给源 App（点菜单栏/热键启动的则本来就没抢过）。
            if !hasFlag("--warm-switch"), let srcApp = NSRunningApplication(processIdentifier: target.pid) {
                let ok = srcApp.activate()
                logLine("output: 前台交还 pid=\(target.pid) ok=\(ok)")
            }
            // 判据：本 App **不该**是 key/active（跟已删除的「铺满整屏 + 抢 key」模式正好相反）。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                logLine("output: 1.5s 后 isKey=\(self.interpWindow.isKeyWindow) "
                    + "appActive=\(NSApplication.shared.isActive) "
                    + "ignoresMouseEvents=\(self.interpWindow.ignoresMouseEvents) "
                    + "覆盖层=\(windowVisibility(self.overlayWindowID))")
            }
            return
        }

        let testWindow = hasFlag("--test-window")
        if testWindow {
            // 自检用：不抢焦点、不进全屏、固定小窗口，免得打断用户。
            // --test-x/--test-y：把输出窗摆到指定屏幕（测延迟时源和输出必须在同一块屏，
            // 延迟测量法要求一次截图里同拍两个窗口）。
            let tx = Double(argument("--test-x") ?? "") ?? 60
            let ty = Double(argument("--test-y") ?? "") ?? 80
            let tw = Double(argument("--test-w") ?? "") ?? 900
            let th = Double(argument("--test-h") ?? "") ?? 560
            interpWindow.styleMask = [.titled]
            interpWindow.collectionBehavior = []
            interpWindow.setFrame(NSRect(x: tx, y: ty, width: tw, height: th), display: true)
            if let below = argument("--below-window"), let number = Int(below) {
                interpWindow.order(.below, relativeTo: number)
            } else { interpWindow.orderFrontRegardless() }
            print("INTERP_WINDOW_ID=\(interpWindow.windowNumber) capture=\(Int(captureSize.width))x\(Int(captureSize.height))")
            scheduleDump()
            return
        }

        let screen = screenFor(cgFrame: target.frame)
        if let screen {
            var f = interpWindow.frame
            f.origin = CGPoint(x: screen.frame.midX - f.width / 2, y: screen.frame.midY - f.height / 2)
            interpWindow.setFrame(f, display: true)
        }
        interpWindow.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
        interpWindow.makeKeyAndOrderFront(nil)
        interpWindow.makeFirstResponder(video)
        let w = interpWindow!
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.running || self.pipeline != nil else { return }
            if !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        }
    }

    /// 自检钩子：把**控制窗自己**截一张 PNG（`--dump-control <前缀>`）。
    /// 用来证明 UI 真的搭起来了 —— 红线：「编译过了」不等于「功能在跑」，
    /// 新增的控件（`--reconstruct` 那个下拉）必须有一张能看见它的截图。
    func scheduleControlDump() {
        guard let prefix = argument("--dump-control") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let num = self.controlWindow?.windowNumber, num != 0 else {
                print("CONTROL_DUMP_FAILED 没有控制窗"); return
            }
            guard let view = self.controlWindow?.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                print("CONTROL_DUMP_FAILED 无法绘制控制窗"); return
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            do {
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: prefix + ".png"))
                print("CONTROL_DUMP_DONE \(prefix).png \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
            } catch { print("CONTROL_DUMP_FAILED \(error.localizedDescription)") }
        }
    }

    /// 自检钩子：把「采集到的原始 CIImage」和「输出窗口的实际合成结果」各存一张 PNG，
    /// 用来判定画面方向/镜像是否正确（两张图 + 源窗口截图三方对比）。
    func scheduleDump() {
        guard let prefix = argument("--dump-output") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self else { return }
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            if let image = self.pipeline?.lastImage {
                let url = URL(fileURLWithPath: prefix + "-raw.png")
                try? CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: space)
                print("dump raw → \(url.path) size=\(Int(image.extent.width))x\(Int(image.extent.height))")
            } else {
                print("dump raw: 没有拿到帧")
            }
            if let num = self.interpWindow?.windowNumber, num != 0 {
                let path = prefix + "-window.png"
                Task { @MainActor in
                    do {
                        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                        if let mine = content.windows.first(where: { $0.windowID == CGWindowID(num) }) {
                            let filter = SCContentFilter(desktopIndependentWindow: mine)
                            let cfg = SCStreamConfiguration()
                            let scale = self.scaleFactor(for: mine.frame)
                            cfg.width = Int(mine.frame.width * scale)
                            cfg.height = Int(mine.frame.height * scale)
                            cfg.ignoreShadowsSingleWindow = true
                            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                            let rep = NSBitmapImageRep(cgImage: image)
                            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                            print("dump window → \(path) size=\(image.width)x\(image.height)")
                        } else {
                            print("dump window: 找不到自己的窗口 \(num)")
                        }
                    } catch {
                        print("dump window: \(error.localizedDescription)")
                    }
                    print("DUMP_DONE frames=\(self.pipeline?.frameCount ?? 0)")
                }
            } else {
                print("DUMP_DONE frames=\(self.pipeline?.frameCount ?? 0)")
            }
        }
    }

    func buildHUD(in root: NSView) {
        hud = NSView()
        hud.wantsLayer = true
        hud.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        hud.layer?.cornerRadius = 14
        hud.translatesAutoresizingMaskIntoConstraints = false
        hudLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        hudLabel.textColor = .white
        hudLabel.translatesAutoresizingMaskIntoConstraints = false
        hud.addSubview(hudLabel)

        // 覆盖层模式没有菜单栏可达（我们在原生全屏 Space 里），所有操作必须长在画面上：
        // 上一版只有一行文字、没有任何按钮，用户「什么都点不了」。
        pauseButton = FirstMouseButton(title: "暂停", target: self, action: #selector(pauseClicked))
        stopButton = FirstMouseButton(title: "停止插帧", target: self, action: #selector(stopClicked))
        for b in [pauseButton!, stopButton!] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11, weight: .semibold)
            b.translatesAutoresizingMaskIntoConstraints = false
            hud.addSubview(b)
        }
        root.addSubview(hud)

        badge = NSView()
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        badge.layer?.cornerRadius = 9
        badge.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        badgeLabel.textColor = NSColor.systemGreen
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(badgeLabel)
        root.addSubview(badge)

        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            hud.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -34),
            hud.heightAnchor.constraint(equalToConstant: 34),
            hudLabel.leadingAnchor.constraint(equalTo: hud.leadingAnchor, constant: 16),
            hudLabel.centerYAnchor.constraint(equalTo: hud.centerYAnchor),

            pauseButton.leadingAnchor.constraint(greaterThanOrEqualTo: hudLabel.trailingAnchor, constant: 14),
            pauseButton.centerYAnchor.constraint(equalTo: hud.centerYAnchor),
            stopButton.leadingAnchor.constraint(equalTo: pauseButton.trailingAnchor, constant: 8),
            stopButton.centerYAnchor.constraint(equalTo: hud.centerYAnchor),
            stopButton.trailingAnchor.constraint(equalTo: hud.trailingAnchor, constant: -14),

            badge.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            badge.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            badge.heightAnchor.constraint(equalToConstant: 26),
            badgeLabel.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 12),
            badgeLabel.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -12),
            badgeLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])
        hud.alphaValue = 0
        badge.isHidden = !showBadge
        badge.alphaValue = showBadge ? 1 : 0
    }

    // MARK: 已删除：光标强行显形 + 全局鼠标监听（2026-10-12 第十三轮）
    //
    // 老代码有一段 `ensureCursorVisible()`（`NSCursor.setHiddenUntilMouseMoves(false)` +
    // `CGDisplayShowCursor(CGMainDisplayID())` + `NSCursor.arrow.set()`）配一个全局鼠标监听，
    // 每隔 0.4 秒强行把指针掰回来。
    //
    // 它治的是**旧「非游戏模式」自己造出来的病**：那个模式的覆盖层铺满整屏且**不穿透**，
    // 鼠标移动事件被我们截走 ⇒ Chrome/Safari 收不到 `mouseMoved` ⇒ 全屏视频里被它们
    // 藏起来的指针永远不放回来 ⇒ 用户「鼠标都看不到、什么都点不了」。
    //
    // 现在覆盖层是**点击穿透**的（`ignoresMouseEvents = true`），鼠标事件直达源 App，
    // 源 App 自己就能把指针管好 —— 这段 hack 连同它的副作用一起没了。副作用当时只在
    // 旧模式里发生，但两条都是真问题：① `NSCursor.arrow.set()` 会把源 App 想要的
    // **光标形状**（播放器的隐藏态、网页的文本/手型光标）强行换成箭头；
    // ② `CGDisplayShowCursor(CGMainDisplayID())` 只认主屏，副屏上的窗口管不到。
    // 删掉之后这两条都不再发生。

    @objc func pauseClicked() { setPaused(!paused) }

    /// 暂停 = 停采集停渲染（画面定格、立刻省电），覆盖层与 HUD 原地保留，
    /// 用户随时按「继续」或在画面上点一下恢复。不退出、不动源窗口。
    func setPaused(_ value: Bool) {
        guard running, paused != value else { return }
        if usesEngineWorker {
            paused = value
            pauseRevision += 1
            engineSession?.send(["command": "pause", "value": value, "revision": pauseRevision])
            rebuildStatusMenu()
            return
        }
        paused = value
        pauseButton?.title = value ? "继续" : "暂停"
        gameHUDPause?.title = value ? "▶ 继续" : "⏸ 暂停"
        if value {
            // 连续「继续→暂停」时，使尚未完成的异步 startCapture 失效。
            startGeneration += 1
            starting = false
            pipeline?.stop()
            logLine("pause: 已暂停（采集/渲染已停，画面定格）")
        } else {
            logLine("pause: 继续（重建采集）")
            // ⚠️ 不能走 restartCapture()：它内部是 stopInterpolation()，会把覆盖层
            // orderOut 掉、还会从 Space 里撤出 —— 那是「停止」的语义，不是「继续」。
            startInterpolation(resuming: true)
        }
        flashHUD()
    }

    func applyMetalHUD() {
        // Apple 的公开 CAMetalLayer API；Info.plist 开启能力，mode 控制实时显示。
        metal?.developerHUDProperties = metalHUDEnabled ? ["mode": "default"] : [:]
    }

    @objc func toggleMetalHUD() {
        metalHUDEnabled.toggle()
        preferences.set(metalHUDEnabled, forKey: "metalHUDEnabled")
        metalHUDCheck.state = metalHUDEnabled ? .on : .off
        applyMetalHUD()
        sendLiveSettings()
        rebuildStatusMenu()
    }

    func setFloatingControlsVisible(_ visible: Bool) {
        floatingControlsVisible = visible
        hud?.alphaValue = visible ? 1 : 0
        badge?.isHidden = !visible || !showBadge
        badge?.alphaValue = visible ? 1 : 0
        // 隐藏面板同时撤掉命中区域，避免看不见的按钮挡住源窗口。
        if visible {
            if gameHUD?.isVisible == false { gameHUD?.orderFrontRegardless() }
        }
        else { gameHUD?.orderOut(nil) }
    }

    func startMouseActivityTracking() {
        mouseActivityTimer?.invalidate()
        lastMousePosition = NSEvent.mouseLocation
        flashHUD()
        // 只读系统鼠标位置，无需辅助功能权限，也不修改源 App 的光标。
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let point = NSEvent.mouseLocation
                guard point != self.lastMousePosition else { return }
                self.lastMousePosition = point
                if self.interpWindow?.frame.contains(point) == true || self.gameHUD?.frame.contains(point) == true {
                    self.flashHUD()
                }
            }
        }
        mouseActivityTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func flashHUD() {
        setFloatingControlsVisible(true)
        hudTimer?.invalidate()
        hudTimer = Timer(timeInterval: 3.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.setFloatingControlsVisible(false) }
        }
        RunLoop.main.add(hudTimer!, forMode: .common)
    }

    var refreshRate: Double {
        let screen = interpWindow?.screen ?? NSScreen.main
        guard let screen else { return 60 }
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let mode = id.flatMap { CGDisplayCopyDisplayMode($0)?.refreshRate } ?? 0
        return mode > 1 ? mode : Double(screen.maximumFramesPerSecond)
    }

    func keyPressed(_ event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            exitFullscreen()
        case 49: // 空格
            setPaused(!paused)
        case 3: // F
            toggleFullscreen()
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "f" { toggleFullscreen() }
        }
    }

    @objc func exitFullscreen() {
        if hasFlag("--native-fullscreen"), interpWindow.styleMask.contains(.fullScreen) {
            interpWindow.toggleFullScreen(nil)
        } else {
            stopInterpolation()   // 覆盖层模式：Esc 就是「停止插帧」，_源窗口完全不被动过_，立刻回到原视频
        }
    }
    @objc func stopClicked() { stopInterpolation() }
    func toggleFullscreen() {
        guard interpWindow != nil else { return }
        guard hasFlag("--native-fullscreen") else {
            // 覆盖层模式已经铺满屏幕；再切原生全屏会把源窗口挤到别的 Space，
            // 源会立刻停止渲染（见 openInterpWindow 的说明）。
            logLine("toggleFullscreen: 覆盖层模式忽略（原生全屏会让源窗口停止渲染）")
            return
        }
        interpWindow.toggleFullScreen(nil)
    }

    @objc func showControl() {
        if isEngineWorker { emitWorkerEvent(["event": "showControl"]); return }
        if controlWindow == nil { buildControlWindow() }
        if controlWindow.isMiniaturized { controlWindow.deminiaturize(nil) }
        NSApplication.shared.activate(ignoringOtherApps: true)
        controlWindow.makeKeyAndOrderFront(nil)
        Task { await refreshTargets() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        logLine("dock-reopen: 显示控制窗口")
        showControl()
        return false
    }

    @objc func openPermissionSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: 跟随源窗口尺寸变化
    //
    // 这一块原来是一个 1 秒一次的定时器，每次都调 SCShareableContent 重新枚举
    // **全部** 窗口（还是 onScreenWindowsOnly:false，跨所有空间）。配上 5 秒一次的
    // 列表预热，等于每秒多跑一次全窗口枚举 —— 而它唯一的目的只是判断「源窗口的
    // 尺寸变了没有」。现在改成复用已有的 5 秒枚举结果，不再单独枚举。

    // MARK: 游戏模式 HUD（独立可点小窗）

    /// 创建（一次性）并摆好游戏模式 HUD 小窗。位置优先在覆盖层**上方右侧**（完全
    /// 不挡游戏画面）；源窗口顶到屏幕上沿时，退到覆盖层内右上角。
    func showGameHUD(overlayFrame: NSRect) {
        if gameHUD == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 42),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            // floating 与覆盖层同级：后 order 的在上，稳压覆盖层一头。
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear          // 圆角黑底由内容层自己画
            panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            let root = NSView()
            root.wantsLayer = true
            root.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
            root.layer?.cornerRadius = 10
            panel.contentView = root

            gameHUDLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            gameHUDLabel.textColor = .white
            gameHUDLabel.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(gameHUDLabel)

            let pause = NSButton(title: "⏸ 暂停", target: self, action: #selector(pauseClicked))
            let stop = NSButton(title: "⏹ 停止插帧", target: self, action: #selector(stopClicked))
            for b in [pause, stop] {
                b.bezelStyle = .rounded
                b.controlSize = .small
                b.font = .systemFont(ofSize: 11, weight: .semibold)
                b.translatesAutoresizingMaskIntoConstraints = false
                root.addSubview(b)
            }
            gameHUDPause = pause
            gameHUDStop = stop
            NSLayoutConstraint.activate([
                gameHUDLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
                gameHUDLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
                pause.leadingAnchor.constraint(greaterThanOrEqualTo: gameHUDLabel.trailingAnchor, constant: 12),
                pause.centerYAnchor.constraint(equalTo: root.centerYAnchor),
                stop.leadingAnchor.constraint(equalTo: pause.trailingAnchor, constant: 8),
                stop.centerYAnchor.constraint(equalTo: root.centerYAnchor),
                stop.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            ])
            gameHUD = panel
        }
        positionGameHUD(overlayFrame: overlayFrame)
        flashHUD()
        logLine("game-hud: 已显示 frame=\(gameHUD?.frame ?? .zero)")
    }

    func positionGameHUD(overlayFrame: NSRect) {
        guard let panel = gameHUD else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(overlayFrame) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? overlayFrame
        var y = overlayFrame.maxY + 10                    // 覆盖层正上方（不挡游戏）
        if y + panel.frame.height > vf.maxY {             // 顶到屏幕边：贴到覆盖层内右上
            y = overlayFrame.maxY - panel.frame.height - 10
        }
        let w = panel.frame.width
        let x = max(overlayFrame.maxX - w - 12, vf.minX)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// 只查**源窗口自己**的 frame。走 `CGWindowListCopyWindowInfo`（不碰 ScreenCaptureKit）。
    ///
    /// 为什么不复用 `targets`：那套是 `SCShareableContent` 枚举出来的 —— 要跨 Space、
    /// 跨 App 收集全部窗口信息，很贵，只能 5 秒一拍。而跟随要的是**实时**，
    /// 所以这里换一条几十微秒的便宜路径（一次 syscall，返回在屏窗口列表）。
    func windowFrameFromCGWindowList(_ id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] else { return nil }
        for info in list {
            guard let num = info[kCGWindowNumber as String] as? NSNumber, num.uint32Value == id else { continue }
            guard info[kCGWindowIsOnscreen as String] as? Bool == true else { return nil }
            guard let d = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: d) else { return nil }
            return rect
        }
        return nil
    }

    /// 覆盖层的**实时跟随**（4Hz，由 followTimer 驱动）。
    ///
    /// 旧的「非游戏模式」覆盖层铺满整屏、压根不需要跟随；贴源覆盖层要通用所有场景之后，
    /// 「拖着窗口走、画面晚 5 秒才贴上来」就成了硬伤（画面会飘在窗口外面）。
    func followOverlayFrame() {
        // ⚠️ overlayActive 那一项不能少：`--test-window` 的输出窗必须停在指定位置，
        // 被跟着拖到源窗口上会让延迟测量静默归零。理由见 overlayActive 的声明处。
        guard mode == .window, overlayActive, running, !paused, interpTargetID != 0 else { return }
        guard let iw = interpWindow, iw.isVisible else { return }
        guard let f = windowFrameFromCGWindowList(interpTargetID) else { return }
        // 垃圾帧守卫：窗口列表偶发会给出一个**不在任何屏幕内**的 frame
        // （窗口刚销毁、正在跨 Space 迁移、或 window server 的中间态）。
        // 这种帧套上去一定会把覆盖层甩到看不见的地方，且肉眼表现为「跳一下」。
        // 宁可不贴（停在原位，250ms 后下一拍重试），也不要贴错。
        // 注意：这**不是**对「某次 @790,278」那个未复现异常的修复 —— 那次的值仍在屏内，
        // 这道守卫拦不住它。它拦的是「frame 根本不在屏幕上」这一整个类别。
        guard let fScreen = strictScreenFor(cgFrame: f) else {
            let k = "\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
            if k != lastOverlayRejectKey {       // 去重：拖出去那一秒别刷屏
                lastOverlayRejectKey = k
                logLine("overlay-follow: 跳过屏外帧 \(k)（不在任何屏幕内）")
            }
            return
        }
        lastOverlayRejectKey = ""
        let nf = appkitRect(fromCG: f)
        let cur = iw.frame
        if abs(nf.minX - cur.minX) > 1 || abs(nf.minY - cur.minY) > 1
            || abs(nf.width - cur.width) > 1 || abs(nf.height - cur.height) > 1 {
            iw.setFrame(nf, display: true)
            positionGameHUD(overlayFrame: nf)   // 控制小窗跟着贴
            // 诊断字段给足：源 CG 帧 + 换算后的 AppKit 帧 + 落在哪块屏 + 源是不是前台。
            // 「@790,278 应为 @790,762」那次不可复现的异常，就差这些上下文。
            logLine("overlay-follow: 贴住源窗口 \(Int(f.width))x\(Int(f.height)) "
                    + "CG@\(Int(f.minX)),\(Int(f.minY)) AppKit@\(Int(nf.minX)),\(Int(nf.minY)) "
                    + "screen=\(fScreen.localizedName) front=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == interpTargetPID)")
        }
        // 只有**尺寸**变了才动采集管线。纯移动绝不碰 updateSize —— 那是重活，
        // 不能让它变成 4Hz 的热路径。
        guard let t = selected,
              abs(f.width - t.frame.width) > 2 || abs(f.height - t.frame.height) > 2 else { return }
        applyCaptureSizeChange(f)
    }

    /// 窗口尺寸变了：按同一套规则（物理像素上限）重算采集尺寸。**采集尺寸就是渲染尺寸**。
    func applyCaptureSizeChange(_ f: CGRect) {
        let planned = plannedCaptureSize(for: f)
        let w = Int(planned.width), h = Int(planned.height)
        selected?.frame = f
        metal?.drawableSize = planned
        video?.movieAspect = CGFloat(w) / CGFloat(h)
        video?.needsLayout = true
        pipeline?.renderSize = planned
        pipeline?.updateSize(width: w, height: h, captureFPS: effectiveCaptureFPS)
        logLine("resize: \(Int(f.width))x\(Int(f.height)) → 采集=输出 \(w)x\(h)")
    }

    /// 5 秒一次检查窗口是否关闭；坐标必须实时读取，不能复用启动时的 targets 缓存。
    func followTargetSize() {
        guard interpTargetID != 0 else { return }
        guard let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, interpTargetID) as? [[String: Any]] else { return }
        guard windows.contains(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == interpTargetID }) else {
            if isEngineWorker { emitWorkerEvent(["event": "error", "message": "目标窗口已关闭，请重新选择窗口"]) }
            stopInterpolation()
            statusLabel.stringValue = "目标窗口已关闭，请重新选择窗口"
            return
        }
        followOverlayFrame()
    }

    // MARK: 屏幕换算

    /// CG 全局坐标（主屏左上为原点，y 向下）→ AppKit 全局坐标（主屏左下为原点，y 向上）。
    /// 与 screenFor(cgFrame:) 同一套换算，保证一致。游戏模式要拿它把覆盖层**精确贴住**源窗口。
    func appkitRect(fromCG cg: CGRect) -> NSRect {
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: cg.origin.x, y: mainTop - cg.maxY, width: cg.width, height: cg.height)
    }

    /// 严格版「这帧落在哪块屏」：**不在任何屏幕内就返回 nil**。
    /// 不能复用 `screenFor` —— 它的末尾是 `?? NSScreen.main`（对着「一定要给块屏」的场景写的），
    /// 拿它判垃圾帧等于把垃圾帧也兜成 NSScreen.main，判据当场失效。
    func strictScreenFor(cgFrame: CGRect) -> NSScreen? {
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        let point = CGPoint(x: cgFrame.midX, y: mainTop - cgFrame.midY)
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    func screenFor(cgFrame: CGRect) -> NSScreen? {
        // CG 坐标（左上原点）→ AppKit 坐标（左下原点）
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let mainTop = NSScreen.screens.first.map { $0.frame.maxY } ?? primaryHeight
        let appkitY = mainTop - cgFrame.midY
        let point = CGPoint(x: cgFrame.midX, y: appkitY)
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    func scaleFactor(for cgFrame: CGRect) -> CGFloat {
        let screen = screenFor(cgFrame: cgFrame)
        return screen?.backingScaleFactor ?? 2
    }

    /// 显示器**真实像素**尺寸。
    ///
    /// 不能用「逻辑尺寸 × backingScaleFactor」：在「更多空间」这类缩放模式下
    /// backingScaleFactor 仍然返回 2，而这台机器的屏幕真实像素只有 2560×1664，
    /// 于是 1710×1069 会被算成 3420×2138 —— 比屏幕本身还多 1.72 倍像素。
    /// 代价是 WindowServer 先上采样、插帧引擎在放大后的图上生成中间帧、最后
    /// 再缩回去显示，整条链路白烧电（实测这一项就占了 GPU 满负荷的一大半）。
    func physicalPixelSize(for cgFrame: CGRect) -> CGSize {
        guard let screen = screenFor(cgFrame: cgFrame) else { return .zero }
        guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            return CGSize(width: screen.frame.width * screen.backingScaleFactor,
                          height: screen.frame.height * screen.backingScaleFactor)
        }
        // 面板物理分辨率 = 这块显示器所有显示模式里「渲染像素尺寸」的最大值。
        //
        // 不能用 CGDisplayCopyDisplayMode()：它返回的是**当前渲染缓冲区**的尺寸。在
        // 「更多空间」这类缩放模式下，系统是先把画面渲染到 3420×2224（逻辑点 ×2），
        // 再下采样到面板的 2560×1664 才真正显示。让插帧引擎在 3420×2224 上生成中间帧，
        // 多出来的 1.72 倍像素最后全被丢掉 —— 实测这就是功耗的大头。
        if let modes = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] {
            var best = CGSize.zero
            for m in modes {
                let w = CGFloat(m.pixelWidth), h = CGFloat(m.pixelHeight)
                if w * h > best.width * best.height { best = CGSize(width: w, height: h) }
            }
            if best.width >= 16 { return best }
        }
        if let mode = CGDisplayCopyDisplayMode(id), mode.pixelWidth > 0, mode.pixelHeight > 0 {
            return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        }
        return CGSize(width: screen.frame.width * screen.backingScaleFactor,
                      height: screen.frame.height * screen.backingScaleFactor)
    }

    /// Capture and drawable follow the full Retina backing raster by default.
    /// Panel capping would downsample here and let WindowServer scale up again.
    /// --limit-capture-pixels retains the old lower-cost diagnostic path.
    func plannedCaptureSize(for cgFrame: CGRect) -> CGSize {
        let scale = scaleFactor(for: cgFrame)
        var w = cgFrame.width * scale
        var h = cgFrame.height * scale
        if !ignorePixelCap {
            let cap = physicalPixelSize(for: cgFrame)
            if cap.width >= 16, cap.height >= 16 {
                let k = min(1.0, min(cap.width / w, cap.height / h))
                w *= k; h *= k
            }
        }
        if workResolution > 0 {
            let k = min(1.0, Double(workResolution) / h)
            w *= k; h *= k
        }
        return evenSize(CGSize(width: w, height: h))
    }

    /// 长宽各向下取到偶数（视频/纹理管线对奇数尺寸不友好），并保证不小于 64。
    func evenSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(64, (size.width / 2).rounded(.down) * 2),
               height: max(64, (size.height / 2).rounded(.down) * 2))
    }

    /// 实际使用的采集帧率上限。
    ///
    /// 引擎按「源帧率 × 倍率」出帧，超出屏幕刷新率的部分**根本显示不出来**。
    /// 60Hz 屏 + 2× 时源只要能到 30fps 就够，多采的帧等于让引擎白算一遍。
    /// 这是捕获上限；实际仍由源窗口和 WindowServer 决定。高帧率源也会被采样到该上限。
    var effectiveCaptureFPS: Double { appleBackend && !offMode ? max(1, min(60, Double(targetFPS) / 2)) : 60 }

    /// 端到端延迟估计（毫秒）—— 不是拍脑袋，是 `dev/lat-round.sh`（扫描条相对位置法）
    /// 实测出来的。两套实测（Apple M4 / 光流 0.5 / queueDepth 3 / 工作分辨率 400p）：
    ///
    ///     60Hz 主屏（内建）：基线 20ms · 2×=50 · 3×=185 · 4×=285
    ///     144Hz 主屏（外接）：基线 14ms · 2×=21 · 3×=28 · 4×=35
    ///
    /// 两个关键结论（2026-10-12 实测定案）：
    ///   ① **高刷屏上延迟 = (倍率+1) 个刷新周期**：144Hz 的 21/28/35ms 与
    ///      (m+1)×1000/144 严丝合缝，基线 14ms ≈ 2 帧。之前「3× 185ms」的元凶
    ///      就是 60Hz：源被压到 20fps + 16.7ms 的 vsync 步进，3× 起进入饥饿区
    ///      立方暴涨；144Hz 上源帧率 ≥36fps，永远不饿。
    ///   ② ⚠️ **引擎按「主屏」刷新率排程**（日志 display 144 Hz），不是输出窗口所在
    ///      那块屏：输出放 60Hz 副屏时引擎仍按 144 排程，实测 2× 会多吃 ~60ms 惩罚
    ///      （117ms vs 主屏 50ms）。⇒ 插帧/游戏尽量放主屏（通常是高刷外接屏）。
    private static let measuredLatencyAt60Hz: [Int: Double] = [2: 50, 3: 185, 4: 285]

    static func latencyEstimateMS(multiplier m: Int, refreshRate hz: Double) -> Double? {
        guard m > 1 else { return nil }
        let hz = hz > 1 ? hz : 60
        if hz >= 120 {
            // 高刷区：实测线性模型「(倍率+1) 个刷新周期」（144Hz 的 2/3/4× 全部命中）
            return Double(m + 1) * 1000.0 / hz
        }
        // 低刷区（≤60Hz）：2× 仍是 3 帧（50ms）；3× 起进入饥饿区按立方外推
        let base: Double
        if let exact = measuredLatencyAt60Hz[m] {
            base = exact
        } else {
            guard let ref = measuredLatencyAt60Hz[4] else { return nil }
            base = ref * Double(m * m * m) / 64.0
        }
        return base * 60.0 / hz
    }

    var estimatedLatencyMS: Double? {
        guard !offMode, !appleBackend else { return nil }
        return Self.latencyEstimateMS(multiplier: multiplier, refreshRate: refreshRate)
    }

    /// 倍率拉高时的「延迟代价」提示。
    /// 实测 2× 和 3× 完全不是一个量级（50ms vs 185ms），值得明确说一句 ——
    /// 免得用户以为「倍率越高越好」而选了 3×，却觉得操作变迟钝、以为是程序卡了。
    var latencyAdvice: String? {
        guard !offMode, let ms = estimatedLatencyMS, ms > 80 else { return nil }
        if let two = Self.latencyEstimateMS(multiplier: 2, refreshRate: refreshRate), two < ms * 0.6 {
            return String(format: "%d× 的端到端延迟约 %.0fms（2× 只要约 %.0fms）。画面更顺，但操作会明显迟钝。",
                          multiplier, ms, two)
        }
        return String(format: "当前端到端延迟约 %.0fms，觉得操作迟钝就把倍率调低一档。", ms)
    }

    /// 「约 185ms 延迟」这种给人看的短句
    static func latencyLabel(multiplier m: Int, refreshRate hz: Double) -> String {
        guard !appleBackend else { return "" }
        guard let ms = latencyEstimateMS(multiplier: m, refreshRate: hz) else { return "" }
        return " · 约 \(Int(ms.rounded()))ms 延迟"
    }

    // MARK: 功耗相关选项

    @objc func togglePerfMode() {
        guard !appleBackend else { return }
        let on = !performanceMode
        preferences.set(on, forKey: "performanceMode")
        perfModeCheck.state = on ? .on : .off
        performanceMode = on
        scheduleEngineSwitch()
    }

    // MARK: 状态栏 / 快捷键

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⚡︎"
        statusItem.button?.toolTip = "窗口插帧助手"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildStatusMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // 先显示缓存，打开菜单时按需更新一次；不做后台列表预热。
        rebuildStatusMenu()
        Task { await refreshTargets(); if NSApp.currentEvent != nil { rebuildStatusMenu() } }
    }

    func rebuildStatusMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()
        @discardableResult
        func add(_ title: String, _ action: Selector?, checked: Bool? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if let checked { item.state = checked ? .on : .off }
            menu.addItem(item)
            return item
        }
        add("窗口插帧助手 · \(multiplier)× · v\(appVersion)", nil).isEnabled = false
        menu.addItem(.separator())
        add("显示控制窗口", #selector(showControl))
        let start = add(running ? "停止插帧" : "开始插帧", #selector(startStopClicked))
        start.isEnabled = running || selected != nil
        start.keyEquivalent = "s"
        start.keyEquivalentModifierMask = [.control, .option]
        if running { add(paused ? "继续插帧" : "暂停插帧", #selector(pauseClicked)) }
        menu.addItem(.separator())
        let sources = NSMenu()
        for target in targets.prefix(40) {
            let item = NSMenuItem(title: target.display, action: #selector(menuTargetClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: target.windowID)
            item.state = selected?.windowID == target.windowID ? .on : .off
            sources.addItem(item)
        }
        if sources.items.isEmpty { sources.addItem(withTitle: "暂无窗口，请刷新列表", action: nil, keyEquivalent: "") }
        add("选择目标窗口", nil).submenu = sources
        add("刷新窗口列表", #selector(refreshMenu))
        let multipliers = NSMenu()
        for value in supportedMultipliers {
            let item = NSMenuItem(title: "\(value)× 插帧", action: #selector(menuMultiplier(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: value)
            item.state = value == multiplier ? .on : .off
            multipliers.addItem(item)
        }
        add("插帧倍数", nil).submenu = multipliers
        let modes = NSMenu()
        for (index, title) in ["窗口（推荐）", "整屏"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(menuMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: index)
            item.state = index == mode.rawValue ? .on : .off
            modes.addItem(item)
        }
        add("抓取方式", nil).submenu = modes
        menu.addItem(.separator())
        if !appleBackend { add("性能模式", #selector(togglePerfMode), checked: performanceMode) }
        add("显示右上角插帧角标", #selector(toggleBadge), checked: showBadge)
        add("Metal HUD", #selector(toggleMetalHUD), checked: metalHUDEnabled)
        if !CGPreflightScreenCaptureAccess() {
            menu.addItem(.separator())
            add("打开屏幕录制权限设置", #selector(openPermissionSettings))
        }
        menu.addItem(.separator())
        let quit = add("退出", #selector(NSApplication.terminate(_:)))
        quit.target = NSApplication.shared
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = [.control, .option]
    }

    @objc func menuTargetClicked(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber,
              let t = targets.first(where: { $0.windowID == n.uint32Value }) else { return }
        select(t)
        rebuildStatusMenu()
    }
    @objc func refreshMenu() { Task { await refreshTargets() } }
    @objc func focusInterp() {
        guard let w = interpWindow else { return }
        w.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
    @objc func toggleBadge() { showBadge.toggle(); preferences.set(showBadge, forKey: "showBadge"); badge?.isHidden = !showBadge || !floatingControlsVisible; if showBadge { flashHUD() }; sendLiveSettings() }

    @objc func menuMultiplier(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        preferences.set(n.intValue, forKey: "multiplier")
        applyEngineSettings(multiplier: n.intValue)
    }
    @objc func menuMode(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        mode = CaptureMode(rawValue: n.intValue) ?? .window
        preferences.set(mode.rawValue, forKey: "mode")
        modePopup.selectItem(at: mode.rawValue)
        scheduleEngineSwitch()
    }

    func registerHotkeys() {
        // ⌃⌥S / ⌃⌥P / ⌃⌥Q：Carbon **系统级**热键 —— 不需要辅助功能权限、
        // 游戏/其它 App 全屏时照样触发。（上一版 NSEvent 键盘全局监听没授权就
        // 静默失效，是「游戏模式退不出去」的直接元凶，见 SystemHotkeys 注释。）
        SystemHotkeys.register(key: "s") { [weak self] in self?.startStopClicked() }
        SystemHotkeys.register(key: "p") { [weak self] in self?.setPaused(!(self?.paused ?? false)) }
        SystemHotkeys.register(key: "q") { NSApplication.shared.terminate(nil) }
    }

    var multiplierLabel: String { "\(multiplier)×" }

    // MARK: 每秒状态刷新

    func tickStatus() {
        if usesEngineWorker {
            if running && pendingSession == nil {
                statusLabel.stringValue = paused ? "⏸ 已暂停" : String(format: "%d× · 呈现 %.1f fps · 已渲染 %d · 丢弃过期帧 %d", appliedMultiplier, remoteFPS, remoteFrames, remoteDropped)
                if engineOutFPS > 0 && !appleBackend { statusLabel.stringValue += String(format: " · 估计输出 %.0f fps", engineOutFPS) }
                if !settingsError.isEmpty { statusLabel.stringValue += " · ⚠️ 设置未应用：" + settingsError }
            }
            statusItem?.button?.title = running ? "⚡\(appliedMultiplier)×" : "⚡︎"
            return
        }
        guard running else { return }
        var parts: [String] = []
        if let p = pipeline {
            parts.append(String(format: appleBackend && !offMode ? "呈现 %.1f fps" : "采集 %.1f fps", appleBackend && !offMode ? p.displayFPS : p.feedFPS))
            parts.append("已渲染 \(p.frameCount)")
            if p.droppedCount > 0 { parts.append("丢 \(p.droppedCount)") }
        }
        parts.append(String(format: "屏 %.0fHz", refreshRate))
        if appleBackend, !offMode, let p = pipeline, let stats = p.appleStats {
            lastEngineGenerated = p.presentedGeneratedCount
            engineOutFPS = p.displayFPS
            engineSrcFPS = stats.inputFPS
            lastEngineStamp = CACurrentMediaTime()
            parts.append(String(format: "苹果 2× · 已显示中间帧 %d · 处理 %.1fms · 工作 %d×%d",
                                lastEngineGenerated, stats.processingMS, Int(stats.size.width), Int(stats.size.height)))
        }
        if !appleBackend, !offMode, let text = tailOfFile(engineLog) {
            let line = text.components(separatedBy: "\n").last(where: { $0.contains("Frame generation stats") }) ?? ""
            if !line.isEmpty, line != lastEngineLine {
                func count(_ name: String) -> Int {
                    guard let range = line.range(of: name + "=") else { return 0 }
                    return Int(line[range.upperBound...].prefix(while: { $0.isNumber })) ?? 0
                }
                let generated = count("generated"), original = count("source"), total = count("total")
                let delta = original - lastEngineSource
                if lastEngineStamp > 0 && delta > 0 {
                    let engineRate = Double(count("source_fps"))
                    let ratio = Double(total - lastEngineTotal) / Double(delta)
                    let out = engineRate * ratio
                    let gen = engineRate * Double(generated - lastEngineGenerated) / Double(delta)
                    parts.append(String(format: "源 %.0f fps → 估计 %.0f fps（插入 %.0f）", engineRate, out, gen))
                    engineSrcFPS = engineRate
                    engineOutFPS = out
                    engineGenRatio = ratio
                } else if generated > 0 {
                    parts.append("LSFG 已插入 \(generated) 帧")
                }
                lastEngineGenerated = generated; lastEngineSource = original; lastEngineTotal = total
                lastEngineStamp = CACurrentMediaTime(); lastEngineLine = line
            } else if text.contains("failed") || text.contains("unavailable") {
                parts.append("⚠️ 插帧异常，可能已回退原帧")
            } else if lastEngineStamp == 0 && running {
                parts.append("LSFG 引擎预热中…")
            }
        }
        if running, !paused, let p = pipeline, p.frameCount == 0, CACurrentMediaTime() - runningSince > 6 {
            parts.append("⚠️ 还没抓到帧（静态画面本来就不出帧；动态画面仍为 0 请反馈）")
        }
        let text = parts.joined(separator: " · ")
        statusLabel.stringValue = text
        if let badge, !badge.isHidden {
            // 角标顺带当「操作提示」用：用户上一次的反馈是「什么都点不了、也不知道怎么退」，
            // 所以把可用操作直接写在画面右上角常驻。
            if running && paused {
                badgeLabel.stringValue = "⏸ 已暂停 · ⌃⌥P 继续 · ⌃⌥S 停止"
                badgeLabel.textColor = NSColor.systemYellow
            } else {
                // 「源 40 → 出 120」是关键：只亮采集帧率（40）会让人以为插帧没生效
                // （实测就有用户拿着 3× 引擎输出 120fps 的会话说「一丝都没提升」——
                //  他看不到引擎日志。把引擎真实输出直接亮在画面上。）
                let rate: String = {
                    if offMode { return "\(Int(pipeline?.feedFPS ?? 0))fps" }
                    if engineOutFPS > 1 && CACurrentMediaTime() - lastEngineStamp < 4 {
                        return String(format: appleBackend ? "呈现 %.0ffps" : "源 %.0f → 估计 %.0ffps", appleBackend ? engineOutFPS : engineSrcFPS, engineOutFPS)
                    }
                    return "\(Int(pipeline?.feedFPS ?? 0))fps"
                }()
                badgeLabel.stringValue = running
                    ? "⚡ \(offMode ? "原帧" : "\(multiplierLabel) 插帧中") · \(rate) · ⌃⌥S 停止"
                    : "⏹ 已停止"
                badgeLabel.textColor = running ? NSColor.systemGreen : NSColor.systemOrange
            }
        }
        // 游戏 HUD 小窗文案（独立窗，永远可见可点）：状态 + 真实输出帧率
        if let panel = gameHUD, panel.isVisible {
            gameHUDLabel.textColor = paused ? NSColor.systemYellow : NSColor.white
            gameHUDLabel.stringValue = running
                ? (offMode ? "原帧 · \(Int(pipeline?.feedFPS ?? 0))fps"
                           : (paused ? "⏸ 已暂停（⌃⌥P 继续）"
                                     : (engineOutFPS > 1 && CACurrentMediaTime() - lastEngineStamp < 4
                                        ? (appleBackend ? String(format: "苹果 2× · 呈现 %.0f fps", engineOutFPS) : String(format: "%@ · 源 %.0f → 估计输出 %.0f fps", multiplierLabel, engineSrcFPS, engineOutFPS))
                                        : "\(multiplierLabel) · 采集 \(Int(pipeline?.feedFPS ?? 0))fps · 等待引擎统计")))
                : "已停止"
        }
        // 菜单栏图标带状态（A = 自动倍率）：不用盯日志也知道现在几倍
        if let button = statusItem?.button {
            let title = running ? "⚡\(offMode ? "原" : "\(multiplier)×")" : "⚡︎"
            if button.title != title { button.title = title }
        }
        if let hud, hud.alphaValue > 0 { hudLabel.stringValue = text }
        if isEngineWorker {
            reportWorkerReadiness()
            emitWorkerEvent(["event": "stats", "frames": pipeline?.frameCount ?? 0,
                             "dropped": pipeline?.droppedCount ?? 0, "fps": (appleBackend && !offMode ? pipeline?.displayFPS : pipeline?.feedFPS) ?? 0,
                             "outputFPS": engineOutFPS, "generated": pipeline?.presentedGeneratedCount ?? 0,
                             "sourceFPS": engineSrcFPS, "presentationStalls": pipeline?.presentationStalls ?? 0,
                             "captureWidth": Int(pipeline?.renderSize.width ?? 0), "captureHeight": Int(pipeline?.renderSize.height ?? 0),
                             "workWidth": Int(pipeline?.appleStats?.size.width ?? 0), "workHeight": Int(pipeline?.appleStats?.size.height ?? 0),
                             "processingMS": pipeline?.appleStats?.processingMS ?? 0,
                             "backend": appleBackend ? "apple" : "lsfg", "paused": paused, "pauseRevision": pauseRevision])
        }

    }

    // MARK: 窗口代理

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if let iw = w as? InterpWindow, iw === interpWindow, !iw.closingForReal, running {
            logLine("interp window closed by user → 停止插帧")
            stopInterpolation()
            return
        }
        guard w === controlWindow else { return }
        // 关掉控制窗不退出：工具类应用的主入口是菜单栏
        logLine("control window closed (hidden)")
    }

    // MARK: 窗口列表（NSTableView）

    nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
        MainActor.assumeIsolated { targets.count }
    }

    nonisolated func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        MainActor.assumeIsolated {
            guard row >= 0, row < targets.count else { return nil }
            let id = NSUserInterfaceItemIdentifier("cell")
            var cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView
            if cell == nil {
                let c = NSTableCellView()
                c.identifier = id
                let tf = NSTextField(labelWithString: "")
                tf.font = .systemFont(ofSize: 12)
                tf.lineBreakMode = .byTruncatingMiddle
                tf.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(tf)
                c.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6),
                    tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                cell = c
            }
            cell?.textField?.stringValue = targets[row].display
            return cell
        }
    }

    nonisolated func tableViewSelectionDidChange(_ notification: Notification) {
        MainActor.assumeIsolated {
            let row = table?.selectedRow ?? -1
            guard row >= 0, row < targets.count else { return }
            let t = targets[row]
            if selected?.windowID != t.windowID { select(t) }
        }
    }
}

// MARK: - Persistent controller / isolated engine lifecycle

extension AppDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        engineSwitchWork?.cancel()
        pendingTimeout?.cancel()
        pendingSession?.stop()
        engineSession?.stop()
        pipeline?.stop()
    }

    func reportWorkerReadiness() {
        guard isEngineWorker, workerHasFrame, !workerReportedReady,
              offMode || (appleBackend ? workerHasFrame : lastEngineGenerated > 0) else { return }
        workerReportedReady = true
        emitWorkerEvent(["event": "ready", "window": interpWindow?.windowNumber ?? 0])
    }

    func sendLiveSettings() {
        guard usesEngineWorker else { return }
        let command: [String: Any] = ["command": "quality", "mode": reconstruct.rawValue,
            "sharpness": sharpenAmount, "badge": showBadge, "metalHUD": metalHUDEnabled]
        engineSession?.send(command)
        pendingSession?.send(command)
    }

    func applyEngineSettings(multiplier value: Int) {
        guard supportedMultipliers.contains(value), value != multiplier else { return }
        if value > 4 && !FileManager.default.fileExists(atPath: native.appendingPathComponent("liblsfg_extended.dylib").path) {
            multiplierPopup.selectItem(at: supportedMultipliers.firstIndex(of: multiplier) ?? 0)
            statusLabel.stringValue = "缺少扩展引擎，当前可选 2×、3×、4×"
            return
        }
        multiplier = value
        preferences.set(value, forKey: "multiplier")
        multiplierPopup.selectItem(at: supportedMultipliers.firstIndex(of: value) ?? 0)
        scheduleEngineSwitch()
    }

    func scheduleEngineSwitch() {
        rebuildStatusMenu()
        guard usesEngineWorker, running || starting else {
            statusLabel.stringValue = "设置已保存，下次开始时使用"
            return
        }
        // Coalesce fast clicks. An obsolete warm-up must never replace the selected configuration.
        engineSwitchWork?.cancel()
        pendingTimeout?.cancel()
        pendingSession?.stop(); pendingSession = nil
        if let _ = engineSession, multiplier == appliedMultiplier,
           performanceMode == appliedPerformance, mode == appliedMode {
            starting = false
            statusLabel.stringValue = "设置已生效"
            return
        }
        starting = true
        statusLabel.stringValue = "正在后台应用设置…"
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.startEngineSession() }
        }
        engineSwitchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func startEngineSession() {
        guard usesEngineWorker, pendingSession == nil,
              let target = activeTarget ?? selected else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            starting = false
            startButton.title = "开始插帧"
            statusLabel.stringValue = "需要屏幕录制权限，授权后请重新打开本应用"
            if hasFlag("--control-stdin") { emitWorkerEvent(["event": "error", "message": statusLabel.stringValue]) }
            return
        }
        let session = EngineSession()
        let requestedMultiplier = multiplier
        let requestedPerformance = performanceMode
        let requestedMode = mode
        var args = ["--engine-worker", "--window-id", String(target.windowID), "--autostart",
                    "--multiplier", String(multiplier), "--mode", mode == .window ? "window" : "display",
                    performanceMode ? "--performance" : "--quality",
                    "--reconstruct", reconstruct.rawValue, "--reconstruct-sharp", String(sharpenAmount),
                    "--target-fps", String(targetFPS)]
        args += ["--backend", appleBackend ? "apple" : "lsfg"]
        if offMode { args.append("--off") }
        for flag in ["--test-window", "--native-fullscreen", "--ignore-pixel-cap", "--diagnostics",
                     "--reconstruct-thru-mid", "--solid", "--no-space-switch", "--limit-capture-pixels"] where hasFlag(flag) { args.append(flag) }
        for key in ["--test-x", "--test-y", "--test-w", "--test-h", "--queue-depth", "--drawable-count",
                    "--overlay-alpha", "--dump-output"] {
            if let value = argument(key) { args += [key, value] }
        }
        for value in arguments(named: "--engine-env") { args += ["--engine-env", value] }
        if let active = engineSession {
            args += ["--warm-switch", "--below-window", String(workerOutputWindow)]
            logLine("engine: switch old=\(active.pid) requested=\(requestedMultiplier)x performance=\(requestedPerformance)")
        }
        settingsError = ""
        starting = true
        pendingSession = session
        startButton.title = running ? "停止插帧" : "取消启动"
        statusLabel.stringValue = running ? "正在后台切换引擎，保留当前画面…" : "正在启动插帧引擎…"
        session.onEvent = { [weak self, weak session] event in
            MainActor.assumeIsolated {
                guard let self, let session else { return }
                let type = event["event"] as? String ?? ""
                if self.pendingSession === session {
                    if type == "ready" {
                        self.pendingTimeout?.cancel(); self.pendingTimeout = nil
                        let previous = self.engineSession
                        self.engineSession = session
                        self.pendingSession = nil
                        self.activeTarget = target
                        self.appliedMultiplier = requestedMultiplier
                        self.appliedPerformance = requestedPerformance
                        self.appliedMode = requestedMode
                        self.workerOutputWindow = event["window"] as? Int ?? 0
                        self.running = true; self.starting = false
                        self.remoteFrames = 0; self.remoteDropped = 0; self.remoteFPS = 0; self.engineOutFPS = 0
                        self.startButton.title = "停止插帧"
                        self.sendLiveSettings()
                        session.send(["command": "activate", "paused": self.paused, "revision": self.pauseRevision])
                        previous?.stop()
                        logLine("engine: ready controller=\(getpid()) worker=\(session.pid) multiplier=\(requestedMultiplier) performance=\(requestedPerformance)")
                        self.statusLabel.stringValue = "设置已生效 · \(requestedMultiplier)×"
                        self.rebuildStatusMenu()
                        if hasFlag("--control-stdin") {
                            emitWorkerEvent(["event": "applied", "controller": getpid(), "worker": session.pid,
                                             "backend": appleBackend ? "apple" : "lsfg",
                                             "multiplier": requestedMultiplier, "performance": requestedPerformance,
                                             "mode": requestedMode.rawValue])
                        }
                        self.scheduleParentPauseTest()
                    } else if type == "error" || type == "stopped" {
                        self.failPendingSession(event["message"] as? String ?? "后台采集未能启动")
                    }
                    return
                }
                guard self.engineSession === session else { return }
                switch type {
                case "stats":
                    self.remoteFrames = event["frames"] as? Int ?? 0
                    self.remoteDropped = event["dropped"] as? Int ?? 0
                    self.remoteFPS = event["fps"] as? Double ?? 0
                    self.engineOutFPS = event["outputFPS"] as? Double ?? 0
                    if event["pauseRevision"] as? Int == self.pauseRevision {
                        self.paused = event["paused"] as? Bool ?? self.paused
                    }
                    if hasFlag("--control-stdin") {
                        var report = event
                        report["worker"] = session.pid
                        report["controllerPaused"] = self.paused
                        report["controllerPauseRevision"] = self.pauseRevision
                        emitWorkerEvent(report)
                    }
                case "stopped", "error":
                    self.stopInterpolation()
                    if let message = event["message"] as? String { self.statusLabel.stringValue = message }
                case "showControl": self.showControl()
                default: break
                }
            }
        }
        session.onDiagnostic = { [weak session] line in
            logLine("worker[\(session?.pid ?? 0)]: \(line)")
            if hasFlag("--diagnostics") || hasFlag("--test-seconds") { print(line) }
        }
        session.onExit = { [weak self, weak session] code in
            MainActor.assumeIsolated {
                guard let self, let session else { return }
                if self.pendingSession === session { self.failPendingSession("引擎退出（\(code)）") }
                else if self.engineSession === session {
                    self.stopInterpolation()
                    self.statusLabel.stringValue = "引擎已退出（\(code)），可重新开始"
                }
            }
        }
        do {
            try session.start(executable: arguments[0], arguments: args)
            if hasFlag("--control-stdin") { emitWorkerEvent(["event": "warming", "worker": session.pid]) }
            sendLiveSettings()
            let timeout = DispatchWorkItem { [weak self, weak session] in
                MainActor.assumeIsolated {
                    guard let self, let session, self.pendingSession === session else { return }
                    self.failPendingSession("等待新引擎画面超时，请确认源窗口仍在渲染")
                }
            }
            pendingTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        } catch { failPendingSession(error.localizedDescription) }
    }

    func failPendingSession(_ message: String) {
        pendingTimeout?.cancel(); pendingTimeout = nil
        pendingSession?.stop(); pendingSession = nil
        starting = false
        if engineSession != nil {
            multiplier = appliedMultiplier; performanceMode = appliedPerformance; mode = appliedMode
            preferences.set(multiplier, forKey: "multiplier")
            preferences.set(performanceMode, forKey: "performanceMode")
            preferences.set(mode.rawValue, forKey: "mode")
            multiplierPopup.selectItem(at: supportedMultipliers.firstIndex(of: multiplier) ?? 0)
            perfModeCheck.state = appleBackend || performanceMode ? .on : .off
            modePopup.selectItem(at: mode.rawValue)
        }
        startButton.title = running ? "停止插帧" : "开始插帧"
        statusLabel.stringValue = "设置未应用：\(message)" + (running ? "；继续使用原引擎" : "")
        settingsError = message
        logLine("engine: \(statusLabel.stringValue)")
        rebuildStatusMenu()
        if hasFlag("--control-stdin") { emitWorkerEvent(["event": "error", "message": statusLabel.stringValue]) }
    }

    func receiveWorkerCommand(_ command: [String: Any]) {
        let name = command["command"] as? String ?? ""
        if usesEngineWorker { // Explicit diagnostic control channel, never enabled in normal launches.
            switch name {
            case "multiplier": applyEngineSettings(multiplier: command["value"] as? Int ?? 2)
            case "performance":
                guard !appleBackend else { return }
                performanceMode = command["value"] as? Bool ?? false
                preferences.set(performanceMode, forKey: "performanceMode")
                perfModeCheck.state = performanceMode ? .on : .off
                scheduleEngineSwitch()
            case "mode":
                modePopup.selectItem(at: command["value"] as? Int ?? 0); modeChanged()
            case "quality":
                if let value = command["mode"] as? String,
                   let mode = ReconstructMode(rawValue: value),
                   let index = ReconstructMode.allCases.firstIndex(of: mode) { reconstructPopup.selectItem(at: index) }
                if let value = command["sharpness"] as? Double { sharpnessSlider.doubleValue = value }
                reconstructionChanged()
            case "pause": setPaused(command["value"] as? Bool ?? false)
            case "start": startInterpolation()
            case "stop": stopInterpolation()
            case "quit": NSApplication.shared.terminate(nil)
            default: break
            }
            return
        }
        switch name {
        case "activate":
            pauseRevision = command["revision"] as? Int ?? pauseRevision
            workerActivated = true
            interpWindow?.alphaValue = workerOutputAlpha
            interpWindow?.orderFrontRegardless()
            if overlayActive, let window = interpWindow { showGameHUD(overlayFrame: window.frame) }
            if command["paused"] as? Bool == true { setPaused(true) }
        case "quality":
            if let value = command["mode"] as? String, let mode = ReconstructMode(rawValue: value) { reconstruct = mode }
            if let value = command["sharpness"] as? Double { sharpenAmount = Float(min(max(value, 0), 1)) }
            if let value = command["badge"] as? Bool { showBadge = value }
            if let value = command["metalHUD"] as? Bool { metalHUDEnabled = value }
            pipeline?.reconstruct = reconstruct
            pipeline?.sharpenAmount = sharpenAmount
            badge?.isHidden = !showBadge || !floatingControlsVisible
            applyMetalHUD()
        case "pause":
            pauseRevision = command["revision"] as? Int ?? pauseRevision
            setPaused(command["value"] as? Bool ?? false)
        case "stop": stopInterpolation(); NSApplication.shared.terminate(nil)
        default: break
        }
    }

    func scheduleParentPauseTest() {
        guard !pauseTestScheduled, let raw = argument("--test-pause"), let delay = Double(raw) else { return }
        pauseTestScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.setPaused(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self?.setPaused(false) }
        }
    }
}

// MARK: - 入口

let application = NSApplication.shared
application.setActivationPolicy(isEngineWorker ? .accessory : .regular)
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.run()
