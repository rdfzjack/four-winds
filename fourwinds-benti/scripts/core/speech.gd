extends RefCounted
## 谁在什么时候对谁说什么（无画面，能无头测试）。
##
## 用法：画面每拿到一批事件（game.drain_events()）就调 plan(events)，返回和 events 一一对应的列表：
##   plan(events)[i] = 播放第 i 个事件时要冒的台词 [{player, event（事件 id）, text, mood, target, source}]
## 画面只负责显示。台词句子来自 LinesDb（台词文本文件），事件和规则在 data/lines/events.json。
##
## 规则：
##   - 同一刻（两个“一步”“一次掷骰”“一次交易回答”之间）只让一个人开口，撞上时按事件的 priority 取一个，
##     破产 > 性格时刻 > 普通台词。例外：偷钱时小偷和被偷的人可以同时说；对手破产时接手家产的人在破产者之后回一句；
##     游戏结束时赢的和输的各说各的。
##   - 性格时刻（AI 的 ai_note：被压价、讨价还价、放水让价、领先时放宽、落后时损人不利己、按错）
##     发生在回答交易的那一刻，替换普通的接受 / 拒绝 / 还价。
##   - 不是每件事都开口：事件的 chance（概率）和 cooldown（同一个人隔几天）；同一个人最近说过的几句先不抽。
##   - 随机数用自己的，不碰 game.rng（不影响对局结果，也不影响存档重放）。

const LinesDb = preload("res://scripts/core/lines_db.gd")

## AI 的 ai_note → 它对应的性格时刻事件（先匹配到的优先，顺序就是优先顺序）
const NOTE_EVENTS := [
	["spite", ["spite"]],
	["lowball", ["lowball"]],
	["slip", ["slip"]],
	["random_yes", ["slip"]],
	["haggle", ["haggle"]],
	["grace", ["lead_relax", "mercy"]],
	["mercy", ["mercy"]],
]
## 不改变“上一个是 ai_note”的事件：夹在 ai_note 和回答之间也不算打断
const TRANSPARENT := ["ai_note", "relation"]
## 这些事件开始新的“一刻”
const MOMENT_STARTS := ["turn_start", "rolled", "step", "trade_proposed", "trade_countered",
		"trade_done",
		"trade_rejected", "auction_start", "auction_bid", "auction_pass", "auction_sold", "game_over"]

var db: LinesDb
var game
var rng := RandomNumberGenerator.new()

var _day: int = 1
var _gone: Dictionary = {}        ## 已破产的玩家 -> true
var _recent: Dictionary = {}      ## 玩家 -> 最近说过的句子
var _last_day: Dictionary = {}    ## "玩家|事件" -> 上次说的那天
var _proposals: Array = []        ## 发起过的交易提议 [{from, to, day}]
var _countered: bool = false      ## 正在进行的交易是不是已经还过价
var _started: bool = false
var _notes: Array = []            ## 紧挨着的 ai_note：[{player, kind}]
var _moment: int = 0
var _cands: Array = []


func _init(p_db: LinesDb, p_game) -> void:
	db = p_db
	game = p_game
	rng.seed = int(p_game.seed_used) + 7919


## 一批事件 → 每个事件要冒的台词
func plan(events: Array) -> Array:
	_cands.clear()
	for i in range(events.size()):
		_scan(i, events)
		var t := str(events[i]["type"])
		if not TRANSPARENT.has(t):
			_notes.clear()
	var winners := _pick_winners()
	var out: Array = []
	for _i in range(events.size()):
		out.append([])
	for c in winners:
		var u := _speak(c)
		if not u.is_empty():
			out[int(c["i"])].append(u)
	return out


# ───────────────────────── 事件 → 候选台词 ─────────────────────────

