extends RefCounted
## 原版 AI（brain.gd）的测试（由 run_tests.gd 调用）。

const JsonUtil = preload("res://scripts/core/json_util.gd")
const Board = preload("res://scripts/core/board.gd")
const Game = preload("res://scripts/core/game.gd")
const Brain = preload("res://scripts/core/brain.gd")
const AiProfiles = preload("res://scripts/core/ai_profiles.gd")
const AI = preload("res://scripts/core/ai.gd")
const EvalLib = preload("res://tools/ai_eval_lib.gd")

## 每局最多跑几天（再长的局只是重复，测试太慢）
const MAX_DAYS := 120

var runner: Object
var rules: Dictionary
var cards_file: Dictionary
var characters: Array
var shanghai := Board.new()
var loop := Board.new()


func run(p_runner: Object) -> void:
	runner = p_runner
	var errors: Array = []
	rules = JsonUtil.load_dict("res://data/rules.json", errors)
	cards_file = JsonUtil.load_dict("res://data/cards/chance.json", errors)
	characters = JsonUtil.load_dict("res://data/characters.json", errors).get("characters", [])
	var maps_dir := "res://data/maps/"
	errors.append_array(shanghai.load_from(JsonUtil.load_dict(maps_dir + "shanghai.json", errors)))
	errors.append_array(loop.load_from(JsonUtil.load_dict(maps_dir + "shanghai_loop.json", errors)))
	check(errors.is_empty(), "AI 测试需要的数据能读取 %s" % str(errors))
	AiProfiles.ensure_loaded()
	test_scores()
	test_games(shanghai, 12, "原版上海")
	test_games(loop, 6, "40 格简化图")
	test_profile_differences()
	test_interface()
	test_eval_tool()


func check(ok: bool, what: String) -> void:
	runner.check(ok, what)


func new_game(board: Board, ids: Array, seed_value: int) -> Game:
	var g := Game.new()
	var specs: Array = []
	for id in ids:
		specs.append({"character": id, "human": false})
	g.setup(board, rules, cards_file, characters, specs, seed_value)
	g.start()
	return g


func char_ids() -> Array:
	var out: Array = []
	for c in characters:
		out.append(str(c["id"]))
	return out


## 打分函数和几个被动决定，对照反汇编读出的公式手算
func test_scores() -> void:
	var ids := char_ids()
	var g := new_game(shanghai, ids, 1)
	# 上海有 160 格路，用大地图的分档
	check(Brain._money_score(g, 39) == 0 and Brain._money_score(g, 40) == 10
			and Brain._money_score(g, 2000) == 80 and Brain._money_score(g, 2500) == 90,
			"原版 AI：大地图现金分档")
	var gl := new_game(loop, ids, 1)
	check(Brain._money_score(gl, 2000) == 90 and Brain._money_score(gl, 299) == 30,
			"原版 AI：小地图现金分档")
	# 开局全部无主：想留的现金 = keepCashExpect × 150 ÷ 100
	var keep := Brain.param(g, 0, "keepCashExpect") * 150 / 100
	var expect: int = 2000 - keep
	expect -= expect % 10
	var amount := Brain.bank_amount(g, 0)
	check(amount == expect, "原版 AI：银行存取额 %d（应为 %d）" % [amount, expect])
	g.players[0].ai_memory["cash_need"] = 5000
	check(Brain.bank_amount(g, 0) == -2000, "原版 AI：想建房差钱时把存款全取出来")
	g.players[0].ai_memory.clear()
	# 保释：开局现金 + 存款 = 总资产，现金因子 0.5，谁都交
	check(Brain.wants_bail(g, 0), "原版 AI：钱多时交保释金")
	# 给玩家 0 一堆地，现金 + 存款只占总资产的 1/3–2/3：现金因子 1
	var given := 0
	for t in g.props:
		if g.board.get_tile(t)["type"] == "land" and given < 40:
			g.props[t]["owner"] = 0
			given += 1
	g.players[0].cash = 0
	g.players[0].deposit = 0
	# 现金 = 地产总值时，(现金 + 存款) ÷ (总资产 ÷ 3) = 1.5，整数除法得 1
	g.players[0].cash = g.total_assets(0)
	check(Brain._cash_factor(g, 0) == 1.0, "原版 AI：现金因子 = 1")
	var low := ""
	var high := ""
	for id in ids:
		var f := int(AiProfiles.of(id).get("bailFactor", 100))
		if f < 100:
			low = id
		elif f >= 100:
			high = id
	if low != "" and high != "":
		g.players[0].character = low
		var low_pays := Brain.wants_bail(g, 0)
		g.players[0].character = high
		check(low_pays and not Brain.wants_bail(g, 0), "原版 AI：保释系数小的角色更愿意交保释金")
	# 地分：旁边的地归自己以后，这块地的分数更高
	var g2 := new_game(shanghai, ids, 2)
	var target := -1
	var neighbor := -1
	var geo := Brain._geometry(shanghai)
	for t in g2.props:
		if shanghai.get_tile(t)["type"] != "land":
			continue
		var lot: Vector2i = geo["lot_of"][t]
		for d in Brain.DIRS:
			if geo["land_at"].has(lot + d):
				target = t
				neighbor = int(geo["land_at"][lot + d])
				break
		if target >= 0:
			break
	var before := Brain._land_score(g2, 0, target)
	g2.props[neighbor]["owner"] = 0
	var after := Brain._land_score(g2, 0, target)
	check(target >= 0 and after > before, "原版 AI：隔壁是自己的地时地分更高（%d → %d）" % [before, after])


