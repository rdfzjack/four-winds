extends RefCounted
## 新 AI 的交易和拍卖出价（第 6a 步 ② 第三个模块）。设计见 docs/ai_design.md 的 F 节。
## 只通过 Game 的公开方法操作；估价时会临时改地产主人再改回来（_with_owners），算完局面不变。
##
## 一笔交易对玩家 x 的“得分”（百分比）：
##   得失 = 交易后 x 在相关街 / 行业上的地产价值 − 交易前 + 收到的现金 − 付出的现金
##          − 对方因此多出来的价值 × trade_harm_pct% ÷ 对手人数（帮对手变强也是损失；
##            4 人局里一个对手变强，损失由 3 个对手分担，所以按人数平摊）
##   得分 = 得失 ÷ 交出去的东西值多少 × 100（关系值以后再接，作者定先不做）
## 回答（F 节三个区间）：得分 < trade_reject_pct 绝对不接受；≥ trade_accept_pct 一定接受；中间按比例的概率接受。
## 不接受但差得不多（得分 ≥ trade_counter_pct）时还价一次：要对方再多付刚好够“一定接受”的现金。
## 发起：盯自己占了地的街，向对手要他手里这条街的地；付多少现金按“猜对方的一定接受线”
## （trade_guess_accept_pct，发起人不知道对方真实的区间）算，自己得失要为正、付完要留得够钱。
## 能拿自己用不上的地（别人凑街要的）去换，就先试换地。
## 拍卖：出价上限 = 拿到这块对自己多值的 + 不让对手拿到的价值，不超过付完还留得够钱的现金。

const Valuer = preload("res://scripts/core/valuer.gd")


static func param(game, pi: int, key: String, fallback: float) -> float:
	return Valuer.param(game, pi, key, fallback)


# ───────────────────────── 估价 ─────────────────────────

## 临时把 change 里的地块换主人，算完 fn 再改回来
static func _with_owners(game, change: Dictionary, fn: Callable) -> Variant:
	var saved := {}
	for t in change:
		saved[t] = game.props[t]["owner"]
		game.props[t]["owner"] = change[t]
	var out: Variant = fn.call()
	for t in saved:
		game.props[t]["owner"] = saved[t]
	return out


## 交易会影响价值的地产：交易里的地所在整条街 + 交易里的企业的整个行业
static func _scope(game, tiles: Array) -> Array:
	var groups := {}
	var industries := {}
	for t in tiles:
		var tile: Dictionary = game.board.get_tile(t)
		if tile["type"] == "land":
			groups[str(tile.get("group", ""))] = true
		else:
			industries[str(tile.get("industry", ""))] = true
	var out: Array = []
	for t in game.props:
		var tile: Dictionary = game.board.get_tile(t)
		var key := str(tile.get("group" if tile["type"] == "land" else "industry", ""))
		var is_land: bool = tile["type"] == "land"
		if (is_land and groups.has(key)) or (not is_land and industries.has(key)):
			out.append(t)
	return out


## x 在 scope 这些地产上的价值（按现在的主人）
static func _value(game, x: int, scope: Array) -> float:
	var v := 0.0
	for t in scope:
		if game.owner_of(t) == x:
			v += Valuer.property_worth(game, x, t)
	return v


## 交易对 x 的影响：{net: 得失, lost: 交出去的东西值多少, other: 对方多出来的价值}
static func trade_effect(game, x: int, offer: Dictionary) -> Dictionary:
	var a: int = offer["from"]
	var b: int = offer["to"]
	var other := b if x == a else a
	var change := {}
	for t in offer["give"]:
		change[t] = b
	for t in offer["get"]:
		change[t] = a
	var scope := _scope(game, change.keys())
	var mine_before := _value(game, x, scope)
	var other_before := _value(game, other, scope)
	var after: Array = _with_owners(game, change, func() -> Array:
		return [_value(game, x, scope), _value(game, other, scope)])
	var cash_out: int = offer["give_cash"] if x == a else offer["get_cash"]
	var cash_in: int = offer["get_cash"] if x == a else offer["give_cash"]
	var lost := float(cash_out)
	for t in (offer["give"] if x == a else offer["get"]):
		lost += Valuer.property_worth(game, x, t)
	return {"net": after[0] - mine_before + cash_in - cash_out, "lost": lost,
			"other": after[1] - other_before}


