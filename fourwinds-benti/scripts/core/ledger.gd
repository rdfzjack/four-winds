extends RefCounted
## 新框架的“三本账”（第 6a 步返工，设计见 docs/ai_design.md 的 H 节）。只读局面，不改局面（临时改的都会改回来）。
##
## 一个玩家的“局面值”：
##   局面值 = 撑得下去的机会 × (现金 + 存款 + 他所有地产的价值)
##   - 地产的价值（第一本账）：property_worth，这局剩下的天数里预计收的租 + 凑齐整段街盖房后多收的
##     （按凑得齐的可能性、主人盖不盖得起打折，扣造价）+ 抵押能拿回的钱
##   - 撑得下去的机会（第二本账）：survival，接下来 safety_rolls 次掷骰都不碰上付不起的租的概率。
##     钱越少越容易付不起，所以缺钱时每一块钱都很值钱，地产也跟着打折
##   - 破产的人的资产归债主（原版规则）：撑不下去的那部分，按他最可能在谁的地上破产，算进那个人的局面值
## 我的得分（第三本账，赢的机会）：score = 我的局面值 ÷ (我的局面值 + rival_weight_pct% × 对手里最大的局面值)
##   比的是名次：对手多赚的，只有让最强的那个更强时才是损失；我自己快不行时，对手多赚多少影响也小
##   （反正赢的机会都很小），我强的时候帮人凑街让他跑到最前面，损失就大。
## 所有决定（买地、盖房、交易）都是比较“做”和“不做”的得分。交易的得失换算成钱（money_gain），方便和交出去的东西比。
##
## 用到的参数（profiles.json 的 standard 表形态，说明见那里的 params）：
##   game_length_days / horizon_min_days  这局大概打多少天 / 剩下的天数最少按几天算
##   value_noise_pct      估价误差（标准 AI 为 0）
##   street_chance_pct    这段街缺的地，每块最后能弄到手的可能性（对手也在收这段街时减半）
##   street_obsession_pct 想凑齐的街多算几成（标准 AI 为 0，角色以后用）
##   safety_rolls         安全线：看接下来几次掷骰（0 = 不看现金流）
##   rival_weight_pct     最强对手的局面值算多重

const Valuer = preload("res://scripts/core/valuer.gd")

## 一次决定里复用的结果（局面不变时估价不变）。每个决定开始时调 begin() 清掉。
static var _worth_cache: Dictionary = {}     ## "viewer:owner:tile" -> 价值
static var _exposure_cache: Dictionary = {}  ## 玩家 -> {正格: 租金}


## 一个决定开始前调用：局面可能变了，清掉复用的结果
static func begin() -> void:
	_worth_cache.clear()
	_exposure_cache.clear()


static func param(game, pi: int, key: String, fallback: float) -> float:
	return Valuer.param(game, pi, key, fallback)


## 这局大概还剩几天
static func days_left(game, pi: int) -> float:
	return maxf(param(game, pi, "horizon_min_days", 20),
			param(game, pi, "game_length_days", 90) - game.day)


static func _opponents(game, owner: int) -> int:
	var n := 0
	for p in game.alive_players():
		if p.index != owner:
			n += 1
	return maxi(1, n)


# ───────────────────────── 第一本账：地产值多少 ─────────────────────────

## viewer 看来，tile 归 owner 时值多少（按现在局面上的主人和房子）
static func property_worth(game, viewer: int, owner: int, tile: int) -> float:
	var freq: float = float(Valuer.visit_freq(game).get(tile, 0.0))
	var per_day := freq * _opponents(game, owner)
	var days := days_left(game, viewer)
	var price: int = game.property_price(tile)
	var mortgage: Dictionary = game.rules.get("mortgage", {})
	var salvage := price * float(mortgage.get("payout_pct", 50)) / 100.0
	var t: Dictionary = game.board.get_tile(tile)
	var worth := 0.0
	if t["type"] == "company":
		worth = Valuer.expected_rent(game, tile, owner) * per_day * days + salvage
	else:
		worth = _rent_now(game, tile) * per_day * days + _development(game, viewer, owner, tile, days) \
				+ salvage
	if game.props[tile]["mortgaged"]:
		# 抵押中：要先花钱赎回才收租，抵押的钱已经拿过了
		worth -= salvage + price * float(mortgage.get("unmortgage_cost_pct", 60)) / 100.0
	return maxf(0.0, worth) * (1.0 + Valuer.noise(game, viewer, tile))


