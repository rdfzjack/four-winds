extends RefCounted
## 新框架的标准 AI（ai 版本 standard_v2，第 6a 步返工）。用法和别的 AI 一样：StdAi.step(game)，经过 ai.gd 调用。
## 所有决定都比较“做”和“不做”的得分（ledger.gd 的三本账），设计见 docs/ai_design.md 的 H 节。
##   买地 / 企业：买下 vs 不买（不买时这块可能被某个对手买走）
##   盖房、升级：盖 vs 不盖（钱少时撑下去的机会变小，所以不会盖到没钱）
##   回答交易：成交 vs 不成交；差一点时还价一次，要对方多给现金
##   发起交易：向对手要凑街的地（能拿用不上的地换就先试换地）。算出“我最多肯给”和“猜对方最少要”，
##            出价 = 对方最少要的 + 两者之差 ÷ 还活着的人数（多出来的好处按人数分给对方）
## 路口：见 best_direction（参数 direction_by_ledger 可以切回旧选法）。
## 还没改、照旧的：拍卖出价（trader.gd，作者定先不改）、银行存取 / 保释 / 赎回（原版 AI）。
## 被拒后收敛（几天不找同一人、被拒几次放弃、被拒一次加价）照 trader.gd 的做法。
##
## 性格用的数（标准 AI 都是“不偏”的值，角色以后在自己的参数组里改，见 H 节）：
##   partner_attitude_pct  ⑥ 对交易对象的态度：正 = 肯让一点（最多让出自己交出去的东西的这么多 %），
##                         负 = 对方多赚的部分算成自己额外的损失（损人不利己）
##   partner_attitude_ahead_pct / partner_attitude_behind_pct  ⑥ 自己比交易对象领先 / 落后时，上一项随差距怎么变
##   decision_band_pct  ⑦ 决定的随机范围（交易得失在 ± 这么多 % 以内按概率答应；主动做的事好处要够大）
##   ask_up_pct         ⑧a 要价虚高：别人找我时，好处不到交出去的东西的这么多 % 就先还价往上要
##   bid_down_pct       ⑧a' 开价压低：我找别人时开 公道价 ÷ (1 + 这么多 %)，被拒一次加 trade_raise_pct%
##   counter_range_pct  ⑧b 差多远还肯还价：要对方多给的钱超过交出去的东西的这么多 %，直接拒绝
##   trade_propose_pct  ⑨ 主动找人交易的概率
##   distress_use_pct   ⑩ 看不看缺钱：小于 100 时，出价不压缺钱的对方，回答时也不因为自己缺钱就贱卖

const Brain = preload("res://scripts/core/brain.gd")
const Valuer = preload("res://scripts/core/valuer.gd")
const Trader = preload("res://scripts/core/trader.gd")
const NewAi = preload("res://scripts/core/new_ai.gd")
const Ledger = preload("res://scripts/core/ledger.gd")

const FAKE_HOUSE := 999999


static func param(game, pi: int, key: String, fallback: float) -> float:
	return Valuer.param(game, pi, key, fallback)


static func step(game) -> bool:
	if game.phase == "over" or game.players[game.actor()].human:
		return false
	var pi: int = game.actor()
	if game.phase == "pre_roll":
		if not _improve(game):
			game.roll()
		return true
	if game.phase == "pending":
		match str(game.pending.get("type", "")):
			"choose_direction":
				game.choose_direction(best_direction(game, pi))
				return true
			"trade":
				answer(game, pi)
				return true
			"auction":
				Trader.auction_turn(game, pi)
				return true
			"buy_land", "buy_company":
				if wants_property(game, pi, int(game.pending["tile"])):
					game.buy()
				else:
					game.decline()
				return true
	return Brain.step(game)


## 掷骰前做一件事，做了返回 true。顺序：交易 → 建房 → 升级 → 赎回（抵押、拍卖按开关，现在关着）
static func _improve(game) -> bool:
	if propose_step(game):
		return true
	if _build_step(game):
		return true
	if _upgrade_step(game):
		return true
	if Brain._scoring("ai_mortgage", 1) == 1 and Brain._mortgage_step(game):
		return true
	if Brain._unmortgage_step(game):
		return true
	return Brain._scoring("ai_auction", 1) == 1 and Brain._auction_step(game)


