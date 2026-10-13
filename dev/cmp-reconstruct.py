#!/usr/bin/env python3
"""cmp-reconstruct.py — 输出重建档（「档 1」）的客观判据

红线提醒（第十二轮定的）：**不能靠肉眼说「清楚了」**。锐化与缩放是两件事，
必须分开量：
  * 尺度有没有变 → 用「质心间距」（对模糊免疫，模糊不会移动字形簇的质心）
  * 清不清楚     → 用「高频能量 / 边缘梯度」（模糊会直接吃掉它）

再加一条**恒等判据**：CAS 强度 0 时输出必须与「关闭」档**逐像素一致**。
它不合格就说明管线接错了（最常见的就是 uv 映射错 ⇒ 上下颠倒/左右镜像，
而截图上看起来「也挺清楚」，不查根本发现不了）。

用法：
  cmp-reconstruct.py <参考图.png> <待测图.png> [--crop x,y,w,h] [--margin N] [--name 标签]
  cmp-reconstruct.py --ab <off.png> <cas0.png> <cas.png> <lanczos.png>

不给 `--crop` 时会**自动裁掉窗口边框**（见 auto_box），默认再内缩 12px 甩掉闪烁红点。
另外跑批脚本必须关掉界面徽标（`-showBadge NO`）—— 徽标上有 `56fps/57fps` 这种每次都变的
数字，会把恒等判据打到 99.83%（第十五轮实测踩过，差异像素正好是徽标那 247 个）。
"""
import sys
try:
    import numpy as np
except ImportError:  # 系统 python3 里没有 numpy，别只丢个 ModuleNotFoundError 让人猜
    sys.exit("需要 numpy。用本机的受管解释器跑：\n"
             "  /Users/zxwzz/.workbuddy/binaries/python/envs/default/bin/python " + __file__)
from PIL import Image


def auto_box(a, margin=0):
    """从四边向内吃掉「近黑边框」= `SCK` 截 .titled 窗口时留下的透明/阴影/标题栏区
    （实测帧比内容大 12pt 宽 28pt 高；透明区转换后是纯黑），再内缩 `margin` 像素。

    判据用「整行/整列里近黑像素占比 ≥ 50%」——**不要**用「整行均值 < 10」：
    最上面那行只有 25（一像素的窗口圆角亮边混进去了），会被漏掉；
    也别用「均值 > 阈值」找内容，深色源（动画图案那种）会全军覆没。

    `margin` 默认给 12，是为了两件事：
      ① 甩掉窗口圆角/边框的抗锯齿边（那里会掺进内容，放大噪声差异）；
      ② 甩掉 `--soft` 源**右下角那个 6×6 闪烁红点**。它必须存在（静态窗口
         SCK 不送帧，管线就停了），但它每次截图相位都不同 ⇒ 36 个像素会随机
         差到 100 多，把恒等判据从 100.00% 打到 99.99%、"最大差"被它顶到 5.6。
    """
    dark = a < 5
    rm, cm = a.mean(axis=1), a.mean(axis=0)
    # 两条并集：近黑占比 ≥ 50%（边框绝大多数像素是透明→黑），或整行/列均值 ≤ 40
    # （专门兜住第 0 行那种"窗口圆角亮边"：它近黑占比只有 0.02，但均值也才 25）。
    rows = (dark.mean(axis=1) >= 0.5) | (rm <= 40)
    cols = (dark.mean(axis=0) >= 0.5) | (cm <= 40)
    h, w = a.shape
    top = 0
    while top < h - 1 and rows[top]: top += 1
    bot = h - 1
    while bot > top and rows[bot]: bot -= 1
    left = 0
    while left < w - 1 and cols[left]: left += 1
    right = w - 1
    while right > left and cols[right]: right -= 1
    left += margin; top += margin; right -= margin; bot -= margin
    return (left, top, right - left + 1, bot - top + 1)


def luma(path, crop=None):
    a = np.asarray(Image.open(path).convert("RGB")).astype(np.float64)
    if crop:
        x, y, w, h = crop
        a = a[y:y + h, x:x + w]
    return 0.299 * a[:, :, 0] + 0.587 * a[:, :, 1] + 0.114 * a[:, :, 2]


def grad(img):
    """平均绝对梯度（一阶）。模糊会直接把它压低。"""
    gx = np.abs(np.diff(img, axis=1)).mean()
    gy = np.abs(np.diff(img, axis=0)).mean()
    return (gx + gy) / 2


def hf(img):
    """高频能量 = 原图 − 3×3 盒式模糊。这正是锐化在放大的那份东西。"""
    k = np.ones((3, 3)) / 9.0
    p = np.pad(img, 1, mode="edge")
    blur = sum(k[i, j] * p[i:i + img.shape[0], j:j + img.shape[1]]
               for i in range(3) for j in range(3))
    return np.abs(img - blur).mean()


def centroid_spacing(img):
    """字形/色块的质心间距：模糊免疫的尺度判据。

    做法：按列求「暗度」(255−luma) 的一阶矩得横向质心，再拿相邻峰的距离做尺度。
    这里简化成「暗度加权的一阶/零阶矩」——尺度变了它就会变。
    """
    dark = np.clip(255 - img, 0, None)
    colsum = dark.sum(axis=0)
    if colsum.sum() <= 1:
        return float("nan")
    xs = np.arange(len(colsum))
    return float((xs * colsum).sum() / colsum.sum())


