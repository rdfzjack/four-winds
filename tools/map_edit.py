#!/usr/bin/env python3
"""小改地图的工具：调换两个建筑 / 地块的位置、把几块地划进一条街（新建 / 改名）、改路口自选 / 随机、
改某一格的出口（路口的方向、岔路）、改价格。每次改完自动检查（格式 + 整张图任何格子都走得通）。
用法（地图 id 是 fourwinds-benti/data/maps/ 里的文件名，不含 .json；格子编号看 tools/map_info.py 或游戏里点格子）：
  python3 tools/map_edit.py 地图id swap A B                 调换 A、B 两个格子上的东西（建筑、地块、银行……整个换）
  python3 tools/map_edit.py 地图id street 街名 id id id ...  把这几块地划进“街名”这条街（街名不存在就新建，可加 --color #81c784）
  python3 tools/map_edit.py 地图id rename-street 旧名 新名
  python3 tools/map_edit.py 地图id crossroad ID choice|random   这个路口默认自选还是随机
  python3 tools/map_edit.py 地图id exits ID n1 [n2 ...]     这一格走完去哪（一个 = 单行道，两个以上 = 路口）
  python3 tools/map_edit.py 地图id set ID 字段=值 ...         改这一格的字段：price_pct、build_cost_pct、price、rent、name、industry
  python3 tools/map_edit.py 地图id check                    只检查
加 --dir 目录 可以改别处的地图文件（测试用）。改之前建议先复制一份地图文件。
做不到的：新增路面 / 新增地块（要写 pos 坐标，比较麻烦，找 Claude）。"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate_data import check_map  # noqa: E402

CONTENT_FIELDS = ["type", "name", "industry", "price", "rent", "group", "price_pct", "build_cost_pct", "source"]
SETTABLE = {"price_pct", "build_cost_pct", "price", "rent", "name", "industry"}
GROUP_COLORS = ["#8d6e63", "#4fc3f7", "#f48fb1", "#ba68c8", "#ff8a65", "#e57373", "#fff176", "#81c784",
                "#1565c0", "#4db6ac"]


def fail(msg: str) -> None:
    print("错误：" + msg)
    sys.exit(1)


def main_tile(tiles: list, i: int) -> dict:
    if not 0 <= i < len(tiles):
        fail(f"格子 {i} 不存在（这张图 0–{len(tiles) - 1}）")
    if "site" in tiles[i]:
        fail(f"格子 {i} 是分身格，请用它的正格 {tiles[i]['site']}")
    return tiles[i]


def reach(tiles: list, start: int, reverse: bool = False) -> set:
    edges: dict[int, list] = {i: [] for i in range(len(tiles))}
    for t in tiles:
        for n in t["next"]:
            if reverse:
                edges[n].append(t["id"])
            else:
                edges[t["id"]].append(n)
    seen, stack = {start}, [start]
    while stack:
        for n in edges[stack.pop()]:
            if n not in seen:
                seen.add(n)
                stack.append(n)
    return seen


def check(d: dict) -> list[str]:
    errors = check_map(d, 4) if not d.get("short_streets_ok") else check_map(d, 0)
    tiles = d["tiles"]
    start = int(d.get("start_tile", 0))
    if len(reach(tiles, start)) != len(tiles):
        errors.append("从起点走不到所有格子（改了出口以后有格子成了孤岛）")
    if len(reach(tiles, start, reverse=True)) != len(tiles):
        errors.append("有些格子走进去就出不来（要保证从任何格子都能走回起点）")
    return errors


def fix_aliases(tiles: list) -> None:
    for t in tiles:
        if "site" in t:
            t["type"] = tiles[t["site"]]["type"]


def main() -> None:
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("map")
    ap.add_argument("cmd")
    ap.add_argument("args", nargs="*")
    ap.add_argument("--color", default=None)
    ap.add_argument("--dir", default=str(ROOT / "fourwinds-benti" / "data" / "maps"))
    ap.add_argument("-h", "--help", action="store_true")
    a = ap.parse_args()
    path = Path(a.dir) / f"{a.map}.json"
    if not path.exists():
        fail(f"找不到 {path}")
    d = json.load(open(path, encoding="utf-8"))
    tiles = d["tiles"]
    if a.cmd == "check":
        pass
    elif a.cmd == "swap":
        i, j = int(a.args[0]), int(a.args[1])
        ta, tb = main_tile(tiles, i), main_tile(tiles, j)
        old_a = {k: ta.get(k) for k in CONTENT_FIELDS}
        old_b = {k: tb.get(k) for k in CONTENT_FIELDS}
        for k in CONTENT_FIELDS:
            for t, src in ((ta, old_b), (tb, old_a)):
                if src[k] is None:
                    t.pop(k, None)
                else:
                    t[k] = src[k]
        fix_aliases(tiles)
        print(f"已调换 {i}（{ta.get('name', ta['type'])}）和 {j}（{tb.get('name', tb['type'])}）")
    elif a.cmd == "street":
        name, ids = a.args[0], [int(x) for x in a.args[1:]]
        if not ids:
            fail("要写至少一块地的编号")
        if name not in d["groups"]:
            d["groups"][name] = {"name": name, "color": a.color or GROUP_COLORS[len(d["groups"]) % len(GROUP_COLORS)]}
        elif a.color:
            d["groups"][name]["color"] = a.color
        for i in ids:
            t = main_tile(tiles, i)
            if t["type"] != "land":
                fail(f"格子 {i} 不是地（是 {t['type']}）")
            t["group"] = name
        for g in [g for g in d["groups"] if not any(t.get("group") == g for t in tiles)]:
            print(f"（街“{g}”现在一块地也没有了，已删掉）")
            del d["groups"][g]
        print(f"已把 {ids} 划进“{name}”")
    elif a.cmd == "rename-street":
        old, new = a.args
        if old not in d["groups"] or new in d["groups"]:
            fail("旧街名不存在，或新街名已经有了")
        d["groups"] = {(new if k == old else k): (dict(v, name=new) if k == old else v) for k, v in d["groups"].items()}
        for t in tiles:
            if t.get("group") == old:
                t["group"] = new
            if t.get("type") == "land" and str(t.get("name", "")).startswith(old):
                t["name"] = new + str(t["name"])[len(old):]
    elif a.cmd == "crossroad":
        i, mode = int(a.args[0]), a.args[1]
        if mode not in ("choice", "random"):
            fail("方式只能写 choice 或 random")
        if len(tiles[i]["next"]) < 2:
            fail(f"格子 {i} 不是路口（出口只有 {len(tiles[i]['next'])} 个）")
        tiles[i]["crossroad"] = mode
    elif a.cmd == "exits":
        i, nexts = int(a.args[0]), [int(x) for x in a.args[1:]]
        if not nexts or any(not 0 <= n < len(tiles) for n in nexts):
            fail("出口要写至少一个存在的格子编号")
        tiles[i]["next"] = nexts
        if len(nexts) > 1:
            tiles[i].setdefault("crossroad", "choice")
        else:
            tiles[i].pop("crossroad", None)
        print(f"格子 {i} 的出口改成 {nexts}")
    elif a.cmd == "set":
        t = main_tile(tiles, int(a.args[0]))
        for kv in a.args[1:]:
            k, v = kv.split("=", 1)
            if k not in SETTABLE:
                fail(f"不能改 {k}（能改：{sorted(SETTABLE)}）")
            t[k] = v if k in ("name", "industry") else int(v)
    else:
        fail("不认识的命令。能用：swap / street / rename-street / crossroad / exits / set / check")
    errors = check(d)
    if errors:
        print("改完以后检查出问题（没有写入文件）：")
        for e in errors:
            print("  · " + e)
        sys.exit(1)
    if a.cmd != "check":
        json.dump(d, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
        print(f"已写入 {path}，检查通过。提醒：关卡里预置地产写的格子编号如果换了类型，运行 python3 tools/validate_data.py 会报")
    else:
        print("检查通过")


if __name__ == "__main__":
    main()
