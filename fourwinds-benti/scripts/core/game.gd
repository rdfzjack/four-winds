# gdlint: ignore=max-public-methods
# gdlint: disable=max-file-lines
extends RefCounted
## 一局游戏的规则（无画面）：回合、掷骰、移动、买地、收租、建房、银行、坐牢、机会卡、破产。
##
## 用法（画面或 AI 都这样驱动）：
##   var game := Game.new()
##   game.setup(board, rules, cards_file, characters, [{"character": "david", "human": true}, ...])
##   game.start()
##   轮到某人时 game.phase == "pre_roll"：可以 build / upgrade / remove_house，然后 roll()。
##   走到需要选择的地方 game.phase == "pending"，看 game.pending["type"]：
##     choose_direction → choose_direction(tile)   十字路口选方向
##     bank             → bank_deposit / bank_withdraw，最后 bank_done()（路过或停在银行都会弹）
##     buy_land / buy_company → buy() 或 decline()
##     bail             → bail(true) 交保释金，bail(false) 坐牢
##   每个选择做完，游戏会自己往下走，直到轮到下一个人（phase 回到 "pre_roll"）或结束（"over"）。
##   发生的事记在 events 里（drain_events() 取走），画面和台词靠它。
##
## 单位是万圆。数值都在 rules.json 和地图文件里。不访问任何画面节点。

const Board = preload("res://scripts/core/board.gd")
const Player = preload("res://scripts/core/player.gd")

## 会让玩家跳过回合的状态
const SKIP_STATES := ["jail", "park"]
## 玩家处于这些状态时，他自己的地不收租
const NO_RENT_STATES := ["jail", "park", "charity"]
const PERMITS := ["gang", "fortune_teller", "pawnshop"]

var board: Board = null
var rules: Dictionary = {}
var cards: Array = []
var special_events: Array = []
var players: Array = []         ## Player 列表，下标 = 玩家编号
var current: int = 0            ## 轮到谁
var day: int = 1
var phase: String = "idle"      ## idle / pre_roll / pending / over
var pending: Dictionary = {}    ## 等待玩家做的选择，见上面
var winner: int = -1            ## 获胜者编号；-1 = 没有（还没结束，或人类全部破产）
## 地块编号 -> {owner: 玩家编号或 -1, mortgaged: bool, house: 房屋编号或 0, pct: 当前地价系数}
## 只有 land 和 company 的正格有（分身格用 board.site() 换成正格）。
var props: Dictionary = {}
## 房屋编号 -> {kind: 房屋 id, owner: 玩家编号, tiles: [占的地块编号]}
var houses: Dictionary = {}
var events: Array = []
var rng := RandomNumberGenerator.new()
## 测试和作弊用（原版的 STEP / C 作弊码）：下一次掷骰用的点数 [a, b]；下一张机会卡的编号
var forced_dice: Array = []
var forced_cards: Array = []

var _house_defs: Dictionary = {}  ## 房屋 id -> rules.houses.levels 里的条目
var _jail_tile: int = -1
var _next_house_id: int = 1
var _move: Dictionary = {}        ## 正在走的路：{remaining, pick}


## 整数百分比计算：value × pct ÷ 100，向下取整
@warning_ignore("integer_division")
static func pct_of(value: int, pct: int) -> int:
	return value * pct / 100


## 开一局。specs 是每个玩家一项：{"character": 角色 id, "human": 是不是人类}。
## 返回错误列表，空表示没问题。seed_value >= 0 时随机数可复现。
func setup(p_board: Board, p_rules: Dictionary, cards_file: Dictionary, characters: Array,
		specs: Array, seed_value: int = -1) -> Array:
	var errors: Array = []
	board = p_board
	rules = p_rules
	cards = cards_file.get("cards", [])
	special_events = cards_file.get("special_events", [])
	if seed_value >= 0:
		rng.seed = seed_value
	else:
		rng.randomize()
	_house_defs.clear()
	for lv in rules.get("houses", {}).get("levels", []):
		_house_defs[str(lv["id"])] = lv
	_jail_tile = -1
	for t in board.tiles:
		if t["type"] == "jail" and not t.has("site"):
			_jail_tile = int(t["id"])
			break
	if specs.size() < 2 or specs.size() > int(rules.get("max_players", 4)):
		errors.append("玩家人数应该是 2 到 %d" % int(rules.get("max_players", 4)))
		return errors
	players.clear()
	var names := {}
	for c in characters:
		names[str(c.get("id", ""))] = str(c.get("nickname", c.get("name", "")))
	for i in range(specs.size()):
		var p := Player.new()
		p.index = i
		p.character = str(specs[i].get("character", ""))
		p.display_name = str(names.get(p.character, p.character))
		p.human = bool(specs[i].get("human", false))
		p.cash = int(rules.get("starting_cash", 0))
		p.deposit = int(rules.get("starting_deposit", 0))
		p.pos = board.start_tile
		players.append(p)
	props.clear()
	for t in board.tiles:
		if (t["type"] == "land" or t["type"] == "company") and not t.has("site"):
			props[int(t["id"])] = {
				"owner": -1, "mortgaged": false, "house": 0, "pct": int(t.get("price_pct", 100)),
			}
	houses.clear()
	events.clear()
	pending = {}
	_move = {}
	winner = -1
	day = 1
	phase = "idle"
	return errors


