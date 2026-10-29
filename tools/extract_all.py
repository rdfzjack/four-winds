#!/usr/bin/env python3
"""Unpack the original Shanghai 1940 files into extracted/.

Usage:
    python3 tools/extract_all.py [--src shanghai1940] [--out extracted] [--only images,cities,...]

Steps (each can be run alone with --only):
    palettes  .col / .idx            -> extracted/palettes/
    images    .pic / .spr            -> extracted/images/<Folder>/
    psd       WP/*.PCC (Photoshop)   -> extracted/wp/
    fonts     Font/*                 -> extracted/fonts/
    text      .ai + exe strings      -> extracted/text/
    cities    .cit                   -> extracted/data/cities/
    audio     Sound/*                -> extracted/audio/   (copied unchanged)
    video     Sprite/*.avi           -> extracted/video/   (converted to .ogv if ffmpeg exists)
    devfiles  Map.lib / Houses.lib   -> extracted/devfiles/ (identifier lists only)
    manifest  every source file      -> extracted/manifest.csv

The original files are only read, never modified.
Requires Python 3.10+ and Pillow. ffmpeg is optional (video only).
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import shutil
import struct
import subprocess
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from fw_formats import (SHADOW, TRANSPARENT, frame_to_image, read_color_idx,  # noqa: E402
                        read_palette, read_pic, read_spr)
from fw_city import (BUILDING_SPRITE_KINDS, COMPANY_GROUPS, PERSON_IDS,  # noqa: E402
                     read_city)

STATUS: dict[str, dict] = {}   # source relative path -> manifest row


def note(src: Path, root: Path, kind: str, status: str, outputs=(), detail: str = "") -> None:
    rel = src.relative_to(root).as_posix()
    STATUS[rel] = {
        "source": rel,
        "kind": kind,
        "status": status,
        "outputs": ";".join(str(o) for o in outputs),
        "detail": detail,
    }


def write_json(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=1), encoding="utf-8")


def write_csv(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    keys: list[str] = []
    for r in rows:
        for k in r:
            if k not in keys:
                keys.append(k)
    # utf-8-sig so Excel on Windows opens the Chinese text correctly
    with path.open("w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(rows)


def ci_find(root: Path, rel: str) -> Path:
    """Case-insensitive lookup (the game was written for Windows)."""
    p = root
    for part in rel.replace("\\", "/").split("/"):
        hit = [c for c in p.iterdir() if c.name.lower() == part.lower()]
        if not hit:
            raise FileNotFoundError(rel)
        p = hit[0]
    return p


# ------------------------------------------------------------------ palettes

def step_palettes(src: Path, out: Path) -> dict:
    from PIL import Image

    pals = {}
    for p in sorted(src.rglob("*")):
        if p.suffix.lower() != ".col":
            continue
        pal = read_palette(p)
        name = f"{p.parent.name}_{p.stem}"
        pals[p.relative_to(src).as_posix()] = pal
        sw = Image.new("RGB", (16, 16))
        sw.putdata(pal)
        sw = sw.resize((256, 256), Image.NEAREST)
        o_png = out / "palettes" / f"{name}.png"
        o_json = out / "palettes" / f"{name}.json"
        o_png.parent.mkdir(parents=True, exist_ok=True)
        sw.save(o_png)
        write_json(o_json, {"source": p.relative_to(src).as_posix(),
                            "colors": ["#%02x%02x%02x" % c for c in pal]})
        note(p, src, "palette", "ok", [o_png.relative_to(out), o_json.relative_to(out)],
             "256 colours, 8-bit RGB after an 8-byte header")
    for p in sorted(src.rglob("*")):
        if p.suffix.lower() != ".idx":
            continue
        tables = read_color_idx(p)
        remap = []
        for i, t in enumerate(tables):
            remap.append({"table": i, "owner": PERSON_IDS.get(i - 1, "none") if i else "none",
                          "changes": {str(j): t[j] for j in range(256) if t[j] != j}})
        o = out / "palettes" / "Color_idx_owner_recolor.json"
        write_json(o, {"source": p.relative_to(src).as_posix(),
                       "note": "9 remap tables; table 0 = identity, tables 1-8 recolour "
                               "indices 56 and 184-191 (flag / owner marker colours). "
                               "Which table belongs to which player is not confirmed.",
                       "tables": remap})
        note(p, src, "palette remap", "ok", [o.relative_to(out)], "9 x 256-byte colour remap tables")
    return pals


# ------------------------------------------------------------------ images

def _smoothness(frame, pal) -> float:
    """Lower = neighbouring pixels have closer colours (used to pick a palette)."""
    w, h = frame.width, frame.height
    px = frame.pixels
    tot, n = 0, 0
    step = max(1, (w * h) // 40000)
    for i in range(0, w * h - 1, step):
        a, b = px[i], px[i + 1]
        if a < 0 or b < 0 or (i + 1) % w == 0:
            continue
        ca, cb = pal[a], pal[b]
        tot += abs(ca[0] - cb[0]) + abs(ca[1] - cb[1]) + abs(ca[2] - cb[2])
        n += 1
    return tot / n if n else 0.0


def _pick_palette(frames, pals: dict, folder: str) -> str:
    main = "Sprite/1940.col"
    if folder.lower() != "sub":
        return main
    alt = "Sub/Main.col"
    sample = frames[:3]
    s_main = sum(_smoothness(f, pals[main]) for f in sample)
    s_alt = sum(_smoothness(f, pals[alt]) for f in sample)
    return alt if s_alt < s_main else main


def _sheet(frames_by_group, pal):
    """Pack frames into a grid: one row per group, one column per frame."""
    from PIL import Image

    cw = max((f.width for g in frames_by_group for f in g), default=1)
    ch = max((f.height for g in frames_by_group for f in g), default=1)
    cols = max((len(g) for g in frames_by_group), default=1)
    sheet = Image.new("RGBA", (cw * cols, ch * len(frames_by_group)), (0, 0, 0, 0))
    rects = []
    for gi, g in enumerate(frames_by_group):
        row = []
        for fi, f in enumerate(g):
            x, y = fi * cw, gi * ch
            sheet.paste(frame_to_image(f, pal), (x, y))
            row.append({"rect": [x, y, f.width, f.height],
                        "header_x": f.x, "header_y": f.y,
                        "anchor": [f.hot_x, f.hot_y], "prefix": f.prefix,
                        "mode": f.mode})
        rects.append(row)
    return sheet, rects


def _building_preview(groups, pal):
    """Re-assemble isometric building slices side by side (one view per direction).

    Rule found by trial: slices sit next to each other left to right, each
    drawn so that its anchor_y lines up with a common ground line. Correct for
    most buildings; 3-slice ones (Hua_y, Xiao_y) show small seams.
    """
    from PIL import Image

    views = []
    for g in groups:
        real = [f for f in g if f.width > 2]
        if not real:
            continue
        top = max(f.hot_y for f in real)
        bottom = max(f.height - f.hot_y for f in real)
        w = sum(f.width for f in real)
        img = Image.new("RGBA", (w, top + bottom), (0, 0, 0, 0))
        x = 0
        for f in real:
            img.alpha_composite(frame_to_image(f, pal), (x, top - f.hot_y))
            x += f.width
        views.append(img)
    if not views:
        return None
    W = sum(v.width for v in views) + 8 * (len(views) - 1)
    H = max(v.height for v in views)
    out = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    x = 0
    for v in views:
        out.alpha_composite(v, (x, H - v.height))
        x += v.width + 8
    return out


def step_images(src: Path, out: Path, pals: dict) -> None:
    for p in sorted(src.rglob("*")):
        ext = p.suffix.lower()
        if ext not in (".pic", ".spr"):
            continue
        rel = p.relative_to(src)
        folder = rel.parts[0] if len(rel.parts) > 1 else ""
        odir = out / "images" / folder
        odir.mkdir(parents=True, exist_ok=True)
        try:
            if ext == ".pic":
                f = read_pic(p)
                pal_name = _pick_palette([f], pals, folder)
                img = frame_to_image(f, pals[pal_name])
                o = odir / f"{p.stem}.png"
                img.save(o, optimize=True)
                meta = {"source": rel.as_posix(), "width": f.width, "height": f.height,
                        "screen_pos": [f.x, f.y], "anchor": [f.hot_x, f.hot_y],
                        "compression": {0: "raw", 1: "rle", 2: "rle"}[f.mode],
                        "palette": pal_name,
                        "has_transparency": TRANSPARENT in f.pixels,
                        "has_shadow": SHADOW in f.pixels}
                write_json(odir / f"{p.stem}.json", meta)
                note(p, src, "image (.pic)", "ok", [o.relative_to(out)],
                     f"{f.width}x{f.height}, {meta['compression']}, palette {pal_name}")
            else:
                s = read_spr(p)
                allf = [f for g in s.groups for f in g]
                pal_name = _pick_palette(allf, pals, folder)
                sheet, rects = _sheet(s.groups, pals[pal_name])
                o = odir / f"{p.stem}.png"
                sheet.save(o, optimize=True)
                meta = {"source": rel.as_posix(), "palette": pal_name,
                        "default_group": s.default_group,
                        "group_params": s.group_params,
                        "groups": rects,
                        "note": "Sheet layout: one row per group (animation / facing), "
                                "one column per frame. 'rect' = x, y, w, h in the sheet. "
                                "'anchor' = header fields 2-3 (draw offset). "
                                "For walking characters header_x and prefix hold the "
                                "per-frame step in pixels."}
                outputs = [o.relative_to(out)]
                if folder.lower() == "build":
                    prev = _building_preview(s.groups, pals[pal_name])
                    if prev is not None:
                        po = odir / f"{p.stem}.preview.png"
                        prev.save(po, optimize=True)
                        outputs.append(po.relative_to(out))
                write_json(odir / f"{p.stem}.json", meta)
                note(p, src, "sprite (.spr)", "ok", outputs,
                     f"{len(s.groups)} group(s), {len(allf)} frame(s), palette {pal_name}")
        except Exception as e:  # keep going, report in manifest
            note(p, src, "image", "failed", [], str(e))


# ------------------------------------------------------------------ PSD

def step_psd(src: Path, out: Path) -> None:
    from PIL import Image

    for p in sorted(src.rglob("*")):
        if p.suffix.lower() != ".pcc":
            continue
        o = out / "wp" / f"{p.stem}.png"
        o.parent.mkdir(parents=True, exist_ok=True)
        try:
            im = Image.open(p)
            layers = [l[0] for l in getattr(im, "layers", [])]
            im.load()                      # merged composite (before any seek)
            im.convert("RGB").save(o, optimize=True)
            note(p, src, "Photoshop PSD", "ok", [o.relative_to(out)],
                 f"{im.size[0]}x{im.size[1]} {im.mode}, layers: {', '.join(layers) or 'none'}")
        except Exception as e:
            note(p, src, "Photoshop PSD", "failed", [], str(e))


# ------------------------------------------------------------------ fonts

def step_fonts(src: Path, out: Path) -> None:
    from PIL import Image

    fdir = out / "fonts"
    fdir.mkdir(parents=True, exist_ok=True)
    asc = ci_find(src, "Font/Asc16")
    d = asc.read_bytes()
    img = Image.new("L", (16 * 9, 16 * 17), 255)
    for c in range(256):
        g = d[c * 16:(c + 1) * 16]
        ox, oy = (c % 16) * 9, (c // 16) * 17
        for r in range(16):
            for b in range(8):
                if g[r] & (0x80 >> b):
                    img.putpixel((ox + b, oy + r), 0)
    img.save(fdir / "Asc16.png")
    note(asc, src, "bitmap font", "ok", [(fdir / "Asc16.png").relative_to(out)],
         "8x16 ASCII, 256 glyphs, 16 bytes each")

    for name, label in (("H16_j", "simplified"), ("H16_f", "traditional")):
        p = ci_find(src, f"Font/{name}")
        d = p.read_bytes()
        n = len(d) // 32
        rows = (n + 93) // 94
        img = Image.new("L", (94 * 17, rows * 17), 255)
        for i in range(n):
            g = d[i * 32:(i + 1) * 32]
            ox, oy = (i % 94) * 17, (i // 94) * 17
            for r in range(16):
                bits = (g[r * 2] << 8) | g[r * 2 + 1]
                for b in range(16):
                    if bits & (0x8000 >> b):
                        img.putpixel((ox + b, oy + r), 0)
        o = fdir / f"{name}.png"
        img.save(o, optimize=True)
        note(p, src, "bitmap font", "ok", [o.relative_to(out)],
             f"16x16 Chinese ({label}), {n} glyphs x 32 bytes, indexed by GB2312 "
             "(row-0xA1)*94+(col-0xA1); sheet rows = GB2312 rows")
    write_json(fdir / "fonts.json", {
        "Asc16": "8x16 ASCII bitmap, 1 bit per pixel, MSB = left",
        "H16_j": "HZK16-style 16x16 simplified Chinese, GB2312 order; glyph index = (b1-0xA1)*94 + (b2-0xA1)",
        "H16_f": "same layout but traditional glyph shapes (e.g. 币 drawn as 幣)",
    })


# ------------------------------------------------------------------ text

AI_KEY_RE = re.compile(r"^\s*(\d*)_int\s+(\w+)\s*=\s*(-?\d+)\s*;?\s*(?://(.*))?$")


def parse_ai(text: str) -> dict:
    out: dict = {"profiles": {}, "comments": {}}
    current = None
    for line in text.splitlines():
        s = line.strip()
        if not s:
            continue
        if s.endswith("：") or s.endswith(":"):
            current = s.rstrip("：:")
            out["profiles"][current] = {}
            continue
        m = AI_KEY_RE.match(s)
        if m and current:
            _, key, val, comment = m.groups()
            out["profiles"][current][key] = int(val)
            if comment and key not in out["comments"]:
                out["comments"][key] = comment.strip()
    return out


def exe_strings(exe: Path) -> list[dict]:
    """GBK strings from the .rdata/.data sections of 1940.exe."""
    d = exe.read_bytes()
    pe_off = struct.unpack_from("<I", d, 0x3C)[0]
    n_sec = struct.unpack_from("<H", d, pe_off + 6)[0]
    opt_size = struct.unpack_from("<H", d, pe_off + 20)[0]
    sec_off = pe_off + 24 + opt_size
    ranges = []
    for i in range(n_sec):
        name = d[sec_off + i * 40:sec_off + i * 40 + 8].rstrip(b"\0").decode()
        raw_size, raw_ptr = struct.unpack_from("<II", d, sec_off + i * 40 + 16)
        if name in (".rdata", ".data"):
            ranges.append((raw_ptr, raw_ptr + raw_size))
    res = []
    pat = re.compile(rb"(?:[\x81-\xfe][\x40-\xfe]|[\x20-\x7e\t\r\n]){2,}\x00")
    for a, b in ranges:
        for m in pat.finditer(d, a, b):
            raw = m.group()[:-1]
            if len(re.findall(rb"[\x81-\xfe][\x40-\xfe]", raw)) < 2:
                continue
            try:
                s = raw.decode("gbk")
            except UnicodeDecodeError:
                continue
            if re.search(r"[一-鿿]", s) is None:
                continue
            # drop short decoded binary noise: require mostly CJK / punctuation
            cjk = len(re.findall(r"[　-〿一-鿿＀-￯]", s))
            if cjk < 2 or cjk < len(s.strip()) * 0.3:
                continue
            res.append({"offset": f"0x{m.start():06x}", "text": s})
    return res


CHARACTERS = [
    # person_id, code used in file names, name, role tag from const.h
    (0, "dyy", "董莺雨", "NV_XS", "Nu_x"),
    (1, "sm", "四毛", "LIU_LE", "Liu_l"),
    (2, "bdl", "包德利", "MAI_B", "Mai_b"),
    (3, "cml", "陈玛丽", "FU_JXJ", "Fu_j"),
    (4, "szz", "赛珍珠", "JIAO_JH", "Jao_j"),
    (5, "fqm", "冯全篾", "HEI_B", "Hei_b"),
    (6, "fdr", "发达而", "WAI_GR", "Wai_g"),
    (7, "jrs", "金如山", "BAO_SP", "Tu_c"),
]


def step_text(src: Path, out: Path) -> None:
    tdir = out / "text"
    # .ai personality files
    for p in sorted(src.rglob("*")):
        if p.suffix.lower() != ".ai":
            continue
        txt = p.read_bytes().decode("gbk")
        parsed = parse_ai(txt)
        parsed["source"] = p.relative_to(src).as_posix()
        o_json = tdir / "ai" / f"{p.stem}.json"
        o_txt = tdir / "ai" / f"{p.stem}.utf8.txt"
        write_json(o_json, parsed)
        o_txt.write_text(txt, encoding="utf-8")
        rows = [{"profile": k, **v} for k, v in parsed["profiles"].items()]
        o_csv = tdir / "ai" / f"{p.stem}.csv"
        write_csv(o_csv, rows)
        note(p, src, "AI personality (GBK text)", "ok",
             [x.relative_to(out) for x in (o_json, o_csv, o_txt)],
             f"{len(parsed['profiles'])} profiles x 12 parameters")

    # strings inside the exe
    exe = ci_find(src, "1940.exe")
    strs = exe_strings(exe)
    o = tdir / "exe_strings.json"
    write_json(o, {"source": "1940.exe", "encoding": "GBK",
                   "note": "All Chinese strings found in .rdata/.data, in file order. "
                           "Some story lines are stored in reverse order of use.",
                   "strings": strs})
    write_csv(tdir / "exe_strings.csv", strs)

    # Character bios: short lines (one per text-box row) stored back to back,
    # 0x28 bytes apart. A new bio starts after a larger gap.
    by_off = sorted(strs, key=lambda s: int(s["offset"], 16))
    blocks, cur, last = [], [], None
    for s in by_off:
        off = int(s["offset"], 16)
        if last is not None and off - last > 0x30:
            if cur:
                blocks.append(cur)
            cur = []
        cur.append(s["text"])
        last = off
    if cur:
        blocks.append(cur)
    bios = {}
    for blk in blocks:
        if len(blk) < 3:
            continue
        joined = "".join(t.strip() for t in blk)
        for _, _, name, _, _ in CHARACTERS:
            # every bio opens with "<name>，"; 董莺雨's opens with an English
            # greeting written in Chinese characters (‘古的猫宁’ = good morning)
            if name not in bios and (joined.startswith(name + "，") or
                                     (name == "董莺雨" and "古的猫宁" in joined[:12])):
                bios[name] = joined
                break
    chars = []
    for pid, code, name, tag, spr in CHARACTERS:
        chars.append({
            "person_id": pid, "code": code, "name": name, "const_tag": tag,
            "walk_sprite": f"Sprite/{spr}.spr",
            "files": {
                "portrait_full": f"Sprite/{code.capitalize()}_f.pic",
                "portrait_w": f"Sprite/{code.capitalize()}_w.pic",
                "intro": f"Sprite/Itr_{code}.pic",
                "speech_simplified": f"Sentence/{code.capitalize()}_j.spr",
                "speech_traditional": f"Sentence/{code.capitalize()}_f.spr",
                "trade_button": f"Trade/{code.capitalize()}.spr",
            },
            "bio": bios.get(name, ""),
        })
    o2 = tdir / "characters.json"
    write_json(o2, {"note": "person_id order comes from the PERSON_ID enum in the "
                            "developer's const.h (recovered from Map.lib). Bios are "
                            "from 1940.exe.", "characters": chars})
    # campaign stages: briefing strings "地点：…出场人物：…胜利条件：…失败条件：…"
    # are stored last stage first; campaign order = 四毛, 冯全篾, 董莺雨
    briefs = [s for s in by_off if s["text"].startswith("地点：")]
    stage_files = ([f"Sub/Story1{i}.cit" for i in range(1, 8)] +
                   [f"Sub/Story2{i}.cit" for i in range(1, 8)] +
                   [f"Sub/Story3{i}.cit" for i in range(1, 7)])
    lead = ["四毛"] * 7 + ["冯全篾"] * 7 + ["董莺雨"] * 6
    campaigns = []
    if len(briefs) == len(stage_files):
        groups = [briefs[0:7][::-1], briefs[7:14][::-1], briefs[14:20][::-1]]
        k = 0
        for g in groups:
            for b in g:
                t = re.sub(r"[　 ]+", "", b["text"])
                m = re.match(r"地点：(.*?)出场人物：(.*?)胜利条件：(.*?)失败条件：(.*)", t)
                campaigns.append({
                    "campaign_lead": lead[k], "map_file": stage_files[k],
                    "stage": int(stage_files[k][-5]),
                    "place": m.group(1) if m else "",
                    "characters": re.split(r"[、，,]", m.group(2)) if m else [],
                    "win": m.group(3) if m else "", "lose": m.group(4) if m else "",
                    "exe_offset": b["offset"], "raw": b["text"]})
                k += 1
    o3 = tdir / "campaigns.json"
    write_json(o3, {"note": "Story-mode stage briefings from 1940.exe, matched to Sub/Story*.cit "
                            "by order and place name. Dialogue lines for each stage are in "
                            "exe_strings.json (stored next to each briefing, last line first).",
                    "stages": campaigns})

    # hand transcriptions of text that only exists inside pictures
    tr = Path(__file__).resolve().parent / "transcriptions"
    extra = []
    for f in sorted(tr.glob("*.json")):
        shutil.copyfile(f, tdir / f.name)
        extra.append((tdir / f.name).relative_to(out))
    for p in src.glob("Sprite/Chance*.pic"):
        row = STATUS.get(p.relative_to(src).as_posix())
        if row:
            row["outputs"] += ";text/chance_cards.json"
    for p in src.glob("Sentence/*.spr"):
        row = STATUS.get(p.relative_to(src).as_posix())
        if row:
            row["outputs"] += ";text/speech_lines.json"

    note(exe, src, "Windows executable", "partial",
         [o.relative_to(out), (tdir / "exe_strings.csv").relative_to(out), o2.relative_to(out), o3.relative_to(out)],
         f"{len(strs)} GBK strings exported; game logic itself not decompiled")


# ------------------------------------------------------------------ cities

def _hz_font(src: Path):
    try:
        return ci_find(src, "Font/H16_j").read_bytes(), ci_find(src, "Font/Asc16").read_bytes()
    except FileNotFoundError:
        return None, None


def _draw_text(img, x, y, text, hz, asc, color):
    """Draw GBK text with the game's own bitmap fonts."""
    for ch in text:
        try:
            b = ch.encode("gb2312")
        except UnicodeEncodeError:
            b = b"?"
        if len(b) == 2 and hz:
            i = (b[0] - 0xA1) * 94 + (b[1] - 0xA1)
            g = hz[i * 32:(i + 1) * 32]
            for r in range(16):
                bits = (g[r * 2] << 8) | g[r * 2 + 1]
                for c in range(16):
                    if bits & (0x8000 >> c) and 0 <= x + c < img.width and 0 <= y + r < img.height:
                        img.putpixel((x + c, y + r), color)
            x += 16
        elif asc:
            g = asc[b[0] * 16:(b[0] + 1) * 16]
            for r in range(16):
                for c in range(8):
                    if g[r] & (0x80 >> c) and 0 <= x + c < img.width and 0 <= y + r < img.height:
                        img.putpixel((x + c, y + r), color)
            x += 8


