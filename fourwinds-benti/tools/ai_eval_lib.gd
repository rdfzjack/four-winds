extends RefCounted
## “AI 对 AI”评测：跑 N 局全 AI 对局，按座位统计胜负和“像不像这个角色”的数字。
## 命令行入口是 tools/ai_eval.gd（用法写在那里），无头测试也直接用这个脚本。
##
## 每个座位 = {character: 角色 id, form: front / back, ai: AI 版本}。
## 第 k 局把座位顺序轮转 k 位（谁先走轮着来），统计仍按座位记。
## 初始好感按座位编号配（座位 a 对座位 b），开局时换算成玩家编号。
## 指标见 docs/ai_design.md 的 E 节。

const JsonUtil = preload("res://scripts/core/json_util.gd")
const Board = preload("res://scripts/core/board.gd")
const Game = preload("res://scripts/core/game.gd")
const AI = preload("res://scripts/core/ai.gd")
const AiProfiles = preload("res://scripts/core/ai_profiles.gd")

## 被某人拒绝后几天内又向他提议，算一次“纠缠”
const PESTER_DAYS := 5

var games := 40
var max_days := 300
var seed_start := 1
var map_id := "shanghai"
var crossroads := ""  ## 空 = 按地图；"random" = 所有路口随机（同主界面的“路口全部随机”）
var seats: Array = []           ## [{character, form, ai}]
var default_relation := 0       ## 所有人之间的初始好感
var pair_relations: Dictionary = {}  ## Vector2i(座位 a, 座位 b) -> a 对 b 的初始好感
var overrides: Dictionary = {}  ## 临时改的 AI 参数：参数名（或“角色/形态:参数名”）-> 值

var board := Board.new()
var rules: Dictionary = {}
var cards_file: Dictionary = {}
var characters: Array = []
var top_street := ""  ## 最值钱的街（地价系数之和 × 能盖的最大房子的租金单价最大），统计谁凑齐了它
var _groups: Dictionary = {}  ## 街（group）-> [地块]


## 读数据、检查座位。返回错误列表，空 = 可以跑。
func prepare() -> Array:
	var errors: Array = []
	rules = JsonUtil.load_dict("res://data/rules.json", errors)
	cards_file = JsonUtil.load_dict("res://data/cards/chance.json", errors)
	characters = JsonUtil.load_dict("res://data/characters.json", errors).get("characters", [])
	var path := "res://data/maps/%s.json" % map_id
	errors.append_array(board.load_from(JsonUtil.load_dict(path, errors)))
	var ids := characters.map(func(c: Dictionary) -> String: return str(c["id"]))
	if seats.size() < 2 or seats.size() > int(rules.get("max_players", 4)):
		errors.append("座位数应该是 2 到 %d" % int(rules.get("max_players", 4)))
	for s in seats:
		if not ids.has(s["character"]):
			errors.append("没有角色 %s（可选：%s）" % [s["character"], ", ".join(ids)])
		if not AiProfiles.FORMS.has(s["form"]):
			errors.append("没有形态 %s（可选：%s）" % [s["form"], ", ".join(AiProfiles.FORMS)])
		if not AI.READY.has(s["ai"]):
			errors.append("AI 版本 %s 还没实现（现在能用：%s）" % [s["ai"], ", ".join(AI.READY)])
	AiProfiles.ensure_loaded()
	for k in AiProfiles.table:
		for name in overrides:
			# "角色/形态:参数" 只改这一个条目（例如 eric/front:value_horizon_days），否则改全部
			var parts := str(name).split(":")
			if parts.size() == 2:
				if parts[0] == k or (parts[0] == "standard" and k == ""):
					AiProfiles.table[k][parts[1]] = overrides[name]
			else:
				AiProfiles.table[k][name] = overrides[name]
	_groups.clear()
	var pct_sum := {}
	for t in board.tiles:
		if t["type"] == "land" and not t.has("site"):
			var key := str(t.get("group", ""))
			_groups.get_or_add(key, []).append(int(t["id"]))
			pct_sum[key] = int(pct_sum.get(key, 0)) + int(t.get("price_pct", 100))
	var best_value := -1
	for key in _groups:
		var unit := 0
		for lv in rules.get("houses", {}).get("levels", []):
			if int(lv["lots"]) <= _groups[key].size():
				unit = maxi(unit, int(board.prices.get("rent", {}).get(str(lv["rent"]), 0)))
		if int(pct_sum[key]) * unit > best_value:
			best_value = int(pct_sum[key]) * unit
			top_street = key
	return errors


