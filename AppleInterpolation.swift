import Foundation
import CoreMedia
import CoreVideo
import CoreImage
import VideoToolbox
import QuartzCore
import Darwin

/// One serial owner, including all conversions and session teardown.
/// Requests uniformly spaced native phases in one processor call.
final class AppleFrameInterpolator {
    private var processor: NSObject?
    private var inputPool: CVPixelBufferPool?
    private var outputPool: CVPixelBufferPool?
    private var originalPool: CVPixelBufferPool?
    private var transfer: VTPixelTransferSession?
    private(set) var size = CGSize.zero

    private let multiplier: Int
    private let cascade: Bool

    init(width: Int, height: Int, multiplier: Int = 2, videoQuality: Bool = false) throws {
        guard [2, 4].contains(multiplier) else { throw Self.error("苹果原生支持 2× 或 4×") }
        self.multiplier = multiplier
        cascade = videoQuality && multiplier == 4
        guard WIAppleSupported() else { throw Self.error("此系统或芯片不支持苹果低延迟插帧，需要 macOS 26 或更新系统") }
        // Generic mode uses a conservative 720p budget; video on macOS27+
        // can retain up to Full HD. These are performance budgets, not hardware limits.
        let budget = videoQuality && ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)) ? 2_073_600.0 : 921_600.0
        let scale = min(1, sqrt(budget / Double(width * height)))
        let alignment = videoQuality && scale == 1 ? 2 : 16
        let w = max(64, Int(Double(width) * scale) / alignment * alignment)
        let h = max(64, Int(Double(height) * scale) / alignment * alignment)
        guard let config = WIAppleConfigurationForMultiplier(w, h, cascade ? 2 : multiplier), let p = WIAppleProcessor() else {
            throw Self.error("无法创建苹果低延迟插帧配置")
        }
        if let error = WIAppleStart(p, config) { throw error }
        processor = p
        do {
            inputPool = try Self.pool(WIAppleAttributes(config, false) as NSDictionary)
            outputPool = try Self.pool(WIAppleAttributes(config, true) as NSDictionary)
            originalPool = try Self.pool([
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ] as NSDictionary)
            guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) == noErr else {
                throw Self.error("无法创建苹果像素转换会话")
            }
        } catch { WIAppleEnd(p); processor = nil; throw error }
        size = CGSize(width: w, height: h)
    }

    deinit {
        if let processor { WIAppleEnd(processor) }
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "WindowInterp.Apple", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func pool(_ attributes: NSDictionary) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess,
              let pool else { throw error("无法创建苹果插帧缓冲池") }
        return pool
    }

    private func buffer(_ pool: CVPixelBufferPool?, limit: Int = 12) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard let pool,
              CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
                [kCVPixelBufferPoolAllocationThresholdKey as String: limit] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw Self.error("苹果插帧缓冲池已满") }
        return buffer
    }

    // Never retain SCK's small IOSurface pool through the playout delay. Owning a
    // full-resolution copy frees capture slots immediately after this request.
    func copyOriginal(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let destination = try buffer(originalPool)
        guard let transfer,
              VTPixelTransferSessionTransferImage(transfer, from: source, to: destination) == noErr else {
            throw Self.error("无法复制窗口捕获帧")
        }
        return destination
    }

    func convert(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let destination = try buffer(inputPool)
        guard let transfer,
              VTPixelTransferSessionTransferImage(transfer, from: source, to: destination) == noErr else {
            throw Self.error("窗口图像无法转换为苹果插帧格式")
        }
        return destination
    }

    /// VTPixelTransfer Normal stretches the full raster to the aligned working
    /// size. Undo both axes exactly; aspect-fitting this raster changes geometry
    /// on every interpolated frame (e.g. 640x360 -> 640x352).
    static func displayImage(_ buffer: CVPixelBuffer, canvas: CGSize) -> CIImage {
        let image = CIImage(cvPixelBuffer: buffer)
        let e = image.extent
        let normalized = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        let sx = canvas.width / e.width, sy = canvas.height / e.height
        guard abs(sx - 1) > 0.00001 || abs(sy - 1) > 0.00001 else { return normalized }
        return normalized.applyingFilter("CILanczosScaleTransform", parameters: [
            "inputScale": sy, "inputAspectRatio": sx / sy
        ]).cropped(to: CGRect(origin: .zero, size: canvas))
    }

    func midpoint(previous: CVPixelBuffer, previousPTS: CMTime,
                  current: CVPixelBuffer, currentPTS: CMTime) throws -> CVPixelBuffer {
        guard multiplier == 2 else { throw Self.error("midpoint 仅适用于 2× 会话") }
        return try intermediates(previous: previous, previousPTS: previousPTS, current: current, currentPTS: currentPTS)[0]
    }

    func intermediates(previous: CVPixelBuffer, previousPTS: CMTime,
                       current: CVPixelBuffer, currentPTS: CMTime) throws -> [CVPixelBuffer] {
        // Up to 16 scheduled outputs plus the active triple and in-flight renders.
        // Keep the pool bounded, with enough headroom for 144Hz delayed playout.
        if cascade {
            guard let processor else { throw Self.error("苹果插帧会话未启动") }
            let middle = try buffer(outputPool, limit: 24)
            let quarter = try buffer(outputPool, limit: 24)
            let last = try buffer(outputPool, limit: 24)
            let mt = CMTimeAdd(previousPTS, CMTimeMultiplyByFloat64(CMTimeSubtract(currentPTS, previousPTS), multiplier: 0.5))
            if let e = WIAppleInterpolate(processor, previous, previousPTS, current, currentPTS, middle) { throw e }
            if let e = WIAppleInterpolate(processor, previous, previousPTS, middle, mt, quarter) { throw e }
            if let e = WIAppleInterpolate(processor, middle, mt, current, currentPTS, last) { throw e }
            return [quarter, middle, last]
        }
        let destinations = try (1..<multiplier).map { _ in try buffer(outputPool, limit: multiplier == 4 ? 24 : 12) }
        guard let processor else { throw Self.error("苹果插帧会话未启动") }
        if let error = WIAppleInterpolateFrames(processor, previous, previousPTS, current, currentPTS, destinations as CFArray) { throw error }
        return destinations
    }
}

