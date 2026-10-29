#!/usr/bin/env python3
"""把原版 .cit 地图转成四方来财的地图 JSON（fourwinds-benti/data/maps/）。

用法：
    python3 tools/cit_to_map.py extracted/data/cities/Cit_Shaihai.json --id shanghai --name 上海
    python3 tools/cit_to_map.py shanghai1940/Sub/Story11.cit --id story11 --name 金县   （也能直接读 .cit）

默认不覆盖已有的地图文件（data/ 里的文件归作者所有），要覆盖加 --force。
加 --print 只打印统计，不写文件。

怎么对应（停在哪格触发什么，是反汇编 1940.exe 得到的，见 docs/analysis.md 5.5 节）：
- 原版棋子走的是路面格（ROAD / CROSS_ROAD），一格路就是我们的一格（pos = 原版格子坐标）。
- 原版停在一格路上时，按 左(x-1)、右(x+1)、上(y-1)、下(y+1) 的顺序找第一个相邻的
  地 / 企业 / 公共建筑格，触发它（Road::comeHere 0x404f00）；路过时同样找法（0x405080）。
  所以每格路的类型 = 这样找到的东西；什么都没找到的是 road（普通路面）。
- 一块地 / 一栋建筑可能被几格路找到：第一格（编号最小的；地优先选前后挨着同街地的那格）是正格，
  写名字、价格和 lot（路边格坐标）；其余是分身格，只写 "site": 正格编号。
- 地按原版街道名分组（“万航渡路1号”→ 街道组“万航渡路”），地价系数、建房系数照原版。
- 路口：原版的路是双向的、路口按箭头走；我们的路网是单向的（每格 next）。
  工具自动给每段路定方向：保证从任何格子都能走到任何格子，并让尽量多的路口有 2 个以上出口；
  路口都写 "crossroad": "choice"，作者可以改成 random。
- 起点：原版第一个玩家的开局位置（不是一种格子，停下没有效果）。
- 不转：原版开局的地主、已建的房子、战役关卡条件（第 8 步再做）。
"""
from __future__ import annotations

import argparse
import itertools
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))

from build_game_data import GROUP_COLORS, INDUSTRY, TYPE_NAMES, street_of  # noqa: E402

MAPS = ROOT / "fourwinds-benti" / "data" / "maps"

ROADS = ("ROAD", "CROSS_ROAD")
BASES = ("LAND", "COMPANY_BASE", "PUBLIC_BASE")
# 原版建筑类 → 我们的格子类型
BUILDING_TYPES = {
    "COMPANY": "company", "BANK": "bank", "CHANCE": "chance", "CHURCH": "church",
    "GOVERNMENT": "government", "PARK": "park", "RACE_COURSE": "race_course",
    "TAX_HOUSE": "tax", "WATCH_MAN_HOUSE": "jail", "CASINO": "casino",
}
# 枚举所有走向的上限（2^n 种）；路段更多时用 DFS 定向
BRUTE_FORCE_MAX_SEGMENTS = 20


def load_city(path: Path) -> dict:
    if path.suffix.lower() == ".cit":
        from fw_city import read_city
        return read_city(path)
    return json.loads(path.read_text("utf-8"))


def neighbours(p: tuple) -> list:
    """原版 Road::comeHere 查相邻格的顺序：x-1、x+1、y-1、y+1。"""
    x, y = p
    return [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]


# ───────────────────────── 路网定向 ─────────────────────────

def find_segments(roads: set, crossroads: set) -> list:
    """把路网切成路段：两个路口之间的一串格子（含两头的路口）。没有路口时整圈是一段。"""
    if not crossroads:
        start = min(roads)
        path, prev, cur = [start], None, start
        while True:
            nxt = [q for q in neighbours(cur) if q in roads and q != prev]
            if not nxt or nxt[0] == start:
                break
            prev, cur = cur, nxt[0]
            path.append(cur)
        if len(path) != len(roads):
            raise ValueError("没有路口的地图应该是一整圈")
        return [path + [start]]
    segments, seen = [], set()
    for c in sorted(crossroads):
        for first in neighbours(c):
            if first not in roads:
                continue
            path, prev, cur = [c, first], c, first
            while cur not in crossroads:
                nxt = [q for q in neighbours(cur) if q in roads and q != prev]
                if len(nxt) != 1:
                    raise ValueError(f"路在 {cur} 断了或分叉了，原版地图应该没有这种格子")
                prev, cur = cur, nxt[0]
                path.append(cur)
            key = (frozenset([path[0], path[-1]]), frozenset(path[1:-1]))
            if key not in seen:
                seen.add(key)
                segments.append(path)
    return segments


