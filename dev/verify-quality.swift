import Foundation
import Metal
import CoreImage

@main struct QualityChecks {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("Metal unavailable") }
        let pass = CASPass(device: device)
        guard pass.enabled, let textures = pass.buffers(width: 96, height: 64) else { fatalError(pass.disabledReason ?? "textures unavailable") }
        let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let width = 96, height = 64
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt8(128 + 30 * sin(Double(x) * 0.8) + 20 * cos(Double(y) * 0.6))
                let i = (y * width + x) * 4
                pixels[i] = value; pixels[i+1] = value; pixels[i+2] = value
            }
        }
        let image = CIImage(bitmapData: Data(pixels), bytesPerRow: width * 4,
                            size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: space)
        func render(_ amount: Float) -> [UInt8] {
            let command = queue.makeCommandBuffer()!
            context.render(image, to: textures.src, commandBuffer: command,
                           bounds: image.extent, colorSpace: space)
            pass.encode(commandBuffer: command, src: textures.src, dst: textures.dst, sharpness: amount)
            command.commit(); command.waitUntilCompleted()
            precondition(command.status == .completed, "Metal command failed")
            let result = CIImage(mtlTexture: textures.dst, options: [.colorSpace: space])!
            var bytes = [UInt8](repeating: 0, count: pixels.count)
            context.render(result, toBitmap: &bytes, rowBytes: width * 4,
                           bounds: image.extent, format: .RGBA8, colorSpace: space)
            return bytes
        }
        let zero = render(0)
        let enhanced = render(0.5)
        func error(_ bytes: [UInt8], flipped: Bool) -> Double {
            var total = 0.0
            for y in 0..<height { for x in 0..<width {
                let expected = pixels[(y * width + x) * 4]
                let actual = bytes[((flipped ? height-1-y : y) * width + x) * 4]
                total += abs(Double(expected) - Double(actual))
            } }
            return total / Double(width * height)
        }
        let identity = error(zero, flipped: false)
        let flipped = error(zero, flipped: true)
        precondition(identity <= 1 && identity < flipped, "Zero-strength identity/orientation failed: \(identity), flipped \(flipped)")
        func gradient(_ a: [UInt8]) -> Double {
            var total = 0.0
            for y in 1..<height-1 { for x in 1..<width-1 {
                let i = (y * width + x) * 4
                total += abs(Double(a[i]) - Double(a[i+4])) + abs(Double(a[i]) - Double(a[i+width*4]))
            } }
            return total / Double((width-2)*(height-2)*2)
        }
        let gain = gradient(enhanced) / gradient(zero)
        precondition(gain > 1.02 && gain < 1.5, "Unexpected sharpening response: \(gain)")
        precondition(pass.buffers(width: width, height: height)!.src === textures.src, "Intermediate texture was not reused")
        print(String(format: "PASS actual CAS Metal shader: zero-strength MAE %.3f, flipped MAE %.3f, gradient gain %.3f; buffers reused", identity, flipped, gain))
    }
}
