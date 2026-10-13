#!/usr/bin/env python3
"""把别的着色器包重灌进 lsfg-vk.dll 的 PE 资源段。

背景（2026-10-12 实测得到的引擎行为）：
  * lsfg-metal 通过 **PE 资源段**（类型 10 = RCDATA）读取 SPIR-V 着色器；
  * 它按**固定 ID/名字表**索取着色器，缺一个就报
        Shader '<name>' missing from DLL
    然后优雅降级（不再插帧，正常 present），不会崩；
  * LSFGM_DLL_PATH 只取**父目录**，固定去找里面名为 lsfg-vk.dll 的文件。

用法:
  rebuild-lsfg-dll.py <骨架PE> <新着色器来源PE> <输出路径> [--keep-ids]

  --keep-ids  保留来源里的原始资源 ID（默认重编号为 0..N-1，
              以匹配骨架引擎期望的 ID 方案）
"""
import struct
import sys
import os
from collections import Counter

SPIRV_MAGIC = b"\x03\x02\x23\x07"
DXBC_MAGIC = b"DXBC"
RT_RCDATA = 10
RT_VERSION = 16
RT_MANIFEST = 24
LANG = 1033


# ---------------------------------------------------------------- PE 解析

def sections(d):
    """返回 [(name, va, vsize, rawptr, rawsize)] 与资源数据目录 RVA。"""
    pe = struct.unpack_from("<I", d, 0x3C)[0]
    if d[pe:pe + 4] != b"PE\0\0":
        raise ValueError("不是 PE 文件")
    nsec = struct.unpack_from("<H", d, pe + 6)[0]
    opt = pe + 24
    magic = struct.unpack_from("<H", d, opt)[0]
    ddoff = opt + (112 if magic == 0x20B else 96)
    rsrc_rva = struct.unpack_from("<I", d, ddoff + 2 * 8)[0]
    sec = opt + struct.unpack_from("<H", d, pe + 20)[0]
    out = []
    for i in range(nsec):
        o = sec + i * 40
        nm = d[o:o + 8].rstrip(b"\0").decode("latin1")
        vs, va, rs, ptr = struct.unpack_from("<IIII", d, o + 8)
        out.append((nm, va, vs, ptr, rs))
    return out, rsrc_rva


def read_resources(d):
    """解析资源树，返回 {(type, name, lang): bytes}。"""
    secs, rsrc_rva = sections(d)

    def r2o(rva):
        for _nm, va, vs, ptr, rs in secs:
            if va <= rva < va + max(vs, rs):
                return ptr + (rva - va)
        return None

    base = r2o(rsrc_rva)
    out = {}

    def walk(off, lvl, path):
        nnamed, nid = struct.unpack_from("<HH", d, off + 12)
        for i in range(nnamed + nid):
            e = off + 16 + i * 8
            name_or_id, offv = struct.unpack_from("<II", d, e)
            isdir = bool(offv & 0x80000000)
            o2 = offv & 0x7FFFFFFF
            if name_or_id & 0x80000000:
                tp = base + (name_or_id & 0x7FFFFFFF)
                ln = struct.unpack_from("<H", d, tp)[0]
                tag = d[tp + 2:tp + 2 + ln * 2].decode("utf-16le", "replace")
            else:
                tag = name_or_id
            if isdir:
                if lvl < 2:
                    walk(base + o2, lvl + 1, path + (tag,))
            else:
                de = base + o2
                drva, dsz = struct.unpack_from("<II", d, de)
                doff = r2o(drva)
                out[path + (tag,)] = d[doff:doff + dsz]
    walk(base, 0, ())
    return out


def pick_shaders(res):
    """从资源字典里挑出所有 SPIR-V 着色器，按 ID 排序。

    资源键可能是数字 ID，也可能是字符串名（打包器会把 ID 0 写成名为 "0" 的
    命名资源），两种都归一化成 int。
    """
    items = []
    for k, v in res.items():
        if len(k) != 3 or k[0] != RT_RCDATA or v[:4] != SPIRV_MAGIC:
            continue
        nm = k[1]
        if isinstance(nm, str):
            if not nm.isdigit():
                continue
            nm = int(nm)
        items.append((nm, v))
    items.sort(key=lambda t: t[0])
    return items


# ---------------------------------------------------------------- PE 资源构造

