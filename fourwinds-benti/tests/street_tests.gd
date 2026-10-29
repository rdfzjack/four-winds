extends "res://tests/game_tests.gd"
## 街道进度（scripts/core/streets.gd）的测试，借用 game_tests.gd 的开局和造数据的小函数。

const Streets = preload("res://scripts/core/streets.gd")


func run(p_runner: Object) -> void:
	if load_data(p_runner):
		test_street_progress()
		test_merge_flats()


## 每条街凑大房子的进度：北京路 4 块，自己 1、3 号（不连着），别人 2 号，4 号没主人
func test_street_progress() -> void:
	var game := new_game()
	var bj := tile_named(shanghai, "北京路1号")
	give(game, 0, bj)
	give(game, 1, bj + 1)
	give(game, 0, bj + 2)
	var info := {}
	for s in Streets.progress(game, 0):
		if str(s["name"]) == "北京路":
			info = s
	check(Streets.progress(game, 0).size() == 1, "只列出自己有地的街")
	check(int(info.get("total", 0)) == 4 and int(info.get("mine", 0)) == 2
			and int(info.get("others", 0)) == 1 and int(info.get("free", 0)) == 1,
			"北京路：4 块，自己 2、别人 1、没主人 1 %s" % str(info))
	check(int(info.get("run", 0)) == 1, "自己的地被别人隔开，连续只有 1 块")
	give(game, 0, bj + 3)
	var run := 0
	for s in Streets.progress(game, 0):
		run = int(s["run"])
	check(run == 2, "买下 4 号后，3、4 号连着 2 块")
	game.players[0].cash = 5000
	game.build(0, "flat", [bj + 3])
	for s in Streets.progress(game, 0):
		run = int(s["run"])
	check(run == 2, "平房也算（可以合并），3 号空地 + 4 号平房还是连着 2 块")


## 合并并排的平房：只付差价，不触发古董 / 倒塌
func test_merge_flats() -> void:
	var game := new_game(null, 4, quiet_rules())
	var bj := tile_named(shanghai, "北京路1号")
	for i in range(4):
		give(game, 0, bj + i)
	game.players[0].cash = 5000
	game.build(0, "flat", [bj])
	game.build(0, "flat", [bj + 1])
	check(game.build(0, "hotel", [bj, bj + 1]) != "", "平房上不能直接建旅社（要用合并）")
	var expected := game.house_cost("hotel", [bj, bj + 1]) - game.house_cost("flat", [bj]) \
			- game.house_cost("flat", [bj + 1])
	check(game.merge_cost("hotel", [bj, bj + 1]) == expected, "合并只付差价 %d" % expected)
	var kinds := {}
	for o in game.build_options(0, true):
		kinds[o["kind"]] = true
	check(kinds.has("hotel") and kinds.has("floor") and kinds.has("villa") and not kinds.has("flat"),
			"合并选项：旅社、小洋楼、别墅都能合（平房 + 空地也行）%s" % str(kinds.keys()))
	check(game.merge(0, "hotel", [bj + 2, bj + 3]) != "", "两块都是空地不算合并（直接建就行）")
	var cash: int = game.players[0].cash
	game.drain_events()
	check(game.merge(0, "hotel", [bj, bj + 1]) == "", "两栋并排的平房合并成旅社")
	check(game.players[0].cash == cash - expected, "付了差价")
	var hid := game.house_at(bj)
	check(hid != 0 and hid == game.house_at(bj + 1) and str(game.houses[hid]["kind"]) == "hotel"
			and game.houses.size() == 1, "两块地上现在是同一栋旅社，平房没了")
	var types: Array = []
	for ev in game.drain_events():
		types.append(str(ev["type"]))
	check(types == ["merged"], "只记一条合并事件 %s" % str(types))
	check(game.why_cannot_upgrade(0, hid) == "", "合并出来的旅社可以照常升级成旅馆")
	var g2 := new_game(null, 4, quiet_rules())
	give(g2, 0, bj)
	give(g2, 1, bj + 1)
	g2.players[0].cash = 5000
	g2.players[1].cash = 5000
	g2.build(0, "flat", [bj])
	g2.current = 1
	g2.build(1, "flat", [bj + 1])
	g2.current = 0
	check(g2.merge(0, "hotel", [bj, bj + 1]) != "", "别人的平房不能合并")
	var off: Dictionary = quiet_rules()
	off["houses"]["merge_flats"]["enabled"] = false
	var g3 := new_game(null, 4, off)
	give(g3, 0, bj)
	give(g3, 0, bj + 1)
	g3.players[0].cash = 5000
	g3.build(0, "flat", [bj])
	check(g3.build_options(0, true).is_empty() and g3.merge(0, "hotel", [bj, bj + 1]) != "",
			"rules.json 里关掉 merge_flats 就不能合并")
