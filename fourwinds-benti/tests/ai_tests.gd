extends RefCounted
## 第 3 步临时 AI 的测试（由 run_tests.gd 调用）。

const JsonUtil = preload("res://scripts/core/json_util.gd")
const Board = preload("res://scripts/core/board.gd")
const Game = preload("res://scripts/core/game.gd")
const SimpleAI = preload("res://scripts/core/simple_ai.gd")

var runner: Object


func run(p_runner: Object) -> void:
	runner = p_runner
	test_simple_ai_games()


func check(ok: bool, what: String) -> void:
	runner.check(ok, what)


## 第 3 步的临时 AI：全 AI 对局能一直打下去、数据一致，并且有人会买地、建房。
func test_simple_ai_games() -> void:
	var errors: Array = []
	var rules := JsonUtil.load_dict("res://data/rules.json", errors)
	var cards_file := JsonUtil.load_dict("res://data/cards/chance.json", errors)
	var chars := JsonUtil.load_dict("res://data/characters.json", errors)
	var characters: Array = chars.get("characters", [])
	var board := Board.new()
	var map_data := JsonUtil.load_dict("res://data/maps/shanghai_loop.json", errors)
	errors.append_array(board.load_from(map_data))
	check(errors.is_empty(), "AI 测试需要的数据能读取 %s" % str(errors))
	var finished := 0
	var bought := 0
	var built := 0
	for seed_value in range(1, 13):
		var g := Game.new()
		var specs: Array = []
		for i in range(2 + seed_value % 3):
			specs.append({"character": str(characters[i]["id"]), "human": false})
		g.setup(board, rules, cards_file, characters, specs, seed_value)
		g.start()
		var bad: Array = []
		var steps := 0
		while g.phase != "over" and steps < 6000 and bad.is_empty():
			steps += 1
			if not SimpleAI.step(g):
				bad.append("AI 没有动作，卡在 %s" % g.phase)
			bad.append_array(g.check_invariants())
			for ev in g.drain_events():
				if ev["type"] == "bought":
					bought += 1
				elif ev["type"] == "built":
					built += 1
		check(bad.is_empty(), "临时 AI 对局 %d 数据一致 %s" % [seed_value, str(bad.slice(0, 3))])
		if g.phase == "over":
			finished += 1
	print("临时 AI 对局：%d/12 局打完，买地 %d 次，建房 %d 次" % [finished, bought, built])
	check(bought > 0 and built > 0, "临时 AI 会买地也会建房")
