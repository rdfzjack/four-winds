extends "res://tests/save_tests.gd"
## 第 8a 步：个人主线框架的测试：条件类型、开局设置、胜 / 负 / 超时、没有关卡时不变、
## 存档读档后接着判定、进度文件（profile）读写和损坏。

const Scenario = preload("res://scripts/core/scenario.gd")
const Profile = preload("res://scripts/core/profile.gd")

const PROFILE_PATH := "user://test_profile.json"
const FIXTURE := "res://tests/fixtures/example_campaign.json"


func run(p_runner: Object) -> void:
	if not load_data(p_runner):
		return
	SaveGame.dir = TEST_DIR
	_clean()
	Profile.path = PROFILE_PATH
	test_campaign_data()
	test_real_stages_play()
	test_validate_catches_mistakes()
	test_apply_setup()
	test_conditions()
	test_win_lose_flow()
	test_free_mode_untouched()
	test_ai_games_end_in_time()
	test_save_and_resume()
	test_profile()
	_clean()
	_remove_profile_files()
	SaveGame.dir = "user://saves"
	Profile.path = "user://profile.json"


func _remove_profile_files() -> void:
	for f in [PROFILE_PATH, PROFILE_PATH + ".tmp"]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(f)


# ───────────────────────── 帮助 ─────────────────────────

func data() -> Node:
	return runner.root.get_node("Data")


## 测试用的示例关（tests/fixtures/example_campaign.json，不是正式内容）
func sample_stage(index: int = 0) -> Dictionary:
	var errors: Array = []
	var fx := JsonUtil.load_dict(FIXTURE, errors)
	check(errors.is_empty(), "示例主线能读 %s" % str(errors))
	return fx["stages"][index].duplicate(true)


## 概率事件关掉的规则（建房后不会挖古董 / 倒塌），测试里要建房时用
func quiet_rules() -> Dictionary:
	var r := rules.duplicate(true)
	r["houses"]["antique_chance_by_lots"] = NEVER_ODDS.duplicate()
	r["houses"]["collapse_chance"] = 2000000000
	return r


func scn_game(stage: Dictionary, seed_value: int = 5, game_rules: Dictionary = {}) -> Game:
	var sc := Scenario.new(stage)
	var g := Game.new()
	var use_rules := game_rules if not game_rules.is_empty() else rules
	var errors := g.setup(real_maps()[str(stage["map"])], use_rules,
			cards_file, characters, sc.specs(), seed_value)
	check(errors.is_empty(), "关卡开局成功 %s" % str(errors))
	g.scenario = sc
	var apply_errors := sc.apply(g)
	check(apply_errors.is_empty(), "关卡设置成功 %s" % str(apply_errors))
	g.start()
	return g


func event_types(g: Game) -> Array:
	var out: Array = []
	for e in g.events:
		out.append(str(e["type"]))
	return out


# ───────────────────────── 数据 ─────────────────────────

func test_campaign_data() -> void:
	for e in data().errors:
		check(not str(e).contains(".json：关卡") and not str(e).contains("campaigns"),
				"主线数据没有校验问题：%s" % str(e))
	for cid in ["david", "eric"]:
		check(data().campaigns.has(cid) and data().stages_of(cid).size() == 3, "%s 的主线有 3 关" % cid)
	for stage in data().stages_of("david"):
		check(bool(stage.get("example", false)) == (str(stage["id"]) != "david_3"),
				"斐斐第 1、2 关是占位（example），第 3 关不是：%s" % str(stage["id"]))
	check(sample_stage(0)["seats"].size() == 3 and sample_stage(1)["seats"].size() == 4, "示例关读得到")


## 正式主线的每一关：能开局，玩家交给 AI 打一阵，内部数据一直一致；打出结果的话结果合理
func test_real_stages_play() -> void:
	for cid in ["eric", "david"]:
		for i in range(data().stages_of(cid).size()):
			var stage: Dictionary = data().stages_of(cid)[i].duplicate(true)
			var g := scn_game(stage, 100 + i)
			g.players[g.scenario.player_seat].human = false
			g.players[g.scenario.player_seat].ai = "new_v2"
			steps(g, 2500)
			check(g.check_invariants().is_empty(),
					"%s 内部数据一致 %s" % [str(stage["id"]), str(g.check_invariants())])
			check(g.phase != "over" or g.scenario.result != "",
					"%s 结束时有结果" % str(stage["id"]))
			print("  主线 %s：第 %d 天 %s %s" % [str(stage["id"]), g.day,
					g.scenario.result if g.phase == "over" else "还在打", g.scenario.reason])


