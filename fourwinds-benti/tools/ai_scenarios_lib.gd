extends RefCounted
## AI 评测场景：在原版上海图上摆固定局面，看 AI 怎么决定，和“应该怎么做”比。
## 场景和期望是作者确认过的（docs/ai_design.md 的 H 节），这里只检查，**不要为了让场景过关去加参数**：
## 不过关说明三本账哪里算错了，改账。
## 命令行入口是 tools/ai_scenarios.gd；无头测试只跑一遍确认不崩。
##
## 局面：4 人局，玩家 0 是被测的 AI（斐斐），1–3 是对手。数字单位万圆。

const JsonUtil = preload("res://scripts/core/json_util.gd")
const Board = preload("res://scripts/core/board.gd")
const Game = preload("res://scripts/core/game.gd")
const AI = preload("res://scripts/core/ai.gd")
const AiProfiles = preload("res://scripts/core/ai_profiles.gd")
const Valuer = preload("res://scripts/core/valuer.gd")
const Ledger = preload("res://scripts/core/ledger.gd")

## 原版上海图上用到的地（地块编号）
const ZHONGSHAN := [15, 16, 17, 18, 19]  ## 中山路 5 块，凑齐能盖别墅，租金上千
const HENAN_S := [30, 31, 32]            ## 河南南路 3 块，很多人路过
const JINLING_E := [26, 27]              ## 金陵东路 2 块
const HENGSHAN := [127, 128, 129, 130, 131]  ## 衡山路 5 块，很少有人停

var board := Board.new()
var rules: Dictionary = {}
var cards_file: Dictionary = {}
var characters: Array = []
var version := "standard_v2"


func prepare() -> Array:
	var errors: Array = []
	AiProfiles.ensure_loaded()
	rules = JsonUtil.load_dict("res://data/rules.json", errors)
	cards_file = JsonUtil.load_dict("res://data/cards/chance.json", errors)
	characters = JsonUtil.load_dict("res://data/characters.json", errors).get("characters", [])
	errors.append_array(board.load_from(JsonUtil.load_dict("res://data/maps/shanghai.json", errors)))
	return errors


## 跑全部场景：[{id, what, expect, got, ok}]
func run(p_version: String) -> Array:
	version = p_version
	var out: Array = []
	for s in [
		["1", "开局钱多，停在河南南路 1 号（很多人路过）", "买", s1_buy_busy],
		["2", "开局钱多，停在衡山路 1 号（很少有人停）", "不买", s2_skip_quiet],
		["3", "现金 200、没存款，停在河南南路 1 号（地价 80），下一把可能停到对手的房子", "不买", s3_no_buy_broke],
		["4", "同 3，但存款 1000", "买", s4_buy_with_deposit],
		["5", "只剩 100、下一把可能停到对手的房子；对手出地价七成，买我一块凑不成街的地", "卖", s5_sell_to_survive],
		["6a", "同 5，但对方要的是让他凑齐中山路的那块（凑齐后租上千），我前面那些租也是他的", "卖", s6a_sell_key_to_creditor],
		["6b", "同 6a，但我前面那些租是别的对手的", "待作者定", s6b_sell_key_other_creditor],
		["7", "钱多（3000），对手出两倍地价，买让他凑齐中山路的那块", "不卖", s7_keep_key_rich],
		["8", "钱多，对手八折买河南南路 1 号", "不卖", s8_no_discount],
		["9a", "互换：我凑齐河南南路，对手凑齐金陵东路（我的街更好）", "换", s9a_swap_good],
		["9b", "互换：我凑齐衡山路，对手凑齐河南南路（他的街好得多）", "不换", s9b_swap_bad],
		["11", "刚凑齐中山路，现金刚够盖别墅，下一把可能停到对手的房子", "盖完还留得够付下一把最大的租", s11_no_overbuild],
		["12", "凑齐中山路，现金 5000", "盖别墅", s12_build_rich],
		["13", "我有河南南路 2 块，第 3 块在对手手里，我主动去买", "出价不低于地价，对方按标准账也不亏", s13_fair_offer],
	]:
		var got: Dictionary = s[3].call()
		out.append({"id": s[0], "what": s[1], "expect": s[2], "got": got["got"], "ok": got["ok"]})
	return out


