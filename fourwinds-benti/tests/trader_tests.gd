extends RefCounted
## 新 AI 交易、拍卖出价（trader.gd）和关系值规则的测试（由 run_tests.gd 调用）。

const JsonUtil = preload("res://scripts/core/json_util.gd")
const Board = preload("res://scripts/core/board.gd")
const Game = preload("res://scripts/core/game.gd")
const Trader = preload("res://scripts/core/trader.gd")
const NewAi = preload("res://scripts/core/new_ai.gd")
const AiProfiles = preload("res://scripts/core/ai_profiles.gd")
const Valuer = preload("res://scripts/core/valuer.gd")

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
	test_personality()


## 玩家 0 是人类，1 是新 AI，2 是原版 AI（3 人局：2 人局里一方赚多少另一方就亏多少，凑街交易本来就谈不成）
func new_game() -> Game:
	var g := Game.new()
	g.setup(loop, rules, cards_file, characters, [
		{"character": "david", "human": true}, {"character": "eric", "ai": "new"},
		{"character": "marcel"},
	], 1)
	g.start()
	return g


## 一段至少 2 块、沿路连在一起的街（被隔开的同名地不算）
func street(g: Game) -> Array:
	for t in g.props:
		if g.board.get_tile(t)["type"] == "land" and Valuer.segment_of(g, t).size() >= 2:
			return Valuer.segment_of(g, t)
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


## 性格参数：喜欢的地不卖、按错同意、被拒后冷却、标准 AI 不带性格
func test_personality() -> void:
	var key := AiProfiles.key("eric", "front")
	var saved: Dictionary = AiProfiles.table[key].duplicate()
	var t: int = street(new_game())[0]
	# 喜欢的地：出多少钱都不卖
	AiProfiles.table[key]["favorite_count"] = 1
	var g := new_game()
	g.players[1].ai_memory["favorites"] = [t]
	g.props[t]["owner"] = 1
	g.propose_trade({"from": 0, "to": 1, "get": [t], "give": [], "give_cash": g.players[0].cash,
		"get_cash": 0})
	NewAi.step(g)
	runner.check(g.owner_of(t) == 1, "性格：喜欢的地出多少钱都不卖")
	AiProfiles.table[key] = saved.duplicate()
	# 按错：下线以下也有概率同意（概率 100% 时一定同意 1 块钱的交易）
	AiProfiles.table[key]["trade_accept_floor_pct"] = 100
	var g2 := new_game()
	g2.props[t]["owner"] = 1
	g2.propose_trade({"from": 0, "to": 1, "get": [t], "give": [], "give_cash": 1, "get_cash": 0})
	NewAi.step(g2)
	runner.check(g2.owner_of(t) == 0, "性格：按错时 1 块钱也卖")
	AiProfiles.table[key] = saved.duplicate()
	# 被拒后冷却：拒绝过它的人，冷却天数内不再找他
	AiProfiles.table[key]["trade_cooldown_days"] = 10
	var g3 := new_game()
	var s := street(g3)
	for i in range(s.size()):
		g3.props[s[i]]["owner"] = 0 if i == 0 else 1
	g3.current = 1
	g3.players[1].cash = 5000
	var first := Trader.propose_step(g3)
	if first:
		g3.trade_answer(false)
	g3.day += 1
	var again := Trader.propose_step(g3)
	runner.check(first and not again, "性格：被拒后冷却天数内不再找同一个人")
	AiProfiles.table[key] = saved
	# 标准 AI：不管角色，一律用 standard 参数
	var g4 := new_game()
	g4.players[1].ai = "standard"
	runner.check(Valuer.param(g4, 1, "value_horizon_days", -1)
			== float(AiProfiles.table[""]["value_horizon_days"]), "标准 AI 用 standard 参数")
