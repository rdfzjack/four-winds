extends RefCounted
## 原版 AI：照 1940.exe 里 Brain.cpp 的算法（反汇编读出，函数地址写在各函数的注释里）。
## 参数是 data/ai/profiles.json 里每个角色的 12 个阈值；打分表也在那个文件的 scoring 里。
##
## 用法：轮到 AI 时反复调用 Brain.step(game)，每次做一个决定；
## 返回 false 表示现在没有要 AI 做的事（游戏结束，或轮到人类）。
## 只通过 Game 的公开方法操作，不访问画面。
##
## 原版 AI 不看局势，只把几项“分数”加权后和阈值比，大于阈值就做：
## - 地分（_land_score）：回报率、周围有几块地、周围有几块自己的地、临不临路
## - 企业分（_company_score）：租金 / 价格、同行业有几家、自己有几家同行业、临几格路
## - 现金分 / 存款分（_money_score）：按现金 / 存款多少分档，0–90
## - 无主比例（_free_pct）：还没人买的地和企业占几成
## 抵押、赎回、交易、拍卖的部分（tryToTrade 等）留给第 5 步。
## mortgageExpect 和 removeExpect 在 Brain.cpp 里没有被读到（已读完 23 个函数）。

const JsonUtil = preload("res://scripts/core/json_util.gd")

const PROFILES_PATH := "res://data/ai/profiles.json"
const CHARACTERS_PATH := "res://data/characters.json"
## 原版网格的四个方向（地分看这四个方向上 1–3 格）
const DIRS := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]

## 角色 id -> 参数（测试可以直接改这个字典，换别的参数）
static var profiles: Dictionary = {}
static var scoring: Dictionary = {}
static var _geo: Dictionary = {}  ## Board 实例 id -> 网格信息（见 _geometry）


static func step(game) -> bool:
	if game.phase == "over" or game.player().human:
		return false
	if game.phase == "pre_roll":
		if not _improve(game):
			game.roll()
		return true
	if game.phase != "pending":
		return false
	var pi: int = game.current
	match str(game.pending["type"]):
		"choose_direction":
			# 原版路口按箭头走，AI 不选；这里随机
			var options: Array = game.pending["options"]
			game.choose_direction(int(options[game.rng.randi() % options.size()]))
		"bank":
			var amount := bank_amount(game, pi)
			if amount > 0:
				game.bank_deposit(amount)
			elif amount < 0:
				game.bank_withdraw(-amount)
			game.bank_done()
		"buy_land":
			if wants_land(game, pi, int(game.pending["tile"])):
				game.buy()
			else:
				game.decline()
		"buy_company":
			if wants_company(game, pi, int(game.pending["tile"])):
				game.buy()
			else:
				game.decline()
		"bail":
			game.bail(wants_bail(game, pi))
		_:
			return false
	return true


# ───────────────────────── 参数 ─────────────────────────

static func profile_of(game, pi: int) -> Dictionary:
	ensure_loaded()
	var c: String = game.players[pi].character
	return profiles.get(c, profiles.get("", {}))


static func param(game, pi: int, key: String) -> int:
	return int(profile_of(game, pi).get(key, 0))


## 读 profiles.json，按 characters.json 的 ai_profile 对到角色 id。"" 是找不到时用的 standard。
static func ensure_loaded() -> void:
	if not profiles.is_empty():
		return
	var errors: Array = []
	var file := JsonUtil.load_dict(PROFILES_PATH, errors)
	var chars := JsonUtil.load_dict(CHARACTERS_PATH, errors)
	if not errors.is_empty():
		push_error("原版 AI 读不到参数：%s" % str(errors))
	var by_id: Dictionary = file.get("profiles", {})
	scoring = file.get("scoring", {})
	profiles[""] = by_id.get("standard", {})
	for c in chars.get("characters", []):
		profiles[str(c["id"])] = by_id.get(str(c.get("ai_profile", "standard")), profiles[""])


# ───────────────────────── 被动决定：买、银行、保释 ─────────────────────────