func test_validate_catches_mistakes() -> void:
	var maps := real_maps()
	var ok := Scenario.validate(sample_stage(), maps, characters, rules)
	check(ok.is_empty(), "示例关通过校验 %s" % str(ok))
	var s := sample_stage()
	s["map"] = "nowhere"
	check(not Scenario.validate(s, maps, characters, rules).is_empty(), "地图不存在要报错")
	s = sample_stage()
	s["win"] = [{"type": "no_such_type"}]
	check(not Scenario.validate(s, maps, characters, rules).is_empty(), "不认识的条件类型要报错")
	s = sample_stage()
	s["seats"][0].erase("player")
	check(not Scenario.validate(s, maps, characters, rules).is_empty(), "没有玩家座位要报错")
	s = sample_stage()
	s["seats"][1]["player"] = true
	check(not Scenario.validate(s, maps, characters, rules).is_empty(), "两个玩家座位要报错")
	s = sample_stage()
	s["seats"][0]["props"] = [{"tile": 999}]
	check(not Scenario.validate(s, maps, characters, rules).is_empty(), "预置地产格子不存在要报错")
	s = sample_stage(1)
	var alias := -1
	for t in real_maps()["shanghai_west"].tiles:
		if t.has("site"):
			alias = int(t["id"])
			break
	s["seats"][0]["props"] = [{"tile": alias}]
	check(not Scenario.validate(s, maps, characters, rules).is_empty(), "预置地产写成分身格要报错")
	s = sample_stage()
	s["seats"][1]["character"] = "david"
	check(not Scenario.validate(s, maps, characters, rules).is_empty(), "同一个角色坐两个位置要报错")
	s = sample_stage()
	s["win"] = []
	check(not Scenario.validate(s, maps, characters, rules).is_empty(), "胜利条件为空要报错")


func test_apply_setup() -> void:
	var g := scn_game(sample_stage())
	check(g.players[0].cash == 1000 and g.players[0].deposit == 500, "玩家开局现金 / 存款按关卡")
	check(g.players[0].human and not g.players[1].human and g.players[1].ai == "new_v2",
			"玩家是人类，对手是角色 AI")
	check(g.owner_of(4) == 0 and g.owner_of(5) == 0 and g.owner_of(6) == -1, "预置地产归玩家")
	check(g.owner_of(1) == 1 and g.house_at(1) != 0 and g.houses[g.house_at(1)]["kind"] == "flat",
			"预置的房子盖好了")
	check(g.check_invariants().is_empty(), "预置之后内部数据一致 %s" % str(g.check_invariants()))
	var sc := Scenario.new(sample_stage())
	var g2 := Game.new()
	g2.setup(real_maps()["shanghai_loop"], rules, cards_file, characters, sc.specs(), 1)
	var bad := sample_stage()
	bad["seats"][0]["props"] = [{"tiles": [4, 5], "house": "villa"}]
	check(not Scenario.new(bad).apply(g2).is_empty(), "房子占的地块数不对要报错")
	check(g2.owner_of(4) == -1, "出错时地不留在玩家名下")
	bad = sample_stage()
	bad["seats"][0]["props"] = [{"tile": 4}, {"tile": 4}]
	g2.setup(real_maps()["shanghai_loop"], rules, cards_file, characters, sc.specs(), 1)
	check(not Scenario.new(bad).apply(g2).is_empty(), "同一块地给两次要报错")


# ───────────────────────── 条件类型 ─────────────────────────