CLASS_COLORS = {
    "NULL_BLOCK": (24, 24, 24), "SURFACE": (70, 110, 60), "ROAD": (150, 150, 150),
    "CROSS_ROAD": (230, 200, 60), "PUBLIC_BASE": (90, 120, 200),
    "COMPANY_BASE": (200, 110, 60), "BUYABLE_BASE": (200, 160, 60),
    "BASE": (120, 120, 200), "BLOCK": (60, 60, 60),
}


def _map_png(city: dict, src: Path, path: Path) -> None:
    """Top-down schematic: rows = x, columns = y, as stored in the file."""
    from PIL import Image

    hz, asc = _hz_font(src)
    cell = 18
    n = city["size"]
    img = Image.new("RGB", (n * cell, n * cell), (0, 0, 0))
    ox = city["origin_x"]
    prop = city["property"]
    labels = []
    seen_b = set()
    for b in city["blocks"]:
        r, c = b["x"] - ox, b["y"]
        if b["class"] == "NULL_BLOCK" and b["x"] == 0 and b["y"] == 0:
            continue
        if b["class"] == "LAND":
            pct = b["value_pct"]
            t = max(0, min(1, (pct - 60) / 100))
            col = (int(120 + 135 * t), int(200 - 120 * t), 90)
        else:
            col = CLASS_COLORS.get(b["class"], (255, 0, 255))
        for i in range(cell - 1):
            for j in range(cell - 1):
                img.putpixel((c * cell + j, r * cell + i), col)
        bi = b.get("building_index")
        if bi is not None and bi >= 0 and bi not in seen_b:
            seen_b.add(bi)
            labels.append((c * cell, r * cell, bi))
    names = {bd["slot"]: bd["name"] for bd in city["buildings"]}
    for x, y, bi in labels:
        _draw_text(img, x + 1, y + 1, names.get(bi, str(bi))[:6], hz, asc, (255, 255, 255))
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, optimize=True)