# ───────────────────────── 路口 ─────────────────────────

## 路口选方向：每个方向一步步走完，算停下（和路过）的得失，选最好的。direction_by_ledger = 0 时用旧框架的
## 选法（valuer.gd，空地估得偏高，会被能买地的方向吸引）。新选法只把“停到没人买的地上”换成三本账的估价，
## 付租、坐牢、机会卡等照 valuer.gd。后面的路口：能选的取最好，随机的取平均。
static func best_direction(game, pi: int) -> int:
	if param(game, pi, "direction_by_ledger", 1) < 1:
		return NewAi.best_direction(game, pi)
	Ledger.begin()
	var best := -1
	var best_value := -INF
	var ctx := {"passed": game.passed_this_move()}
	for o in game.pending["options"]:
		var v := _enter(game, pi, int(o), int(game.pending["steps"]), ctx.duplicate(true))
		if v > best_value:
			best = int(o)
			best_value = v
	return best


static func _walk(game, pi: int, pos: int, steps: int, ctx: Dictionary) -> float:
	var opts: Array = game.board.next_tiles(pos)
	if opts.size() == 1:
		return _enter(game, pi, int(opts[0]), steps, ctx)
	var vals: Array = []
	for o in opts:
		vals.append(_enter(game, pi, int(o), steps, ctx.duplicate(true)))
	if game.crossroad_mode(pos) == "choice":
		return vals.max()
	var sum := 0.0
	for v in vals:
		sum += v
	return sum / vals.size()


static func _enter(game, pi: int, tile: int, steps: int, ctx: Dictionary) -> float:
	var v := Valuer._meet_value(game, pi, tile)
	if steps <= 1:
		return v + _stop_value(game, pi, tile)
	v += Valuer._pass_value(game, pi, tile, ctx)
	return v + _walk(game, pi, tile, steps - 1, ctx)


## 停在这格的得失：没人买的地 / 企业按三本账（值多少 − 价格，买不起算 0），其余照 valuer.gd
static func _stop_value(game, pi: int, tile: int) -> float:
	var site: int = game.board.site(tile)
	var t: Dictionary = game.board.get_tile(site)
	if (t["type"] == "land" or t["type"] == "company") and game.owner_of(site) < 0:
		var price: int = game.property_price(site)
		if game.players[pi].cash < price:
			return 0.0
		return maxf(0.0, Ledger.property_worth(game, pi, pi, site) - price)
	return Valuer.stop_value(game, pi, tile)


# ───────────────────────── 买地 ─────────────────────────

## 买下 vs 不买。不买时：每个对手各有 1 / 活着的人数 的可能以后买走它（只算买了对他有利的对手），
## 剩下的可能还没人买。
static func wants_property(game, pi: int, tile: int) -> bool:
	var price: int = game.property_price(tile)
	if game.players[pi].cash < price:
		return false
	Ledger.begin()
	var base := Ledger.positions(game, pi)
	var now := Ledger.score_of(game, pi, base)
	var bought := Ledger.score_of(game, pi, Ledger.positions(game, pi, {tile: pi}, {pi: -price}))
	var alive: Array = game.alive_players()
	var share := 1.0 / alive.size()
	var skip := now * share
	for q in alive:
		if q.index == pi:
			continue
		# 对手买了对他自己有利（按标准的账猜）、而且付得起，才算他会买走；否则还是没人买
		var pos := Ledger.positions(game, pi, {tile: q.index}, {q.index: -price})
		var wants: bool = q.cash >= price \
				and Ledger.score_of(game, q.index, pos, 1.0) > Ledger.score_of(game, q.index, base, 1.0)
		skip += share * (Ledger.score_of(game, pi, pos) if wants else now)
	var buy := worth_doing(game, pi, Ledger.to_money(game, pi, base, bought - skip), price)
	if game.record_history:
		var p = game.players[pi]
		game.ai_think(pi, "buy", {"tile": tile, "buy": buy, "price": price, "score_buy": bought,
				"score_skip": skip, "score_now": now, "cash": p.cash, "deposit": p.deposit,
				"worth": Ledger.property_worth(game, pi, pi, tile),
				"survival_after": Ledger.survival(game, pi, pi, p.cash + p.deposit - price)})
	return buy


