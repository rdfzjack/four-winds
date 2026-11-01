extends "res://tests/game_tests.gd"
## 第 7 步：存档 / 读档的测试。最重要的一条：存档后读回来，用同样的随机数继续走，
## 结果和没存档一直走下去完全一样（含人类等着做选择的时候存）。

const SaveGame = preload("res://scripts/core/save_game.gd")
const Speech = preload("res://scripts/core/speech.gd")
const AI = preload("res://scripts/core/ai.gd")

const TEST_DIR := "user://test_saves"


func run(p_runner: Object) -> void:
	if not load_data(p_runner):
		return
	SaveGame.dir = TEST_DIR
	_clean()
	test_codec()
	test_same_after_load_ai_games()
	test_same_after_load_human_pending()
	test_speech_state_continues()
	test_slots_and_errors()
	_clean()
	SaveGame.dir = "user://saves"


func _clean() -> void:
	if not DirAccess.dir_exists_absolute(TEST_DIR):
		return
	for f in DirAccess.get_files_at(TEST_DIR):
		DirAccess.remove_absolute(TEST_DIR.path_join(f))
	DirAccess.remove_absolute(TEST_DIR)


func real_maps() -> Dictionary:
	return runner.root.get_node("Data").maps


func ai_game(map_id: String, seed_value: int, ai_kind: String = "new_v2") -> Game:
	var specs: Array = []
	for i in range(4):
		specs.append({"character": str(characters[i]["id"]), "human": false, "ai": ai_kind})
	var g := Game.new()
	var errors := g.setup(real_maps()[map_id], rules, cards_file, characters, specs, seed_value)
	check(errors.is_empty(), "开局成功 %s" % str(errors))
	g.record_history = true
	g.start()
	return g


func steps(g: Game, n: int) -> void:
	for _i in range(n):
		if g.phase == "over" or not AI.step(g):
			return


func state_text(g: Game) -> String:
	return JSON.stringify(SaveGame.encode(g.export_state()))


## 存到 slot 再读回来，返回读回来的游戏（失败返回 null）
func roundtrip(g: Game, slot: String, speech = null) -> Dictionary:
	var err := SaveGame.save(slot, g, speech, {"log": ["第一行", "第二行"]})
	check(err == "", "存档成功 %s" % err)
	var r := SaveGame.load_slot(slot, real_maps(), rules, cards_file, characters)
	check(r["error"] == "", "读档成功 %s" % str(r.get("error", "")))
	return r


# ───────────────────────── 测试 ─────────────────────────

func test_codec() -> void:
	var v := {"a": 1, "b": [1, 2.5, "x", true, null], 3: {4: [5]}, "c": {"d": -7}, "f": 0.1,
			"g": 95.10096677940541}
	var back = SaveGame.decode(JSON.parse_string(JSON.stringify(SaveGame.encode(v))))
	check(back == v, "编码再解码，整数键、小数、嵌套都原样回来 %s" % str(back))
	check(typeof(back[3].keys()[0]) == TYPE_INT and typeof(back["a"]) == TYPE_INT, "整数还是整数")
	check(typeof(back["f"]) == TYPE_FLOAT and back["g"] == 95.10096677940541, "小数还是小数，一位都不差")
	var big := {"k": {"__f": "x", "other": 1}}
	check(SaveGame.decode(JSON.parse_string(JSON.stringify(SaveGame.encode(big)))) == big,
			"字典里碰巧有 __f 这样的键也不会读错")


