extends RefCounted
## 关卡（个人主线的一关）：开局设置 + 胜负判定。只处理数据，不依赖画面节点。
##
## 关卡数据是一个字典（来自 data/campaigns/<角色 id>.json 的 stages 里的一项），格式见 docs/campaigns.md。
## 用法：
##   var sc := Scenario.new(stage)
##   var game := Game.new()
##   game.setup(board, rules, cards_file, characters, sc.specs())   # 座位由关卡决定
##   game.scenario = sc
##   sc.apply(game)      # 开局现金 / 存款 / 预置地产；返回错误列表
##   game.start()
## 之后 Game 在每个可能改变结果的时刻调用 sc.check(game)：胜 / 负 / 继续。
## 结果出来时 Game 发 scenario_won / scenario_lost 事件，再发 game_over，phase 变成 over。
## 没有关卡（game.scenario == null）时 Game 的行为和以前完全一样。
##
## 条件 = {"type": 类型, ...参数}。新增类型：在 TYPES 里登记，写一个 _cond_<类型>(game, c) 和一句 describe。
## 同时满足胜和负时按“负”算（先查 lose）。

## 条件类型 -> 说明（给 docs 和校验用）
const TYPES := {
	"bankrupt": "who 破产（mode: any 任意一个 / all 全部，默认 any）",
	"build_house": "who 名下有 kind 这种房子（kind 是房屋 id 或列表），数量 count（默认 1）",
	"control_industry": "who 拥有地图上 industry 这个行业的全部企业",
	"control_street": "who 拥有 group 这条街的全部地（group 不写 = 任意一条街）",
	"own_lots_pct": "who 拥有全图 pct% 以上的地",
	"assets_at_least": "who 的总资产达到 amount",
	"days_over": "天数超过 days（第 days 天走完，进入第 days+1 天）",
}

## who 可以写：座位号、"player"（玩家自己）、"others"（除玩家以外的所有人）、座位号列表
var stage: Dictionary = {}
var result: String = ""      ## "" 还没结果 / "won" / "lost"
var reason: String = ""      ## 触发结果的那个条件的说明（结算页显示）
var player_seat: int = 0


func _init(p_stage: Dictionary = {}) -> void:
	stage = p_stage.duplicate(true)
	var seats: Array = stage.get("seats", [])
	for i in range(seats.size()):
		if bool(seats[i].get("player", false)):
			player_seat = i
			break


# ───────────────────────── 开局 ─────────────────────────

## 交给 Game.setup 的座位。玩家自己是人类，对手默认用角色 AI（new_v2）。
func specs() -> Array:
	var out: Array = []
	for i in range(stage.get("seats", []).size()):
		var s: Dictionary = stage["seats"][i]
		var spec := {"character": str(s.get("character", "")), "human": i == player_seat,
				"form": str(s.get("form", "front"))}
		if i != player_seat:
			spec["ai"] = str(s.get("ai", "new_v2"))
		out.append(spec)
	return out


## Game.setup 之后、start 之前：开局现金 / 存款、预置地产和房子。返回错误列表（空 = 没问题）。
func apply(game) -> Array:
	var errors: Array = []
	var seats: Array = stage.get("seats", [])
	for i in range(mini(seats.size(), game.players.size())):
		var s: Dictionary = seats[i]
		var p = game.players[i]
		p.cash = int(s.get("cash", p.cash))
		p.deposit = int(s.get("deposit", p.deposit))
		for entry in s.get("props", []):
			var tiles: Array = []
			if entry.has("tiles"):
				for t in entry["tiles"]:
					tiles.append(int(t))
			else:
				tiles.append(int(entry.get("tile", -1)))
			var why: String = game.grant_lots(i, tiles, str(entry.get("house", "")))
			if why != "":
				errors.append("座位 %d 的预置地产 %s：%s" % [i, str(tiles), why])
	return errors


# ───────────────────────── 判定 ─────────────────────────

## 现在的结果：返回 "won" / "lost" / ""（继续）。同时记下 result 和 reason。已经有结果就原样返回。
func check(game) -> String:
	if result != "":
		return result
	for c in stage.get("lose", []):
		if cond_met(game, c):
			return _finish("lost", c, game)
	for c in stage.get("win", []):
		if cond_met(game, c):
			return _finish("won", c, game)
	return ""


## 没有条件命中，但对局本身已经结束（只剩一个人 / 玩家破产）时：按谁赢了算
func finish_by_standing(game) -> String:
	if result != "":
		return result
	var alive: Array = game.alive_players()
	var player_alive: bool = not game.players[player_seat].bankrupt
	if player_alive and alive.size() == 1:
		result = "won"
		reason = "其他人都破产了"
	else:
		result = "lost"
		reason = "你破产了" if not player_alive else "没能达成目标"
	return result


func _finish(r: String, c: Dictionary, game) -> String:
	result = r
	reason = describe(c, names_of(game))
	return r