## 开始第一个回合。
func start() -> void:
	current = 0
	if not _begin_turn():
		_next_turn()


func drain_events() -> Array:
	var out := events
	events = []
	return out


func player() -> Player:
	return players[current]


# ───────────────────────── 查询 ─────────────────────────

func prices() -> Dictionary:
	return board.prices


## 空地价格（现价）
func land_price(tile: int) -> int:
	return pct_of(int(props[tile]["pct"]), int(prices().get("blank_land_price", 0)))


## 这块地或企业的价格（企业是地图里写的价格）
func property_price(tile: int) -> int:
	if board.get_tile(tile)["type"] == "company":
		return int(board.get_tile(tile)["price"])
	return land_price(tile)


func owner_of(tile: int) -> int:
	if not props.has(tile):
		return -1
	return int(props[tile]["owner"])


## 这块地上的房子编号，没有房子返回 0
func house_at(tile: int) -> int:
	if not props.has(tile):
		return 0
	return int(props[tile]["house"])


func _sum_field(tiles: Array, field: String) -> int:
	var total := 0
	for t in tiles:
		if field == "price_pct":
			total += int(props[t]["pct"])
		else:
			total += int(board.get_tile(t).get(field, 0))
	return total


## 造价：所占各块地的 build_cost_pct 之和 × 造价表 ÷ 100
func house_cost(kind: String, tiles: Array) -> int:
	var unit := 0
	for key in _house_defs[kind]["cost"]:
		unit += int(prices()["build_cost"][key])
	return pct_of(_sum_field(tiles, "build_cost_pct"), unit)


## 升级费（旅社 → 旅馆、小洋楼 → 花园洋房）
func upgrade_fee(tiles: Array) -> int:
	return pct_of(_sum_field(tiles, "build_cost_pct"), int(prices()["build_cost"]["upgrade"]))


## 房子的租金：所占各块地的现价系数之和 × 租金表 ÷ 100
func house_rent(house_id: int) -> int:
	var h: Dictionary = houses[house_id]
	var unit := int(prices()["rent"][_house_defs[h["kind"]]["rent"]])
	return pct_of(_sum_field(h["tiles"], "price_pct"), unit)


## 站在这块地 / 企业上要付给主人的租金（不考虑状态减免）
func rent_of(tile: int) -> int:
	var t: Dictionary = board.get_tile(tile)
	if t["type"] == "company":
		var industry := str(t.get("industry", ""))
		var count := 0
		for i in props:
			if owner_of(i) == owner_of(tile) and board.get_tile(i)["type"] == "company" \
					and str(board.get_tile(i).get("industry", "")) == industry:
				count += 1
		var mult := int(rules.get("companies", {}).get("same_industry_multiplier", 2))
		return int(t["rent"]) * int(pow(mult, maxi(count - 1, 0)))
	var hid := house_at(tile)
	if hid != 0:
		return house_rent(hid)
	return pct_of(int(props[tile]["pct"]), int(prices()["rent"]["blank_land"]))


## 总资产 = 现金 + 存款 + 地价 + 企业价 + 房屋造价（抵押中的地和企业按一半算）
func total_assets(pi: int) -> int:
	var p: Player = players[pi]
	var total := p.cash + p.deposit
	for tile in props:
		if owner_of(tile) != pi:
			continue
		var value := property_price(tile)
		if props[tile]["mortgaged"]:
			value = pct_of(value, 50)
		total += value
	for hid in houses:
		var h: Dictionary = houses[hid]
		if h["owner"] == pi:
			total += house_cost(h["kind"], h["tiles"])
	return total


func alive_players() -> Array:
	var out: Array = []
	for p in players:
		if not p.bankrupt:
			out.append(p)
	return out


# ───────────────────────── 掷骰前：建房、升级、拆房 ─────────────────────────