## 全 AI 的局：在好几个时刻存档（含等着回答交易、拍卖的时候），读回来继续走，和不存档的结果完全一样
func test_same_after_load_ai_games() -> void:
	var cases := [["shanghai", 3, "new_v2"], ["shanghai_west", 5, "standard_v2"],
			["shanghai", 9, "original"]]
	var saved_pending := {}
	for c in cases:
		var base := ai_game(c[0], c[1], c[2])
		for round_no in range(4):
			steps(base, 1 if round_no == 0 else 40)
			if base.phase == "over":
				break
			_check_branch(base, "%s 种子 %s %s 第 %d 次存档" % [c[0], c[1], c[2], round_no + 1])
		# 专门找几种“等着回答”的时刻存档
		var probe := ai_game(c[0], c[1], c[2])
		for _i in range(3000):
			if probe.phase == "over" or not AI.step(probe):
				break
			if probe.phase == "pending" and not saved_pending.has(probe.pending.get("type", "")):
				saved_pending[probe.pending.get("type", "")] = true
				_check_branch(probe, "等着“%s”时存档" % str(probe.pending.get("type", "")))
	check(saved_pending.size() >= 2, "至少试了两种等回答的时刻 %s" % str(saved_pending.keys()))


## g 现在存档读回来；g 和读回来的各再走 120 步（g 是没存过档一直走的那份），完整状态（含记录）一样
func _check_branch(g: Game, label: String) -> void:
	var r := roundtrip(g, "1")
	if r["error"] != "":
		return
	var loaded: Game = r["game"]
	check(state_text(loaded) == state_text(g), "%s：读回来的状态和存档时一样" % label)
	check(r["extra"]["log"] == ["第一行", "第二行"], "额外的东西（日志）一起存了")
	steps(g, 120)
	steps(loaded, 120)
	check(state_text(g) == state_text(loaded), "%s：各再走 120 步，结果完全一样" % label)
	check(g.check_invariants().is_empty() and loaded.check_invariants().is_empty(),
			"%s：数据自洽" % label)


func test_same_after_load_human_pending() -> void:
	var g := new_game()
	var bj := tile_named(shanghai, "北京路1号")
	move(g, bj - 1, 1)
	check(g.phase == "pending" and g.pending["type"] == "buy_land", "走到空地：等人类决定买不买")
	var r := SaveGame.save("2", g)
	check(r == "", "等人类决定时能存档 %s" % r)
	var res := SaveGame.load_slot("2", {shanghai.id: shanghai}, rules, cards_file, characters)
	check(res["error"] == "", "读档 %s" % str(res["error"]))
	var loaded: Game = res["game"]
	check(loaded.phase == "pending" and loaded.pending == g.pending and loaded.actor() == 0,
			"读回来还是等同一个人决定同一块地")
	check(loaded.buy() and g.buy(), "读回来的局能买下")
	check(loaded.owner_of(bj) == 0 and state_text(loaded) == state_text(g), "买完以后两边一样")
	# 人类之后的回合：掷骰子用同样的随机数
	for pair in [[g, 0], [loaded, 0]]:
		for p in pair[0].players:
			p.human = false
	steps(g, 200)
	steps(loaded, 200)
	check(state_text(loaded) == state_text(g), "之后交给 AI 走 200 步，两边一样")
	# 路口选方向时存档
	var west = real_maps()["shanghai_west"]
	var gw := Game.new()
	gw.setup(west, rules, cards_file, characters, [{"character": "david", "human": true},
			{"character": "giorgio", "human": false}], 4)
	gw.start()
	var guard := 0
	while gw.phase != "over" and gw.pending.get("type", "") != "choose_direction" and guard < 400:
		guard += 1
		if gw.phase == "pre_roll" and gw.players[gw.actor()].human:
			gw.roll()
		elif gw.phase == "pending" and gw.players[gw.actor()].human:
			_human_default(gw)
		elif not AI.step(gw):
			break
	if gw.pending.get("type", "") == "choose_direction":
		check(SaveGame.save("3", gw) == "", "选方向时能存档")
		var rw := SaveGame.load_slot("3", real_maps(), rules, cards_file, characters)
		var lw: Game = rw["game"]
		var option: int = gw.pending["options"][0]
		check(lw.pending == gw.pending and lw.choose_direction(option)
				and gw.choose_direction(option),
				"读回来能接着选方向")
		check(state_text(lw) == state_text(gw), "选完方向两边一样")
	else:
		check(true, "（这个种子没走到路口选方向，跳过）")