## 一个条件现在满足没有
func cond_met(game, c: Dictionary) -> bool:
	var type := str(c.get("type", ""))
	if type == "days_over":
		return game.day > int(c.get("days", 0))
	var list := seats_of(c.get("who", "player"), game.players.size())
	if not TYPES.has(type) or list.is_empty():
		return false
	var all_mode: bool = str(c.get("mode", "any")) == "all"
	for pi in list:
		var ok := _seat_ok(game, pi, type, c)
		if all_mode and not ok:
			return false
		if not all_mode and ok:
			return true
	return all_mode


## 座位 pi 满足这个条件吗（days_over 不看座位，不在这里）
func _seat_ok(game, pi: int, type: String, c: Dictionary) -> bool:
	var ok := false
	match type:
		"bankrupt":
			ok = game.players[pi].bankrupt
		"build_house":
			ok = _houses_of(game, pi, c) >= int(c.get("count", 1))
		"control_industry":
			ok = _controls_industry(game, pi, str(c.get("industry", "")))
		"control_street":
			ok = _controls_street(game, pi, str(c.get("group", "")))
		"own_lots_pct":
			ok = _lots_pct(game, pi) >= int(c.get("pct", 100))
		"assets_at_least":
			ok = not game.players[pi].bankrupt and game.total_assets(pi) >= int(c.get("amount", 0))
	return ok


## who 解析成座位列表（不存在的座位忽略）
func seats_of(who: Variant, count: int) -> Array:
	var out: Array = []
	if typeof(who) == TYPE_STRING:
		if who == "player":
			out.append(player_seat)
		elif who == "others":
			for i in range(count):
				if i != player_seat:
					out.append(i)
	elif typeof(who) == TYPE_ARRAY:
		for x in who:
			out.append(int(x))
	elif typeof(who) == TYPE_INT or typeof(who) == TYPE_FLOAT:
		out.append(int(who))
	return out.filter(func(i: int) -> bool: return i >= 0 and i < count)


func _seats_pred(game, c: Dictionary, pred: Callable) -> bool:
	var list := seats_of(c.get("who", "player"), game.players.size())
	if list.is_empty():
		return false
	var all_mode: bool = str(c.get("mode", "any")) == "all"
	for pi in list:
		var ok: bool = pred.call(pi)
		if all_mode and not ok:
			return false
		if not all_mode and ok:
			return true
	return all_mode


func _houses_of(game, pi: int, c: Dictionary) -> int:
	var kinds: Array = []
	if typeof(c.get("kind", "")) == TYPE_ARRAY:
		for k in c["kind"]:
			kinds.append(str(k))
	else:
		kinds.append(str(c.get("kind", "")))
	var n := 0
	for hid in game.houses:
		var h: Dictionary = game.houses[hid]
		if int(h["owner"]) == pi and kinds.has(str(h["kind"])):
			n += 1
	return n


func _controls_industry(game, pi: int, industry: String) -> bool:
	var total := 0
	for t in game.props:
		var tile: Dictionary = game.board.get_tile(t)
		if str(tile["type"]) == "company" and str(tile.get("industry", "")) == industry:
			total += 1
			if game.owner_of(t) != pi:
				return false
	return total > 0


func _controls_street(game, pi: int, group: String) -> bool:
	var by_group := {}
	for t in game.props:
		var tile: Dictionary = game.board.get_tile(t)
		if str(tile["type"]) != "land":
			continue
		var g := str(tile.get("group", ""))
		if group != "" and group != "any" and g != group:
			continue
		if not by_group.has(g):
			by_group[g] = true
		if game.owner_of(t) != pi:
			by_group[g] = false
	for g in by_group:
		if by_group[g]:
			return true
	return false


func _lots_pct(game, pi: int) -> int:
	var total := 0
	var mine := 0
	for t in game.props:
		if str(game.board.get_tile(t)["type"]) != "land":
			continue
		total += 1
		if game.owner_of(t) == pi:
			mine += 1
	return mine * 100 / maxi(total, 1)


# ───────────────────────── 说明文字 ─────────────────────────

## 每个座位的显示名（关前简介、结算页用）。characters 是 characters.json 的角色列表
func seat_names(characters: Array) -> Array:
	var out: Array = []
	for s in stage.get("seats", []):
		var name := str(s.get("character", ""))
		for c in characters:
			if str(c.get("id", "")) == name:
				name = str(c.get("nickname", c.get("name", name)))
		out.append(name)
	return out


func names_of(game) -> Array:
	var out: Array = []
	for p in game.players:
		out.append(p.display_name)
	return out


