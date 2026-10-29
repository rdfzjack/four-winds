extends "res://tests/game_tests.gd"
## 第 5 步：抵押、赎回、拍卖、交易的规则测试，以及 AI 的抵押 / 赎回 / 交易 / 拍卖。
## 借用 game_tests.gd 的开局和造数据的小函数（40 格简化图）。

const Brain = preload("res://scripts/core/brain.gd")


func run(p_runner: Object) -> void:
	if not load_data(p_runner):
		return
	Brain.ensure_loaded()
	test_mortgage()
	test_unmortgage()
	test_auction()
	test_auction_government_and_broke()
	test_trade()
	test_trade_houses_and_mortgage()
	test_trade_counter_and_refuse()
	test_ai_mortgage_unmortgage()
	test_ai_auction_and_trade()


func test_mortgage() -> void:
	var g := new_game()
	var bj := tile_named(shanghai, "北京路1号")
	give(g, 0, bj)
	give(g, 0, bj + 1)
	var cash: int = g.players[0].cash
	var price := g.property_price(bj)
	g.rules = rules_with({"mortgage": {"payout_pct": 50, "unmortgage_cost_pct": 60,
			"seize_chance": 2000000000}})
	check(g.mortgage(0, bj) == "", "能抵押自己的空地")
	check(g.players[0].cash == cash + price / 2 and g.props[bj]["mortgaged"], "抵押拿到价格的 50%")
	check(g.mortgage(0, bj) != "", "已经抵押的不能再抵押")
	check(g.mortgage(1, bj + 1) != "" and g.mortgage(0, bj + 2) != "", "别人的、不是自己的地不能抵押")
	g.build(0, "flat", [bj + 1])
	check(g.mortgage(0, bj + 1) != "", "盖了房子的地不能抵押")
	var flat_cost := g.house_cost("flat", [bj + 1])
	check(g.total_assets(0) == g.players[0].cash + g.players[0].deposit + price / 2
			+ g.property_price(bj + 1) + flat_cost, "抵押的地总资产按一半算")
	# 被银行扣留：地照样抵押，钱不给
	var g2 := new_game()
	give(g2, 0, bj)
	g2.rules = rules_with({"mortgage": {"payout_pct": 50, "unmortgage_cost_pct": 60,
			"seize_chance": 1}})
	var c2: int = g2.players[0].cash
	check(g2.mortgage(0, bj) == "" and g2.props[bj]["mortgaged"] and g2.players[0].cash == c2,
			"被银行扣留时地照样抵押，拿不到钱")
	check(has_event(g2, "mortgaged") and g2.events[-1]["seized"], "扣留事件")
	# 抵押中的地不收租
	var g3 := new_game()
	give(g3, 1, bj)
	g3.props[bj]["mortgaged"] = true
	move(g3, bj - 1, 1)
	check(has_event(g3, "rent_waived"), "抵押中的地不收租")


func test_unmortgage() -> void:
	var g := new_game()
	var bj := tile_named(shanghai, "北京路1号")
	give(g, 0, bj)
	g.props[bj]["mortgaged"] = true
	var cost := g.property_price(bj) * 60 / 100
	g.players[0].cash = cost - 1
	g.players[0].deposit = 5000
	check(g.unmortgage(0, bj) != "", "赎回只能用现金")
	g.players[0].cash = cost
	check(g.unmortgage(0, bj) == "" and g.players[0].cash == 0 and not g.props[bj]["mortgaged"],
			"赎回付价格的 60%")
	check(g.unmortgage(0, bj) != "", "没抵押的不能赎回")
	g.roll()
	check(g.mortgage(0, bj) != "", "不在自己掷骰前不能抵押")


