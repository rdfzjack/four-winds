extends "res://tests/game_tests.gd"
## 原版上海地图（tools/cit_to_map.py 转出来的 data/maps/shanghai.json）的测试：
## 普通路面、分身格（site）、路过建筑只触发一次、在这张图上随机对局。

var original: Board = null


func run(p_runner: Object) -> void:
	if not load_data(p_runner):
		return
	var errors: Array = []
	original = Board.new()
	var d := JsonUtil.load_dict("res://data/maps/shanghai.json", errors)
	errors.append_array(original.load_from(d))
	check(errors.is_empty(), "原版上海地图能读取 %s" % str(errors))
	if not errors.is_empty():
		return
	test_shape()
	test_alias_land()
	test_alias_company()
	test_bare_road()
	test_pass_building_once()
	test_fuzz_on_original()


## 走一步就到 tile 的上一格（上一格只有一个方向，不会停下来选路）
func prev_of(board: Board, tile: int) -> int:
	for t in board.tiles:
		if t["next"] == [tile]:
			return int(t["id"])
	return -1


func first_alias(board: Board, tile_type: String) -> int:
	for t in board.tiles:
		if t.has("site") and t["type"] == tile_type and prev_of(board, int(t["id"])) >= 0:
			return int(t["id"])
	return -1


func test_shape() -> void:
	var count := {}
	for t in original.tiles:
		if not t.has("site"):
			count[t["type"]] = int(count.get(t["type"], 0)) + 1
	check(original.tile_count() == 160, "原版上海 160 格路（现在 %d）" % original.tile_count())
	check(int(count.get("land", 0)) == 64 and int(count.get("company", 0)) == 16,
			"64 块地、16 家企业 %s" % str(count))
	check(original.longest_street() >= 5, "最长的街有 5 块连续的地（%d）" % original.longest_street())
	var g := new_game(original)
	check(g.props.size() == 80, "地产只算正格：64 + 16（%d）" % g.props.size())
	check(not original.get_tile(g._jail_tile).has("site"), "巡捕房是正格")


func test_alias_land() -> void:
	var a := first_alias(original, "land")
	var s := original.site(a)
	check(a >= 0 and s != a and original.lot_chains(a, 1).is_empty(), "分身格不能当房子的地 %d→%d" % [a, s])
	var g := new_game(original)
	move(g, prev_of(original, a), 1)
	check(g.player().pos == a, "棋子停在分身格上")
	check(g.phase == "pending" and g.pending["type"] == "buy_land" and int(g.pending["tile"]) == s,
			"停在分身格上买的是它代表的地 %s" % str(g.pending))
	g.buy()
	check(g.owner_of(s) == 0 and not g.props.has(a), "买下后地主记在正格上")
	var r := new_game(original)
	give(r, 1, s)
	move(r, prev_of(original, a), 1)
	var paid := false
	for e in r.events:
		if e["type"] == "rent" and int(e["tile"]) == s and int(e["owner"]) == 1:
			paid = true
	check(paid, "停在分身格上给正格的地主交租")


func test_alias_company() -> void:
	var a := first_alias(original, "company")
	var s := original.site(a)
	var g := new_game(original)
	move(g, prev_of(original, a), 1)
	check(g.phase == "pending" and g.pending["type"] == "buy_company" and int(g.pending["tile"]) == s,
			"停在企业的分身格上买的是这家企业 %s" % str(g.pending))


func test_bare_road() -> void:
	var road := tile_of_type(original, "road")
	var g := new_game(original)
	move(g, prev_of(original, road), 1)
	check(g.players[0].pos == road and g.phase == "pre_roll" and g.current == 1,
			"停在普通路面上没有效果")


## 同一家银行挨着连续两格路：一次移动只弹一次存取款
func test_pass_building_once() -> void:
	var first := -1
	for t in original.tiles:
		var i := int(t["id"])
		if t["type"] == "bank" and t["next"].size() == 1 and prev_of(original, i) >= 0:
			var nx: int = t["next"][0]
			if original.site(nx) == original.site(i) and original.next_tiles(nx).size() == 1:
				first = i
				break
	check(first >= 0, "地图上有银行挨着连续两格路")
	if first < 0:
		return
	var g := new_game(original)
	move(g, prev_of(original, first), 3)
	check(g.phase == "pending" and g.pending["type"] == "bank", "路过银行第一格要存取款")
	g.bank_done()
	check(g.pending.get("type", "") != "bank", "同一家银行的第二格不再弹")


func test_fuzz_on_original() -> void:
	var finished := 0
	for seed_value in range(1, 21):
		var g := new_game(original, 4, {}, seed_value)
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
		check(bad.is_empty(), "原版上海随机对局 %d 数据一致 %s" % [seed_value, str(bad.slice(0, 3))])
		if g.phase == "over":
			finished += 1
	print("原版上海随机对局：%d/20 局打完" % finished)
