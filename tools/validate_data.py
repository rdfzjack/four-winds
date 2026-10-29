#!/usr/bin/env python3
"""Check the Godot project's data files without opening Godot.

Usage:
    python3 tools/validate_data.py [--project fourwinds-benti]

Applies the same map checks as fourwinds-benti/scripts/core/board.gd
(validate) plus basic checks on rules.json and characters.json, and runs a
small walk test on every map. Exit code 0 = all good.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

TILE_TYPES = {"start", "land", "company", "chance", "bank", "tax", "jail", "park",
              "church", "government", "casino", "race_course"}


def load(path: Path, errors: list[str]):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        errors.append(f"找不到 {path}")
    except json.JSONDecodeError as e:
        errors.append(f"{path} JSON 格式错误：第 {e.lineno} 行 {e.msg}")
    return None


def longest_street(tiles: list) -> int:
    """最长的一条街：同一街道组、沿路（next）连续的地有几块。"""
    best = 0

    def extend(chain: list) -> int:
        longest = len(chain)
        for nx in tiles[chain[-1]]["next"]:
            t = tiles[nx]
            if t.get("type") == "land" and t.get("group") == tiles[chain[0]].get("group") \
                    and nx not in chain:
                longest = max(longest, extend(chain + [nx]))
        return longest

    for i, t in enumerate(tiles):
        if t.get("type") == "land":
            best = max(best, extend([i]))
    return best


def check_map(d: dict, max_house_lots: int = 4) -> list[str]:
    errors: list[str] = []
    if not d.get("id"):
        errors.append("地图缺少 id")
    tiles = d.get("tiles") or []
    groups = d.get("groups") or {}
    if not tiles:
        return errors + ["地图没有格子"]
    n = len(tiles)
    for i, t in enumerate(tiles):
        label = f"第 {i} 格"
        if t.get("id") != i:
            errors.append(f"{label} 的 id 是 {t.get('id')}，应该是 {i}")
        typ = t.get("type", "")
        if typ not in TILE_TYPES:
            errors.append(f"{label} 的类型 {typ!r} 不认识")
        nexts = t.get("next") or []
        if not nexts:
            errors.append(f"{label} 没有下一格")
        for nx in nexts:
            if not isinstance(nx, int) or not 0 <= nx < n:
                errors.append(f"{label} 的下一格 {nx} 超出范围")
        if typ == "land":
            if t.get("group") not in groups:
                errors.append(f"{label} 的街道组 {t.get('group')!r} 没有定义")
            if "price_pct" not in t:
                errors.append(f"{label} 缺少 price_pct")
            if "build_cost_pct" not in t:
                errors.append(f"{label} 缺少 build_cost_pct")
        if typ == "company" and ("price" not in t or "rent" not in t):
            errors.append(f"{label} 是企业，需要 price 和 rent")
        pos = t.get("pos")
        if not (isinstance(pos, list) and len(pos) == 2):
            errors.append(f"{label} 缺少 pos")
    start = d.get("start_tile", 0)
    if not 0 <= start < n:
        return errors + [f"start_tile {start} 超出范围"]
    if errors:
        return errors
    seen, queue = {start}, [start]
    while queue:
        cur = queue.pop(0)
        for nx in tiles[cur]["next"]:
            if nx not in seen:
                seen.add(nx)
                queue.append(nx)
    if len(seen) != n:
        errors.append(f"从起点走不到：{sorted(set(range(n)) - seen)}")
    street = longest_street(tiles)
    if street < max_house_lots:
        errors.append(f"最长的街只有 {street} 块连续的地，别墅要占 {max_house_lots} 块，"
                      f"至少要有一条街有 {max_house_lots} 块连续的地")
    positions = [tuple(t["pos"]) for t in tiles]
    if len(set(positions)) != n:
        errors.append("有格子的 pos 重复")
    return errors


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", default=str(root / "fourwinds-benti"))
    proj = Path(ap.parse_args().project)
    errors: list[str] = []

    rules = load(proj / "data/rules.json", errors) or {}
    if not rules.get("starting_cash"):
        errors.append("rules.json 缺少 starting_cash")
    chars = (load(proj / "data/characters.json", errors) or {}).get("characters", [])
    if len(chars) != 4:
        errors.append(f"characters.json 应该有 4 个角色，现在是 {len(chars)}")
    ids = [c.get("id") for c in chars]
    if len(set(ids)) != len(ids) or not all(ids):
        errors.append("角色 id 为空或重复")

    ai = load(proj / "data/ai/profiles.json", errors) or {}
    lines = load(proj / "data/lines/speech.json", errors) or {}
    conditions = lines.get("conditions", {})
    for c in chars:
        if c.get("ai_profile") not in ai.get("profiles", {}):
            errors.append(f"角色 {c.get('id')} 的 AI 参数 {c.get('ai_profile')!r} 不存在")
        lset = lines.get("characters", {}).get(c.get("lines"))
        if lset is None:
            errors.append(f"角色 {c.get('id')} 的台词 {c.get('lines')!r} 不存在")
        else:
            for cond in conditions:
                if not lset.get(cond):
                    errors.append(f"角色 {c.get('id')} 缺少事件 {cond} 的台词")
    cards = load(proj / "data/cards/chance.json", errors) or {}
    ops = cards.get("ops", {})
    ids = [c.get("id") for c in cards.get("cards", [])]
    if len(ids) != len(set(ids)):
        errors.append("机会卡 id 重复")
    char_ids = {c.get("id") for c in chars}
    for c in cards.get("cards", []):
        if not 0 <= c.get("weight", 100) <= 100:
            errors.append(f"机会卡 {c.get('id')} 的 weight 超出 0-100")
        for who in c.get("allowed_for", []):
            if who not in char_ids:
                errors.append(f"机会卡 {c.get('id')} 的 allowed_for 有不存在的角色 {who!r}")
        for e in c.get("effects", []):
            if e.get("op") not in ops:
                errors.append(f"机会卡 {c.get('id')} 的效果 {e.get('op')!r} 没有在 ops 里说明")
    print(f"机会卡 {len(ids)} 张，台词 {len(lines.get('characters', {}))} 人 × {len(conditions)} 种事件")

    map_ids = []
    for f in sorted((proj / "data/maps").glob("*.json")):
        d = load(f, errors)
        if d is None:
            continue
        map_ids.append(d.get("id"))
        lots = max((lv.get("lots", 1) for lv in rules.get("houses", {}).get("levels", [])), default=4)
        for e in check_map(d, lots):
            errors.append(f"{f.name}：{e}")
        print(f"{f.name}: {len(d.get('tiles', []))} 格, "
              f"路口 {sum(1 for t in d.get('tiles', []) if len(t.get('next', [])) > 1)} 个")
    if not map_ids:
        errors.append("data/maps 里没有地图")
    if rules.get("default_map") not in map_ids:
        errors.append(f"rules.json 的 default_map {rules.get('default_map')!r} 不存在")

    for e in errors:
        print("问题：", e)
    print("通过" if not errors else f"{len(errors)} 个问题")
    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(main())
