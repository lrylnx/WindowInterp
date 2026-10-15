import Foundation
import Metal
import MetalFX
import CoreImage
import CoreGraphics

/// MetalFX Spatial 档的离线自检 —— **不需要屏幕录制权限**。
///
/// 测的是 `main.swift` 里**当前真实的** `SpatialPass` 源码（由 `verify-local.sh` 就地抽取拼进来），
/// 不是副本 —— 否则改了实现而测试还在测旧逻辑，判据会**假绿**。
///
/// 三条判据，每条都刻意选成「能区分 A 和 B」的：
///   ① **准入判定**：该拒绝的必须拒绝（缩小 / 1:1 / 宽高比不一致）。这条最要紧 ——
///      MetalFX 只做整体拉伸、不做「等比 + 居中留黑边」，放它过去会把画面**拉变形**，
///      而变形比糊更糟、且当场看不出来（要等看到圆变椭圆）。
///   ② **纹理尺寸**：放大后必须真的变成输出尺寸（防「参数传了但没生效」那类假成功）。
///   ③ **方向**：MetalFX **不得**引入额外的上下翻转。
///      做法是拿「CI 直接渲染的同一张图」当基准，比较 `MAE(正比)` 与 `MAE(垂直翻转)`，
///      翻转那条更大才算通过。⚠️ 这条**不能用推理代替** —— CASPass 的注释里写着
///      「uv 取向只能靠实测定，推错过两次」，而推错的后果是整个画面上下颠倒。
///
/// ⚠️ 本机若无 MetalFX Spatial 支持，② ③ 会**跳过并明确说"跳过"**，不会假报通过。
@main struct MetalFXChecks {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal unavailable")
        }
        let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        let space = CGColorSpace(name: CGColorSpace.sRGB)!

        var failed = 0
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "  ✓ \(what)" : "  ✗ \(what)")
            if !ok { failed += 1 }
        }

        print("① 准入判定（该拒绝的必须拒绝）")
        check(!SpatialPass(device: device).prepare(inputWidth: 1920, inputHeight: 1080,
                                                   outputWidth: 960, outputHeight: 540),
              "缩小 1920×1080 → 960×540 被拒绝")
        check(!SpatialPass(device: device).prepare(inputWidth: 1920, inputHeight: 1080,
                                                   outputWidth: 1920, outputHeight: 1080),
              "1:1 1920×1080 → 1920×1080 被拒绝")
        check(!SpatialPass(device: device).prepare(inputWidth: 1000, inputHeight: 600,
                                                   outputWidth: 1920, outputHeight: 1080),
              "宽高比不一致 5:3 → 16:9 被拒绝")

        let srcW = 96, srcH = 64, outW = 192, outH = 128
        let pass = SpatialPass(device: device)
        let supported = pass.prepare(inputWidth: srcW, inputHeight: srcH,
                                     outputWidth: outW, outputHeight: outH)
        print("② 本机 MetalFX Spatial：\(supported ? "可用" : "不可用（\(pass.disabledReason ?? "未知")）")")
        guard supported, let srcTex = pass.inputTexture, let dstTex = pass.outputTexture else {
            print("  ⚠️ 本机不支持 → 跳过尺寸/方向断言（**这不是通过**，请在有 MetalFX 的机器上重跑）")
            print(failed == 0 ? "PARTIAL：准入判定通过，GPU 断言已跳过" : "FAIL：\(failed) 项")
            exit(failed == 0 ? 0 : 1)
        }
        check(dstTex.width == outW && dstTex.height == outH,
              "中间纹理尺寸 = \(outW)×\(outH)（实际 \(dstTex.width)×\(dstTex.height)）")
        check(srcTex.width == srcW && srcTex.height == srcH,
              "输入纹理尺寸 = \(srcW)×\(srcH)（实际 \(srcTex.width)×\(srcTex.height)）")

        // 输入：上半亮 / 下半暗（CI 坐标 y 大 = 视觉上方）。纯色块，放大算法差异对它几乎无影响，
        // 于是「方向错」会成为唯一能拉开 MAE 的因素 —— 这正是这条判据要有区分度的做法。
        var pixels = [UInt8](repeating: 0, count: srcW * srcH * 4)
        for y in 0..<srcH {
            for x in 0..<srcW {
                let value = UInt8(y >= srcH / 2 ? 220 : 40)
                let i = (y * srcW + x) * 4
                pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value; pixels[i + 3] = 255
            }
        }
        let image = CIImage(bitmapData: Data(pixels), bytesPerRow: srcW * 4,
                            size: CGSize(width: srcW, height: srcH), format: .RGBA8, colorSpace: space)

        // 与 present() 同一套的垂直翻转。
        func flipV(_ img: CIImage, _ h: CGFloat) -> CIImage {
            img.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
                .concatenating(CGAffineTransform(translationX: 0, y: h)))
        }
        func mae(_ a: [UInt8], _ b: [UInt8], flipB: Bool) -> Double {
            var total = 0.0
            for y in 0..<outH { for x in 0..<outW {
                let i = (y * outW + x) * 4
                let j = ((flipB ? outH - 1 - y : y) * outW + x) * 4
                total += abs(Double(a[i]) - Double(b[j]))
            } }
            return total / Double(outW * outH)
        }

        print("③ 方向 —— 必须覆盖 flipVertical 的**两种**取值")
        // ⚠️ 只测一种就下结论是上一轮踩过的坑：这次实测发现「MetalFX 那一步自身会带来一次
        //    上下翻转」，于是两种 flipVertical 下的**正确实现恰好相反**，只测一种会改错方向。
        //
        // 下面这段**必须与 main.swift 里 present() 的 ③-A 分支保持同构**（第一跳是否翻转 +
        // 最后一跳在什么条件下补翻）。漂移了这条判据就会假绿。
        for flipVertical in [true, false] {
            // 基准 = 「关闭」档：CI 直接渲染「按关闭档约定处理过的图」到输出尺寸。
            let refTex0 = makeTexture(device, outW, outH)!
            let c1 = queue.makeCommandBuffer()!
            let refInput = flipVertical ? flipV(image, CGFloat(srcH)) : image
            context.render(refInput, to: refTex0, commandBuffer: c1,
                           bounds: CGRect(x: 0, y: 0, width: outW, height: outH), colorSpace: space)
            c1.commit(); c1.waitUntilCompleted()
            precondition(c1.status == .completed, "ref command failed")

            // 被测 = MetalFX 路径：第一跳**不翻** → MetalFX → 最后一跳仅当 !flipVertical 时补翻。
            let c2 = queue.makeCommandBuffer()!
            context.render(image, to: srcTex, commandBuffer: c2,
                           bounds: CGRect(x: 0, y: 0, width: srcW, height: srcH), colorSpace: space)
            pass.encode(commandBuffer: c2)
            c2.commit(); c2.waitUntilCompleted()
            precondition(c2.status == .completed, "metalfx command failed")

            // ⚠️ MetalFX 这一路**不翻** —— 与 main.swift 的 ③-A 分支同构。
            //    实测结论：这条链相对「关闭」档自带一次翻转，所以两边都不用再翻；
            //    **两种 flipVertical 都认同这个结论**（只测一种会改错方向）。
            guard let fxImage = CIImage(mtlTexture: dstTex, options: [.colorSpace: space]) else {
                fatalError("dst 读不回来"); }

            let fxTex0 = makeTexture(device, outW, outH)!
            let c3 = queue.makeCommandBuffer()!
            context.render(fxImage, to: fxTex0, commandBuffer: c3,
                           bounds: CGRect(x: 0, y: 0, width: outW, height: outH), colorSpace: space)
            c3.commit(); c3.waitUntilCompleted()

            let ref = readback(context, refTex0, outW, outH, space)
            let fx = readback(context, fxTex0, outW, outH, space)
            let same = mae(ref, fx, flipB: false)
            let flip = mae(ref, fx, flipB: true)
            print("    flipVertical=\(flipVertical ? "true " : "false") "
                  + String(format: "MAE 正比 %.2f / 垂直翻转 %.2f", same, flip))
            check(same < flip, "flipVertical=\(flipVertical)：MetalFX 链与「关闭」档同向")
            // ⚠️ 反向注入：判据不能只是"永远绿"。要求翻转那条 MAE **显著更大** ——
            // 若哪天有人把翻转决策改回去，`same` 与 `flip` 会对调、上面那条立刻变红；
            // 这条则保证两者确实处在可区分的距离上（不是噪声级差异）。
            check(flip - same > 20,
                  "判据有区分度：翻转那条比正比高 \(String(format: "%.1f", flip - same))")
        }

        // 内容保持：放大后上下半的亮度差应该还在（防「全黑/全白」这类静默失败）。
        let fx = readback(context, dstTex, outW, outH, space)
        var topSum = 0.0, botSum = 0.0
        for y in 0..<outH { for x in 0..<outW {
            let v = Double(fx[(y * outW + x) * 4])
            if y >= outH / 2 { topSum += v } else { botSum += v }
        } }
        let half = Double(outW * outH / 2)
        print(String(format: "    放大后上半均值 %.1f / 下半均值 %.1f（相差应 > 60）", topSum / half, botSum / half))
        check(abs(topSum - botSum) / half > 60, "放大后上下半仍可区分（内容没有被抹平）")

        print(failed == 0 ? "PASS actual MetalFX Spatial pass" : "FAIL \(failed) 项")
        exit(failed == 0 ? 0 : 1)
    }

    private static func makeTexture(_ device: MTLDevice, _ w: Int, _ h: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                         width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .renderTarget, .shaderWrite]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    private static func readback(_ context: CIContext, _ tex: MTLTexture,
                                 _ w: Int, _ h: Int, _ space: CGColorSpace) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let img = CIImage(mtlTexture: tex, options: [.colorSpace: space]) else { return bytes }
        context.render(img, toBitmap: &bytes, rowBytes: w * 4,
                       bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: space)
        return bytes
    }
}
