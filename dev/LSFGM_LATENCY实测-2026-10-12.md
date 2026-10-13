# 实测：`LSFGM_LATENCY=1` 能不能降延迟？

日期：2026-10-12（第九轮） · 机器：M4 / macOS 15.8.1 / 主屏 Q24T09 2560×1440@144Hz
问题（用户原话）：「开 LSFGM_LATENCY=1 实跑一轮，看能不能降延迟」

**结论一句话：不能降 —— 它是诊断开关。但这一轮第一次把「延迟到底花在哪」量出来了，
而且顺手修掉了两个「根本测不出数」的坑。**

---

## 一、A/B 结论：开与不开没差别

固定条件（与历史测量可比）：源 640×400（`dev/testpattern --ruler`）/ 光流 **0.5** /
queueDepth 3（默认）/ 工作分辨率 **400p** / **2×** / **144Hz 主屏** / 输出窗 620×400。
工具 `dev/lat-round.sh`（标尺相对位置法，每轮 15 个样本）。

交错重复（base → lat → base → lat），**每轮都核对了引擎日志 `generated` 在涨**
（`original=1440 generated=1438` 量级）：

| 轮次 | `LSFGM_LATENCY` | 中位数 | 均值 | 范围 |
| --- | --- | --- | --- | --- |
| base（第一轮） | 关 | 25 ms | 26 ms | 21–34 |
| base-a | 关 | **27 ms** | 26 ms | 7–38 |
| base-b | 关 | **26 ms** | 27 ms | 18–37 |
| lat1（第一轮） | **开** | 29 ms | 28 ms | 23–32 |
| lat-a | **开** | **26 ms** | 25 ms | 11–33 |
| lat-b | **开** | **26 ms** | 26 ms | 12–33 |

⇒ **差异落在噪声内（±2 ms）。`LSFGM_LATENCY=1` 不改变延迟。**

⚠️ 本轮绝对值比历史 21 ms（2×）高约 4~5 ms —— 是**与倍率无关的加法偏移**、**不是退化**，
但也**不是**并发实例造成的（初版归因错了，见第五节）。

---

## 二、它真正的价值：把延迟拆开（原始日志）

`LSFGM_LATENCY=1` 让引擎每 120 次回调写一条分解（每项是 `p50/p95`，单位 ms）：

```
(lsfg-metal) [INFO]: Metal display intervals=240 p50_ms=6.945 p95_ms=13.889 stdev_ms=3.1 late=60
(lsfg-metal) [INFO]: Metal latency kind=original samples=120 dropped=0
      enqueue_display_ms=26.252/30.221 queue_ms=0.012/0.029 worker_ms=0.410/0.879
      drawable_ms=0.012/0.044 submit_display_ms=25.915/29.501
(lsfg-metal) [INFO]: Metal latency kind=generated samples=120 dropped=0
      enqueue_display_ms=19.882/23.445 queue_ms=0.012/0.026 worker_ms=0.330/0.599
      drawable_ms=0.027/0.065 submit_display_ms=19.632/22.912
```

三次独立运行的数值高度一致（`worker_ms` 0.30–0.41、`enqueue_display_ms` 19.2–19.9 生成 /
26.1–26.8 原帧）。144Hz 下一个刷新周期 = **6.944 ms**。

| 环节 | 实测 | 占延迟比例 | 含义 |
| --- | --- | --- | --- |
| `worker_ms` | 0.35 / 0.30 | ~1% | 光流 + 插值**计算本身**（400p 下 <1 ms） |
| `queue_ms` | 0.012 | ~0 | 命令队列排队 |
| `drawable_ms` | 0.011 / 0.026 | ~0 | 取 CAMetalDrawable |
| **`enqueue_display_ms`** | **26.2（原帧）/ 19.4（生成帧）** | **≈99%** | 入队 → 真正上屏（送显排队） |
| `display intervals` | p50 = 6.945 | — | 恰好 1 个刷新周期 ⇒ 引擎中位数每 vblank 送一张新画面（合格） |
| `late` | 60/240 = 25% | — | 1/4 的显示间隔晚了一个 vblank（p95 = 2 个周期） |

### 两条推论

1. **两个独立通道对上了。** 引擎自报原帧 `enqueue_display` ≈ **26 ms**；我们用标尺
   相对位置法测的端到端也是 **26 ms**。⇒ **采集侧（ScreenCaptureKit）几乎不引入额外延迟**，
   延迟全部在「送显排队」。
