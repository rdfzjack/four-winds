extends SceneTree
## 主线关卡体检：每一关让 AI 替玩家打 N 局（对手按关卡设置），汇总：结果分布、平均天数、
## 哪些格子几乎没人走（路口把人引到别处去了）、企业有没有被买。用来在标定难度前先发现“地图 / 设置本身的问题”。
##   godot --headless --script res://tools/campaign_audit.gd -- [每关局数，默认 6] [角色 id:关卡序号，如 david:0，默认全部] [random|choice 强行覆盖路口方式]
## 数字只是“AI 当玩家”的参考，不等于真人的难度。

const Game = preload("res://scripts/core/game.gd")
const AI = preload("res://scripts/core/ai.gd")
const Scenario = preload("res://scripts/core/scenario.gd")

const MAX_STEPS := 4000

var _done := false
var args_crossroad := ""  ## 第 3 个参数：random / choice，强行覆盖所有关的路口方式（对比用）


func _process(_delta: float) -> bool:
	if _done:
		return false
	_done = true
	var data = root.get_node("Data")
	var args := OS.get_cmdline_user_args()
	var games := int(args[0]) if args.size() > 0 else 6
	var only: String = args[1] if args.size() > 1 else ""
	args_crossroad = args[2] if args.size() > 2 else ""
	for cid in data.campaigns:
		var stages: Array = data.stages_of(cid)
		for i in range(stages.size()):
			if only != "" and only != "%s:%d" % [cid, i]:
				continue
			_audit(data, stages[i], games)
	quit(0)
	return false


func _audit(data, stage: Dictionary, games: int) -> void:
	var board = data.maps[str(stage["map"])]
	var results := {"won": 0, "lost": 0, "none": 0}
	var reasons := {}
	var days_sum := 0
	var visits := {}
	var total_steps := 0
	var companies_owned := 0
	var company_count := 0
	for t in board.tiles:
		if t["type"] == "company" and not t.has("site"):
			company_count += 1
	for k in range(games):
		var sc := Scenario.new(stage)
		var g := Game.new()
		g.setup(board, data.rules, {"cards": data.cards, "special_events": data.special_events},
				data.all_characters(), sc.specs(), 1000 + k)
		g.scenario = sc
		sc.apply(g)
		if args_crossroad != "":
			g.crossroad_override = args_crossroad
		g.players[sc.player_seat].human = false
		g.players[sc.player_seat].ai = "new_v2"
		g.start()
		var n := 0
		while g.phase != "over" and n < MAX_STEPS and AI.step(g):
			n += 1
			for e in g.drain_events():
				if str(e["type"]) == "step":
					var s: int = board.site(int(e["tile"]))
					visits[s] = int(visits.get(s, 0)) + 1
					total_steps += 1
		days_sum += g.day
		var r := sc.result if g.phase == "over" else "none"
		results[r] += 1
		if r != "none":
			reasons[sc.reason] = int(reasons.get(sc.reason, 0)) + 1
		for t in g.props:
			if board.get_tile(t)["type"] == "company" and g.owner_of(t) >= 0:
				companies_owned += 1
	# 冷门格子：被走到的次数不到平均的 1/4（地、企业的正格）
	var kinds := 0
	var sum := 0
	for t in board.tiles:
		if (t["type"] == "land" or t["type"] == "company") and not t.has("site"):
			kinds += 1
			sum += int(visits.get(int(t["id"]), 0))
	var mean := float(sum) / maxf(1.0, float(kinds))
	var cold: Array = []
	var cold_companies: Array = []
	for t in board.tiles:
		if (t["type"] == "land" or t["type"] == "company") and not t.has("site") \
				and float(visits.get(int(t["id"]), 0)) < mean * 0.25:
			cold.append(int(t["id"]))
			if t["type"] == "company":
				cold_companies.append(str(t.get("name", "")))
	print("%s [%s] %d 局：赢 %d / 输 %d / 打不完(%d 步内) %d；平均第 %d 天；冷门地块 %d / %d 块%s；企业局末被买 %s" % [
			str(stage["id"]), board.display_name, games, results["won"], results["lost"], MAX_STEPS,
			results["none"], days_sum / games, cold.size(), kinds,
			("，其中企业 " + str(cold_companies)) if not cold_companies.is_empty() else "",
			("%d%%" % (companies_owned * 100 / maxi(1, company_count * games))) if company_count > 0 else "无企业"])
	if not reasons.is_empty():
		print("    结果原因：%s" % str(reasons))
