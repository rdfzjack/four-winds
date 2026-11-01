#!/usr/bin/env python3
"""生成地图目录，写进 docs/campaign_brief.md：原版 24 张城市 / 战役地图（和已经转好的地图）的规模、企业、路口。
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
OUT = ROOT / "docs/campaign_brief.md"  # 表格写进简报里 <!-- map_catalog:start/end --> 之间
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


def original_campaigns() -> list[str]:
    """原版 3 条战役（20 关）的对局情况：地图、各人开局资金、预置地产、胜负条件。给讨论剧情当参考。"""
    camp = json.load(open(ROOT / "extracted/text/campaigns.json", encoding="utf-8"))["stages"]
    pid_name: dict[int, str] = {}
    for f in CITIES.glob("Sub_Story*.json"):
        if f.name.endswith("_buildings.json"):
            continue
        for pr in json.load(open(f, encoding="utf-8")).get("persons", []):
            pid_name[pr["person_id"]] = pr["name"]
    out: list[str] = []
    lead = None
    for st in camp:
        d = json.load(open(CITIES / (st["map_file"].replace("/", "_").replace(".cit", "") + ".json"),
                           encoding="utf-8"))
        if st["campaign_lead"] != lead:
            lead = st["campaign_lead"]
            out += ["", f"### 原版战役：{lead}（主角）", "",
                    "| 关 | 地图 | 玩家（主角）开局 | 对手开局 | 预置地产 | 胜利条件 | 失败条件 |",
                    "|---|---|---|---|---|---|---|"]
        persons = d["persons"]
        me = next((p for p in persons if p["ai"] == 0), persons[0])
        others = "、".join(f"{p['name']} {p['cash']}/{p['deposit']}" for p in persons if p is not me)
        owned = Counter()
        for b in d["blocks"]:
            if b.get("class") == "LAND" and b.get("owner") not in (None, 8):
                owned[(pid_name.get(b["owner"], str(b["owner"])), "房子" if b["building_index"] >= 0 else "空地")] += 1
        for b in d["buildings"]:
            if b["class"] == "COMPANY" and b.get("owner") not in (None, 8):
                owned[(pid_name.get(b["owner"], str(b["owner"])), "企业")] += 1
        pre = "、".join(f"{n} {v} 块{k}" if k != "企业" else f"{n} {v} 家企业" for (n, k), v in owned.items()) or "无"
        out.append(f"| {st['stage']} | {st['place']}（{st['map_file'].split('/')[-1][:-4]}） | "
                   f"{me['name']} {me['cash']}/{me['deposit']} | {others} | {pre} | {st['win']} | {st['lose']} |")
    return out


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
    lines = ["| 原版文件 | 地名 | 格数 | 路口 | 街道数 | 企业（按行业） | 已转换 |", "|---|---|---|---|---|---|---|"]
    for stem, name, tiles, cross, streets, comp, _n, conv, st in rows:
        companies = "、".join(f"{k} {v}" for k, v in comp.items()) or "无"
        lines.append(f"| {stem} | {name} | {tiles or st} | {cross} | {streets} | {companies} | {conv or '—'} |")
    text = OUT.read_text(encoding="utf-8")
    for tag, body in (("map_catalog", lines), ("original_campaigns", original_campaigns())):
        start, end = f"<!-- {tag}:start -->", f"<!-- {tag}:end -->"
        a, b = text.index(start) + len(start), text.index(end)
        text = text[:a] + "\n" + "\n".join(body) + "\n" + text[b:]
    OUT.write_text(text, encoding="utf-8")
    print(f"写入 {OUT}（{len(rows)} 张）")


if __name__ == "__main__":
    main()
