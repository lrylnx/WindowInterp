import Foundation
import CoreMedia
import CoreVideo
import CoreImage
import VideoToolbox
import QuartzCore

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

    init(width: Int, height: Int, multiplier: Int = 2) throws {
        guard [2, 4].contains(multiplier) else { throw Self.error("苹果原生支持 2× 或 4×") }
        self.multiplier = multiplier
        guard WIAppleSupported() else { throw Self.error("此系统或芯片不支持苹果低延迟插帧，需要 macOS 26 或更新系统") }
        // A conservative 720p processing budget. Originals remain at capture resolution.
        // Not a hardware limit; avoids probing arbitrary large window sizes during playback.
        let scale = min(1, sqrt(921_600 / Double(width * height)))
        let w = max(64, Int(Double(width) * scale) / 16 * 16)
        let h = max(64, Int(Double(height) * scale) / 16 * 16)
        guard let config = WIAppleConfigurationForMultiplier(w, h, multiplier), let p = WIAppleProcessor() else {
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

    func preserve(previous: CIImage, current: CIImage, middle: CIImage) throws -> CIImage {
        let bounds = current.extent
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
        guard let crossingSmall = difference.apply(extent: smallBounds, arguments: [lowFrequency(current), lowFrequency(middle), 0.01, 0.03]),
              let result = combine.apply(extent: bounds, arguments: [current, middle, motion,
                crossingSmall.transformed(by: CGAffineTransform(scaleX: 4, y: 4))]) else {
            throw AppleFrameInterpolator.error("静态细节保护无法生成输出")
        }
        return result.cropped(to: bounds)
    }
}

/// A latest-input mailbox bounds latency while the hardware is busy. Presentation is
/// independently scheduled using source timestamps: A, midpoint(A,B), B, ... .
final class AppleInterpolationStream {
    private let queue = DispatchQueue(label: "windowinterp.apple.interpolation", qos: .userInteractive)
    private let lock = NSLock()
    private let multiplier: Int

    init(multiplier: Int = 2) { self.multiplier = multiplier }

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
        lock.lock()
        guard !stopped else { lock.unlock(); return }
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
        queue.async { [self] in previous = nil; engine = nil }
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
                    previous = nil; engine = nil
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
                current: CIImage(cvPixelBuffer: original), middle: AppleFrameInterpolator.displayImage(middle, canvas: dimensions))
            onOutput?(detailed, due + interval * Double(index + 1) / Double(multiplier), true)
        }
        // A final B must still appear if the source becomes idle after this pair.
        onOutput?(CIImage(cvPixelBuffer: original), due + interval, false)
    }
}