/// Preserve source detail only where both reference frames and the low-frequency
/// interpolated scene agree. The second guard protects a moving object crossing
/// pixels which happen to be identical in the two endpoints.
final class StaticDetailPreserver {
    // Max-pool differences, not colors: a thin moving line cannot disappear
    // through averaging/cancellation before the conservative motion test.
    private static let tiledMotion = CIKernel(source: """
        kernel vec4 tiledMotion(sampler a, sampler b) {
            vec2 base = floor(destCoord()) * 4.0;
            float delta = 0.0;
            for (int y = 0; y < 4; y++) {
                for (int x = 0; x < 4; x++) {
                    vec2 p = base + vec2(float(x) + 0.5, float(y) + 0.5);
                    vec3 d = abs(sample(a, samplerTransform(a, p)).rgb - sample(b, samplerTransform(b, p)).rgb);
                    delta = max(delta, max(d.r, max(d.g, d.b)));
                }
            }
            float m = smoothstep(0.001, 0.008, delta);
            return vec4(m, m, m, 1.0);
        }
        """)
    private static let difference = CIColorKernel(source: """
        kernel vec4 difference(__sample a, __sample b, float low, float high) {
            vec3 d = abs(a.rgb - b.rgb);
            float m = smoothstep(low, high, max(d.r, max(d.g, d.b)));
            return vec4(m, m, m, 1.0);
        }
        """)
    private static let combine = CIColorKernel(source: """
        kernel vec4 combine(__sample original, __sample middle, __sample motion, __sample crossing) {
            float m = max(motion.r, crossing.r);
            return vec4(mix(original.rgb, middle.rgb, m), original.a);
        }
        """)

    // Low-contrast changes need the correct point in time even when the
    // conservative motion mask chooses source detail instead of optical flow.
    private static let temporalReference = CIColorKernel(source: """
        kernel vec4 temporalReference(__sample a, __sample b, float phase) {
            return mix(a, b, phase);
        }
        """)

