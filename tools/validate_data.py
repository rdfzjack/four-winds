#!/usr/bin/env python3
"""Check the Godot project's data files without opening Godot.

Usage:
    python3 tools/validate_data.py [--project fourwinds-benti]

Applies the same map checks as fourwinds-benti/scripts/core/board.gd
(validate) plus basic checks on rules.json and characters.json, the speech lines
(data/lines/*.txt, same reading as scripts/core/lines_db.gd), and runs a
small walk test on every map. Exit code 0 = all good.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lines_lib import Lines  # noqa: E402

TILE_TYPES = {"start", "land", "company", "chance", "bank", "tax", "jail", "park",
              "church", "government", "casino", "race_course", "road"}


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
            if t.get("type") == "land" and "site" not in t \
                    and t.get("group") == tiles[chain[0]].get("group") and nx not in chain:
                longest = max(longest, extend(chain + [nx]))
        return longest

    for i, t in enumerate(tiles):
        if t.get("type") == "land" and "site" not in t:
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
        if "crossroad" in t and t["crossroad"] not in ("choice", "random"):
            errors.append(f"{label} 的 crossroad {t['crossroad']!r} 不认识（只能是 choice 或 random）")
        if "site" in t:
            # 分身格：停在这里等于停在 site 那一格，site 要是同类型的正格
            s = t["site"]
            if not (isinstance(s, int) and 0 <= s < n and "site" not in tiles[s]
                    and tiles[s].get("type") == typ):
                errors.append(f"{label} 的 site 要指向一个同类型的正格（不能是分身格）")
        elif typ == "land":
            if t.get("group") not in groups:
                errors.append(f"{label} 的街道组 {t.get('group')!r} 没有定义")
            if "price_pct" not in t:
                errors.append(f"{label} 缺少 price_pct")
            if "build_cost_pct" not in t:
                errors.append(f"{label} 缺少 build_cost_pct")
        if typ == "company" and "site" not in t and ("price" not in t or "rent" not in t):
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
    if street < max_house_lots and not d.get("short_streets_ok", False):
        errors.append(f"最长的街只有 {street} 块连续的地，别墅要占 {max_house_lots} 块，"
                      f"至少要有一条街有 {max_house_lots} 块连续的地")
    positions = [tuple(t["pos"]) for t in tiles]
    if len(set(positions)) != n:
        errors.append("有格子的 pos 重复")
    return errors


CONDITION_TYPES = {"bankrupt", "build_house", "control_industry", "control_street", "own_lots_pct",
                   "assets_at_least", "days_over"}


def check_campaign(d: dict, maps: dict, char_ids: set, max_players: int, playable_ids: set) -> list[str]:
    """个人主线文件的检查（和 scripts/core/scenario.gd 的 validate 一致，不需要 Godot）。"""
    errors: list[str] = []
    if d.get("character") not in playable_ids:
        errors.append(f"角色 {d.get('character')!r} 不存在")
    seen = set()
    for st in d.get("stages", []):
        sid = st.get("id", "?")
        if sid in seen:
            errors.append(f"关卡 id {sid!r} 重复")
        seen.add(sid)
        board = maps.get(st.get("map"))
        if board is None:
            errors.append(f"关卡 {sid}：地图 {st.get('map')!r} 不存在")
            continue
        tiles = board.get("tiles", [])
        seats = st.get("seats", [])
        if st.get("crossroad", "") not in ("", "random", "choice"):
            errors.append(f"关卡 {sid}：crossroad 只能写 random 或 choice")
        if not 2 <= len(seats) <= max_players:
            errors.append(f"关卡 {sid}：座位数应该是 2 到 {max_players}")
        if sum(1 for s in seats if s.get("player")) != 1:
            errors.append(f"关卡 {sid}：要有且只有一个 player 座位")
        chars = [s.get("character") for s in seats]
        if len(set(chars)) != len(chars) or not set(chars) <= char_ids:
            errors.append(f"关卡 {sid}：角色不存在或重复")
        for i, s in enumerate(seats):
            for entry in s.get("props", []):
                for t in entry.get("tiles", [entry.get("tile", -1)]):
                    if not isinstance(t, (int, float)) or not 0 <= int(t) < len(tiles) or "site" in tiles[int(t)]:
                        errors.append(f"关卡 {sid} 座位 {i}：预置地产格子 {t} 不存在或是分身格")
        for key in ("win", "lose"):
            if not st.get(key):
                errors.append(f"关卡 {sid}：{key} 条件不能为空")
            for c in st.get(key, []):
                if c.get("type") not in CONDITION_TYPES:
                    errors.append(f"关卡 {sid}：不认识的条件类型 {c.get('type')!r}")
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
    lines = Lines(proj)
    errors.extend(lines.errors)
    for cid in ids:
        if (cid, "front") not in lines.sets:
            errors.append(f"角色 {cid} 没有台词文件（data/lines/{lines.nicknames.get(cid, cid)}.txt）")
    for c in chars:
        prof = ai.get("profiles", {}).get(c.get("ai_profile"))
        if prof is None:
            errors.append(f"角色 {c.get('id')} 的 AI 参数 {c.get('ai_profile')!r} 不存在")
        elif not isinstance(prof.get("front"), dict):
            errors.append(f"角色 {c.get('id')} 的 AI 参数缺少 front（表形态）")
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
    total = sum(len(v) for st in lines.sets.values() for v in st.values())
    print(f"机会卡 {len(ids)} 张，台词 {len(lines.sets)} 个文件共 {total} 句，{len(lines.events)} 种事件")

    map_ids = []
    map_data = {}
    for f in sorted((proj / "data/maps").glob("*.json")):
        d = load(f, errors)
        if d is None:
            continue
        map_ids.append(d.get("id"))
        map_data[d.get("id")] = d
        lots = max((lv.get("lots", 1) for lv in rules.get("houses", {}).get("levels", [])), default=4)
        for e in check_map(d, lots):
            errors.append(f"{f.name}：{e}")
        print(f"{f.name}: {len(d.get('tiles', []))} 格, "
              f"路口 {sum(1 for t in d.get('tiles', []) if len(t.get('next', [])) > 1)} 个")
    if not map_ids:
        errors.append("data/maps 里没有地图")
    if rules.get("default_map") not in map_ids:
        errors.append(f"rules.json 的 default_map {rules.get('default_map')!r} 不存在")

    extras = (load(proj / "data/extra_characters.json", errors) or {}).get("characters", [])
    extra_ids = {str(c.get("id")) for c in extras}
    if len(extra_ids) != len(extras) or extra_ids & {str(i) for i in char_ids}:
        errors.append("extra_characters.json 的 id 重复，或和 characters.json 重复")
    for f in sorted((proj / "data/campaigns").glob("*.json")):
        d = load(f, errors)
        if d is None:
            continue
        for e in check_campaign(d, map_data, {str(i) for i in char_ids} | extra_ids, int(rules.get("max_players", 4)),
                                {str(i) for i in char_ids}):
            errors.append(f"{f.name}：{e}")
        print(f"{f.name}: {len(d.get('stages', []))} 关")

    for e in errors:
        print("问题：", e)
    print("通过" if not errors else f"{len(errors)} 个问题")
    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(main())
