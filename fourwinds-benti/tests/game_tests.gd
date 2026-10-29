# gdlint: ignore=max-public-methods
extends RefCounted
## 第 2 步核心规则的测试（由 run_tests.gd 调用）。

const JsonUtil = preload("res://scripts/core/json_util.gd")
const Board = preload("res://scripts/core/board.gd")
const Game = preload("res://scripts/core/game.gd")

## 概率 1/20亿：测试里当作“不会发生”
const NEVER_ODDS := {"1": 2000000000, "2": 2000000000, "3": 2000000000, "4": 2000000000}

var runner: Object
var rules: Dictionary = {}
var cards_file: Dictionary = {}
var characters: Array = []
var shanghai: Board = null


func run(p_runner: Object) -> void:
	if not load_data(p_runner):
		return
	_run_all()


## 读测试要用的数据；别的测试文件（extends 这个文件）也用它
func load_data(p_runner: Object) -> bool:
	runner = p_runner
	var errors: Array = []
	rules = JsonUtil.load_dict("res://data/rules.json", errors)
	cards_file = JsonUtil.load_dict("res://data/cards/chance.json", errors)
	characters = JsonUtil.load_dict("res://data/characters.json", errors).get("characters", [])
	shanghai = Board.new()
	var map_data := JsonUtil.load_dict("res://data/maps/shanghai_loop.json", errors)
	errors.append_array(shanghai.load_from(map_data))
	check(errors.is_empty(), "规则测试需要的数据能读取 %s" % str(errors))
	return errors.is_empty()


func _run_all() -> void:
	test_street_lengths()
	test_setup_and_roll()
	test_buy_and_decline()
	test_rent_and_waivers()
	test_company_rent_doubles()
	test_build_rules()
	test_build_prices_and_rent()
	test_upgrade_and_remove()
	test_build_events()
	test_build_only_before_roll()
	test_bank_pass()
	test_church()
	test_tax_and_crossroad()
	test_jail_and_bail()
	test_park_and_race_and_government()
	test_state_durations()
	test_thief_believer_arsonist_robber()
	test_cards()
	test_card_draw_respects_characters()
	test_bankruptcy()
	test_payday()
	test_fuzz_games()


func check(ok: bool, what: String) -> void:
	runner.check(ok, what)


# ───────────────────────── 帮助函数 ─────────────────────────

func new_game(board: Board = null, count: int = 4, game_rules: Dictionary = {},
		seed_value: int = 7) -> Game:
	var game := Game.new()
	var specs: Array = []
	for i in range(count):
		specs.append({"character": str(characters[i]["id"]), "human": i == 0})
	var errors := game.setup(board if board != null else shanghai,
			game_rules if not game_rules.is_empty() else rules, cards_file, characters, specs, seed_value)
	check(errors.is_empty(), "开局成功 %s" % str(errors))
	game.start()
	return game


func tile_named(board: Board, tile_name: String) -> int:
	for t in board.tiles:
		if str(t.get("name", "")) == tile_name:
			return int(t["id"])
	return -1


func tile_of_type(board: Board, tile_type: String) -> int:
	for t in board.tiles:
		if t["type"] == tile_type:
			return int(t["id"])
	return -1


## 让当前玩家从 from 出发正好走 steps 步（用作弊骰子）。
func move(game: Game, from: int, steps: int) -> void:
	game.player().pos = from
	game.forced_dice.append([steps, 0])
	game.roll()


func give(game: Game, pi: int, tile: int) -> void:
	game.props[tile]["owner"] = pi


func event_types(game: Game) -> Array:
	var out: Array = []
	for e in game.events:
		out.append(e["type"])
	return out


func has_event(game: Game, type: String) -> bool:
	return event_types(game).has(type)


## 带自定义数值的规则副本
func rules_with(changes: Dictionary) -> Dictionary:
	var r: Dictionary = rules.duplicate(true)
	for k in changes:
		r[k] = changes[k]
	return r


## 自定义小棋盘：0 起点 → 1 地 → 2 税务局 → 3 路口地 → (4 地 | 5 地) → 6 巡捕房 → 7 地 → 回 0
func crossroad_board(mode: String = "choice") -> Board:
	var tiles: Array = []
	var spec := [
		["start", [1]], ["land", [2]], ["tax", [3]], ["land", [4, 5]], ["land", [6]],
		["land", [6]], ["jail", [7]], ["land", [0]],
	]
	for i in range(spec.size()):
		var t := {"id": i, "type": spec[i][0], "pos": [i, 0], "next": spec[i][1], "name": "T%d" % i}
		if spec[i][0] == "land":
			t["group"] = "g"
			t["price_pct"] = 100
			t["build_cost_pct"] = 100
		if spec[i][1].size() > 1:
			t["crossroad"] = mode
		tiles.append(t)
	var board := Board.new()
	var errors := board.load_from({
		"id": "x", "start_tile": 0, "tiles": tiles,
		"groups": {"g": {"name": "g", "color": "#fff"}}, "prices": shanghai.prices,
	})
	check(errors.is_empty(), "自定义棋盘有效 %s" % str(errors))
	return board


# ───────────────────────── 测试 ─────────────────────────