    func preserve(previous: CIImage, current: CIImage, middle: CIImage, phase: Double = 0.5) throws -> CIImage {
        let bounds = current.extent
        guard let reference = Self.temporalReference?.apply(extent: bounds,
            arguments: [previous, current, min(1, max(0, phase))]) else {
            throw AppleFrameInterpolator.error("无法创建对应时间点的细节参考帧")
        }
        let smallBounds = CGRect(x: 0, y: 0, width: ceil(bounds.width / 4), height: ceil(bounds.height / 4))
        guard let difference = Self.difference, let combine = Self.combine, let tiledMotion = Self.tiledMotion,
              let changed = tiledMotion.apply(extent: smallBounds, roiCallback: { _, rect in
                  rect.applying(CGAffineTransform(scaleX: 4, y: 4)).insetBy(dx: -4, dy: -4)
              }, arguments: [previous.clampedToExtent(), current.clampedToExtent()]) else {
            throw AppleFrameInterpolator.error("无法创建静态细节保护处理器")
        }
        let motion = changed.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 2.0])
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 0.5]).cropped(to: smallBounds)
            .transformed(by: CGAffineTransform(scaleX: 4, y: 4))
        func lowFrequency(_ image: CIImage) -> CIImage {
            image.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": 0.25, "inputAspectRatio": 1.0])
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 0.75]).cropped(to: smallBounds)
        }
        guard let crossingSmall = difference.apply(extent: smallBounds, arguments: [lowFrequency(reference), lowFrequency(middle), 0.01, 0.03]),
              let result = combine.apply(extent: bounds, arguments: [reference, middle, motion,
                crossingSmall.transformed(by: CGAffineTransform(scaleX: 4, y: 4))]) else {
            throw AppleFrameInterpolator.error("静态细节保护无法生成输出")
        }
        return result.cropped(to: bounds)
    }
}

enum VideoFrameIdentity {
    static func equal(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Bool {
        let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
        guard w == CVPixelBufferGetWidth(b), h == CVPixelBufferGetHeight(b),
              CVPixelBufferGetPixelFormatType(a) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(b) == kCVPixelFormatType_32BGRA else { return false }
        guard CVPixelBufferLockBaseAddress(a, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly) }
        guard CVPixelBufferLockBaseAddress(b, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        guard let ap = CVPixelBufferGetBaseAddress(a), let bp = CVPixelBufferGetBaseAddress(b) else { return false }
        let ar = CVPixelBufferGetBytesPerRow(a), br = CVPixelBufferGetBytesPerRow(b)
        for y in stride(from: 0, to: h, by: max(1, h/32)) {
            for x in stride(from: 0, to: w, by: max(1, w/64)) {
                if memcmp(ap+y*ar+x*4, bp+y*br+x*4, 4) != 0 { return false }
            }
        }
        for y in 0..<h { if memcmp(ap+y*ar, bp+y*br, w*4) != 0 { return false } }
        return true
    }
}

/// Estimates visible content cadence. It does not read decoder metadata.
/// Multiple interior regions must agree, so an animated browser control alone
/// cannot select a cadence for the whole window.
struct AutomaticVideoCadence {
    private var history = [[Double]](repeating: [], count: 6)
    private var previous: [[UInt8]]?
    private var lastTime = 0.0
    private var lastEvaluation = -Double.infinity
    private var pending = 0
    private var pendingSince = 0.0
    private var lastSupported = 0.0
    private(set) var fps = 0
    private(set) var confidence = 0.0

    mutating func observe(samples: [[UInt8]], at time: Double) {
        guard samples.count == 6 else { return }
        let changed: [Bool]
        if let old = previous, old.count == samples.count {
            changed = zip(old, samples).map { a,b in
                guard a.count == b.count && !a.isEmpty else { return false }
                var count=0, difference=0
                for (x,y) in zip(a,b) {
                    let delta=abs(Int(x)-Int(y)); difference += delta
                    if delta>2 { count += 1 }
                }
                return count >= max(6,a.count/100) && difference > a.count/5
            }
        } else { changed = Array(repeating:false,count:6) }
        previous=samples
        observe(changed: changed, at: time)
    }