func test_conditions() -> void:
	var g := scn_game(sample_stage(), 5, quiet_rules())
	var sc: Scenario = g.scenario
	# bankrupt
	var c := {"type": "bankrupt", "who": 1}
	check(not sc.cond_met(g, c), "bankrupt：没破产不满足")
	g.players[1].bankrupt = true
	check(sc.cond_met(g, c), "bankrupt：破产了满足")
	var all_others := {"type": "bankrupt", "who": "others", "mode": "all"}
	check(not sc.cond_met(g, all_others), "bankrupt all：还有人没破产不满足")
	check(sc.cond_met(g, {"type": "bankrupt", "who": "others", "mode": "any"}), "bankrupt any：有人破产满足")
	g.players[2].bankrupt = true
	check(sc.cond_met(g, all_others), "bankrupt all：所有对手都破产满足")
	g.players[1].bankrupt = false
	g.players[2].bankrupt = false
	check(not sc.cond_met(g, {"type": "bankrupt", "who": "player"}), "bankrupt player：玩家没破产")
	check(not sc.cond_met(g, {"type": "bankrupt", "who": 9}), "bankrupt：座位不存在不满足也不崩")
	# build_house：对手 giorgio 预置了 1 栋平房
	check(sc.cond_met(g, {"type": "build_house", "who": 1, "kind": "flat"}), "build_house：有平房")
	var two := {"type": "build_house", "who": 1, "kind": "flat", "count": 2}
	check(not sc.cond_met(g, two), "build_house：数量不够")
	var listed := {"type": "build_house", "who": 1, "kind": ["villa", "flat"]}
	check(sc.cond_met(g, listed), "build_house：kind 可以是列表")
	var villa := {"type": "build_house", "who": "player", "kind": "villa"}
	check(not sc.cond_met(g, villa), "build_house：玩家没别墅")
	# control_industry：shanghai_loop 的 transport 企业在 8 和 25
	var ind := {"type": "control_industry", "who": "player", "industry": "transport"}
	check(not sc.cond_met(g, ind), "control_industry：没拥有不满足")
	g.grant_lots(0, [8])
	check(not sc.cond_met(g, ind), "control_industry：只有一家不满足")
	g.grant_lots(0, [25])
	check(sc.cond_met(g, ind), "control_industry：全拥有满足")
	check(not sc.cond_met(g, {"type": "control_industry", "who": "player", "industry": "nothing"}),
			"control_industry：行业不存在不满足")
	# control_street：北京路 4–7，玩家已有 4、5
	var st := {"type": "control_street", "who": "player", "group": "北京路"}
	check(not sc.cond_met(g, st), "control_street：还差两块")
	g.grant_lots(0, [6, 7])
	check(sc.cond_met(g, st), "control_street：凑齐了")
	check(sc.cond_met(g, {"type": "control_street", "who": "player"}), "control_street：任意一条街")
	check(not sc.cond_met(g, {"type": "control_street", "who": 2}), "control_street：别人没凑齐")
	# own_lots_pct / assets_at_least
	var pct90 := {"type": "own_lots_pct", "who": "player", "pct": 90}
	check(not sc.cond_met(g, pct90), "own_lots_pct：不到 90%")
	var pct10 := {"type": "own_lots_pct", "who": "player", "pct": 10}
	check(sc.cond_met(g, pct10), "own_lots_pct：到 10%")
	var assets := g.total_assets(0)
	var exact := {"type": "assets_at_least", "who": "player", "amount": assets}
	check(sc.cond_met(g, exact), "assets_at_least：刚好够")
	var over := {"type": "assets_at_least", "who": "player", "amount": assets + 1}
	check(not sc.cond_met(g, over), "assets_at_least：差一点")
	# days_over
	var d := {"type": "days_over", "days": 30}
	g.day = 30
	check(not sc.cond_met(g, d), "days_over：第 30 天还没超")
	g.day = 31
	check(sc.cond_met(g, d), "days_over：第 31 天超了")
	check(not sc.cond_met(g, {"type": "bogus"}), "不认识的条件当作不满足")
	# 说明文字
	var names := sc.names_of(g)
	check(sc.describe({"type": "build_house", "who": "player", "kind": "villa"}, names) == "你建成一栋别墅",
			"说明：建别墅 %s" % sc.describe({"type": "build_house", "who": "player", "kind": "villa"}, names))
	check(sc.describe(all_others, names) == "击败所有对手", "说明：击败所有对手")
	check(sc.goals_text(names).contains("胜利条件") and sc.goals_text(names).contains("失败条件"), "简介里有胜负条件")


# ───────────────────────── 胜 / 负 / 超时 ─────────────────────────