## 为什么现在不能建？返回原因，空字符串表示可以。
## merging = 合并平房：占的地里可以有自己的平房（至少一块），见 merge()。
# gdlint: disable=max-returns
func why_cannot_build(pi: int, kind: String, tiles: Array, merging: bool = false) -> String:
	if phase != "pre_roll" or current != pi:
		return "现在不是你掷骰前的时间"
	if not _house_defs.has(kind) or _house_defs[kind].get("build_directly", true) == false:
		return "这种房子不能直接建"
	var lots := int(_house_defs[kind]["lots"])
	if tiles.size() != lots:
		return "这种房子要占 %d 块地" % lots
	if merging:
		if not rules["houses"].get("merge_flats", {}).get("enabled", false):
			return "规则里没有开合并平房"
		if lots < 2 or _flats_in(tiles).is_empty():
			return "合并要占到自己的平房"
	var why := _why_lots_invalid(pi, tiles, merging)
	if why != "":
		return why
	var min_lots_no_player := int(rules["houses"]["placement"].get("no_player_on_lots_from", 99))
	if lots >= min_lots_no_player:
		for p in alive_players():
			if tiles.has(board.site(p.pos)):
				return "有人站在要建房的地上"
	if players[pi].cash < (merge_cost(kind, tiles) if merging else house_cost(kind, tiles)):
		return "现金不够（建房只能用现金）"
	return ""


## 占的几块地合不合格：都是自己的空地，同一条街，沿路连成一排。
func _why_lots_invalid(pi: int, tiles: Array, allow_flats: bool = false) -> String:
	var same_street: bool = rules["houses"]["placement"].get("same_street", true)
	var group := ""
	for i in range(tiles.size()):
		var t := int(tiles[i])
		if not props.has(t) or board.get_tile(t)["type"] != "land":
			return "只能在空地上建房"
		if i == 0:
			group = str(board.get_tile(t).get("group", ""))
		elif not board.next_tiles(int(tiles[i - 1])).has(t):
			return "占的地要沿路连成一排"
		elif same_street and str(board.get_tile(t).get("group", "")) != group:
			return "占的地要在同一条街上"
		if owner_of(t) != pi:
			return "占的地都要是自己的"
		if props[t]["mortgaged"]:
			return "抵押中的地不能建房"
		if house_at(t) != 0 and not (allow_flats and _flats_in([t]).size() == 1):
			return "这块地上已经有房子"
	return ""


# gdlint: enable=max-returns


## 所有现在能建的房子：[{kind, tiles, cost}]。AI 和建房界面都用它。
## merging = true 时列出“合并平房”的选项（cost 是合并要付的钱）
func build_options(pi: int, merging: bool = false) -> Array:
	var out: Array = []
	var seen := {}
	for kind in _house_defs:
		if _house_defs[kind].get("build_directly", true) == false:
			continue
		var lots := int(_house_defs[kind]["lots"])
		for start in props:
			if owner_of(start) != pi or board.get_tile(start)["type"] != "land":
				continue
			for chain in board.lot_chains(start, lots):
				var sorted: Array = chain.duplicate()
				sorted.sort()
				var key := "%s:%s" % [kind, str(sorted)]
				if seen.has(key):
					continue
				seen[key] = true
				if why_cannot_build(pi, kind, chain, merging) == "":
					var cost := merge_cost(kind, chain) if merging else house_cost(kind, chain)
					out.append({"kind": kind, "tiles": chain, "cost": cost})
	return out


## 建房。成功返回 ""，否则返回原因。tiles 按沿路的顺序给。
func build(pi: int, kind: String, tiles: Array) -> String:
	var why := why_cannot_build(pi, kind, tiles)
	if why != "":
		return why
	var cost := house_cost(kind, tiles)
	players[pi].cash -= cost
	var hid := _place_house(pi, kind, tiles)
	var tile_list: Array = houses[hid]["tiles"]
	_emit("built", {"player": pi, "house": hid, "kind": kind, "tiles": tile_list, "cost": cost})
	# 建房后的随机事件：挖到古董；没挖到时房子可能倒塌
	var lots := tile_list.size()
	var antique_odds := int(rules["houses"]["antique_chance_by_lots"][str(lots)])
	if rng.randi() % antique_odds == 0:
		var amount := _special_event_amount("antique", 1000)
		players[pi].cash += amount
		_emit("antique", {"player": pi, "amount": amount})
	elif rng.randi() % int(rules["houses"]["collapse_chance"]) == 0:
		_demolish(hid)
		_emit("collapse", {"player": pi, "house": hid, "tiles": tile_list})
	return ""


func _place_house(pi: int, kind: String, tiles: Array) -> int:
	var hid := _next_house_id
	_next_house_id += 1
	var tile_list: Array = []
	for t in tiles:
		tile_list.append(int(t))
		props[int(t)]["house"] = hid
	houses[hid] = {"kind": kind, "owner": pi, "tiles": tile_list}
	return hid


## 这几块地上的平房（每块地一栋）的房屋编号
func _flats_in(tiles: Array) -> Array:
	var out: Array = []
	for t in tiles:
		var hid := house_at(int(t))
		if hid != 0 and str(houses[hid]["kind"]) == "flat" and houses[hid]["tiles"].size() == 1:
			out.append(hid)
	return out