# ───────────────────────── 盖房、升级 ─────────────────────────

## 临时在 tiles 上放一栋 kind（或把房子 hid 换成 kind），算完 fn 再改回来
static func _with_house(game, owner: int, kind: String, tiles: Array, fn: Callable) -> Variant:
	var saved := {}
	for t in tiles:
		saved[t] = game.props[t]["house"]
		game.props[t]["house"] = FAKE_HOUSE
	game.houses[FAKE_HOUSE] = {"kind": kind, "owner": owner, "tiles": tiles}
	var out: Variant = fn.call()
	game.houses.erase(FAKE_HOUSE)
	for t in saved:
		game.props[t]["house"] = saved[t]
	return out


## 在现在能建的里挑得分涨得最多的；现金不够但加上存款够时，记下差多少（路过银行时多取）
static func _build_step(game) -> bool:
	var pi: int = game.current
	var p = game.players[pi]
	p.ai_memory["cash_need"] = 0
	Ledger.begin()
	var base := Ledger.positions(game, pi)
	var now := Ledger.score_of(game, pi, base)
	var best := {}
	var best_gain := 0.0
	for c in game.build_choices(pi):
		var why := str(c["why"])
		if why != "" and not why.begins_with("现金不够"):
			continue
		var cost := int(c["cost"])
		if p.cash + p.deposit < cost:
			continue
		var after: float = _with_house(game, pi, str(c["kind"]), c["tiles"], func() -> float:
			return Ledger.score_of(game, pi, Ledger.positions(game, pi, {}, {pi: -cost}, {}, c["tiles"])))
		if after - now > best_gain:
			best = c
			best_gain = after - now
	if best.is_empty() or not worth_doing(game, pi, Ledger.to_money(game, pi, base, best_gain),
			int(best["cost"])):
		return false
	if game.record_history:
		game.ai_think(pi, "build", {"kind": best["kind"], "tiles": best["tiles"], "cost": best["cost"],
				"gain": best_gain, "cash": p.cash, "deposit": p.deposit})
	if str(best["why"]) != "":
		p.ai_memory["cash_need"] = int(best["cost"]) - p.cash
		return false
	return game.build(pi, str(best["kind"]), best["tiles"]) == ""


static func _upgrade_step(game) -> bool:
	var pi: int = game.current
	Ledger.begin()
	var base := Ledger.positions(game, pi)
	var now := Ledger.score_of(game, pi, base)
	var best := 0
	var best_gain := 0.0
	for hid in game.houses:
		if game.houses[hid]["owner"] != pi or game.why_cannot_upgrade(pi, hid) != "":
			continue
		var h: Dictionary = game.houses[hid]
		var fee: int = game.upgrade_fee(h["tiles"])
		var old: String = h["kind"]
		h["kind"] = game.upgrade_kind(old)
		var after := Ledger.score_of(game, pi, Ledger.positions(game, pi, {}, {pi: -fee}, {}, h["tiles"]))
		h["kind"] = old
		if after - now > best_gain:
			best = hid
			best_gain = after - now
	if best == 0 or not worth_doing(game, pi, Ledger.to_money(game, pi, base, best_gain),
			game.upgrade_fee(game.houses[best]["tiles"])):
		return false
	return game.upgrade(pi, best) == ""


# ───────────────────────── 交易 ─────────────────────────