func test_win_lose_flow() -> void:
	# 胜：玩家建成别墅
	var g := scn_game(sample_stage(), 5, quiet_rules())
	g.grant_lots(0, [6, 7])
	g.players[0].cash = 5000
	var why := g.build(0, "villa", [4, 5, 6, 7])
	check(why == "", "建别墅成功 %s" % why)
	check(g.phase == "over" and g.scenario.result == "won" and g.winner == 0, "建成别墅立刻过关")
	var types := event_types(g)
	check(types.has("scenario_won") and types.find("scenario_won") < types.rfind("game_over"),
			"先发 scenario_won 再发 game_over %s" % str(types))
	check(g.scenario.reason == "你建成一栋别墅", "过关的原因：%s" % g.scenario.reason)
	# 负：玩家破产
	g = scn_game(sample_stage(), 5)
	g._bankrupt(g.players[0], 1)
	check(g.phase == "over" and g.scenario.result == "lost" and g.winner == -1, "玩家破产就失败")
	check(event_types(g).has("scenario_lost"), "发 scenario_lost")
	# 负：对手先破产但条件是“全部”——不满足，继续
	g = scn_game(sample_stage(1), 5)
	g._bankrupt(g.players[1], 0)
	check(g.phase != "over", "只破产一个对手，击败所有对手的关还没过")
	g._bankrupt(g.players[2], 0)
	check(g.phase != "over", "还剩一个对手没破产")
	g._bankrupt(g.players[3], 0)
	check(g.phase == "over" and g.scenario.result == "won", "所有对手都破产，过关")
	# 同时满足胜和负：按负算
	var both := sample_stage()
	both["win"] = [{"type": "days_over", "days": 0}]
	both["lose"] = [{"type": "days_over", "days": 0}]
	g = scn_game(both, 5)
	check(g.phase == "over" and g.scenario.result == "lost", "胜和负同时满足时算失败")
	# 对局本身结束（只剩玩家一个人）但没有条件命中：按谁赢了算
	var odd := sample_stage()
	odd["win"] = [{"type": "assets_at_least", "who": "player", "amount": 99999999}]
	g = scn_game(odd, 5)
	g._bankrupt(g.players[1], 0)
	g._bankrupt(g.players[2], 0)
	check(g.phase == "over" and g.scenario.result == "won" and g.winner == 0, "只剩玩家：按最后站着的算赢")
	g = scn_game(odd, 5)
	g._bankrupt(g.players[0], 1)
	check(g.scenario.result == "lost" and g.scenario.reason.contains("破产"),
			"玩家破产：算输 %s" % g.scenario.reason)
	# 结果出来以后不再变
	var r: String = g.scenario.check(g)
	check(r == "lost", "有了结果以后 check 返回原结果")


func test_free_mode_untouched() -> void:
	var g := new_game(null, 4, {}, 7)
	check(g.scenario == null, "自由模式没有关卡")
	g._bankrupt(g.players[1], 0)
	g._bankrupt(g.players[2], 0)
	g._bankrupt(g.players[3], 0)
	check(g.phase == "over" and g.winner == 0, "自由模式：只剩一个人，他赢")
	check(not event_types(g).has("scenario_won") and not event_types(g).has("scenario_lost"),
			"自由模式不发关卡事件")
	check(g.export_state()["scenario"].is_empty(), "自由模式的存档里关卡是空的")


func test_ai_games_end_in_time() -> void:
	# 限时 5 天、赢不了的关：玩家交给 AI，一定在第 6 天开始时判负
	var s := sample_stage()
	s["win"] = [{"type": "assets_at_least", "who": "player", "amount": 99999999}]
	s["lose"] = [{"type": "days_over", "days": 5}]
	var g := scn_game(s, 3)
	g.players[0].human = false
	g.players[0].ai = "new_v2"
	steps(g, 5000)
	check(g.phase == "over" and g.scenario.result == "lost", "限时到了判负")
	check(g.day == 6 and g.scenario.reason == "超过 5 天",
			"第 6 天开始时判负：第 %d 天 %s" % [g.day, g.scenario.reason])
	check(g.check_invariants().is_empty(), "超时结束时内部数据一致")
	# 两个示例关全 AI 打：都会在限时内出结果，且事件里恰好一个 scenario_*
	for i in range(2):
		g = scn_game(sample_stage(i), 11 + i)
		g.players[0].human = false
		g.players[0].ai = "new_v2"
		var limit := 30 if i == 0 else 60
		steps(g, 20000)
		check(g.phase == "over" and g.scenario.result != "",
				"示例关 %d 打到出结果：%s" % [i + 1, g.scenario.result])
		check(g.day <= limit + 1, "示例关 %d 没有超过限时：第 %d 天" % [i + 1, g.day])
		var n := 0
		for e in g.events:
			if str(e["type"]) == "scenario_won" or str(e["type"]) == "scenario_lost":
				n += 1
		check(n == 1, "示例关 %d 只发一个结果事件" % [i + 1])


