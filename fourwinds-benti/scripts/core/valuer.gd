extends RefCounted
## 估价（新 AI 的底线聪明，第 6a 步 ② 第一个模块）。只读 Game 的数据，不改局面，不访问画面。
## 结果都是“折合多少万圆”（浮点数），正数 = 对我有利。
##
## - visit_freq(board)：每格被停下的概率（一个人掷一次骰子停在这块地 / 建筑上的概率），按地图算一次
## - income_per_day(game, tile, owner)：这块地产每天预计给主人收多少租（对手人数 × 停下概率 × 租金）
## - property_worth(game, pi, tile)：这块地产对 pi 值多少 = 价格 + 估价天数 × 每天预计收入
## - stop_value(game, pi, tile)：pi 停在这格的得失（付租、买地机会、坐牢、税……）
## - direction_values(game, pi)：路口每个方向的得失（AI 选方向用）
## - roll_outcomes(game, pi)：从现在的位置掷一次骰子，期望得失和最坏得失
## - rent_risk(game, pi)：从现在的位置掷一次，最多可能要付多少租（留钱防破产用）
## - build_gain / upgrade_gain：建房、升级值不值（估价天数里多收的租 − 要付的钱）
##
## 用到的参数在 profiles.json 的 standard 表形态里（value_horizon_days 等，见那里的 params 说明），
## 角色可以在自己的参数组里覆盖。
## 简化（草案，可改）：地的“发展后租金”按这一段街（同名、沿路连在一起的地）能盖的最大房子算，乘上自己占这条街的比例的
## street_share_power 次方，
## 不扣造价（建房模块再算）；机会卡、银行用固定分；路口在别的玩家那里按平均算。

const AiProfiles = preload("res://scripts/core/ai_profiles.gd")
const Game = preload("res://scripts/core/game.gd")

static var _freq: Dictionary = {}  ## Board 实例 id -> {正格: 停下概率}
static var _segments: Dictionary = {}  ## Board 实例 id -> {正格: 这一段街的地块}


static func param(game, pi: int, key: String, fallback: float = 0.0) -> float:
	return float(AiProfiles.for_player(game.players[pi]).get(key, fallback))


# ───────────────────────── 骰子和停下概率 ─────────────────────────

## 掷一次的点数分布：{点数: 概率}
static func dice_distribution(game) -> Dictionary:
	var dist := {0: 1.0}
	var sides := int(game.rules.get("dice_sides", 6))
	for _i in range(int(game.rules.get("dice_count", 2))):
		var next := {}
		for s in dist:
			for face in range(1, sides + 1):
				next[s + face] = float(next.get(s + face, 0.0)) + dist[s] / sides
		dist = next
	return dist


## 每格（正格）被停下的概率：一个人长期来看，掷一次停在这里的概率。路口按平均分岔，不算机会卡传送和坐牢。
static func visit_freq(game) -> Dictionary:
	var board = game.board
	var key: int = board.get_instance_id()
	if _freq.has(key):
		return _freq[key]
	var n: int = board.tiles.size()
	var dice := dice_distribution(game)
	var max_steps := 0
	for d in dice:
		max_steps = maxi(max_steps, int(d))
	# reach[d][s] = 从 s 走 d 步停在各格的概率
	var reach: Array = [[]]
	for s in range(n):
		reach[0].append({s: 1.0})
	for d in range(1, max_steps + 1):
		var row: Array = []
		for s in range(n):
			var out := {}
			var opts: Array = board.next_tiles(s)
			for o in opts:
				var sub: Dictionary = reach[d - 1][int(o)]
				for t in sub:
					out[t] = float(out.get(t, 0.0)) + sub[t] / opts.size()
			row.append(out)
		reach.append(row)
	var trans: Array = []
	for s in range(n):
		var out := {}
		for d in dice:
			var sub: Dictionary = reach[int(d)][s]
			for t in sub:
				out[t] = float(out.get(t, 0.0)) + sub[t] * dice[d]
		trans.append(out)
	# 从起点出发反复走，取后面几十次的平均（避免周期）
	var dist: Array = []
	dist.resize(n)
	dist.fill(0.0)
	dist[board.start_tile] = 1.0
	var total: Array = []
	total.resize(n)
	total.fill(0.0)
	var rounds := 200
	for k in range(rounds):
		var next: Array = []
		next.resize(n)
		next.fill(0.0)
		for s in range(n):
			if dist[s] == 0.0:
				continue
			for t in trans[s]:
				next[t] += dist[s] * trans[s][t]
		dist = next
		if k >= rounds / 2:
			for s in range(n):
				total[s] += dist[s]
	var freq := {}
	for s in range(n):
		var site: int = board.site(s)
		freq[site] = float(freq.get(site, 0.0)) + total[s] / (rounds - rounds / 2)
	_freq[key] = freq
	return freq