## 买地（0x4075b0）：(6×地分 + 2×现金分 + 2×存款分) ÷ 10 > buyLandExpect 就买；
## 否则看别人：只要有一个对手的 (3×(现金分 + 存款分) + 4×他的地分) ÷ 10 > buyLandExpect，也买（抢地）。
## 现金分、存款分都是自己的。
static func wants_land(game, pi: int, tile: int) -> bool:
	var expect := param(game, pi, "buyLandExpect")
	var b := _money_score(game, game.players[pi].cash)
	var c := _money_score(game, game.players[pi].deposit)
	if (6 * _land_score(game, pi, tile) + 2 * b + 2 * c) / 10 > expect:
		return true
	for p in game.alive_players():
		if p.index != pi and (3 * (b + c) + 4 * _land_score(game, p.index, tile)) / 10 > expect:
			return true
	return false


## 买企业（0x407740）：(5×企业分 + 3×现金分 + 2×存款分) ÷ 10 > buyCompanyExpect 就买；
## 否则同样看对手，但原版这里比的是 buyLandExpect（照抄）。
static func wants_company(game, pi: int, tile: int) -> bool:
	var b := _money_score(game, game.players[pi].cash)
	var c := _money_score(game, game.players[pi].deposit)
	if (5 * _company_score(game, pi, tile) + 3 * b + 2 * c) / 10 > param(game, pi, "buyCompanyExpect"):
		return true
	for p in game.alive_players():
		if p.index != pi and (3 * (b + c) + 4 * _company_score(game, p.index, tile)) / 10 \
				> param(game, pi, "buyLandExpect"):
			return true
	return false


## 银行（0x408630）：要存（正数）或要取（负数）多少，0 = 不动。
## 想留的现金 = keepCashExpect × (无主比例 + 50) ÷ 100；现金和它差不到 keepCashDiff 就不动。
## 掷骰前想建房却差钱时（cash_need），多取出差的那部分。金额取整到 10。
static func bank_amount(game, pi: int) -> int:
	var p = game.players[pi]
	var target := param(game, pi, "keepCashExpect") * (_free_pct(game) + 50) / 100
	var diff: int = p.cash - target
	if absi(diff) < param(game, pi, "keepCashDiff"):
		return 0
	diff -= int(p.ai_memory.get("cash_need", 0))
	if p.deposit + diff < 0:
		diff = -p.deposit
	return diff - diff % 10


## 保释（0x409f20）：现金因子 × bailFactor < 100 就交。
## 现金因子（0x40b670）= 2 ÷ ((现金 + 存款) ÷ (总资产 ÷ 3) + 1)，里面的除法是整数除法。
## 也就是现金 + 存款不到总资产的 2/3 时，bailFactor = 100 的角色不交。
static func wants_bail(game, pi: int) -> bool:
	return _cash_factor(game, pi) * float(profile_of(game, pi).get("bailFactor", 100)) < 100.0


static func _cash_factor(game, pi: int) -> float:
	var p = game.players[pi]
	var third: int = game.total_assets(pi) / 3
	if third <= 0:
		return 0.0
	return 2.0 / (float((p.cash + p.deposit) / third) + 1.0)


# ───────────────────────── 掷骰前：建房、升级 ─────────────────────────

## 掷骰前做一件事，做了返回 true（调用者会再来一次）。原版的顺序（0x4073f0）：
## 交易 → 建房 → 升级 → 抵押 → 赎回 → 拍卖 → 为建房拆房，做过任何一件就从建房重新来。
## 现在只有建房（含拆房、合并平房）和升级；交易、抵押、赎回、拍卖是第 5 步。
static func _improve(game) -> bool:
	if _build_step(game):
		return true
	return _upgrade_step(game)