def step_cities(src: Path, out: Path) -> None:
    cdir = out / "data" / "cities"
    summary = []
    for p in sorted(src.rglob("*")):
        if p.suffix.lower() != ".cit":
            continue
        rel = p.relative_to(src)
        try:
            c = read_city(p)
            ok = c["_bytes_read"] == c["_bytes_total"]
            stem = f"{rel.parts[0]}_{p.stem}"
            prop = c["property"]
            # handy derived numbers
            for b in c["blocks"]:
                if b["class"] == "LAND":
                    b["price"] = b["value_pct"] * prop["uPrice_BLANK_LAND"] // 100
                    b["rent_blank"] = b["value_pct"] * prop["uRent_BLANK_LAND"] // 100
            for bd in c["buildings"]:
                bd["sprite_kind_name"] = (BUILDING_SPRITE_KINDS[bd["sprite_kind"]]
                                          if 0 <= bd["sprite_kind"] < len(BUILDING_SPRITE_KINDS) else None)
                if "company_group" in bd:
                    bd["company_group_name"] = COMPANY_GROUPS.get(bd["company_group"])
            for pr in c["persons"]:
                pr["person_name"] = PERSON_IDS.get(pr["person_id"])
            c["source"] = rel.as_posix()
            write_json(cdir / f"{stem}.json", c)
            lands = [{k: b[k] for k in ("name", "x", "y", "value_pct", "build_cost_pct",
                                         "price", "rent_blank", "owner", "mortgaged")}
                     for b in c["blocks"] if b["class"] == "LAND"]
            write_csv(cdir / f"{stem}_lands.csv", lands)
            blds = [{k: bd.get(k, "") for k in ("slot", "class", "name", "sprite_kind_name",
                                                 "company_group_name", "price", "rent",
                                                 "direction", "owner", "describe")}
                    for bd in c["buildings"]]
            write_csv(cdir / f"{stem}_buildings.csv", blds)
            _map_png(c, src, cdir / f"{stem}_map.png")
            summary.append({"file": rel.as_posix(), "name": c["name"], "ai_file": c["ai_file"],
                            "size": c["size"], "lands": len(lands),
                            "buildings": len(c["buildings"]),
                            "persons": len(c["persons"]), **prop})
            note(p, src, "city map", "ok" if ok else "partial",
                 [(cdir / f"{stem}{s}").relative_to(out)
                  for s in (".json", "_lands.csv", "_buildings.csv", "_map.png")],
                 f"{c['name']}: {c['size']}x{c['size']} grid, {len(lands)} lands, "
                 f"{len(c['buildings'])} buildings, {len(c['persons'])} players")
        except Exception as e:
            note(p, src, "city map", "failed", [], str(e))
    write_csv(cdir / "_summary.csv", summary)
    # isometric reference pictures built from the game's own tiles
    from render_city import render
    for p in sorted(src.rglob("*")):
        if p.suffix.lower() != ".cit":
            continue
        rel = p.relative_to(src)
        o = cdir / f"{rel.parts[0]}_{p.stem}_iso.jpg"
        try:
            render(p, src, o)
            row = STATUS.get(rel.as_posix())
            if row:
                row["outputs"] += ";" + str(o.relative_to(out))
        except Exception as e:
            print("render failed", rel, e)