def _strongly_connected(nodes: list, edges: list) -> bool:
    def reach(adj: dict) -> set:
        seen, stack = {nodes[0]}, [nodes[0]]
        while stack:
            for nx in adj.get(stack.pop(), []):
                if nx not in seen:
                    seen.add(nx)
                    stack.append(nx)
        return seen
    fwd, back = {}, {}
    for a, b in edges:
        fwd.setdefault(a, []).append(b)
        back.setdefault(b, []).append(a)
    return len(reach(fwd)) == len(nodes) and len(reach(back)) == len(nodes)


def orient(segments: list, crossroads: set) -> list:
    """给每段路定方向，返回 True = 按 segment 原来的顺序走，False = 反过来走。"""
    if not crossroads:
        return [True]
    nodes = sorted(crossroads)
    ends = [(s[0], s[-1]) for s in segments]
    if len(segments) <= BRUTE_FORCE_MAX_SEGMENTS:
        best, best_score = None, None
        for flips in itertools.product((True, False), repeat=len(segments)):
            edges = [(a, b) if f else (b, a) for (a, b), f in zip(ends, flips)]
            if not _strongly_connected(nodes, edges):
                continue
            out = {n: 0 for n in nodes}
            inn = {n: 0 for n in nodes}
            for a, b in edges:
                out[a] += 1
                inn[b] += 1
            # 先比有几个路口能选方向（出口 ≥ 2），再比进出是否均衡
            score = (sum(1 for n in nodes if out[n] >= 2),
                     -sum(abs(out[n] - inn[n]) for n in nodes))
            if best_score is None or score > best_score:
                best, best_score = flips, score
        if best is None:
            raise ValueError(_no_orientation_message(nodes, ends))
        return list(best)
    # 路段太多：DFS，树边往下、回边往上（只要路网没有“桥”就能走遍）
    adj: dict = {}
    for i, (a, b) in enumerate(ends):
        adj.setdefault(a, []).append((i, b))
        adj.setdefault(b, []).append((i, a))
    flips: list = [None] * len(segments)
    seen = set()

    def dfs(n):
        seen.add(n)
        for i, other in adj[n]:
            if flips[i] is None:
                flips[i] = (ends[i][0] == n)
                if other not in seen:
                    dfs(other)
    dfs(nodes[0])
    edges = [(a, b) if f else (b, a) for (a, b), f in zip(ends, flips)]
    if not _strongly_connected(nodes, edges):
        raise ValueError(_no_orientation_message(nodes, ends))
    return flips


def _no_orientation_message(nodes: list, ends: list) -> str:
    """找出“桥”：去掉这段路，路口就分成两块。单向路网走过桥就回不来了。"""
    bridges = []
    for i, (a, b) in enumerate(ends):
        rest = [e for j, e in enumerate(ends) if j != i]
        if not _strongly_connected(nodes, rest + [(y, x) for x, y in rest]):
            bridges.append(f"{a}—{b}")
    return ("这张图的路网定不成单向还能走遍全图"
            + (f"：路段 {'、'.join(bridges)} 是唯一通道（原版这里要掉头走回来），要手动处理" if bridges else ""))


# ───────────────────────── 转换 ─────────────────────────