func test_save_and_resume() -> void:
	# 全 AI 走一段，存档再读回来：状态逐字一样，各自再走一段还是一样
	var g := scn_game(sample_stage(1), 21)
	g.players[0].human = false
	g.players[0].ai = "new_v2"
	steps(g, 60)
	check(g.phase != "over", "存档前还没结束")
	var r := roundtrip(g, "1")
	var g2: Game = r["game"]
	check(g2.scenario != null and g2.scenario.stage == g.scenario.stage, "读档后关卡数据原样回来")
	check(state_text(g) == state_text(g2), "读档后的状态和存档时逐字一样")
	g2.players[0].human = false
	steps(g, 150)
	steps(g2, 150)
	check(state_text(g) == state_text(g2), "再各走 150 步，状态还是逐字一样（含关卡结果）")
	check(g.scenario.result == g2.scenario.result, "两边的关卡结果一样")
	# 人类等着掷骰时存档，读回来建别墅就过关
	var h := scn_game(sample_stage(), 5)
	h.grant_lots(0, [6, 7])
	h.players[0].cash = 5000
	var r2 := roundtrip(h, "2")
	var loaded: Game = r2["game"]
	loaded.rules = quiet_rules()
	check(loaded.phase == "pre_roll" and loaded.scenario != null, "读档后在掷骰前，关卡还在")
	check(loaded.build(0, "villa", [4, 5, 6, 7]) == "", "读档后建别墅")
	check(loaded.phase == "over" and loaded.scenario.result == "won", "读档后接着判定，过关")
	# 旧存档（没有 scenario 这一项）读回来是自由模式
	var free := new_game(null, 4, {}, 7)
	var st := free.export_state()
	st.erase("scenario")
	var fresh := Game.new()
	var specs: Array = []
	for i in range(4):
		specs.append({"character": str(characters[i]["id"]), "human": i == 0})
	fresh.setup(shanghai, rules, cards_file, characters, specs, 1)
	check(fresh.import_state(st) == "" and fresh.scenario == null, "没有 scenario 项的旧存档读成自由模式")
	# 结束了的关卡不能存档
	var done := scn_game(sample_stage(), 5)
	done._bankrupt(done.players[0], 1)
	check(SaveGame.save("3", done) != "", "结束了的关卡局不能存档")


func test_profile() -> void:
	_remove_profile_files()
	var p := Profile.load_profile()
	check(p["characters"].is_empty() and p["back_unlocked"].is_empty(), "没有文件：全新进度")
	check(Profile.stage_status(p, "david", 0, 3) == "current", "全新进度：第 1 关是当前")
	check(Profile.stage_status(p, "david", 1, 3) == "locked", "全新进度：第 2 关未解锁")
	Profile.mark_cleared(p, "david", 0, 3)
	check(Profile.stage_status(p, "david", 0, 3) == "cleared"
			and Profile.stage_status(p, "david", 1, 3) == "current", "通关第 1 关：它变成已通关，第 2 关变当前")
	Profile.mark_cleared(p, "david", 0, 3)
	check(Profile.next_stage(p, "david") == 1, "重玩已通关的关，进度不倒退也不多涨")
	check(not Profile.back_unlocked(p, "david"), "还没通关主线，里形态没解锁")
	Profile.mark_cleared(p, "david", 1, 3)
	Profile.mark_cleared(p, "david", 2, 3)
	check(Profile.main_cleared(p, "david") and Profile.back_unlocked(p, "david"), "通关最后一关：主线通关，里形态解锁")
	check(not Profile.back_unlocked(p, "eric"), "别的角色不受影响")
	check(Profile.save_profile(p) == "", "进度能存")
	check(not FileAccess.file_exists(PROFILE_PATH + ".tmp"), "没有留下临时文件")
	var back := Profile.load_profile()
	check(back == p, "存了再读，内容一样 %s" % str(back))
	# 损坏的文件
	var bads := ["{{{ not json", "[1,2,3]", "", "{\"version\": 99, \"characters\": {}}",
			"{\"version\": 1}"]
	for bad in bads:
		var f := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
		f.store_string(bad)
		f.close()
		var q := Profile.load_profile()
		check(q["characters"].is_empty() and q["back_unlocked"].is_empty(), "坏文件当全新：%s" % bad)
	var f2 := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
	var odd_data := {"version": 1, "characters": {"david": {"next": -5, "cleared": true},
			"eric": "oops"}, "back_unlocked": ["david", "david", "x"]}
	f2.store_string(JSON.stringify(odd_data))
	f2.close()
	var odd := Profile.load_profile()
	check(Profile.next_stage(odd, "david") == 0 and not odd["characters"].has("eric"), "奇怪的内容被修正 / 忽略")
	check(odd["back_unlocked"] == ["david", "x"], "解锁列表去重")