func test_street_lengths() -> void:
	check(shanghai.longest_street() >= 4, "占位地图至少有一条 4 块连续的街（现在 %d）" % shanghai.longest_street())
	var bj := tile_named(shanghai, "北京路1号")
	check(shanghai.lot_chains(bj, 4).size() == 1, "北京路 4 块连成一排")
	check(shanghai.lot_chains(tile_named(shanghai, "华山路1号"), 3).is_empty(), "华山路只有 2 块，凑不出 3 块")
	var wh := tile_named(shanghai, "万航渡路1号")
	check(shanghai.lot_chains(wh, 2).is_empty(), "万航渡路被企业隔开，1 号后面凑不出 2 块")
	var cb := crossroad_board()
	check(cb.lot_chains(3, 2).size() == 2, "路口后面两个方向各能凑一排")
	check(cb.nearest_of_type(0, "jail") == 6, "找最近的巡捕房")


func test_setup_and_roll() -> void:
	var game := new_game()
	check(game.phase == "pre_roll" and game.current == 0, "开局轮到 0 号玩家掷骰前")
	check(game.players[0].cash == 2000 and game.players[0].deposit == 2000, "开局现金存款各 2000")
	check(game.players[0].pos == shanghai.start_tile, "开局在起点")
	game.forced_dice.append([1, 2])
	var r := game.roll()
	check(r.get("steps", 0) == 3, "掷骰两颗相加：%s" % str(r))
	check(game.players[0].pos == 3, "走 3 步到 3 号格")
	# 3 号是顺昌路2号，现金够，等玩家决定
	check(game.phase == "pending" and game.pending["type"] == "buy_land", "停在空地上等玩家决定买不买")
	check(game.roll().is_empty(), "等决定时不能掷骰")
	var game2 := new_game()
	for _i in range(200):
		if game2.phase == "pre_roll":
			var rr := game2.roll()
			var s: int = rr["steps"]
			check(s >= 2 and s <= 12, "两颗骰子点数 2–12")
			break
	var counts := {}
	var game3 := new_game(null, 4, {}, 99)
	for _i in range(300):
		game3.phase = "pre_roll"
		var rr := game3.roll()
		counts[rr["steps"]] = true
		if game3.phase == "pending":
			game3.pending = {}
		game3.phase = "pre_roll"
	check(counts.size() >= 9 and not counts.has(1) and not counts.has(13), "300 次掷骰点数分布在 2–12")


func test_buy_and_decline() -> void:
	var game := new_game()
	move(game, 0, 1)  # 顺昌路1号：80 × 80 / 100 = 64
	check(game.pending.get("price", 0) == 64, "顺昌路1号 地价 64")
	check(game.buy(), "买地成功")
	check(game.owner_of(1) == 0 and game.players[0].cash == 2000 - 64, "买地花现金，地归自己")
	check(game.phase == "pre_roll" and game.current == 1, "买完轮到下一个人")
	# 存款不能用来买
	var poor := new_game()
	poor.players[0].cash = 50
	move(poor, 0, 1)
	check(poor.phase == "pre_roll" and poor.current == 1 and poor.owner_of(1) == -1, "现金不够不能买（存款不算）")
	check(has_event(poor, "cannot_afford"), "现金不够有提示事件")
	var dec := new_game()
	move(dec, 0, 1)
	check(dec.decline() and dec.owner_of(1) == -1 and dec.current == 1, "不买就让给下一个人")
	check(not dec.buy(), "没有待买的东西时 buy 无效")
	# 买企业
	var co := new_game()
	var station := tile_named(shanghai, "上海站")
	move(co, station - 1, 1)
	check(co.pending.get("type", "") == "buy_company" and co.pending["price"] == 560, "企业按地图价格 560")
	co.buy()
	check(co.owner_of(station) == 0, "买到企业")


func test_rent_and_waivers() -> void:
	# 空地租金 = 地价系数 80 × 空地租金 15 ÷ 100 = 12
	var game := new_game()
	give(game, 0, 1)
	game.current = 1
	move(game, 0, 1)
	check(game.players[1].cash == 2000 - 12 and game.players[0].cash == 2000 + 12, "付空地租金 12")
	check(game.current == 2, "付完租金轮到下一个人")

	var cases := {
		"mortgaged": 0, "jail": 0, "park": 0, "charity": 0, "free_rent": 0,
		"double_rent": 24, "half_rent": 6, "": 12,
	}
	for kind in cases:
		var g := new_game()
		give(g, 0, 1)
		if kind == "mortgaged":
			g.props[1]["mortgaged"] = true
		elif kind in ["jail", "park", "charity"]:
			g.players[0].status = {"kind": kind, "days": 2}
		elif kind != "":
			g.players[1].status = {"kind": kind, "days": 2}
		g.current = 1
		move(g, 0, 1)
		var paid: int = 2000 - g.players[1].cash
		check(paid == cases[kind], "租金情形 [%s] 应付 %d，实际 %d" % [kind, cases[kind], paid])

	var big := new_game()
	give(big, 0, 1)
	big.players[1].cash = 40
	big.players[1].deposit = 0
	big.current = 1
	move(big, 0, 1)
	var rent_event: Dictionary = {}
	for e in big.events:
		if e["type"] == "rent":
			rent_event = e
	check(rent_event.get("scale", "") == "big", "租金超过自己钱的 20% 记为 big")


func test_company_rent_doubles() -> void:
	var game := new_game()
	var station := tile_named(shanghai, "上海站")
	var pier := tile_named(shanghai, "十六铺码头")  # 同为 transport
	give(game, 0, station)
	game.current = 1
	move(game, station - 1, 1)
	check(game.players[1].cash == 2000 - 130, "一家企业收基本租金 130")
	give(game, 0, pier)
	game.current = 1
	game.players[1].cash = 2000
	move(game, station - 1, 1)
	check(game.players[1].cash == 2000 - 260, "同一老板同行业两家，租金翻倍 260")


