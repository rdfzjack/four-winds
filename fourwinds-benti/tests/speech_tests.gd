extends "res://tests/game_tests.gd"
## 第 6b 步：台词框架的测试。台词库（lines_db.gd）的读法和条件筛选、谁什么时候说话（speech.gd）、
## 游戏里新加的 street_done / dodged 事件、真实台词文件没写错。

const LinesDb = preload("res://scripts/core/lines_db.gd")
const Speech = preload("res://scripts/core/speech.gd")
const AI = preload("res://scripts/core/ai.gd")

## 测试用的小事件表：几个事件，数值全部可控
const EVENTS := {
	"sources": {"作者": 1, "占位": 1},
	"moods": {"list": ["平常", "生气", "开心"]},
	"settings": {"weight_target": 4, "weight_present": 2, "weight_map": 3, "recent_memory": 2,
			"pester_window_days": 6, "pester_count": 3},
	"events": {
		"付高额租金": {"id": "rent_big", "mood": "平常", "priority": 10, "chance": 100, "cooldown": 0},
		"进巡捕房": {"id": "jailed", "mood": "平常", "priority": 10, "chance": 100, "cooldown": 0},
		"交好运": {"id": "good_luck", "mood": "开心", "priority": 10, "chance": 100, "cooldown": 2},
		"倒霉": {"id": "bad_luck", "mood": "平常", "priority": 10, "chance": 0, "cooldown": 0},
		"被偷": {"id": "stolen", "mood": "平常", "priority": 10, "chance": 100, "cooldown": 0},
		"偷到钱": {"id": "steal", "mood": "平常", "priority": 10, "chance": 100, "cooldown": 0},
		"发起交易": {"id": "trade_propose", "mood": "平常", "priority": 10, "chance": 100, "cooldown": 0},
		"接受交易": {"id": "trade_accept", "mood": "开心", "priority": 10, "chance": 100, "cooldown": 0},
		"拒绝交易": {"id": "trade_reject", "mood": "平常", "priority": 10, "chance": 100, "cooldown": 0},
		"还价": {"id": "trade_counter", "mood": "平常", "priority": 10, "chance": 100, "cooldown": 0},
		"讨价还价": {"id": "haggle", "mood": "平常", "priority": 20, "chance": 100, "cooldown": 0},
		"被压价": {"id": "lowball", "mood": "生气", "priority": 20, "chance": 100, "cooldown": 0},
		"放水让价": {"id": "mercy", "mood": "开心", "priority": 20, "chance": 100, "cooldown": 0},
		"领先时放宽": {"id": "lead_relax", "mood": "平常", "priority": 20, "chance": 100, "cooldown": 0},
		"按错": {"id": "slip", "mood": "平常", "priority": 20, "chance": 100, "cooldown": 0},
		"被同一个人纠缠": {"id": "pestered", "mood": "生气", "priority": 15, "chance": 100, "cooldown": 0},
		"自己破产": {"id": "self_bankrupt", "mood": "平常", "priority": 30, "chance": 100, "cooldown": 0},
		"对手破产": {"id": "rival_bankrupt", "mood": "平常", "priority": 30, "chance": 100,
				"cooldown": 0},
		"开局": {"id": "game_start", "mood": "平常", "priority": 10, "chance": 100, "cooldown": 0},
		"赢": {"id": "win", "mood": "开心", "priority": 30, "chance": 100, "cooldown": 0},
		"输": {"id": "lose", "mood": "平常", "priority": 30, "chance": 100, "cooldown": 0},
	},
}

## 性格时刻和“被纠缠”：通用台词里不放，要用的测试自己用 extra 加
const MOMENT_EVENTS := ["按错", "被压价", "放水让价", "领先时放宽", "讨价还价", "被同一个人纠缠"]
const MAPS := [{"id": "shanghai_loop", "name": "上海（原版数据，一圈）"}, {"id": "shanghai",
		"name": "上海（原版地图）"},
		{"id": "shanghai_west", "name": "上海西区"}]


func run(p_runner: Object) -> void:
	if not load_data(p_runner):
		return
	test_parse_and_errors()
	test_pool_conditions()
	test_sources_and_form_fallback()
	test_trade_speakers()
	test_moments_and_priority()
	test_pairs_and_game_over()
	test_chance_cooldown_recent()
	test_pester()
	test_start_only_one()
	test_new_game_events()
	test_ai_game_speech()
	test_real_lines()