## 全 AI 对局：不卡、数据一致；统计每个角色的买地率、建房、平均存款
func test_games(board: Board, count: int, label: String) -> void:
	var ids := char_ids()
	var total := {}
	var finished := 0
	var finish_days := 0
	var full_streets := 0
	for seed_value in range(1, count + 1):
		var n := 2 + seed_value % 3
		var who: Array = []
		for i in range(n):
			who.append(ids[(seed_value + i) % ids.size()])
		var g := new_game(board, who, seed_value)
		var r := play(g)
		check(r["bad"].is_empty(), "%s 原版 AI 对局 %d 不卡、数据一致 %s"
				% [label, seed_value, str(r["bad"].slice(0, 3))])
		if g.phase == "over":
			finished += 1
			finish_days += g.day
		full_streets += int(r["full_day30"])
		for id in r["stats"]:
			var s: Dictionary = total.get_or_add(id, {})
			for k in r["stats"][id]:
				s[k] = int(s.get(k, 0)) + int(r["stats"][id][k])
	var lines: Array = []
	var bought := 0
	var built := 0
	var big := 0
	for id in total:
		var s: Dictionary = total[id]
		bought += int(s.get("bought_land", 0))
		built += int(s.get("built", 0))
		big += int(s.get("big", 0))
		lines.append("%s 买地 %d/%d 企业 %d/%d 建房 %d（大房子 %d）升级 %d 拆 %d 平均现金 %d 存款 %d" % [
			id, s.get("bought_land", 0), s.get("offer_land", 0), s.get("bought_company", 0),
			s.get("offer_company", 0), s.get("built", 0), s.get("big", 0), s.get("upgraded", 0),
			s.get("removed", 0),
			s.get("cash", 0) / maxi(1, s.get("turns", 0)), s.get("deposit", 0) / maxi(1, s.get("turns", 0))])
	var deals := {}
	for id in total:
		for k in ["trade_proposed", "trade_done", "auction_start", "auction_sold", "mortgaged",
				"unmortgaged"]:
			deals[k] = int(deals.get(k, 0)) + int(total[id].get(k, 0))
	print("%s 原版 AI：%d/%d 局在 %d 天内打完（平均第 %d 天）；第 30 天整条街归一人的共 %d 条\n  %s\n  %s" % [
		label, finished, count, MAX_DAYS, finish_days / maxi(1, finished), full_streets,
		"交易提议 %d 成交 %d · 拍卖 %d 卖出 %d · 抵押 %d 赎回 %d" % [deals["trade_proposed"],
				deals["trade_done"], deals["auction_start"], deals["auction_sold"], deals["mortgaged"],
				deals["unmortgaged"]],
		"\n  ".join(lines)])
	check(bought > 0 and built > 0 and big > 0, "%s 原版 AI 会买地、建房、盖大房子" % label)