func test_build_rules() -> void:
	var game := new_game(null, 4, quiet_rules())
	var bj := tile_named(shanghai, "北京路1号")
	for i in range(4):
		give(game, 0, bj + i)
	game.players[0].cash = 5000
	# 4 块一排：别墅
	check(game.build(0, "villa", [bj, bj + 1, bj + 2, bj + 3]) == "", "北京路 4 块可以建别墅")
	check(game.houses.size() == 1 and game.house_at(bj + 3) != 0, "建房后房子登记，占 4 块地")
	var g2 := new_game()
	g2.players[0].cash = 5000
	for i in range(3):
		give(g2, 0, bj + i)
	check(g2.build(0, "villa", [bj, bj + 1, bj + 2, bj + 3]) != "", "没有第 4 块地不能建别墅")
	check(g2.build(0, "floor", [bj, bj + 1, bj + 2]) == "", "3 块地可以建小洋楼")
	var g3 := new_game()
	g3.players[0].cash = 5000
	give(g3, 0, tile_named(shanghai, "顺昌路2号"))
	give(g3, 0, bj)
	check(g3.build(0, "hotel", [3, bj]) != "", "跨街道不能建")
	var wh := tile_named(shanghai, "万航渡路1号")
	give(g3, 0, wh)
	give(g3, 0, wh + 2)
	check(g3.build(0, "hotel", [wh, wh + 2]) != "", "不连续的地不能建（中间隔着企业）")
	check(g3.build(0, "super_hotel", [bj, bj + 1]) != "", "旅馆不能直接建，只能升级")
	give(g3, 1, bj + 1)
	check(g3.build(0, "hotel", [bj, bj + 1]) != "", "地不全是自己的不能建")
	g3.props[bj + 1]["owner"] = 0
	g3.props[bj + 1]["mortgaged"] = true
	check(g3.build(0, "hotel", [bj, bj + 1]) != "", "抵押中的地不能建")
	g3.props[bj + 1]["mortgaged"] = false
	g3.players[0].cash = 10
	check(g3.build(0, "hotel", [bj, bj + 1]) != "", "现金不够不能建")
	g3.players[0].cash = 5000
	g3.players[0].deposit = 0
	g3.players[1].pos = bj
	check(g3.build(0, "hotel", [bj, bj + 1]) == "", "2 块地的房子，有人站着也能建")
	var g4 := new_game()
	for i in range(3):
		give(g4, 0, bj + i)
	g4.players[0].cash = 5000
	g4.players[1].pos = bj + 1
	check(g4.build(0, "floor", [bj, bj + 1, bj + 2]) != "", "3 块以上的房子，地上有人站着不能建")
	g4.players[1].pos = 0
	var opts := g4.build_options(0)
	var kinds := {}
	for o in opts:
		kinds[o["kind"]] = true
	check(kinds.has("flat") and kinds.has("hotel") and kinds.has("floor") and not kinds.has("villa"),
			"build_options 列出能建的种类：%s" % str(kinds.keys()))
	# 不站在地上也能建（建房不需要走到那块地）
	check(g4.players[0].pos == 0 and g4.build(0, "flat", [bj]) == "", "建房不需要站在那块地上")


## 为了让建房结果可预测：不挖古董、不倒塌
func quiet_rules() -> Dictionary:
	var r: Dictionary = rules.duplicate(true)
	r["houses"]["antique_chance_by_lots"] = NEVER_ODDS
	r["houses"]["collapse_chance"] = 2000000000
	return r


func test_build_prices_and_rent() -> void:
	var g := new_game(null, 4, quiet_rules())
	var bj := tile_named(shanghai, "北京路1号")  # price_pct 100, build_cost_pct 100
	for i in range(4):
		give(g, 0, bj + i)
	g.players[0].cash = 5000
	check(g.house_cost("flat", [bj]) == 40, "平房造价 100% × 40 = 40")
	check(g.house_cost("hotel", [bj, bj + 1]) == 200, "旅社造价 200% × 100 = 200")
	check(g.house_cost("super_hotel", [bj, bj + 1]) == 320, "旅馆造价 200% × (100+60) = 320")
	check(g.house_cost("floor", [bj, bj + 1, bj + 2]) == 420, "小洋楼 300% × 140 = 420")
	check(g.house_cost("villa", [bj, bj + 1, bj + 2, bj + 3]) == 800, "别墅 400% × 200 = 800")
	check(g.build(0, "villa", [bj, bj + 1, bj + 2, bj + 3]) == "", "建别墅")
	check(g.players[0].cash == 5000 - 800, "建房花现金 800")
	check(g.rent_of(bj + 2) == 600, "别墅租金 400% × 150 = 600，站在占地的任意一块都一样")
	check(g.rent_of(bj) == 600, "别墅租金（另一块）")
	check(
		g.total_assets(0) == 4200 + 2000 + 4 * 80 + 800,
		"总资产 = 现金 + 存款 + 4 块地(各 80) + 房子造价 800：%d" % g.total_assets(0)
	)
	g.current = 1
	g.players[1].cash = 2000
	move(g, bj - 1, 2)
	check(g.players[1].cash == 1400, "别人走到别墅上付 600")
	# 地价系数变了，租金和地价跟着变
	g.props[bj]["pct"] = 200
	check(g.land_price(bj) == 160 and g.rent_of(bj) == 750, "地价系数 200：地价 160，别墅租金 500%% × 150 = 750")


