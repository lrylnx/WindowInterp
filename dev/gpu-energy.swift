// dev/gpu-energy.swift — 直接读 GPU 能耗（不需要 root）
//
// 为什么需要它：
//   * `powermetrics` 要 root，自动化环境里拿不到；
//   * 靠电池放电电流 × 电压估整机功耗噪声太大（电池计的 InstantAmperage 更新慢，
//     实测同一负载两次读数能差一倍，插拔电源/充电状态还会污染）；
//   * GPU 的 "Device Utilization %" 也不是功耗 —— 它是「有工作在跑的时间占比」，
//     分辨率降了 44% 它照样显示 94%，完全不能用来判断省了多少电。
//
// IOReport 的 "Energy Model" 组里有一个 "GPU Energy" 通道，是 GPU 累计消耗的能量。
// 两次采样求差再除以时间，就是这段区间的**平均功率（瓦）**。这是 powermetrics 背后
// 用的同一份数据，只是不需要特权。
//
// 用法: ./dev/gpu-energy <秒数> [标签]

import Foundation
import CoreFoundation

typealias IOReportSubscriptionRef = OpaquePointer

@_silgen_name("IOReportCopyChannelsInGroup")
func IOReportCopyChannelsInGroup(_ group: CFString, _ subgroup: CFString?,
                                 _ a: UInt64, _ b: UInt64, _ c: UInt64) -> CFMutableDictionary?

@_silgen_name("IOReportCreateSubscription")
func IOReportCreateSubscription(_ a: UnsafeMutableRawPointer?, _ desired: CFMutableDictionary,
                                _ subbed: UnsafeMutablePointer<CFMutableDictionary?>?,
                                _ channel: UInt64, _ b: UnsafeMutableRawPointer?) -> IOReportSubscriptionRef?

@_silgen_name("IOReportCreateSamples")
func IOReportCreateSamples(_ sub: IOReportSubscriptionRef?, _ channels: CFMutableDictionary,
                           _ a: CFTypeRef?) -> CFDictionary?

@_silgen_name("IOReportCreateSamplesDelta")
func IOReportCreateSamplesDelta(_ a: CFDictionary, _ b: CFDictionary, _ c: CFTypeRef?) -> CFDictionary?

@_silgen_name("IOReportChannelGetGroup")
func IOReportChannelGetGroup(_ d: CFDictionary) -> CFString?

@_silgen_name("IOReportChannelGetChannelName")
func IOReportChannelGetChannelName(_ d: CFDictionary) -> CFString?

@_silgen_name("IOReportChannelGetUnitLabel")
func IOReportChannelGetUnitLabel(_ d: CFDictionary) -> CFString?

@_silgen_name("IOReportSimpleGetIntegerValue")
func IOReportSimpleGetIntegerValue(_ d: CFDictionary, _ i: Int32) -> Int64

/// 取出一个 samples/channels 字典里的通道数组
func channelArray(_ dict: CFDictionary) -> [CFDictionary] {
    let ns = dict as NSDictionary
    guard let arr = ns["IOReportChannels"] as? NSArray else { return [] }
    return arr.compactMap { $0 as? NSDictionary as CFDictionary? }
}

struct Reading {
    var gpu: Double = 0     // 焦耳（区间内累计）
    var cpu: Double = 0
    var ane: Double = 0
    var dram: Double = 0
    var raw: [String: Int64] = [:]
    var units: [String: String] = [:]
}

func sample(_ sub: IOReportSubscriptionRef, _ channels: CFMutableDictionary) -> CFDictionary? {
    IOReportCreateSamples(sub, channels, nil)
}

/// 单位标签 → 换算到焦耳的系数
func joulesScale(_ unit: String) -> Double {
    let u = unit.lowercased()
    if u.contains("nanojoule") || u == "nj" { return 1e-9 }
    if u.contains("microjoule") || u == "uj" { return 1e-6 }
    if u.contains("millijoule") || u == "mj" { return 1e-3 }
    if u.contains("joule") || u == "j" { return 1.0 }
    return 1.0        // 未知单位时按原始值处理，由调用方打印出来人工判断
}