class ResBuilder:
    """按 Windows 标准布局构造资源段：目录 → 数据条目 → 数据。"""

    def __init__(self):
        self.root = {}          # type -> {name -> {lang: bytes}}

    def add(self, rtype, name, lang, data):
        self.root.setdefault(rtype, {}).setdefault(name, {})[lang] = data

    def build(self, rsrc_rva):
        # 先规划目录结构，算出每层目录的偏移
        dir_blobs = []          # (offset_placeholder_index, bytes)
        layout = []             # 依次排布

        def dir_size(entries):
            return 16 + 8 * len(entries)

        # 收集所有目录：root、每个 type、每个 (type,name)
        dirs = []               # (key, entries)  entries=[(name_or_id, child_key_or_None, data_key)]

        root_entries = []
        for t in sorted(self.root):
            names = sorted(self.root[t], key=lambda x: (isinstance(x, str), x))
            type_entries = []
            for nm in names:
                langs = sorted(self.root[t][nm])
                lang_entries = []
                for lg in langs:
                    lang_entries.append((lg, None))
                type_entries.append((nm, lang_entries))
            root_entries.append((t, type_entries))

        # 分配目录偏移：深度优先，父在前
        offsets = {}
        cursor = 0

        def alloc_dir(key, entries):
            nonlocal cursor
            offsets[key] = cursor
            cursor += 16 + 8 * len(entries)

        alloc_dir((), root_entries)
        for t, type_entries in root_entries:
            alloc_dir((t,), type_entries)
            for nm, lang_entries in type_entries:
                alloc_dir((t, nm), lang_entries)

        # 数据条目紧随目录之后
        data_entry_offsets = {}

        def alloc_data_entry(key):
            nonlocal cursor
            data_entry_offsets[key] = cursor
            cursor += 16

        for t, type_entries in root_entries:
            for nm, lang_entries in type_entries:
                for lg, _ in lang_entries:
                    alloc_data_entry((t, nm, lg))

        # 数据区：4 字节对齐
        cursor = (cursor + 3) & ~3
        data_offsets = {}
        for t, type_entries in root_entries:
            for nm, lang_entries in type_entries:
                for lg, _ in lang_entries:
                    blob = self.root[t][nm][lg]
                    data_offsets[(t, nm, lg)] = cursor
                    cursor += len(blob)
                    cursor = (cursor + 3) & ~3
        total = cursor

        buf = bytearray(total)

        def write_dir(key, entries, is_root=False, is_type=False, parent_type=None):
            off = offsets[key]
            # 头部：Characteristics, TimeDateStamp, MajorVersion, MinorVersion, NamedEntries, IdEntries
            named = sum(1 for e in entries if isinstance(e[0], str))
            ident = sum(1 for e in entries if not isinstance(e[0], str))
            struct.pack_into("<IIHHHH", buf, off, 0, 0, 0, 0, named, ident)
            # 排序：命名条目在前（按字符串），ID 条目在后（按数值升序）
            ordered = sorted(entries, key=lambda e: (0, e[0]) if isinstance(e[0], str) else (1, e[0]))
            for i, (name, child) in enumerate(ordered):
                eo = off + 16 + i * 8
                if isinstance(name, str):
                    # 命名条目：指向字符串表 —— 本工具不生成命名条目
                    raise ValueError("不支持命名资源条目")
                if is_root:
                    child_key = (name,)
                    struct.pack_into("<II", buf, eo, name, 0x80000000 | offsets[child_key])
                else:
                    child_key = (parent_type, name)
                    struct.pack_into("<II", buf, eo, name, 0x80000000 | offsets[child_key])

        write_dir((), root_entries, is_root=True)
        for t, type_entries in root_entries:
            write_dir((t,), type_entries, is_type=True, parent_type=t)
            for nm, lang_entries in type_entries:
                off = offsets[(t, nm)]
                struct.pack_into("<IIHHHH", buf, off, 0, 0, 0, 0, 0, len(lang_entries))
                for i, (lg, _) in enumerate(sorted(lang_entries)):
                    eo = off + 16 + i * 8
                    struct.pack_into("<II", buf, eo, lg, data_entry_offsets[(t, nm, lg)])

        # 数据条目 + 数据
        for t, type_entries in root_entries:
            for nm, lang_entries in type_entries:
                for lg, _ in lang_entries:
                    deo = data_entry_offsets[(t, nm, lg)]
                    do = data_offsets[(t, nm, lg)]
                    blob = self.root[t][nm][lg]
                    struct.pack_into("<IIII", buf, deo, rsrc_rva + do, len(blob), 0, 0)
                    buf[do:do + len(blob)] = blob
        return bytes(buf)