func test_upgrade_and_remove() -> void:
	var g := new_game(null, 4, quiet_rules())
	var bj := tile_named(shanghai, "北京路1号")
	give(g, 0, bj)
	give(g, 0, bj + 1)
	g.players[0].cash = 1000
	g.build(0, "hotel", [bj, bj + 1])
	var hid: int = g.house_at(bj)
	check(hid != 0 and g.rent_of(bj) == 120, "旅社租金 200% × 60 = 120")
	check(g.upgrade(0, hid) == "", "旅社升级成旅馆")
	check(g.players[0].cash == 1000 - 200 - 120, "升级只付升级费 200% × 60 = 120")
	check(g.houses[hid]["kind"] == "super_hotel" and g.rent_of(bj) == 160, "旅馆租金 200% × 80 = 160")
	check(g.upgrade(0, hid) != "", "旅馆不能再升级")
	var before: int = g.players[0].cash
	check(g.remove_house(0, hid) == "", "拆房")
	check(
		g.players[0].cash == before + 160 and g.house_at(bj) == 0 and g.houses.is_empty(),
		"拆房退造价的一半 320 ÷ 2 = 160"
	)
	g.players[0].cash = 100
	g.build(0, "flat", [bj])
	g.players[0].cash = 1
	check(g.upgrade(0, g.house_at(bj)) != "", "平房不能升级")
	check(g.check_invariants().is_empty(), "内部数据一致 %s" % str(g.check_invariants()))


func test_build_events() -> void:
	var always_antique: Dictionary = rules.duplicate(true)
	always_antique["houses"]["antique_chance_by_lots"] = {"1": 1, "2": 1, "3": 1, "4": 1}
	var g := new_game(null, 4, always_antique)
	var bj := tile_named(shanghai, "北京路1号")
	give(g, 0, bj)
	g.players[0].cash = 1000
	g.build(0, "flat", [bj])
	check(g.players[0].cash == 1000 - 40 + 1000 and has_event(g, "antique"), "挖到古董 +1000")
	var always_collapse: Dictionary = rules.duplicate(true)
	always_collapse["houses"]["antique_chance_by_lots"] = NEVER_ODDS
	always_collapse["houses"]["collapse_chance"] = 1
	var g2 := new_game(null, 4, always_collapse)
	give(g2, 0, bj)
	g2.players[0].cash = 1000
	g2.build(0, "flat", [bj])
	check(
		g2.house_at(bj) == 0 and g2.players[0].cash == 960 and has_event(g2, "collapse"),
		"房子倒塌，造价不退"
	)
	check(g2.check_invariants().is_empty(), "倒塌后数据一致")


func test_build_only_before_roll() -> void:
	var g := new_game(null, 4, quiet_rules())
	var bj := tile_named(shanghai, "北京路1号")
	give(g, 1, bj)
	g.players[1].cash = 1000
	check(g.build(1, "flat", [bj]) != "", "没轮到你不能建房")
	g.current = 1
	check(g.build(1, "flat", [bj]) == "", "轮到你掷骰前可以建房")
	g.forced_dice.append([1, 0])
	g.roll()
	check(g.build(1, "flat", [bj + 1]) != "", "掷骰之后不能建房")


func test_bank_pass() -> void:
	var g := new_game()
	var bank := tile_of_type(shanghai, "bank")
	move(g, bank - 2, 3)  # 路过银行，停在银行后一格
	check(g.phase == "pending" and g.pending["type"] == "bank", "路过银行要等玩家操作")
	check(g.player().pos == bank, "走到银行时暂停")
	check(g.bank_deposit(300) and g.players[0].cash == 1700 and g.players[0].deposit == 2300, "存款 300")
	check(
		g.bank_withdraw(100) and g.players[0].cash == 1800 and g.players[0].deposit == 2200,
		"取款 100"
	)
	check(not g.bank_deposit(99999) and not g.bank_withdraw(99999), "超过余额的存取无效")
	check(g.bank_done(), "离开银行继续走")
	check(
		g.player().pos == bank + 1 and g.phase == "pending" and g.pending["type"] == "buy_land",
		"继续走到银行后一格"
	)
	var stop := new_game()
	move(stop, bank - 1, 1)
	check(
		stop.phase == "pending" and stop.pending["type"] == "bank" and stop.current == 0,
		"停在银行上也能存取款（作者定的规则）"
	)
	check(stop.bank_deposit(300) and stop.players[0].deposit == 2300, "停在银行存款")
	check(stop.bank_done() and stop.phase == "pre_roll" and stop.current == 1, "存完这回合结束")


func test_church() -> void:
	var g := new_game()
	var church := tile_of_type(shanghai, "church")
	move(g, church - 1, 2)  # 第 1 次路过
	check(not has_event(g, "donation") and g.players[0].church_passes == 1, "第一次路过教堂不捐")
	g.decline()
	g.current = 0
	g.phase = "pre_roll"
	g.events.clear()
	move(g, church - 1, 2)  # 第 2 次路过
	check(has_event(g, "donation") and g.players[0].cash == 2000 - 30, "第二次路过教堂捐 30")
	var s := new_game()
	move(s, church - 1, 1)
	check(s.players[0].status == {"kind": "believer", "days": 3}, "停在教堂成为信徒 3 回合")