# ───────────────────────── 地产值多少 ─────────────────────────

## 这块地所在的“一段街”：同一条街（group）里沿路连在一起的地（正格），能盖多大的房子只看这一段。
## 同名的街被别的格子隔开时是几段（例如一圈图的河南中路是 3 段各 1 块，只能盖平房）。
## 返回这一段的地块和能盖的最大房子每块地的租金单价。
static func _street(game, tile: int) -> Dictionary:
	var tiles: Array = segment_of(game, tile)
	var rents: Dictionary = game.prices()["rent"]
	var best := int(rents.get("flat", 0))
	for lv in game.rules.get("houses", {}).get("levels", []):
		if int(lv["lots"]) <= tiles.size():
			best = maxi(best, int(rents.get(str(lv["rent"]), 0)))
	return {"tiles": tiles, "best_unit": best, "flat_unit": int(rents.get("flat", 0))}


## 这块地所在的一段街（正格列表，按地图算一次）
static func segment_of(game, tile: int) -> Array:
	var board = game.board
	var key: int = board.get_instance_id()
	if not _segments.has(key):
		_segments[key] = _build_segments(board)
	return _segments[key].get(tile, [tile])


## 同一条街、沿路相邻（一格的 next 是另一格）的地连成一段。分身格换成正格。
static func _build_segments(board) -> Dictionary:
	var link := {}
	for t in board.tiles:
		var a: int = board.site(int(t["id"]))
		if board.get_tile(a)["type"] != "land":
			continue
		link.get_or_add(a, {})
		for nx in board.next_tiles(int(t["id"])):
			var b: int = board.site(int(nx))
			var tb: Dictionary = board.get_tile(b)
			if b != a and tb["type"] == "land" \
					and str(tb.get("group", "")) == str(board.get_tile(a).get("group", "")):
				link[a][b] = true
				link.get_or_add(b, {})[a] = true
	var out := {}
	for start in link:
		if out.has(start):
			continue
		var seg: Array = [start]
		var i := 0
		while i < seg.size():
			for nb in link[seg[i]]:
				if not seg.has(nb):
					seg.append(nb)
			i += 1
		seg.sort()
		for t in seg:
			out[t] = seg
	return out


## 地产归 owner 时每块地预计的租金（一次停下）。
## 地：有房子按房子租金平摊到每块地，和“发展后租金”取大的；企业：按 owner 手上同行业的家数算。
static func expected_rent(game, tile: int, owner: int) -> float:
	var t: Dictionary = game.board.get_tile(tile)
	if t["type"] == "company":
		var industry := str(t.get("industry", ""))
		var count := 1
		for i in game.props:
			var c: Dictionary = game.board.get_tile(i)
			if i != tile and c["type"] == "company" and str(c.get("industry", "")) == industry \
					and game.owner_of(i) == owner:
				count += 1
		var mult := int(game.rules.get("companies", {}).get("same_industry_multiplier", 2))
		return float(int(t["rent"]) * int(pow(mult, count - 1)))
	var pct := int(game.props[tile]["pct"])
	var now := 0.0
	var hid: int = game.house_at(tile)
	if hid != 0:
		now = float(game.house_rent(hid)) / game.houses[hid]["tiles"].size()
	else:
		now = float(game.rent_of(tile))
	var st := _street(game, tile)
	var mine := 0
	for s in st["tiles"]:
		if s == tile or game.owner_of(s) == owner:
			mine += 1
	var share := float(mine) / maxi(1, st["tiles"].size())
	var power := param(game, owner, "street_share_power", 2) if owner >= 0 else 2.0
	var unit: float = st["flat_unit"] + (st["best_unit"] - st["flat_unit"]) * pow(share, power)
	return maxf(now, unit * pct / 100.0)


