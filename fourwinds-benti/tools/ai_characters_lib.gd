extends "res://tools/ai_scenarios_lib.gd"
## 表形态角色的评测（新框架角色 AI，ai 版本 new_v2）：每个角色几个场景 + 成交价区间表。
## 场景只检查打法方向对不对（和标准 AI 比），不为场景加参数。命令行入口 tools/ai_characters.gd。
## 玩家 0 是被测的角色，其余是标准 AI（standard_v2）。

const StdAi = preload("res://scripts/core/std_ai.gd")

## 成交价区间表的出价档位（占“标准价”的 %）
const PRICE_STEPS := [50, 70, 90, 100, 120, 150, 200]
const TRIALS := 20

var me := "david"


func new_game() -> Game:
	var g := Game.new()
	var specs: Array = [{"character": me, "ai": version}]
	for c in ["david", "giorgio", "marcel", "eric"]:
		if c != me:
			specs.append({"character": c, "ai": "standard_v2"})
	g.setup(board, rules, cards_file, characters, specs, 1)
	g.start()
	g.day = 3
	g.current = 0
	return g


## 玩家 0 按标准 AI 的账，卖 tiles 给玩家 from 最少要多少钱（不算态度、不算随机）
func standard_price(g: Game, from: int, tiles: Array) -> int:
	var saved: String = g.players[0].ai
	g.players[0].ai = "standard_v2"
	Ledger.begin()
	var base := Ledger.positions(g, 0)
	var ok := func(x: int) -> bool:
		var o := {"from": from, "to": 0, "give": [], "get": tiles, "give_cash": x, "get_cash": 0}
		return StdAi.trade_parts(g, 0, o, base)[0] >= 0.0
	var top: int = g.players[from].cash
	var price := StdAi._first_true(ok, 0, top) if ok.call(top) else top
	g.players[0].ai = saved
	return price


## 同一个局面摆 TRIALS 次（每次换随机种子），玩家 0 回答出价 cash：{成交, 还价, 拒绝} 次数
func answer_counts(make: Callable, from: int, tiles: Array, cash: int) -> Dictionary:
	var out := {"成交": 0, "还价": 0, "拒绝": 0}
	for k in range(TRIALS):
		var g: Game = make.call()
		g.rng.seed = 1000 + k
		offer_to_me(g, from, tiles, cash)
		var r := answer(g, tiles)
		out["还价" if r.begins_with("还价") else r] += 1
	return out


## 成交价区间表：河南南路 1 号归玩家 0，对手 1 按标准价的各档出价来买
func price_table() -> Dictionary:
	var make := func() -> Game:
		var g := new_game()
		own(g, 0, [HENAN_S[0]])
		return g
	var price := standard_price(make.call(), 1, [HENAN_S[0]])
	var rows := {}
	for pct in PRICE_STEPS:
		rows[pct] = answer_counts(make, 1, [HENAN_S[0]], int(price * pct / 100.0))
	return {"price": price, "rows": rows}


# ───────────────────────── 每个角色的场景 ─────────────────────────

## [{id, what, expect, got, ok}]
func run_character(p_me: String) -> Array:
	me = p_me
	version = "new_v2"
	var list: Array = []
	match me:
		"david":
			list = [
				["斐1", "我领先（我 6000，对方 2000），对方出标准价的九成买普通地", "多数答应（标准 AI 不答应）", d1_grace],
				["斐2", "我领先，对方出两倍地价买让他凑齐中山路的那块", "不卖", d2_no_kingmaker],
				["斐3", "对手快破产，我去买他手里我凑街要的地", "出价不比标准 AI 低", d3_fair_to_distressed],
			]
		"giorgio":
			list = [
				["九1", "对方（比我穷）出标准价的八成，摆 20 次", "答应的次数明显多于标准 AI", g1_easy],
				["九2", "停在衡山路 1 号（很少有人停），摆 20 次", "只记录（随便买买看对局评测的买地率）", g2_casual_buy],
			]
		"marcel":
			list = [
				["孔1", "我落后，对方出高价买让他凑齐中山路的那块（标准 AI 会卖的价）", "不卖", m1_spite],
				["孔2", "同孔 1，但我不落后", "不直接拒绝（成交或还高价）", m2_normal_when_ahead],
				["孔3", "钱不多（300），停在衡山路 1 号（喜欢的街）", "买", m3_favorite],
				["孔4", "对方出标准价的一半买普通地", "直接拒绝，不还价", m4_insulted],
			]
		"eric":
			list = [
				["理1", "对方出标准价的 1.1 倍买普通地", "先还价往上要", e1_haggle],
				["理2", "我去买凑街要的地，被拒以后再提", "第二次出价更高", e2_raise],
				["理3", "刚凑齐中山路，现金刚够盖别墅，下一把可能停到对手的房子",
						"只记录（重仓盖房看对局评测的建房数、平均现金）", e3_heavy_build],
			]
	var out: Array = []
	for s in list:
		var got: Dictionary = s[3].call()
		out.append({"id": s[0], "what": s[1], "expect": s[2], "got": got["got"], "ok": got["ok"]})
	return out