func test_tax_and_crossroad() -> void:
	var cb := crossroad_board()
	var g := new_game(cb, 2)
	move(g, 0, 2)  # 税务局：总资产 4000 × 5% = 200
	check(g.players[0].cash == 1800, "税务局交总资产的 5%%：现金 %d" % g.players[0].cash)
	g.current = 0
	g.phase = "pre_roll"
	g.forced_dice.append([2, 0])
	g.players[0].pos = 1
	g.roll()  # 1 → 2 → 3，3 号是路口，停下
	check(
		g.player().pos == 3 and g.phase == "pending" and g.pending["type"] == "buy_land",
		"停在路口格上（是块地）"
	)
	var h := new_game(cb, 2)
	h.players[0].pos = 2
	h.forced_dice.append([3, 0])  # 2 → 3 → (选方向) → 5 → 6(监狱, 路过没效果)... 3 步
	h.roll()
	check(h.phase == "pending" and h.pending["type"] == "choose_direction", "走过路口要选方向")
	check(h.pending["options"] == [4, 5], "路口有两个方向")
	check(h.player().pos == 3 and not h.choose_direction(6), "选了不存在的方向无效")
	check(h.choose_direction(5), "选择方向")
	check(h.player().pos == 6 and h.pending["type"] == "bail", "选完继续走：2 → 3 → 5 → 6（巡捕房）")
	var k := new_game(cb, 2)
	k.players[0].pos = 2
	k.forced_dice.append([3, 0])
	k.roll()
	k.choose_direction(4)
	check(k.player().pos == 6 and k.pending["type"] == "bail", "另一个方向：2 → 3 → 4 → 6")
	check(
		k.events.filter(func(e): return e["type"] == "step" and e["tile"] == 4).size() == 1,
		"确实走了 4 号格"
	)
	# 随机路口：不停下来问，自己随机选一边
	var seen := {}
	for seed_value in range(1, 30):
		var rg := new_game(crossroad_board("random"), 2, {}, seed_value)
		rg.players[0].pos = 2
		rg.forced_dice.append([3, 0])
		rg.roll()
		check(rg.pending.get("type", "") == "bail", "随机路口不用选方向，直接走到巡捕房")
		for e in rg.events:
			if e["type"] == "random_direction":
				seen[e["tile"]] = true
	check(seen.has(4) and seen.has(5) and seen.size() == 2, "随机路口两个方向都会走到")
	check(crossroad_board("random").crossroad_mode(3) == "random", "路口类型能读出来")
	var bad_board := Board.new()
	var bad_errors := bad_board.load_from({
		"id": "b", "start_tile": 0,
		"tiles": [
			{"id": 0, "type": "start", "pos": [0, 0], "next": [1, 2], "crossroad": "arrow"},
			{"id": 1, "type": "chance", "pos": [1, 0], "next": [0]},
			{"id": 2, "type": "chance", "pos": [2, 0], "next": [0]},
		],
	})
	check(bad_errors.size() == 1, "不认识的路口类型会被发现 %s" % str(bad_errors))
	# 从路口格出发也要先选方向
	var m := new_game(cb, 2)
	m.players[0].pos = 3
	m.forced_dice.append([2, 0])
	m.roll()
	check(
		m.phase == "pending" and m.pending["type"] == "choose_direction" and m.pending["from"] == 3,
		"站在路口上掷骰，先选方向"
	)


func test_jail_and_bail() -> void:
	var jail := tile_of_type(shanghai, "jail")
	var g := new_game()
	move(g, jail - 1, 1)
	check(g.phase == "pending" and g.pending["type"] == "bail", "停在巡捕房：可以交保释金")
	var amount: int = g.pending["amount"]
	check(amount >= 50 and amount <= 150, "保释金 50–150：%d" % amount)
	g.bail(true)
	check(g.players[0].cash == 2000 - amount and g.players[0].status.is_empty(), "交了保释金不坐牢")

	var j := new_game()
	move(j, jail - 1, 1)
	j.bail(false)
	check(j.players[0].status == {"kind": "jail", "days": 3}, "不交就坐牢 3 回合")
	check(j.current == 1, "坐牢后轮到下一个人")
	# 之后 3 个回合被跳过，第 4 个回合正常
	var skips := 0
	var played_again := false
	j.events.clear()
	for _i in range(40):
		auto_turn(j)
		for e in j.events:
			if e["type"] == "skip_turn" and e["player"] == 0:
				skips += 1
			if e["type"] == "turn_start" and e["player"] == 0:
				played_again = true
		j.events.clear()
		if played_again or j.phase == "over":
			break
	check(skips == 3 and played_again, "坐牢跳过 3 个回合后恢复：跳过 %d 次" % skips)

	var poor := new_game()
	poor.players[0].cash = 40
	move(poor, jail - 1, 1)
	check(poor.players[0].status.get("kind", "") == "jail" and poor.current == 1, "现金不够保释金直接坐牢")
	check(poor.players[0].pos == jail, "坐牢的人在巡捕房里")


## 简单自动走一回合：能买就买，有保释金就交，路口选第一个方向，银行不动。
func auto_turn(game: Game) -> void:
	var guard := 0
	var start_player := game.current
	while game.phase != "over" and guard < 50:
		guard += 1
		match game.phase:
			"pre_roll":
				if game.current != start_player:
					return
				game.roll()
			"pending":
				_auto_resolve(game)
			_:
				return
	return


func _auto_resolve(game: Game) -> void:
	match str(game.pending["type"]):
		"choose_direction":
			game.choose_direction(game.pending["options"][0])
		"bank":
			game.bank_done()
		"buy_land", "buy_company":
			game.buy()
		"bail":
			game.bail(false)