## 地产归 owner 时每天预计收的租：还活着的对手每人每天掷一次
static func income_per_day(game, tile: int, owner: int) -> float:
	return expected_rent(game, tile, owner) * float(visit_freq(game).get(tile, 0.0)) \
			* _opponents(game, owner)


## 这块地产对 pi 值多少（万圆）：价格 + 估价天数 × 归 pi 后每天预计收入，再乘上 pi 这局的估价误差
static func property_worth(game, pi: int, tile: int) -> float:
	var worth: float = game.property_price(tile) + param(game, pi, "value_horizon_days", 30) \
			* income_per_day(game, tile, pi)
	return worth * (1.0 + noise(game, pi, tile))


# ───────────────────────── 性格：估价误差、喜欢的地 ─────────────────────────
## 每局开局后第一次用到时随机定好，存在 Player.ai_memory 里（存档时一起存），这局不变。

## pi 对这块地产的估价误差（−value_noise_pct% 到 +value_noise_pct%，小数）。
## 简化：别人估 pi 的价值时也用 pi 自己的误差。
static func noise(game, pi: int, tile: int) -> float:
	var pct := param(game, pi, "value_noise_pct", 0)
	if pct <= 0.0:
		return 0.0
	var table: Dictionary = game.players[pi].ai_memory.get_or_add("value_noise", {})
	var key := str(tile)
	if not table.has(key):
		table[key] = game.rng.randf_range(-pct, pct) / 100.0
	return float(table[key])


## pi 这局“喜欢的地”（favorite_count 块，随机挑）：见到就买，任何交易都不卖
static func favorites(game, pi: int) -> Array:
	var count := int(param(game, pi, "favorite_count", 0))
	if count <= 0:
		return []
	var memory: Dictionary = game.players[pi].ai_memory
	if not memory.has("favorites"):
		var lands: Array = []
		for t in game.props:
			if game.board.get_tile(t)["type"] == "land":
				lands.append(t)
		lands.sort()
		var picked: Array = []
		while picked.size() < mini(count, lands.size()):
			var t: int = lands[game.rng.randi() % lands.size()]
			if not picked.has(t):
				picked.append(t)
		memory["favorites"] = picked
	return memory["favorites"]


# ───────────────────────── 停在某格 ─────────────────────────

## pi 停在 tile 的得失（不含路过的效果）
static func stop_value(game, pi: int, tile: int) -> float:
	var p = game.players[pi]
	var t: Dictionary = game.board.get_tile(tile)
	var site: int = game.board.site(tile)
	match str(t["type"]):
		"land", "company":
			var owner: int = game.owner_of(site)
			if owner == pi:
				return 0.0
			if owner < 0:
				var price: int = game.property_price(site)
				if p.cash < price:
					return 0.0
				return maxf(0.0, property_worth(game, pi, site) - price)
			return -_rent_cost(game, pi, site)
		"chance":
			return param(game, pi, "chance_value", 0)
		"tax":
			return -game.total_assets(pi) * int(game.rules["tax"]["pct_of_total_assets"]) / 100.0
		"bank":
			return param(game, pi, "bank_stop_value", 0)
		"jail":
			var jail: Dictionary = game.rules["jail"]
			var bail := (int(jail["bail_min"]) + int(jail["bail_max"])) / 2.0
			if p.cash >= int(jail["bail_max"]):
				return -bail
			return -param(game, pi, "skip_day_value", 30) * int(jail["days"])
		"park":
			return -param(game, pi, "skip_day_value", 30) * int(game.rules["park"]["rest_days"])
		"church":
			return param(game, pi, "believer_value", -10)
		"race_course":
			var prizes: Array = game.rules["race_course"]["prizes"]
			var sum := 0.0
			for x in prizes:
				sum += int(x)
			return sum / maxi(1, prizes.size())
	return 0.0


