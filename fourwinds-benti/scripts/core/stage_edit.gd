extends RefCounted
## 关卡数据的编辑（简介页的调试面板用：增减对手、给谁送哪些地产 / 企业）。只改关卡字典，不碰画面，能无头测试。
## 改完的字典仍然是合法的关卡（Scenario.validate 能过）；牵涉到被删座位的胜负条件会自动处理。

const PLAYER_KEY := "player"

## 能加的条件类型（顺序就是界面下拉的顺序）和界面上的名字
const COND_TYPES := ["bankrupt", "assets_at_least", "days_over", "build_house", "control_street",
		"control_industry", "own_lots_pct", "richest_after", "not_richest_after"]
const COND_LABELS := {
	"bankrupt": "某人破产（击败）", "assets_at_least": "总资产达到", "days_over": "超过多少天（限时）",
	"build_house": "建成某种房子", "control_street": "凑齐一条街",
	"control_industry": "控制一个行业的全部企业", "own_lots_pct": "拥有全图一定比例的地",
	"richest_after": "限时到期时总资产第一", "not_richest_after": "限时到期时总资产不是第一",
}
const HOUSE_KINDS := {"flat": "平房", "hotel": "旅社", "super_hotel": "旅馆", "floor": "小洋楼",
		"super_floor": "花园洋房", "villa": "别墅"}


## 加一个对手（放在最后）。成功返回 ""，否则返回原因。max_players 是 rules.json 的上限。
static func add_seat(stage: Dictionary, character: String, ai: String, cash: int, deposit: int,
		max_players: int) -> String:
	var seats: Array = stage["seats"]
	if seats.size() >= max_players:
		return "座位已满（最多 %d 个，rules.json 的 max_players）" % max_players
	for s in seats:
		if str(s.get("character", "")) == character:
			return "这个角色已经在这一关里了"
	seats.append({"character": character, "ai": ai, "cash": cash, "deposit": deposit})
	return ""


## 删一个对手（不能删玩家，至少剩两个座位）。涉及他的条件：who 里去掉他、后面的座位号前移；
## who 空了的条件删掉；胜 / 负条件列表空了就补默认（胜：击败所有对手；负：玩家破产）。
static func remove_seat(stage: Dictionary, index: int) -> String:
	var seats: Array = stage["seats"]
	if index < 0 or index >= seats.size():
		return "没有这个座位"
	if bool(seats[index].get(PLAYER_KEY, false)):
		return "不能删玩家自己"
	if seats.size() <= 2:
		return "至少要有一个对手"
	seats.remove_at(index)
	for key in ["win", "lose"]:
		var kept: Array = []
		for c in stage.get(key, []):
			if _remap_cond(c, index):
				kept.append(c)
		stage[key] = kept
	if stage["win"].is_empty():
		stage["win"] = [{"type": "bankrupt", "who": "others", "mode": "all"}]
	if stage["lose"].is_empty():
		stage["lose"] = [{"type": "bankrupt", "who": "player"}]
	return ""


## 条件里的 who 按“删掉座位 removed”修正。条件还有意义返回 true，who 空了返回 false
static func _remap_cond(c: Dictionary, removed: int) -> bool:
	if not c.has("who"):
		return true
	var who = c["who"]
	if typeof(who) == TYPE_STRING:
		return true
	if typeof(who) == TYPE_ARRAY:
		var out: Array = []
		for x in who:
			var i := int(x)
			if i == removed:
				continue
			out.append(i - 1 if i > removed else i)
		c["who"] = out
		return not out.is_empty()
	var i := int(who)
	if i == removed:
		return false
	c["who"] = i - 1 if i > removed else i
	return true


## 座位 seat 的所有预置格子（地和企业；房子占的地也算）
static func seat_tiles(seat: Dictionary) -> Array:
	var out: Array = []
	for e in seat.get("props", []):
		if e.has("tiles"):
			for t in e["tiles"]:
				out.append(int(t))
		else:
			out.append(int(e.get("tile", -1)))
	return out


## 把 tiles 送给座位 index。已经在别人名下的先从他那里拿走（含他在这些地上盖的房子）；已经是自己的跳过。
static func grant(stage: Dictionary, index: int, tiles: Array) -> void:
	var seats: Array = stage["seats"]
	for t in tiles:
		var tile := int(t)
		for i in range(seats.size()):
			if i != index and seat_tiles(seats[i]).has(tile):
				revoke(stage, i, tile)
		if seat_tiles(seats[index]).has(tile):
			continue
		if not seats[index].has("props"):
			seats[index]["props"] = []
		seats[index]["props"].append({"tile": tile})