## 合并平房要付的钱：新房子造价 − 拆掉的平房造价 × credit_flat_cost_pct%（不少于 0）
func merge_cost(kind: String, tiles: Array) -> int:
	var credit := 0
	for hid in _flats_in(tiles):
		credit += house_cost("flat", houses[hid]["tiles"])
	var pct := int(rules["houses"].get("merge_flats", {}).get("credit_flat_cost_pct", 100))
	return maxi(0, house_cost(kind, tiles) - pct_of(credit, pct))


## 【作者定】同一条街上并排的自己的平房（可以夹着自己的空地）直接合并成旅社 / 小洋楼 / 别墅。
## 不触发古董和倒塌（和升级一样）。成功返回 ""。
func merge(pi: int, kind: String, tiles: Array) -> String:
	var why := why_cannot_build(pi, kind, tiles, true)
	if why != "":
		return why
	var cost := merge_cost(kind, tiles)
	players[pi].cash -= cost
	for hid in _flats_in(tiles):
		_demolish(hid)
	var hid := _place_house(pi, kind, tiles)
	_emit("merged", {"player": pi, "house": hid, "kind": kind, "tiles": houses[hid]["tiles"],
			"cost": cost})
	return ""


func why_cannot_upgrade(pi: int, hid: int) -> String:
	if phase != "pre_roll" or current != pi:
		return "现在不是你掷骰前的时间"
	if not houses.has(hid) or houses[hid]["owner"] != pi:
		return "这不是你的房子"
	if not _house_defs[houses[hid]["kind"]].has("upgrade_to"):
		return "这种房子不能再升级"
	if players[pi].cash < upgrade_fee(houses[hid]["tiles"]):
		return "现金不够（升级只能用现金）"
	return ""


## 升级：旅社 → 旅馆，小洋楼 → 花园洋房，只付升级费。成功返回 ""。
func upgrade(pi: int, hid: int) -> String:
	var why := why_cannot_upgrade(pi, hid)
	if why != "":
		return why
	var h: Dictionary = houses[hid]
	var fee := upgrade_fee(h["tiles"])
	players[pi].cash -= fee
	h["kind"] = _house_defs[h["kind"]]["upgrade_to"]
	_emit("upgraded", {"player": pi, "house": hid, "kind": h["kind"], "cost": fee})
	return ""


## 拆房，退还造价的一半。成功返回 ""。
func remove_house(pi: int, hid: int) -> String:
	if phase != "pre_roll" or current != pi:
		return "现在不是你掷骰前的时间"
	if not houses.has(hid) or houses[hid]["owner"] != pi:
		return "这不是你的房子"
	var h: Dictionary = houses[hid]
	var refund := pct_of(house_cost(h["kind"], h["tiles"]),
			int(rules["houses"]["remove_refund_pct"]))
	players[pi].cash += refund
	_emit("removed", {"player": pi, "house": hid, "tiles": h["tiles"], "refund": refund})
	_demolish(hid)
	return ""


func _demolish(hid: int) -> void:
	for t in houses[hid]["tiles"]:
		props[t]["house"] = 0
	houses.erase(hid)


func _special_event_amount(event_id: String, fallback: int) -> int:
	for e in special_events:
		if str(e.get("id", "")) == event_id:
			for fx in e.get("effects", []):
				if fx.get("op", "") == "money":
					return int(fx["amount"])
	return fallback


# ───────────────────────── 掷骰和移动 ─────────────────────────

## 掷两颗骰子并开始走。返回 {dice: [a, b], steps}；现在不能掷返回空字典。
func roll() -> Dictionary:
	if phase != "pre_roll":
		return {}
	var dice: Array = []
	if not forced_dice.is_empty():
		dice = forced_dice.pop_front()
	else:
		for _i in range(int(rules.get("dice_count", 2))):
			dice.append(rng.randi_range(1, int(rules.get("dice_sides", 6))))
	var steps := 0
	for d in dice:
		steps += int(d)
	_emit("rolled", {"player": current, "dice": dice, "steps": steps})
	_move = {"remaining": steps, "pick": -1, "passed": {}}
	_continue_move()
	return {"dice": dice, "steps": steps}


## 十字路口选方向。tile 是 pending["options"] 里的一个格子编号。
func choose_direction(tile: int) -> bool:
	if pending.get("type", "") != "choose_direction" or not pending["options"].has(tile):
		return false
	_move["pick"] = tile
	_clear_pending()
	_continue_move()
	return true