## 别人停在这块地上一次付多少（有房子付整栋房子的租金，房子占的哪块地被停到都一样）
static func _rent_now(game, tile: int) -> float:
	return float(game.rent_of(tile))


## 凑齐这段街盖最大的房子后多收的（扣造价），按凑得齐的可能性、盖不盖得起打折；还没盖的按剩下天数的一半算
static func _development(game, viewer: int, owner: int, tile: int, days: float) -> float:
	var seg: Array = Valuer.segment_of(game, tile)
	var best := _best_level(game, seg.size())
	if best.is_empty():
		return 0.0
	var pct := float(game.props[tile]["pct"])
	var unit := 0.0
	for key in best["cost"]:
		unit += float(game.prices()["build_cost"][key])
	var cost := unit * float(game.board.get_tile(tile).get("build_cost_pct", 100)) / 100.0
	# 停在这块地上付整栋大房子的租金（按这块地的地价系数估整栋）
	var rent_after := float(game.prices()["rent"][str(best["rent"])]) * pct / 100.0 * int(best["lots"])
	var extra := rent_after - _rent_now(game, tile)
	if extra <= 0.0:
		return 0.0
	var chance := _street_chance(game, viewer, owner, seg)
	# 房子还没盖：不知道什么时候盖，按剩下天数的一半算收入（盖了以后整段时间都按新租金算，所以早盖有好处）
	var wait := days / 2.0
	var per_day: float = float(Valuer.visit_freq(game).get(tile, 0.0)) * _opponents(game, owner)
	var gain := extra * per_day * (days - wait) - cost
	if gain <= 0.0:
		return 0.0
	# 盖不盖得起：主人的现金 + 存款不够盖整栋时，按够的比例打折（简化：不管交易里临时加减的钱）
	var p = game.players[owner]
	var afford := clampf((p.cash + p.deposit) / maxf(1.0, cost * int(best["lots"])), 0.0, 1.0)
	return chance * afford * gain * (1.0 + param(game, viewer, "street_obsession_pct", 0) / 100.0)


## 能盖在 lots 块地上的最大房子（租金单价最高的那种）
static func _best_level(game, lots: int) -> Dictionary:
	var best := {}
	var best_rent := -1.0
	for lv in game.rules.get("houses", {}).get("levels", []):
		if int(lv["lots"]) > lots:
			continue
		var rent := float(game.prices()["rent"].get(str(lv["rent"]), 0))
		if rent > best_rent:
			best = lv
			best_rent = rent
	return best


## owner 最后凑齐这段街的可能性：自己的算 1；没人买的每块 street_chance_pct%；
## 在对手手里的也是 street_chance_pct%（对手在这段街也有两块以上时，他也在收，减半）
static func _street_chance(game, viewer: int, owner: int, seg: Array) -> float:
	var base := param(game, viewer, "street_chance_pct", 50) / 100.0
	var count := {}
	for s in seg:
		var o: int = game.owner_of(s)
		count[o] = int(count.get(o, 0)) + 1
	var chance := 1.0
	for s in seg:
		var o: int = game.owner_of(s)
		if o == owner:
			continue
		if o >= 0 and int(count[o]) >= 2:
			chance *= base / 2.0
		else:
			chance *= base
	return chance


# ───────────────────────── 第二本账：撑不撑得下去 ─────────────────────────