## 条件的中文说明。names 是每个座位的名字。
func describe(c: Dictionary, names: Array) -> String:
	var who := _who_text(c.get("who", "player"), names)
	var text := "（未知条件）"
	match str(c.get("type", "")):
		"bankrupt":
			var everyone: bool = str(c.get("mode", "any")) == "all" and c.get("who", "") == "others"
			text = "击败所有对手" if everyone else "%s破产" % who
		"build_house":
			var kinds: Array = c["kind"] if typeof(c.get("kind", "")) == TYPE_ARRAY \
					else [c.get("kind", "")]
			var kind_names: Array = []
			for k in kinds:
				kind_names.append(_house_name(str(k)))
			var count := int(c.get("count", 1))
			text = "%s建成%s%s" % [who, ("%d 栋" % count) if count > 1 else "一栋", "/".join(kind_names)]
		"control_industry":
			text = "%s控制所有“%s”企业" % [who, str(c.get("industry_name", c.get("industry", "")))]
		"control_street":
			var g := str(c.get("group", ""))
			var street := "一整条街"
			if g != "" and g != "any":
				street = "“%s”这条街" % str(c.get("group_name", g))
			text = "%s凑齐%s" % [who, street]
		"own_lots_pct":
			text = "%s拥有全图 %d%% 以上的地" % [who, int(c.get("pct", 100))]
		"assets_at_least":
			text = "%s总资产达到 %d 万" % [who, int(c.get("amount", 0))]
		"days_over":
			text = "超过 %d 天" % int(c.get("days", 0))
	return text


func _who_text(who: Variant, names: Array) -> String:
	if typeof(who) == TYPE_STRING:
		return "你" if who == "player" else "所有对手"
	var parts: Array = []
	for i in seats_of(who, names.size()):
		parts.append("你" if i == player_seat else str(names[i]))
	return "、".join(parts)


static func _house_name(kind: String) -> String:
	const NAMES := {"flat": "平房", "hotel": "旅社", "super_hotel": "旅馆", "floor": "小洋楼",
			"super_floor": "花园洋房", "villa": "别墅"}
	return str(NAMES.get(kind, kind))


## 胜 / 负条件各一行的说明（关前简介用）
func goals_text(names: Array) -> String:
	var lines: Array = []
	var win: Array = []
	for c in stage.get("win", []):
		win.append(describe(c, names))
	lines.append("胜利条件：" + "；或 ".join(win))
	var lose: Array = []
	for c in stage.get("lose", []):
		lose.append(describe(c, names))
	lines.append("失败条件：" + "；或 ".join(lose))
	return "\n".join(lines)


# ───────────────────────── 存档 ─────────────────────────

## 存进 Game.export_state：整个关卡数据 + 结果（存档自带关卡，之后改了 data/ 也不影响这一局）
func export_state() -> Dictionary:
	return {"stage": stage, "result": result, "reason": reason}


static func from_state(d: Dictionary):
	var sc = load("res://scripts/core/scenario.gd").new(d.get("stage", {}))
	sc.result = str(d.get("result", ""))
	sc.reason = str(d.get("reason", ""))
	return sc


# ───────────────────────── 校验 ─────────────────────────

## 检查一关的数据。boards 是 地图 id -> Board。返回错误列表。
static func validate(stage: Dictionary, boards: Dictionary, characters: Array,
		rules: Dictionary) -> Array:
	var errors: Array = []
	var sid := str(stage.get("id", "?"))
	var board = boards.get(str(stage.get("map", "")))
	if board == null:
		errors.append("关卡 %s：地图“%s”不存在" % [sid, str(stage.get("map", ""))])
		return errors
	var seats: Array = stage.get("seats", [])
	var char_ids: Array = []
	for c in characters:
		char_ids.append(str(c.get("id", "")))
	if seats.size() < 2 or seats.size() > int(rules.get("max_players", 4)):
		errors.append("关卡 %s：座位数应该是 2 到 %d" % [sid, int(rules.get("max_players", 4))])
	var players := 0
	var used := {}
	for i in range(seats.size()):
		var s: Dictionary = seats[i]
		if not char_ids.has(str(s.get("character", ""))):
			errors.append("关卡 %s 座位 %d：角色“%s”不存在" % [sid, i, str(s.get("character", ""))])
		if used.has(str(s.get("character", ""))):
			errors.append("关卡 %s：角色“%s”坐了两个位置" % [sid, str(s.get("character", ""))])
		used[str(s.get("character", ""))] = true
		if bool(s.get("player", false)):
			players += 1
		for entry in s.get("props", []):
			for t in entry.get("tiles", [entry.get("tile", -1)]):
				var ti := int(t)
				if ti < 0 or ti >= board.tile_count() or board.is_alias(ti):
					errors.append("关卡 %s 座位 %d：预置地产格子 %d 不存在，或是分身格（要写正格）" % [sid, i, ti])
	if players != 1:
		errors.append("关卡 %s：要有且只有一个 player 座位（现在 %d 个）" % [sid, players])
	for key in ["win", "lose"]:
		if stage.get(key, []).is_empty():
			errors.append("关卡 %s：%s 条件不能为空" % [sid, key])
		for c in stage.get(key, []):
			if not TYPES.has(str(c.get("type", ""))):
				errors.append("关卡 %s：不认识的条件类型“%s”" % [sid, str(c.get("type", ""))])
			var who = c.get("who", "player")
			if typeof(who) != TYPE_STRING and typeof(who) != TYPE_ARRAY and typeof(who) != TYPE_INT \
					and typeof(who) != TYPE_FLOAT:
				errors.append("关卡 %s：who 写法不对" % sid)
	return errors
