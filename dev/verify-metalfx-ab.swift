import Foundation
import Metal
import MetalFX
import CoreImage
import CoreGraphics

/// MetalFX Spatial 档的**画质 A/B 测量**（离线，不需要屏幕录制权限）。
///
/// 测的是 `main.swift` 里**当前真实的** `SpatialPass`（由 `verify-local.sh` 就地抽取拼进来）。
///
/// ⚠️ 它**不下"哪个更好"的结论** —— 画质是主观的，而且**强烈取决于输入内容**。
/// 这里只把可量化的差异摆出来，并把结果写成 PNG 供肉眼复核（与第 12 轮「画质对比-插帧开-关」同法）：
///   * **平均梯度**（锐度）：越高越"锐"；
///   * **过冲**（振铃 / 光晕）：像素超出 8 邻域极值的平均幅度 —— 越高硬边旁越容易出黑边白边；
///   * **与双线性的 MAE**：差异幅度，**不表示好坏**。
///
/// ⚠️ **为什么跑两组测试图**：第一版只用了「硬内容」（含 4px 周期斜线），结果 MetalFX 的过冲
/// 是 Lanczos 的 3 倍、梯度是它的 1.6 倍 —— 但那种图案已经接近 Nyquist，对**任何**锐利放大器
/// 都是最不利的输入，拿它单独下结论就是**判据本身偏心**（红线：「判据本身错了比没判据更危险」）。
/// 所以再加一组「软内容」（低频形状 + 软边笔画，更接近真实视频/游戏的统计特性）做对照。
@main struct MetalFXAB {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal unavailable")
        }
        let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        let space = CGColorSpace(name: CGColorSpace.sRGB)!

        let srcW = 320, srcH = 180, outW = 640, outH = 360
        let scale = Double(outW) / Double(srcW)

        /// A · 硬内容：细条纹 + 中间硬边 + 4px 周期斜线 + 渐变。
        /// 刻意不利 —— 用来暴露「过锐 / 振铃」这一类失效模式。
        func hardPixels() -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: srcW * srcH * 4)
            for y in 0..<srcH {
                for x in 0..<srcW {
                    var v = 0.0
                    v += 26.0 * sin(Double(x) * 1.7 * .pi / 2.0)
                    v += (x > srcW / 2 ? 42.0 : -42.0)
                    if (x + y) % 24 < 4 { v += 34.0 }
                    v += 30.0 * Double(y) / Double(srcH)
                    let value = UInt8(max(0, min(255, v + 128)))
                    let i = (y * srcW + x) * 4
                    pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value; pixels[i + 3] = 255
                }
            }
            return pixels
        }

        /// B · 软内容：同心圆 + 低频纹理 + 横向渐变 + 一条软边笔画。
        /// 统计特性更接近真实视频/游戏画面（没有接近 Nyquist 的规律图案）。
        func softPixels() -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: srcW * srcH * 4)
            for y in 0..<srcH {
                for x in 0..<srcW {
                    let dx = Double(x) - 118.0, dy = Double(y) - 92.0
                    var v = 128.0
                    v += 46.0 * cos(sqrt(dx * dx + dy * dy) / 27.0)
                    v += 22.0 * sin(Double(x) / 21.0) * cos(Double(y) / 17.0)
                    v += 26.0 * Double(x) / Double(srcW)
                    let d = abs(Double(y) - 28.0 - 0.38 * Double(x))
                    if d < 5 { v += 55.0 * (1.0 - d / 5.0) }   // 软边笔画
                    let value = UInt8(max(0, min(255, v)))
                    let i = (y * srcW + x) * 4
                    pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value; pixels[i + 3] = 255
                }
            }
            return pixels
        }

        func bytes(of img: CIImage) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: outW * outH * 4)
            context.render(img, toBitmap: &out, rowBytes: outW * 4,
                           bounds: CGRect(x: 0, y: 0, width: outW, height: outH),
                           format: .RGBA8, colorSpace: space)
            return out
        }
        func gradient(_ a: [UInt8]) -> Double {
            var total = 0.0
            for y in 1..<outH - 1 { for x in 1..<outW - 1 {
                let i = (y * outW + x) * 4
                total += abs(Double(a[i]) - Double(a[i + 4])) + abs(Double(a[i]) - Double(a[i + outW * 4]))
            } }
            return total / Double((outW - 2) * (outH - 2) * 2)
        }
        /// 过冲：中心像素超出**其余 8 个邻居**极值的平均幅度（振铃 / 光晕的代理指标）。
        func overshoot(_ a: [UInt8]) -> Double {
            var total = 0.0
            for y in 1..<outH - 1 { for x in 1..<outW - 1 {
                var mn = 255.0, mx = 0.0
                for dy in -1...1 { for dx in -1...1 {
                    if dx == 0 && dy == 0 { continue }
                    let v = Double(a[((y + dy) * outW + (x + dx)) * 4])
                    mn = min(mn, v); mx = max(mx, v)
                } }
                let c = Double(a[(y * outW + x) * 4])
                total += max(0, max(mn - c, c - mx))
            } }
            return total / Double((outW - 2) * (outH - 2))
        }
        func mae(_ a: [UInt8], _ b: [UInt8]) -> Double {
            var total = 0.0
            for i in stride(from: 0, to: a.count, by: 4) { total += abs(Double(a[i]) - Double(b[i])) }
            return total / Double(outW * outH)
        }

        let pass = SpatialPass(device: device)
        let fxOK = pass.prepare(inputWidth: srcW, inputHeight: srcH, outputWidth: outW, outputHeight: outH)
        if !fxOK { print("⚠️ 本机 MetalFX Spatial 不可用（\(pass.disabledReason ?? "未知")）→ 只报告 Lanczos vs 双线性") }

        let dir = URL(fileURLWithPath: "dev/verification-metalfx-ab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(_ data: [UInt8], _ w: Int, _ h: Int, _ name: String) {
            let img = CIImage(bitmapData: Data(data), bytesPerRow: w * 4,
                              size: CGSize(width: w, height: h), format: .RGBA8, colorSpace: space)
            do {
                try context.writePNGRepresentation(of: img, to: dir.appendingPathComponent(name),
                                                   format: .RGBA8, colorSpace: space)
            } catch { print("⚠️ 写不出 \(name)：\(error.localizedDescription)") }
        }

        print("=== MetalFX 画质 A/B · \(srcW)×\(srcH) → \(outW)×\(outH)（\(scale)×）===")

        for (index, item) in [("A · 硬内容（含接近 Nyquist 的周期斜线）", hardPixels()),
                              ("B · 软内容（低频形状 + 软边笔画）", softPixels())].enumerated() {
            let (caseName, srcPixels) = item
            let image = CIImage(bitmapData: Data(srcPixels), bytesPerRow: srcW * 4,
                                size: CGSize(width: srcW, height: srcH), format: .RGBA8, colorSpace: space)

            let bilinear = bytes(of: image)

            var lanczosImage = image.applyingFilter("CILanczosScaleTransform",
                                                    parameters: ["inputScale": scale, "inputAspectRatio": 1.0])
            lanczosImage = lanczosImage.transformed(
                by: CGAffineTransform(translationX: -lanczosImage.extent.minX, y: -lanczosImage.extent.minY))
            lanczosImage = lanczosImage.cropped(to: CGRect(x: 0, y: 0, width: outW, height: outH))
            let lanczos = bytes(of: lanczosImage)

            var metalfx: [UInt8]? = nil
            if fxOK, let srcTex = pass.inputTexture, let dstTex = pass.outputTexture {
                let cmd = queue.makeCommandBuffer()!
                context.render(image, to: srcTex, commandBuffer: cmd,
                               bounds: CGRect(x: 0, y: 0, width: srcW, height: srcH), colorSpace: space)
                pass.encode(commandBuffer: cmd)
                cmd.commit(); cmd.waitUntilCompleted()
                precondition(cmd.status == .completed, "MetalFX command failed")
                if let fxImage = CIImage(mtlTexture: dstTex, options: [.colorSpace: space]) {
                    metalfx = bytes(of: fxImage)
                }
            }

            // 防「跑了个寂寞」：新档必须与双线性有可测差异，否则说明缩放根本没生效。
            precondition(mae(bilinear, lanczos) > 0.5, "\(caseName)：Lanczos 与双线性完全相同 —— 缩放没生效")
            if let metalfx { precondition(mae(bilinear, metalfx) > 0.5, "\(caseName)：MetalFX 与双线性完全相同 —— 缩放没生效") }

            print("")
            print("— 用例 \(caseName)")
            let base = gradient(bilinear)
            print("    档位 · 平均梯度 · 相对双线性 · 过冲(振铃) · 与双线性 MAE")
            var rows: [(String, [UInt8])] = [("双线性", bilinear), ("Lanczos", lanczos)]
            if let metalfx { rows.append(("MetalFX", metalfx)) }
            for (name, data) in rows {
                print(String(format: "    %@  梯度 %.3f  相对 %.3f  过冲 %.3f  MAE %.3f",
                             name, gradient(data), gradient(data) / base, overshoot(data), mae(bilinear, data)))
            }

            write(srcPixels, srcW, srcH, String(format: "%dA-source.png", index + 1))
            write(bilinear, outW, outH, String(format: "%dB-bilinear.png", index + 1))
            write(lanczos, outW, outH, String(format: "%dC-lanczos.png", index + 1))
            if let metalfx { write(metalfx, outW, outH, String(format: "%dD-metalfx.png", index + 1)) }
        }

        print("")
        print("⚠️ 这些是**特征指标**，不是「哪个更好」的结论，而且**结论随内容变**：")
        print("   * 梯度高 = 更锐；但内容本身平滑时，过高的梯度只是把噪点一起放大；")
        print("   * 过冲高 = 硬边旁更容易出现黑边/白边（光晕）；")
        print("   * 两组用例的差异说明「用哪种源去测」会直接影响结论 —— 别只跑一组就下判断。")
        print("")
        print("对比图已写入 dev/verification-metalfx-ab/（每组：source / bilinear / lanczos / metalfx）")
    }
}