2. **这就是为什么过去所有软件旋钮都无效。** `--resolution` / `--drawable-count` /
   `--no-display-sync` / `LSFGM_TARGET_FPS` / `LSFGM_FLOW_SCALE` 都不碰「一帧要等几个
   vblank 才上屏」这条路径。降延迟只能改**倍率**和**屏幕刷新率** —— 微观上正好解释了
   「144Hz 上延迟 =（倍率＋1）× 刷新周期」那条规律。

---

## 三、顺手修掉的两个坑（不改代码根本测不出数）

### 坑 1：偏好里勾着「游戏模式」会让 `--test-window` 也走覆盖层贴源

第一次跑出来 15 个样本**全是** `源 0.387 · 插帧 0.387 · Δ 0.000 → 0 ms`。
查 `CGWindowListCopyWindowInfo`：源窗口 `id=6102 rect=40,740 640x400`，
输出窗口 `id=6106 rect=40,740 640x400` —— **完全重合**。

根因（`main.swift`）：

```swift
var gameMode: Bool = hasFlag("--game-mode") || UserDefaults.standard.bool(forKey: "gameMode")
```

用户的偏好里 `gameMode = true`（他正在用游戏模式看红果短剧），于是每次启动都是游戏模式；
游戏模式的输出层**精确贴住源窗口** ⇒ 相对位置法把两个窗口当成一个，延迟恒为 0。

**修法**（已改 `main.swift`）：

```swift
var gameMode: Bool = (hasFlag("--game-mode") || UserDefaults.standard.bool(forKey: "gameMode"))
    && !hasFlag("--no-game-mode") && !hasFlag("--test-window")
```

`--test-window`（自检模式）强制关掉游戏模式，另加显式逃生舱 `--no-game-mode`。
⚠️ 这个坑只在「偏好里开着游戏模式」时出现 —— 所以以前测的时候没暴露。

### 坑 2：`lat-round.sh` 只 `tail` 最后几行会丢掉中位数

跑 A/B 时用 `| grep … | tail -12` 看结果，中位数那行被引擎日志挤掉了，两轮数据白跑。
**修法**：整轮输出同时落盘 `/tmp/lat-round-<标签>.out`。

### 附带改进

`dev/lat-round.sh` 第 11 个参数起是**额外引擎环境变量**（做旋钮 A/B）：

```sh
dev/lat-round.sh 1 2 2 40 300 700 300 2560 1440 lat1 LSFGM_LATENCY=1
```

---

## 四、复现步骤

```sh
cd ~/Documents/WindowInterp
# A（对照）：基准 2×
./dev/lat-round.sh 1 2 2 40 300 700 300 2560 1440 base LSFGM_LATENCY=0
# B（实验）：开引擎延迟统计
./dev/lat-round.sh 1 2 2 40 300 700 300 2560 1440 lat  LSFGM_LATENCY=1
# 看结果（中位数在 .out 里，别只 tail 终端）
grep -E "^(==|样本)" /tmp/lat-round-base.out /tmp/lat-round-lat.out
grep -E "Metal latency|Metal display intervals" /tmp/lat-round-lat.out
```

参数顺序：`<screencapture序号> <CGDirectDisplayID> <倍率|off> <源x> <源y> <输出x> <输出y>
<期望截图宽> <期望截图高> <标签> [额外KEY=VALUE…]`。
`--test-window` 的输出窗位置是 AppKit 坐标（原点左下），所以 `--test-y 300 --test-h 400`
在 1440 高的屏上落到 CG 的 y=740。

---

## 五、⚠️ 本轮数字比历史高 4~5 ms —— 原因**未定**，且已确认**不是**并发实例

| 配置 | 历史（第五轮） | 本轮（第九轮 + 19:50 复核） |
| --- | --- | --- |
| 原帧（off） | 14 ms | **18 / 19 / 19 ms** |
| 2× | 21 ms | **26 / 30 / 25 ms** |

偏移约 +4 ms 且**与倍率无关**（不插帧的基线也一起抬高）⇒ 是**加法偏移**，出在
「采集 → 渲染 → 送显」这条**固定**链路上，不是插帧开销变大 —— `2× − off` 仍然是
7~8 ms，与历史完全一致。

