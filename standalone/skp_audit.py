#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SketchUp .skp 材质资产体检脚本 v2

纯只读：不打开 SketchUp、不修改原文件、不需要 GPU、不需要插件。
产出：贴图外部依赖 / 命名与来源 / 材质参数 / schema 版本 / 出图设置 体检报告。

用法:
    python3 skp_audit.py <file.skp> [-o report.md]

要点:
  * .skp 字符串为 UTF-16LE，ASCII strings 零命中（必须按 UTF-16 搜）
  * 断链风险由 <Source> 决定，不由路径决定：
      SKETCHUP              -> 像素已被 SketchUp 内嵌进 .skp，Filepath 只是缓存/来源记录
      TEXTURE_PATH_ABSOLUTE -> Enscape 直读外部文件，这才是真外部依赖
  * schema Version 属性存在单引号与双引号两种写法，正则须同时覆盖
  * V1 块里存在 Metallic = -inf 等非法值，统计前必须剔除
"""
import re
import os
import sys
import argparse
import datetime
import collections

CHUNK = 1 << 26     # 64 MB
OVERLAP = 1 << 20   # 1 MB，远大于单个 XML 块，跨界不漏

DICT_MARKERS = [
    "Enscape.Material", "Enscape.Light", "Enscape.PointLight",
    "Enscape.LinearLight", "Enscape_ies", "Enscape.EmbeddedSettings",
    "VRayInfo", "VRayPlugins", "BRDFVRayMtl",
]

TAG_RE = re.compile(r"<([A-Za-z]+)>([^<>]*)</\1>")
TEX_RE = re.compile(r"<(\w*Texture)>(.*?)</\1>", re.S)
VER_RE = re.compile(r"""Version=['"](\d+)['"]""")
WINPATH_RE = re.compile(r"(?i)^[A-Z]:\\")
TEMP_RE = re.compile(r"(?i)\\AppData\\Local\\Temp\\")
USER_RE = re.compile(r"(?i)[A-Z]:\\Users\\([^\\]+)\\")
RESX_RE = re.compile(r'"ScreenshotResolutionX":\s*\{\s*"Value":\s*(\d+)')
RESY_RE = re.compile(r'"ScreenshotResolutionY":\s*\{\s*"Value":\s*(\d+)')
SETKEY_RE = re.compile(r'"([A-Za-z][A-Za-z0-9_]*)":\s*\{\s*"Value":')

# 第三方素材站指纹（出现在贴图路径/文件名里）
VENDORS = {
    "3d66": "3d66 模型网", "justeasy": "justeasy 知末", "3ddd": "3ddd",
    "3dfreehub": "3dfreehub", "sketchuptexture": "SketchUpTextureClub",
    "cgaxis": "CGAxis", "quixel": "Quixel", "megascan": "Megascans",
    "evermotion": "Evermotion", "turbosquid": "TurboSquid",
    "dmodel": "dmodel", "知末": "justeasy 知末(中文名)",
}

ASCII_RUN = re.compile(rb"(?:[\x20-\x7e]\x00){2,}")


def d16(b):
    try:
        return b.decode("utf-16-le")
    except UnicodeDecodeError:
        return None