## 交易对局面的改动：{change: {地块: 新主人}, money: {玩家: 现金变化}}
static func _effect(offer: Dictionary) -> Dictionary:
	var a := int(offer["from"])
	var b := int(offer["to"])
	var change := {}
	for t in offer["give"]:
		change[int(t)] = b
	for t in offer["get"]:
		change[int(t)] = a
	var flow := int(offer["get_cash"]) - int(offer["give_cash"])
	return {"change": change, "money": {a: flow, b: -flow}}


## x 看这笔交易：得分涨多少，换算成钱（加上对交易对象的态度），calm 见 Ledger.positions
static func trade_gain(game, x: int, offer: Dictionary, base: Array = [],
		calm: Dictionary = {}) -> float:
	var parts := trade_parts(game, x, offer, base, calm)
	return parts[0] + parts[1]


## [按账算的得失, 态度加减的部分]（都折成钱）
static func trade_parts(game, x: int, offer: Dictionary, base: Array = [],
		calm: Dictionary = {}) -> Array:
	if base.is_empty():
		base = Ledger.positions(game, x, {}, {}, calm)
	var e := _effect(offer)
	var after := Ledger.positions(game, x, e["change"], e["money"], calm)
	var g := Ledger.money_gain(game, x, base, after)
	var other := int(offer["to"]) if x == int(offer["from"]) else int(offer["from"])
	var a := attitude(game, x, other, base)
	if a >= 0.0:
		# 正的态度 = 肯让一点：最多让出自己交出去的东西的 a 那么多
		return [g, a * _given(game, x, offer)]
	# 负的态度 = 对方多赚的部分算成自己额外的损失（损人不利己）
	return [g, a * maxf(0.0, float(after[other]) - float(base[other]))]


## x 对交易对象多赚的部分怎么看（⑥）。lead = x 比对方领先的比例（−1 到 1）。标准 AI 为 0。
static func attitude(game, x: int, other: int, pos: Array) -> float:
	var lead := clampf((float(pos[x]) - float(pos[other])) / maxf(1.0, float(pos[x])), -1.0, 1.0)
	var slope := param(game, x, "partner_attitude_ahead_pct", 0) if lead > 0.0 \
			else param(game, x, "partner_attitude_behind_pct", 0)
	return (param(game, x, "partner_attitude_pct", 0) + slope * lead) / 100.0


## 回答时用的“冷静”名单：⑩ 小于 100 的人不因为自己缺钱就贱卖（算自己时不看撑不撑得下去）
static func _calm_self(game, x: int) -> Dictionary:
	return {x: true} if param(game, x, "distress_use_pct", 100) < 100 else {}


## x 在这笔交易里交出去的东西值多少（决定的随机范围按它的百分比算）
static func _given(game, x: int, offer: Dictionary) -> float:
	var mine: bool = x == int(offer["from"])
	var total := float(offer["give_cash"] if mine else offer["get_cash"])
	for t in (offer["give"] if mine else offer["get"]):
		total += Ledger.property_worth(game, x, x, int(t))
	return maxf(1.0, total)


## 自己主动做的事（买地、盖房、升级、提交易）值不值得做：好处（折成钱）≥ 动用的钱 × decision_band_pct% 一定做，
## 在 0 和它之间按比例的概率做，≤ 0 不做。这样为一点点好处（例如快破产时什么都几乎不值钱）不会乱动。
static func worth_doing(game, pi: int, gain: float, moved: float) -> bool:
	var band := param(game, pi, "decision_band_pct", 0) / 100.0 * maxf(1.0, moved)
	if gain <= 0.0:
		return false
	if band <= 0.0 or gain >= band:
		return true
	return game.rng.randf() < gain / band


## 答不答应：得分涨的超过随机范围一定答应，低于负的随机范围一定不答应，中间按比例
static func _accepts(game, x: int, g: float, given: float) -> bool:
	var band := param(game, x, "decision_band_pct", 0) / 100.0 * given
	if band <= 0.0:
		return g > 0.0
	if g >= band:
		return true
	if g <= -band:
		return false
	return game.rng.randf() < (g + band) / (2.0 * band)


