# Mac 能不能做「Mac 版 Magpie」—— 算法落地清单

2026-10-16。用户看到 [Magpie](https://github.com/Blinue/Magpie)（Windows 的窗口超分工具），
问：它能给图片、视频都加「DLSS」，Mac 能实现吗。

**结论：能 —— 而且我们已经做了一半。** 缺的只有算法库（§2/§3）。
但要说清两层：**官方 Magpie 内置的 40+ 种效果全是空间算法，没有 DLSS**（§1）；
**社区魔改版确实集成了 DLSS（DLSS-NR）**，但它依赖 NVIDIA 的专有运行时，Mac 做不了（§1b）。
**真正对我们可用的，仍然是空间算法那一路。**

---

## 1. 官方 Magpie 的内置效果里没有 DLSS

Magpie 是 GPL-3.0 的 Windows 窗口超分工具，内置 40+ 种效果。把它的内置效果清单
（官方 wiki「内置效果介绍」）按类过一遍：

| 类别 | 具体算法 |
| --- | --- |
| 超分类 | Anime4K（Restore / Thin / Upscale / Denoise / 3D 五族）、FSRCNNX / FSRCNNX_LineArt、ACNet、CuNNy / CuNNy2、NNEDI3、RAVU / RAVU-Zoom、FSR_EASU、NIS、SGSR、xBRZ（2×–6× / Freescale）、MMPX、LCAS、CAS_Scaling、Jinc、Lanczos、Bicubic、Bilinear、Nearest、Pixellate、SharpBilinear |
| 锐化类（不改尺寸） | CAS、FSR_RCAS、AdaptiveSharpen、FineSharp、LumaSharpen、NVSharpen |
| 抗锯齿 | FXAA、SMAA |
| 其他 | CRT 系列（Easymode / Geom / Hyllian / Lottes / GTU）、Deband、ImageAdjustment、SSimDownscaler（缩小用） |

**这份（官方）清单里没有任何一个需要深度缓冲或运动矢量，也没有 DLSS —— 魔改版另有，见 §1b。**
最"AI"的 Anime4K / FSRCNNX / CuNNy / ACNet 都是**单帧空间 CNN**；FSR_EASU 是近似 ML 的
空间算法。DLSS / FSR4 那类**时域**算法在这里一个都没有 —— 因为窗口超分工具根本拿不到
游戏内部的深度与运动矢量（上一轮 `FSR4-可行性-2026-10-16.md` 已论证）。

**但这正是好消息**：它们全是空间算法（只要一张图）⇒ **Mac 上完全能实现**。

顺带说明「给图片、视频都加」：Magpie 是**窗口**超分，它处理的是"图片查看器窗口 / 播放器窗口"，
不是图片文件本身。这个概念区分在 §4 有用。

---

## 1b. 修正：魔改版 Magpie 确实集成了 DLSS —— 但 Mac 做不了

> 本节是 2026-10-16 当天的追加修正。上一版只查了**官方** `Blinue/Magpie`，漏了社区魔改版。

**确实存在**：[`SAOG0721/Magpie`](https://github.com/SAOG0721/Magpie)（"Magpie Experimental"），
自述为 *"Unofficial experimental Magpie fork with **colour-only DLSS**, FSR2 and NVIDIA RTX Video integrations"*。
它内置的效果名是 **`DLSSNR`**，另有实验性的 DLSS SR / FSR 2 / 3 / 4 / XeSS SR、
DLSSFG / XeSSFG / FSR3FG / NVIDIA VFG（帧生成）和 RTX Video（视频超分降噪）。
**用户说的没错，它确实能给游戏、视频、图片窗口加。**

### DLSS-NR（= DLSS 5）是什么

DLSS 5 = **DLSS-NR（Neural Rendering）**。它原本是随 NBA 2K27 抢先体验版**误打包泄漏**的
（`nvngx_dlssnr.dll`，约 158 MB），NVIDIA 尚未正式发布（SIGGRAPH 2026 预览过，说"今秋"）。
社区已经把它接到了 Magpie / OptiScaler / OBS / ComfyUI 上。

三个关键属性 —— 其中一个正好解释了「为什么窗口工具能喂它」：

| 属性 | 说明 |
| --- | --- |
| **只要颜色（colour-only）** | 魔改版自述就是 "colour-only DLSS"。**不需要 depth / motion vectors / jitter** |
| **同分辨率** | 它是"神经渲染后处理"（tone / structure / shadow / reflection / glow），**不是超分**，输出尺寸 = 输入尺寸 |
| 生成式 | 约 158 MB 的模型，比 DLSS 4.5 的 Ray Reconstruction（72 MB）大一倍多 |

⚠️ **这推翻了我上一轮的一个隐含前提**："凡是 AI 的都要 depth/MV" —— 不成立。
只要模型设计成 colour-only，窗口工具确实能喂。**但下面这条挡住了 Mac。**

### 为什么 Mac 做不了（硬依赖链）

```
DLSS-NR 效果
  └── nvngx_dlssnr.dll        ← NVIDIA 专有二进制（约 158 MB，泄漏物，任何人都不得再分发）
       └── NGX 运行时 _nvngx.dll  ← 从 NVIDIA **Windows 驱动包**里提取
            └── NVIDIA Tensor Core（FP8）+ CUDA kernel
                 └── Windows + NVIDIA 驱动 616.56+
```

- Mac 上：**没有 N 卡、没有 NVIDIA 驱动、没有 NGX、没有 CUDA**。整条链从第二环就断了。
- 有人把它移植到了 AMD（`DLSS-NR-on-AMD`：拦 NGX API + 把数学翻到 HIP RT），
  但那是 **Windows + Adrenalin 驱动**，而且 **RX 9070 XT 只有约 33 FPS @1080p**。
- 说明**硬件锁是软件锁**（模型本身可移植），但把 CUDA kernel 翻到 Metal 等于重做那个 AMD 项目的活，
  还要面对 M1 Max 没有 FP8（M5 / family 10 才有张量单元）、以及**模型是未发布的泄漏二进制**
  ⇒ **工程量、算力、许可三条全不划算。**

### 顺带记录：这个效果本身有争议

它**不是无脑提升画质** —— 是强风格化的"重新生成细节"，代价很实在：
社区反馈里提到**文字瞬间模糊**、连看 30 分钟眼睛受不了、人脸"越拉越油腻"；
性能上 RTX 4090 在 *Control* 里约 −40%（130→82 FPS）、RTX 5070 在 *Cyberpunk 2077* 里腰斩（138→68 FPS）。
⇒ 即使有 N 卡，也建议先用它自带的 Comparison 对比再决定。

### 对 Mac 的正确姿势

Mac 上等价的能力**不是** DLSS-NR，而是 **Apple 自己的神经引擎路线**：
在 CoreML / Metal 上跑**开源的空间 AI 模型**（Anime4K、ESRGAN 系等），或直接用 MetalFX。
⇒ 结论回到 §2–§5：**我们该做的仍然是空间算法档位。**

---

## 2. 架构对照：我们已经做了一半

| 环节 | Magpie（Windows） | WindowInterp（macOS） |
| --- | --- | --- |
| 抓窗口 | WinRT Capture（Screen Capture API） | SCStream |
| 中间处理 | D3D11 像素/计算着色器（HLSL，效果放 `effects/`，有 MagpieFX 格式） | Metal（Core Image + 自写 Metal shader） |
| **算法库** | **40+ 种，可任意组合** | **2 档：Lanczos + CAS** ← **唯一缺口** |
| 显示 | 自己的全屏窗口（切换前台窗口即退出） | 贴住源窗口的穿透覆盖层 |
| 插帧 | 无 | **LSFG**（Magpie 没有的能力） |

**两边抓窗口用的是同一套做法**（WinRT Capture 与 SCStream 都是系统截屏 API），输出都是一个覆盖层。
⇒ 架构层面没有障碍，**缺的只是算法档位**。

---

## 3. 落地清单（含许可红线）

⚠️ **红线：不要从 Magpie 仓库取代码。** Magpie 是 **GPL-3.0（copyleft）**，
把它的 HLSL 抄进本项目会把 GPL 传染过来。要取**上游算法的原始实现**（下表第二列）。
这与 README「第三方来源与许可」表的口径一致。

| 目标档 | 上游来源（取这个，不是 Magpie） | 许可 | Mac 落地难度 |
| --- | --- | --- | --- |
| **MetalFX Spatial** | macOS 系统 API（`MTLFXSpatialScaler`） | 免许可 | **最低** —— 系统自带，且 **Magpie 没有这个东西** |
| **FSR 1.0 EASU**（放大） | GPUOpen-Effects / **FidelityFX-FSR** | MIT | 低（shader 直译成 Metal） |
| **FSR 1.0 RCAS**（锐化） | 同上 | MIT | 低（与现有 CASPass 同族） |
| **Anime4K** | bloc97 / **Anime4K** | MIT | 中（有 Metal 移植 `imxieyi/Anime4KMetal`，Apache-2.0） |
| NIS / NVSharpen | NVIDIAGameWorks / **NVIDIAImageScaling** | MIT | 低 |
| FSRCNNX / ACNet / CuNNy / RAVU / NNEDI3 | 各自上游（mpv-prescalers 等） | 多为 MIT，**需逐个核对** | 中（GLSL → Metal 转换） |
| CAS（**已有**） | FidelityFX-CAS | MIT | 已完成 |

---

## 4. 图片 / 视频分别怎么落

- **视频 / 游戏 / 图片查看器窗口** —— 我们天然支持：抓的就是窗口。加一个算法档即可全覆盖。
- **单张图片文件（离线放大导出）** —— 这是**另一个形态**：输入文件 → 输出文件，不是覆盖层。
  同一套 Metal shader 可以复用，但建议做成独立 CLI / 小工具，**不要混进主 App**：
  实时覆盖层与离线批处理的验收标准完全不同（延迟 vs 输出质量）。

---

## 5. 建议的落地顺序

1. **MetalFX Spatial 档** —— 零第三方依赖、系统自带、只要一张颜色纹理。
   成本最低，正好用来打通「输出尺寸 ≠ 采集尺寸」的同图 A/B 对比。
2. **FSR 1.0 EASU + RCAS 档** —— 就是用户最初说的「FSR 那种缩放」的本体，MIT 干净。
3. **Anime4K 档** —— 动漫 / 视频 / 日系游戏最合适，用户点名过。
4. NIS / FSRCNNX 等 —— 按需后补。

工作量：架构已在。**加一个档 ≈ `ReconstructMode` 加一个 case + 一个 Metal pass +
UI 一项 + 验证脚本一条**，与现有 `CASPass`（`main.swift:1001` 附近）同一量级。

---

## 6. 未验证 / 风险（诚实清单）

- MetalFX Spatial 在这类源（游戏 720p 带锯齿输出）上比现有 CAS 好多少，**没量过**，
  必须先做同图 A/B（复用 `dev/verify-quality.swift` 的质心间距 + 笔画梯度方法）再定默认档。
- Anime4K 的 Metal 移植是**播放器工程不是库**，复用其 GLSL→Metal 转换器的可行性未评估。
- 上表「多为 MIT」是概览，**落地前每个上游仓库的 LICENSE 要逐个核对**。
- 输出尺寸变大后 LSFG 光流成本按像素数上涨（10-12 文档第 5 节量过约 4×），
  需实测帧率是否达产（`generated` 有没有掉），不能只看功耗。
- Magpie 的**全屏窗口 + 切换前台即退出**这套交互，与本工具的**贴源穿透覆盖层**不同；
  不打算改我们的输出方式（第十三轮定下的唯一输出方式）。
- DLSS-NR 的依赖链（§1b）只在 NVIDIA + Windows 上成立。**不要**因为"有 Magpie 先例"
  就去尝试在 Mac 上复刻 —— 那是重做一个 CUDA→Metal 的移植工程，且上游是**未发布的泄漏二进制**。
