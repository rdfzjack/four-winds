extends RefCounted
## 新框架的标准 AI（ai 版本 standard_v2，第 6a 步返工）。用法和别的 AI 一样：StdAi.step(game)，经过 ai.gd 调用。
## 所有决定都比较“做”和“不做”的得分（ledger.gd 的三本账），设计见 docs/ai_design.md 的 H 节。
##   买地 / 企业：买下 vs 不买（不买时这块可能被某个对手买走）
##   盖房、升级：盖 vs 不盖（钱少时撑下去的机会变小，所以不会盖到没钱）
##   回答交易：成交 vs 不成交；差一点时还价一次，要对方多给现金
##   发起交易：向对手要凑街的地（能拿用不上的地换就先试换地）。算出“我最多肯给”和“猜对方最少要”，
##            出价 = 对方最少要的 + 两者之差 ÷ 还活着的人数（多出来的好处按人数分给对方）
## 还没改、照旧的：路口（valuer.gd）、拍卖出价（trader.gd，作者定先不改）、银行存取 / 保释 / 赎回（原版 AI）。
## 被拒后收敛（几天不找同一人、被拒几次放弃、被拒一次加价）照 trader.gd 的做法。
##
## 性格用的数（标准 AI 都是“不偏”的值，角色以后在自己的参数组里改，见 H 节）：
##   partner_attitude_pct / partner_attitude_lead_pct  对交易对象多赚的怎么看：基础值 / 自己每领先 100% 加多少
##   decision_band_pct  决定的随机范围（交易得失在 ± 这么多 % 以内按概率答应）
##   haggle_pct         讨价空间：开价、要价离底线多远（占交易好处的 %），被拒一次往底线靠 trade_raise_pct
##   trade_propose_pct  主动找人交易的概率
##   distress_use_pct   出价时看不看对方缺钱（100 看，0 不看）

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
				game.choose_direction(NewAi.best_direction(game, pi))
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


# ───────────────────────── 买地 ─────────────────────────

## 买下 vs 不买。不买时：每个对手各有 1 / 活着的人数 的可能以后买走它，剩下的可能还没人买。
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
		if q.index != pi:
			var pos := Ledger.positions(game, pi, {tile: q.index}, {q.index: -price})
			skip += share * Ledger.score_of(game, pi, pos)
	var buy := bought > skip
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
	var now := Ledger.score_of(game, pi, Ledger.positions(game, pi))
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
	if best.is_empty():
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
	var now := Ledger.score_of(game, pi, Ledger.positions(game, pi))
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
	return best != 0 and game.upgrade(pi, best) == ""


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
static func trade_gain(game, x: int, offer: Dictionary, base: Array = [], calm: Dictionary = {}) -> float:
	if base.is_empty():
		base = Ledger.positions(game, x, {}, {}, calm)
	var e := _effect(offer)
	var after := Ledger.positions(game, x, e["change"], e["money"], calm)
	var g := Ledger.money_gain(game, x, base, after)
	var other := int(offer["to"]) if x == int(offer["from"]) else int(offer["from"])
	return g + attitude(game, x, other, base) * (after[other] - base[other])


## x 对交易对象多赚的部分怎么看（正 = 替他高兴，负 = 他多赚就是我更大的损失）。标准 AI 为 0。
static func attitude(game, x: int, other: int, pos: Array) -> float:
	var lead := (float(pos[x]) - float(pos[other])) / maxf(1.0, float(pos[x]))
	return (param(game, x, "partner_attitude_pct", 0)
			+ param(game, x, "partner_attitude_lead_pct", 0) * lead) / 100.0


