#!/usr/bin/env python3
"""把画面要用的少量原版素材拷进 Godot 项目，当占位图。

    python3 tools/copy_placeholder.py

从 extracted/images/ 读原版精灵（拼图 PNG + 帧数据 JSON），只挑用到的组，
重新拼成小图写到 fourwinds-benti/assets/placeholder/，并生成同目录的 README.md 记录来源。

输出的 JSON 格式（画面代码 scripts/ui/art.gd 读它）：
    {"source": 原版文件, "groups": [[{"rect": [x, y, w, h], "pivot": [px, py]}, ...], ...]}
pivot = 帧里要对准“参考点”的像素：地面图块对准菱形中心，人物对准脚底。
以后换成作者自己的素材：同样格式的 PNG + JSON 放别处，改 art.gd 里的路径表即可。
"""
from __future__ import annotations

import json
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "extracted" / "images"
OUT = ROOT / "fourwinds-benti" / "assets" / "placeholder"

HALF_W = 40  # 原版图块是 80×40 的菱形

# 名字 → (原版精灵, 要的组（None = 全部）, 参考点类型, 用途)
# 参考点类型：tile = 地面图块（原版锚点是“左角 + 偏移”），foot = 人物（原版锚点就是脚底），none = 不在地图上画
SPRITES = {
    "Surface": ("Sprite/Surface", None, "tile", "地表（草地、水边）"),
    "Road": ("Sprite/Road", None, "tile", "道路：帧 0、1 是带虚线的直路，其余是无标线路面"),
    "Base": ("Sprite/Base", [0], "tile", "地基：帧 0 是路边的空地"),
    "Flag": ("Sprite/Flag", None, "tile", "格子标记：帧 0–3 是方向箭头，帧 4 白框，帧 5 黄框（选中）"),
    "Saizi": ("Sprite/Saizi", [1], "none", "骰子：只取第 2 组（1–6 点各一帧），滚动动画那组不要"),
    "Wai_g": ("Sprite/Wai_g", None, "foot", "外国人走路图（4 个朝向 × 8 帧），占位给斐斐"),
    "Hei_b": ("Sprite/Hei_b", None, "foot", "黑帮走路图，占位给小九"),
    "Mai_b": ("Sprite/Mai_b", None, "foot", "买办走路图，占位给孔雀"),
    "Tu_c": ("Sprite/Tu_c", None, "foot", "土财主走路图，占位给理理"),
}


def pivot_of(frame: dict, kind: str) -> list[int]:
    ax, ay = frame["anchor"]
    if kind == "tile":
        # 原版画法：左上角 = (菱形中心.x - 40 + ax, 菱形中心.y - ay)
        return [HALF_W - ax, ay]
    if kind == "foot":
        return [ax, ay]
    return [frame["rect"][2] // 2, frame["rect"][3] // 2]


def copy_sprite(name: str, rel: str, groups: list[int] | None, kind: str) -> dict:
    meta = json.loads((SRC / f"{rel}.json").read_text(encoding="utf-8"))
    sheet = Image.open(SRC / f"{rel}.png").convert("RGBA")
    picked = [g for i, g in enumerate(meta["groups"]) if groups is None or i in groups]
    width = max(sum(f["rect"][2] for f in g) for g in picked)
    height = sum(max(f["rect"][3] for f in g) for g in picked)
    out = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    out_groups = []
    y = 0
    for g in picked:
        x = 0
        row = []
        for f in g:
            fx, fy, fw, fh = f["rect"]
            out.alpha_composite(sheet.crop((fx, fy, fx + fw, fy + fh)), (x, y))
            row.append({"rect": [x, y, fw, fh], "pivot": pivot_of(f, kind)})
            x += fw
        out_groups.append(row)
        y += max(f["rect"][3] for f in g)
    out.save(OUT / f"{name}.png")
    data = {"source": meta["source"], "groups": out_groups}
    (OUT / f"{name}.json").write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n",
                                      encoding="utf-8")
    return meta


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    lines = [
        "# 占位素材（原版《上海大富翁1940》）",
        "",
        "由 `tools/copy_placeholder.py` 从 `extracted/images/` 生成，不要手改；要换图改 `scripts/ui/art.gd` 的路径表。",
        "只自用，不发布。换成作者自己的素材后，整个 `placeholder/` 目录删掉即可（画面会退回色块）。",
        "",
        "| 文件 | 来源（原版文件） | 取了哪些 | 用途 |",
        "|---|---|---|---|",
    ]
    for name, (rel, groups, kind, use) in SPRITES.items():
        meta = copy_sprite(name, rel, groups, kind)
        which = "全部" if groups is None else "第 " + "、".join(str(g + 1) for g in groups) + " 组"
        lines.append(f"| `{name}.png` / `{name}.json` | `{meta['source']}`（解包：`extracted/images/{rel}.png`） "
                     f"| {which} | {use} |")
    (OUT / "README.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("已写入", OUT)


if __name__ == "__main__":
    main()