def build(new_shaders, extra, rsrc_rva):
    """new_shaders: [(id, bytes)]; extra: {(type,name,lang): bytes}"""
    rb = ResBuilder()
    for i, (_orig_id, blob) in enumerate(new_shaders):
        rb.add(RT_RCDATA, i, LANG, blob)
    for (t, nm, lg), blob in extra.items():
        rb.add(t, nm, lg, blob)
    return rb.build(rsrc_rva)


def read_resources_ex(d):
    """解析资源树，返回 ({(type,name,lang): bytes}, {(type,name,lang): dataEntry文件偏移})。"""
    secs, rsrc_rva = sections(d)

    def r2o(rva):
        for _nm, va, vs, ptr, rs in secs:
            if va <= rva < va + max(vs, rs):
                return ptr + (rva - va)
        return None

    base = r2o(rsrc_rva)
    out = {}
    entryoff = {}

    def walk(off, lvl, path):
        nnamed, nid = struct.unpack_from("<HH", d, off + 12)
        for i in range(nnamed + nid):
            e = off + 16 + i * 8
            name_or_id, offv = struct.unpack_from("<II", d, e)
            isdir = bool(offv & 0x80000000)
            o2 = offv & 0x7FFFFFFF
            if name_or_id & 0x80000000:
                tp = base + (name_or_id & 0x7FFFFFFF)
                ln = struct.unpack_from("<H", d, tp)[0]
                tag = d[tp + 2:tp + 2 + ln * 2].decode("utf-16le", "replace")
            else:
                tag = name_or_id
            if isdir:
                if lvl < 2:
                    walk(base + o2, lvl + 1, path + (tag,))
            else:
                de = base + o2
                drva, dsz = struct.unpack_from("<II", d, de)
                doff = r2o(drva)
                out[path + (tag,)] = d[doff:doff + dsz]
                entryoff[path + (tag,)] = de
    walk(base, 0, ())
    return out, entryoff, rsrc_rva


def rewrite_minimal(skel, new_shader_blobs, outpath):
    """保持资源目录树原封不动，只按顺序替换 RCDATA 里的 SPIR-V 数据块。

    这是最保守的做法：引擎的 PE 解析器看到的目录结构和原来**逐字节一致**，
    只有每个数据块的 RVA/size 与内容变了。
    """
    secs, rsrc_rva = sections(skel)
    rsrc = next(s for s in secs if s[0] == ".rsrc")
    _nm, _va, rsrc_vsize, rsrc_rawptr, rsrc_rawsize = rsrc

    res, entryoff, _ = read_resources_ex(skel)

    # 叶子顺序：按资源树遍历顺序（= 原文件里的物理顺序）
    order = list(res.keys())

    # 找出原来的数据区起点（所有 DataEntry 偏移的最小值）与树区终点
    tree_end = 0
    data_start = None
    for k in order:
        de = entryoff[k]
        rel = de - rsrc_rawptr
        tree_end = max(tree_end, rel + 16)
        drva = struct.unpack_from("<I", skel, de)[0]
        if rsrc_rva <= drva < rsrc_rva + rsrc_rawsize:
            off = drva - rsrc_rva
            if data_start is None or off < data_start:
                data_start = off
    if data_start is None:
        data_start = (tree_end + 3) & ~3

    # 组装新的数据区
    buf = bytearray(skel)
    blob_regions = bytearray(len(skel) - rsrc_rawptr)
    # 数据区起点之前的一切（目录、数据条目、名字串）原样保留 —— 引擎的 PE
    # 解析器必须看到和原文件完全一样的结构。
    start = data_start
    blob_regions[:start] = skel[rsrc_rawptr:rsrc_rawptr + start]

    cursor = start

    si = 0
    replaced = 0
    for k in order:
        blob = res[k]
        if len(k) == 3 and k[0] == RT_RCDATA and blob[:4] == SPIRV_MAGIC:
            if si < len(new_shader_blobs):
                blob = new_shader_blobs[si]
                replaced += 1
            si += 1
        newoff = (cursor + 3) & ~3
        blob_regions[newoff:newoff + len(blob)] = blob
        struct.pack_into("<II", blob_regions, entryoff[k] - rsrc_rawptr,
                         rsrc_rva + newoff, len(blob))
        cursor = newoff + len(blob)

    if cursor > rsrc_rawsize:
        print(f"❌ 装不下：需要 {cursor}，只有 {rsrc_rawsize}")
        return 1
    print(f"替换了 {replaced} 个着色器；数据区 {data_start}..{cursor}（可用 {rsrc_rawsize}）")

    buf[rsrc_rawptr:rsrc_rawptr + rsrc_rawsize] = bytes(blob_regions[:rsrc_rawsize]).ljust(rsrc_rawsize, b"\0")
    open(outpath, "wb").write(bytes(buf))
    print(f"✅ 已写出 {outpath}")

    chk, _e, _r = read_resources_ex(open(outpath, "rb").read())
    got = pick_shaders(chk)
    print(f"回读：{len(got)} 个 SPIR-V；与输入一致 = {[b for _i, b in got] == list(new_shader_blobs)}")
    return 0