static func answer(game, pi: int) -> void:
	Ledger.begin()
	var offer: Dictionary = game.pending["offer"]
	var calm := _calm_self(game, pi)
	var base := Ledger.positions(game, pi, {}, {}, calm)
	var parts := trade_parts(game, pi, offer, base, calm)
	var g: float = parts[0] + parts[1]
	var given := _given(game, pi, offer)
	var yes := _accepts(game, pi, g, given)
	var first: bool = game.pending["stage"] == "offer"
	var counter := {}
	var haggle := param(game, pi, "ask_up_pct", 0) / 100.0
	# ⑧a 要价虚高：好处不够这么多时先还价往上要（能答应的也先要）；不能答应的也试着还价
	if first and (not yes or (haggle > 0.0 and g < haggle * given)):
		counter = _counter(game, pi, offer, base, calm)
	_note_answer(game, pi, parts, yes, counter)
	if game.record_history:
		var p = game.players[pi]
		game.ai_think(pi, "trade_answer", {"offer": offer.duplicate(true),
				"stage": str(game.pending["stage"]), "gain": g, "gain_by_books": parts[0],
				"attitude": parts[1], "given": given, "accept": yes, "counter": counter,
				"cash": p.cash, "deposit": p.deposit,
				"survival": Ledger.survival(game, pi, pi, p.cash + p.deposit)})
	Ledger.begin()
	if not counter.is_empty() and game.trade_counter(counter) == "":
		return
	game.trade_answer(yes)


## 评测统计性格动作：grace（态度让我答应了按账不划算的）、spite（态度让我拒绝了按账划算的）、
## random_yes（随机范围里答应了不划算的）、haggle（能答应也先还价）
static func _note_answer(game, pi: int, parts: Array, yes: bool, counter: Dictionary) -> void:
	var books: float = parts[0]
	var total: float = parts[0] + parts[1]
	if yes and counter.is_empty() and books <= 0.0:
		game.ai_note(pi, "grace" if total > 0.0 else "random_yes")
	elif not yes and counter.is_empty() and books > 0.0 and total <= 0.0:
		game.ai_note(pi, "spite")
	elif yes and not counter.is_empty():
		game.ai_note(pi, "haggle")


## 还价：要发起人多给现金（先少要他的钱），回到自己的底价再加上要价虚高的那部分（⑧a）。
## 要多给的超过交出去的东西 × counter_range_pct%（⑧b）或者对方付不起，就不还价（返回 {}）。
static func _counter(game, pi: int, offer: Dictionary, base: Array, calm: Dictionary) -> Dictionary:
	var from := int(offer["from"])
	var room: int = game.players[from].cash - int(offer["give_cash"]) + int(offer["get_cash"])
	var given := _given(game, pi, offer)
	# 只要回到自己的底价（得分不亏），再加上要价虚高 ⑧a。不按随机范围 ⑦ 的上沿要价：
	# ⑦ 大的人（小九）是好说话，不是漫天要价
	var want := param(game, pi, "ask_up_pct", 0) / 100.0
	var need := func(extra: int) -> float:
		var c := _with_cash_to_responder(offer, extra)
		return trade_gain(game, pi, c, base, calm) - want * _given(game, pi, c)
	if room <= 0 or need.call(room) <= 0.0:
		return {}
	var hi := _first_true(func(x: int) -> bool: return need.call(x) > 0.0, 0, room)
	if hi > given * param(game, pi, "counter_range_pct", 100) / 100.0:
		return {}
	return _with_cash_to_responder(offer, mini(room, Trader._round_up(hi)))


## 回答的人多拿 extra 现金：先减少他要付的，不够再加发起人给的
static func _with_cash_to_responder(offer: Dictionary, extra: int) -> Dictionary:
	var c: Dictionary = offer.duplicate(true)
	var cut := mini(extra, int(c["get_cash"]))
	c["get_cash"] = int(c["get_cash"]) - cut
	c["give_cash"] = int(c["give_cash"]) + extra - cut
	return c