## 用标准 AI 坐玩家 0 跑同一个函数（对比用）
func as_standard(fn: Callable) -> Variant:
	var saved := version
	version = "standard_v2"
	var out: Variant = fn.call()
	version = saved
	return out


func d1_grace() -> Dictionary:
	var make := func() -> Game:
		var g := new_game()
		own(g, 0, [HENAN_S[0]])
		money(g, 0, 3000, 3000)
		money(g, 1, 1000, 1000)
		return g
	var cash := int(standard_price(make.call(), 1, [HENAN_S[0]]) * 0.9)
	var mine := answer_counts(make, 1, [HENAN_S[0]], cash)
	var std: Dictionary = as_standard(func() -> Dictionary:
		return answer_counts(make, 1, [HENAN_S[0]], cash))
	return result(mine["成交"] > TRIALS / 2 and std["成交"] < mine["成交"],
			"斐斐 %s，标准 AI %s" % [str(mine), str(std)])


func d2_no_kingmaker() -> Dictionary:
	var g := new_game()
	own(g, 1, ZHONGSHAN.slice(1))
	own(g, 0, [ZHONGSHAN[0]])
	money(g, 0, 3000, 3000)
	offer_to_me(g, 1, [ZHONGSHAN[0]], g.property_price(ZHONGSHAN[0]) * 2)
	var r := answer(g, [ZHONGSHAN[0]])
	return result(r != "成交", r)


## 我有河南南路 2 块，对手 1 有第 3 块且快破产，看我开的价
func _offer_to_distressed() -> int:
	var g := new_game()
	own(g, 0, [HENAN_S[0], HENAN_S[1]])
	own(g, 1, [HENAN_S[2]])
	g.players[1].pos = HENAN_S[2]
	var worst := threaten(g, 1, 2, HENAN_S)
	money(g, 1, maxi(0, worst - 20), 0)
	g.phase = "pre_roll"
	for _i in range(5):
		AI.step(g)
		if g.phase == "pending" and str(g.pending.get("type", "")) == "trade":
			return int(g.pending["offer"]["give_cash"])
		if g.phase != "pre_roll" or g.current != 0:
			break
	return -1


func d3_fair_to_distressed() -> Dictionary:
	var mine := _offer_to_distressed()
	var std: int = as_standard(_offer_to_distressed)
	return result(mine >= 0 and mine >= std, "斐斐出 %d，标准 AI 出 %d（-1 = 没开价）" % [mine, std])


func g1_easy() -> Dictionary:
	var make := func() -> Game:
		var g := new_game()
		own(g, 0, [HENAN_S[0]])
		money(g, 1, 1000, 0)
		return g
	var cash := int(standard_price(make.call(), 1, [HENAN_S[0]]) * 0.8)
	var mine := answer_counts(make, 1, [HENAN_S[0]], cash)
	var std: Dictionary = as_standard(func() -> Dictionary:
		return answer_counts(make, 1, [HENAN_S[0]], cash))
	return result(mine["成交"] >= std["成交"] + TRIALS / 4,
			"小九 %s，标准 AI %s" % [str(mine), str(std)])


func g2_casual_buy() -> Dictionary:
	var bought := 0
	for k in range(TRIALS):
		var g := new_game()
		g.rng.seed = 2000 + k
		if offer_buy(g, HENGSHAN[0]):
			bought += 1
	return result(null, "%d / %d 次买了" % [bought, TRIALS])


