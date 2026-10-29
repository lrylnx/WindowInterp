import Foundation
import CoreVideo
import CoreMedia
import CoreImage
import QuartzCore

@main struct VerifyApple {
    static let context = CIContext(options: [.cacheIntermediates: false])
    static func source(width: Int, height: Int, x: Int) -> CVPixelBuffer {
        var out: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &out) == kCVReturnSuccess)
        let buffer = out!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for xx in 0..<width {
                let offset = y * stride + xx * 4
                let inside = xx >= x && xx < x + width / 5 && y > height / 4 && y < 3 * height / 4
                base[offset] = inside ? 220 : 30
                base[offset + 1] = inside ? 180 : 40
                base[offset + 2] = inside ? 240 : 50
                base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
    static func bytes(_ buffer: CVPixelBuffer, width: Int, height: Int) -> [UInt8] {
        let image = CIImage(cvPixelBuffer: buffer)
        let resized = image.transformed(by: CGAffineTransform(scaleX: Double(width) / image.extent.width,
                                                               y: Double(height) / image.extent.height))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            context.render(resized, toBitmap: $0.baseAddress!, rowBytes: width * 4,
                bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        return pixels
    }
    static func raster(_ image: CIImage, width: Int, height: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 4,
                bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        return data
    }
    static func edges(_ bytes: [UInt8], width: Int, height: Int, x: Int) -> [Int] {
        (0..<height).filter { bytes[($0 * width + x) * 4] > 140 }
    }
    static func mae(_ a: [UInt8], _ b: [UInt8]) -> Double {
        zip(a,b).enumerated().reduce(0.0) { $0 + ($1.offset % 4 == 3 ? 0 : abs(Double($1.element.0) - Double($1.element.1))) } / Double(a.count / 4 * 3)
    }
    static func main() throws {
        setbuf(stdout, nil)
        precondition(WIAppleSupported(), "Apple low-latency interpolation unavailable")
        for (width, height) in [(640, 360), (1280, 720), (1920, 1080), (1280, 800), (2560, 1066)] {
            let engine = try AppleFrameInterpolator(width: width, height: height)
            let a = source(width: width, height: height, x: width / 4)
            let b = source(width: width, height: height, x: width / 4 + width / 40)
            let aa = try engine.convert(a), bb = try engine.convert(b)
            var samples: [Double] = []
            var middle: CVPixelBuffer?
            for i in 0..<35 {
                let started = CACurrentMediaTime()
                middle = try engine.midpoint(previous: aa, previousPTS: CMTime(value: Int64(i), timescale: 30),
                    current: bb, currentPTS: CMTime(value: Int64(i+1), timescale: 30))
                if i >= 5 { samples.append((CACurrentMediaTime() - started) * 1000) }
            }
            let m = bytes(middle!, width: 320, height: 180)
            let da = mae(m, bytes(aa, width: 320, height: 180))
            let db = mae(m, bytes(bb, width: 320, height: 180))
            precondition(da > 0.1 && db > 0.1, "output duplicates a source frame")
            // Identical references: any alternating border movement is a pipeline
            // geometry error, not motion estimation or temporal cadence.
            let still = try engine.midpoint(previous: aa, previousPTS: CMTime(value: 40, timescale: 30),
                current: aa, currentPTS: CMTime(value: 41, timescale: 30))
            let canvas = CGSize(width: width, height: height)
            let fixed = AppleFrameInterpolator.displayImage(still, canvas: canvas)
            precondition(fixed.extent == CGRect(origin: .zero, size: canvas))
            let originalPixels = raster(CIImage(cvPixelBuffer: a), width: width, height: height)
            let fixedPixels = raster(fixed, width: width, height: height)
            let old = CIImage(cvPixelBuffer: still)
            let scale = min(Double(width) / old.extent.width, Double(height) / old.extent.height)
            let fitted = old.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": scale, "inputAspectRatio": 1.0])
            let centered = fitted.transformed(by: CGAffineTransform(translationX: (Double(width)-fitted.extent.width)/2,
                y: (Double(height)-fitted.extent.height)/2))
            let oldPixels = raster(centered, width: width, height: height)
            let ref = edges(originalPixels, width: width, height: height, x: width/3)
            let now = edges(fixedPixels, width: width, height: height, x: width/3)
            let before = edges(oldPixels, width: width, height: height, x: width/3)
            let error = max(abs(ref.first! - now.first!), abs(ref.last! - now.last!))
            let oldError = max(abs(ref.first! - before.first!), abs(ref.last! - before.last!))
            precondition(error <= 1, "static original/intermediate borders shift: \(error)px")
            print("PASS static geometry \(width)x\(height): old border error=\(oldError)px, corrected=\(error)px")
            samples.sort()
            print(String(format: "PASS %dx%d -> %.0fx%.0f median=%.2fms p95=%.2fms midpoint MAE(A)=%.3f MAE(B)=%.3f",
                         width, height, engine.size.width, engine.size.height,
                         samples[samples.count/2], samples[Int(Double(samples.count-1)*0.95)], da, db))
        }
        // Native 4× must produce three distinct, temporally ordered phases.
        for (width, height) in [(640, 360), (2560, 1440)] {
            let engine = try AppleFrameInterpolator(width: width, height: height, multiplier: 4)
            let a = try engine.convert(source(width: width, height: height, x: width/4))
            let b = try engine.convert(source(width: width, height: height, x: width/4 + width/12))
            var samples: [Double] = []
            var frames: [CVPixelBuffer] = []
            for i in 0..<25 {
                let start = CACurrentMediaTime()
                frames = try engine.intermediates(previous: a, previousPTS: CMTime(value: Int64(i), timescale: 36),
                    current: b, currentPTS: CMTime(value: Int64(i+1), timescale: 36))
                if i >= 5 { samples.append((CACurrentMediaTime()-start)*1000) }
            }
            precondition(frames.count == 3)
            let rasters = ([a] + frames + [b]).map { bytes($0, width: 320, height: 180) }
            func center(_ raster: [UInt8]) -> Double {
                var sum = 0.0, weight = 0.0
                for y in 50..<130 { for x in 0..<320 {
                    let value = max(0, Double(raster[(y*320+x)*4])-100)
                    sum += Double(x)*value; weight += value
                } }
                return sum/weight
            }
            let centers = rasters.map(center)
            for i in 0..<4 {
                precondition(centers[i+1] > centers[i]+1, "4× phases do not advance: \(centers)")
                precondition(mae(rasters[i],rasters[i+1]) > 0.1, "4× duplicated frame")
            }
            samples.sort()
            print(String(format: "PASS native 4× %dx%d: three ordered distinct phases, median %.2fms p95 %.2fms; centers %@",
                width, height, samples[samples.count/2], samples[Int(Double(samples.count-1)*0.95)], "\(centers)"))
        }
        // Slowly changing shadows must use the matching temporal reference,
        // rather than borrowing the future endpoint for all three phases.
        do {
            let w=640, h=360
            let engine = try AppleFrameInterpolator(width:w,height:h,multiplier:4)
            let a = source(width:w,height:h,x:0)
            CVPixelBufferLockBaseAddress(a, [])
            let p = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to:UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(a)
            for y in 0..<h { for x in 0..<w {
                for c in 0..<3 { p[y*stride+x*4+c] = UInt8(8+x*100/w) }
                p[y*stride+x*4+3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(a, [])
            let b = try engine.copyOriginal(a)
            CVPixelBufferLockBaseAddress(b, [])
            let q = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to:UInt8.self)
            let bs = CVPixelBufferGetBytesPerRow(b)
            for y in 0..<h { for x in 0..<w { for c in 0..<3 { q[y*bs+x*4+c] += 4 } } }
            CVPixelBufferUnlockBaseAddress(b, [])
            let aa = try engine.convert(a), bb = try engine.convert(b)
            let frames = try engine.intermediates(previous:aa,previousPTS:.zero,current:bb,currentPTS:CMTime(value:1,timescale:30))
            let original = bytes(a,width:w,height:h)
            var levels:[Double] = []
            for (i, frame) in frames.enumerated() {
                let image = try StaticDetailPreserver().preserve(previous:CIImage(cvPixelBuffer:a), current:CIImage(cvPixelBuffer:b),
                    middle:AppleFrameInterpolator.displayImage(frame,canvas:CGSize(width:w,height:h)),phase:Double(i+1)/4)
                let pixels = raster(image,width:w,height:h)
                var level=0.0
                for y in 10..<h-10 { for x in 10..<w-10 {
                    let j=(y*w+x)*4; level += Double(pixels[j])-Double(original[j])
                } }
                level /= Double((w-20)*(h-20)); levels.append(level)
                precondition(abs(level-Double(i+1)) < 0.5, "shadow jumps toward future endpoint: \(levels)")
            }
            print("PASS shadow fade: expected [1, 2, 3] code values; actual \(levels)")
        }
        // Infer visible cadence, including capture quantization and held frames.
        for fps in [24,25,30] {
            for captureFPS in [48.0,60.0] {
                var detector=AutomaticVideoCadence(), previous = -1
                for i in 0..<Int(captureFPS*7) {
                    let t=Double(i)/captureFPS
                    let frame=Int(floor(t*Double(fps)+0.00001))
                    detector.observe(changed:Array(repeating:frame != previous,count:6),at:t)
                    previous=frame
                }
                print("auto diagnostic \(fps)fps at \(captureFPS): \(detector.fps) confidence \(detector.confidence)")
                precondition(detector.fps == fps, "automatic cadence did not identify source")
                let locked=detector.fps
                for i in 0..<Int(captureFPS*4) { detector.observe(changed:Array(repeating:false,count:6),at:7+Double(i)/captureFPS) }
                precondition(detector.fps == locked, "still image erased known cadence")
            }
        }
        do {
            var detector=AutomaticVideoCadence(), old = -1
            for i in 0..<720 {
                let t=Double(i)/48, fps=t<7 ? 25.0:30.0
                let frame=Int(floor(t*fps+0.00001))
                detector.observe(changed:Array(repeating:frame != old,count:6),at:t);old=frame
            }
            precondition(detector.fps == 30, "did not adapt from 25 to 30fps")
            var ui=AutomaticVideoCadence()
            for i in 0..<480 { ui.observe(changed:[true,false,false,false,false,false],at:Double(i)/48) }
            precondition(ui.fps == 0, "one animated control selected video cadence")
            var fast=AutomaticVideoCadence()
            for i in 0..<480 { fast.observe(changed:Array(repeating:true,count:6),at:Double(i)/48) }
            precondition(fast.fps == 0, "unsupported high-rate UI was labeled 24/25/30fps")
            print("PASS automatic cadence: 24/25/30, 48/60Hz capture, still hold, 25→30 change, UI rejection")
        }
        // A pixel outside the sparse probe grid must still prevent a false duplicate.
        do {
            let a=source(width:640,height:360,x:100), b=source(width:640,height:360,x:100)
            precondition(VideoFrameIdentity.equal(a,b))
            CVPixelBufferLockBaseAddress(b,[])
            let p=CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to:UInt8.self)
            p[7*CVPixelBufferGetBytesPerRow(b)+13*4] ^= 1
            CVPixelBufferUnlockBaseAddress(b,[])
            precondition(!VideoFrameIdentity.equal(a,b), "sparse sampling hid a changed pixel")
            var clock=VideoCadenceClock(fps:25)
            var times:[Double]=[], prior = -1
            for i in 0..<480 {
                let frame=Int(floor(Double(i)*25/48))
                if frame == prior { continue }; prior=frame
                let tick=clock.advance(100+Double(i)/48)
                precondition(tick.gap == 1, "25fps at 48 captures misclassified: \(tick)")
                times.append(tick.time)
            }
            for (a,b) in zip(times,times.dropFirst()) { precondition(abs(b-a-0.04)<0.000001) }
            // Declared video cadence must not run ahead when UI changes too fast.
            var fast=VideoCadenceClock(fps:25)
            for i in 0..<480 {
                let t=Double(i)/48
                let tick=fast.advance(t)
                precondition(tick.time-t <= 0.031)
            }
            print("PASS video identity: complete pixel comparison; 25fps/48Hz captures reconstruct uniform 40ms steps; fast UI bounded")
        }
        for (w,h) in [(1200,500),(1920,800)] {
            let e=try AppleFrameInterpolator(width:w,height:h,multiplier:4,videoQuality:true)
            let a=try e.convert(source(width:w,height:h,x:w/4)), b=try e.convert(source(width:w,height:h,x:w/4+w/40))
            var samples:[Double]=[]
            for i in 0..<12 {
                let t=CACurrentMediaTime()
                let frames=try e.intermediates(previous:a,previousPTS:CMTime(value:Int64(i),timescale:25),current:b,currentPTS:CMTime(value:Int64(i+1),timescale:25))
                precondition(frames.count == 3)
                if i>2 { samples.append((CACurrentMediaTime()-t)*1000) }
            }
            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
                precondition(e.size == CGSize(width:w,height:h), "video quality unexpectedly downscaled")
            }
            samples.sort()
            print("PASS video native \(w)x\(h) -> \(e.size), cascade 4× median \(samples[samples.count/2])ms")
        }
        // Static 2px details above a fast object: restore detail without replacing
        // the interpolated object by an endpoint, including a disjoint crossing.
        func detailFrame(_ x: Int) -> CIImage {
            let w = 256, h = 160
            var data = [UInt8](repeating: 255, count: w*h*4)
            for y in 0..<h { for xx in 0..<w {
                let text = y < 40 && xx > 16 && xx < 240
                let moving = y >= 85 && y < 105 && xx >= x && xx < x+12
                let value: UInt8 = moving ? 240 : (text ? ((xx/2+y/2)%2 == 0 ? 40 : 210) : 51)
                for c in 0..<3 { data[(y*w+xx)*4+c] = value }
            } }
            return CIImage(bitmapData: Data(data), bytesPerRow: w*4, size: CGSize(width: w,height: h),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        let left = detailFrame(20), right = detailFrame(180)
        let interpolated = detailFrame(100).clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 1.2])
            .cropped(to: right.extent)
        let preserved = try StaticDetailPreserver().preserve(previous: left, current: right, middle: interpolated)
        let ref = raster(right, width:256,height:160), raw = raster(interpolated,width:256,height:160)
        let restored = raster(preserved,width:256,height:160)
        var rawError = 0.0, fixedError = 0.0
        for y in 8..<32 { for x in 32..<224 {
            let i = (y*256+x)*4
            rawError += abs(Double(raw[i])-Double(ref[i]))
            fixedError += abs(Double(restored[i])-Double(ref[i]))
        } }
        precondition(fixedError < rawError * 0.4, "static detail did not improve")
        let crossing = (95*256+105)*4
        precondition(abs(Int(restored[crossing])-Int(raw[crossing])) <= 2,
                     "static protection erased the moving midpoint object")
        // Shift a high-frequency pattern whose averaged colors are unchanged.
        // Pooling colors would call this static; max-pooling differences must not.
        let shifted = right.clampedToExtent().transformed(by: CGAffineTransform(translationX: 2, y: 0)).cropped(to:right.extent)
        let checkedMotion = try StaticDetailPreserver().preserve(previous: right, current: shifted, middle: interpolated)
        let checkedPixels = raster(checkedMotion,width:256,height:160)
        let fineMotion = (20*256+100)*4
        precondition(abs(Int(checkedPixels[fineMotion])-Int(raw[fineMotion])) <= 2,
                     "averaging hid fine motion and copied endpoint detail")
        print(String(format:"PASS static detail: error %.2f -> %.2f; fast crossing retained",rawError/4608,fixedError/4608))

        do {
            let stream=AppleInterpolationStream(multiplier:4,videoFPS:25)
            let mutex=NSLock(); var due:[Double]=[]; var errors:[String]=[]
            stream.onOutput = { _,time,generated in if generated { mutex.lock(); due.append(time); mutex.unlock() } }
            stream.onError = { message in mutex.lock(); errors.append(message); mutex.unlock() }
            let frames=(0..<80).map { source(width:640,height:360,x:20+$0*3) }
            let start=CACurrentMediaTime()
            for i in 0..<144 {
                let capture=CACurrentMediaTime()
                stream.submit(frames[Int((capture-start)*25)%frames.count],pts:CMTime(seconds:capture,preferredTimescale:60000))
                Thread.sleep(forTimeInterval:max(0,start+Double(i+1)/48-CACurrentMediaTime()))
            }
            Thread.sleep(forTimeInterval:0.18)
            let stats=stream.cadenceStats
            stream.stop(); Thread.sleep(forTimeInterval:0.1)
            mutex.lock(); let count=due.count, failures=errors; let stamps=due; mutex.unlock()
            print("video stream diagnostic count=\(count) stats=\(stats) errors=\(failures)")
            precondition(failures.isEmpty, "video stream failed: \(failures)")
            precondition(count>120 && stats.duplicates>30, "video stream did not interpolate and deduplicate: \(count) \(stats)")
            var correct=0
            for (a,b) in zip(stamps,stamps.dropFirst()) { if abs(b-a-0.01)<0.00002 { correct += 1 } }
            // Across original boundaries generated-to-generated is 20ms.
            print("video stream cadence matching=\(correct) / \(count)")
            precondition(correct>count/2, "video stream did not schedule 10ms phases")
            print("PASS video stream: \(count) intermediates, duplicates \(stats.duplicates), 10ms cadence, errors=0")
        }
        // Timestamp discontinuity, size change and stop exercise the production stream.
        let stream = AppleInterpolationStream()
        let outputLock = NSLock()
        var outputs: [(Double, Bool)] = []
        var errors: [String] = []
        stream.onOutput = { _, due, generated in outputLock.lock(); outputs.append((due, generated)); outputLock.unlock() }
        stream.onError = { error in outputLock.lock(); errors.append(error); outputLock.unlock() }
        for i in 0..<60 {
            let w = i < 40 ? 640 : 800
            stream.submit(source(width: w, height: 360, x: 100 + i * 2),
                          pts: CMTime(value: Int64(i < 30 ? i : i + 30), timescale: 30))
            Thread.sleep(forTimeInterval: 1.0/30)
        }
        Thread.sleep(forTimeInterval: 0.15)
        stream.stop()
        Thread.sleep(forTimeInterval: 0.1)
        outputLock.lock()
        let count = outputs.count, generated = outputs.filter { $0.1 }.count
        let failures = errors
        outputLock.unlock()
        precondition(failures.isEmpty, "stream failed: \(failures)")
        precondition(generated >= 10, "no sustained genuine midpoint production")
        stream.submit(source(width: 640, height: 360, x: 100), pts: CMTime(value: 100, timescale: 30))
        Thread.sleep(forTimeInterval: 0.1)
        outputLock.lock(); let finalCount = outputs.count; outputLock.unlock()
        precondition(count == finalCount, "stopped stream still produces frames")
        print("PASS stream: \(generated) midpoints, discontinuity/resize/stop")
        // Regression: delayed first capture/model setup must not shift the whole
        // host-clock timeline into the future and keep overflowing the display queue.
        let hostStream = AppleInterpolationStream()
        var furthestDeadline = 0.0
        var hostMidpoints = 0
        hostStream.onOutput = { _, deadline, generated in
            outputLock.lock()
            furthestDeadline = max(furthestDeadline, deadline - CACurrentMediaTime())
            if generated { hostMidpoints += 1 }
            outputLock.unlock()
        }
        hostStream.onError = { error in outputLock.lock(); errors.append(error); outputLock.unlock() }
        for i in 0..<30 {
            let time = CACurrentMediaTime() - (i == 0 ? 0.12 : 0)
            hostStream.submit(source(width: 640, height: 360, x: 100 + i),
                pts: CMTime(seconds: time, preferredTimescale: 60_000))
            Thread.sleep(forTimeInterval: 1.0/30)
        }
        Thread.sleep(forTimeInterval: 0.1)
        hostStream.stop()
        outputLock.lock()
        let horizon = furthestDeadline, hostCount = hostMidpoints, hostErrors = errors
        outputLock.unlock()
        precondition(hostErrors.isEmpty && hostCount > 2)
        precondition(horizon < 0.14, "initialization shifted playout too far ahead: \(horizon)")
        print(String(format: "PASS host-clock regression: %d midpoints, maximum future deadline %.1fms", hostCount, horizon * 1000))

    }
}