## 建房（0x4086d0）。每次重新打分：
## 1. 资金（现金 + 存款）不到 总资产 × maxInvestment ÷ 100 就不投资。
## 2. 自己每块没抵押的地都当起点，沿路往后连 1–4 块自己的地，挑分数最高的一种（_best_site）。
## 3. (6×位置分 + 2×现金分 + 存款分 + 无主比例) ÷ 10 > buildHouseExpect 才盖。
## 4. 付完造价后资金还要够 maxInvestment 那条线。
## 5. 现金够：要拆的先拆（一次拆一栋，下次再来），平房能合并就合并，否则直接盖。
##    现金不够：总分比阈值高出 10 以上，就记下还差多少（cash_need），路过银行时多取。
static func _build_step(game) -> bool:
	var p = game.players[game.current]
	var pi: int = p.index
	p.ai_memory["cash_need"] = 0
	p.ai_memory["plan_waiting"] = false
	if not _can_invest(game, pi, 0):
		return false
	var best := _best_site(game, pi)
	if best.is_empty():
		return false
	var total: int = (6 * int(best["score"]) + 2 * _money_score(game, p.cash)
			+ _money_score(game, p.deposit) + _free_pct(game)) / 10
	var expect := param(game, pi, "buildHouseExpect")
	if total <= expect:
		return false
	var cost := int(best["cost"])
	if not _can_invest(game, pi, cost):
		return false
	if p.cash < cost:
		if total - expect > 10:
			p.ai_memory["cash_need"] = cost - p.cash
			p.ai_memory["plan_waiting"] = true
		return false
	var why := ""
	match str(best["how"]):
		"remove":
			p.ai_memory["plan_waiting"] = true
			why = game.remove_house(pi, int(best["remove"]))
		"merge":
			why = game.merge(pi, str(best["kind"]), best["tiles"])
		_:
			why = game.build(pi, str(best["kind"]), best["tiles"])
	return why == ""


## 付出 cost 之后，资金（现金 + 存款）还够不够 总资产 × maxInvestment ÷ 100（0x40b6f0）
static func _can_invest(game, pi: int, cost: int) -> bool:
	var p = game.players[pi]
	var liquid: int = p.cash + p.deposit - cost
	if liquid < 0:
		return false
	return (game.total_assets(pi) - cost) * param(game, pi, "maxInvestment") / 100 <= liquid


## 最好的建房位置（0x409770 + 0x4086d0 的挑选）。返回
## {score, kind, tiles, cost, how: build / merge / remove, remove: 要先拆的房子}，没有返回 {}。
## 位置分 = 每块地 min(100, 50 × 地价系数 ÷ 建房系数) ÷ 2 之和，地越多分越高，所以总是挑最大的房子。
## 原版在网格上从每块地往两个方向延伸；这里用 Board.lot_chains（沿路、同一条街），效果相同。
static func _best_site(game, pi: int) -> Dictionary:
	var kinds := _kinds_by_lots(game)
	var no_player_from := int(game.rules["houses"]["placement"].get("no_player_on_lots_from", 99))
	var can_merge: bool = game.rules["houses"].get("merge_flats", {}).get("enabled", false)
	var standing := {}
	for q in game.alive_players():
		standing[game.board.site(q.pos)] = true
	var best := {}
	var seen := {}
	for start in game.props:
		if not _usable_lot(game, pi, start):
			continue
		for n in kinds:
			for chain in game.board.lot_chains(start, n):
				var key := str(_sorted(chain))
				if seen.has(key):
					continue
				seen[key] = true
				var plan := _plan_for(game, pi, chain, str(kinds[n]), can_merge)
				if plan.is_empty():
					continue
				if n >= no_player_from and chain.any(func(t): return standing.has(t)):
					continue
				if best.is_empty() or int(plan["score"]) > int(best["score"]):
					best = plan
	return best


## 这几块地能不能盖成 kind（可能要先拆 / 合并），能就返回计划，不能返回 {}。
## 原版：占到的地上已有的房子比新房子小才行（4 块的别墅不动），有房子就先拆掉。
## 作者的规则可以把平房直接合并，所以只有平房时用合并代替拆。
static func _plan_for(game, pi: int, chain: Array, kind: String, can_merge: bool) -> Dictionary:
	var score := 0
	var others: Array = []  ## 要拆的房子（平房以外）
	var flats := 0
	for t in chain:
		if not _usable_lot(game, pi, t):
			return {}
		var hid: int = game.house_at(t)
		if hid != 0:
			var h: Dictionary = game.houses[hid]
			if h["tiles"].size() >= chain.size():
				return {}
			for ht in h["tiles"]:
				if not chain.has(ht):
					return {}
			if str(h["kind"]) == "flat" and can_merge:
				flats += 1
			elif not others.has(hid):
				others.append(hid)
		score += _lot_value(game, t)
	var plan := {"score": score, "kind": kind, "tiles": chain, "how": "build"}
	if not others.is_empty():
		plan["how"] = "remove"
		plan["remove"] = others[0]
		plan["cost"] = game.house_cost(kind, chain)
	elif flats > 0:
		plan["how"] = "merge"
		plan["cost"] = game.merge_cost(kind, chain)
	else:
		plan["cost"] = game.house_cost(kind, chain)
	return plan