func _continue_move() -> void:
	var p: Player = player()
	while int(_move["remaining"]) > 0:
		var options: Array = board.next_tiles(p.pos)
		var dest: int = options[0]
		if options.size() > 1:
			if int(_move["pick"]) >= 0:
				dest = int(_move["pick"])
				_move["pick"] = -1
			elif _may_choose_direction(p, p.pos):
				_set_pending({"type": "choose_direction", "from": p.pos, "options": options.duplicate()})
				return
			else:
				dest = options[rng.randi() % options.size()]
				_emit("random_direction", {"player": p.index, "from": p.pos, "tile": dest})
		p.pos = dest
		_move["remaining"] = int(_move["remaining"]) - 1
		_emit("step", {"player": p.index, "tile": dest})
		_meet_players(p)
		if p.bankrupt:
			_finish_turn()
			return
		if int(_move["remaining"]) > 0 and _on_pass(p):
			return  # 路过银行，等玩家操作
		if p.bankrupt:
			_finish_turn()
			return
	_move = {}
	_on_stop(p)
	if phase != "pending" and phase != "over":
		_finish_turn()


## 走到这个路口时，这个玩家能不能自己选方向。
## 现在只看路口类型（choice 能选，random 不能）；以后角色特性可以在这里开例外，
## 比如某个角色在随机路口也能选。
func _may_choose_direction(_p: Player, tile: int) -> bool:
	return board.crossroad_mode(tile) == "choice"


## 路上遇到别的玩家：小偷偷走现金，信徒施舍现金。
func _meet_players(p: Player) -> void:
	for q in players:
		if q == p or q.bankrupt or q.pos != p.pos:
			continue
		var kind := p.status_kind()
		if kind == "thief":
			var stolen: int = q.cash
			q.cash = 0
			p.cash += stolen
			p.status = {}
			_emit("stolen", {"thief": p.index, "victim": q.index, "amount": stolen})
			return
		if kind == "believer":
			var divisor := int(rules.get("states", {}).get("believer_alms_divisor", 4))
			var alms: int = floori(p.cash / float(divisor))
			p.cash -= alms
			q.cash += alms
			_emit("alms", {"giver": p.index, "receiver": q.index, "amount": alms})


## 路过（不是最后一步）某格的效果。返回 true 表示要等玩家做选择。
## 一栋建筑挨着好几格路时（原版地图），一次移动里只触发一次。
func _on_pass(p: Player) -> bool:
	var site := board.site(p.pos)
	var passed: Dictionary = _move.get_or_add("passed", {})
	if passed.has(site):
		return false
	passed[site] = true
	var tile_type: String = board.get_tile(p.pos)["type"]
	if tile_type == "bank" and (p.cash > 0 or p.deposit > 0):
		_set_pending({"type": "bank", "tile": p.pos})
		return true
	if tile_type == "church":
		p.church_passes += 1
		var every := int(rules["church"]["pass_every"])
		if p.church_passes % every == 0:
			var amount := int(rules["church"]["pass_donation"])
			_emit("donation", {"player": p.index, "amount": amount})
			pay(p.index, amount, -1)
	return false


func bank_deposit(amount: int) -> bool:
	if pending.get("type", "") != "bank":
		return false
	var p: Player = player()
	if amount <= 0 or amount > p.cash:
		return false
	p.cash -= amount
	p.deposit += amount
	_emit("deposit", {"player": p.index, "amount": amount})
	return true


func bank_withdraw(amount: int) -> bool:
	if pending.get("type", "") != "bank":
		return false
	var p: Player = player()
	if amount <= 0 or amount > p.deposit:
		return false
	p.deposit -= amount
	p.cash += amount
	_emit("withdraw", {"player": p.index, "amount": amount})
	return true


func bank_done() -> bool:
	if pending.get("type", "") != "bank":
		return false
	var stopped: bool = pending.get("stop", false)
	_clear_pending()
	if stopped:
		_finish_turn()  # 停在银行：存取完这回合就结束
	else:
		_continue_move()
	return true


# ───────────────────────── 停下来的效果 ─────────────────────────

## stop_from_card：机会卡把人传送过来触发的停下（不再抽卡，免得无限循环）
func _on_stop(p: Player, from_card: bool = false) -> void:
	var t: Dictionary = board.get_tile(p.pos)
	match str(t["type"]):
		"land":
			_stop_on_land(p)
		"company":
			_stop_on_company(p)
		"chance":
			if not from_card:
				_draw_card(p)
		"tax":
			var amount := pct_of(total_assets(p.index), int(rules["tax"]["pct_of_total_assets"]))
			_emit("tax", {"player": p.index, "amount": amount})
			pay(p.index, amount, -1)
		"bank":
			# 作者定的规则：停在银行也能存取款（原版反汇编表里停下没有效果）
			if p.cash > 0 or p.deposit > 0:
				_set_pending({"type": "bank", "tile": p.pos, "stop": true})
		"jail":
			_stop_at_jail(p)
		"church":
			_set_status(p, "believer", int(rules["church"]["believer_days"]))
		"park":
			_set_status(p, "park", int(rules["park"]["rest_days"]))
		"government":
			p.permit = PERMITS[rng.randi() % PERMITS.size()]
			_emit("permit", {"player": p.index, "permit": p.permit})
		"race_course":
			var prizes: Array = rules["race_course"]["prizes"]
			var rank := rng.randi() % prizes.size()
			var prize := int(prizes[rank])
			p.cash += prize
			_emit("race", {"player": p.index, "rank": rank + 1, "prize": prize})
		_:
			pass  # 起点、普通路面、赌场：停下没有效果