# ───────────────────────── 帮助函数 ─────────────────────────

func make_db(files: Dictionary) -> LinesDb:
	var db := LinesDb.new()
	db.setup(EVENTS.duplicate(true), characters, MAPS)
	for f in files:
		db.add_file(str(f), str(files[f]))
	return db


func speech_for(g: Game, files: Dictionary) -> Speech:
	var db := make_db(files)
	check(db.errors.is_empty(), "测试台词没写错 %s" % str(db.errors))
	return Speech.new(db, g)


## 一个 4 人局的所有人都有的“通用”台词：每个事件每人一句，句子里带人名好认
func plain_files(extra: Dictionary = {}) -> Dictionary:
	var files := {}
	var nick := {"斐斐": "david", "小九": "giorgio", "孔雀": "marcel", "理理": "eric"}
	for n in nick:
		var text := "# 来源：作者\n"
		for ev in EVENTS["events"]:
			if MOMENT_EVENTS.has(ev):
				continue
			text += "## %s\n- %s·%s\n" % [ev, n, ev]
		text += str(extra.get(n, ""))
		files[n + ".txt"] = text
	return files


func ev(type: String, data: Dictionary = {}) -> Dictionary:
	var e := data.duplicate()
	e["type"] = type
	return e


func texts(plan: Array) -> Array:
	var out: Array = []
	for list in plan:
		for u in list:
			out.append(str(u["text"]))
	return out


# ───────────────────────── 台词库 ─────────────────────────

func test_parse_and_errors() -> void:
	var db := make_db({"斐斐.txt": """# 随便的注释
# 来源：作者
## 付高额租金
- “这笔我记下了。”
- （对孔雀）（只在上海）教授，你是认真的吗？ [生气]
- （小九在场时）哇，盖好了～
""", "孔雀·里.txt": "# 来源：占位\n## 进巡捕房\n- 里孔雀的话\n"})
	check(db.errors.is_empty(), "写对的台词文件没有错误 %s" % str(db.errors))
	var lines: Array = db.lines_of("david", "front")["付高额租金"]
	check(lines.size() == 3 and lines[0]["text"] == "这笔我记下了。", "两头的引号去掉")
	check(lines[1]["mood"] == "生气" and lines[1]["conds"].size() == 2
			and lines[1]["text"] == "教授，你是认真的吗？",
			"句尾表情和两个条件都读出来")
	check(lines[1]["conds"][1]["maps"].size() == 2, "“只在上海”匹配所有叫上海（……）的地图")
	check(lines[2]["conds"][0] == {"kind": "present", "id": "giorgio"}, "某某在场时")
	check(db.lines_of("marcel", "back").has("进巡捕房"), "昵称·里.txt 是里形态的台词")
	# 各种写错：都要报，带文件名和行号
	var bad := make_db({
		"斐斐.txt": "- 没有来源\n# 来源：作者\n## 没这个事件\n- x\n## 进巡捕房\n- （对路人甲）x\n- （只在火星）x\n- x [没这个表情]\n"
				+ "- （看不懂）x\n- （对孔雀x\n乱写的一行\n# 来源：别人\n",
		"路人.txt": "# 来源：作者\n",
		"小九·外.txt": "# 来源：作者\n"})
	var joined := "\n".join(bad.errors)
	check(bad.errors.size() == 11, "每处错误都报出来（%d 条）" % bad.errors.size())
	for needle in ["斐斐.txt 第 1 行", "斐斐.txt 第 3 行", "斐斐.txt 第 6 行", "斐斐.txt 第 7 行", "斐斐.txt 第 8 行",
			"斐斐.txt 第 9 行", "斐斐.txt 第 10 行", "斐斐.txt 第 11 行", "斐斐.txt 第 12 行", "路人.txt", "小九·外.txt"]:
		check(joined.contains(needle), "错误里有 " + needle)