## 停在别人的地产上实际要付的（考虑状态减免）；付不起 = 破产，按失去全部资产再加破产罚分算
static func _rent_cost(game, pi: int, site: int) -> float:
	var p = game.players[pi]
	var kind: String = p.status_kind()
	if kind == "arsonist" and game.house_at(site) != 0:
		return 0.0
	if kind == "robber" and game.board.get_tile(site)["type"] == "company":
		return -property_worth(game, pi, site)
	var rent := _plain_rent(game, pi, site)
	if rent > p.cash + p.deposit:
		return rent + game.total_assets(pi) + param(game, pi, "bankrupt_penalty", 1000)
	return rent


# ───────────────────────── 走一步一步算 ─────────────────────────

## 从 pos 再走 steps 步的得失。路口：自己能选的取最好，随机路口取平均。
## ctx = {passed: {正格: true}, church: 已路过教堂次数}，会被复制，不影响调用者。
static func walk_value(game, pi: int, pos: int, steps: int, ctx: Dictionary) -> float:
	var opts: Array = game.board.next_tiles(pos)
	if opts.size() == 1:
		return _enter(game, pi, int(opts[0]), steps, ctx)
	var vals: Array = []
	for o in opts:
		vals.append(_enter(game, pi, int(o), steps, ctx.duplicate(true)))
	if game.board.crossroad_mode(pos) == "choice":
		return vals.max()
	var sum := 0.0
	for v in vals:
		sum += v
	return sum / vals.size()


## 走进 tile，这一步之后还剩 steps - 1 步
static func _enter(game, pi: int, tile: int, steps: int, ctx: Dictionary) -> float:
	var v := _meet_value(game, pi, tile)
	if steps <= 1:
		return v + stop_value(game, pi, tile)
	v += _pass_value(game, pi, tile, ctx)
	return v + walk_value(game, pi, tile, steps - 1, ctx)


## 路过的效果：银行（能存取款）、教堂（每路过几次捐一次）
static func _pass_value(game, pi: int, tile: int, ctx: Dictionary) -> float:
	var site: int = game.board.site(tile)
	var passed: Dictionary = ctx.get_or_add("passed", {})
	if passed.has(site):
		return 0.0
	passed[site] = true
	match str(game.board.get_tile(tile)["type"]):
		"bank":
			return param(game, pi, "bank_pass_value", 10)
		"church":
			var count := int(ctx.get("church", game.players[pi].church_passes)) + 1
			ctx["church"] = count
			if count % int(game.rules["church"]["pass_every"]) == 0:
				return -float(game.rules["church"]["pass_donation"])
	return 0.0


## 遇到别的玩家：自己是小偷就偷走他的现金，自己是信徒就施舍现金的一部分
static func _meet_value(game, pi: int, tile: int) -> float:
	var p = game.players[pi]
	var kind: String = p.status_kind()
	if kind != "thief" and kind != "believer":
		return 0.0
	for q in game.players:
		if q.index == pi or q.bankrupt or q.pos != tile:
			continue
		if kind == "thief":
			return float(q.cash)
		var divisor := int(game.rules.get("states", {}).get("believer_alms_divisor", 4))
		return -float(p.cash) / divisor
	return 0.0


## 路口各方向的得失：[{option: 第一格, value: 得失}]。没在等选方向时返回空。
static func direction_values(game, pi: int) -> Array:
	var out: Array = []
	if game.phase != "pending" or str(game.pending.get("type", "")) != "choose_direction":
		return out
	var ctx := {"passed": game.passed_this_move()}
	for o in game.pending["options"]:
		var v := _enter(game, pi, int(o), int(game.pending["steps"]), ctx.duplicate(true))
		out.append({"option": int(o), "value": v})
	return out


