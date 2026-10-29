extends RefCounted
## 临时 AI（第 3 步用，让热座里有对手）：规则很简单，第 4 步会换成原版的 12 个阈值参数。
##
## 用法：轮到 AI 时反复调用 SimpleAI.step(game)，每次做一个决定；
## 返回 false 表示现在没有要 AI 做的事（游戏结束，或轮到人类）。
## 只通过 Game 的公开方法操作，不访问画面。

const Streets = preload("res://scripts/core/streets.gd")

## 现金低于这个数就不买地、不建房（万圆）
const RESERVE := 400
## 现金超过这个数的部分，路过银行时存起来
const KEEP_CASH := 800


static func step(game) -> bool:
	if game.phase == "pre_roll":
		if game.player().human:
			return false
		if not _improve(game):
			game.roll()
		return true
	if game.phase != "pending":
		return false
	if game.player().human:
		return false
	var p = game.player()
	match str(game.pending["type"]):
		"choose_direction":
			var options: Array = game.pending["options"]
			game.choose_direction(int(options[game.rng.randi() % options.size()]))
		"bank":
			_bank(game, p)
		"buy_land", "buy_company":
			if p.cash - int(game.pending["price"]) >= RESERVE:
				game.buy()
			else:
				game.decline()
		"bail":
			game.bail(p.cash - int(game.pending["amount"]) >= RESERVE)
		_:
			return false
	return true


## 掷骰前做一件建设。做了返回 true（调用者会再来一次）。
static func _improve(game) -> bool:
	var p = game.player()
	# 先升级（便宜），再建最贵的买得起的房子（平房除外，见下面）
	for hid in game.houses:
		if game.houses[hid]["owner"] == p.index and game.why_cannot_upgrade(p.index, hid) == "":
			if p.cash - game.upgrade_fee(game.houses[hid]["tiles"]) >= RESERVE:
				game.upgrade(p.index, hid)
				return true
	var best := {}
	for o in game.build_options(p.index):
		if p.cash - int(o["cost"]) < RESERVE:
			continue
		# 平房占了地就再也凑不成旅社 / 洋楼 / 别墅：这条街还有希望时先留着地
		if str(o["kind"]) == "flat" and Streets.still_open(game, p.index, int(o["tiles"][0])):
			continue
		if best.is_empty() or int(o["cost"]) > int(best["cost"]):
			best = o
	if best.is_empty():
		return false
	game.build(p.index, str(best["kind"]), best["tiles"])
	return true


static func _bank(game, p) -> void:
	if p.cash > KEEP_CASH:
		game.bank_deposit(p.cash - KEEP_CASH)
	elif p.cash < RESERVE and p.deposit > 0:
		game.bank_withdraw(mini(p.deposit, KEEP_CASH - p.cash))
	game.bank_done()