func test_pool_conditions() -> void:
	var db := make_db({"斐斐.txt": """# 来源：作者
## 进巡捕房
- 通用
- （对孔雀）对孔雀
- （对孔雀里）对孔雀里
- （理理在场时）理理在场
- （只在上海）只在上海
- （对孔雀）（理理在场时）两个条件
"""})
	var base := {"target": "", "target_form": "", "present": [], "map": "shanghai_west"}
	check(db.pool("david", "front", "进巡捕房", base).size() == 1, "没对象、没人在场、别的地图：只有通用一句")
	var ctx := base.duplicate()
	ctx["target"] = "marcel"
	ctx["target_form"] = "front"
	var pool: Array = db.pool("david", "front", "进巡捕房", ctx)
	check(pool.size() == 2 and float(pool[1]["weight"]) == 4.0, "对孔雀（表）：通用 + 对孔雀，针对某人权重 ×4")
	ctx["target_form"] = "back"
	check(db.pool("david", "front", "进巡捕房", ctx).size() == 3, "对孔雀（里）：对孔雀（不限形态）也算")
	ctx["present"] = ["eric"]
	ctx["map"] = "shanghai"
	pool = db.pool("david", "front", "进巡捕房", ctx)
	check(pool.size() == 6, "全满足时 6 句都能抽，现在 %d" % pool.size())
	var weights: Array = []
	for e in pool:
		weights.append(float(e["weight"]))
	check(weights.has(8.0) and weights.has(2.0) and weights.has(3.0), "在场 ×2，地图 ×3，两个条件相乘（4×2 = 8）")


func test_sources_and_form_fallback() -> void:
	var db := make_db({"斐斐.txt": "# 来源：作者\n## 进巡捕房\n- 作者的\n# 来源：占位\n## 进巡捕房\n- 占位的\n",
			"孔雀.txt": "# 来源：作者\n## 进巡捕房\n- 表孔雀\n## 倒霉\n- 表孔雀倒霉\n",
			"孔雀·里.txt": "# 来源：作者\n## 进巡捕房\n- 里孔雀\n"})
	var ctx := {"target": "", "target_form": "", "present": [], "map": "x"}
	check(db.pool("david", "front", "进巡捕房", ctx).size() == 2, "作者和占位混在一个池子里")
	db.sources["占位"] = 0
	check(db.pool("david", "front", "进巡捕房", ctx).size() == 1, "来源开关关掉占位")
	db.sources["占位"] = 0.5
	check(float(db.pool("david", "front", "进巡捕房", ctx)[1]["weight"]) == 0.5, "来源权重")
	check(db.pool("marcel", "back", "进巡捕房", ctx)[0]["line"]["text"] == "里孔雀", "里形态用自己的句子")
	check(db.pool("marcel", "back", "倒霉", ctx)[0]["line"]["text"] == "表孔雀倒霉", "里形态没有的事件用表形态的")
	check(db.pool("giorgio", "front", "进巡捕房", ctx).is_empty(), "没有台词文件的角色池子是空的")


# ───────────────────────── 谁说、对谁说 ─────────────────────────

func offer(from: int, to: int) -> Dictionary:
	return {"from": from, "to": to, "give": [1], "get": [3], "give_cash": 0, "get_cash": 0}


