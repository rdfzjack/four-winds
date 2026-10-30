#!/usr/bin/env python3
"""Build the first version of the Godot game data from extracted/.

Usage:
    python3 tools/build_game_data.py            # write files that do not exist yet
    python3 tools/build_game_data.py --force    # overwrite (loses hand edits!)
    python3 tools/build_game_data.py --force --only chance.json,shanghai_loop.json

Writes into fourwinds-benti/data/:
    maps/shanghai_loop.json        38-tile loop built from the original Shanghai data
    cards/chance.json              30 chance cards + 4 special events, effects from the game code
    ai/profiles.json               AI parameters for the 4 characters (from Ai/Standard.ai)
    lines/speech.json              speech lines per event (drafts) + original lines for reference
    reference/original_cities.json price tables of all 24 original maps (for designing new maps)

After the first run these files belong to the author: edit the JSON directly.
The script skips files that already exist unless --force is given.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXTRACTED = ROOT / "extracted"
DATA = ROOT / "fourwinds-benti" / "data"

# Our 4 characters and which original character lends them placeholder data
# (AI parameters now, art in step 3). Same mapping as characters.json.
CHARACTERS = {
    "david": {"name": "斐斐", "original": "包德利", "code": "bdl"},
    "giorgio": {"name": "小九", "original": "冯全篾", "code": "fqm"},
    "marcel": {"name": "孔雀", "original": "董莺雨", "code": "dyy"},
    "eric": {"name": "理理", "original": "发达而", "code": "fdr"},
}

# ------------------------------------------------------------------ map

# One loop of 38 tiles laid on an 11 x 10 rectangle. Corners: 0, 10, 19, 29.
# "land:<street>" takes the next lot of that street from the original city;
# "company:<name>" takes price/rent/industry from the original building.
SHANGHAI_LOOP = {
    "id": "shanghai_loop",
    "name": "上海（原版数据，一圈）",
    "source_city": "Cit_Shaihai",
    "width": 11,
    "height": 10,
    "tiles": [
        "start",
        "land:顺昌路", "chance", "land:顺昌路",
        "land:北京路", "land:北京路", "land:北京路",
        "company:上海站",
        "land:华山路", "land:华山路",
        "jail",
        "land:万航渡路", "company:大世界夜总会", "land:万航渡路", "land:万航渡路",
        "bank",
        "land:河南中路", "chance", "land:河南中路",
        "park",
        "land:河南中路", "church",
        "land:中华路", "land:中华路", "company:十六铺码头", "land:中华路",
        "race_course",
        "land:南京西路", "land:南京西路",
        "government",
        "land:南京西路", "company:百乐门夜总会", "chance", "company:先施百货公司", "bank",
        "land:南京路", "land:南京路", "land:南京路",
    ],
}

GROUP_COLORS = ["#8d6e63", "#4fc3f7", "#f48fb1", "#ba68c8", "#ff8a65",
                "#e57373", "#fff176", "#81c784", "#1565c0", "#4db6ac"]

TYPE_NAMES = {"start": "起点", "chance": "运气", "bank": "银行", "jail": "巡捕房",
              "park": "公园", "church": "教堂", "government": "市政厅",
              "race_course": "赛马场", "tax": "税务局", "casino": "赌场"}

INDUSTRY = {0: "transport", 1: "public", 2: "food", 3: "cigarette", 4: "newspaper",
            5: "weaving", 6: "shop", 7: "entertainment"}


def perimeter(width: int, height: int) -> list[list[int]]:
    """Positions around a rectangle, starting bottom-right, going left first."""
    w, h = width - 1, height - 1
    pos = [[w, h]]
    pos += [[x, h] for x in range(w - 1, -1, -1)]
    pos += [[0, y] for y in range(h - 1, -1, -1)]
    pos += [[x, 0] for x in range(1, w + 1)]
    pos += [[w, y] for y in range(1, h)]
    return pos


def street_of(lot_name: str) -> str:
    return lot_name.rstrip(" 0123456789号")


def build_loop_map(spec: dict) -> dict:
    city = json.loads((EXTRACTED / "data/cities" / f"{spec['source_city']}.json").read_text("utf-8"))
    prop = city["property"]
    lots: dict[str, list] = {}
    for b in city["blocks"]:
        if b["class"] == "LAND":
            lots.setdefault(street_of(b["name"]), []).append(b)
    companies = {b["name"]: b for b in city["buildings"] if b["class"] == "COMPANY"}

    pos = perimeter(spec["width"], spec["height"])
    if len(pos) != len(spec["tiles"]):
        raise ValueError(f"{len(spec['tiles'])} tiles do not fit a "
                         f"{spec['width']}x{spec['height']} loop ({len(pos)} positions)")
    groups: dict[str, dict] = {}
    used: dict[str, int] = {}
    tiles = []
    for i, entry in enumerate(spec["tiles"]):
        kind, _, arg = entry.partition(":")
        t: dict = {"id": i, "type": kind}
        if kind == "land":
            street = arg
            k = used.get(street, 0)
            lot = lots[street][k]
            used[street] = k + 1
            if street not in groups:
                groups[street] = {"name": street,
                                  "color": GROUP_COLORS[len(groups) % len(GROUP_COLORS)]}
            t.update({"name": f"{street}{k + 1}号", "group": street,
                      "price_pct": lot["value_pct"],
                      "build_cost_pct": lot["build_cost_pct"],
                      "source": f"{spec['source_city']}.cit 地块 ({lot['x']},{lot['y']}) {lot['name']}"})
        elif kind == "company":
            c = companies[arg]
            t.update({"name": arg, "industry": INDUSTRY.get(c["company_group"], "other"),
                      "price": c["price"], "rent": c["rent"]})
            if c.get("describe"):
                t["slogan"] = c["describe"].strip()
            t["source"] = f"{spec['source_city']}.cit 建筑 {arg}"
        else:
            t["name"] = TYPE_NAMES.get(kind, kind)
        t["pos"] = pos[i]
        t["next"] = [(i + 1) % len(spec["tiles"])]
        tiles.append(t)
    return {
        "id": spec["id"],
        "name": spec["name"],
        "placeholder": True,
        "_comment": "由 tools/build_game_data.py 从原版上海数据生成，之后可直接修改。"
                    "每格的 next 列出可以走到的下一格；岔路就是 next 有多个格子。"
                    "price_pct 是地价系数：空地价 = price_pct × blank_land_price ÷ 100，租金也按它算；"
                    "build_cost_pct 是建房系数：造价 = 房子所占各块地的 build_cost_pct 之和 × 造价 ÷ 100。",
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


# ------------------------------------------------------------------ chance cards

# Card effects as read from the game code (chance1..chance30 in 1940.exe,
# see docs/original_rules.md). id -> (simplified text, effects, setting_specific)
CARD_EFFECTS = {
    1: ("成为小偷：盗窃所遇第一人的全部现款", [{"op": "state", "state": "thief", "days": 0}], False),
    2: ("成为纵火犯：一周内烧毁所到地点的房屋", [{"op": "state", "state": "arsonist", "days": 7}], False),
    3: ("成为抢劫犯：一周内把所到公司据为己有", [{"op": "state", "state": "robber", "days": 7}], False),
    4: ("被金砖绊倒，得 300 万圆", [{"op": "money", "amount": 300}], False),
    5: ("走私军火，拘留五天", [{"op": "jail", "days": 5}], False),
    6: ("逛夜总会，花费 100 万圆", [{"op": "money", "amount": -100}], False),
    7: ("抗日募捐，收每人 50 万圆", [{"op": "money_from_each", "amount": 50}], True),
    8: ("贪污募捐款，坐牢三天", [{"op": "jail", "days": 3}], False),
    9: ("丑行败露，付每人遮丑费 100 万圆", [{"op": "money_to_each", "amount": 100}], False),
    10: ("举止粗俗，送教堂感化", [{"op": "goto", "tile_type": "church", "trigger_stop": True}], False),
    11: ("随地吐痰，罚款 30 万圆", [{"op": "money", "amount": -30}], False),
    12: ("赤膊上街，强令买衣服花费 100 万圆", [{"op": "money", "amount": -100}], False),
    13: ("出身贫贱，免费旅游一周", [{"op": "state", "state": "free_rent", "days": 7}], False),
    14: ("挥霍成性，加倍消费一周", [{"op": "state", "state": "double_rent", "days": 7}], False),
    15: ("生活拮据，半价旅行一周", [{"op": "state", "state": "half_rent", "days": 7}], False),
    16: ("得罪市长，最贵地产被没收", [{"op": "lose_most_expensive_land"}], False),
    17: ("支援抗战前线，抵押物业被政府收回", [{"op": "lose_mortgaged_properties"}], True),
    18: ("银行倒闭，所有存款丢失", [{"op": "lose_deposit"}], False),
    19: ("意外拾到 100 万圆", [{"op": "money", "amount": 100}], False),
    20: ("擦皮鞋，得 1 万圆", [{"op": "money", "amount": 1}], False),
    21: ("被富婆相中，得 300 万圆", [{"op": "money", "amount": 300}], False),
    22: ("见义勇为，反被巡捕房拘留 3 日", [{"op": "jail", "days": 3}], False),
    23: ("得罪黑帮，一处房屋被砸", [{"op": "demolish_random_house"}], False),
    24: ("经营不善，所有房产贬值 10%", [{"op": "land_value_pct", "pct": -10}], False),
    25: ("经营有方，所有土地增值 10%", [{"op": "land_value_pct", "pct": 10}], False),
    26: ("得到政府赏识，所有房产级别提升", [{"op": "upgrade_houses"}], False),
    27: ("痛打洋鬼子，受国人拥戴，免费旅游三天", [{"op": "state", "state": "free_rent", "days": 3}], True),
    28: ("得罪洋大人，坐牢三天", [{"op": "jail", "days": 3}], True),
    29: ("支援抗战前线，捐款 100 万圆", [{"op": "money", "amount": -100}], True),
    30: ("发展慈善事业，所有产业免费开放一周", [{"op": "state", "state": "charity", "days": 7}], False),
}

# Draw weight (0-100) and which original characters can draw each card,
# copied from the tables at 0x45399c and 0x4538ac in 1940.exe.
# Column order = PERSON_ID: 董莺雨 四毛 包德利 陈玛丽 赛珍珠 冯全篾 发达而 金如山
ORIGINAL_ORDER = ["董莺雨", "四毛", "包德利", "陈玛丽", "赛珍珠", "冯全篾", "发达而", "金如山"]
CARD_WEIGHT = {18: 30, 26: 30}
CARD_ALLOWED = {
    3: "01101110", 5: "10110101", 6: "01100001", 7: "11111110", 9: "00100111",
    10: "01000101", 11: "01111101", 12: "01100001", 13: "11011101", 18: "11111011",
    20: "00001001", 21: "01100101", 23: "11111011", 27: "11011101", 28: "11111101",
}

# Pictures 31-34 are not in the chance deck; the game shows them for other events.
SPECIAL_EVENTS = [
    {"id": "antique", "picture": "Sprite/Chance31.pic", "text": "发现古董，获利 1000 万圆",
     "when": "建房后随机触发；概率按房子占地：1 块 1/61，2 块 1/41，3 块 1/31，4 块 1/16",
     "effects": [{"op": "money", "amount": 1000}]},
    {"id": "collapse", "picture": "Sprite/Chance32.pic", "text": "发生事故，房屋倒塌",
     "when": "建房后没挖到古董时，再有 1/31 的概率触发；刚盖的房子被拆掉，造价不退",
     "effects": [{"op": "demolish_new_house"}]},
    {"id": "fake_money", "picture": "Sprite/Chance33.pic", "text": "收到假钞，收益作废",
     "when": "程序里没有调用，是没用上的图", "effects": []},
    {"id": "mortgage_seized", "picture": "Sprite/Chance34.pic", "text": "银行强行扣留应付款项",
     "when": "抵押地产时有 1/21 的概率触发：地照样抵押，但拿不到钱",
     "effects": [{"op": "mortgage_without_payment"}]},
]

CARD_OPS = {
    "money": "现金增减 amount 万圆；支出时先扣现金，不够再扣存款，还不够就破产",
    "money_from_each": "向其他每位玩家各收 amount 万圆（对方付不起就破产）",
    "money_to_each": "付给其他每位玩家各 amount 万圆（自己付不起就破产）",
    "jail": "直接送到巡捕房，坐牢 days 回合（这期间跳过回合）",
    "goto": "直接移动到 tile_type 格子；trigger_stop 为 true 时触发停在那里的效果",
    "state": "进入状态 state，持续 days 回合（0 = 一直持续到触发一次）。thief 小偷 / arsonist 纵火犯 / "
             "robber 抢劫犯 / free_rent 免付租金 / double_rent 付租加倍 / half_rent 付租减半 / "
             "charity 自己的产业不收租。玩家同一时间只有一种状态，新状态会覆盖旧的",
    "lose_most_expensive_land": "自己地价最高的一块空地被收走（地上的房子拆掉，变成无主）",
    "lose_mortgaged_properties": "自己所有已抵押的地产和企业被收走（变成无主）",
    "demolish_random_house": "随机拆掉自己的一栋房子",
    "land_value_pct": "自己所有地块的地价系数改变 pct%（地价和租金都跟着变）",
    "upgrade_houses": "自己所有旅社免费升成旅馆、小洋楼免费升成花园洋房",
    "lose_deposit": "银行存款清零",
    "demolish_new_house": "刚盖好的房子被拆掉",
    "mortgage_without_payment": "这次抵押拿不到钱",
}


def build_cards() -> dict:
    src = json.loads((EXTRACTED / "text/chance_cards.json").read_text("utf-8"))
    cards = []
    for c in src["cards"]:
        if c["id"] not in CARD_EFFECTS:
            continue
        text, effects, specific = CARD_EFFECTS[c["id"]]
        mask = CARD_ALLOWED.get(c["id"], "11111111")
        original_allowed = [n for n, bit in zip(ORIGINAL_ORDER, mask) if bit == "1"]
        card = {"id": c["id"], "text": text, "effects": effects,
                "weight": CARD_WEIGHT.get(c["id"], 100),
                "allowed_for": [cid for cid, ch in CHARACTERS.items() if ch["original"] in original_allowed],
                "original_allowed": original_allowed,
                "original_text": f"{c['title']} {c['text']}",
                "picture": c["picture"]}
        if specific:
            card["setting_specific"] = True
        cards.append(card)
    return {
        "_comment": "机会卡。效果和数值都是从原版程序里读出来的（见 docs/original_rules.md）。"
                    "抽卡：随机选一张，若当前角色不在 allowed_for 里就重抽，再以 weight% 的概率保留，否则重抽。"
                    "allowed_for 是 4 个新角色，暂时照抄借用的原版角色（斐斐=包德利，小九=冯全篾，"
                    "孔雀=董莺雨，理理=发达而），作者可以按人设改；original_allowed 是原版 8 个角色。"
                    "setting_specific 标出带 1940 年代中国背景、换皮时要改写的卡。",
        "ops": CARD_OPS,
        "cards": cards,
        "special_events": SPECIAL_EVENTS,
    }


# ------------------------------------------------------------------ AI

AI_PARAM_DOC = {
    "buyLandExpect": "越小，越喜欢买土地",
    "buyCompanyExpect": "越小，越喜欢买企业",
    "keepCashExpect": "一般情况下希望保留的现金数（万圆）",
    "keepCashDiff": "越小，进入银行越频繁",
    "buildHouseExpect": "越小，越喜欢建房",
    "mortgageExpect": "越小，越喜欢抵押",
    "unmortgageExpect": "越小，越喜欢赎回",
    "removeExpect": "越小，越喜欢拆房",
    "intendToAddMuchMoney": "越大，拍卖时越愿意加价",
    "acceptableDiffenceInTrade": "交易中能接受的价值差（百分比，负数 = 愿意吃亏）",
    "tradeCycle": "平均几回合主动找人交易一次",
    "maxInvestment": "资金低于 总资产 × 此值 ÷ 100 时不再投资",
}


def build_ai() -> dict:
    src = json.loads((EXTRACTED / "text/ai/Standard.json").read_text("utf-8"))["profiles"]
    # 每个参数组分形态：front = 表形态（原版参数），back = 里形态（待定，没写的数沿用 front）
    profiles = {"standard": {"front": {"based_on": "标准", **src["标准"]}}}
    for cid, c in CHARACTERS.items():
        profiles[cid] = {"front": {"based_on": c["original"], **src[c["original"]]}, "back": {}}
    return {
        "_comment": "AI 性格参数（原版 12 项阈值）。4 个角色暂时借用原版角色的参数（based_on），"
                    "来源 shanghai1940/Ai/Standard.ai。第 4 步再按人设细调。",
        "params": AI_PARAM_DOC,
        "profiles": profiles,
    }


# ------------------------------------------------------------------ speech lines

CONDITIONS = [
    ("GIVE_MUCH_MONEY", "付了一大笔钱（高额租金）"),
    ("GIVE_LITTLE_MONEY", "付了一点小钱"),
    ("GOOD_LUCK", "交好运"),
    ("BAD_LUCK", "倒霉"),
    ("TO_JAIL", "进巡捕房"),
    ("BUILD_VILLA", "建成别墅"),
    ("TRADE_OK", "交易成功"),
    ("TRADE_NOT_OK", "交易被拒"),
    ("GET_CHARITY", "得到施舍"),
    ("BEEN_STOLEN", "被偷"),
    ("STEAL", "偷到钱"),
    ("AFTER_DANGER", "脱险"),
]

# Draft lines written from the personas in docs/design.md. The author will rewrite.
DRAFT_LINES = {
    "david": ["这笔账，我记下了。", "零钱而已，不必找了。", "运气也是一种资产。", "短期波动，不足挂齿。",
              "我要见我的律师——还有我的银行经理。", "利息总会回来的。", "很高兴和您做生意。",
              "您先开个价，我再考虑。", "这算借款，还是赠予？", "保险公司会处理的……我希望。",
              "就当是提前收的手续费。", "风险已对冲。"],
    "giorgio": ["Mamma mia！这比海关还狠！", "拿去，朋友，喝杯咖啡。", "圣母保佑那不勒斯人！",
                "今天的海风不对劲。", "我只是个卖橄榄油的！", "给我妈妈也盖一间。", "成交！握手就算合同。",
                "朋友之间，别这么算计嘛。", "你是好人，我欠你一次。", "谁动了我的货？！",
                "这不叫偷，这叫转运。", "跑得比缉私船还快。"],
    "marcel": ["如此粗鄙的数字……", "区区小数，不值一提。", "这是学识的回报。", "此乃命运对学者的嫉妒。",
               "你们可知道我是法兰西学院的……？", "终于有地方放我的藏书了。", "成交。记得在报上写明是我让的价。",
               "这种价格，有辱斯文。", "我收下，纯粹是为了学术。", "那可是吐火罗文的手稿！",
               "这叫文物保护。", "体面，总算保住了。"],
    "eric": ["记在竞选经费里。", "我早就算到了。", "内部消息从不出错。", "这是对手的抹黑！",
             "我要求举行听证会。", "下一步，州长官邸。", "你刚刚错过了更好的价格。",
             "没关系，我已经买下了你隔壁那块。", "选民的支持我心领了。", "我会让国会调查此事。",
             "这叫再分配。", "我从不出现在出事的现场。"],
}


def build_lines() -> dict:
    src = json.loads((EXTRACTED / "text/speech_lines.json").read_text("utf-8"))
    chars = {}
    for cid, lines in DRAFT_LINES.items():
        chars[cid] = {cond: [line] for (cond, _), line in zip(CONDITIONS, lines)}
    reference = {}
    for code, c in src["characters"].items():
        reference[c["name"]] = c["lines"]
    return {
        "_comment": "角色台词。characters 里每种事件是一个列表，游戏从中随机挑一句，可以随时加句子。"
                    "这一版是按设计文档人设写的草稿，等作者改写。"
                    "以后可加 \"vs\"：{对手 id: {事件: [台词]}}，做针对某个对手的专属台词。"
                    "original_reference 是原版 8 个角色的台词（来自 Sentence/*.spr），只作参考，游戏不读。",
        "status": "草稿",
        "conditions": {cond: zh for cond, zh in CONDITIONS},
        "characters": chars,
        "original_reference": reference,
    }


# ------------------------------------------------------------------ reference cities

def build_reference() -> dict:
    summary = []
    for f in sorted((EXTRACTED / "data/cities").glob("*.json")):
        c = json.loads(f.read_text("utf-8"))
        streets: dict[str, dict] = {}
        for b in c["blocks"]:
            if b["class"] == "LAND":
                s = streets.setdefault(street_of(b["name"]), {"lots": 0, "price_pct": []})
                s["lots"] += 1
                s["price_pct"].append(b["value_pct"])
        for s in streets.values():
            pcts = s.pop("price_pct")
            s["price_pct"] = pcts[0] if len(set(pcts)) == 1 else pcts
        companies = [{"name": b["name"], "industry": INDUSTRY.get(b["company_group"], "other"),
                      "price": b["price"], "rent": b["rent"],
                      **({"slogan": b["describe"].strip()} if b.get("describe") else {})}
                     for b in c["buildings"] if b["class"] == "COMPANY"]
        functions: dict[str, int] = {}
        for b in c["buildings"]:
            if b["class"] != "COMPANY":
                functions[b["class"].lower()] = functions.get(b["class"].lower(), 0) + 1
        summary.append({"file": c["source"], "name": c["name"], "grid_size": c["size"],
                        "prices": c["property"], "streets": streets,
                        "companies": companies, "other_buildings": functions})
    return {"_comment": "原版 24 张地图的价格表、街道、企业，供设计新地图时参考。游戏不读这个文件。",
            "cities": summary}


# ------------------------------------------------------------------ main

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--force", action="store_true", help="overwrite existing files")
    ap.add_argument("--only", default="", help="comma-separated file names to build, e.g. chance.json")
    a = ap.parse_args()
    only = set(filter(None, a.only.split(",")))
    outputs = {
        "maps/shanghai_loop.json": lambda: build_loop_map(SHANGHAI_LOOP),
        "cards/chance.json": build_cards,
        "ai/profiles.json": build_ai,
        "lines/speech.json": build_lines,
        "reference/original_cities.json": build_reference,
    }
    for rel, fn in outputs.items():
        if only and Path(rel).name not in only:
            continue
        path = DATA / rel
        if path.exists() and not a.force:
            print(f"跳过（已存在）：{rel}")
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(fn(), ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        print(f"已生成：{rel}")


if __name__ == "__main__":
    main()