    mutating func observe(changed: [Bool], at time: Double) {
        guard time.isFinite, changed.count == 6 else { return }
        if lastTime > 0 && (time <= lastTime || time-lastTime > 2) {
            history = Array(repeating:[],count:6); pending=0; lastEvaluation = -Double.infinity
        }
        lastTime=time
        for i in 0..<6 {
            if changed[i] { history[i].append(time) }
            history[i].removeAll { time-$0 > 3.5 }
        }
        guard time-lastEvaluation >= 0.3 else { return }
        lastEvaluation=time
        var votes:[Int:[Double]] = [:]
        for events in history {
            guard events.count >= 32, let start=events.first, let end=events.last, end-start >= 1.4 else { continue }
            let rate=Double(events.count-1)/(end-start)
            let scores=[24,25,30].map { candidate -> (Int,Double) in
                guard rate <= Double(candidate)*1.12 else { return (candidate,0) }
                var x=0.0,y=0.0
                for t in events {
                    let phase=2*Double.pi*Double(candidate)*(t-start)
                    x += cos(phase); y += sin(phase)
                }
                return (candidate,sqrt(x*x+y*y)/Double(events.count))
            }.sorted { $0.1 > $1.1 }
            if scores[0].1 >= 0.44 && scores[0].1-scores[1].1 >= 0.12 {
                votes[scores[0].0,default:[]].append(scores[0].1)
            }
        }
        let winner=votes.filter { $0.value.count >= 2 }.max {
            $0.value.reduce(0,+) < $1.value.reduce(0,+)
        }
        if let winner {
            confidence=winner.value.reduce(0,+)/Double(winner.value.count)
            if winner.key == fps { lastSupported=time; pending=0; return }
            if pending != winner.key { pending=winner.key; pendingSince=time }
            let settle=fps == 0 ? 0.9 : 1.8
            if time-pendingSince >= settle {
                fps=winner.key; lastSupported=time; pending=0
            }
        } else {
            confidence=0; pending=0
            // Keep the last cadence during a still scene. Clear it when sustained
            // motion no longer supports it, e.g. scrolling or changing videos.
            let active=history.filter { events in
                events.filter { time-$0 < 1.5 }.count >= 20
            }.count
            if fps != 0 && active >= 2 && time-lastSupported > 6 { fps=0 }
        }
    }

    static func samples(_ buffer: CVPixelBuffer) -> [[UInt8]] {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer,.readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
        guard let base=CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to:UInt8.self) else { return [] }
        let w=CVPixelBufferGetWidth(buffer), h=CVPixelBufferGetHeight(buffer), row=CVPixelBufferGetBytesPerRow(buffer)
        guard w>8,h>8 else { return [] }
        return (0..<6).map { tile in
            var values:[UInt8]=[]; values.reserveCapacity(16*9*3)
            for y in 0..<9 { for x in 0..<16 {
                let fx=0.12+(Double(tile%3)+(Double(x)+0.5)/16)*0.76/3
                let fy=0.14+(Double(tile/3)+(Double(y)+0.5)/9)*0.72/2
                let index=min(h-1,Int(Double(h)*fy))*row+min(w-1,Int(Double(w)*fx))*4
                values.append(base[index]); values.append(base[index+1]); values.append(base[index+2])
            } }
            return values
        }
    }
}

/// A declared video cadence, not a claim to recover decoder timestamps. Capture
/// phase jitter is removed; stalls/seeks and late timelines re-anchor explicitly.
struct VideoCadenceClock {
    let fps: Double
    private var origin: Double?
    private var index = 0
    private var lastCapture = 0.0
    init(fps: Double) { self.fps = fps }
    mutating func advance(_ capture: Double) -> (time: Double, gap: Int, reset: Bool) {
        guard let start = origin, capture > lastCapture, capture-lastCapture <= 0.5 else {
            origin = capture; index = 0; lastCapture = capture
            return (capture, 1, true)
        }
        let predicted = index + max(1, Int(((capture-lastCapture)*fps).rounded()))
        let causalLimit = max(index, Int(floor((capture-start)*fps+0.75)))
        let next = min(predicted, causalLimit)
        let gap = next-index
        if gap > 0 { index = next; lastCapture = capture }
        return (start+Double(next)/fps, gap, false)
    }
    mutating func reset() { origin = nil; index = 0; lastCapture = 0 }
}

/// A latest-input mailbox bounds latency while the hardware is busy. Presentation is
/// independently scheduled using source timestamps: A, midpoint(A,B), B, ... .
final class AppleInterpolationStream {
    private let queue = DispatchQueue(label: "windowinterp.apple.interpolation", qos: .userInteractive)
    private let lock = NSLock()
    private let multiplier: Int

