extends SceneTree
## 自动测试（不开窗口）。在项目文件夹里运行：
##   godot --headless --script res://tests/run_tests.gd
## 全部通过时退出码为 0，有失败时为 1。
## 测试在第一帧才开始（这时全局的 Data 才加载好），最后把棋盘画面全 AI 跑几秒，确认画面代码能跑。

const JsonUtil = preload("res://scripts/core/json_util.gd")
const Board = preload("res://scripts/core/board.gd")
const DataCheck = preload("res://scripts/core/data_check.gd")
const GameTests = preload("res://tests/game_tests.gd")
const AiTests = preload("res://tests/ai_tests.gd")
const StreetTests = preload("res://tests/street_tests.gd")
const OriginalMapTests = preload("res://tests/original_map_tests.gd")
const Iso = preload("res://scripts/ui/iso.gd")
const Art = preload("res://scripts/ui/art.gd")

const SMOKE_DAYS := 3          ## 棋盘画面跑到第几天算通过
const SMOKE_TIMEOUT_MS := 30000  ## 最多等这么久
const SMOKE_MAP := "shanghai"     ## 冒烟测试用的地图（原版上海，格子最多）

var failures := 0
var checks := 0
var _frame := 0
var _table: Node = null
var _smoke_start := 0


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 1:
		run_logic_tests()
		test_iso()
		test_art_table()
		_start_table_smoke()
	elif _smoke_done():
		_finish_table_smoke()
		print("测试完成：%d 项检查，%d 项失败" % [checks, failures])
		quit(1 if failures > 0 else 0)
	return false


func run_logic_tests() -> void:
	test_data_files_load()
	test_maps_valid()
	test_walk_on_loop()
	test_walk_with_crossroad()
	test_broken_map_is_reported()
	test_characters_ai_lines_match()
	test_cards_valid()
	test_broken_cards_reported()
	test_default_map()
	GameTests.new().run(self)
	StreetTests.new().run(self)
	OriginalMapTests.new().run(self)
	AiTests.new().run(self)


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
	check(errors.size() >= 3, "坏地图能被发现（走不到的格子、缺街道组、缺系数）")


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
	var chars := JsonUtil.load_dict("res://data/characters.json", errors)
	errors.append_array(DataCheck.check_cards(cards, chars.get("characters", [])))
	check(errors.is_empty(), "机会卡格式正确 %s" % str(errors))
	check(cards.get("cards", []).size() == 30, "牌堆 30 张机会卡")
	check(cards.get("special_events", []).size() == 4, "4 个特殊事件")


func test_broken_cards_reported() -> void:
	var bad := {
		"cards":
		[
			{"id": 1, "text": "a", "effects": [{"op": "fly_to_moon"}]},
			{"id": 1, "text": "b", "effects": [{"op": "money"}]},
			{"id": 2, "text": "c", "effects": [{"op": "state", "state": "rich", "days": 1}]},
			{
				"id": 3,
				"text": "d",
				"weight": 150,
				"allowed_for": ["nobody"],
				"effects": [{"op": "money", "amount": 1}]
			},
		]
	}
	var chars := [{"id": "david"}]
	var errs := DataCheck.check_cards(bad, chars)
	check(errs.size() == 6, "坏机会卡能被发现（未知效果、重复 id、缺参数、未知状态、权重、角色）%s" % str(errs))


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


func test_iso() -> void:
	for cell in [Vector2(0, 0), Vector2(3, 7), Vector2(-2, 5), Vector2(11, 9)]:
		var w := Iso.to_world(cell)
		check(Iso.to_cell_f(w).is_equal_approx(cell), "等距换算能换回来 %s" % str(cell))
		check(Iso.to_cell(w + Vector2(15, 5)) == Vector2i(cell), "点在菱形里面算这一格 %s" % str(cell))
	check(Iso.to_world(Vector2(1, 0)) == Vector2(40, 20), "x 加 1 往右下半格（80×40 菱形）")
	check(Iso.to_world(Vector2(0, 1)) == Vector2(-40, 20), "y 加 1 往左下半格")
	check(Iso.depth(Vector2(2, 2)) > Iso.depth(Vector2(1, 2)), "靠前（屏幕下方）的格子后画")
	check(Iso.facing(Vector2(1, 0)) == "down_right" and Iso.facing(Vector2(-1, 0)) == "up_left"
			and Iso.facing(Vector2(0, 1)) == "down_left" and Iso.facing(Vector2(0, -1)) == "up_right",
			"走一步的朝向")


## 素材表：placeholder 目录在的时候每一项都能取到图；不在的时候（删掉后）全部返回空，不报错
func test_art_table() -> void:
	var has_placeholder := DirAccess.dir_exists_absolute(Art.P)
	for key in Art.SPRITES:
		var f: Dictionary
		if str(key).begins_with("walker_"):
			for facing in Art.FACING_GROUPS:
				f = Art.walker(str(key).trim_prefix("walker_"), facing)
				check(f.is_empty() != has_placeholder, "素材 %s 朝向 %s" % [key, facing])
		else:
			for i in Art.frame_count(key):
				f = Art.frame(key, i)
				check(f.is_empty() != has_placeholder, "素材 %s 第 %d 帧" % [key, i])
	check(Art.frame("没有这种图").is_empty(), "表里没有的图返回空")
	for c in root.get_node("Data").characters:
		check(Art.SPRITES.has("walker_" + str(c["id"])), "角色 %s 有走路图" % c["id"])


## 棋盘画面冒烟测试：全 AI 在原版上海地图上开一局，跑到第 SMOKE_DAYS 天
func _smoke_done() -> bool:
	if Time.get_ticks_msec() - _smoke_start > SMOKE_TIMEOUT_MS:
		return true
	var g = _table.get("game") if _table != null else null
	return g == null or g.day >= SMOKE_DAYS or g.phase == "over"



func _start_table_smoke() -> void:
	var specs: Array = []
	for c in root.get_node("Data").characters:
		specs.append({"character": str(c["id"]), "human": false})
	root.get_node("Data").start_specs = specs
	root.get_node("Data").start_map = SMOKE_MAP
	_table = load("res://scenes/table.tscn").instantiate()
	root.add_child(_table)
	_table._fast = true
	_smoke_start = Time.get_ticks_msec()


func _finish_table_smoke() -> void:
	var g = _table.get("game") if _table != null else null
	check(g != null, "棋盘画面能打开")
	if g == null:
		return
	check(g.check_invariants().is_empty(), "棋盘画面跑完数据自洽 %s" % str(g.check_invariants()))
	check(g.day >= SMOKE_DAYS or g.phase == "over", "棋盘画面上 AI 在走（%d 秒内到第 %d 天）"
			% [SMOKE_TIMEOUT_MS / 1000, g.day])
	var map = _table.get("_map")
	var cam = _table.get("_camera")
	check(map != null and cam != null and cam.is_current(), "地图层和镜头都在")
	check(map.tile_at(map.tile_position(0)) == 0, "点起点格子能点中起点")
	_table.queue_free()
	root.get_node("Data").start_specs = []
	root.get_node("Data").start_map = ""
