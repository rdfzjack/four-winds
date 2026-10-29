#!/usr/bin/env python3
"""Render a .cit map as an isometric picture using the game's own tiles.

Usage:
    python3 tools/render_city.py [--src shanghai1940] [--out extracted/data/cities] [files...]

This is a reference picture, not a pixel-exact copy of the game screen:
tile placement follows the grid maths below, which were worked out by
matching road pieces, not by reading the game's drawing code.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from fw_city import read_city  # noqa: E402
from fw_formats import frame_to_image, read_palette, read_spr  # noqa: E402

# BUILDING_SPRITE_KIND -> sprite file in Build/ (list stored in 1940.exe)
KIND_FILES = [
    "Ping_f", "Gong_y", "Chao_j", "Xiao_y", "Hua_y", "Bie_s", "Shui_w", "Hei_b",
    "Suan_m", "Dang_p", "Huo_c", "Ma_t", "Dian_c", "Dian_d", "Mei_q", "Dian_h",
    "Zi_l", "Fan_d", "Yan_c", "Bao_s", "Fang_z", "Shang_d", "Yie_z", "Gong_yu",
    "Yun_q", "Yin_h", "Jiao_t", "Xun_b", "Shi_z", "Du_c", "Sai_m",
]

HALF_W, HALF_H = 40, 20   # isometric tile is 80 x 40 pixels


def ci(root: Path, rel: str) -> Path:
    p = root
    for part in rel.split("/"):
        p = next(c for c in p.iterdir() if c.name.lower() == part.lower())
    return p


def render(city_path: Path, src: Path, out_png: Path, mirror: bool = False,
           scale: float = 0.5) -> None:
    from PIL import Image

    pal = read_palette(ci(src, "Sprite/1940.col"))
    cache: dict[str, list] = {}

    def spr(rel):
        if rel not in cache:
            cache[rel] = read_spr(ci(src, rel)).groups
        return cache[rel]

    def tile(rel, group, frame):
        groups = spr(rel)
        g = groups[min(group, len(groups) - 1)]
        return g[min(frame, len(g) - 1)]

    city = read_city(city_path)
    n, ox = city["size"], city["origin_x"]
    buildings = {b["slot"]: b for b in city["buildings"]}

    def screen(r, c):
        # r = x - origin_x (row in the file), c = y (column)
        if mirror:
            r, c = c, r
        return (c - r) * HALF_W, (c + r) * HALF_H

    xs = [screen(r, c)[0] for r in (0, n) for c in (0, n)]
    ys = [screen(r, c)[1] for r in (0, n) for c in (0, n)]
    pad = 200
    W, H = max(xs) - min(xs) + 2 * pad, max(ys) - min(ys) + 2 * pad
    img = Image.new("RGBA", (W, H), (20, 30, 20, 255))
    offx, offy = -min(xs) + pad, -min(ys) + pad

    blocks = sorted(city["blocks"], key=lambda b: sum(screen(b["x"] - ox, b["y"])[::-1]))
    # ground pass
    for b in blocks:
        if b["class"] == "NULL_BLOCK":
            continue
        sx, sy = screen(b["x"] - ox, b["y"])
        sx, sy = sx + offx - HALF_W, sy + offy
        if b["class"] == "SURFACE":
            f = tile("Sprite/Surface.spr", 0, b.get("surface_frame", 0))
        elif b["class"] in ("ROAD", "CROSS_ROAD"):
            f = tile("Sprite/Road.spr", 0, b.get("road_frame", 0))
        else:
            f = tile("Sprite/Base.spr", 0, 0)
        img.alpha_composite(frame_to_image(f, pal), (sx, sy - f.hot_y))
    # building pass: glue the slices of one direction side by side (same rule
    # as the *.preview.png files), then place the whole picture so its left
    # edge meets the footprint's leftmost tile corner and its ground line
    # meets the footprint's top tile.
    feet: dict[int, list] = {}
    for b in city["blocks"]:
        if b.get("building_index", -1) >= 0:
            feet.setdefault(b["building_index"], []).append(screen(b["x"] - ox, b["y"]))
    placed = []
    for idx, cells in feet.items():
        bd = buildings.get(idx)
        if not bd or not (0 <= bd["sprite_kind"] < len(KIND_FILES)):
            continue
        groups = spr(f"Build/{KIND_FILES[bd['sprite_kind']]}.spr")
        g = groups[min(bd["direction"], len(groups) - 1)]
        real = [f for f in g if f.width > 2]
        if not real:
            continue
        top = max(f.hot_y for f in real)
        bottom = max(f.height - f.hot_y for f in real)
        pic = Image.new("RGBA", (sum(f.width for f in real), top + bottom), (0, 0, 0, 0))
        x = 0
        for f in real:
            pic.alpha_composite(frame_to_image(f, pal), (x, top - f.hot_y))
            x += f.width
        left = min(c[0] for c in cells) - HALF_W
        ground = min(c[1] for c in cells)
        placed.append((max(c[1] for c in cells), pic, left + offx, ground + offy - top))
    for _, pic, x, y in sorted(placed, key=lambda t: t[0]):
        img.alpha_composite(pic, (x, y))
    # decorations (trees)
    for b in blocks:
        if "decorate" in b:
            try:
                f = tile("Sprite/Decorate.spr", b["decorate"], 0)
            except (IndexError, StopIteration):
                continue
            sx, sy = screen(b["x"] - ox, b["y"])
            sx, sy = sx + offx - HALF_W, sy + offy
            img.alpha_composite(frame_to_image(f, pal), (sx + f.hot_x, sy - f.hot_y))
    # crop to the drawn area and halve the size to keep files small
    from PIL import ImageChops
    rgb = img.convert("RGB")
    bbox = ImageChops.difference(rgb, Image.new("RGB", img.size, (20, 30, 20))).getbbox()
    if bbox:
        img = img.crop(bbox)
    if scale != 1:
        img = img.resize((int(img.width * scale), int(img.height * scale)), Image.LANCZOS)
    out_png.parent.mkdir(parents=True, exist_ok=True)
    img.convert("RGB").save(out_png, quality=88)


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", default=str(root / "shanghai1940"))
    ap.add_argument("--out", default=str(root / "extracted" / "data" / "cities"))
    ap.add_argument("--mirror", action="store_true", help="swap axes (for checking orientation)")
    ap.add_argument("--scale", type=float, default=0.5)
    ap.add_argument("files", nargs="*")
    a = ap.parse_args()
    src = Path(a.src)
    files = [Path(f) for f in a.files] or sorted(p for p in src.rglob("*") if p.suffix.lower() == ".cit")
    for f in files:
        rel = f.resolve().relative_to(src.resolve())
        o = Path(a.out) / f"{rel.parts[0]}_{f.stem}_iso.jpg"
        render(f, src, o, a.mirror, a.scale)
        print(o)


if __name__ == "__main__":
    main()
