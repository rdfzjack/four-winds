extends "res://tests/game_tests.gd"
## 街道进度（scripts/core/streets.gd）的测试，借用 game_tests.gd 的开局和造数据的小函数。

const Streets = preload("res://scripts/core/streets.gd")


func run(p_runner: Object) -> void:
	if load_data(p_runner):
		test_street_progress()


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
	check(int(info.get("run", 0)) == 1, "自己的地被别人隔开，连续空地只有 1 块")
	check(Streets.still_open(game, 0, bj), "还有没主人的地，这条街还有希望")
	give(game, 0, bj + 3)
	var run := 0
	for s in Streets.progress(game, 0):
		run = int(s["run"])
	check(run == 2, "买下 4 号后，3、4 号连着 2 块")
	game.props[bj + 1]["owner"] = 1
	game.players[0].cash = 5000
	game.build(0, "hotel", [bj + 2, bj + 3])
	check(not Streets.still_open(game, 0, bj), "空地用完、也没有没主人的地，这条街没希望了，可以盖平房")