## x 在这笔交易里交出去的东西值多少（决定的随机范围按它的百分比算）
static func _given(game, x: int, offer: Dictionary) -> float:
	var mine: bool = x == int(offer["from"])
	var total := float(offer["give_cash"] if mine else offer["get_cash"])
	for t in (offer["give"] if mine else offer["get"]):
		total += Ledger.property_worth(game, x, x, int(t))
	return maxf(1.0, total)


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
	var g := trade_gain(game, pi, offer)
	var given := _given(game, pi, offer)
	var yes := _accepts(game, pi, g, given)
	var counter := {}
	if not yes and game.pending["stage"] == "offer":
		counter = _counter(game, pi, offer)
	if game.record_history:
		var p = game.players[pi]
		game.ai_think(pi, "trade_answer", {"offer": offer.duplicate(true),
				"stage": str(game.pending["stage"]), "gain": g, "given": given, "accept": yes,
				"counter": counter, "cash": p.cash, "deposit": p.deposit,
				"survival": Ledger.survival(game, pi, pi, p.cash + p.deposit)})
	Ledger.begin()
	if yes:
		game.trade_answer(true)
	elif not counter.is_empty() and game.trade_counter(counter) == "":
		return
	else:
		game.trade_answer(false)


## 还价：要发起人多给现金（先少要他的钱），刚好够自己一定答应，再加上讨价空间。付不起返回 {}。
static func _counter(game, pi: int, offer: Dictionary) -> Dictionary:
	var from := int(offer["from"])
	var room: int = game.players[from].cash - int(offer["give_cash"]) + int(offer["get_cash"])
	var base := Ledger.positions(game, pi)
	var need := func(extra: int) -> float:
		var c := _with_cash_to_responder(offer, extra)
		var g := trade_gain(game, pi, c, base)
		return g - param(game, pi, "decision_band_pct", 0) / 100.0 * _given(game, pi, c)
	if room <= 0 or need.call(room) <= 0.0:
		return {}
	var lo := 0
	var hi := room
	while hi - lo > 10:
		var mid := (lo + hi) / 2
		if need.call(mid) > 0.0:
			hi = mid
		else:
			lo = mid
	var extra := mini(room, Trader._round_up(hi + int(hi * param(game, pi, "haggle_pct", 0) / 100.0)))
	return _with_cash_to_responder(offer, extra)


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
	for want in Trader._wants(game, pi):
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
	if best.is_empty():
		return false
	asked[best["key"]] = game.day
	var offer: Dictionary = best["offer"]
	p.ai_memory["trade_last"] = {"to": offer["to"], "get": offer["get"].duplicate(), "day": game.day}
	if game.record_history:
		game.ai_think(pi, "trade_propose", {"offer": offer.duplicate(true), "gain": best["gain"],
				"most_i_pay": best["most"], "least_they_need": best["least"]})
	return game.propose_trade(offer) == ""


## 能拿来换的：不拿地，或者拿一块自己用不上、对 q 有用的地（trader.gd 的 _spare_for）
static func _swaps(game, pi: int, q: int) -> Array:
	var out: Array = [[]]
	for t in Trader._spare_for(game, pi, q):
		out.append([t])
	return out


## 定价：我最多肯付 most（再多我就不赚），猜对方最少要 least（用我的估价、我对他的看法）。
## 出价 = least + (most − least) ÷ 活着的人数 − 讨价空间 + 被拒次数 × 加价，不超过 most。谈不成返回 {}。
static func _price(game, pi: int, q: int, give: Array, tiles: Array, times: int, base: Array) -> Dictionary:
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
	var x := least + room / alive - room * param(game, pi, "haggle_pct", 0) / 100.0 \
			+ room * times * param(game, pi, "trade_raise_pct", 10) / 100.0
	var pay := mini(most, Trader._round_up(int(clampf(x, float(least), float(most)))))
	if pay > cash:
		return {}
	offer["give_cash"] = pay
	return {"offer": offer, "gain": mine.call(pay), "most": most, "least": least}


## pi 猜 q 怎么看这笔交易：用 pi 的估价，按标准的得分算（不知道 q 的性格），换算成钱
static func _gain_seen_as(game, pi: int, q: int, offer: Dictionary, base: Array, calm: Dictionary) -> float:
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
