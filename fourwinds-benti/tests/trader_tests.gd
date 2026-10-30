extends RefCounted
## 新 AI 交易、拍卖出价（trader.gd）和关系值规则的测试（由 run_tests.gd 调用）。

const JsonUtil = preload("res://scripts/core/json_util.gd")
const Board = preload("res://scripts/core/board.gd")
const Game = preload("res://scripts/core/game.gd")
const Trader = preload("res://scripts/core/trader.gd")
const NewAi = preload("res://scripts/core/new_ai.gd")

var runner: Object
var rules: Dictionary
var cards_file: Dictionary
var characters: Array
var loop := Board.new()


func run(p_runner: Object) -> void:
	runner = p_runner
	var errors: Array = []
	rules = JsonUtil.load_dict("res://data/rules.json", errors)
	cards_file = JsonUtil.load_dict("res://data/cards/chance.json", errors)
	characters = JsonUtil.load_dict("res://data/characters.json", errors).get("characters", [])
	var path := "res://data/maps/shanghai_loop.json"
	errors.append_array(loop.load_from(JsonUtil.load_dict(path, errors)))
	runner.check(errors.is_empty(), "交易测试需要的数据能读取 %s" % str(errors))
	test_answers()
	test_propose_street()
	test_auction_limit()


## 玩家 0 是人类，1 是新 AI，2 是原版 AI（3 人局：2 人局里一方赚多少另一方就亏多少，凑街交易本来就谈不成）
func new_game() -> Game:
	var g := Game.new()
	g.setup(loop, rules, cards_file, characters, [
		{"character": "david", "human": true}, {"character": "eric", "ai": "new"},
		{"character": "marcel"},
	], 1)
	g.start()
	return g


## 一条至少 2 块地的街
func street(g: Game) -> Array:
	var groups := {}
	for t in g.props:
		var tile: Dictionary = g.board.get_tile(t)
		if tile["type"] == "land":
			groups.get_or_add(str(tile.get("group", "")), []).append(t)
	for k in groups:
		if groups[k].size() >= 2:
			return groups[k]
	return []


func test_answers() -> void:
	var g := new_game()
	var t: int = street(g)[0]
	g.props[t]["owner"] = 1
	var cheap := int(g.property_price(t) * 0.8)
	g.propose_trade({"from": 0, "to": 1, "get": [t], "get_cash": 0, "give": [], "give_cash": cheap})
	NewAi.step(g)
	runner.check(g.owner_of(t) == 1, "新 AI 不肯八折把地卖给人类")
	var g2 := new_game()
	g2.props[t]["owner"] = 1
	g2.propose_trade({"from": 0, "to": 1, "get": [t], "get_cash": 0, "give": [],
		"give_cash": g2.property_price(t) * 6})
	NewAi.step(g2)
	runner.check(g2.owner_of(t) == 0, "新 AI 接受出价很高的交易")


## 新 AI 主动交易凑整条街：只差对手一块，就向他提议
func test_propose_street() -> void:
	var g := new_game()
	var s := street(g)
	for i in range(s.size()):
		g.props[s[i]]["owner"] = 0 if i == 0 else 1
	# 现在轮到玩家 0（人类）；把顺序换成新 AI 先走
	g.current = 1
	g.players[1].cash = 5000
	var proposed := Trader.propose_step(g)
	var ok: bool = proposed and g.phase == "pending" and g.pending["type"] == "trade" \
			and g.pending["offer"]["get"].has(s[0])
	runner.check(ok, "新 AI 向对手提议买下凑整条街差的地")


func test_auction_limit() -> void:
	var g := new_game()
	var s := street(g)
	for i in range(1, s.size()):
		g.props[s[i]]["owner"] = 1
	var limit := Trader.auction_limit(g, 1, s[0])
	runner.check(limit > g.property_price(s[0]) and limit <= g.players[1].cash,
			"拍卖：凑整条街差的那块，新 AI 愿意出到地价以上（%d），不超过现金" % limit)