func _human_default(g: Game) -> void:
	match str(g.pending.get("type", "")):
		"buy_land", "buy_company":
			g.decline()
		"bank":
			g.bank_done()
		"bail":
			g.bail(false)
		"choose_direction":
			g.choose_direction(int(g.pending["options"][0]))
		"auction":
			g.auction_pass()
		"trade":
			g.trade_answer(false)
		_:
			AI.step(g)


## 台词的记忆也存：读档后接着说的和不存档一样
func test_speech_state_continues() -> void:
	var data = runner.root.get_node("Data")
	var g := ai_game("shanghai", 12)
	var sp := Speech.new(data.lines, g)
	for _i in range(150):
		sp.plan(g.drain_events())
		AI.step(g)
	var r := roundtrip(g, "4", sp)
	var g2: Game = r["game"]
	var sp2 := Speech.new(data.lines, g2)
	sp2.import_state(r["speech"])
	check(JSON.stringify(SaveGame.encode(sp.export_state()))
			== JSON.stringify(SaveGame.encode(sp2.export_state())),
			"台词的记忆存读以后一样")
	var same := true
	var said := 0
	for _i in range(200):
		var plan_a := sp.plan(g.drain_events())
		var plan_b := sp2.plan(g2.drain_events())
		if str(plan_a) != str(plan_b):
			same = false
		for l in plan_a:
			said += l.size()
		AI.step(g)
		AI.step(g2)
	check(same and said > 0, "读档后接着走，说的话一模一样（说了 %d 句）" % said)


func test_slots_and_errors() -> void:
	_clean()
	var all := SaveGame.slots()
	check(all.size() == 6 and all[0]["slot"] == "auto"
			and all.all(func(m: Dictionary) -> bool: return m["empty"]),
			"一开始 6 个存档位（自动 + 5 个）全是空的")
	var g := ai_game("shanghai", 2)
	steps(g, 80)
	check(SaveGame.save("auto", g) == "" and SaveGame.save("5", g) == "", "存到自动位和 5 号位")
	var m: Dictionary = SaveGame.meta("5")
	check(not m["empty"] and m["day"] == g.day and m["map"] == "shanghai"
			and m["players"].size() == 4
			and m["players"][0]["character"] == "david" and str(m["saved_at"]) != "", "摘要里有天数、地图、玩家、时间")
	check(not SaveGame.slots()[5]["empty"] and SaveGame.slots()[1]["empty"], "列表里只有存过的位置不是空的")
	check(not FileAccess.file_exists(TEST_DIR.path_join("slot_5.json.tmp")), "没有留下临时文件")
	# 覆盖
	steps(g, 40)
	SaveGame.save("5", g)
	check(SaveGame.meta("5")["day"] == g.day, "覆盖存档")
	# 读档的各种失败
	var maps := real_maps()
	check(SaveGame.load_slot("3", maps, rules, cards_file, characters)["error"].contains("空"),
			"空位读不了")
	var f := FileAccess.open(TEST_DIR.path_join("slot_4.json"), FileAccess.WRITE)
	f.store_string("{ 坏掉了")
	f.close()
	check(SaveGame.meta("4")["broken"], "只有存档文件没有摘要：列表里标成坏的")
	check(SaveGame.load_slot("4", maps, rules, cards_file, characters)["error"].contains("坏"),
			"坏文件读不了，不崩")
	var no_map := maps.duplicate()
	no_map.erase("shanghai")
	check(SaveGame.load_slot("5", no_map, rules, cards_file, characters)["error"].contains("找不到"),
			"地图没了读不了")
	var other := {"shanghai": maps["shanghai_west"]}
	check(SaveGame.load_slot("5", other, rules, cards_file, characters)["error"].contains("格子数"),
			"地图改过读不了")
	# 结束的局不存
	g.phase = "over"
	check(SaveGame.save("1", g) != "", "结束的局不能存档")
	SaveGame.delete("5")
	check(SaveGame.meta("5")["empty"], "删除存档")