## pi 手上有 money（现金 + 存款）时，接下来 safety_rolls 次掷骰都付得起租的概率（viewer 的看法）。
## 第一次按现在的位置算，之后按长期停下的概率算，每次扣掉平均要付的租。
static func survival(game, viewer: int, pi: int, money: float, rents: Dictionary = {}) -> float:
	var rolls := int(param(game, viewer, "safety_rolls", 10))
	if rolls <= 0:
		return 1.0
	if money < 0.0:
		return 0.0
	if rents.is_empty():
		rents = exposure(game, pi)
	if rents.is_empty():
		return 1.0
	var freq := Valuer.visit_freq(game)
	# 按租金从高到低排，tail[i] = 租金 ≥ 第 i 个的那些格子停下概率之和
	var list: Array = []
	var expected := 0.0
	for t in rents:
		var f := float(freq.get(t, 0.0))
		expected += rents[t] * f
		list.append([float(rents[t]), f])
	list.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var alive := 1.0 - _first_roll_risk(game, pi, money, rents)
	for i in range(1, rolls):
		var left := money - expected * i
		var risk := 0.0
		for item in list:
			if item[0] <= left:
				break
			risk += item[1]
		alive *= 1.0 - minf(1.0, risk)
	return alive


## pi 停在别人地产上要付的租：{正格: 租金}（考虑状态减免）。dirty 为空时用这次决定里算过的结果；
## 不为空时在算过的结果上只重算 dirty 这些格子（临时换了主人或房子的）。
static func exposure(game, pi: int, dirty: Array = []) -> Dictionary:
	if not _exposure_cache.has(pi):
		var all := {}
		for t in game.props:
			_put_rent(game, pi, t, all)
		_exposure_cache[pi] = all
	if dirty.is_empty():
		return _exposure_cache[pi]
	var out: Dictionary = _exposure_cache[pi].duplicate()
	for t in dirty:
		out.erase(t)
		_put_rent(game, pi, t, out)
	return out


static func _put_rent(game, pi: int, t: int, out: Dictionary) -> void:
	var o: int = game.owner_of(t)
	if o < 0 or o == pi or game.players[o].bankrupt:
		return
	var rent: float = Valuer._plain_rent(game, pi, t)
	if rent > 0.0:
		out[t] = rent


## 从现在的位置掷一次，停在付不起的地上的概率（路口按平均分）
static func _first_roll_risk(game, pi: int, money: float, rents: Dictionary) -> float:
	var dice := Valuer.dice_distribution(game)
	var risk := 0.0
	for d in dice:
		var stops := {}
		_stops(game.board, game.players[pi].pos, int(d), 1.0, stops)
		for s in stops:
			var site: int = game.board.site(s)
			if float(rents.get(site, 0.0)) > money:
				risk += dice[d] * stops[s]
	return minf(1.0, risk)


static func _stops(board, pos: int, steps: int, weight: float, out: Dictionary) -> void:
	if steps == 0:
		out[pos] = float(out.get(pos, 0.0)) + weight
		return
	var opts: Array = board.next_tiles(pos)
	for o in opts:
		_stops(board, int(o), steps - 1, weight / opts.size(), out)


# ───────────────────────── 局面值和得分 ─────────────────────────