def convert(city: dict, map_id: str, name: str, source: str) -> dict:
    grid = {(b["x"], b["y"]): b for b in city["blocks"] if b["class"] != "NULL_BLOCK"}
    roads = {p for p, b in grid.items() if b["class"] in ROADS}
    crossroads = {p for p in roads if grid[p]["class"] == "CROSS_ROAD"}
    buildings = {b["slot"]: b for b in city["buildings"]}  # 地块里的 building_index 是槽位号
    for p in roads:
        n = sum(q in roads for q in neighbours(p))
        if (n > 2) != (p in crossroads):
            raise ValueError(f"{p} 的连接数 {n} 和格子类型 {grid[p]['class']} 对不上")

    # 路网 → 每格的下一格
    segments = find_segments(roads, crossroads)
    nexts: dict = {p: [] for p in roads}
    for seg, forward in zip(segments, orient(segments, crossroads)):
        cells = seg if forward else seg[::-1]
        for a, b in zip(cells, cells[1:]):
            if b not in nexts[a]:
                nexts[a].append(b)

    # 起点：原版第一个玩家的开局位置
    start = None
    for person in city.get("persons", []):
        g = tuple(person["grid"])
        if g in roads:
            start = g
            break
    if start is None:
        start = min(roads)

    # 编号：从起点沿路深度优先，同一段路上的格子编号连着
    order, seen, stack = [], set(), [start]
    while stack:
        p = stack.pop()
        if p in seen:
            continue
        seen.add(p)
        order.append(p)
        stack.extend(reversed(nexts[p]))
    if len(order) != len(roads):
        raise ValueError("定向后有格子走不到")
    index = {p: i for i, p in enumerate(order)}

    # 每格路触发什么（原版 Road::comeHere 的找法）
    hit: dict = {}
    for p in order:
        for q in neighbours(p):
            if q in grid and grid[q]["class"] in BASES:
                hit[p] = q
                break

    def site_key(q: tuple):
        b = grid[q]
        return ("land", q) if b["class"] == "LAND" else ("building", b["building_index"])

    def street(q: tuple) -> str:
        return street_of(grid[q]["name"])

    # 选正格：地优先选前后挨着同街其他地的那格（建房要沿路连着），其次编号小的
    prevs: dict = {p: [] for p in order}
    for p in order:
        for nx in nexts[p]:
            prevs[nx].append(p)

    def chain_score(p: tuple) -> int:
        q = hit[p]
        if grid[q]["class"] != "LAND":
            return 0
        return sum(1 for r in nexts[p] + prevs[p]
                   if r in hit and hit[r] != q and grid[hit[r]]["class"] == "LAND"
                   and street(hit[r]) == street(q))

    primary: dict = {}
    for p in order:
        if p in hit:
            k = site_key(hit[p])
            if k not in primary or chain_score(p) > chain_score(primary[k]):
                primary[k] = p

    lands = sorted({q for q in hit.values() if grid[q]["class"] == "LAND"},
                   key=lambda q: (grid[q]["value_pct"], street(q)))
    groups: dict = {}
    for q in lands:
        s = street(q)
        if s not in groups:
            groups[s] = {"name": s, "color": GROUP_COLORS[len(groups) % len(GROUP_COLORS)]}

    stem = Path(city.get("source") or city.get("file") or source).name
    tiles = []
    for p in order:
        t: dict = {"id": index[p]}
        q = hit.get(p)
        if q is None:
            t["type"] = "road"
        else:
            b = grid[q]
            if b["class"] == "LAND":
                kind = "land"
            else:
                bld = buildings[b["building_index"]]
                kind = BUILDING_TYPES.get(bld["class"])
                if kind is None:
                    raise ValueError(f"不认识的原版建筑 {bld['class']}（{bld.get('name')}）")
            t["type"] = kind
            main = primary[site_key(q)]
            if main != p:
                t["site"] = index[main]
            elif kind == "land":
                t.update({"name": b["name"], "group": street(q),
                          "price_pct": b["value_pct"], "build_cost_pct": b["build_cost_pct"],
                          "source": f"{stem} 地块 ({q[0]},{q[1]})"})
            else:
                t["name"] = bld["name"] or TYPE_NAMES.get(kind, kind)
                if kind == "company":
                    t.update({"industry": INDUSTRY.get(bld["company_group"], "other"),
                              "price": bld["price"], "rent": bld["rent"]})
                    if bld.get("describe"):
                        t["slogan"] = bld["describe"].strip()
                t["source"] = f"{stem} 建筑 {bld['name']}"
            if main == p:
                t["lot"] = list(q)
        t["pos"] = list(p)
        if p in crossroads:
            t["crossroad"] = "choice"
        t["next"] = [index[nx] for nx in nexts[p]]
        tiles.append(t)

    prop = city["property"]
    if isinstance(prop, list):  # 老的导出把字典存成了 [键, 值] 列表
        prop = dict(prop)
    return {
        "id": map_id,
        "name": name,
        "placeholder": True,
        "_comment": f"由 tools/cit_to_map.py 从原版 {stem} 转换，之后可直接修改。"
                    "pos 是原版的路面格坐标，lot 是地 / 建筑所在的路边格。"
                    "带 site 的是分身格：停在这里等于停在 site 那一格（原版一栋建筑、拐角的地挨着好几格路）。"
                    "road 是旁边没有东西的路面。原版的路是双向的，这里每段路的方向是工具自动定的；"
                    "路口 crossroad 可以改成 random。"
                    "price_pct 是地价系数，build_cost_pct 是建房系数（见 shanghai_loop.json 的说明）。",
        "start_tile": 0,
        "prices": {
            "_comment": f"原版 {city['name']} 的 CITY_PROPERTY，单位万圆。",
            "blank_land_price": prop["uPrice_BLANK_LAND"],
            "build_cost": {"flat": prop["uCost_FLAT_HOUSE"], "hotel": prop["uCost_HOTEL_HOUSE"],
                           "floor": prop["uCost_FLOOR_HOUSE"], "villa": prop["uCost_VILLA_HOUSE"],
                           "upgrade": prop["uCost_UPDATE"], "function": prop["uCost_FUNCTION_HOUSE"]},
            "rent": {"blank_land": prop["uRent_BLANK_LAND"], "flat": prop["uRent_FLAT_HOUSE"],
                     "hotel": prop["uRent_HOTEL_HOUSE"], "super_hotel": prop["uRent_SUPER_HOTEL_HOUSE"],
                     "floor": prop["uRent_FLOOR_HOUSE"], "super_floor": prop["uRent_SUPER_FLOOR_HOUSE"],
                     "villa": prop["uRent_VILLA_HOUSE"]},
        },
        "groups": groups,
        "tiles": tiles,
    }