# ───────────────────────── 摆局面 ─────────────────────────

func new_game() -> Game:
	var g := Game.new()
	var specs: Array = []
	for c in ["david", "eric", "marcel", "giorgio"]:
		specs.append({"character": c, "ai": version})
	g.setup(board, rules, cards_file, characters, specs, 1)
	g.start()
	g.day = 3
	g.current = 0
	return g


func own(g: Game, pi: int, tiles: Array) -> void:
	for t in tiles:
		g.props[t]["owner"] = pi


func money(g: Game, pi: int, cash: int, deposit: int) -> void:
	g.players[pi].cash = cash
	g.players[pi].deposit = deposit


## 玩家 pi 从现在的位置掷一次可能停下的地和企业（除了 keep 里的）都归对手 by：
## 地按整段给他，盖上这段能盖的最大的房子（地价系数不动）。返回这些格子里最大的租金。
func threaten(g: Game, pi: int, by: int, keep: Array) -> int:
	var stops := {}
	for d in range(2, 13):
		Ledger._stops(board, g.players[pi].pos, d, 1.0, stops)
	for s in stops:
		var t: int = board.site(s)
		if not g.props.has(t) or keep.has(t) or g.owner_of(t) >= 0:
			continue
		if board.get_tile(t)["type"] == "company":
			g.props[t]["owner"] = by
			continue
		var seg: Array = Valuer.segment_of(g, t).filter(func(x: int) -> bool:
			return not keep.has(x) and g.owner_of(x) < 0)
		for x in seg:
			g.props[x]["owner"] = by
		_house_on(g, by, seg)
	var worst := 0
	for s in stops:
		var t: int = board.site(s)
		if g.props.has(t) and g.owner_of(t) == by:
			worst = maxi(worst, g.rent_of(t))
	return worst


## 在 tiles 里沿路连着的地上，盖能盖的最大的房子（一栋）
func _house_on(g: Game, by: int, tiles: Array) -> void:
	var levels: Array = g.rules["houses"]["levels"].duplicate()
	levels.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["lots"]) > int(b["lots"]))
	for lv in levels:
		if lv.get("build_directly", true) == false or int(lv["lots"]) > tiles.size():
			continue
		for chain in board.lot_chains(int(tiles[0]), int(lv["lots"])):
			if chain.all(func(x) -> bool: return tiles.has(int(x)) and g.house_at(int(x)) == 0):
				g._place_house(by, str(lv["id"]), chain)
				return


func offer_to_me(g: Game, from: int, get: Array, cash: int) -> void:
	g.current = from
	g.phase = "pending"
	g.pending = {"type": "trade", "stage": "offer", "offer": Game.normalize_offer(
			{"from": from, "to": 0, "give": [], "get": get, "give_cash": cash, "get_cash": 0})}


## 让玩家 0 回答，返回 "成交" / "拒绝" / "还价"
func answer(g: Game, tiles: Array) -> String:
	AI.step(g)
	if g.phase == "pending" and str(g.pending.get("type", "")) == "trade":
		return "还价（要 %d）" % int(g.pending["offer"]["give_cash"])
	return "成交" if g.owner_of(tiles[0]) != 0 else "拒绝"


func swap_answer(g: Game, give_me: Array, take: Array) -> String:
	g.current = 1
	g.phase = "pending"
	g.pending = {"type": "trade", "stage": "offer", "offer": Game.normalize_offer(
			{"from": 1, "to": 0, "give": give_me, "get": take, "give_cash": 0, "get_cash": 0})}
	AI.step(g)
	if g.phase == "pending" and str(g.pending.get("type", "")) == "trade":
		return "还价（要 %d）" % int(g.pending["offer"]["give_cash"])
	return "成交" if g.owner_of(give_me[0]) == 0 else "拒绝"


