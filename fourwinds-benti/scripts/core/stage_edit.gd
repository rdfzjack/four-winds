extends RefCounted
## 关卡数据的编辑（简介页的调试面板用：增减对手、给谁送哪些地产 / 企业）。只改关卡字典，不碰画面，能无头测试。
## 改完的字典仍然是合法的关卡（Scenario.validate 能过）；牵涉到被删座位的胜负条件会自动处理。

const PLAYER_KEY := "player"


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