def stats(a, b):
    d = np.abs(a - b)
    return dict(mae=d.mean(), mx=d.max(), same=float((d < 0.5).mean()))


def main():
    args = sys.argv[1:]
    if args and args[0] == "--ab":
        off, cas0, cas, lan = args[1:5]
        crop = None
        if "--crop" in args:
            crop = tuple(int(v) for v in args[args.index("--crop") + 1].split(","))
        else:
            m = int(args[args.index("--margin") + 1]) if "--margin" in args else 12
            a0 = np.asarray(Image.open(off).convert("RGB")).astype(np.float64).mean(axis=2)
            crop = auto_box(a0, m)
            print(f"（没给 --crop，自动裁掉窗口边框并内缩 {m}px → {crop}）")
        files = [("关闭 off", off), ("CAS 强度0", cas0), ("CAS 强度0.5", cas), ("Lanczos", lan)]
        imgs = {n: luma(p, crop) for n, p in files}
        base = imgs["关闭 off"]

        print(f"区域 = {crop if crop else '整幅'}   尺寸 = {base.shape[1]}x{base.shape[0]}")
        print()
        print(f"{'档位':<12}{'平均亮度':>10}{'梯度(锐)':>11}{'高频能量':>11}{'质心x':>12}"
              f"{'MAE':>8}{'最大差':>8}{'逐像素一致':>12}")
        print("-" * 84)
        for name, _ in files:
            im = imgs[name]
            s = stats(base, im) if name != "关闭 off" else dict(mae=0, mx=0, same=1.0)
            print(f"{name:<12}{im.mean():>10.2f}{grad(im):>11.4f}{hf(im):>11.4f}"
                  f"{centroid_spacing(im):>12.2f}{s['mae']:>8.3f}{s['mx']:>8.1f}{s['same']*100:>11.2f}%")
        print()
        print("判据：")
        # 恒等判据的基准**要看有没有发生重采样**：
        #   输出 = 采集尺寸 ⇒ 不重采样 ⇒ 基准是「关闭」档（双线性直通）
        #   输出 ≠ 采集尺寸 ⇒ 会重采样 ⇒ 基准必须换成「Lanczos」档（否则量到的是
        #   「换了重采样器」，不是「CAS 有没有破坏画面」—— 两件事必须分开）
        lan_vs_off = stats(base, imgs["Lanczos"])
        ref_name = "关闭 off" if lan_vs_off["mae"] < 0.1 else "Lanczos"
        ref = imgs[ref_name]
        r = stats(ref, imgs["CAS 强度0"])
        ok = r["same"] > 0.999
        print(f"  ① 恒等（CAS 强度0 == {ref_name}）：逐像素一致 {r['same']*100:.2f}%  "
              f"{'✅' if ok else '❌ 管线接错了（uv/翻转/量化）'}   MAE={r['mae']:.4f} 最大差={r['mx']:.1f}")
        g0, g1 = grad(base), grad(imgs["CAS 强度0.5"])
        h0, h1 = hf(base), hf(imgs["CAS 强度0.5"])
        print(f"  ② 锐化：梯度 {g0:.4f} → {g1:.4f} ({(g1/g0-1)*100:+.1f}%)   "
              f"高频 {h0:.4f} → {h1:.4f} ({(h1/h0-1)*100:+.1f}%)  "
              f"{'✅' if g1 > g0 else '❌ 没变清楚'}")
        c0, c1 = centroid_spacing(base), centroid_spacing(imgs["CAS 强度0.5"])
        s3 = stats(base, imgs["CAS 强度0.5"])
        print(f"  ③ 尺度：质心 {c0:.2f} → {c1:.2f}"
              f"  亮度 {base.mean():.2f} → {imgs['CAS 强度0.5'].mean():.2f}  "
              f"MAE={s3['mae']:.3f} 最大差={s3['mx']:.1f}  "
              f"{'✅ 没变形' if abs(c0-c1) < 1.0 else '⚠️ 尺度变了'}")
        l0 = stats(base, imgs["Lanczos"])
        print(f"  ④ 重采样（Lanczos vs 关闭）：MAE={l0['mae']:.3f} 最大差={l0['mx']:.1f}  "
              f"梯度 {grad(base):.4f} → {grad(imgs['Lanczos']):.4f} ({(grad(imgs['Lanczos'])/grad(base)-1)*100:+.1f}%)"
              + ("（输出=采集尺寸 ⇒ 不重采样，应当≈0）" if l0['mae'] < 0.1 else "  ← 放大路径的收益"))
        return 0

    if len(args) < 2:
        print(__doc__)
        return 2
    p1, p2 = args[0], args[1]
    crop = None
    if "--crop" in args:
        crop = tuple(int(v) for v in args[args.index("--crop") + 1].split(","))
    else:
        m = int(args[args.index("--margin") + 1]) if "--margin" in args else 12
        a0 = np.asarray(Image.open(p1).convert("RGB")).astype(np.float64).mean(axis=2)
        crop = auto_box(a0, m)
    a, b = luma(p1, crop), luma(p2, crop)
    s = stats(a, b)
    print(f"尺寸 {a.shape[1]}x{a.shape[0]}")
    print(f"MAE={s['mae']:.4f}  max={s['mx']:.1f}  逐像素一致={s['same']*100:.2f}%")
    print(f"梯度 {grad(a):.4f} → {grad(b):.4f}   高频 {hf(a):.4f} → {hf(b):.4f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