func test_trade_speakers() -> void:
	var g := new_game()
	var sp := speech_for(g, plain_files())
	var o := offer(0, 1)
	var plan := sp.plan([ev("turn_start", {"player": 0, "day": 2}), ev("trade_proposed",
			{"player": 0, "offer": o})])
	var u: Dictionary = plan[1][0]
	check(u["player"] == 0 and u["target"] == 1 and u["event"] == "trade_propose", "发起交易：发起人对对方说")
	var cases := [
		[ev("trade_done", {"player": 0, "offer": o}), 1, 0, "trade_accept"],
		[ev("trade_rejected", {"player": 1, "offer": o}), 1, 0, "trade_reject"],
		[ev("trade_countered", {"player": 1, "offer": o}), 1, 0, "trade_counter"],
	]
	for c in cases:
		var p := speech_for(g, plain_files()).plan([ev("trade_proposed", {"player": 0, "offer": o}),
				c[0]])
		var r: Dictionary = p[1][0]
		check(r["player"] == c[1] and r["target"] == c[2] and r["event"] == c[3],
				"%s：回答的人 %d 对 %d 说" % [c[3], c[1], c[2]])
	# 还价以后发起人的回应：说话的是发起人，对象是回答还价的人
	var p2 := sp.plan([ev("trade_proposed", {"player": 0, "offer": o}), ev("trade_countered",
			{"player": 1, "offer": o}),
			ev("trade_done", {"player": 0, "offer": o})])
	check(p2[2][0]["player"] == 0 and p2[2][0]["target"] == 1
			and p2[2][0]["event"] == "trade_accept", "对还价的回应是发起人说的")
	var p3 := sp.plan([ev("trade_proposed", {"player": 0, "offer": o}), ev("trade_countered",
			{"player": 1, "offer": o}),
			ev("trade_rejected", {"player": 0, "offer": o})])
	check(p3[2][0]["player"] == 0 and p3[2][0]["event"] == "trade_reject", "发起人拒绝还价：发起人说一句拒绝")
	check(p3[1].size() == 1 and p3[2].size() == 1, "每一步各只一个人说")
	# 针对某人的台词只在对象对的时候出现
	var sp2 := speech_for(g, {"斐斐.txt": "# 来源：作者\n## 发起交易\n- （对孔雀）只对孔雀\n",
			"小九.txt": "# 来源：作者\n## 发起交易\n- 通用\n"})
	check(texts(sp2.plan([ev("trade_proposed", {"player": 0, "offer": offer(0, 1)})])).is_empty(),
			"斐斐对小九没有台词就不说")
	check(texts(sp2.plan([ev("trade_proposed", {"player": 0, "offer": offer(0, 2)})])) == ["只对孔雀"],
			"斐斐对孔雀说专属台词")
	# 性格时刻替换普通回答：ai_note 紧挨着回答
	var extra := {"小九": "## 按错\n- 小九按错了\n## 被压价\n- 小九被压价\n## 放水让价\n- 小九放水\n"}
	var sp3 := speech_for(g, plain_files(extra))
	for pair in [["random_yes", "小九按错了"], ["slip", "小九按错了"], ["grace", "小九放水"], ["mercy", "小九放水"]]:
		var pn := sp3.plan([ev("trade_proposed", {"player": 0, "offer": o}), ev("ai_note",
				{"player": 1, "kind": pair[0]}),
				ev("trade_done", {"player": 0, "offer": o})])
		check(texts(pn).slice(1) == [pair[1]], "ai_note %s → %s（替换普通接受，只一句）" % [pair[0], pair[1]])
	var pn2 := sp3.plan([ev("trade_proposed", {"player": 0, "offer": o}), ev("ai_note",
			{"player": 1, "kind": "lowball"}),
			ev("trade_rejected", {"player": 1, "offer": o})])
	check(pn2[2][0]["text"] == "小九被压价" and pn2[2][0]["mood"] == "生气", "被压价替换拒绝，默认表情生气")
	# 中间隔了别的事件的 ai_note 作废；别人的 ai_note 不算
	var pn3 := sp3.plan([ev("ai_note", {"player": 1, "kind": "slip"}), ev("rolled", {"player": 1,
			"dice": [1, 1], "steps": 2}),
			ev("trade_proposed", {"player": 0, "offer": o}), ev("trade_done", {"player": 0,
					"offer": o})])
	check(pn3[3][0]["text"] == "小九·接受交易", "隔了别的事件的 ai_note 不再算")
	var pn4 := sp3.plan([ev("trade_proposed", {"player": 0, "offer": o}), ev("ai_note",
			{"player": 2, "kind": "slip"}),
			ev("trade_done", {"player": 0, "offer": o})])
	check(pn4[2][0]["text"] == "小九·接受交易", "别人的 ai_note 不算")
	# 性格时刻事件下该角色没台词：退回普通回答
	var pn5 := sp3.plan([ev("trade_proposed", {"player": 0, "offer": o}), ev("ai_note",
			{"player": 1, "kind": "haggle"}),
			ev("trade_countered", {"player": 1, "offer": o})])
	check(pn5[2][0]["text"] == "小九·还价", "没有讨价还价的台词就退回普通还价")


