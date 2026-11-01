#!/usr/bin/env python3
"""列出一张地图的格子编号，方便在关卡数据里写预置地产 / 选“那条街”。
用法：python3 tools/map_info.py 地图id          （地图 id 就是 fourwinds-benti/data/maps/ 里的文件名，不含 .json）
      python3 tools/map_info.py                  列出所有地图
输出：每条街有哪几块地（编号:地价%）、每家企业（编号 名字 行业 价格/租金）、银行 / 巡捕房等特殊格、路口。
游戏里点格子，左下角的信息里也有“编号”。"""
import json
import sys
from collections import defaultdict
from pathlib import Path

MAPS = Path(__file__).resolve().parent.parent / "fourwinds-benti" / "data" / "maps"


def main() -> None:
    if len(sys.argv) < 2:
        for f in sorted(MAPS.glob("*.json")):
            d = json.load(open(f, encoding="utf-8"))
            print(f"{f.stem}：{d.get('name', '')}，{len(d['tiles'])} 格")
        return
    d = json.load(open(MAPS / f"{sys.argv[1]}.json", encoding="utf-8"))
    tiles = d["tiles"]
    print(f"{d.get('name', '')}（{sys.argv[1]}）{len(tiles)} 格，起点 {d['start_tile']}")
    streets: dict[str, list] = defaultdict(list)
    for t in tiles:
        if t["type"] == "land" and "site" not in t:
            streets[t["group"]].append(f"{t['id']}:{t['price_pct']}%")
    print("\n街道（编号:地价%，同一条街的地沿路相连，凑房子要连续的）")
    for g, lots in streets.items():
        print(f"  {g}：{' '.join(lots)}")
    print("\n企业")
    for t in tiles:
        if t["type"] == "company" and "site" not in t:
            print(f"  {t['id']} {t['name']}  行业 {t['industry']}  价格 {t['price']} 租金 {t['rent']}")
    print("\n其他格子（正格）")
    for t in tiles:
        if t["type"] not in ("land", "company", "road") and "site" not in t:
            print(f"  {t['id']} {t.get('name', t['type'])}（{t['type']}）")
    cross = [(t["id"], t.get("crossroad", "choice")) for t in tiles if len(t["next"]) > 1]
    print(f"\n路口：{cross}")


if __name__ == "__main__":
    main()