func test_park_and_race_and_government() -> void:
	var g := new_game()
	move(g, tile_of_type(shanghai, "park") - 1, 1)
	check(g.players[0].status == {"kind": "park", "days": 1}, "停在公园游览 1 回合")
	var skipped := 0
	for _i in range(4):
		auto_turn(g)
	skipped = g.events.filter(func(e): return e["type"] == "skip_turn" and e["player"] == 0).size()
	check(skipped == 1, "游览跳过 1 个回合：%d" % skipped)
	var r := new_game()
	move(r, tile_of_type(shanghai, "race_course") - 1, 1)
	var prize := 0
	for e in r.events:
		if e["type"] == "race":
			prize = e["prize"]
	check([100, 60, 40].has(prize) and r.players[0].cash == 2000 + prize, "赛马场得奖金：%d" % prize)
	var gov := new_game()
	move(gov, tile_of_type(shanghai, "government") - 1, 1)
	check(["gang", "fortune_teller", "pawnshop"].has(gov.players[0].permit), "市政厅发特许证")


func test_state_durations() -> void:
	var g := new_game()
	g.players[0].status = {"kind": "double_rent", "days": 2}
	var kinds: Array = []
	for _round in range(3):
		kinds.append(g.players[0].status_kind())
		g.current = 0
		g.phase = "pre_roll"
		g._finish_turn()  # 轮到别人
		for _i in range(3):
			g._finish_turn()
	check(kinds == ["double_rent", "double_rent", ""], "2 天的状态覆盖两次回合：%s" % str(kinds))
	var s := new_game()
	s.players[0].status = {"kind": "thief", "days": -1}
	for _i in range(8):
		s._finish_turn()
	check(s.players[0].status_kind() == "thief", "小偷状态一直持续到偷成功为止")
	# 新状态覆盖旧状态
	s._set_status(s.players[0], "free_rent", 7)
	check(s.players[0].status_kind() == "free_rent", "新状态覆盖旧状态")


func test_thief_believer_arsonist_robber() -> void:
	var g := new_game()
	g.players[0].status = {"kind": "thief", "days": -1}
	g.players[1].pos = 3
	g.players[1].cash = 777
	move(g, 0, 3)
	check(g.players[1].cash == 0 and g.players[0].cash >= 2777 - 1, "小偷偷走遇到的玩家全部现金")
	check(g.players[0].status_kind() == "", "偷成功后小偷状态结束")
	var b := new_game()
	b.players[0].status = {"kind": "believer", "days": 3}
	b.players[1].pos = 2
	move(b, 0, 2)
	check(b.players[1].cash == 2500 and b.players[0].cash == 1500, "信徒路上遇到人施舍 1/4 现金 500")

	var quiet := quiet_rules()
	var a := new_game(null, 4, quiet)
	var bj := tile_named(shanghai, "北京路1号")
	give(a, 1, bj)
	give(a, 1, bj + 1)
	a.players[1].cash = 1000
	a.current = 1
	a.phase = "pre_roll"
	check(a.build(1, "hotel", [bj, bj + 1]) == "", "给纵火测试建一栋旅社")
	a.current = 0
	a.players[0].status = {"kind": "arsonist", "days": 7}
	var cash_before: int = a.players[0].cash
	move(a, bj - 1, 2)
	check(a.houses.is_empty() and a.players[0].cash == cash_before, "纵火犯烧掉房子，这次不收租")
	check(a.check_invariants().is_empty(), "纵火后数据一致")

	var r := new_game()
	var station := tile_named(shanghai, "上海站")
	give(r, 1, station)
	r.players[0].status = {"kind": "robber", "days": 7}
	move(r, station - 1, 1)
	check(r.owner_of(station) == 0 and r.players[0].cash == 2000, "抢劫犯停在别人的企业上，直接抢走")


func card_game(card_id: int, board: Board = null) -> Game:
	var g := new_game(board)
	g.forced_cards.append(card_id)
	return g