## 座位的显示名：角色/形态/AI 版本
static func seat_label(s: Dictionary) -> String:
	return "%s/%s/%s" % [s["character"], s["form"], s["ai"]]


## 解析 "david:back:original" 这种写法（形态、AI 版本可省略）
static func parse_seat(text: String) -> Dictionary:
	var parts := text.split(":")
	return {
		"character": parts[0],
		"form": parts[1] if parts.size() > 1 and parts[1] != "" else "front",
		"ai": parts[2] if parts.size() > 2 and parts[2] != "" else "original",
	}


## 跑完全部对局，返回报告（见 format_report）
func run() -> Dictionary:
	var per_seat: Array = []
	for i in range(seats.size()):
		per_seat.append({})
	var totals := {"games": 0, "finished": 0, "finish_days": 0, "first_bankrupt_games": 0,
		"first_bankrupt_days": 0, "first_street_games": 0, "first_street_days": 0, "bad": []}
	for k in range(games):
		_play_one(k, per_seat, totals)
	return {"per_seat": per_seat, "totals": totals}


func _play_one(k: int, per_seat: Array, totals: Dictionary) -> void:
	var n := seats.size()
	# order[玩家编号] = 座位编号
	var order: Array = []
	for i in range(n):
		order.append((i + k) % n)
	var player_of := {}
	for pi in range(n):
		player_of[order[pi]] = pi
	var specs: Array = []
	for pi in range(n):
		var seat: Dictionary = seats[order[pi]]
		var rel := {}
		for other in range(n):
			if other == order[pi]:
				continue
			var v := int(pair_relations.get(Vector2i(order[pi], other), default_relation))
			if v != 0:
				rel[player_of[other]] = v
		specs.append({"character": seat["character"], "form": seat["form"], "ai": seat["ai"],
			"human": false, "relations": rel})
	var g := Game.new()
	var errors := g.setup(board, rules, cards_file, characters, specs, seed_start + k)
	if not errors.is_empty():
		totals["bad"].append("第 %d 局开不了：%s" % [k + 1, str(errors)])
		return
	g.crossroad_override = crossroads
	g.start()
	totals["games"] += 1
	var st: Array = []  ## 玩家编号 -> 这局的计数
	for pi in range(n):
		st.append({"streets": {}})
	var first_bankrupt := -1
	var first_street := -1
	var last_refusal := {}  ## Vector2i(被拒的人, 拒绝的人) -> 第几天
	var steps := 0
	while g.phase != "over" and g.day <= max_days:
		steps += 1
		if steps > max_days * 1000:
			totals["bad"].append("第 %d 局步数太多，可能死循环（第 %d 天）" % [k + 1, g.day])
			break
		var actor: int = g.actor()
		var pending_type := str(g.pending.get("type", "")) if g.phase == "pending" else ""
		if pending_type == "buy_land" or pending_type == "buy_company":
			_add(st[actor], "offer_" + pending_type.trim_prefix("buy_"))
		if not AI.step(g):
			totals["bad"].append("第 %d 局 AI 没有动作，卡在 %s" % [k + 1, g.phase])
			break
		for ev in g.drain_events():
			var who := int(ev.get("player", actor))
			match str(ev["type"]):
				"bought":
					var kind := "land" if g.board.get_tile(int(ev["tile"]))["type"] == "land" else "company"
					_add(st[who], "bought_" + kind)
				"built":
					_add(st[who], "built")
				"trade_proposed":
					_add(st[who], "trade_proposed")
					# 被这个人拒绝后 PESTER_DAYS 天内又向他提议 = 纠缠
					var to := int(ev["offer"]["to"])
					if g.day - int(last_refusal.get(Vector2i(who, to), -9999)) <= PESTER_DAYS:
						_add(st[who], "pester")
				"trade_countered":
					_add(st[who], "trade_countered")
				"trade_rejected":
					_add(st[who], "trade_rejected")
					var o: Dictionary = ev["offer"]
					var refused: int = o["from"] if who == int(o["to"]) else o["to"]
					last_refusal[Vector2i(refused, who)] = g.day
				"trade_done":
					# who 是发起人；接受的人是这一步做决定的人
					_add(st[who], "trade_proposed_done")
					if pending_type == "trade":
						_add(st[actor], "trade_accepted")
				"auction_bid":
					_add(st[who], "auction_bids")
					_add(st[who], "auction_bid_sum", int(ev["price"]))
				"auction_sold":
					_add(st[who], "auction_won")
				"ai_note":
					_add(st[who], "note_" + str(ev["kind"]))
				"bankrupt":
					st[who]["bankrupt_day"] = g.day
					if first_bankrupt < 0:
						first_bankrupt = g.day
				"turn_start":
					_add(st[who], "turns")
					_add(st[who], "cash", g.players[who].cash)
					_add(st[who], "deposit", g.players[who].deposit)
					if first_bankrupt < 0:
						var got := _mark_streets(g, st)
						if got and first_street < 0:
							first_street = g.day
	if g.phase == "over":
		totals["finished"] += 1
		totals["finish_days"] += g.day
	if first_bankrupt >= 0:
		totals["first_bankrupt_games"] += 1
		totals["first_bankrupt_days"] += first_bankrupt
	if first_street >= 0:
		totals["first_street_games"] += 1
		totals["first_street_days"] += first_street
	var leader := _leader(g)
	for pi in range(n):
		var s: Dictionary = per_seat[order[pi]]
		var mine: Dictionary = st[pi]
		_add(s, "games")
		if g.phase == "over" and g.winner == pi:
			_add(s, "wins")
		elif g.phase != "over" and leader == pi:
			_add(s, "leads")
		if mine.has("bankrupt_day"):
			_add(s, "bankrupt")
			_add(s, "bankrupt_days", int(mine["bankrupt_day"]))
		_add(s, "streets", mine["streets"].size())
		if mine["streets"].has(top_street):
			_add(s, "top_street")
		for key in mine:
			if key != "streets" and key != "bankrupt_day":
				_add(s, key, int(mine[key]))
		# 对局结束时的关系值：我给别人的、别人给我的（各自取平均）
		for other in range(n):
			if other != pi:
				_add(s, "rel_given", g.relation(pi, other))
				_add(s, "rel_got", g.relation(other, pi))
				_add(s, "rel_pairs")