## 我落后 / 不落后时，对方出 cash 买我手里让他凑齐中山路的那块。cash = 标准 AI 会卖的价
func _spite_case(behind: bool) -> Array:
	var make := func() -> Game:
		var g := new_game()
		own(g, 1, ZHONGSHAN.slice(1))
		own(g, 0, [ZHONGSHAN[0]])
		if behind:
			money(g, 0, 500, 0)
			money(g, 1, 4000, 4000)
		else:
			money(g, 0, 6000, 4000)
			money(g, 1, 8000, 0)
		return g
	var cash := _round10(int(standard_price(make.call(), 1, [ZHONGSHAN[0]]) * 1.1))
	var g: Game = make.call()
	offer_to_me(g, 1, [ZHONGSHAN[0]], mini(cash, g.players[1].cash))
	return [answer(g, [ZHONGSHAN[0]]), cash]


static func _round10(x: int) -> int:
	return (x + 9) / 10 * 10


func m1_spite() -> Dictionary:
	var r := _spite_case(true)
	return result(not str(r[0]).begins_with("成交"), "出 %d：%s" % [r[1], r[0]])


func m2_normal_when_ahead() -> Dictionary:
	var r := _spite_case(false)
	return result(not str(r[0]).begins_with("拒绝"), "出 %d：%s" % [r[1], r[0]])


func m3_favorite() -> Dictionary:
	var g := new_game()
	money(g, 0, 300, 0)
	var b := offer_buy(g, HENGSHAN[0])
	return result(b, "买" if b else "不买")


func m4_insulted() -> Dictionary:
	var g := new_game()
	own(g, 0, [HENAN_S[0]])
	var cash := int(standard_price(g, 1, [HENAN_S[0]]) * 0.5)
	offer_to_me(g, 1, [HENAN_S[0]], cash)
	var r := answer(g, [HENAN_S[0]])
	return result(r == "拒绝", "出 %d：%s" % [cash, r])


func e1_haggle() -> Dictionary:
	var g := new_game()
	own(g, 0, [HENAN_S[0]])
	var cash := int(standard_price(g, 1, [HENAN_S[0]]) * 1.1)
	offer_to_me(g, 1, [HENAN_S[0]], cash)
	var r := answer(g, [HENAN_S[0]])
	return result(r.begins_with("还价"), "出 %d：%s" % [cash, r])


## 理理有河南南路 2 块，对手 1 有第 3 块；理理提议 → 对方拒绝 → 过几天再提
func e2_raise() -> Dictionary:
	var g := new_game()
	own(g, 0, [HENAN_S[0], HENAN_S[1]])
	own(g, 1, [HENAN_S[2]])
	money(g, 1, 500, 500)
	var first := _propose_cash(g)
	if first < 0:
		return result(false, "没开价")
	g.trade_answer(false)
	g.drain_events()
	# 同一天再来一次（局面不变，只看加不加价）：把“今天提过”“隔几天再提”“被拒冷却”的记录往前拨
	var memory: Dictionary = g.players[0].ai_memory
	memory["trade_day"] = -1
	for k in memory.get("trade_asked", {}):
		memory["trade_asked"][k] = -9999
	g.current = 0
	g.phase = "pre_roll"
	g._trade_refused = {}
	g.players[0].ai_memory["trade_last"]["day"] = g.day - 100
	var second := _propose_cash(g)
	return result(second > first, "第一次 %d，第二次 %d（-1 = 没开价）" % [first, second])


func _propose_cash(g: Game) -> int:
	g.phase = "pre_roll"
	for _i in range(5):
		AI.step(g)
		if g.phase == "pending" and str(g.pending.get("type", "")) == "trade":
			return int(g.pending["offer"]["give_cash"])
		if g.phase != "pre_roll" or g.current != 0:
			break
	return -1


func _left_after_build() -> int:
	var g := new_game()
	own(g, 0, ZHONGSHAN)
	g.players[0].pos = HENAN_S[0]
	threaten(g, 0, 2, ZHONGSHAN)
	money(g, 0, g.build_price("villa", ZHONGSHAN.slice(0, 4)) + 20, 0)
	pre_roll_builds(g)
	return g.players[0].cash


func e3_heavy_build() -> Dictionary:
	var mine := _left_after_build()
	var std: int = as_standard(_left_after_build)
	return result(null, "理理剩 %d，标准 AI 剩 %d" % [mine, std])