**已排除（本节初版写错了，用户当场纠正，证据站在用户这边）**：
初版我写「用户自己还有个 5× 实例在跑、抢 GPU」。错。证据：
`~/Library/Logs/WindowInterp/engine-55379.log`（他那个 5× 实例的引擎日志）最后一笔是
**19:34:22**，而本轮全部测量发生在 **19:40–19:45** ⇒ 它当时**根本没在出帧**
（暂停状态下采集/渲染都停了，日志自然不动）。pid 55379 进程虽在，
但「进程活着」≠「在算帧」。

**仍未排除**（都没有证据，别当结论）：
① 他那个实例暂停后**窗口还留在 144Hz 主屏上**（`CGWindowList` 可见一个 1200×678 的浮层
   + 一个 768×588 的 5× 控制窗）—— 多两个合成层，代价理应是微秒级，但没实测；
② 我手工 `swiftc -O` 那份二进制 vs 官方 `build.sh` 产物；
③ 第六~八轮给普通模式新加的 HUD / 角标层；
④ 纯粹是两次会话的合成器/窗口排布差异。

⇒ **绝对值的跨会话比较不可靠**；本报告所有结论都建立在**同一次会话内的 A/B** 上
（这是站得住的：A/B 两臂带着同一个偏移）。

---

## 五之补、我复核时自己踩的坑（19:50，记下来免得再犯）

用户说「我没开 5×」之后，我立刻重测想验证「有没有并发实例的差别」。结果四轮全测出
59~100 ms 的垃圾值。根因是我自己的一行 zsh：

```zsh
for spec in "roff1 off" "r2x1 2"; do set -- $spec; ./dev/lat-round.sh 1 2 "$2" …  # ← zsh 不切分!
```

**zsh 默认不做 word-split**（不像 bash），`set -- $spec` 把整串塞进 `$1`、`$2` 为空
⇒ 传给 App 的是 `--multiplier ""` ⇒ App 不报错、**静默回落到偏好里的 5×**
（`main.swift:74`：`Int(argument("--multiplier") ?? "") ?? savedMultiplier`），
于是四轮「对照」全在跑 5×。`app.log` 白纸黑字：

```
2026-10-12T11:51:36Z launch v1.1.0-game2 pid=63910 multiplier=5 … args=… --multiplier
                                                                          ↑ 空
```

修好后重测：**off 19/19 ms、2× 30/25 ms**，与此前（18 / 26）一致 ⇒ 之前的主数据没坏。

顺手加的两个防呆：
* `dev/lat-round.sh` 支持 `BIN_OVERRIDE=<另一份 App 的二进制>` 做对照（怀疑二进制差异时用）；
* `main.swift` 现在对**解析不了的 `--multiplier`** 写一条
  `warn: --multiplier "…" 解析不了 → 回落到偏好 5×`（进 app.log），
  不再一声不吭地跑成别的东西。已重编译 + 固定自签身份签名（DR 不变）。

---

## 六、改动的文件

| 文件 | 改了什么 |
| --- | --- |
| `main.swift` | ①`gameMode` 表达式加 `!hasFlag("--no-game-mode") && !hasFlag("--test-window")`，并写清原因注释 ②`--multiplier` 解析失败时往 stderr 报警（不再静默回落） |
| `dev/lat-round.sh` | ①第 11 参数起额外引擎 env ②整轮输出落盘 `/tmp/lat-round-<标签>.out` ③引擎日志 grep 增加延迟统计行 ④`BIN_OVERRIDE` 可换另一份二进制做对照 |
| `README.md` | 延迟章节新增「延迟到底花在哪」分解表；旋钮表 `LSFGM_LATENCY` 一行改为「只报数不降延迟」；新增第九轮实测记录；测量配方补 `--test-window` 关游戏模式的说明；订正第五节那个错误的「并发实例抢 GPU」归因 |

⚠️ 重新编译时**没有跑 `build.sh`** —— 它结尾会 `ditto` 覆盖桌面上那份**正在运行的**日常副本。
本轮改为手动 `swiftc -O` + `codesign --sign "WindowInterp Local Signing"`（固定自签身份 ⇒
DR 不变 ⇒ 屏幕录制授权不失效）。**桌面副本仍是旧的**，需要时再跑一次 `./build.sh` 同步。