func offer_buy(g: Game, tile: int) -> bool:
	g.players[0].pos = tile
	g.phase = "pending"
	g.pending = {"type": "buy_land", "tile": tile, "price": g.property_price(tile)}
	AI.step(g)
	return g.owner_of(tile) == 0


## 玩家 0 掷骰前做事，直到掷骰（最多 10 个动作）。返回他这期间盖的房子种类
func pre_roll_builds(g: Game) -> Array:
	g.phase = "pre_roll"
	var built: Array = []
	for _i in range(10):
		if g.phase != "pre_roll" or g.current != 0:
			break
		AI.step(g)
		for ev in g.drain_events():
			if ev["type"] == "built":
				built.append(str(ev["kind"]))
			if ev["type"] == "rolled":
				return built
		if g.phase == "pending" and str(g.pending.get("type", "")) == "trade":
			break
	return built


## ok = null 表示期望还没定，只记录结果
static func result(ok: Variant, got: String) -> Dictionary:
	return {"ok": ok, "got": got}


# ───────────────────────── 场景 ─────────────────────────

func s1_buy_busy() -> Dictionary:
	var b := offer_buy(new_game(), HENAN_S[0])
	return result(b, "买" if b else "不买")


func s2_skip_quiet() -> Dictionary:
	var b := offer_buy(new_game(), HENGSHAN[0])
	return result(not b, "买" if b else "不买")


func s3_no_buy_broke() -> Dictionary:
	var g := new_game()
	money(g, 0, 200, 0)
	g.players[0].pos = HENAN_S[0]
	var worst := threaten(g, 0, 2, HENAN_S)
	var b := offer_buy(g, HENAN_S[0])
	return result(not b, ("买" if b else "不买") + "（前面最大租 %d）" % worst)


func s4_buy_with_deposit() -> Dictionary:
	var g := new_game()
	money(g, 0, 200, 1000)
	g.players[0].pos = HENAN_S[0]
	var worst := threaten(g, 0, 2, HENAN_S)
	var b := offer_buy(g, HENAN_S[0])
	return result(b, ("买" if b else "不买") + "（前面最大租 %d）" % worst)


func s5_sell_to_survive() -> Dictionary:
	var g := new_game()
	own(g, 0, [HENAN_S[0]])
	own(g, 2, [HENAN_S[1]])
	own(g, 3, [HENAN_S[2]])
	money(g, 0, 100, 0)
	var worst := threaten(g, 0, 2, HENAN_S)
	offer_to_me(g, 1, [HENAN_S[0]], int(g.property_price(HENAN_S[0]) * 0.7))
	var r := answer(g, [HENAN_S[0]])
	return result(r == "成交", r + "（前面最大租 %d）" % worst)


func s6a_sell_key_to_creditor() -> Dictionary:
	return _key_to_survive(1, true)


func s6b_sell_key_other_creditor() -> Dictionary:
	return _key_to_survive(2, null)


## 快破产时对手 1 买我手里中山路的最后一块；creditor = 我前面那些租的主人。expect_sell = null 时不判对错
func _key_to_survive(creditor: int, expect_sell: Variant) -> Dictionary:
	var g := new_game()
	own(g, 1, ZHONGSHAN.slice(1))
	own(g, 0, [ZHONGSHAN[0]])
	money(g, 0, 100, 0)
	g.players[0].pos = HENAN_S[0]
	var worst := threaten(g, 0, creditor, ZHONGSHAN)
	offer_to_me(g, 1, [ZHONGSHAN[0]], int(g.property_price(ZHONGSHAN[0]) * 0.7))
	var r := answer(g, [ZHONGSHAN[0]]) + "（前面最大租 %d）" % worst
	if expect_sell == null:
		return result(null, r)
	return result(r.begins_with("成交") == expect_sell, r)