## viewer 看来每个人的局面值（数组，下标 = 玩家编号，破产的是 0）。
## change = {地块: 新主人} 临时换主人，money = {玩家: 现金变化} 临时加减现金，算完改回来。
## calm = {玩家: true}：算这个人时不看他缺不缺钱（撑得下去的机会按 1 算），出公道价用（⑩）。
## touched = 调用者临时改过房子的地块（要重算的）。换主人的地块所在的整段街 / 整个行业也会重算，其余用这次决定里算过的。
static func positions(game, viewer: int, change: Dictionary = {}, money: Dictionary = {},
		calm: Dictionary = {}, touched: Array = []) -> Array:
	var dirty := _dirty(game, change.keys() + touched)
	var saved := {}
	for t in change:
		saved[t] = game.props[t]["owner"]
		game.props[t]["owner"] = change[t]
	var worth := {}
	for p in game.players:
		worth[p.index] = 0.0
	for t in game.props:
		var o: int = game.owner_of(t)
		if o < 0 or game.players[o].bankrupt:
			continue
		var key := "%d:%d:%d" % [viewer, o, t]
		var w := 0.0
		if dirty.has(t) or not _worth_cache.has(key):
			w = property_worth(game, viewer, o, t)
			if not dirty.has(t):
				_worth_cache[key] = w
		else:
			w = _worth_cache[key]
		worth[o] += w
	var out: Array = []
	var lost := {}  ## 玩家 -> [撑不下去的那部分资产, 他的租金风险表]
	for p in game.players:
		if p.bankrupt:
			out.append(0.0)
			continue
		var m: float = p.cash + p.deposit + float(money.get(p.index, 0))
		var assets := maxf(0.0, m + worth[p.index])
		var alive := 1.0
		if not calm.has(p.index):
			var rents := exposure(game, p.index, dirty.keys())
			alive = survival(game, viewer, p.index, m, rents)
			lost[p.index] = [(1.0 - alive) * assets, rents]
		out.append(alive * assets)
	_inherit(game, out, lost)
	for t in saved:
		game.props[t]["owner"] = saved[t]
	return out


## 撑不下去的那部分资产归债主：按他每次掷骰停在各人地上要付的租（停下概率 × 租金）分给各人
static func _inherit(game, out: Array, lost: Dictionary) -> void:
	var freq := Valuer.visit_freq(game)
	for pi in lost:
		var amount: float = lost[pi][0]
		if amount <= 0.0:
			continue
		var share := {}
		var total := 0.0
		var rents: Dictionary = lost[pi][1]
		for t in rents:
			var w: float = rents[t] * float(freq.get(t, 0.0))
			var o: int = game.owner_of(t)
			share[o] = float(share.get(o, 0.0)) + w
			total += w
		if total <= 0.0:
			continue
		for o in share:
			if o >= 0 and not game.players[o].bankrupt:
				out[o] += amount * share[o] / total


## 改了这些地块以后估价会变的地块：同一段街的地、同一行业的企业
static func _dirty(game, tiles: Array) -> Dictionary:
	var out := {}
	for t in tiles:
		var tile: Dictionary = game.board.get_tile(t)
		if tile["type"] == "company":
			var industry := str(tile.get("industry", ""))
			for c in game.props:
				var ct: Dictionary = game.board.get_tile(c)
				if ct["type"] == "company" and str(ct.get("industry", "")) == industry:
					out[c] = true
		else:
			for s in Valuer.segment_of(game, t):
				out[s] = true
	return out


## pi 的得分（赢的机会）：自己的局面值 ÷ (自己的 + rival_weight_pct% × 对手里最大的局面值)
static func score_of(game, pi: int, pos: Array, weight: float = -1.0) -> float:
	if weight < 0.0:
		weight = param(game, pi, "rival_weight_pct", 100) / 100.0
	var top := _top(game, pi, pos)
	var mine: float = pos[pi]
	if mine + weight * top <= 0.0:
		return 0.0
	return mine / (mine + weight * top)


static func _top(game, pi: int, pos: Array) -> float:
	var top := 0.0
	for p in game.alive_players():
		if p.index != pi:
			top = maxf(top, float(pos[p.index]))
	return top


## 得分变化换算成钱：得分对自己局面值的变化率是 w·top ÷ (mine + w·top)²，
## 得分差 ÷ 它 ≈ “相当于自己多了多少钱”。base 是变化前的局面值。
static func money_gain(game, pi: int, base: Array, after: Array, weight: float = -1.0) -> float:
	if weight < 0.0:
		weight = param(game, pi, "rival_weight_pct", 100) / 100.0
	var top := weight * _top(game, pi, base)
	var mine: float = base[pi]
	var slope := top / maxf(1.0, (mine + top) * (mine + top))
	var diff := score_of(game, pi, after, weight) - score_of(game, pi, base, weight)
	if slope <= 0.0:
		return float(after[pi]) - mine
	return diff / slope