# ------------------------------------------------------------------ audio / video

def step_audio(src: Path, out: Path) -> None:
    import wave

    adir = out / "audio"
    adir.mkdir(parents=True, exist_ok=True)
    rows = []
    for p in sorted(src.rglob("*")):
        ext = p.suffix.lower()
        if ext not in (".wav", ".mid"):
            continue
        o = adir / p.name.lower()
        shutil.copyfile(p, o)
        info = ""
        if ext == ".wav":
            try:
                with wave.open(str(p)) as w:
                    info = (f"PCM {w.getsampwidth() * 8}-bit, {w.getnchannels()} ch, "
                            f"{w.getframerate()} Hz, {w.getnframes() / w.getframerate():.2f}s")
            except Exception as e:
                info = f"wave module could not read: {e}"
        else:
            info = "Standard MIDI (Godot 4 has no built-in MIDI playback)"
        rows.append({"file": p.name, "info": info})
        note(p, src, "audio", "ok (copied)", [o.relative_to(out)], info)
    write_csv(adir / "_audio.csv", rows)


def step_video(src: Path, out: Path) -> None:
    vdir = out / "video"
    has_ffmpeg = shutil.which("ffmpeg") is not None
    for p in sorted(src.rglob("*")):
        if p.suffix.lower() != ".avi":
            continue
        vdir.mkdir(parents=True, exist_ok=True)
        o = vdir / f"{p.stem}.ogv"
        if not has_ffmpeg:
            note(p, src, "video (Cinepak AVI)", "skipped", [], "ffmpeg not installed")
            continue
        r = subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(p),
                            "-c:v", "libtheora", "-q:v", "7", "-c:a", "libvorbis",
                            "-q:a", "4", str(o)], capture_output=True, text=True)
        if r.returncode == 0:
            note(p, src, "video (Cinepak AVI)", "ok (converted)", [o.relative_to(out)],
                 "Cinepak + PCM in AVI, converted to Ogg Theora for Godot VideoStreamPlayer")
        else:
            note(p, src, "video (Cinepak AVI)", "failed", [], r.stderr.strip()[:200])