func test_moments_and_priority() -> void:
	var g := new_game()
	var sp := speech_for(g, plain_files())
	# 交租导致破产：只说破产那句（同一刻同一个人）；接手的人接一句
	var plan := sp.plan([ev("rolled", {"player": 0, "dice": [1, 1], "steps": 2}),
			ev("rent", {"player": 0, "owner": 1, "tile": 3, "amount": 99, "scale": "big"}),
			ev("bankrupt", {"player": 0, "creditor": 1})])
	check(texts(plan) == ["斐斐·自己破产", "小九·对手破产"], "破产 > 普通台词；破产者之后接手的人回一句 %s" % str(texts(plan)))
	check(plan[2].size() == 2 and plan[2][0]["player"] == 0 and plan[2][1]["player"] == 1
			and plan[2][1]["target"] == 0,
			"一前一后，接手的人对破产者说")
	# 政府逼的破产（没有债主）：只有自己那句
	var plan2 := sp.plan([ev("bankrupt", {"player": 2, "creditor": -1})])
	check(texts(plan2) == ["孔雀·自己破产"], "没有债主就没人接话")
	# 破产的人不再算“在场”
	var sp2 := speech_for(g, {"斐斐.txt": "# 来源：作者\n## 进巡捕房\n- （理理在场时）理理在\n- 理理不在\n"})
	sp2.plan([ev("bankrupt", {"player": 3, "creditor": -1})])
	var p3 := sp2.plan([ev("jailed", {"player": 0, "days": 3})])
	var seen := {}
	for _i in range(40):
		seen[texts(sp2.plan([ev("step", {"player": 0, "tile": 1}), ev("jailed", {"player": 0,
				"days": 3})]))[0]] = true
	check(not seen.has("理理在") and seen.has("理理不在") and p3.size() == 1, "破产的理理不算在场")
	# 同一刻两个人撞上：只说一个；中间隔一步就都说
	var same := sp.plan([ev("rolled", {"player": 0, "dice": [1, 1], "steps": 2}),
			ev("jailed", {"player": 0, "days": 3}), ev("jailed", {"player": 1, "days": 3})])
	check(texts(same).size() == 1, "同一刻只让一个人开口")
	var apart := sp.plan([ev("jailed", {"player": 0, "days": 3}), ev("step", {"player": 1,
			"tile": 2}),
			ev("jailed", {"player": 1, "days": 3})])
	check(texts(apart).size() == 2, "隔了一步就各说各的")
	# 优先级：性格时刻（20）>= 普通（10）；用同一刻的付高额租金 vs 被偷（同 10）看不出，换成破产 30 > 倒霉
	var pr := sp.plan([ev("collapse", {"player": 1, "house": 1, "tiles": [1]}), ev("bankrupt",
			{"player": 2, "creditor": -1})])
	check(texts(pr) == ["孔雀·自己破产"], "破产压过同一刻的其他台词（倒霉概率 0 不会说，换成别的事件也一样）")


func test_pairs_and_game_over() -> void:
	var g := new_game()
	var sp := speech_for(g, plain_files())
	var plan := sp.plan([ev("stolen", {"thief": 1, "victim": 0, "amount": 50})])
	var who: Array = []
	for u in plan[0]:
		who.append([u["player"], u["target"], u["event"]])
	check(plan[0].size() == 2 and who.has([0, 1, "stolen"]) and who.has([1, 0, "steal"]),
			"偷钱：小偷和被偷的人都说，各对对方")
	var over := sp.plan([ev("game_over", {"winner": 2})])
	var ids := {}
	for u in over[0]:
		ids[u["event"]] = true
	check(over[0].size() == 4 and ids.has("win") and ids.has("lose"), "游戏结束：赢的说赢，没破产的输家各说一句输")
	var over2 := sp.plan([ev("game_over", {"winner": -1})])
	check(texts(over2).is_empty(), "没有赢家（人类全破产）没人说话")


func test_chance_cooldown_recent() -> void:
	var g := new_game()
	var sp := speech_for(g, plain_files())
	# 概率 0 的事件不说话
	check(texts(sp.plan([ev("collapse", {"player": 0, "house": 1, "tiles": [1]})])).is_empty(),
			"概率 0 不说话")
	# 冷却：交好运 cooldown = 2 天
	var turn := func(day: int) -> Dictionary: return ev("turn_start", {"player": 0, "day": day})
	var a := sp.plan([turn.call(5), ev("antique", {"player": 0, "amount": 10})])
	var b := sp.plan([turn.call(6), ev("antique", {"player": 0, "amount": 10})])
	var c := sp.plan([turn.call(7), ev("antique", {"player": 0, "amount": 10})])
	check(texts(a).size() >= 1 and texts(b).size() == 0 and texts(c).size() == 1,
			"冷却 2 天：当天说，隔 1 天不说，隔 2 天又说")
	# 不重复：池子 4 句，最近 2 句不抽，所以连抽 3 次不会和前一次、前两次一样
	var lines := "# 来源：作者\n## 进巡捕房\n- 甲\n- 乙\n- 丙\n- 丁\n"
	var sp2 := speech_for(g, {"斐斐.txt": lines})
	var last: Array = []
	var ok := true
	for i in range(30):
		var t: String = texts(sp2.plan([ev("step", {"player": 0, "tile": 1}), ev("jailed",
				{"player": 0, "days": 3})]))[0]
		if last.has(t):
			ok = false
		last.append(t)
		if last.size() > 2:
			last.pop_front()
	check(ok, "最近说过的 2 句先不抽")
	# 池子比记忆还小：照样能说（不会卡住）
	var sp3 := speech_for(g, {"斐斐.txt": "# 来源：作者\n## 进巡捕房\n- 唯一\n"})
	var twice := 0
	for _i in range(3):
		twice += texts(sp3.plan([ev("step", {"player": 0, "tile": 1}), ev("jailed", {"player": 0,
				"days": 3})])).size()
	check(twice == 3, "只有一句也能连着说")
	# 不碰游戏的随机数
	var seed_before := g.rng.state
	sp2.plan([ev("step", {"player": 0, "tile": 1}), ev("jailed", {"player": 0, "days": 3})])
	check(g.rng.state == seed_before, "台词不消耗游戏的随机数")