func test_cards() -> void:
	var chance := tile_of_type(shanghai, "chance")
	var g := card_game(4)
	move(g, chance - 1, 1)
	check(g.players[0].cash == 2300, "卡 4：得 300")

	g = card_game(11)
	move(g, chance - 1, 1)
	check(g.players[0].cash == 1970, "卡 11：罚款 30")

	g = card_game(5)
	move(g, chance - 1, 1)
	check(
		g.players[0].status == {"kind": "jail", "days": 5}
		and g.players[0].pos == tile_of_type(shanghai, "jail"),
		"卡 5：直接送进巡捕房 5 天"
	)

	g = card_game(7)
	move(g, chance - 1, 1)
	check(g.players[0].cash == 2150 and g.players[1].cash == 1950, "卡 7：向每人收 50")

	g = card_game(9)
	move(g, chance - 1, 1)
	check(g.players[0].cash == 1700 and g.players[3].cash == 2100, "卡 9：付每人 100")

	g = card_game(10)
	move(g, chance - 1, 1)
	check(
		g.players[0].pos == tile_of_type(shanghai, "church") and g.players[0].status_kind() == "believer",
		"卡 10：送教堂并成为信徒"
	)

	g = card_game(14)
	move(g, chance - 1, 1)
	check(g.players[0].status == {"kind": "double_rent", "days": 7}, "卡 14：加倍消费 7 回合")

	g = card_game(18)
	move(g, chance - 1, 1)
	check(g.players[0].deposit == 0, "卡 18：存款丢失")

	g = card_game(16)
	give(g, 0, tile_named(shanghai, "顺昌路1号"))
	give(g, 0, tile_named(shanghai, "南京路1号"))
	give(g, 0, tile_named(shanghai, "上海站"))
	move(g, chance - 1, 1)
	var nanjing := tile_named(shanghai, "南京路1号")
	check(
		g.owner_of(nanjing) == -1 and g.owner_of(1) == 0
		and g.owner_of(tile_named(shanghai, "上海站")) == 0,
		"卡 16：最贵的地（不含企业）被没收"
	)

	g = card_game(17)
	give(g, 0, 1)
	give(g, 0, tile_named(shanghai, "上海站"))
	g.props[1]["mortgaged"] = true
	g.props[tile_named(shanghai, "上海站")]["mortgaged"] = true
	give(g, 0, 4)
	move(g, chance - 1, 1)
	check(
		g.owner_of(1) == -1 and g.owner_of(tile_named(shanghai, "上海站")) == -1 and g.owner_of(4) == 0,
		"卡 17：抵押的地和企业被收走"
	)

	g = card_game(24)
	give(g, 0, 4)
	give(g, 1, 5)
	move(g, chance - 1, 1)
	check(g.props[4]["pct"] == 90 and g.props[5]["pct"] == 100, "卡 24：自己的地价系数 ×0.9")
	g = card_game(25)
	give(g, 0, 4)
	move(g, chance - 1, 1)
	check(g.props[4]["pct"] == 110 and g.land_price(4) == 88, "卡 25：地价系数 ×1.1")

	var quiet := quiet_rules()
	g = new_game(null, 4, quiet)
	var bj := tile_named(shanghai, "北京路1号")
	for i in range(5):
		give(g, 0, bj + i)
	g.players[0].cash = 5000
	g.build(0, "hotel", [bj, bj + 1])
	g.build(0, "flat", [bj + 3])
	g.forced_cards.append(26)
	g.events.clear()
	move(g, chance - 1, 1)
	check(
		g.houses[g.house_at(bj)]["kind"] == "super_hotel"
		and g.houses[g.house_at(bj + 3)]["kind"] == "flat",
		"卡 26：旅社升旅馆，平房不变"
	)

	g = new_game(null, 4, quiet)
	for i in range(2):
		give(g, 0, bj + i)
	g.players[0].cash = 5000
	g.build(0, "hotel", [bj, bj + 1])
	g.forced_cards.append(23)
	move(g, chance - 1, 1)
	check(g.houses.is_empty(), "卡 23：房屋被砸")

	g = card_game(1)
	move(g, chance - 1, 1)
	check(g.players[0].status == {"kind": "thief", "days": -1}, "卡 1：成为小偷（一直持续到偷成功）")

	# 重要：卡把人传送走后，回合照常结束
	g = card_game(10)
	move(g, chance - 1, 1)
	check(g.current == 1 and g.phase == "pre_roll", "抽卡后轮到下一个人")
	check(g.check_invariants().is_empty(), "抽卡后数据一致")

	# 卡里的效果都认得
	var ops_known := true
	var g2 := new_game()
	for c in cards_file["cards"]:
		for e in c["effects"]:
			if not ["money", "money_from_each", "money_to_each", "jail", "goto", "state",
					"lose_most_expensive_land", "lose_mortgaged_properties", "demolish_random_house",
					"land_value_pct", "upgrade_houses", "lose_deposit"].has(e["op"]):
				ops_known = false
		g2.forced_cards.append(int(c["id"]))
	check(ops_known, "30 张卡的效果 game.gd 都实现了")


func test_card_draw_respects_characters() -> void:
	var g := new_game()
	var seen_by_david := {}
	for _i in range(600):
		var c: Dictionary = g._pick_card(g.players[0])
		seen_by_david[int(c["id"])] = true
	check(not seen_by_david.has(20), "卡 20 四个角色都抽不到")
	check(seen_by_david.has(4) and seen_by_david.has(19), "常见卡能抽到")
	check(not seen_by_david.has(10) and not seen_by_david.has(13), "斐斐抽不到卡 10、13（allowed_for 限制）")
	var giorgio_cards := {}
	for _i in range(600):
		giorgio_cards[int(g._pick_card(g.players[1])["id"])] = true
	check(giorgio_cards.has(10) and giorgio_cards.has(13), "小九能抽到卡 10、13")
	check(not giorgio_cards.has(18), "小九抽不到卡 18")
	var low := 0
	var all := 0
	for _i in range(3000):
		var id := int(g._pick_card(g.players[0])["id"])
		all += 1
		if id == 18:
			low += 1
	check(low > 0 and low < all / 20, "卡 18 权重 30%%，比常规卡少很多（%d/%d）" % [low, all])