## 掷骰前发起一笔交易（每回合最多一次）。被拒后收敛的记账照 trader.gd。发起了返回 true。
static func propose_step(game) -> bool:
	var pi: int = game.current
	var p = game.players[pi]
	if int(p.ai_memory.get("trade_day", -1)) == game.day:
		return false
	p.ai_memory["trade_day"] = game.day
	Trader._note_last_result(game, pi)
	if game.rng.randf() * 100.0 >= param(game, pi, "trade_propose_pct", 100):
		return false
	var asked: Dictionary = p.ai_memory.get_or_add("trade_asked", {})
	var refused_by: Dictionary = p.ai_memory.get_or_add("trade_refused_by", {})
	var refusals: Dictionary = p.ai_memory.get_or_add("trade_refusals", {})
	var retry := int(param(game, pi, "trade_retry_days", 5))
	var cooldown := int(param(game, pi, "trade_cooldown_days", 0))
	var give_up := int(param(game, pi, "trade_give_up_after", 0))
	Ledger.begin()
	var base := Ledger.positions(game, pi)
	var best := {}
	var best_gain := 0.0
	for want in _wants(game, pi):
		var q := int(want["owner"])
		if game.day - int(refused_by.get(str(q), -9999)) < cooldown:
			continue
		var key := "%d:%s" % [q, str(want["tiles"])]
		if game.day - int(asked.get(key, -9999)) < retry:
			continue
		var times := 0
		for t in want["tiles"]:
			times = maxi(times, int(refusals.get("%d:%d" % [q, t], 0)))
		if give_up > 0 and times >= give_up:
			continue
		for give in _swaps(game, pi, q):
			var plan := _price(game, pi, q, give, want["tiles"], times, base)
			if not plan.is_empty() and plan["gain"] > best_gain:
				best = plan
				best_gain = plan["gain"]
				best["key"] = key
	if best.is_empty() or not worth_doing(game, pi, best["gain"], _given(game, pi, best["offer"])):
		return false
	asked[best["key"]] = game.day
	var offer: Dictionary = best["offer"]
	p.ai_memory["trade_last"] = {"to": offer["to"], "get": offer["get"].duplicate(), "day": game.day}
	if game.record_history:
		game.ai_think(pi, "trade_propose", {"offer": offer.duplicate(true), "gain": best["gain"],
				"most_i_pay": best["most"], "least_they_need": best["least"]})
	return game.propose_trade(offer) == ""


## 想要的地：自己在这一段街有地、或者这条街是自己喜欢的街（地图的 favorites），对手手里这一段没盖房子的地；
## 还有自己已经有的行业里，对手手里的同行业企业
static func _wants(game, pi: int) -> Array:
	var liked: Array = game.board.favorites.get(game.players[pi].character, []) \
			if param(game, pi, "street_obsession_pct", 0) > 0.0 else []
	var seen := {}
	var out: Array = []
	for t in game.props:
		if game.board.get_tile(t)["type"] != "land":
			continue
		var seg: Array = Valuer.segment_of(game, t)
		if seen.has(seg[0]):
			continue
		seen[seg[0]] = true
		var mine := 0
		var by := {}
		for x in seg:
			var o: int = game.owner_of(x)
			if o == pi:
				mine += 1
			elif o >= 0 and game.house_at(x) == 0 and not game.players[o].bankrupt:
				by.get_or_add(o, []).append(x)
		if mine == 0 and not liked.has(str(game.board.get_tile(t).get("group", ""))):
			continue
		for q in by:
			out.append({"owner": q, "tiles": by[q]})
	# 企业：自己已经有这个行业的企业，对手手里同行业的企业也想要（同行业越多租金越翻倍）
	var industries := {}
	for t in game.props:
		var tile: Dictionary = game.board.get_tile(t)
		if tile["type"] == "company" and game.owner_of(t) == pi:
			industries[str(tile.get("industry", ""))] = true
	for t in game.props:
		var tile: Dictionary = game.board.get_tile(t)
		var o: int = game.owner_of(t)
		if tile["type"] != "company" or not industries.has(str(tile.get("industry", ""))) \
				or o < 0 or o == pi or game.players[o].bankrupt:
			continue
		out.append({"owner": o, "tiles": [t]})
	return out