func test_pester() -> void:
	var g := new_game()
	var sp := speech_for(g, plain_files({"孔雀": "## 被同一个人纠缠\n- 孔雀被缠\n"}))
	var o := offer(3, 2)
	var turn := func(day: int) -> Dictionary: return ev("turn_start", {"player": 3, "day": day})
	var answers: Array = []
	for day in [10, 11, 12]:
		var p := sp.plan([turn.call(day), ev("trade_proposed", {"player": 3, "offer": o}),
				ev("trade_rejected", {"player": 2, "offer": o})])
		answers.append(texts(p)[-1])
	check(answers == ["孔雀·拒绝交易", "孔雀·拒绝交易", "孔雀被缠"],
			"6 天内第 3 次提议被拒：说“被纠缠”而不是普通拒绝 %s" % str(answers))
	var p2 := sp.plan([turn.call(12), ev("trade_proposed", {"player": 3, "offer": o}),
			ev("trade_done", {"player": 3, "offer": o})])
	check(texts(p2)[-1] == "孔雀·接受交易", "答应了就说接受，不说被纠缠")
	var sp2 := speech_for(g, plain_files({"孔雀": "## 被同一个人纠缠\n- 孔雀被缠\n"}))
	var last := ""
	for day in [1, 9, 17]:
		last = texts(sp2.plan([turn.call(day), ev("trade_proposed", {"player": 3, "offer": o}),
				ev("trade_rejected", {"player": 2, "offer": o})]))[-1]
	check(last == "孔雀·拒绝交易", "隔得远的提议不算纠缠")


func test_start_only_one() -> void:
	var g := new_game()
	var sp := speech_for(g, plain_files())
	var plan := sp.plan([ev("turn_start", {"player": 0, "day": 1})])
	check(plan[0].size() == 1 and plan[0][0]["event"] == "game_start", "开局：4 个人里只有一个人说")
	check(sp.plan([ev("turn_start", {"player": 1, "day": 1})])[0].is_empty(),
			"只在第一个 turn_start 说开局")


# ───────────────────────── 规则层新事件 ─────────────────────────