func test_bankruptcy() -> void:
	var g := new_game()
	var bj := tile_named(shanghai, "北京路1号")
	give(g, 0, bj)
	give(g, 0, bj + 1)
	give(g, 1, 1)
	give(g, 1, 3)
	g.players[1].cash = 100
	g.players[1].deposit = 50
	g.props[3]["mortgaged"] = true
	var hid := 7
	g.houses[hid] = {"kind": "flat", "owner": 1, "tiles": [1]}
	g.props[1]["house"] = hid
	g.players[0].cash = 10
	g.players[0].deposit = 0
	var paid := g.pay(0, 1000, 1)
	check(not paid and g.players[0].bankrupt, "付不起就破产")
	check(g.players[1].cash == 110, "剩下的钱全部给收款人")
	check(g.owner_of(bj) == 1 and g.owner_of(bj + 1) == 1, "破产者的地归债主")
	check(g.check_invariants().is_empty(), "破产后数据一致 %s" % str(g.check_invariants()))

	var h := new_game()
	give(h, 0, 1)
	h.props[1]["mortgaged"] = true
	h.houses[3] = {"kind": "flat", "owner": 0, "tiles": [3]}
	give(h, 0, 3)
	h.props[3]["house"] = 3
	h.players[0].cash = 10
	h.players[0].deposit = 0
	h.pay(0, 500, -1)
	check(h.owner_of(1) == -1 and not h.props[1]["mortgaged"], "被政府逼破产：地变无主并清除抵押")
	check(h.houses.is_empty() and h.owner_of(3) == -1, "破产者的房子全拆掉")

	# 付钱顺序：先现金后存款
	var p := new_game()
	p.players[0].cash = 100
	p.players[0].deposit = 500
	check(p.pay(0, 300, 1), "现金不够用存款补")
	check(
		p.players[0].cash == 0 and p.players[0].deposit == 300 and p.players[1].cash == 2300,
		"先扣现金再扣存款"
	)

	# 两人局：对手破产后获胜
	var two := new_game(null, 2)
	two.pay(1, 99999, 0)
	check(two.phase == "over" and two.winner == 0, "只剩一人时他获胜")
	# 人类全部破产游戏结束
	var h2 := new_game(null, 3)
	h2.pay(0, 99999, -1)
	check(h2.phase == "over" and h2.winner == -1, "人类全部破产时游戏结束")

	# 破产的人不再轮到，且在路上不会被遇到
	var skip := new_game()
	skip.players[1].bankrupt = true
	skip.players[2].pos = 0
	skip.forced_dice.append([1, 0])
	skip.roll()
	skip.decline()
	check(skip.current == 2, "跳过破产的玩家")

	# 房租让人破产：回合正常结束
	var rent_game := new_game()
	give(rent_game, 0, 1)
	rent_game.players[1].cash = 5
	rent_game.players[1].deposit = 0
	rent_game.current = 1
	move(rent_game, 0, 1)
	check(
		rent_game.players[1].bankrupt and rent_game.current == 2 and rent_game.players[0].cash == 2005,
		"付租付不起：破产，钱全给地主"
	)


func test_payday() -> void:
	var g := new_game()
	var start_cash: int = g.players[0].cash
	for i in range(4 * 7):
		auto_turn(g)
		if g.phase == "over":
			break
	check(g.day >= 7, "过了 7 天以上")
	check(g.events.filter(func(e): return e["type"] == "payday").size() >= 4, "第 7 天开始派息")
	var d := new_game()
	d.day = 6
	d.players[0].deposit = 1000
	d.players[0].cash = 0
	d.current = 3
	d._finish_turn()  # 回到 0 号，新的一天 → 第 7 天
	check(d.day == 7 and d.players[0].cash == 100, "存款 1000 × 10%% = 100 加进现金：%d" % d.players[0].cash)


## 随机玩很多局，检查不会出错、数据始终一致。
func test_fuzz_games() -> void:
	var finished := 0
	var total_houses := 0
	for seed_value in range(1, 41):
		var count := 2 + seed_value % 3
		var g := new_game(null, count, {}, seed_value)
		var bad: Array = []
		var turns := 0
		while g.phase != "over" and turns < 3000 and bad.is_empty():
			turns += 1
			if g.phase == "pre_roll":
				_fuzz_build(g)
				g.roll()
			elif g.phase == "pending":
				_fuzz_resolve(g)
			else:
				bad.append("卡在 %s" % g.phase)
			bad.append_array(g.check_invariants())
			g.events.clear()
		total_houses += g.houses.size()
		check(bad.is_empty(), "随机对局 %d 数据一致 %s" % [seed_value, str(bad.slice(0, 3))])
		if g.phase == "over":
			finished += 1
	print("随机对局：%d/40 局打完" % finished)
	check(finished >= 5, "随机对局不少能打完（%d/40）" % finished)
	check(total_houses > 0, "随机对局里确实盖了房子")


func _fuzz_build(g: Game) -> void:
	var pi := g.current
	for _i in range(3):
		var options := g.build_options(pi)
		if options.is_empty() or g.rng.randi() % 3 == 0:
			break
		var o: Dictionary = options[g.rng.randi() % options.size()]
		g.build(pi, o["kind"], o["tiles"])
	for hid in g.houses.keys():
		if g.houses.has(hid) and g.houses[hid]["owner"] == pi and g.rng.randi() % 4 == 0:
			g.upgrade(pi, hid)
	if g.rng.randi() % 8 == 0:
		for hid in g.houses.keys():
			if g.houses[hid]["owner"] == pi:
				g.remove_house(pi, hid)
				break


func _fuzz_resolve(g: Game) -> void:
	match str(g.pending["type"]):
		"choose_direction":
			var opts: Array = g.pending["options"]
			g.choose_direction(opts[g.rng.randi() % opts.size()])
		"bank":
			if g.rng.randi() % 2 == 0:
				g.bank_deposit(g.player().cash / 2)
			else:
				g.bank_withdraw(g.player().deposit / 2)
			g.bank_done()
		"buy_land", "buy_company":
			if g.rng.randi() % 4 != 0:
				g.buy()
			else:
				g.decline()
		"bail":
			g.bail(g.rng.randi() % 2 == 0)