## x 看来，对方多出 other 的价值算自己损失多少
static func harm(game, x: int, other: float) -> float:
	var opponents := maxi(1, game.alive_players().size() - 1)
	return maxf(0.0, other) * param(game, x, "trade_harm_pct", 100) / 100.0 / opponents


## x 看这笔交易的得分（百分比，见文件开头）
static func trade_score(game, x: int, offer: Dictionary) -> float:
	var e := trade_effect(game, x, offer)
	return 100.0 * (e["net"] - harm(game, x, e["other"])) / maxf(1.0, e["lost"])


## 按得分决定接不接受（中间区间按概率）
static func accepts(game, x: int, score: float) -> bool:
	var low := param(game, x, "trade_reject_pct", 0)
	var high := param(game, x, "trade_accept_pct", 10)
	if score < low:
		return false
	if score >= high:
		return true
	return game.rng.randf() < (score - low) / maxf(0.001, high - low)


# ───────────────────────── 回答 ─────────────────────────

static func answer(game, pi: int) -> void:
	var offer: Dictionary = game.pending["offer"]
	var score := trade_score(game, pi, offer)
	if game.pending["stage"] == "counter":
		# 自己发起的、对方还了价：按自己的区间回答
		game.trade_answer(accepts(game, pi, score))
		return
	if accepts(game, pi, score):
		game.trade_answer(true)
		return
	if score >= param(game, pi, "trade_counter_pct", -30):
		var counter := _counter(game, pi, offer)
		if not counter.is_empty() and game.trade_counter(counter) == "":
			return
	game.trade_answer(false)


## 还价：发起人再多付多少现金，自己的得分才到“一定接受”线。付不起返回 {}。
static func _counter(game, pi: int, offer: Dictionary) -> Dictionary:
	var counter: Dictionary = offer.duplicate(true)
	var high := param(game, pi, "trade_accept_pct", 10)
	for _i in range(4):
		var score := trade_score(game, pi, counter)
		if score >= high:
			return counter
		var lost: float = trade_effect(game, pi, counter)["lost"]
		var extra := _round_up(int(ceil((high - score) * maxf(1.0, lost) / 100.0)))
		counter["give_cash"] = int(counter["give_cash"]) + extra
		if int(counter["give_cash"]) > game.players[int(counter["from"])].cash:
			return {}
	return counter if trade_score(game, pi, counter) >= high else {}


# ───────────────────────── 发起 ─────────────────────────

## 掷骰前发起一笔交易（每回合最多一次）。发起了返回 true。
static func propose_step(game) -> bool:
	var pi: int = game.current
	var p = game.players[pi]
	if int(p.ai_memory.get("trade_day", -1)) == game.day:
		return false
	p.ai_memory["trade_day"] = game.day
	var asked: Dictionary = p.ai_memory.get_or_add("trade_asked", {})
	var retry := int(param(game, pi, "trade_retry_days", 5))
	var best := {}
	var best_net := 0.0
	for want in _wants(game, pi):
		var key := "%d:%s" % [int(want["owner"]), str(want["tiles"])]
		if game.day - int(asked.get(key, -9999)) < retry:
			continue
		var offer := _make_offer(game, pi, int(want["owner"]), want["tiles"])
		if offer.is_empty():
			continue
		var net: float = trade_effect(game, pi, offer)["net"]
		if net > best_net:
			best = offer
			best_net = net
			best["_key"] = key
	if best.is_empty():
		return false
	asked[best["_key"]] = game.day
	best.erase("_key")
	return game.propose_trade(best) == ""


## 想要的地：自己在这条街至少有一块，对手手里这条街的地（没盖房子）。[{owner, tiles}]
static func _wants(game, pi: int) -> Array:
	var groups := {}
	for t in game.props:
		var tile: Dictionary = game.board.get_tile(t)
		if tile["type"] != "land":
			continue
		var g: Dictionary = groups.get_or_add(str(tile.get("group", "")), {"mine": 0, "by": {}})
		var o: int = game.owner_of(t)
		if o == pi:
			g["mine"] += 1
		elif o >= 0 and game.house_at(t) == 0 and not game.players[o].bankrupt:
			g["by"].get_or_add(o, []).append(t)
	var out: Array = []
	for g in groups.values():
		if g["mine"] == 0:
			continue
		for q in g["by"]:
			out.append({"owner": q, "tiles": g["by"][q]})
	return out