/// 通道分类。**必须白名单精确匹配**：这一组里同一个东西有好几个别名和细分域，
/// 按关键字包含去累加会重复计数 —— 实测「GPU」「GPU Energy」「GPU SRAM」是同一份
/// 数据的三种写法（mJ 与 nJ 各一份），而 CPU 侧还有 PCPUDTL* 这类按电压域的细分，
/// 混进去能把 CPU 从 0.44 W 虚报成 1.8 W。
func classify(_ name: String) -> String? {
    if name == "GPU" || name == "GPU SRAM" { return "gpu" }
    if name == "ANE" { return "ane" }
    if name == "DRAM" { return "dram" }
    if name == "ECPM" || name == "PCPM" || name == "ECPM_SRAM" || name == "PCPM_SRAM" { return "cpu" }
    if name.range(of: "^(E|P)CPU[0-9]+(_SRAM)?$", options: .regularExpression) != nil { return "cpu" }
    return nil
}

func parse(_ delta: CFDictionary) -> Reading {
    var r = Reading()
    for ch in channelArray(delta) {
        let name = (IOReportChannelGetChannelName(ch) as String?) ?? ""
        let unit = (IOReportChannelGetUnitLabel(ch) as String?) ?? ""
        let v = IOReportSimpleGetIntegerValue(ch, 0)
        r.raw[name] = v
        r.units[name] = unit
        guard let kind = classify(name) else { continue }
        let joules = Double(v) * joulesScale(unit)
        switch kind {
        case "gpu": r.gpu += joules
        case "cpu": r.cpu += joules
        case "ane": r.ane += joules
        case "dram": r.dram += joules
        default: break
        }
    }
    return r
}

let argv = CommandLine.arguments
let seconds = Double(argv.count > 1 ? argv[1] : "10") ?? 10
let label = argv.count > 2 ? argv[2] : "未命名"

guard let channels = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0) else {
    print("\(label): 拿不到 Energy Model 通道（这台机器可能不支持）")
    exit(1)
}
var subbed: CFMutableDictionary?
guard let sub = IOReportCreateSubscription(nil, channels, &subbed, 0, nil), let subbed else {
    print("\(label): 订阅失败")
    exit(1)
}

if ProcessInfo.processInfo.environment["GPU_ENERGY_DUMP"] != nil {
    for ch in channelArray(subbed) {
        let n = (IOReportChannelGetChannelName(ch) as String?) ?? "?"
        let u = (IOReportChannelGetUnitLabel(ch) as String?) ?? "?"
        let g = (IOReportChannelGetGroup(ch) as String?) ?? "?"
        print("  channel \(n)  unit=\(u)  group=\(g)  value=\(IOReportSimpleGetIntegerValue(ch, 0))")
    }
}

guard let a = sample(sub, subbed) else { print("\(label): 采样失败"); exit(1) }
let t0 = Date()
Thread.sleep(forTimeInterval: seconds)
guard let b = sample(sub, subbed) else { print("\(label): 采样失败"); exit(1) }
let dt = Date().timeIntervalSince(t0)

guard let delta = IOReportCreateSamplesDelta(a, b, nil) else { print("\(label): 差值失败"); exit(1) }
let r = parse(delta)

func watts(_ j: Double) -> Double { dt > 0 ? j / dt : 0 }

print(String(format: "%@  GPU %6.2f W   CPU %6.2f W   ANE %5.2f W   DRAM %5.2f W   (窗口 %.1fs)",
             label, watts(r.gpu), watts(r.cpu), watts(r.ane), watts(r.dram), dt))
if ProcessInfo.processInfo.environment["GPU_ENERGY_VERBOSE"] != nil {
    for (name, v) in r.raw.sorted(by: { $0.key < $1.key }) {
        print("    \(name) = \(v) \(r.units[name] ?? "")")
    }
}
