#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
工装资产扫描器 —— 批量扫描目录里的 .skp，生成资产索引 assets.json

纯只读：不打开 SketchUp、不修改任何 .skp。只用 Python 标准库。

用法:
    python gz_scan.py --index <索引目录> [<目录或文件> ...]

  * 扫过的目录会记在索引里；不带目录参数时，重扫上次记住的全部目录
  * 带目录参数时，新目录追加到记住的列表里

  * 增量：大小和修改时间都没变的文件直接沿用上次结果，不重新解析
  * 在 Windows 上会实际检查外链贴图是否存在（得到真实断链数）；
    其他系统上 Windows 路径无法检查，标记为 unchecked

解析要点（见 skp_audit.py）：
  * .skp 字符串为 UTF-16LE
  * 断链风险由 <Source> 决定：SKETCHUP 为内嵌，TEXTURE_PATH_ABSOLUTE 为外部依赖
  * Version 属性有单引号和双引号两种写法
  * 参数里可能出现 -inf 等非法值
"""
import os
import re
import sys
import json
import time
import argparse
import datetime

INDEX_VERSION = 1
CHUNK = 1 << 26     # 64 MB
OVERLAP = 1 << 20   # 1 MB，远大于单个 XML 块，跨界不漏
SKIP_DIRS = {"$RECYCLE.BIN", "System Volume Information"}

TAG_RE = re.compile(r"<([A-Za-z]+)>([^<>]*)</\1>")
TEX_RE = re.compile(r"<(\w*Texture)>(.*?)</\1>", re.S)
VER_RE = re.compile(r"""Version=['"](\d+)['"]""")
WINPATH_RE = re.compile(r"(?i)^[A-Z]:\\")
USER_RE = re.compile(r"(?i)[A-Z]:\\Users\\([^\\]+)\\")
SKP_VER_RE = re.compile(r"\{(\d+\.\d+\.\d+)\}")
ASCII_RUN = re.compile(rb"(?:[\x20-\x7e]\x00){4,}")

XML_OPEN = "<SketchupMaterial".encode("utf-16-le")
XML_CLOSE = "</SketchupMaterial>".encode("utf-16-le")
SETTINGS_MARK = "Enscape.EmbeddedSettings".encode("utf-16-le")

VENDORS = {
    "3d66": "3d66", "justeasy": "知末", "知末": "知末", "3ddd": "3ddd",
    "3dfreehub": "3dfreehub", "csnzoo": "Wayfair", "pbrmax": "PBRMAX",
    "quixel": "Quixel", "megascan": "Megascans", "bridge": "Quixel Bridge",
    "rdfactory": "RDFactory", "maxtosu": "MaxToSu", "evermotion": "Evermotion",
    "turbosquid": "TurboSquid", "sketchuptexture": "SketchUpTextureClub",
}

IS_WINDOWS = os.name == "nt"


def d16(b):
    try:
        return b.decode("utf-16-le")
    except UnicodeDecodeError:
        return None


def num(v):
    """字段值转有效浮点；-inf / 空 / 文本 返回 None。"""
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    if f != f or f in (float("inf"), float("-inf")):
        return None
    return f


def parse_material(xml, model_dir):
    m = VER_RE.search(xml)
    body = TEX_RE.sub("", xml)
    sc = dict(TAG_RE.findall(body))
    textures = []
    for tm in TEX_RE.finditer(xml):
        fd = dict(TAG_RE.findall(tm.group(2)))
        src = fd.get("Source") or ""
        fp = fd.get("Filepath") or ""
        if src == "SKETCHUP":
            risk = "embedded"
        elif fp:
            if IS_WINDOWS:
                full = fp if os.path.isabs(fp) else os.path.join(model_dir, fp)
                risk = "ok" if os.path.exists(full) else "missing"
            else:
                risk = "unchecked"
        else:
            risk = "none"
        textures.append({"slot": tm.group(1), "source": src,
                         "path": fp, "risk": risk})
    return {
        "schema": m.group(1) if m else None,
        "type": sc.get("Type") or None,
        "roughness": num(sc.get("Roughness")),
        "metallic": num(sc.get("Metallic")),
        "bump": num(sc.get("BumpAmount")),
        "textures": textures,
    }