func _stop_on_land(p: Player) -> void:
	var tile := board.site(p.pos)
	var owner := owner_of(tile)
	if owner == -1:
		_offer_purchase(p, tile, "buy_land", land_price(tile))
		return
	if owner == p.index:
		return
	if p.status_kind() == "arsonist" and house_at(tile) != 0:
		var hid := house_at(tile)
		_emit("arson", {"player": p.index, "owner": owner, "house": hid, "tiles": houses[hid]["tiles"]})
		_demolish(hid)
		return
	_collect_rent(p, tile)


func _stop_on_company(p: Player) -> void:
	var tile := board.site(p.pos)
	var owner := owner_of(tile)
	if owner == -1:
		_offer_purchase(p, tile, "buy_company", property_price(tile))
	elif owner != p.index:
		if p.status_kind() == "robber":
			props[tile]["owner"] = p.index
			_emit("robbed", {"player": p.index, "from": owner, "tile": tile})
			return
		_collect_rent(p, tile)


func _offer_purchase(p: Player, tile: int, kind: String, price: int) -> void:
	if p.cash < price:
		_emit("cannot_afford", {"player": p.index, "tile": tile, "price": price})
		return
	_set_pending({"type": kind, "tile": tile, "price": price})


func _collect_rent(p: Player, tile: int) -> void:
	var owner := owner_of(tile)
	var rent := rent_of(tile)
	var reason := ""
	if props[tile]["mortgaged"]:
		reason = "mortgaged"
	elif NO_RENT_STATES.has(players[owner].status_kind()):
		reason = str(players[owner].status_kind())
	elif p.status_kind() == "free_rent":
		reason = "free_rent"
	if reason != "":
		_emit("rent_waived", {"player": p.index, "owner": owner, "tile": tile, "reason": reason})
		return
	if p.status_kind() == "double_rent":
		rent *= 2
	elif p.status_kind() == "half_rent":
		rent = pct_of(rent, 50)
	# 台词用：租金占自己现金+存款的比例
	var wealth: int = p.cash + p.deposit
	var scale := ""
	if rent * 100 > wealth * int(rules["speech"]["much_money_pct"]):
		scale = "big"
	elif rent * 100 < wealth * int(rules["speech"]["little_money_pct"]):
		scale = "small"
	_emit("rent", {"player": p.index, "owner": owner, "tile": tile, "amount": rent, "scale": scale})
	pay(p.index, rent, owner)


func buy() -> bool:
	var kind: String = pending.get("type", "")
	if kind != "buy_land" and kind != "buy_company":
		return false
	var p: Player = player()
	var tile: int = pending["tile"]
	var price: int = pending["price"]
	p.cash -= price
	props[tile]["owner"] = p.index
	props[tile]["mortgaged"] = false
	_emit("bought", {"player": p.index, "tile": tile, "price": price})
	_clear_pending()
	_finish_turn()
	return true


func decline() -> bool:
	var kind: String = pending.get("type", "")
	if kind != "buy_land" and kind != "buy_company":
		return false
	_emit("declined", {"player": current, "tile": pending["tile"], "price": pending["price"]})
	_clear_pending()
	_finish_turn()
	return true


func _stop_at_jail(p: Player) -> void:
	var bail_amount := rng.randi_range(int(rules["jail"]["bail_min"]), int(rules["jail"]["bail_max"]))
	if p.cash >= bail_amount:
		_set_pending({"type": "bail", "amount": bail_amount})
	else:
		_send_to_jail(p, int(rules["jail"]["days"]))


## 交保释金（pay_bail = true）或认命坐牢。
func bail(pay_bail: bool) -> bool:
	if pending.get("type", "") != "bail":
		return false
	var p: Player = player()
	var amount: int = pending["amount"]
	_clear_pending()
	if pay_bail:
		p.cash -= amount
		_emit("bail_paid", {"player": p.index, "amount": amount})
	else:
		_send_to_jail(p, int(rules["jail"]["days"]))
	_finish_turn()
	return true


func _send_to_jail(p: Player, days: int) -> void:
	if _jail_tile >= 0:
		p.pos = _jail_tile
	_set_status(p, "jail", days)
	_emit("jailed", {"player": p.index, "days": days})


# ───────────────────────── 机会卡 ─────────────────────────