def d16_lossy(b):
    """窗口取样用：尾部必然截进二进制，必须容错，否则整段被吞成空。"""
    return b[:(len(b) // 2) * 2].decode("utf-16-le", "replace")


def num(v):
    """把字段值转成有效浮点；非法值（-inf / 空 / 文本）返回 None。"""
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    if f != f or f in (float("inf"), float("-inf")):
        return None
    return f


def scan(path):
    size = os.path.getsize(path)
    r = {
        "size": size, "blocks": {}, "markers": collections.Counter(),
        "usernames": collections.Counter(), "res_pairs": collections.Counter(),
        "setting_keys": set(), "header": b"",
    }
    marker_b = {m: m.encode("utf-16-le") for m in DICT_MARKERS}
    oc = "<SketchupMaterial".encode("utf-16-le")
    cc = "</SketchupMaterial>".encode("utf-16-le")
    res_b = '"ScreenshotResolutionX"'.encode("utf-16-le")
    seen_res = set()
    set_b = '"Settings"'.encode("utf-16-le")
    seen = collections.defaultdict(set)

    with open(path, "rb") as f:
        r["header"] = f.read(128)
        pos = 0
        while pos < size:
            f.seek(pos)
            buf = f.read(CHUNK + OVERLAP)
            if not buf:
                break

            for name, needle in marker_b.items():
                s = 0
                while True:
                    i = buf.find(needle, s)
                    if i < 0:
                        break
                    g = pos + i
                    if g not in seen[name]:
                        seen[name].add(g)
                        r["markers"][name] += 1
                    s = i + 1

            s = 0
            while True:
                i = buf.find(oc, s)
                if i < 0:
                    break
                g = pos + i
                if g not in r["blocks"]:
                    j = buf.find(cc, i)
                    if j > 0:
                        x = d16(buf[i:j + len(cc)])
                        if x:
                            r["blocks"][g] = x
                s = i + 1

            # 出图分辨率 + 可用设置键名（为 .json 预设库做准备）
            s = 0
            while True:
                i = buf.find(res_b, s)
                if i < 0:
                    break
                g = pos + i
                if g not in seen_res:
                    seen_res.add(g)
                    txt = d16_lossy(buf[i:i + 4000])
                    mx = RESX_RE.search(txt)
                    my = RESY_RE.search(txt)
                    if mx and my:
                        r["res_pairs"][(int(mx.group(1)), int(my.group(1)))] += 1
                s = i + 1
            s = 0
            while True:
                i = buf.find(set_b, s)
                if i < 0:
                    break
                r["setting_keys"].update(
                    SETKEY_RE.findall(d16_lossy(buf[i:i + 400000])))
                s = i + 1

            for m in ASCII_RUN.finditer(buf):
                t = d16(m.group())
                if t and ":\\" in t:
                    for u in USER_RE.findall(t):
                        r["usernames"][u] += 1

            pos += CHUNK
    return r


def analyze(r):
    a = {
        "ver": collections.Counter(), "quote": collections.Counter(),
        "grid": collections.Counter(), "slots": collections.Counter(),
        "src": collections.Counter(), "dirs": collections.Counter(),
        "files": [], "vendors": collections.Counter(),
        "params": collections.defaultdict(list), "bad": collections.Counter(),
        "types": collections.Counter(), "ext_paths": [],
        "temp_embedded": 0, "temp_external": 0,
    }
    for g, x in r["blocks"].items():
        m = VER_RE.search(x)
        a["ver"][m.group(1) if m else "无"] += 1
        a["quote"]["单引号" if "Version='" in x else "双引号"] += 1

        body = TEX_RE.sub("", x)
        sc = dict(TAG_RE.findall(body))
        a["types"][sc.get("Type") or "(空·V1 旧块未填)"] += 1
        for k in ("Roughness", "Metallic", "BumpAmount", "Specular",
                  "Opacity", "IndexOfRefraction", "EmissiveStrength"):
            if k in sc:
                v = num(sc[k])
                if v is None:
                    a["bad"][k] += 1
                else:
                    a["params"][k].append(v)

        for tm in TEX_RE.finditer(x):
            slot = tm.group(1)
            fd = dict(TAG_RE.findall(tm.group(2)))
            src = fd.get("Source") or "(无 Source 标签)"
            fp = fd.get("Filepath", "")
            a["slots"][slot] += 1
            a["src"][src] += 1
            a["grid"][(slot, src)] += 1
            if fp:
                base = fp.replace("\\", "/").rsplit("/", 1)[-1]
                a["files"].append(base)
                low = fp.lower()
                for k, label in VENDORS.items():
                    if k.lower() in low:
                        a["vendors"][label] += 1
                if TEMP_RE.search(fp):
                    if src == "SKETCHUP":
                        a["temp_embedded"] += 1
                    else:
                        a["temp_external"] += 1
                if src != "SKETCHUP" and WINPATH_RE.match(fp):
                    a["ext_paths"].append((slot, fp))
                    a["dirs"]["\\".join(fp.split("\\")[:-1])] += 1
    return a


def build_report(path, r, a):
    L = []
    w = L.append
    hdr = (d16(r["header"]) or "")
    mv = re.search(r"\{(\d+\.\d+\.\d+)\}", hdr)
    nb = len(r["blocks"])
    ext = len(a["ext_paths"])
    emb = a["src"].get("SKETCHUP", 0)
    ens_slots = {"BumpTexture", "RoughnessTexture", "SpecularTexture", "MaskTexture"}
    ens_total = sum(n for (s, _), n in a["grid"].items() if s in ens_slots)
    ens_ext = sum(n for (s, x), n in a["grid"].items()
                  if s in ens_slots and x != "SKETCHUP")
    dif_total = sum(n for (s, _), n in a["grid"].items() if s == "DiffuseTexture")
    dif_emb = a["grid"].get(("DiffuseTexture", "SKETCHUP"), 0)

    w("# 材质资产体检报告")
    w("")
    w(f"- 样本：`{path}`")
    w(f"- 体积：{r['size'] / (1<<30):.2f} GB（{r['size']:,} 字节）")
    w(f"- SketchUp 格式版本：`{mv.group(1) if mv else '未识别'}`")
    w(f"- 生成时间：{datetime.date.today()}")
    w("- 方式：**纯只读二进制解析**。未打开 SketchUp、未修改原文件、未使用 GPU。")
    w("")
    w("---")
    w("")
    if nb == 0:
        w("**本模型里没有找到 Enscape 材质数据**（`<SketchupMaterial>` 块为 0）。")
        w("")
        w("本工具只解析 Enscape 写进 .skp 的材质信息，没有这部分数据时无法评估贴图外部依赖和材质参数。"
          "模型如果没用过 Enscape，这是正常的；SketchUp 原生材质的贴图请在 SketchUp 里检查。")
        return "\n".join(L)

    w("## 1. 数据盘点")
    w("")
    w("| 属性字典 | 命中数 |")
    w("|---|---|")
    for k, v in sorted(r["markers"].items(), key=lambda x: -x[1]):
        w(f"| `{k}` | {v} |")
    w("")
    w(f"完整解析出 `<SketchupMaterial>` XML 块：**{nb} 个**，")
    w(f"贴图槽引用 **{sum(a['slots'].values())}** 条。")
    w("")
    if nb > r["markers"].get("Enscape.Material", 0):
        w(f"> ⚠️ XML 块数（{nb}）> `Enscape.Material` 字典命中数"
          f"（{r['markers'].get('Enscape.Material', 0)}）。"
          "组件定义内部的材质各自带一份字典是最可能的原因，"
          "但本脚本不开 SketchUp 无法确证。**做命名映射前需 Ruby 侧 "
          "`model.materials` 导出核对，不要直接把这个数字当材质总数用。**")
        w("")

    w("## 2. 贴图外部依赖体检（断链风险）")
    w("")
    w("风险由 `<Source>` 决定，**不由路径决定**：路径看起来再危险（比如在 Temp 里），只要像素已内嵌就不会断链。")
    w("")
    w("| Source | 含义 | 数量 | 断链风险 |")
    w("|---|---|---|---|")
    meaning = {
        "SKETCHUP": ("像素已由 SketchUp 内嵌进 .skp，`Filepath` 只是 Enscape 的解包缓存或原始来源记录",
                     "🟢 无。清 Temp / 换机后 Enscape 会从内嵌数据重建"),
        "TEXTURE_PATH_ABSOLUTE": ("Enscape 直读该外部文件，模型内不存像素",
                                  "🔴 高。文件移动 / 换机 / 换盘符即丢"),
        "(无 Source 标签)": ("旧 schema 未写 Source，行为需实测",
                             "🟠 未知，按外部依赖对待"),
    }
    for k, v in sorted(a["src"].items(), key=lambda x: -x[1]):
        mn, rk = meaning.get(k, ("—", "—"))
        w(f"| `{k}` | {mn} | {v} | {rk} |")
    w("")
    w("### 按贴图槽 × Source 交叉（关键表）")
    w("")
    srcs = sorted(a["src"], key=lambda s: -a["src"][s])
    w("| 贴图槽 | " + " | ".join(f"`{s}`" for s in srcs) + " | 合计 |")
    w("|---" * (len(srcs) + 2) + "|")
    for slot in sorted(a["slots"], key=lambda s: -a["slots"][s]):
        cells = [str(a["grid"].get((slot, s), 0)) for s in srcs]
        w(f"| `{slot}` | " + " | ".join(cells) + f" | {a['slots'][slot]} |")
    w("")
    w(f"**结构性结论**：`DiffuseTexture` 共 {dif_total} 条，其中 {dif_emb} 条"
      f"（{dif_emb / max(dif_total,1):.0%}）是内嵌的 —— 因为 SketchUp 原生材质自带一张贴图，"
      "会随模型存进 .skp。")
    w("")
    w(f"而 Enscape 专属槽（Bump / Roughness / Specular / Mask）共 {ens_total} 条，"
      f"其中 **{ens_ext} 条（{ens_ext / max(ens_total,1):.0%}）必须外链** —— "
      "SketchUp 原生材质没有这些槽位，无处内嵌。")
    w("")
    ens_abs = sum(1 for s_, _ in a["ext_paths"] if s_ in ens_slots)
    dif_abs = ext - ens_abs
    w(f"→ **真正的断链风险 = {ext} 条外部绝对路径，其中 {ens_abs} 条在 Enscape 专属槽、"
      f"{dif_abs} 条在 Diffuse 槽。**")
    w("")

    if a["dirs"]:
        w("### 外部依赖目录（Top 15）")
        w("")
        w("| 目录 | 引用数 |")
        w("|---|---|")
        for d, c in a["dirs"].most_common(15):
            w(f"| `{d}` | {c} |")
        w("")

    if r["usernames"]:
        w("### 路径里的 Windows 用户名")
        w("")
        w("| 用户名 | 出现次数 |")
        w("|---|---|")
        for u, c in r["usernames"].most_common(15):
            w(f"| `{u}` | {c} |")
        w("")
        w(f"→ **{len(r['usernames'])}** 个不同用户名，多人多机拼接，无统一素材管理。")
        w("")

    w("## 3. 贴图来源与命名")
    w("")
    if a["vendors"]:
        w("| 第三方素材来源指纹 | 命中 |")
        w("|---|---|")
        for k, v in a["vendors"].most_common():
            w(f"| {k} | {v} |")
        w("")
    pats = [
        ("V-Ray 残留命名 `vray_*`", re.compile(r"(?i)^vray[_\-]")),
        ("3ds Max 导出残留（lambert / LOD / 长数字 ID）",
         re.compile(r"(?i)(lambert|_LOD\d|^\d{6,})")),
        ("含中文", re.compile(r"[一-鿿]")),
        ("哈希式无意义文件名（纯 16 进制）", re.compile(r"(?i)^[0-9a-f]{12,}\.")),
    ]
    files = sorted(set(a["files"]))
    w(f"去重后贴图文件名 **{len(files)}** 个。命名模式分布：")
    w("")
    w("| 模式 | 数量 |")
    w("|---|---|")
    for label, rx in pats:
        w(f"| {label} | {sum(1 for x in files if rx.search(x))} |")
    w("")
    w("样本（前 25）：")
    w("")
    w("```")
    for x in files[:25]:
        w(x)
    w("```")
    w("")
    w("> 注：这里统计的是**贴图文件名**，不是 SketchUp 材质名。"
      "材质名不存在 Enscape 的 XML 里，`.skp` 侧无法可靠关联，"
      "命名映射方案必须靠 Ruby 导出。")
    w("")

    w("## 4. Enscape XML schema 版本分布")
    w("")
    w("| Version | 块数 |")
    w("|---|---|")
    for k, v in sorted(a["ver"].items(), key=lambda x: str(x[0])):
        w(f"| `{k}` | {v} |")
    w("")
    w("属性引号写法：" + "、".join(f"{k} × {v}" for k, v in a["quote"].items())
      + "（解析器必须同时覆盖，否则漏块）")
    w("")
    w("> 参考：在作者测过的模型里，各版本标量字段集基本一致，差异主要是 `DoubleSided` / "
      "`NormalMapIntensity` / `ImageFade` / `IsSolidGlass` 等可选项的有无。")
    w("")
    vers = sorted(k for k in a["ver"] if k != "无")
    if len(vers) > 1:
        w(f"本模型出现了 {len(vers)} 个 Version（{'、'.join(vers)}），说明被多个 Enscape 版本编辑过。"
          "**批量改写材质前，请先确认团队实际使用的 Enscape 版本。**")
        w("")

    w("## 5. 材质参数分布")
    w("")
    w("| 参数 | 有效值数 | 最小 | 最大 | 均值 | 中位数 |")
    w("|---|---|---|---|---|---|")
    for k in ("Roughness", "Metallic", "BumpAmount", "Specular",
              "Opacity", "IndexOfRefraction", "EmissiveStrength"):
        v = sorted(a["params"].get(k, []))
        if v:
            med = v[len(v) // 2]
            w(f"| `{k}` | {len(v)} | {v[0]:.4f} | {v[-1]:.4f} | "
              f"{sum(v)/len(v):.4f} | {med:.4f} |")
    w("")
    if a["bad"]:
        w("**非法值（已从统计中剔除）**：" +
          "、".join(f"`{k}` × {v}" for k, v in a["bad"].items()) +
          "。常见为 `-inf`，多出现在旧版本的材质块里。"
          "**如果要用程序批量改写参数，先做值域钳制（0–1），否则会把脏值传下去。**")
        w("")
    w("材质类型：" + "、".join(f"`{k}` × {v}" for k, v in a["types"].most_common()))
    w("")

    w("## 6. 出图设置体检")
    w("")
    if r["res_pairs"]:
        w("| 分辨率预设 | 出现次数 | 评价 |")
        w("|---|---|---|")
        from math import gcd
        for (x, y), c in r["res_pairs"].most_common():
            judge = ("🔴 1080p，大图展示偏低" if x <= 1920
                     else "🟢 4K 级，够大图展示" if x >= 3000 else "🟠 中等")
            d = gcd(x, y)
            w(f"| {x} × {y}（{x//d}:{y//d}） | {c} | {judge} |")
        w("")
    w(f"模型内可程序化读写的 Enscape 视觉设置键共 **{len(r['setting_keys'])}** 个"
      "（可以据此整理成统一的出图预设）。")
    w("")
    picks = [k for k in sorted(r["setting_keys"])
             if re.search(r"(?i)exposure|bloom|light|shadow|fog|cloud|white|"
                          r"contrast|saturat|depth|field|auto", k)][:24]
    if picks:
        w("与曝光、灯光、阴影、雾、景深相关的键（节选）：")
        w("")
        w("```")
        for k in picks:
            w(k)
        w("```")
        w("")

    w("## 7. 结论")
    w("")
    n = 0
    def item(text):
        nonlocal n
        n += 1
        w(f"{n}. {text}")
        w("")
    if ext:
        where = "全部在 Enscape 专属槽" if ens_abs == ext else f"{ens_abs} 条在 Enscape 专属槽、{dif_abs} 条在 Diffuse 槽"
        item(f"**真外部依赖 {ext} 条**（{where}）。这是需要治理的断链面："
             "把这些文件收拢到项目素材目录，其余内嵌贴图不用动。")
    else:
        item("**没有外部绝对路径的贴图**，换机、换盘符不会断链。")
    temp_n = a["temp_embedded"] + a["temp_external"]
    if temp_n:
        tail = (f"其余 {a['temp_external']} 条非内嵌，已计入外部依赖" if a["temp_external"] else "全部已内嵌")
        item(f"指向 `%TEMP%` 的贴图 {temp_n} 条，其中 {a['temp_embedded']} 条 `Source=SKETCHUP` "
             f"不是风险（{tail}）：像素已内嵌在 .skp 里，Temp 只是 Enscape 的解包缓存，清掉会自动重建。")
    if len(r["usernames"]) > 1 or a["vendors"]:
        item(f"模型内有 **{len(r['usernames'])}** 个 Windows 用户名、"
             f"**{len(a['vendors'])}** 个第三方素材站指纹，"
             + ("说明模型经过多人多机编辑、混有下载素材，建议统一素材管理。" if len(r["usernames"]) > 1
                else "说明混有下载素材。"))
    vers = sorted(k for k in a["ver"] if k != "无")
    if len(vers) > 1:
        item(f"Enscape schema 有 **{len(vers)}** 个 Version，批量改写材质前先确认实际使用的 Enscape 版本。")
    if a["bad"]:
        item("存在 `-inf` 等非法参数值，**程序批量改写时必须钳制值域**。")
    w("> 本报告全程只读，未对原始 .skp 做任何写入。")
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("skp")
    ap.add_argument("-o", "--out")
    g = ap.parse_args()
    if not os.path.isfile(g.skp):
        sys.exit(f"找不到文件: {g.skp}")
    r = scan(g.skp)
    a = analyze(r)
    rep = build_report(g.skp, r, a)
    if g.out:
        with open(g.out, "w", encoding="utf-8") as f:
            f.write(rep)
        print(f"报告已写入: {g.out}")
    else:
        print(rep)


if __name__ == "__main__":
    main()