static func _usable_lot(game, pi: int, t: int) -> bool:
	return game.owner_of(t) == pi and not game.props[t]["mortgaged"] \
			and game.board.get_tile(t)["type"] == "land"


## 一块地在位置分里值多少：min(100, 50 × 地价系数 ÷ 建房系数) ÷ 2
static func _lot_value(game, t: int) -> int:
	var bpct := maxi(1, int(game.board.get_tile(t).get("build_cost_pct", 100)))
	return mini(100, 50 * int(game.props[t]["pct"]) / bpct) / 2


## 占 n 块地时盖哪种房子（能直接建的那一种）：{1: flat, 2: hotel, 3: floor, 4: villa}
static func _kinds_by_lots(game) -> Dictionary:
	var out := {}
	for lv in game.rules["houses"]["levels"]:
		if lv.get("build_directly", true) == false:
			continue
		var n := int(lv["lots"])
		if not out.has(n):
			out[n] = str(lv["id"])
	return out


## 升级（0x4094f0）：没有在等钱的建房计划、现金分 ≥ 20 时，
## 找第一栋能升级的旅社 / 小洋楼，现金够升级费就升。不看 buildHouseExpect。
static func _upgrade_step(game) -> bool:
	var p = game.players[game.current]
	if int(p.ai_memory.get("cash_need", 0)) > 0 or p.ai_memory.get("plan_waiting", false):
		return false
	if _money_score(game, p.cash) < int(_scoring("upgrade_min_cash_score", 20)):
		return false
	var ids: Array = game.houses.keys()
	ids.sort()
	for hid in ids:
		if game.houses[hid]["owner"] == p.index and game.why_cannot_upgrade(p.index, hid) == "":
			return game.upgrade(p.index, hid) == ""
	return false


# ───────────────────────── 打分 ─────────────────────────

## 地分（0x407870），站在玩家 pi 的角度给一块地打分：
## (2×回报率 + 2×连片分 + 100 × 2^((自有分 − 20) ÷ 20) + 临路分) ÷ 10
## - 回报率 = 50 × 地价系数 ÷ 建房系数
## - 连片分：四个方向，隔壁是地 +25，再隔一块也是地再 +25
## - 自有分：从 20 起，四个方向上第 1 / 2 / 3 格是自己的地 +28 / +25 / +20，最多 80；
##   隔壁不是地的方向不看；碰到已经盖成 4 块别墅的自己的地，这个方向后面也不看
## - 临路分 = 100 × 隔壁有几格路 − 100
static func _land_score(game, pi: int, tile: int) -> int:
	var geo := _geometry(game.board)
	var lot: Vector2i = geo["lot_of"].get(tile, Vector2i(tile, 0))
	var lands: Dictionary = geo["land_at"]
	var bpct := maxi(1, int(game.board.get_tile(tile).get("build_cost_pct", 100)))
	var ratio := 50 * int(game.props[tile]["pct"]) / bpct
	var road := -100
	var line := 0
	var own := 20
	for d in DIRS:
		if geo["road"].has(lot + d):
			road += 100
		if lands.has(lot + d):
			line += 25
			if lands.has(lot + d * 2):
				line += 25
		if not lands.has(lot + d):
			continue
		var bonus := [28, 25, 20]
		for k in range(3):
			var cell: Vector2i = lot + d * (k + 1)
			if not lands.has(cell):
				continue
			var t := int(lands[cell])
			if game.owner_of(t) != pi:
				continue
			var hid: int = game.house_at(t)
			if hid != 0 and hid != game.house_at(tile) and game.houses[hid]["tiles"].size() == 4:
				break
			own += bonus[k]
	own = mini(own, 80)
	var curve := int(-20.0 * pow(2.0, (own - 20) * 0.05))
	return (2 * (ratio + line) - 5 * curve + road) / 10