func _draw_card(p: Player) -> void:
	var card := _pick_card(p)
	if card.is_empty():
		return
	_emit("card", {"player": p.index, "card": int(card["id"]), "text": str(card["text"])})
	for e in card.get("effects", []):
		_apply_effect(p, e)
		if p.bankrupt or phase == "over":
			return


## 抽卡：随机选一张，当前角色不能抽就重抽，再按权重做概率筛选。
func _pick_card(p: Player) -> Dictionary:
	if not forced_cards.is_empty():
		var wanted: int = forced_cards.pop_front()
		for c in cards:
			if int(c["id"]) == wanted:
				return c
	for _try in range(2000):
		var c: Dictionary = cards[rng.randi() % cards.size()]
		if not c.get("allowed_for", []).has(p.character):
			continue
		if rng.randi_range(1, 100) > int(c.get("weight", 100)):
			continue
		return c
	return {}


func _apply_effect(p: Player, e: Dictionary) -> void:
	match str(e["op"]):
		"money":
			var amount := int(e["amount"])
			if amount >= 0:
				p.cash += amount
			else:
				pay(p.index, -amount, -1)
		"money_from_each":
			for q in alive_players():
				if q != p and not p.bankrupt:
					pay(q.index, int(e["amount"]), p.index)
		"money_to_each":
			for q in alive_players():
				if q != p and not p.bankrupt:
					pay(p.index, int(e["amount"]), q.index)
		"jail":
			_send_to_jail(p, int(e["days"]))
		"goto":
			var dest := p.pos
			if board.get_tile(p.pos)["type"] != str(e["tile_type"]):
				dest = board.nearest_of_type(p.pos, str(e["tile_type"]))
			if dest >= 0:
				p.pos = dest
				_emit("teleport", {"player": p.index, "tile": dest})
				if e.get("trigger_stop", false):
					_on_stop(p, true)
		"state":
			_set_status(p, str(e["state"]), int(e["days"]))
		"lose_most_expensive_land":
			var best := -1
			for tile in props:
				if owner_of(tile) == p.index and board.get_tile(tile)["type"] == "land":
					if best < 0 or land_price(tile) > land_price(best):
						best = tile
			if best >= 0:
				_release_property(best)
				_emit("confiscated", {"player": p.index, "tile": best})
		"lose_mortgaged_properties":
			for tile in props:
				if owner_of(tile) == p.index and props[tile]["mortgaged"]:
					_release_property(tile)
					_emit("confiscated", {"player": p.index, "tile": tile})
		"demolish_random_house":
			var mine: Array = []
			for id in houses:
				if houses[id]["owner"] == p.index:
					mine.append(id)
			if not mine.is_empty():
				mine.sort()
				var smashed: int = mine[rng.randi() % mine.size()]
				_emit("house_smashed", {"player": p.index, "house": smashed, "tiles": houses[smashed]["tiles"]})
				_demolish(smashed)
		"land_value_pct":
			for tile in props:
				if owner_of(tile) == p.index and board.get_tile(tile)["type"] == "land":
					props[tile]["pct"] = maxi(roundi(props[tile]["pct"] * (100 + int(e["pct"])) / 100.0), 1)
		"upgrade_houses":
			for hid in houses:
				var h: Dictionary = houses[hid]
				if h["owner"] == p.index and _house_defs[h["kind"]].has("upgrade_to"):
					h["kind"] = _house_defs[h["kind"]]["upgrade_to"]
					_emit("upgraded", {"player": p.index, "house": hid, "kind": h["kind"], "cost": 0})
		"lose_deposit":
			p.deposit = 0
		_:
			pass  # demolish_new_house、mortgage_without_payment 是建房 / 抵押时的事件，不在牌堆里


## 地产变成无主（房子拆掉，抵押清除）
func _release_property(tile: int) -> void:
	if house_at(tile) != 0:
		_demolish(house_at(tile))
	props[tile]["owner"] = -1
	props[tile]["mortgaged"] = false


# ───────────────────────── 钱和破产 ─────────────────────────

## 付钱。先扣现金，不够连存款一起扣；还不够就破产，剩下的全部给收款人。
## to 是收款玩家编号，-1 = 政府 / 银行（钱直接消失）。付清返回 true。
func pay(pi: int, amount: int, to: int) -> bool:
	var p: Player = players[pi]
	if amount <= 0:
		return true
	if p.cash + p.deposit >= amount:
		var from_cash := mini(p.cash, amount)
		p.cash -= from_cash
		p.deposit -= amount - from_cash
		if to >= 0:
			players[to].cash += amount
		return true
	var everything: int = p.cash + p.deposit
	p.cash = 0
	p.deposit = 0
	if to >= 0:
		players[to].cash += everything
	_bankrupt(p, to)
	return false