## 整条街（同一个 group 的地）都归同一个人的街有几条
func full_street_count(g: Game) -> int:
	var owners := {}
	for t in g.props:
		var tile: Dictionary = g.board.get_tile(t)
		if tile["type"] != "land":
			continue
		var key := str(tile.get("group", ""))
		var o := g.owner_of(t)
		if not owners.has(key):
			owners[key] = o
		elif owners[key] != o:
			owners[key] = -1
	return owners.values().filter(func(o: int) -> bool: return o >= 0).size()


## 跑一局到结束或 MAX_DAYS 天。返回 {bad: [问题], stats: {角色: {计数}}}
func play(g: Game) -> Dictionary:
	var bad: Array = []
	var stats := {}
	var steps := 0
	var full_day30 := -1  ## 第 30 天开始时整条街归一人的街数（-1 = 还没到）
	while g.phase != "over" and g.day <= MAX_DAYS and bad.is_empty():
		steps += 1
		if g.day == 30 and full_day30 < 0:
			full_day30 = full_street_count(g)
		if steps > 40000:
			bad.append("步数太多，可能死循环")
			break
		var pending_type := str(g.pending.get("type", "")) if g.phase == "pending" else ""
		var pi: int = g.current
		if not Brain.step(g):
			bad.append("AI 没有动作，卡在 %s" % g.phase)
		bad.append_array(g.check_invariants())
		var s: Dictionary = stats.get_or_add(g.players[pi].character, {})
		if pending_type == "buy_land" or pending_type == "buy_company":
			var kind := "land" if pending_type == "buy_land" else "company"
			s["offer_" + kind] = int(s.get("offer_" + kind, 0)) + 1
		for ev in g.drain_events():
			var who: String = g.players[int(ev.get("player", pi))].character
			var e: Dictionary = stats.get_or_add(who, {})
			match str(ev["type"]):
				"bought":
					var kind := "land" if g.board.get_tile(int(ev["tile"]))["type"] == "land" else "company"
					e["bought_" + kind] = int(e.get("bought_" + kind, 0)) + 1
				"built":
					e["built"] = int(e.get("built", 0)) + 1
					if str(ev["kind"]) != "flat":
						e["big"] = int(e.get("big", 0)) + 1
				"removed":
					e["removed"] = int(e.get("removed", 0)) + 1
				"upgraded":
					e["upgraded"] = int(e.get("upgraded", 0)) + 1
				"trade_proposed", "trade_done", "auction_start", "auction_sold", "auction_government", \
						"mortgaged", "unmortgaged":
					var k := str(ev["type"])
					e[k] = int(e.get(k, 0)) + 1
				"turn_start":
					var p = g.players[int(ev["player"])]
					e["turns"] = int(e.get("turns", 0)) + 1
					e["cash"] = int(e.get("cash", 0)) + p.cash
					e["deposit"] = int(e.get("deposit", 0)) + p.deposit
	return {"bad": bad, "stats": stats, "full_day30": maxi(full_day30, 0)}


## 同样的对局，只改一个参数，行为要有可测的差别
func test_profile_differences() -> void:
	var saved := AiProfiles.table.duplicate(true)
	var ids := char_ids()
	var low_buy := _run_with({"buyLandExpect": 20}, ids)
	var high_buy := _run_with({"buyLandExpect": 45}, ids)
	var rate_low := _ratio(low_buy, "bought_land", "offer_land")
	var rate_high := _ratio(high_buy, "bought_land", "offer_land")
	print("buyLandExpect 20 / 45：买地率 %.2f / %.2f" % [rate_low, rate_high])
	check(rate_low > rate_high, "原版 AI：buyLandExpect 越小越爱买地")
	var low_cash := _run_with({"keepCashExpect": 300}, ids)
	var high_cash := _run_with({"keepCashExpect": 3000}, ids)
	var c_low := _ratio(low_cash, "cash", "turns")
	var c_high := _ratio(high_cash, "cash", "turns")
	print("keepCashExpect 300 / 3000：平均现金 %d / %d" % [c_low, c_high])
	check(c_high > c_low, "原版 AI：keepCashExpect 越大手上现金越多")
	var low_build := _run_with({"buildHouseExpect": 30}, ids)
	var high_build := _run_with({"buildHouseExpect": 70}, ids)
	var b_low := int(low_build.get("built", 0))
	var b_high := int(high_build.get("built", 0))
	print("buildHouseExpect 30 / 70：建房 %d / %d" % [b_low, b_high])
	check(b_low > b_high, "原版 AI：buildHouseExpect 越小越爱建房")
	AiProfiles.table = saved


