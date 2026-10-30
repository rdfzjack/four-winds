extends "res://tests/game_tests.gd"
## 街道进度（scripts/core/streets.gd）的测试，借用 game_tests.gd 的开局和造数据的小函数。

const Streets = preload("res://scripts/core/streets.gd")


func run(p_runner: Object) -> void:
	if load_data(p_runner):
		test_street_progress()
		test_rebuild()


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


## 改建（作者的规则）：在自己的小房子上直接建更大的房子，只付差价，不触发古董 / 倒塌。
## 用的是一圈的简化图（shanghai_loop），北京路 4 块连着。
func test_rebuild() -> void:
	var game := new_game(null, 4, quiet_rules())
	var bj := tile_named(shanghai, "北京路1号")
	var street := [bj, bj + 1, bj + 2, bj + 3]
	for t in street:
		give(game, 0, t)
	game.players[0].pos = shanghai.start_tile
	game.players[0].cash = 9000
	check(game.build(0, "flat", [bj + 1]) == "", "建平房")
	check(game.build(0, "hotel", [bj, bj + 1]) == "", "空地 + 平房直接建成旅社")
	var hid := game.house_at(bj)
	check(hid != 0 and game.house_at(bj + 1) == hid and str(game.houses[hid]["kind"]) == "hotel"
			and game.houses.size() == 1, "两块地上是同一栋旅社，平房没了 %s" % str(game.houses))
	check(game.build(0, "flat", [bj + 2]) == "", "旁边再建一栋平房")
	var expected := game.house_cost("villa", street) - game.house_cost("hotel", [bj, bj + 1]) \
			- game.house_cost("flat", [bj + 2])
	check(game.build_price("villa", street) == expected, "旅社 + 平房 + 空地改建别墅只付差价 %d" % expected)
	var cash: int = game.players[0].cash
	game.drain_events()
	check(game.build(0, "villa", street) == "", "旅社 + 平房 + 空地改建成别墅")
	check(game.players[0].cash == cash - expected, "付了差价")
	var types: Array = []
	for ev in game.drain_events():
		types.append(str(ev["type"]))
	check(types == ["built"], "改建只记一条事件，不触发古董 / 倒塌 %s" % str(types))
	hid = game.house_at(bj)
	check(game.houses.size() == 1 and str(game.houses[hid]["kind"]) == "villa"
			and game.houses[hid]["tiles"] == street, "4 块地上是同一栋别墅")
	check(game.build_choices(0).is_empty(), "别墅不能再改建，也没有别的候选")
	# 拆掉以后能马上重建；钱不够时候选照样列出，写明原因
	check(game.remove_house(0, hid) == "" and game.houses.is_empty(), "拆掉别墅")
	check(game.build(0, "villa", street) == "", "拆完能重建")
	game.remove_house(0, game.house_at(bj))
	game.players[0].cash = 0
	var choices := game.build_choices(0)
	check(choices.size() == 10 and choices.all(func(o): return o["why"] == "现金不够"),
			"没钱时 10 个候选（4 平房 3 旅社 2 小洋楼 1 别墅）都列出来，原因是现金不够 %d" % choices.size())
	check(game.build_options(0).is_empty(), "但没有能建的")
	# 升级过的旅馆也能改建，抵扣含升级费
	game.players[0].cash = 9000
	game.build(0, "hotel", [bj, bj + 1])
	game.upgrade(0, game.house_at(bj))
	var credit := game.house_cost("super_hotel", [bj, bj + 1])
	check(credit > game.house_cost("hotel", [bj, bj + 1])
			and game.build_price("floor", [bj, bj + 1, bj + 2]) == \
			game.house_cost("floor", [bj, bj + 1, bj + 2]) - credit, "旅馆改建小洋楼，抵扣含升级费")
	check(game.why_cannot_build(0, "floor", [bj + 1, bj + 2, bj + 3]) != "", "旧房子没整栋包在里面不行")
	check(game.why_cannot_build(0, "hotel", [bj, bj + 1]) != "", "一样大的不能改建")
	game.players[1].pos = bj + 2
	check(game.why_cannot_build(0, "floor", [bj, bj + 1, bj + 2]).contains("站在"),
			"有人站在要建 3 块以上房子的地上")
	var g2 := new_game(null, 4, quiet_rules())
	give(g2, 0, bj)
	give(g2, 1, bj + 1)
	g2.players[1].cash = 5000
	g2.current = 1
	g2.build(1, "flat", [bj + 1])
	g2.current = 0
	g2.players[0].cash = 5000
	check(g2.build(0, "hotel", [bj, bj + 1]) != "", "别人的平房不能改建")
	var off: Dictionary = quiet_rules()
	off["houses"]["rebuild"]["enabled"] = false
	var g3 := new_game(null, 4, off)
	give(g3, 0, bj)
	give(g3, 0, bj + 1)
	g3.players[0].cash = 5000
	g3.build(0, "flat", [bj])
	check(g3.build(0, "hotel", [bj, bj + 1]) != "", "rules.json 里关掉 rebuild 就要先拆")