## 破产：房子全拆，地和企业归让他破产的人（政府逼的则变无主）。
func _bankrupt(p: Player, creditor: int) -> void:
	p.bankrupt = true
	p.status = {}
	var heir := creditor if creditor >= 0 and not players[creditor].bankrupt else -1
	for hid in houses.keys():
		if houses[hid]["owner"] == p.index:
			_demolish(hid)
	for tile in props:
		if owner_of(tile) == p.index:
			if heir >= 0:
				props[tile]["owner"] = heir
			else:
				props[tile]["owner"] = -1
				props[tile]["mortgaged"] = false
	_emit("bankrupt", {"player": p.index, "creditor": heir})
	_check_game_over()


func _check_game_over() -> void:
	var alive := alive_players()
	var humans_alive := 0
	var any_human := false
	for p in players:
		if p.human:
			any_human = true
			if not p.bankrupt:
				humans_alive += 1
	if alive.size() <= 1:
		phase = "over"
		winner = alive[0].index if alive.size() == 1 else -1
		_emit("game_over", {"winner": winner})
	elif any_human and humans_alive == 0:
		phase = "over"
		winner = -1
		_emit("game_over", {"winner": -1})


# ───────────────────────── 状态 ─────────────────────────

## 设置状态。同一时间只有一种，新的覆盖旧的。days = 0 表示一直持续到触发为止。
func _set_status(p: Player, kind: String, days: int) -> void:
	p.status = {"kind": kind, "days": days if days > 0 else -1}
	_emit("status", {"player": p.index, "kind": kind, "days": days})


# ───────────────────────── 回合切换 ─────────────────────────

## 当前玩家的回合开始。要跳过（坐牢、游览）时返回 false。
func _begin_turn() -> bool:
	var p: Player = player()
	var kind := p.status_kind()
	if kind != "":
		var days := int(p.status["days"])
		if days > 0:
			p.status["days"] = days - 1
			if SKIP_STATES.has(kind):
				_emit("skip_turn", {"player": p.index, "reason": kind})
				return false
			if days - 1 == 0:
				_emit("status_end", {"player": p.index, "kind": kind})
				p.status = {}
		elif days == 0:
			_emit("status_end", {"player": p.index, "kind": kind})
			p.status = {}
	phase = "pre_roll"
	_emit("turn_start", {"player": p.index, "day": day})
	return true


func _finish_turn() -> void:
	_move = {}
	if phase == "over":
		return
	_next_turn()


## 轮到下一个没破产的玩家；一轮走完就是新的一天。
func _next_turn() -> void:
	while phase != "over":
		current = (current + 1) % players.size()
		if current == 0:
			_new_day()
		if players[current].bankrupt:
			continue
		if _begin_turn():
			return


func _new_day() -> void:
	day += 1
	var every := int(rules["bank"]["payday_every_days"])
	if day % every == 0:
		for p in alive_players():
			var interest := pct_of(p.deposit, int(rules["bank"]["interest_pct"]))
			p.cash += interest
			_emit("payday", {"player": p.index, "amount": interest})


func _set_pending(d: Dictionary) -> void:
	pending = d
	phase = "pending"


func _clear_pending() -> void:
	pending = {}
	if phase == "pending":
		phase = "pre_roll"


func _emit(type: String, data: Dictionary) -> void:
	data["type"] = type
	events.append(data)


# ───────────────────────── 自检（测试用）─────────────────────────

## 检查内部数据有没有自相矛盾。返回问题列表。
func check_invariants() -> Array:
	var errors: Array = []
	for p in players:
		if p.cash < 0 or p.deposit < 0:
			errors.append("玩家 %d 的钱是负数：现金 %d 存款 %d" % [p.index, p.cash, p.deposit])
		if p.bankrupt and (p.cash != 0 or p.deposit != 0):
			errors.append("破产的玩家 %d 还有钱" % p.index)
	for tile in props:
		var o := owner_of(tile)
		if o >= 0 and players[o].bankrupt:
			errors.append("格子 %d 的主人 %d 已经破产" % [tile, o])
		var hid := house_at(tile)
		if hid != 0:
			if not houses.has(hid) or not houses[hid]["tiles"].has(tile):
				errors.append("格子 %d 指向不存在的房子 %d" % [tile, hid])
			elif houses[hid]["owner"] != o:
				errors.append("格子 %d 的主人和房子 %d 的主人不一致" % [tile, hid])
			elif props[tile]["mortgaged"]:
				errors.append("格子 %d 盖了房子却在抵押" % tile)
		if o < 0 and props[tile]["mortgaged"]:
			errors.append("无主的格子 %d 在抵押" % tile)
	for hid in houses:
		var h: Dictionary = houses[hid]
		if h["tiles"].size() != int(_house_defs[h["kind"]]["lots"]):
			errors.append("房子 %d 占的地块数和种类不符" % hid)
		for t in h["tiles"]:
			if house_at(t) != hid:
				errors.append("房子 %d 的地块 %d 没有指回它" % [hid, t])
	return errors