## 从座位 index 拿走 tile；如果它是预置房子的一部分，整栋预置一起去掉
static func revoke(stage: Dictionary, index: int, tile: int) -> void:
	var seat: Dictionary = stage["seats"][index]
	var kept: Array = []
	for e in seat.get("props", []):
		var hit := false
		if e.has("tiles"):
			for t in e["tiles"]:
				hit = hit or int(t) == tile
		else:
			hit = int(e.get("tile", -1)) == tile
		if not hit:
			kept.append(e)
	seat["props"] = kept
	if kept.is_empty():
		seat.erase("props")


# ───────────────────────── 目标（胜 / 负条件）的编辑 ─────────────────────────

## 一个类型的默认条件（加条件时用）。board 用来挑默认的街 / 行业
static func default_condition(type: String, board) -> Dictionary:
	match type:
		"bankrupt":
			return {"type": "bankrupt", "who": "others", "mode": "all"}
		"assets_at_least":
			return {"type": "assets_at_least", "who": "player", "amount": 2000}
		"days_over":
			return {"type": "days_over", "days": 30}
		"build_house":
			return {"type": "build_house", "who": "player", "kind": "villa", "count": 1}
		"control_street":
			var groups: Array = board.groups.keys() if board != null else []
			var g: String = str(groups[0]) if not groups.is_empty() else ""
			return {"type": "control_street", "who": "player", "group": g}
		"control_industry":
			var industry := ""
			if board != null:
				for t in board.tiles:
					if str(t["type"]) == "company" and not t.has("site"):
						industry = str(t.get("industry", ""))
						break
			return {"type": "control_industry", "who": "player", "industry": industry}
		"own_lots_pct":
			return {"type": "own_lots_pct", "who": "player", "pct": 40}
		"richest_after":
			return {"type": "richest_after", "who": "player", "days": 100}
		"not_richest_after":
			return {"type": "not_richest_after", "who": "player", "days": 100}
	return {}


## 加一个条件到 stage[key]（"win" / "lose"）
static func add_condition(stage: Dictionary, key: String, cond: Dictionary) -> void:
	if not stage.has(key):
		stage[key] = []
	stage[key].append(cond)


## 删 stage[key] 的第 index 个条件；胜 / 负条件至少留一个。成功返回 ""，否则原因
static func remove_condition(stage: Dictionary, key: String, index: int) -> String:
	var list: Array = stage.get(key, [])
	if index < 0 or index >= list.size():
		return "没有这个条件"
	if list.size() <= 1:
		return "至少要留一个条件"
	list.remove_at(index)
	return ""


## “谁”的下拉选项：你、任意一个对手、所有对手、每个对手。names 是每个座位的名字。
## 返回 [{label, who, mode}]（mode 只有对手组才有意义）
static func who_choices(stage: Dictionary, names: Array) -> Array:
	var out: Array = [{"label": "你", "who": "player", "mode": ""},
			{"label": "任意一个对手", "who": "others", "mode": "any"},
			{"label": "所有对手（都要）", "who": "others", "mode": "all"}]
	for i in range(stage["seats"].size()):
		if not bool(stage["seats"][i].get(PLAYER_KEY, false)):
			out.append({"label": str(names[i]), "who": i, "mode": ""})
	return out


## 条件 c 现在对应 choices 里的第几项（找不到返回 0）
static func who_index(c: Dictionary, choices: Array) -> int:
	var who = c.get("who", "player")
	var mode := str(c.get("mode", "any"))
	for i in range(choices.size()):
		var ch: Dictionary = choices[i]
		if typeof(who) == TYPE_STRING and typeof(ch["who"]) == TYPE_STRING and ch["who"] == who:
			if who == "others" and str(ch["mode"]) != mode:
				continue
			return i
		if typeof(who) != TYPE_STRING and typeof(who) != TYPE_ARRAY and typeof(ch["who"]) != TYPE_STRING \
				and int(ch["who"]) == int(who):
			return i
	return 0


## 把 choices[index] 写进条件 c 的 who / mode
static func apply_who(c: Dictionary, choice: Dictionary) -> void:
	c["who"] = choice["who"]
	if str(choice["mode"]) != "":
		c["mode"] = choice["mode"]
	else:
		c.erase("mode")