## 4 个角色都换成同一组参数（标准参数 + changes），在原版上海跑几局，返回所有人加起来的计数
func _run_with(changes: Dictionary, ids: Array) -> Dictionary:
	var base: Dictionary = AiProfiles.table[""].duplicate()
	base.merge(changes, true)
	for id in ids:
		AiProfiles.table[AiProfiles.key(id, "front")] = base
	var total := {}
	for seed_value in range(1, 7):
		var r := play(new_game(shanghai, ids, 100 + seed_value))
		for id in r["stats"]:
			for k in r["stats"][id]:
				total[k] = int(total.get(k, 0)) + int(r["stats"][id][k])
	return total


func _ratio(d: Dictionary, a: String, b: String) -> float:
	return float(d.get(a, 0)) / maxf(1.0, float(d.get(b, 0)))


## AI 接口：按角色 + 形态取参数、AI 版本、关系值
func test_interface() -> void:
	var front := AiProfiles.of("david", "front")
	var back := AiProfiles.of("david", "back")
	check(int(front.get("buyLandExpect", -1)) == int(back.get("buyLandExpect", -2))
			and not back.has("_todo"), "AI 参数：里形态没写的数沿用表形态")
	var group := {"front": {"a": 1, "b": 2}, "back": {"b": 3, "_note": "x"}}
	var merged := AiProfiles.merged(group, "back")
	check(merged == {"a": 1, "b": 3}, "AI 参数：里形态写了的数覆盖表形态")
	var g := Game.new()
	g.setup(loop, rules, cards_file, characters, [
		{"character": "david", "form": "back", "relations": {1: -30}},
		{"character": "david"},
	], 1)
	g.start()
	var p1 = g.players[1]
	check(g.players[0].form == "back" and p1.form == "front" and p1.ai == "original",
			"开局 specs 能指定形态和 AI 版本（同一角色表、里可以同局）")
	check(g.relation(0, 1) == -30 and g.relation(1, 0) == 0, "关系值是单向的，能配置初始值")
	g.change_relation(1, 0, 5)
	var ev: Array = g.drain_events().filter(
			func(e: Dictionary) -> bool: return e["type"] == "relation")
	check(g.relation(1, 0) == 5 and ev.size() == 1, "改关系值会记一条 relation 事件")
	check(AI.step(g), "AI.step 能驱动原版 AI")


## 评测工具：小规模跑通，能拒绝还没实现的 AI 版本
func test_eval_tool() -> void:
	var ev := EvalLib.new()
	ev.map_id = "shanghai_loop"
	ev.games = 2
	ev.max_days = 15
	ev.default_relation = 7
	for s in ["david", "giorgio:front", "marcel::original", "eric"]:
		ev.seats.append(EvalLib.parse_seat(s))
	var errors := ev.prepare()
	check(errors.is_empty(), "评测工具读得到数据 %s" % str(errors))
	var report := ev.run()
	var seat0: Dictionary = report["per_seat"][0]
	check(report["totals"]["games"] == 2 and report["totals"]["bad"].is_empty()
			and int(seat0.get("games", 0)) == 2 and int(seat0.get("offer_land", 0)) > 0
			and int(seat0.get("rel_pairs", 0)) == 3 * 2,
			"评测工具跑通 2 局并统计到每个座位 %s" % str(report["totals"]["bad"]))
	check(ev.format_report(report).contains("david/front/original"), "评测工具能出报告")
	var bad := EvalLib.new()
	bad.seats = [EvalLib.parse_seat("david:back:no_such_ai"), EvalLib.parse_seat("eric")]
	check(not bad.prepare().is_empty(), "评测工具拒绝还没实现的 AI 版本")