func _scan(i: int, events: Array) -> void:
	var ev: Dictionary = events[i]
	var type := str(ev["type"])
	if MOMENT_STARTS.has(type):
		_moment += 1
	match type:
		"turn_start":
			_day = int(ev["day"])
			if not _started:
				_started = true
				_scan_start(i)
		"rent":
			var p := int(ev["player"])
			if str(ev["scale"]) == "big":
				_add(i, p, int(ev["owner"]), ["rent_big"])
			elif str(ev["scale"]) == "small":
				_add(i, p, int(ev["owner"]), ["rent_small"])
		"jailed":
			_add(i, int(ev["player"]), -1, ["jailed"])
		"built":
			if str(ev["kind"]) == "villa":
				_add(i, int(ev["player"]), -1, ["build_villa"])
		"antique":
			_add(i, int(ev["player"]), -1, ["good_luck"])
		"collapse", "cannot_afford":
			_add(i, int(ev["player"]), -1, ["bad_luck"])
		"card":
			var mood := _card_event(int(ev["card"]))
			if mood != "":
				_add(i, int(ev["player"]), -1, [mood])
		"stolen":
			var group := "stolen%d" % i
			_add(i, int(ev["victim"]), int(ev["thief"]), ["stolen"], group)
			_add(i, int(ev["thief"]), int(ev["victim"]), ["steal"], group)
		"alms":
			_add(i, int(ev["receiver"]), int(ev["giver"]), ["alms_get"])
		"bought":
			if _is_favorite(int(ev["player"]), int(ev["tile"])):
				_add(i, int(ev["player"]), -1, ["fav_street"])
		"street_done":
			_add(i, int(ev["player"]), -1, ["street_done"])
		"auction_sold":
			var buyer := int(ev["player"])
			var chain := ["fav_street", "auction_won"] if _is_favorite(buyer,
					int(ev["tile"])) else ["auction_won"]
			_add(i, buyer, int(ev["seller"]), chain)
		"status":
			if str(ev["kind"]) == "park":
				_add(i, int(ev["player"]), -1, ["park"])
		"dodged":
			_add(i, int(ev["player"]), -1, ["dodged"])
		"ai_note":
			_notes.append({"player": int(ev["player"]), "kind": str(ev["kind"])})
		"trade_proposed", "trade_countered", "trade_done", "trade_rejected":
			_scan_trade(i, ev)
		"bankrupt":
			var who := int(ev["player"])
			var heir := int(ev["creditor"])
			var group := "bankrupt%d" % i
			_add(i, who, heir, ["self_bankrupt"], group)
			if heir >= 0:
				_add(i, heir, who, ["rival_bankrupt"], group)
			_gone[who] = true
		"game_over":
			var winner := int(ev["winner"])
			if winner >= 0:
				_add(i, winner, -1, ["win"], "game_over")
				for p in game.players:
					if p.index != winner and not _gone.has(p.index):
						_add(i, p.index, winner, ["lose"], "game_over")


## 开局：每个人都有一句候选，同一刻只让一个人说
func _scan_start(i: int) -> void:
	for p in game.players:
		var others: Array = []
		for q in game.players:
			if q.index != p.index and not _gone.has(q.index):
				others.append(q.index)
		var target: int = others[rng.randi() % others.size()] if not others.is_empty() else -1
		_add(i, p.index, target, ["game_start"])


func _scan_trade(i: int, ev: Dictionary) -> void:
	var type := str(ev["type"])
	var o: Dictionary = ev["offer"]
	var from := int(o["from"])
	var to := int(o["to"])
	if type == "trade_proposed":
		_countered = false
		_proposals.append({"from": from, "to": to, "day": _day})
		_add(i, from, to, ["trade_propose"])
		return
	# 回答：谁答的？还价以前是对方，还价以后是发起人
	var answerer := to
	var base := "trade_reject"
	match type:
		"trade_countered":
			base = "trade_counter"
		"trade_done":
			base = "trade_accept"
			answerer = from if _countered else to
		"trade_rejected":
			answerer = int(ev["player"])
	var asked := to if answerer == from else from
	var chain := _moment_events(answerer)
	if base != "trade_accept" and answerer == to and not _countered and _pestered(from, to):
		chain.append("pestered")
	chain.append(base)
	_add(i, answerer, asked, chain)
	_countered = type == "trade_countered"


## 紧挨着的 ai_note 对应的性格时刻事件（按 NOTE_EVENTS 的顺序）
func _moment_events(pi: int) -> Array:
	var out: Array = []
	for pair in NOTE_EVENTS:
		for n in _notes:
			if int(n["player"]) == pi and str(n["kind"]) == pair[0]:
				for e in pair[1]:
					if not out.has(e):
						out.append(e)
	return out


## from 在最近几天里向 to 提议了多少次（含这次）够不够“纠缠”
func _pestered(from: int, to: int) -> bool:
	var window := int(db.settings.get("pester_window_days", 6))
	var need := int(db.settings.get("pester_count", 3))
	var n := 0
	for pr in _proposals:
		if int(pr["from"]) == from and int(pr["to"]) == to and _day - int(pr["day"]) <= window:
			n += 1
	return n >= need