## 自己用不上、对 q 有用的地：这条街自己只有这一块、q 也有地，地上没房子
static func _spare_for(game, pi: int, q: int) -> Array:
	var out: Array = []
	for t in game.properties_of(pi):
		var tile: Dictionary = game.board.get_tile(t)
		if tile["type"] != "land" or game.house_at(t) != 0:
			continue
		var group := str(tile.get("group", ""))
		var mine := 0
		var theirs := 0
		for s in game.props:
			if str(game.board.get_tile(s).get("group", "")) != group \
					or game.board.get_tile(s)["type"] != "land":
				continue
			if game.owner_of(s) == pi:
				mine += 1
			elif game.owner_of(s) == q:
				theirs += 1
		if mine == 1 and theirs > 0:
			out.append(t)
	return out


## 给对手 q 开条件：先试拿一块用不上的地换，再试纯现金。现金 = 猜对方“一定接受”要的数。
## 自己得失要为正（扣掉帮对手变强的部分），付完现金要留得够钱。开不出返回 {}。
static func _make_offer(game, pi: int, q: int, tiles: Array) -> Dictionary:
	var swaps: Array = []
	for t in _spare_for(game, pi, q):
		swaps.append([t])
	swaps.append([])
	var guess := param(game, pi, "trade_guess_accept_pct", 50)
	var best := {}
	var best_net := 0.0
	for give in swaps:
		var offer := {"from": pi, "to": q, "give": give, "get": tiles.duplicate(),
				"give_cash": 0, "get_cash": 0}
		# 对方看：得失 / 交出去的 × 100 ≥ guess（不算好感，发起人不知道）
		var e := trade_effect(game, q, offer)
		# 对方多拿 C 现金：他的得失 +C，他眼里我多出来的价值 −C。解出刚好到 guess 线的 C：
		# (net + C) − h × (other − C) ≥ guess × lost  →  C ≥ (guess × lost + h × other − net) ÷ (1 + h)
		var h := harm(game, q, 1.0)
		var need: float = (guess / 100.0 * maxf(1.0, e["lost"]) + h * maxf(0.0, e["other"])
				- e["net"]) / (1.0 + h)
		if need > 0:
			offer["give_cash"] = _round_up(int(ceil(need)))
		var cash := int(offer["give_cash"])
		if cash > game.players[pi].cash or not _can_spend(game, pi, cash):
			continue
		if game.why_bad_trade(offer) != "":
			continue
		var mine := trade_effect(game, pi, offer)
		var net: float = mine["net"] - harm(game, pi, mine["other"])
		if net > best_net:
			best = offer
			best_net = net
	return best


static func _can_spend(game, pi: int, cost: int) -> bool:
	var p = game.players[pi]
	return p.cash + p.deposit - cost >= Valuer.reserve(game, pi)


static func _round_up(amount: int) -> int:
	return (maxi(0, amount) + 9) / 10 * 10


# ───────────────────────── 拍卖出价 ─────────────────────────

## 出价上限：拿到这块对自己多值的 + 不让对手拿到的价值 × block_pct%，不超过付完还留得够钱的现金
static func auction_limit(game, pi: int, tile: int) -> int:
	var scope := _scope(game, [tile])
	var before := _value(game, pi, scope)
	var gain: float = _with_owners(game, {tile: pi}, func() -> float:
		return _value(game, pi, scope)) - before
	var block := 0.0
	for q in game.alive_players():
		if q.index == pi:
			continue
		var qb := _value(game, q.index, scope)
		var qa: float = _with_owners(game, {tile: q.index}, func() -> float:
			return _value(game, q.index, scope))
		block = maxf(block, qa - qb)
	var limit := gain + block * param(game, pi, "block_pct", 50) / 100.0
	var p = game.players[pi]
	var spendable: float = p.cash + p.deposit - Valuer.reserve(game, pi)
	return int(minf(limit, minf(float(p.cash), spendable)))


## 轮到自己出价：上限以内加一档（先试最小档），否则放弃
static func auction_turn(game, pi: int) -> void:
	var limit := auction_limit(game, pi, int(game.pending["tile"]))
	var price := int(game.pending["price"])
	for s in game.bid_steps():
		if price + int(s) <= limit:
			game.auction_bid(int(s))
			return
	game.auction_pass()