## 企业分（0x407cb0）：(3×(回报 + 自有) + 2×(临路 + 同行)) ÷ 10
## - 回报 = min(100, 100 × 租金 ÷ 价格)
## - 同行 = min(100, 25 × 同行业企业数（含自己）)
## - 自有 = 40 × 自己已有的同行业企业数
## - 临路 = 20 × 企业挨着几格路
static func _company_score(game, pi: int, tile: int) -> int:
	var t: Dictionary = game.board.get_tile(tile)
	var ret := mini(100, 100 * int(t.get("rent", 0)) / maxi(1, int(t.get("price", 1))))
	var industry := str(t.get("industry", ""))
	var same := 0
	var own := 0
	for i in game.props:
		var c: Dictionary = game.board.get_tile(i)
		if c["type"] != "company" or str(c.get("industry", "")) != industry:
			continue
		same += 25
		if i != tile and game.owner_of(i) == pi:
			own += 40
	same = mini(same, 100)
	var road := 20 * int(_geometry(game.board)["roads_of"].get(tile, 1))
	return (3 * (ret + own) + 2 * (road + same)) / 10


## 现金分 / 存款分（0x407ec0 / 0x4080d0）：按金额分档，0–90。
## 路面格多于 big_map_roads 的地图用 big 档，否则 small 档。
static func _money_score(game, amount: int) -> int:
	ensure_loaded()
	var big: bool = _geometry(game.board)["road_count"] > int(_scoring("big_map_roads", 80))
	var table: Array = scoring.get("money_score_big" if big else "money_score_small", [])
	var score := 0
	for step_limit in table:
		if amount < int(step_limit):
			return score
		score += 10
	return score


## 无主比例（0x408500）：没主人的地和企业占全部的百分之几
static func _free_pct(game) -> int:
	var free := 0
	for t in game.props:
		if game.owner_of(t) < 0:
			free += 1
	return 100 * free / maxi(1, game.props.size())


static func _scoring(key: String, fallback: int) -> int:
	ensure_loaded()
	return int(scoring.get(key, fallback))


## 地图的网格信息（只算一次）：
## land_at：原版网格坐标 -> 地块编号；lot_of：地块编号 -> 坐标；road：所有路面格坐标；
## roads_of：企业编号 -> 挨着几格路；road_count：路面格数。
## 没有 lot 坐标的地图（shanghai_loop 这种一圈的）：把第 i 格当成 (i, 0) 的地、(i, 1) 的路。
static func _geometry(board) -> Dictionary:
	var key: int = board.get_instance_id()
	if _geo.has(key):
		return _geo[key]
	var g := {"land_at": {}, "lot_of": {}, "road": {}, "roads_of": {}, "road_count": 0}
	var has_grid := false
	for t in board.tiles:
		if t.has("lot"):
			has_grid = true
			break
	for t in board.tiles:
		var id := int(t["id"])
		var site: int = board.site(id)
		g["roads_of"][site] = int(g["roads_of"].get(site, 0)) + 1
		g["road_count"] += 1
		if has_grid:
			if t.has("pos"):
				g["road"][Vector2i(int(t["pos"][0]), int(t["pos"][1]))] = true
		else:
			g["road"][Vector2i(id, 1)] = true
		if t["type"] != "land" or t.has("site"):
			continue
		var lot := Vector2i(id, 0)
		if has_grid and t.has("lot"):
			lot = Vector2i(int(t["lot"][0]), int(t["lot"][1]))
		g["land_at"][lot] = id
		g["lot_of"][id] = lot
	_geo[key] = g
	return g


static func _sorted(a: Array) -> Array:
	var b := a.duplicate()
	b.sort()
	return b