## 从 pi 现在的位置掷一次骰子：{expected: 期望得失, worst: 最坏得失}（路口按自己会选最好的算）
static func roll_outcomes(game, pi: int) -> Dictionary:
	var dice := dice_distribution(game)
	var expected := 0.0
	var worst := INF
	for d in dice:
		var v := walk_value(game, pi, game.players[pi].pos, int(d), {"passed": {}})
		expected += v * dice[d]
		worst = minf(worst, v)
	return {"expected": expected, "worst": worst}


# ───────────────────────── 留钱、建房 ─────────────────────────

## 从 pi 现在的位置掷一次骰子，所有可能停下的格子里最多要付多少租（路口每个方向都算，不考虑付不付得起）
static func rent_risk(game, pi: int) -> float:
	var stops := {}
	var dice := dice_distribution(game)
	for d in dice:
		_collect_stops(game.board, game.players[pi].pos, int(d), stops)
	var worst := 0.0
	for t in stops:
		var site: int = game.board.site(t)
		var t_type: String = game.board.get_tile(site)["type"]
		if (t_type == "land" or t_type == "company") and game.owner_of(site) >= 0 \
				and game.owner_of(site) != pi:
			worst = maxf(worst, _plain_rent(game, pi, site))
	return worst


static func _collect_stops(board, pos: int, steps: int, out: Dictionary) -> void:
	if steps == 0:
		out[pos] = true
		return
	for o in board.next_tiles(pos):
		_collect_stops(board, int(o), steps - 1, out)


## 停在别人地产上要付的租（考虑状态减免，不考虑付不付得起）
static func _plain_rent(game, pi: int, site: int) -> float:
	var p = game.players[pi]
	var kind: String = p.status_kind()
	if game.props[site]["mortgaged"] or Game.NO_RENT_STATES.has(
			game.players[game.owner_of(site)].status_kind()) or kind == "free_rent":
		return 0.0
	var rent := float(game.rent_of(site))
	if kind == "double_rent":
		rent *= 2
	elif kind == "half_rent":
		rent *= 0.5
	return rent


## 想留下的钱（现金 + 存款）：下一次掷骰最多可能付的租 × reserve_pct%
static func reserve(game, pi: int) -> float:
	return rent_risk(game, pi) * param(game, pi, "reserve_pct", 100) / 100.0


static func _opponents(game, owner: int) -> int:
	var n := 0
	for p in game.alive_players():
		if p.index != owner:
			n += 1
	return n


## 这几块地连在一起每天被停下几次（一栋房子任何一块被停到都收整栋的租）
static func _landings_per_day(game, owner: int, tiles: Array) -> float:
	var freq := visit_freq(game)
	var f := 0.0
	for t in tiles:
		f += float(freq.get(t, 0.0))
	return f * _opponents(game, owner)


## 这几块地现在每天预计收的租（地上可能有好几栋小房子或空地，按每块地各自的租金算）
static func _tiles_income(game, owner: int, tiles: Array) -> float:
	var freq := visit_freq(game)
	var total := 0.0
	for t in tiles:
		total += game.rent_of(t) * float(freq.get(t, 0.0))
	return total * _opponents(game, owner)


## 在 tiles 上盖 kind 值不值：估价天数 × (新房子每天的租 − 这些地现在每天的租) − 要付的钱
static func build_gain(game, pi: int, kind: String, tiles: Array) -> float:
	var after: float = game.rent_for(kind, tiles) * _landings_per_day(game, pi, tiles)
	var before := _tiles_income(game, pi, tiles)
	return param(game, pi, "value_horizon_days", 30) * (after - before) \
			- game.build_price(kind, tiles)


## 升级房子 hid 值不值
static func upgrade_gain(game, pi: int, hid: int) -> float:
	var h: Dictionary = game.houses[hid]
	var to: String = game.upgrade_kind(h["kind"])
	if to == "":
		return -INF
	var more: float = (game.rent_for(to, h["tiles"]) - game.house_rent(hid)) \
			* _landings_per_day(game, pi, h["tiles"])
	return param(game, pi, "value_horizon_days", 30) * more - game.upgrade_fee(h["tiles"])