# ---------------------------------------------------------------- 主流程

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    if len(args) != 3:
        print(__doc__)
        return 2
    skeleton, source, outpath = args
    keep_ids = "--keep-ids" in flags
    minimal = "--minimal" in flags

    skel = open(skeleton, "rb").read()
    src = open(source, "rb").read()

    if minimal:
        shaders = pick_shaders(read_resources(src))
        if not shaders:
            print("来源文件里没有 SPIR-V 着色器")
            return 1
        print(f"骨架 {os.path.basename(skeleton)}: "
              f"{len(pick_shaders(read_resources(skel)))} 个 SPIR-V")
        print(f"来源 {os.path.basename(source)}: {len(shaders)} 个 SPIR-V, "
              f"ID {shaders[0][0]}..{shaders[-1][0]}")
        return rewrite_minimal(skel, [b for _i, b in shaders], outpath)

    secs, rsrc_rva = sections(skel)
    rsrc_sec = next(s for s in secs if s[0] == ".rsrc")
    _nm, _va, rsrc_vsize, rsrc_rawptr, rsrc_rawsize = rsrc_sec

    sres = read_resources(skel)
    shaders = pick_shaders(read_resources(src))
    if not shaders:
        print("来源文件里没有 SPIR-V 着色器")
        return 1

    extra = {k: v for k, v in sres.items()
             if len(k) == 3 and k[0] in (RT_VERSION, RT_MANIFEST)}
    skel_shaders = pick_shaders(sres)

    print(f"骨架 {os.path.basename(skeleton)}: {len(skel_shaders)} 个 SPIR-V, "
          f"ID {skel_shaders[0][0]}..{skel_shaders[-1][0]}")
    print(f"来源 {os.path.basename(source)}: {len(shaders)} 个 SPIR-V, "
          f"ID {shaders[0][0]}..{shaders[-1][0]}")

    if keep_ids:
        new_shaders = shaders
    else:
        new_shaders = [(i, b) for i, (_o, b) in enumerate(shaders)]

    blob = build(new_shaders, extra, rsrc_rva)
    tail = len(blob) + 4
    print(f"新资源段 {len(blob)} B（含 {len(extra)} 个附加资源）；可用 {rsrc_rawsize} B")
    if tail > rsrc_rawsize:
        print(f"❌ 装不下：需要 {tail}，只有 {rsrc_rawsize}")
        return 1

    out = bytearray(skel)
    out[rsrc_rawptr:rsrc_rawptr + rsrc_rawsize] = blob.ljust(rsrc_rawsize, b"\0")
    open(outpath, "wb").write(bytes(out))
    print(f"✅ 已写出 {outpath}（{len(out)} B，与原文件同尺寸）")

    # 回读校验
    chk = read_resources(open(outpath, "rb").read())
    got = pick_shaders(chk)
    ok = [b for _i, b in got]
    want = [b for _i, b in new_shaders]
    print(f"回读：{len(got)} 个 SPIR-V，逐字节一致 = {ok == want}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