def summary(d: dict) -> str:
    tiles = d["tiles"]
    count: dict = {}
    for t in tiles:
        if "site" not in t:
            count[t["type"]] = count.get(t["type"], 0) + 1
    aliases = sum(1 for t in tiles if "site" in t)
    cross = sum(1 for t in tiles if len(t["next"]) > 1)
    parts = "、".join(f"{TYPE_NAMES.get(k, k)} {v}" for k, v in sorted(count.items()))
    return (f"{d['name']}：{len(tiles)} 格（{parts}；分身格 {aliases}），"
            f"能选方向的路口 {cross} 个，街道 {len(d['groups'])} 条")


def main() -> int:
    ap = argparse.ArgumentParser(description="原版 .cit 地图 → 四方来财地图 JSON")
    ap.add_argument("source", help="extracted/data/cities/*.json 或原版 .cit 文件")
    ap.add_argument("--id", required=True, help="地图 id，也是输出文件名")
    ap.add_argument("--name", help="显示的地图名，默认用原版城市名")
    ap.add_argument("--out", help="输出文件，默认 fourwinds-benti/data/maps/<id>.json")
    ap.add_argument("--force", action="store_true", help="覆盖已有文件")
    ap.add_argument("--print", action="store_true", help="只打印统计，不写文件")
    args = ap.parse_args()
    src = Path(args.source)
    city = load_city(src)
    d = convert(city, args.id, args.name or city["name"], src.name)
    print(summary(d))
    if args.print:
        return 0
    out = Path(args.out) if args.out else MAPS / f"{args.id}.json"
    if out.exists() and not args.force:
        print(f"{out} 已存在，没有覆盖（要覆盖加 --force）")
        return 1
    out.write_text(json.dumps(d, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"写入 {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