func test_auction() -> void:
	var g := new_game()
	var bj := tile_named(shanghai, "北京路1号")
	give(g, 0, bj)
	var start := g.property_price(bj) / 2
	var seller_cash: int = g.players[0].cash
	check(g.start_auction(0, bj) == "" and g.phase == "pending", "开始拍卖")
	check(g.actor() == 1 and int(g.pending["price"]) == start, "起拍价是价格的一半，下一个座位先出价")
	check(not g.auction_bid(7), "只能按档位加价")
	check(g.auction_bid(10) and g.actor() == 2, "加 10 以后轮到下一个人")
	check(g.auction_pass() and g.actor() == 3, "放弃")
	check(g.auction_bid(50) and g.actor() == 1, "加 50")
	check(g.auction_bid(1), "加 1")
	check(g.actor() == 3, "放弃的人不再轮到")
	check(g.auction_pass() and g.phase == "pre_roll", "只剩最高出价者时成交")
	var price := start + 61
	check(g.owner_of(bj) == 1 and g.players[0].cash == seller_cash + price
			and g.players[1].cash == 2000 - price, "最高价成交，钱给卖家")
	check(g.current == 0, "拍卖完还是卖家掷骰前")
	give(g, 0, bj + 1)
	g.props[bj + 1]["mortgaged"] = true
	check(g.start_auction(0, bj + 1) != "", "抵押中的地不能拍卖")


func test_auction_government_and_broke() -> void:
	var g := new_game(null, 3)
	var bj := tile_named(shanghai, "北京路1号")
	give(g, 0, bj)
	var start := g.property_price(bj) / 2
	g.players[2].cash = 0
	g.start_auction(0, bj)
	check(g.actor() == 1, "现金不够加价的人自动放弃")
	g.auction_pass()
	check(g.phase == "pre_roll" and g.owner_of(bj) == -1 and g.players[0].cash == 2000 + start,
			"没人出价：政府按起拍价收回，地变成无主")
	check(has_event(g, "auction_government"), "政府收回事件")


func test_trade() -> void:
	var g := new_game()
	var bj := tile_named(shanghai, "北京路1号")
	var hs := tile_named(shanghai, "华山路1号")
	give(g, 0, bj)
	give(g, 1, hs)
	var offer := {"from": 0, "to": 1, "give": [bj], "get": [hs], "give_cash": 100, "get_cash": 0}
	check(g.propose_trade({"from": 0, "to": 1, "give": [hs], "get": []}) != "", "不能拿别人的地去交易")
	check(g.propose_trade({"from": 0, "to": 1, "give": [], "get": [], "give_cash": 10}) != "",
			"交易里至少要有一块地产")
	check(g.propose_trade({"from": 0, "to": 1, "give": [bj], "give_cash": 999999}) != "",
			"现金不够不能交易")
	check(g.propose_trade(offer) == "" and g.phase == "pending" and g.actor() == 1, "发起交易，等对方回答")
	check(g.trade_answer(true) and g.phase == "pre_roll", "对方同意")
	check(g.owner_of(bj) == 1 and g.owner_of(hs) == 0, "地产交换")
	check(g.players[0].cash == 1900 and g.players[1].cash == 2100, "现金转手")
	check(has_event(g, "trade_done"), "成交事件")
	check(g.check_invariants().is_empty(), "交易后数据一致")


func test_trade_houses_and_mortgage() -> void:
	var g := new_game()
	var bj := tile_named(shanghai, "北京路1号")
	var hs := tile_named(shanghai, "华山路1号")
	for i in range(4):
		give(g, 0, bj + i)
	give(g, 0, hs)
	g.props[hs]["mortgaged"] = true
	g.players[0].cash = 99999
	check(g.build(0, "hotel", [bj, bj + 1]) == "", "建一栋旅社")
	var hid := g.house_at(bj)
	check(g.propose_trade({"from": 0, "to": 1, "give": [bj]}) != "", "房子占的地要一起交易")
	check(g.propose_trade({"from": 0, "to": 1, "give": [bj, bj + 1, hs], "get_cash": 100}) == "",
			"连房子、抵押的地一起交易")
	g.trade_answer(true)
	check(g.owner_of(bj) == 1 and g.houses[hid]["owner"] == 1, "房子跟着地转手")
	check(g.owner_of(hs) == 1 and g.props[hs]["mortgaged"], "抵押状态跟过去")
	check(g.check_invariants().is_empty(), "交易后数据一致")


