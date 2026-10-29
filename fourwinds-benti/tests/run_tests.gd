extends SceneTree
## 自动测试（不开窗口）。在项目文件夹里运行：
##   godot --headless --script res://tests/run_tests.gd
## 全部通过时退出码为 0，有失败时为 1。

const JsonUtil = preload("res://scripts/core/json_util.gd")
const Board = preload("res://scripts/core/board.gd")
const DataCheck = preload("res://scripts/core/data_check.gd")

var failures := 0
var checks := 0


func _init() -> void:
	test_data_files_load()
	test_maps_valid()
	test_walk_on_loop()
	test_walk_with_crossroad()
	test_broken_map_is_reported()
	test_characters_ai_lines_match()
	test_cards_valid()
	test_broken_cards_reported()
	test_default_map()
	print("测试完成：%d 项检查，%d 项失败" % [checks, failures])
	quit(1 if failures > 0 else 0)


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("失败：" + what)


func test_data_files_load() -> void:
	var errors: Array = []
	var rules := JsonUtil.load_dict("res://data/rules.json", errors)
	var chars := JsonUtil.load_dict("res://data/characters.json", errors)
	check(errors.is_empty(), "数据文件能读取 %s" % str(errors))
	check(int(rules.get("starting_cash", 0)) > 0, "rules.json 有开局现金")
	var list: Array = chars.get("characters", [])
	check(list.size() == 4, "正好 4 个角色")
	for c in list:
		check(str(c.get("id", "")) != "" and str(c.get("name", "")) != "", "角色有 id 和名字")


func test_maps_valid() -> void:
	var files := DirAccess.get_files_at("res://data/maps")
	check(files.size() > 0, "至少有一张地图")
	for f in files:
		if not f.ends_with(".json"):
			continue
		var errors: Array = []
		var d := JsonUtil.load_dict("res://data/maps/" + f, errors)
		var board := Board.new()
		errors.append_array(board.load_from(d))
		check(errors.is_empty(), "%s 校验通过 %s" % [f, str(errors)])


func _make_board(next_lists: Array) -> Board:
	var tiles: Array = []
	for i in range(next_lists.size()):
		var tile_type := "start" if i == 0 else "chance"
		tiles.append({"id": i, "type": tile_type, "pos": [i, 0], "next": next_lists[i]})
	var board := Board.new()
	var errors := board.load_from({"id": "t", "start_tile": 0, "tiles": tiles})
	check(errors.is_empty(), "测试棋盘有效 %s" % str(errors))
	return board


func test_walk_on_loop() -> void:
	var board := _make_board([[1], [2], [3], [0]])
	check(board.walk(0, 3) == [1, 2, 3], "环线走 3 步")
	check(board.walk(2, 3) == [3, 0, 1], "环线绕过起点")
	check(not board.is_crossroad(1), "环线没有路口")


func test_walk_with_crossroad() -> void:
	# 0 → 1 → 路口 2 → (3 或 4) → 5 → 0
	var board := _make_board([[1], [2], [3, 4], [5], [5], [0]])
	check(board.is_crossroad(2), "2 号格是路口")
	check(board.walk(0, 4) == [1, 2, 3, 5], "路口默认走第一个方向")
	check(board.walk(0, 4, [1]) == [1, 2, 4, 5], "路口按选择走第二个方向")


func test_broken_map_is_reported() -> void:
	var board := Board.new()
	var errors := board.load_from({"id": "bad", "start_tile": 0, "tiles": [
		{"id": 0, "type": "start", "pos": [0, 0], "next": [0]},
		{"id": 1, "type": "land", "pos": [1, 0], "next": [0]},
	]})
	check(errors.size() >= 2, "坏地图能被发现（走不到的格子、缺街道组）")


func test_characters_ai_lines_match() -> void:
	var errors: Array = []
	var chars := JsonUtil.load_dict("res://data/characters.json", errors)
	var ai := JsonUtil.load_dict("res://data/ai/profiles.json", errors)
	var lines := JsonUtil.load_dict("res://data/lines/speech.json", errors)
	errors.append_array(DataCheck.check_characters(chars.get("characters", []), ai, lines))
	check(errors.is_empty(), "角色、AI 参数、台词对得上 %s" % str(errors))
	check(lines.get("conditions", {}).size() == 12, "台词有 12 种事件")


func test_cards_valid() -> void:
	var errors: Array = []
	var cards := JsonUtil.load_dict("res://data/cards/chance.json", errors)
	errors.append_array(DataCheck.check_cards(cards))
	check(errors.is_empty(), "机会卡格式正确 %s" % str(errors))
	check(cards.get("cards", []).size() == 34, "34 张机会卡")


func test_broken_cards_reported() -> void:
	var bad := {
		"cards":
		[
			{"id": 1, "text": "a", "effects": [{"op": "fly_to_moon"}]},
			{"id": 1, "text": "b", "effects": [{"op": "money"}]},
			{"id": 2, "text": "c", "effects": [{"op": "state", "state": "rich", "days": 1}]},
		]
	}
	check(DataCheck.check_cards(bad).size() == 4, "坏机会卡能被发现（未知效果、重复 id、缺参数、未知状态）")


func test_default_map() -> void:
	var errors: Array = []
	var rules := JsonUtil.load_dict("res://data/rules.json", errors)
	var map_id := str(rules.get("default_map", ""))
	var d := JsonUtil.load_dict("res://data/maps/%s.json" % map_id, errors)
	var board := Board.new()
	errors.append_array(board.load_from(d))
	check(errors.is_empty(), "默认地图 %s 能读取 %s" % [map_id, str(errors)])
	if not errors.is_empty():
		return
	var n := board.tile_count()
	check(n >= 30 and n <= 40, "默认地图 30-40 格（现在 %d）" % n)
	check(board.walk(n - 1, 1) == [0], "最后一格的下一格是起点")
