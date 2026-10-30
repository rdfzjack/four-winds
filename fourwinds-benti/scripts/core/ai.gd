extends RefCounted
## AI 入口（画面和评测工具都只调这里）。用法和原版 AI 一样：
## 轮到 AI 时反复调用 AI.step(game)，每次做一个决定；返回 false 表示现在没有要 AI 做的事。
##
## 每个玩家用哪个 AI 看 Player.ai（开局时 specs 里的 "ai"，默认 original）：
##   original = 原版 AI（brain.gd），评测基准
##   new      = 角色 AI（第 6a 步分模块实现，按角色 + 形态打；还没做的决定先交给原版 AI，见 new_ai.gd）
##   standard = “认真玩家”替身（无性格、无弱点，评测用，见 docs/ai_design.md 的 E 节）
## 还没实现的版本先用原版 AI 顶上并报错一次，评测工具会直接拒绝。
## 参数按“角色 + 形态”取：AiProfiles.of(角色, 形态)，形态看 Player.form（front 表 / back 里）。
## 关系值在 Player.relations（Game.relation() / change_relation()）。

const Brain = preload("res://scripts/core/brain.gd")
const NewAi = preload("res://scripts/core/new_ai.gd")
const AiProfiles = preload("res://scripts/core/ai_profiles.gd")

const VERSIONS := ["original", "new", "standard"]
## 已经实现的版本
const READY := ["original", "new"]

static var _warned: Dictionary = {}


static func step(game) -> bool:
	if game.phase == "over" or game.players[game.actor()].human:
		return false
	var version: String = game.players[game.actor()].ai
	match version:
		"original":
			return Brain.step(game)
		"new":
			return NewAi.step(game)
	if not _warned.has(version):
		_warned[version] = true
		push_error("AI 版本 %s 还没实现，先用原版 AI" % version)
	return Brain.step(game)


## 玩家 pi 的参数（按他的角色和形态）
static func profile(game, pi: int) -> Dictionary:
	var p = game.players[pi]
	return AiProfiles.of(p.character, p.form)
