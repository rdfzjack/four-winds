extends RefCounted
## 新 AI（角色 AI，第 6a 步分模块实现）。用法和原版 AI 一样：NewAi.step(game)，一般经过 ai.gd 调用。
## 已经做的模块接管对应的决定，还没做的先交给原版 AI（brain.gd）：
##   估价（valuer.gd）：路口选方向（选得失最好的方向）
## 后面的模块（买地和建房 → 交易和拍卖 → 性格差异）做完一个就在这里接一个。

const Brain = preload("res://scripts/core/brain.gd")
const Valuer = preload("res://scripts/core/valuer.gd")


static func step(game) -> bool:
	if game.phase == "over" or game.players[game.actor()].human:
		return false
	if game.phase == "pending" and str(game.pending.get("type", "")) == "choose_direction":
		game.choose_direction(best_direction(game, game.actor()))
		return true
	return Brain.step(game)


## 路口：得失最好的方向（一样好时取第一个）
static func best_direction(game, pi: int) -> int:
	var best := -1
	var best_value := -INF
	for d in Valuer.direction_values(game, pi):
		if d["value"] > best_value:
			best = d["option"]
			best_value = d["value"]
	return best
