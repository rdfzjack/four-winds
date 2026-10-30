extends RefCounted
## 新 AI（角色 AI，第 6a 步分模块实现）。用法和原版 AI 一样：NewAi.step(game)，一般经过 ai.gd 调用。
## 已经做的模块接管对应的决定，还没做的先交给原版 AI（brain.gd）：
##   估价（valuer.gd）：路口选得失最好的方向
##   买地和建房：买不买地 / 企业、建房、升级（看值不值，再看付完钱后留不留得够防破产的钱）
##   交易和拍卖出价（trader.gd）：发起交易、回答交易（三个区间）、拍卖出价（关系值作者定先不做）
## 还交给原版 AI 的：银行存取、保释、赎回（抵押、发起拍卖按 scoring 的开关，现在关着）。
## 下一个模块（性格差异）做完在这里接。

const Brain = preload("res://scripts/core/brain.gd")
const Valuer = preload("res://scripts/core/valuer.gd")
const Trader = preload("res://scripts/core/trader.gd")


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
				Trader.answer(game, pi)
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


## 掷骰前做一件事，做了返回 true（调用者会再来一次）。顺序照原版：交易 → 建房 → 升级 → 抵押 → 赎回 → 拍卖。
static func _improve(game) -> bool:
	if Trader.propose_step(game):
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


## 路口：得失最好的方向（一样好时取第一个）
static func best_direction(game, pi: int) -> int:
	var best := -1
	var best_value := -INF
	for d in Valuer.direction_values(game, pi):
		if d["value"] > best_value:
			best = d["option"]
			best_value = d["value"]
	return best


## 付出 cost 以后，现金 + 存款还够不够留下的钱（Valuer.reserve）
static func can_spend(game, pi: int, cost: int) -> bool:
	var p = game.players[pi]
	return p.cash + p.deposit - cost >= Valuer.reserve(game, pi)


## 买地 / 企业：对自己值的 − 价格，加上不让对手拿到的价值（对手拿到它多值的 × block_pct%），大于 0 才买；
## 付完钱还要留得够防破产的钱。“喜欢的地”（性格）现金够就买，不管留不留得够钱。
static func wants_property(game, pi: int, tile: int) -> bool:
	var price: int = game.property_price(tile)
	if game.players[pi].cash < price:
		return false
	if Valuer.favorites(game, pi).has(tile):
		game.ai_note(pi, "favorite_buy")
		return true
	if not can_spend(game, pi, price):
		return false
	return buy_gain(game, pi, tile) > 0.0


static func buy_gain(game, pi: int, tile: int) -> float:
	var price: int = game.property_price(tile)
	var gain := Valuer.property_worth(game, pi, tile) - price
	var block := 0.0
	for q in game.alive_players():
		if q.index != pi:
			block = maxf(block, Valuer.property_worth(game, q.index, tile) - price)
	return gain + block * Valuer.param(game, pi, "block_pct", 50) / 100.0


## 建房：在现在能建的里挑“值不值”最高的；付完钱要留得够钱。
## 现金不够但现金 + 存款够时，记下还差多少（ai_memory.cash_need），路过银行时原版 AI 的银行逻辑会多取。
static func _build_step(game) -> bool:
	var pi: int = game.current
	var p = game.players[pi]
	p.ai_memory["cash_need"] = 0
	var best := {}
	var best_gain := 0.0
	for c in game.build_choices(pi):
		var why := str(c["why"])
		if why != "" and not why.begins_with("现金不够"):
			continue
		var cost := int(c["cost"])
		if not can_spend(game, pi, cost):
			continue
		var gain := Valuer.build_gain(game, pi, str(c["kind"]), c["tiles"])
		if gain > best_gain:
			best = c
			best_gain = gain
	if best.is_empty():
		return false
	if str(best["why"]) != "":
		p.ai_memory["cash_need"] = int(best["cost"]) - p.cash
		return false
	return game.build(pi, str(best["kind"]), best["tiles"]) == ""


## 升级：值得且付完留得够钱就升（一次一栋，挑最值的）
static func _upgrade_step(game) -> bool:
	var pi: int = game.current
	var best := 0
	var best_gain := 0.0
	for hid in game.houses:
		if game.houses[hid]["owner"] != pi or game.why_cannot_upgrade(pi, hid) != "":
			continue
		if not can_spend(game, pi, game.upgrade_fee(game.houses[hid]["tiles"])):
			continue
		var gain := Valuer.upgrade_gain(game, pi, hid)
		if gain > best_gain:
			best = hid
			best_gain = gain
	return best != 0 and game.upgrade(pi, best) == ""