## 记下每人现在整条街归自己的 group。返回这次有没有人凑齐任何一条
func _mark_streets(g: Game, st: Array) -> bool:
	var any := false
	for group in _groups:
		var tiles: Array = _groups[group]
		var o := g.owner_of(tiles[0])
		if o < 0:
			continue
		var full := true
		for t in tiles:
			if g.owner_of(t) != o:
				full = false
				break
		if full:
			st[o]["streets"][group] = true
			any = true
	return any


## 没打完的局：现在总资产最多的人
func _leader(g: Game) -> int:
	var best := -1
	var best_value := -1
	for p in g.alive_players():
		var v: int = g.total_assets(p.index)
		if v > best_value:
			best = p.index
			best_value = v
	return best


static func _add(d: Dictionary, key: String, amount: int = 1) -> void:
	d[key] = int(d.get(key, 0)) + amount


static func _avg(a: int, b: int) -> String:
	return "-" if b <= 0 else "%.1f" % (float(a) / b)


static func _pct(a: int, b: int) -> String:
	return "-" if b <= 0 else "%d%%" % roundi(100.0 * a / b)


## 把报告排成文字
func format_report(report: Dictionary) -> String:
	var t: Dictionary = report["totals"]
	var lines: Array = []
	lines.append("地图 %s · %d 局 · 每局最多 %d 天 · 种子 %d 起 · 初始好感 %d%s%s" % [
		map_id, t["games"], max_days, seed_start, default_relation,
		"" if pair_relations.is_empty() else "（另有 %d 对单独配置）" % pair_relations.size(),
		("" if overrides.is_empty() else " · 临时参数 %s" % str(overrides))
				+ (" · 路口全部随机" if crossroads == "random" else "")])
	lines.append("打完 %d/%d 局，平均第 %s 天打完；第一次破产平均第 %s 天（%d 局有人破产）；第一次有人凑齐整条街平均第 %s 天（%d 局）" % [
		t["finished"], t["games"], _avg(t["finish_days"], t["finished"]),
		_avg(t["first_bankrupt_days"], t["first_bankrupt_games"]), t["first_bankrupt_games"],
		_avg(t["first_street_days"], t["first_street_games"]), t["first_street_games"]])
	for b in t["bad"]:
		lines.append("问题：" + str(b))
	lines.append("")
	lines.append("| 座位 | 胜 | 超时领先 | 破产（平均天） | 整条街/局 | 凑齐%s | 买地率 | 买企业率 "
			% top_street + "| 建房/局 | 平均现金 / 存款 |")
	lines.append("|---|---|---|---|---|---|---|---|---|---|")
	for i in range(seats.size()):
		var s: Dictionary = report["per_seat"][i]
		var n := int(s.get("games", 0))
		var turns := int(s.get("turns", 0))
		lines.append("| %s | %s | %s | %d（%s） | %s | %s | %s | %s | %s | %d / %d |" % [
			seat_label(seats[i]), _pct(s.get("wins", 0), n), _pct(s.get("leads", 0), n),
			s.get("bankrupt", 0), _avg(s.get("bankrupt_days", 0), s.get("bankrupt", 0)),
			_avg(s.get("streets", 0), n), _pct(s.get("top_street", 0), n),
			_pct(s.get("bought_land", 0), s.get("offer_land", 0)),
			_pct(s.get("bought_company", 0), s.get("offer_company", 0)),
			_avg(s.get("built", 0), n),
			int(s.get("cash", 0)) / maxi(1, turns), int(s.get("deposit", 0)) / maxi(1, turns)])
	lines.append("")
	lines.append("| 座位 | 交易发起/局 | 发起成交 | 接受/局 | 拒绝/局 | 还价/局 "
			+ "| 拍卖出价次数 / 平均出价 / 拍得 | 放水/局 | 按错/局 | 结束时好感（给出 / 收到） |")
	lines.append("|---|---|---|---|---|---|---|---|---|---|")
	for i in range(seats.size()):
		var s: Dictionary = report["per_seat"][i]
		var n := int(s.get("games", 0))
		lines.append("| %s | %s | %s | %s | %s | %s | %d / %s / %d | %s | %s | %s / %s |" % [
			seat_label(seats[i]), _avg(s.get("trade_proposed", 0), n),
			_pct(s.get("trade_proposed_done", 0), s.get("trade_proposed", 0)),
			_avg(s.get("trade_accepted", 0), n), _avg(s.get("trade_rejected", 0), n),
			_avg(s.get("trade_countered", 0), n),
			s.get("auction_bids", 0), _avg(s.get("auction_bid_sum", 0), s.get("auction_bids", 0)),
			s.get("auction_won", 0), _avg(s.get("note_mercy", 0), n), _avg(s.get("note_slip", 0), n),
			_avg(s.get("rel_given", 0), s.get("rel_pairs", 0)),
			_avg(s.get("rel_got", 0), s.get("rel_pairs", 0))])
	lines.append("")
	lines.append("性格动作（每局次数）：")
	for i in range(seats.size()):
		var s: Dictionary = report["per_seat"][i]
		var n := int(s.get("games", 0))
		var parts: Array = ["被拒后 %d 天内又找同一人 %s" % [PESTER_DAYS, _avg(s.get("pester", 0), n)]]
		var keys: Array = s.keys().filter(func(k: String) -> bool: return k.begins_with("note_"))
		keys.sort()
		for k in keys:
			parts.append("%s %s" % [k.trim_prefix("note_"), _avg(s[k], n)])
		lines.append("- %s：%s" % [seat_label(seats[i]), "，".join(parts)])
	return "\n".join(lines)