## 能拿来换的：不拿地，或者拿一块自己用不上、对 q 有用的地（trader.gd 的 _spare_for）
static func _swaps(game, pi: int, q: int) -> Array:
	var out: Array = [[]]
	for t in Trader._spare_for(game, pi, q):
		out.append([t])
	return out


## 定价：我最多肯付 most（再多我就不赚），猜对方最少要 least（用我的估价、我对他的看法）。
## 出价 = 公道价 ÷ (1 + 开价压低) × (1 + 被拒次数 × 加价)，公道价 = least + (most − least) ÷ 活着的人数，
## 不超过 most。谈不成返回 {}。
static func _price(game, pi: int, q: int, give: Array, tiles: Array, times: int,
		base: Array) -> Dictionary:
	var offer := {"from": pi, "to": q, "give": give.duplicate(), "get": tiles.duplicate(),
			"give_cash": 0, "get_cash": 0}
	if game.why_bad_trade(offer) != "":
		return {}
	var cash: int = game.players[pi].cash
	var mine := func(x: int) -> float:
		var o := offer.duplicate(true)
		o["give_cash"] = x
		return trade_gain(game, pi, o, base)
	if mine.call(0) <= 0.0:
		return {}
	var most := _last_true(func(x: int) -> bool: return mine.call(x) >= 0.0, 0, cash)
	var calm := {}
	if param(game, pi, "distress_use_pct", 100) < 100:
		calm[q] = true
	var their_base := Ledger.positions(game, pi, {}, {}, calm)
	var theirs := func(x: int) -> float:
		var o := offer.duplicate(true)
		o["give_cash"] = x
		return _gain_seen_as(game, pi, q, o, their_base, calm)
	if theirs.call(most) < 0.0:
		return {}
	var least := _first_true(func(x: int) -> bool: return theirs.call(x) >= 0.0, 0, most)
	var alive: int = game.alive_players().size()
	var room := float(most - least)
	# 公道价 = 对方最少要的 + 多出来的好处 ÷ 人数；爱压价的先开 公道价 ÷ (1 + bid_down_pct%)
	# （可以比对方最少要的还低，但不会压到 0），每被拒一次加 trade_raise_pct%
	var fair := least + room / alive
	var x := fair / (1.0 + param(game, pi, "bid_down_pct", 0) / 100.0) \
			* (1.0 + times * param(game, pi, "trade_raise_pct", 10) / 100.0)
	var pay := mini(most, Trader._round_up(int(clampf(x, 0.0, float(most)))))
	if pay > cash:
		return {}
	offer["give_cash"] = pay
	return {"offer": offer, "gain": mine.call(pay), "most": most, "least": least}


## pi 猜 q 怎么看这笔交易：用 pi 的估价，按标准的得分算（不知道 q 的性格），换算成钱
static func _gain_seen_as(game, pi: int, q: int, offer: Dictionary, base: Array,
		calm: Dictionary) -> float:
	var e := _effect(offer)
	var after := Ledger.positions(game, pi, e["change"], e["money"], calm)
	return Ledger.money_gain(game, q, base, after, 1.0)


## [lo, hi] 里 ok 成立的最大整数（ok 从成立变成不成立，精度 10）
static func _last_true(ok: Callable, lo: int, hi: int) -> int:
	if ok.call(hi):
		return hi
	while hi - lo > 10:
		var mid := (lo + hi) / 2
		if ok.call(mid):
			lo = mid
		else:
			hi = mid
	return lo


## [lo, hi] 里 ok 成立的最小整数（ok 从不成立变成成立，精度 10）
static func _first_true(ok: Callable, lo: int, hi: int) -> int:
	if ok.call(lo):
		return lo
	while hi - lo > 10:
		var mid := (lo + hi) / 2
		if ok.call(mid):
			hi = mid
		else:
			lo = mid
	return hi