func s7_keep_key_rich() -> Dictionary:
	var g := new_game()
	own(g, 1, ZHONGSHAN.slice(1))
	own(g, 0, [ZHONGSHAN[0]])
	money(g, 0, 3000, 0)
	offer_to_me(g, 1, [ZHONGSHAN[0]], g.property_price(ZHONGSHAN[0]) * 2)
	var r := answer(g, [ZHONGSHAN[0]])
	return result(r != "成交", r)


func s8_no_discount() -> Dictionary:
	var g := new_game()
	own(g, 0, [HENAN_S[0]])
	offer_to_me(g, 1, [HENAN_S[0]], int(g.property_price(HENAN_S[0]) * 0.8))
	var r := answer(g, [HENAN_S[0]])
	return result(r != "成交", r)


func s9a_swap_good() -> Dictionary:
	var g := new_game()
	own(g, 0, [HENAN_S[0], HENAN_S[1], JINLING_E[0]])
	own(g, 1, [HENAN_S[2], JINLING_E[1]])
	var r := swap_answer(g, [HENAN_S[2]], [JINLING_E[0]])
	return result(r == "成交", r)


func s9b_swap_bad() -> Dictionary:
	var g := new_game()
	own(g, 0, HENGSHAN.slice(1) + [HENAN_S[0]])
	own(g, 1, [HENGSHAN[0], HENAN_S[1], HENAN_S[2]])
	var r := swap_answer(g, [HENGSHAN[0]], [HENAN_S[0]])
	return result(r != "成交", r)


func s11_no_overbuild() -> Dictionary:
	var g := new_game()
	own(g, 0, ZHONGSHAN)
	var villa := g.build_price("villa", ZHONGSHAN.slice(0, 4))
	money(g, 0, villa + 20, 0)
	g.players[0].pos = HENAN_S[0]
	var worst := threaten(g, 0, 2, ZHONGSHAN)
	var built := pre_roll_builds(g)
	var left := g.players[0].cash
	var text := ("盖了 %s" % str(built) if not built.is_empty() else "没盖") + "，剩 %d（前面最大租 %d）" % [left, worst]
	return result(left >= worst, text)


func s12_build_rich() -> Dictionary:
	var g := new_game()
	own(g, 0, ZHONGSHAN)
	money(g, 0, 5000, 0)
	var built := pre_roll_builds(g)
	return result(built.has("villa"), "盖了 %s" % str(built) if not built.is_empty() else "没盖")


func s13_fair_offer() -> Dictionary:
	var g := new_game()
	own(g, 0, [HENAN_S[0], HENAN_S[1]])
	own(g, 1, [HENAN_S[2]])
	g.phase = "pre_roll"
	for _i in range(5):
		AI.step(g)
		if g.phase == "pending" and str(g.pending.get("type", "")) == "trade":
			break
	if g.phase != "pending" or str(g.pending.get("type", "")) != "trade":
		return result(false, "没有提议")
	var o: Dictionary = g.pending["offer"]
	var cash := int(o["give_cash"])
	var price: int = g.property_price(HENAN_S[2])
	# 按标准 AI 的账，看对方（玩家 1）这笔交易亏不亏
	var e_change := {HENAN_S[2]: 0}
	for t in o["give"]:
		e_change[int(t)] = 1
	Ledger.begin()
	var before := Ledger.score_of(g, 1, Ledger.positions(g, 1))
	var after := Ledger.score_of(g, 1, Ledger.positions(g, 1, e_change, {0: -cash, 1: cash}))
	var fair := after - before > 0.0
	return result(cash >= price and fair, "出价 %d（地价 %d），对方按标准账%s" % [cash, price,
			"不亏" if fair else "亏 %.0f" % (before - after)])