def scan_file(path):
    size = os.path.getsize(path)
    blocks = {}
    usernames = set()
    vendors = set()
    has_settings = False
    skp_version = None
    with open(path, "rb") as f:
        head = d16(f.read(128)) or ""
        mv = SKP_VER_RE.search(head)
        skp_version = mv.group(1) if mv else None
        pos = 0
        while pos < size:
            f.seek(pos)
            buf = f.read(CHUNK + OVERLAP)
            if not buf:
                break
            if not has_settings and SETTINGS_MARK in buf:
                has_settings = True
            s = 0
            while True:
                i = buf.find(XML_OPEN, s)
                if i < 0:
                    break
                g = pos + i
                if g not in blocks:
                    j = buf.find(XML_CLOSE, i)
                    if j > 0:
                        x = d16(buf[i:j + len(XML_CLOSE)])
                        if x:
                            blocks[g] = x
                s = i + 1
            for m in ASCII_RUN.finditer(buf):
                t = d16(m.group())
                if not t:
                    continue
                if ":\\" in t:
                    usernames.update(USER_RE.findall(t))
                low = t.lower()
                for k, label in VENDORS.items():
                    if k in low:
                        vendors.add(label)
            pos += CHUNK

    # 同样内容的材质块去重（同一模型里会重复出现）
    model_dir = os.path.dirname(path)
    materials = [parse_material(x, model_dir) for x in dict.fromkeys(blocks.values())]
    tex = [t for m in materials for t in m["textures"]]
    return {
        "skp_version": skp_version,
        "has_enscape": bool(blocks) or has_settings,
        "materials": materials,
        "stats": {
            "materials": len(materials),
            "textures": len(tex),
            "external": sum(1 for t in tex if t["risk"] in ("ok", "missing", "unchecked")),
            "missing": sum(1 for t in tex if t["risk"] == "missing") if IS_WINDOWS else None,
        },
        "vendors": sorted(vendors),
        "usernames": sorted(usernames),
    }


def iter_skp(roots):
    for root in roots:
        if os.path.isfile(root):
            if root.lower().endswith(".skp"):
                yield os.path.abspath(root)
            continue
        for dirpath, dirnames, filenames in os.walk(root, onerror=lambda e: None):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for fn in filenames:
                if fn.lower().endswith(".skp") and not fn.startswith("AutoSave_"):
                    yield os.path.abspath(os.path.join(dirpath, fn))


def load_index(path):
    """返回 (上次的文件记录 {path: rec}, 上次记住的目录列表)"""
    if not os.path.isfile(path):
        return {}, []
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}, []
    if data.get("version") != INDEX_VERSION:
        return {}, []
    return {r["path"]: r for r in data.get("files", [])}, data.get("roots", [])


def write_index(path, roots, files):
    data = {
        "version": INDEX_VERSION,
        "scanned_at": datetime.datetime.now().isoformat(timespec="seconds"),
        "host_os": os.name,
        "roots": roots,
        "files": files,
    }
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def main():
    try:
        sys.stdout.reconfigure(errors="replace")
    except AttributeError:
        pass
    ap = argparse.ArgumentParser(description="扫描 .skp 生成资产索引")
    ap.add_argument("--index", required=True, help="索引目录（assets.json 写在这里）")
    ap.add_argument("roots", nargs="*", help="要扫描的目录或 .skp 文件（不填则重扫上次的目录）")
    a = ap.parse_args()

    os.makedirs(a.index, exist_ok=True)
    index_path = os.path.join(a.index, "assets.json")
    old, old_roots = load_index(index_path)
    roots = list(dict.fromkeys(old_roots + [os.path.abspath(r) for r in a.roots]))
    if not roots:
        print("还没有要扫描的目录。\n请把要扫描的文件夹（可以一次选多个）拖到 scan.bat 上。")
        return
    gone = [r for r in roots if not os.path.exists(r)]
    for r in gone:
        print(f"注意：目录不存在，本次跳过（仍保留在列表里）：{r}")
    print("扫描目录：\n  " + "\n  ".join(roots))

    paths = list(dict.fromkeys(iter_skp(roots)))
    print(f"找到 {len(paths)} 个 .skp 文件")
    files, reused, failed = [], 0, 0
    t_all = time.time()
    for n, p in enumerate(paths, 1):
        try:
            st = os.stat(p)
        except OSError as e:
            print(f"[{n}/{len(paths)}] 无法读取 {p}: {e}")
            failed += 1
            continue
        prev = old.get(p)
        if prev and prev.get("size") == st.st_size and prev.get("mtime") == st.st_mtime \
                and not prev.get("error"):
            files.append(prev)
            reused += 1
            continue
        rec = {"path": p, "name": os.path.splitext(os.path.basename(p))[0],
               "size": st.st_size, "mtime": st.st_mtime, "error": None}
        t0 = time.time()
        try:
            rec.update(scan_file(p))
            s = rec["stats"]
            miss = f"，断链 {s['missing']}" if s["missing"] is not None else ""
            print(f"[{n}/{len(paths)}] {p}  材质 {s['materials']}，外链 {s['external']}{miss}"
                  f"  ({time.time() - t0:.1f}s)")
        except Exception as e:  # 单个文件坏了不影响其他文件
            rec["error"] = f"{type(e).__name__}: {e}"
            failed += 1
            print(f"[{n}/{len(paths)}] 解析失败 {p}: {rec['error']}")
        files.append(rec)

    write_index(index_path, roots, files)
    total_mat = sum(r.get("stats", {}).get("materials", 0) for r in files)
    total_ext = sum(r.get("stats", {}).get("external", 0) for r in files)
    print(f"\n完成：{len(files)} 个文件（沿用 {reused}，失败 {failed}），"
          f"材质 {total_mat}，外链贴图 {total_ext}，用时 {time.time() - t_all:.0f}s")
    if IS_WINDOWS:
        total_miss = sum((r.get("stats", {}).get("missing") or 0) for r in files)
        print(f"本机实际找不到的贴图：{total_miss}")
    print(f"索引已写入：{index_path}")


if __name__ == "__main__":
    main()
