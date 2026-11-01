#!/usr/bin/env python3
"""生成地图目录 docs/map_catalog.md：原版 24 张城市 / 战役地图（和已经转好的地图）的规模、企业、路口。
给主线剧情讨论用（选图、定目标时看企业够不够）。用法：python3 tools/map_catalog.py
数字来自 tools/cit_to_map.py --print（转换后的格数、路口、街道数）和解包出来的 *_buildings.csv。"""
from __future__ import annotations

import csv
import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CITIES = ROOT / "extracted/data/cities"
OUT = ROOT / "docs/map_catalog.md"
CONVERTED = {  # 原版文件 -> 已经在 data/maps/ 里的地图 id
    "Cit_Shaihai": "shanghai", "Sub_Story34": "shanghai_west",
}
GROUP = {"TRANSPORT": "运输（码头 / 火车站 / 电车）", "PUBLIC": "公用", "FOOD": "食品", "CIGARETTE": "烟草",
         "NEWSPAPER": "报业（书局 / 报馆）", "WEAVING": "纺织", "SHOP": "商业（百货 / 洋行）",
         "ENTERTAINMENT": "娱乐（夜总会等）"}


def stats(path: Path) -> str:
    r = subprocess.run([sys.executable, str(ROOT / "tools/cit_to_map.py"), str(path), "--id", "t",
                        "--name", "t", "--print"], capture_output=True, text=True)
    return (r.stdout.strip().splitlines() or [r.stderr.strip()[-80:]])[-1] if r.returncode == 0 else "转换失败"


def main() -> None:
    rows = []
    for f in sorted(CITIES.glob("*.json")):
        if f.name.endswith("_buildings.json") or f.stem.startswith("_"):
            continue
        d = json.load(open(f, encoding="utf-8"))
        comp = Counter()
        names = []
        with open(CITIES / f"{f.stem}_buildings.csv", encoding="utf-8-sig") as fh:
            for row in csv.DictReader(fh):
                if row["class"] == "COMPANY":
                    g = row["company_group_name"].split(" ")[0]
                    comp[GROUP.get(g, g)] += 1
                    names.append(row["name"])
        st = stats(f)
        m = re.search(r"(\d+) 格", st)
        cross = re.search(r"路口 (\d+) 个", st)
        streets = re.search(r"街道 (\d+) 条", st)
        persons = [p["name"] for p in d.get("persons", [])]
        rows.append((f.stem, d.get("name", ""), int(m.group(1)) if m else 0, int(cross.group(1)) if cross else 0,
                     int(streets.group(1)) if streets else 0, comp, len(persons), CONVERTED.get(f.stem, ""), st))
    lines = ["# 地图目录（自动生成，不要手改）", "",
             "`python3 tools/map_catalog.py` 生成。原版共 24 张：4 张自由模式城市（`Cit_*`）、20 张战役关卡图（`Sub_Story*`）。",
             "“格数”是转成我们的路网后棋子能走的格子数（一圈的长度），路口 = 能选方向的路口。"
             "“已转换”列有 id 的已经在 `data/maps/` 里，其余用 `tools/cit_to_map.py` 一条命令转（失败的要手动处理）。"
             "另有一张自制的 40 格一圈图 `shanghai_loop`（企业：运输 2 / 娱乐 2 / 商业 1）。", "",
             "| 原版文件 | 地名 | 格数 | 路口 | 街道数 | 企业（按行业） | 已转换 |", "|---|---|---|---|---|---|---|"]
    for stem, name, tiles, cross, streets, comp, _n, conv, st in rows:
        companies = "、".join(f"{k} {v}" for k, v in comp.items()) or "无"
        lines.append(f"| {stem} | {name} | {tiles or st} | {cross} | {streets} | {companies} | {conv or '—'} |")
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"写入 {OUT}（{len(rows)} 张）")


if __name__ == "__main__":
    main()
