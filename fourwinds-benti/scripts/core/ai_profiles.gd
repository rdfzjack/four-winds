extends RefCounted
## AI 参数（data/ai/profiles.json），按“角色 + 形态”取。
##
## profiles.json 里每个参数组分形态：front = 表形态，back = 里形态；characters.json 的 ai_profile 指向参数组。
## 取某个形态的参数时：standard 的 front 打底（新 AI 的共用参数写在那里），再叠上这个参数组的 front，
## 再用该形态里写了的数覆盖（以 _ 开头的键是说明，不算）。
## 原版 AI（brain.gd）和以后的新 AI 都从这里拿参数。

const JsonUtil = preload("res://scripts/core/json_util.gd")

const PROFILES_PATH := "res://data/ai/profiles.json"
const CHARACTERS_PATH := "res://data/characters.json"
## 形态：表 / 里
const FORMS := ["front", "back"]

## "角色 id/形态" -> 参数（已合并好）。"" 是找不到时用的 standard 表形态。测试可以直接改这个字典。
static var table: Dictionary = {}
## profiles.json 的 scoring（原版 AI 写死在 exe 里的打分表和几个开关，所有角色共用）
static var scoring: Dictionary = {}


static func key(character: String, form: String) -> String:
	return "%s/%s" % [character, form]


## 角色 character 在形态 form 下的参数
static func of(character: String, form: String = "front") -> Dictionary:
	ensure_loaded()
	return table.get(key(character, form), table.get("", {}))


static func ensure_loaded() -> void:
	if not table.is_empty():
		return
	var errors: Array = []
	var file := JsonUtil.load_dict(PROFILES_PATH, errors)
	var chars := JsonUtil.load_dict(CHARACTERS_PATH, errors)
	if not errors.is_empty():
		push_error("读不到 AI 参数：%s" % str(errors))
	var groups: Dictionary = file.get("profiles", {})
	var standard: Dictionary = groups.get("standard", {})
	scoring = file.get("scoring", {})
	var base: Dictionary = merged(standard, "front")
	table[""] = base
	for c in chars.get("characters", []):
		var group: Dictionary = groups.get(str(c.get("ai_profile", "standard")), standard)
		for form in FORMS:
			table[key(str(c["id"]), form)] = merged(group, form, base)


## 参数组 group 在形态 form 下的参数：base 打底，叠上 front，再用 form 里写了的数覆盖
static func merged(group: Dictionary, form: String, base: Dictionary = {}) -> Dictionary:
	var out: Dictionary = base.duplicate()
	var layers: Array = ["front"] if form == "front" else ["front", form]
	for layer in layers:
		var extra: Dictionary = group.get(layer, {})
		for k in extra:
			if not str(k).begins_with("_"):
				out[k] = extra[k]
	return out