func test_new_game_events() -> void:
	# 凑齐整条街：买下最后一块
	var g := new_game()
	var bj := tile_named(shanghai, "北京路1号")
	var group := str(shanghai.get_tile(bj).get("group", ""))
	var lots: Array = []
	for t in shanghai.tiles:
		if str(t["type"]) == "land" and str(t.get("group", "")) == group:
			lots.append(int(t["id"]))
	lots.sort()
	for i in range(lots.size() - 1):
		give(g, 0, lots[i])
	move(g, lots[-1] - 1, 1)
	check(g.pending.get("type", "") == "buy_land" and not has_event(g, "street_done"),
			"还没买下最后一块：没有凑齐事件")
	g.buy()
	check(has_event(g, "street_done"), "买下最后一块：street_done")
	var done: Dictionary = g.events.filter(
			func(e: Dictionary) -> bool: return e["type"] == "street_done")[0]
	check(done["player"] == 0 and done["group"] == group, "street_done 记着谁、哪条街")
	# 交易凑齐
	var g2 := new_game()
	for i in range(lots.size() - 1):
		give(g2, 0, lots[i])
	give(g2, 1, lots[-1])
	check(g2.propose_trade({"from": 0, "to": 1, "give": [], "get": [lots[-1]], "give_cash": 10,
			"get_cash": 0}) == "", "提议交易")
	g2.trade_answer(true)
	var d2: Array = g2.events.filter(func(e: Dictionary) -> bool: return e["type"] == "street_done")
	check(d2.size() == 1 and d2[0]["player"] == 0, "交易拿到最后一块也算凑齐")
	# 躲开大租：落点旁边就是对手的高租地
	var g3 := new_game()
	give(g3, 1, bj + 1)
	g3.players[0].cash = 0
	g3.players[0].deposit = 0
	move(g3, bj - 1, 1)
	var dodged: Array = g3.events.filter(func(e: Dictionary) -> bool: return e["type"] == "dodged")
	check(dodged.size() == 1 and dodged[0]["player"] == 0 and dodged[0]["owner"] == 1,
			"落点旁边是对手的高租地：dodged")
	var g4 := new_game()
	move(g4, bj - 1, 1)
	check(not has_event(g4, "dodged"), "旁边没有对手的地：没有 dodged")
	var g5 := new_game()
	give(g5, 1, bj)
	g5.players[0].cash = 0
	move(g5, bj - 1, 1)
	check(not has_event(g5, "dodged") and has_event(g5, "rent"), "落点自己要付租：不算躲开")
	# 事件不影响规则：同一个种子，两局的结果一样（dodged / street_done 不消耗随机数）
	var a := new_game(null, 4, {}, 11)
	var b := new_game(null, 4, {}, 11)
	for _i in range(60):
		if a.phase == "over":
			break
		AI.step(a)
		AI.step(b)
	check(a.snapshot() == b.snapshot(), "同一个种子的两局结果一样")


## 全 AI 打一阵：每一批事件都能算出台词，台词的人、表情、事件都对得上
func test_ai_game_speech() -> void:
	var data = runner.root.get_node("Data")
	var specs: Array = []
	for i in range(4):
		specs.append({"character": str(characters[i]["id"]), "human": false, "ai": "new_v2"})
	var g := Game.new()
	g.setup(shanghai, rules, cards_file, characters, specs, 21)
	g.start()
	var sp := Speech.new(data.lines, g)
	var said := 0
	var kinds := {}
	var bad := 0
	var guard := 0
	while g.phase != "over" and g.day < 40 and guard < 6000:
		guard += 1
		var batch := g.drain_events()
		var plan := sp.plan(batch)
		if plan.size() != batch.size():
			bad += 1
		for list in plan:
			for u in list:
				said += 1
				kinds[u["event"]] = true
				if not data.lines.moods.has(u["mood"]) or str(u["text"]) == "" \
						or not data.lines.event_names.has(u["event"]):
					bad += 1
		if not AI.step(g):
			break
	check(bad == 0, "AI 对局里每批事件都对得上台词")
	check(said > 20 and kinds.size() >= 6, "AI 对局里有不少人说话（%d 句，%d 种事件）：%s" % [said, kinds.size(),
			str(kinds.keys())])


## 真实的台词文件没写错，每个角色每个原版事件都有话说，事件表和代码用的事件对得上
func test_real_lines() -> void:
	var data = runner.root.get_node("Data")
	check(data.lines.errors.is_empty(), "data/lines 下的台词文件没有读不懂的行 %s" % str(data.lines.errors))
	for c in characters:
		var by_event: Dictionary = data.lines.lines_of(str(c["id"]), "front")
		for ev_name in ["付高额租金", "付少量钱", "交好运", "倒霉", "进巡捕房", "建成别墅", "得到施舍", "被偷", "偷到钱",
				"接受交易", "拒绝交易", "开局", "赢"]:
			check(by_event.has(ev_name) and not by_event[ev_name].is_empty(),
					"%s 有“%s”的台词" % [c["nickname"], ev_name])
	var ids := ["rent_big", "rent_small", "good_luck", "bad_luck", "jailed", "build_villa",
			"alms_get", "stolen", "steal",
			"trade_propose", "trade_accept", "trade_reject", "trade_counter", "lowball", "haggle",
			"mercy", "lead_relax", "spite", "slip", "pestered", "fav_street", "street_done",
			"auction_won", "dodged", "park", "game_start",
			"win", "lose", "self_bankrupt", "rival_bankrupt"]
	for id in ids:
		check(data.lines.event_names.has(id), "事件表里有 " + id)
	check(data.lines.event_names.size() == ids.size(), "事件表里没有代码用不到的事件")
