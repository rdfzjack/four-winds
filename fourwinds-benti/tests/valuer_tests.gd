extends RefCounted
## 估价模块（valuer.gd）和新 AI 选路口的测试（由 run_tests.gd 调用）。

const JsonUtil = preload("res://scripts/core/json_util.gd")
const Board = preload("res://scripts/core/board.gd")
const Game = preload("res://scripts/core/game.gd")
const Valuer = preload("res://scripts/core/valuer.gd")
const NewAi = preload("res://scripts/core/new_ai.gd")

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
	runner.check(errors.is_empty(), "估价测试需要的数据能读取 %s" % str(errors))
	test_dice_and_freq()
	test_stop_values()
	test_street_worth()
	test_direction_choice()
	test_buy_and_build()


func new_game(board: Board) -> Game:
	var g := Game.new()
	g.setup(board, rules, cards_file, characters, [
		{"character": "david", "ai": "new"}, {"character": "eric"},
	], 1)
	g.start()
	return g


func test_dice_and_freq() -> void:
	var g := new_game(loop)
	var dice := Valuer.dice_distribution(g)
	var sum := 0.0
	for d in dice:
		sum += dice[d]
	runner.check(absf(sum - 1.0) < 0.0001 and absf(dice[7] - 6.0 / 36) < 0.0001, "估价：两颗骰子的点数分布")
	for board in [loop, shanghai]:
		var gb := new_game(board)
		var freq := Valuer.visit_freq(gb)
		var total := 0.0
		var top := 0.0
		for t in freq:
			total += freq[t]
			top = maxf(top, freq[t])
		runner.check(absf(total - 1.0) < 0.001 and top < 0.2,
				"估价：%s 每格停下概率加起来是 1（最大 %.3f）" % [board.display_name, top])


## 找一块空地
func first_land(g: Game) -> int:
	for t in g.props:
		if g.board.get_tile(t)["type"] == "land":
			return t
	return -1


func test_stop_values() -> void:
	var g := new_game(loop)
	var t := first_land(g)
	runner.check(Valuer.stop_value(g, 0, t) > 0.0, "估价：停在买得起的空地上是好事")
	g.props[t]["owner"] = 1
	var rent := float(g.rent_of(t))
	runner.check(is_equal_approx(Valuer.stop_value(g, 0, t), -rent), "估价：停在别人的地上 = 付租金")
	g.props[t]["mortgaged"] = true
	runner.check(Valuer.stop_value(g, 0, t) == 0.0, "估价：抵押中的地不收租")
	g.props[t]["mortgaged"] = false
	g.players[0].cash = 0
	g.players[0].deposit = 0
	runner.check(Valuer.stop_value(g, 0, t) < -rent, "估价：付不起租金（破产）比付租金糟得多")
	g.props[t]["owner"] = 0
	runner.check(Valuer.stop_value(g, 0, t) == 0.0, "估价：停在自己的地上没有得失")
	var r := Valuer.roll_outcomes(g, 0)
	runner.check(r["worst"] <= r["expected"], "估价：掷一次的最坏得失不比期望好")


## 同一条街自己占得越多，这块地越值钱
func test_street_worth() -> void:
	var g := new_game(shanghai)
	var group := ""
	var street: Array = []
	for t in g.props:
		var tile: Dictionary = g.board.get_tile(t)
		if tile["type"] == "land" and (group == "" or str(tile.get("group", "")) == group):
			group = str(tile.get("group", ""))
			street.append(t)
	var before := Valuer.property_worth(g, 0, street[0])
	for i in range(1, street.size()):
		g.props[street[i]]["owner"] = 0
	var after := Valuer.property_worth(g, 0, street[0])
	runner.check(street.size() >= 2 and after > before,
			"估价：凑整条街时地更值钱（%.0f → %.0f）" % [before, after])


## 新 AI 在路口选不用付高租金的方向
func test_direction_choice() -> void:
	var probe := new_game(shanghai)
	var found := false
	for c in range(shanghai.tiles.size()):
		var opts: Array = shanghai.next_tiles(c)
		if opts.size() != 2 or shanghai.crossroad_mode(c) != "choice":
			continue
		var lands: Array = []
		for o in opts:
			if shanghai.is_crossroad(int(o)):
				break
			var land := int(shanghai.next_tiles(int(o))[0])
			if not probe.props.has(shanghai.site(land)) or shanghai.get_tile(land)["type"] != "land":
				break
			lands.append(land)
		if lands.size() != 2 or shanghai.site(lands[0]) == shanghai.site(lands[1]):
			continue
		found = true
		for bad in range(2):
			var g := new_game(shanghai)
			for k in range(2):
				var site: int = shanghai.site(lands[k])
				g.props[site]["owner"] = 1 if k == bad else 0
				if k == bad:
					g.props[site]["pct"] = 1000
			g.players[0].pos = c
			g.players[1].pos = g.board.start_tile
			g.forced_dice = [[1, 1]]
			g.roll()
			var asked: bool = g.phase == "pending" and g.pending["type"] == "choose_direction"
			NewAi.step(g)
			var good: int = lands[1 - bad]
			runner.check(asked and shanghai.site(g.players[0].pos) == shanghai.site(good),
					"新 AI 路口避开高租金（路口 %d，第 %d 个方向贵）" % [c, bad + 1])
		break
	runner.check(found, "原版上海图里找得到测试用的路口")


## 新 AI 买地、建房：值得且留得够钱才做
func test_buy_and_build() -> void:
	var g := new_game(shanghai)
	var t := first_land(g)
	runner.check(NewAi.wants_property(g, 0, t), "新 AI：开局钱多时买空地")
	# 对手在附近每块地都有高租金：付完钱留不够防破产的钱，就不买
	var g2 := new_game(shanghai)
	for x in g2.props:
		if x != t:
			g2.props[x]["owner"] = 1
			g2.props[x]["pct"] = 2000
	g2.players[0].cash = g2.property_price(t) + 10
	g2.players[0].deposit = 0
	runner.check(Valuer.reserve(g2, 0) > 100 and not NewAi.wants_property(g2, 0, t),
			"新 AI：买了就留不够付租金的钱时不买")
	# 全图的地都是自己的、钱很多：会建房，而且挑大房子
	var g3 := new_game(shanghai)
	for x in g3.props:
		g3.props[x]["owner"] = 0
	g3.players[0].cash = 100000
	g3.players[1].pos = g3.board.start_tile
	g3.players[0].pos = g3.board.start_tile
	var built := NewAi._build_step(g3)
	var kinds: Array = []
	for h in g3.houses.values():
		kinds.append(h["kind"])
	runner.check(built and kinds.size() == 1 and int(g3.houses.values()[0]["tiles"].size()) >= 3,
			"新 AI：钱多时先盖大房子 %s" % str(kinds))
	var g4 := new_game(shanghai)
	for x in g4.props:
		g4.props[x]["owner"] = 0
	g4.players[0].cash = 0
	g4.players[0].deposit = 0
	runner.check(not NewAi._build_step(g4) and g4.houses.is_empty(), "新 AI：没钱不建房")