# ------------------------------------------------------------------ dev files

def step_devfiles(src: Path, out: Path) -> None:
    ddir = out / "devfiles"
    for name, kind in (("Map.lib", "Visual C++ precompiled header (.pch)"),
                       ("Houses.lib", "Visual C++ browse database (.bsc, PDB 2.00 container)")):
        try:
            p = ci_find(src, name)
        except FileNotFoundError:
            continue
        d = p.read_bytes()
        z = zlib.decompressobj(-15)
        data, pos = b"", 0
        try:
            while pos < len(d):
                data += z.decompress(d[pos:pos + 65536])
                pos += 65536
        except zlib.error:
            pass  # stream is followed by unrelated leftover bytes
        idents = sorted(set(m.decode() for m in re.findall(rb"[A-Za-z_][A-Za-z0-9_]{3,}", data)))
        paths = sorted(set(m.decode("latin-1") for m in
                           re.findall(rb"[A-Za-z]:\\[\\A-Za-z0-9_.\- ]+\.(?:cpp|h|sbr)", data)))
        o1 = ddir / f"{p.stem}_identifiers.txt"
        o2 = ddir / f"{p.stem}_source_paths.txt"
        ddir.mkdir(parents=True, exist_ok=True)
        o1.write_text("\n".join(idents), encoding="utf-8")
        o2.write_text("\n".join(paths), encoding="utf-8")
        note(p, src, kind, "ok (not game data)", [o1.relative_to(out), o2.relative_to(out)],
             f"raw-deflate stream -> {len(data)} bytes ({data[:8]!r}...); "
             "game never opens it. Exported identifier names only.")