func test_trade_counter_and_refuse() -> void:
	var g := new_game()
	var bj := tile_named(shanghai, "北京路1号")
	give(g, 1, bj)
	g.propose_trade({"from": 0, "to": 1, "get": [bj], "give_cash": 50})
	check(g.trade_counter({"from": 0, "to": 2, "get": [bj], "give_cash": 80}) != "", "还价不能换人")
	check(g.trade_counter({"from": 0, "to": 1, "get": [bj], "give_cash": 80}) == "" and g.actor() == 0,
			"还价后轮到发起人回答")
	check(g.trade_counter({"from": 0, "to": 1, "get": [bj], "give_cash": 70}) != "", "只能还价一次")
	check(g.trade_answer(false) and g.owner_of(bj) == 1, "发起人拒绝还价")
	check(g.propose_trade({"from": 0, "to": 1, "get": [bj], "give_cash": 90}) != "",
			"被拒后这回合不能再向同一人提")
	check(g.propose_trade({"from": 0, "to": 2, "get": [bj], "give_cash": 90}) != "",
			"不能向不是地主的人要地")
	check(g.propose_trade({"from": 1, "to": 2, "give": [bj]}) != "", "不是自己掷骰前不能发起交易")


## AI 抵押 / 赎回（原版公式）
func test_ai_mortgage_unmortgage() -> void:
	var g := new_game()
	g.players[0].human = false
	var bj := tile_named(shanghai, "北京路1号")
	var hs := tile_named(shanghai, "华山路1号")
	give(g, 0, hs)
	give(g, 0, hs + 1)
	g.players[0].ai_memory = {"cash_need": 50, "plan_tiles": [hs]}
	check(Brain._mortgage_step(g) and g.props[hs + 1]["mortgaged"] and not g.props[hs]["mortgaged"],
			"AI 建房差钱时抵押不在建房计划里的地")
	g.players[0].ai_memory["cash_need"] = 0
	g.players[0].cash = 5000
	check(not Brain._unmortgage_step(g), "AI 同一天抵押的不赎回")
	g.day += 1
	check(Brain._unmortgage_step(g) and not g.props[hs + 1]["mortgaged"], "AI 不差钱时赎回")
	give(g, 0, bj)
	g.players[0].ai_memory = {"cash_need": 99999}
	check(not Brain._mortgage_step(g), "AI：地价不到差额不抵押")


## AI 拍卖出价、交易（临时简单规则）
func test_ai_auction_and_trade() -> void:
	var g := new_game()
	for p in g.players:
		p.human = false
	var bj := tile_named(shanghai, "北京路1号")
	# 玩家 1 有北京路 2、3、4 号，拍卖 1 号时最想要（能凑齐整条街）
	give(g, 0, bj)
	for i in range(1, 4):
		give(g, 1, bj + i)
	g.start_auction(0, bj)
	var guard := 0
	while g.phase == "pending" and guard < 2000:
		guard += 1
		Brain.step(g)
	check(g.owner_of(bj) == 1, "AI 拍卖：能凑齐整条街的人出价最高（得主 %d）" % g.owner_of(bj))
	check(int(g.events.filter(func(e): return e["type"] == "auction_sold")[0]["price"])
			<= g.property_price(bj) * 4, "AI 出价不超过自己的估价")
	# 交易：玩家 0 有华山路 1 号，玩家 2 有 2 号；玩家 0 会提议买下 2 号
	var g2 := new_game()
	for p in g2.players:
		p.human = false
	var hs := tile_named(shanghai, "华山路1号")
	give(g2, 0, hs)
	give(g2, 2, hs + 1)
	var proposed := false
	for _k in range(30):
		g2.day += 1  # tradeCycle 是“平均几回合一次”，多试几天
		if Brain._trade_step(g2):
			proposed = true
			break
	check(proposed and g2.pending.get("type", "") == "trade", "AI 主动提议凑齐一条街")
	var offer: Dictionary = g2.pending["offer"]
	check(offer["to"] == 2 and offer["get"] == [hs + 1]
			and int(offer["give_cash"]) > g2.property_price(hs + 1),
			"AI 出价高于地价（对方让出整条街要加价）%s" % str(offer))
	Brain.step(g2)
	check(g2.owner_of(hs + 1) == 0, "对方 AI 接受公道的出价")
	check(not Brain._trade_step(g2), "AI 每回合最多提一次交易")
	# 太亏的提议：AI 还价
	var g3 := new_game()
	g3.players[1].human = false
	give(g3, 1, hs)
	g3.propose_trade({"from": 0, "to": 1, "get": [hs], "give_cash": 10})
	Brain.step(g3)
	check(g3.phase == "pending" and g3.pending["stage"] == "counter"
			and int(g3.pending["offer"]["give_cash"]) > 10, "AI 嫌出价太低就还价")