    private let videoFPS: Double
    private var detector=AutomaticVideoCadence()
    private var automaticFPS=0
    private var activeVideoFPS: Double
    private var videoClock: VideoCadenceClock
    private var videoPrevious: (original: CVPixelBuffer, converted: CVPixelBuffer, time: Double)?
    private var videoFallback = false
    private var duplicateFrames = 0
    private var uniqueFrames = 0
    private var uniqueWindow = CACurrentMediaTime()
    private var uniqueRate = 0.0
    private var lastUnique = 0.0
    private var timelineResets = 0

    init(multiplier: Int = 2, videoFPS: Double = 0) {
        self.multiplier = multiplier; self.videoFPS = videoFPS
        activeVideoFPS = max(0,videoFPS)
        videoClock = VideoCadenceClock(fps: max(1, videoFPS))
    }

    var cadenceStats: (uniqueFPS: Double, duplicates: Int, resets: Int, detectedFPS: Double) {
        lock.lock(); defer { lock.unlock() }
        return (CACurrentMediaTime()-lastUnique < 1.5 ? uniqueRate : 0, duplicateFrames, timelineResets, videoFPS < 0 ? Double(automaticFPS) : videoFPS)
    }

    private let detailPreserver = StaticDetailPreserver()
    private var pending: (CVPixelBuffer, CMTime)?
    private var busy = false
    private var stopped = false
    private var generated = 0
    private var replaced = 0
    private var processingMS = 0.0
    private var inputFrames = 0
    private var inputWindow = CACurrentMediaTime()
    private var inputRate = 0.0
    private var lastInput = 0.0
    private var workSize = CGSize.zero
    private var engine: AppleFrameInterpolator?
    private var sourceSize = CGSize.zero
    private var previous: (original: CVPixelBuffer, converted: CVPixelBuffer, pts: CMTime)?
    private var anchorPTS = 0.0
    private var anchorHost = 0.0
    private var delay = 0.1
    private var firstPair = true
    var onOutput: ((CIImage, Double, Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onConfiguration: ((String) -> Void)?
    var onTimelineReset: (() -> Void)?

    var stats: (generated: Int, replaced: Int, processingMS: Double, size: CGSize, inputFPS: Double) {
        lock.lock(); defer { lock.unlock() }
        return (generated, replaced, processingMS, workSize, CACurrentMediaTime() - lastInput < 2 ? inputRate : 0)
    }

    func submit(_ buffer: CVPixelBuffer, pts: CMTime) {
        let activity = videoFPS < 0 ? AutomaticVideoCadence.samples(buffer) : []
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        if videoFPS < 0 {
            detector.observe(samples:activity,at:pts.seconds)
            automaticFPS=detector.fps
        }
        let now = CACurrentMediaTime()
        lastInput = now; inputFrames += 1
        if now - inputWindow >= 1 {
            inputRate = Double(inputFrames) / (now - inputWindow)
            inputFrames = 0; inputWindow = now
        }
        if pending != nil { replaced += 1 }
        pending = (buffer, pts)
        let start = !busy
        busy = true
        lock.unlock()
        if start { queue.async { [self] in drain() } }
    }

    func stop() {
        lock.lock(); stopped = true; pending = nil; lock.unlock()
        // Queued after an outstanding process; never endSession concurrently with it.
        queue.async { [self] in previous = nil; videoPrevious = nil; engine = nil }
    }

    private func drain() {
        while true {
            lock.lock()
            let input = stopped ? nil : pending
            pending = nil
            if input == nil { busy = false }
            lock.unlock()
            guard let (buffer, pts) = input else { return }
            autoreleasepool {
                do { try process(buffer, pts: pts) }
                catch {
                    lock.lock(); stopped = true; pending = nil; lock.unlock()
                    previous = nil; videoPrevious = nil; engine = nil
                    onError?("苹果 \(multiplier)× 插帧失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func hostAnchor(for timestamp: Double) -> Double {
        let now = CACurrentMediaTime()
        // SCK timestamps use the host clock. Mapping the first *processed* frame
        // to now adds model initialization time to every subsequent deadline.
        return abs(now - timestamp) < 10 ? timestamp : now
    }

    private func process(_ buffer: CVPixelBuffer, pts: CMTime) throws {
        if videoFPS != 0 { try processVideo(buffer, pts: pts); return }
        let timestamp = pts.seconds
        guard timestamp.isFinite else { return }
        let dimensions = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        if dimensions != sourceSize {
            previous = nil; engine = nil
            engine = try AppleFrameInterpolator(width: Int(dimensions.width), height: Int(dimensions.height), multiplier: multiplier)
            sourceSize = dimensions
            lock.lock(); workSize = engine!.size; lock.unlock()
            onConfiguration?("Apple VTLowLatencyFrameInterpolation \(multiplier)× · 采集 \(Int(dimensions.width))×\(Int(dimensions.height)) · 插帧 \(Int(engine!.size.width))×\(Int(engine!.size.height))")
        }
        guard let engine else { return }
        let original = try engine.copyOriginal(buffer)
        let converted = try engine.convert(buffer)
        defer { previous = (original, converted, pts) }
        guard let old = previous else {
            anchorPTS = timestamp; anchorHost = hostAnchor(for: timestamp); firstPair = true
            // Initial/static source can still be displayed without waiting for a second frame.
            onOutput?(CIImage(cvPixelBuffer: original), CACurrentMediaTime(), false)
            return
        }
        let interval = timestamp - old.pts.seconds
        guard interval > 0.001, interval <= 0.2 else {
            anchorPTS = timestamp; anchorHost = hostAnchor(for: timestamp); firstPair = true
            onTimelineReset?()
            onOutput?(CIImage(cvPixelBuffer: original), CACurrentMediaTime(), false)
            return
        }
        let started = CACurrentMediaTime()
        let middles = try engine.intermediates(previous: old.converted, previousPTS: old.pts, current: converted, currentPTS: pts)
        let elapsed = CACurrentMediaTime() - started
        lock.lock(); let cancelled = stopped; lock.unlock()
        guard !cancelled else { return }
        // Fixed playout delay per timeline; do not accumulate compute time every pair.
        // The first ML request can compile shaders and take hundreds of ms. Do not
        // turn that one-off cost into a permanent deep queue and recurring drops.
        if firstPair { delay = max(0.075, min(0.1, interval + 0.025)) }
        let due = anchorHost + old.pts.seconds - anchorPTS + delay
        if due + interval / Double(multiplier) < CACurrentMediaTime() - 0.02 {
            anchorPTS = timestamp; anchorHost = hostAnchor(for: timestamp); firstPair = true
            onTimelineReset?()
            onOutput?(CIImage(cvPixelBuffer: original), CACurrentMediaTime(), false)
            return
        }
        lock.lock(); generated += middles.count; processingMS = elapsed * 1000; lock.unlock()
        if firstPair { onOutput?(CIImage(cvPixelBuffer: old.original), due, false); firstPair = false }
        for (index, middle) in middles.enumerated() {
            let detailed = try detailPreserver.preserve(previous: CIImage(cvPixelBuffer: old.original),
                current: CIImage(cvPixelBuffer: original), middle: AppleFrameInterpolator.displayImage(middle, canvas: dimensions),
                phase: Double(index + 1) / Double(multiplier))
            onOutput?(detailed, due + interval * Double(index + 1) / Double(multiplier), true)
        }
        // A final B must still appear if the source becomes idle after this pair.
        onOutput?(CIImage(cvPixelBuffer: original), due + interval, false)
    }
    private func processVideo(_ buffer: CVPixelBuffer, pts: CMTime) throws {
        let capture = pts.seconds
        guard capture.isFinite else { return }
        lock.lock(); let selectedFPS = videoFPS < 0 ? Double(automaticFPS) : videoFPS; lock.unlock()
        if selectedFPS != activeVideoFPS {
            activeVideoFPS=selectedFPS; videoClock=VideoCadenceClock(fps:max(1,selectedFPS))
            videoPrevious=nil; firstPair=true
            onTimelineReset?()
            onConfiguration?(selectedFPS > 0 ? "自动视频已识别约 \(Int(selectedFPS))fps，恢复均匀节奏" : "自动视频正在识别，暂时显示捕获原帧")
        }
        let dimensions = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        if dimensions != sourceSize {
            videoPrevious = nil; engine = nil; videoClock.reset(); videoFallback = false
            do { engine = try AppleFrameInterpolator(width: Int(dimensions.width), height: Int(dimensions.height), multiplier: multiplier, videoQuality: true) }
            catch { videoFallback = true; engine = try AppleFrameInterpolator(width: Int(dimensions.width), height: Int(dimensions.height), multiplier: multiplier) }
            sourceSize = dimensions
            lock.lock(); workSize = engine!.size; lock.unlock()
            onConfiguration?("视频 \(activeVideoFPS > 0 ? "约\(Int(activeVideoFPS))fps" : "自动识别中") · 采集 \(Int(dimensions.width))×\(Int(dimensions.height)) · 插帧 \(Int(engine!.size.width))×\(Int(engine!.size.height)) · \(videoFallback ? "兼容模式" : "播放器级联路径")")
        }
        guard let engine else { return }
        if activeVideoFPS <= 0 {
            let original=try engine.copyOriginal(buffer)
            onOutput?(CIImage(cvPixelBuffer:original),CACurrentMediaTime(),false)
            return
        }
        if let old = videoPrevious, VideoFrameIdentity.equal(buffer, old.original) {
            lock.lock(); duplicateFrames += 1; lock.unlock()
            return
        }
        let original = try engine.copyOriginal(buffer), converted = try engine.convert(buffer)
        let tick = videoClock.advance(capture)
        if tick.gap == 0 { lock.lock(); replaced += 1; lock.unlock(); return }
        let now = CACurrentMediaTime()
        lock.lock()
        uniqueFrames += 1; lastUnique = now
        if now-uniqueWindow >= 1 { uniqueRate = Double(uniqueFrames)/(now-uniqueWindow); uniqueFrames = 0; uniqueWindow = now }
        lock.unlock()
        func output(_ pixelBuffer: CVPixelBuffer, _ due: Double, _ generated: Bool) {
            onOutput?(AppleFrameInterpolator.displayImage(pixelBuffer, canvas: dimensions), due, generated)
        }
        guard let old = videoPrevious, !tick.reset else {
            let resumingHold = videoPrevious != nil
            videoPrevious = (original, converted, tick.time)
            firstPair = true; anchorPTS = tick.time; anchorHost = hostAnchor(for: capture)
            onTimelineReset?()
            output(converted, now + (resumingHold ? 0.14 : 0), false)
            return
        }
        let interval = 1/activeVideoFPS
        // A true hold is displayed as a hold; never stretch its final motion
        // across the entire unchanged interval.
        let previousTime = tick.time-interval
        let started = CACurrentMediaTime()
        let middles: [CVPixelBuffer]
        do {
            middles = try engine.intermediates(previous: old.converted,
                previousPTS: CMTime(seconds: previousTime, preferredTimescale: 60_000), current: converted,
                currentPTS: CMTime(seconds: tick.time, preferredTimescale: 60_000))
        } catch {
            guard !videoFallback else { throw error }
            // Some configurations start successfully but fail on first process.
            // Retry once at the known conservative budget, and report the change.
            self.engine = nil; videoPrevious = nil; videoClock.reset(); videoFallback = true
            self.engine = try AppleFrameInterpolator(width: Int(dimensions.width), height: Int(dimensions.height), multiplier: multiplier)
            lock.lock(); workSize = self.engine!.size; lock.unlock()
            onTimelineReset?()
            onConfiguration?("视频原尺寸处理失败，已切换兼容插帧 \(Int(self.engine!.size.width))×\(Int(self.engine!.size.height))：\(error.localizedDescription)")
            return
        }
        videoPrevious = (original, converted, tick.time)
        lock.lock(); let cancelled = stopped; processingMS = (CACurrentMediaTime()-started)*1000; lock.unlock()
        guard !cancelled else { return }
        let due = anchorHost + previousTime-anchorPTS + 0.14
        if due < CACurrentMediaTime()-0.015 {
            videoClock.reset(); videoPrevious = nil
            lock.lock(); timelineResets += 1; lock.unlock()
            onTimelineReset?(); firstPair = true
            output(converted, CACurrentMediaTime(), false)
            return
        }
        if firstPair { output(old.converted, due, false); firstPair = false }
        lock.lock(); generated += middles.count; lock.unlock()
        // Originals and interpolated frames share the same YUV conversion and
        // scaling path. Video mode intentionally avoids the UI detail mask.
        for (index, middle) in middles.enumerated() {
            output(middle, due + interval*Double(index+1)/Double(multiplier), true)
        }
        output(converted, due+interval, false)
    }

}