# ------------------------------------------------------------------ main

OTHER_KINDS = {
    ".dll": ("DirectDraw wrapper DLL (DDrawCompat, modern add-on)", "not extracted"),
    ".ini": ("DDrawCompat settings (modern add-on)", "not extracted"),
    ".exe": ("Windows executable", "see text step"),
    ".txt": ("empty save list", "not extracted"),
}


def step_manifest(src: Path, out: Path) -> None:
    rows = []
    for p in sorted(src.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(src).as_posix()
        row = STATUS.get(rel)
        if row is None:
            kind, status = OTHER_KINDS.get(p.suffix.lower(), ("unknown", "not extracted"))
            row = {"source": rel, "kind": kind, "status": status, "outputs": "", "detail": ""}
        row = dict(row)
        row["size"] = p.stat().st_size
        rows.append(row)
    write_csv(out / "manifest.csv", rows)
    bad = [r for r in rows if r["status"].startswith(("failed", "partial"))]
    print(f"manifest: {len(rows)} files, {len(bad)} failed/partial")
    for r in bad:
        print("  ", r["status"], r["source"], r["detail"][:100])


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    root = Path(__file__).resolve().parent.parent
    ap.add_argument("--src", default=str(root / "shanghai1940"))
    ap.add_argument("--out", default=str(root / "extracted"))
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    src, out = Path(a.src), Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    only = set(filter(None, a.only.split(",")))

    def want(step):
        return not only or step in only

    pals = step_palettes(src, out)
    if want("images"):
        print("images..."); step_images(src, out, pals)
    if want("psd"):
        print("psd..."); step_psd(src, out)
    if want("fonts"):
        print("fonts..."); step_fonts(src, out)
    if want("text"):
        print("text..."); step_text(src, out)
    if want("cities"):
        print("cities..."); step_cities(src, out)
    if want("audio"):
        print("audio..."); step_audio(src, out)
    if want("video"):
        print("video..."); step_video(src, out)
    if want("devfiles"):
        print("devfiles..."); step_devfiles(src, out)
    if not only:
        step_manifest(src, out)


if __name__ == "__main__":
    main()