## 机会卡的钱是正还是负 → 交好运 / 倒霉；没有金额的卡不说话
func _card_event(card_id: int) -> String:
	for c in game.cards:
		if int(c["id"]) != card_id:
			continue
		for e in c.get("effects", []):
			if str(e["op"]) == "money":
				return "good_luck" if int(e["amount"]) > 0 else "bad_luck"
	return ""


func _is_favorite(pi: int, tile: int) -> bool:
	var liked: Array = game.board.favorites.get(game.players[pi].character, [])
	return liked.has(str(game.board.get_tile(tile).get("group", "")))


## 加一个候选。chain = 事件 id 列表（前面的优先，句子池空的跳过）。这个人在这些事件下都没有可抽的句子就不加。
func _add(i: int, speaker: int, target: int, chain: Array, group: String = "") -> void:
	var ctx := _ctx(speaker, target)
	var usable: Array = []
	for e in chain:
		if not db.event_names.has(e):
			continue  # 事件表里没有这个事件（data/lines/events.json 缺了），当没有台词
		var pool := db.pool(game.players[speaker].character, game.players[speaker].form,
				db.event_names[e], ctx)
		if not pool.is_empty():
			usable.append(e)
	if usable.is_empty():
		return
	_cands.append({"i": i, "moment": _moment, "speaker": speaker, "target": target, "chain": usable,
			"priority": int(db.events[db.event_names[usable[0]]]["priority"]),
			"group": group if group != "" else "c%d" % _cands.size(), "tie": rng.randf(), "ctx": ctx})


func _ctx(speaker: int, target: int) -> Dictionary:
	var present: Array = []
	for p in game.players:
		if p.index != speaker and not _gone.has(p.index):
			present.append(p.character)
	var ctx := {"present": present, "map": game.board.id, "target": "", "target_form": ""}
	if target >= 0:
		ctx["target"] = game.players[target].character
		ctx["target_form"] = game.players[target].form
	return ctx


# ───────────────────────── 同一刻只留一个 ─────────────────────────

## 每一刻里留下优先级最高的那一组（同一组的人可以一起说）；同分取随机数小的
func _pick_winners() -> Array:
	var best: Dictionary = {}  ## 刻 -> {group, priority, tie}
	for c in _cands:
		var b: Dictionary = best.get(c["moment"], {})
		if b.is_empty() or c["priority"] > b["priority"] or (c["priority"] == b["priority"]
				and c["tie"] < b["tie"]):
			best[c["moment"]] = {"group": c["group"], "priority": c["priority"], "tie": c["tie"]}
	var out: Array = []
	for c in _cands:
		if best[c["moment"]]["group"] == c["group"]:
			out.append(c)
	return out


# ───────────────────────── 抽句子 ─────────────────────────

## 掷概率、查冷却、抽一句。不说话返回空字典
func _speak(c: Dictionary) -> Dictionary:
	var pi := int(c["speaker"])
	var p = game.players[pi]
	var event_id := str(c["chain"][0])
	var name: String = db.event_names[event_id]
	var def: Dictionary = db.events[name]
	var key := "%d|%s" % [pi, event_id]
	var cooldown := int(def.get("cooldown", 0))
	if cooldown > 0 and _last_day.has(key) and _day - int(_last_day[key]) < cooldown:
		return {}
	if rng.randf() * 100.0 >= float(def.get("chance", 100)):
		return {}
	var pool := db.pool(p.character, p.form, name, c["ctx"])
	var recent: Array = _recent.get(pi, [])
	var fresh: Array = []
	for entry in pool:
		if not recent.has(entry["line"]["text"]):
			fresh.append(entry)
	if not fresh.is_empty():
		pool = fresh
	var line: Dictionary = _weighted(pool)["line"]
	recent.append(line["text"])
	while recent.size() > int(db.settings.get("recent_memory", 3)):
		recent.pop_front()
	_recent[pi] = recent
	_last_day[key] = _day
	var mood: String = str(line["mood"]) if str(line["mood"]) != "" else str(def["mood"])
	return {"player": pi, "event": event_id, "text": line["text"], "mood": mood,
			"target": int(c["target"]), "source": line["source"]}


func _weighted(pool: Array) -> Dictionary:
	var total := 0.0
	for e in pool:
		total += float(e["weight"])
	var r := rng.randf() * total
	for e in pool:
		r -= float(e["weight"])
		if r <= 0.0:
			return e
	return pool[pool.size() - 1]
