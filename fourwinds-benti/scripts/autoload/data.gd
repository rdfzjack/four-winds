extends Node
## 全局数据（自动加载，名字是 Data）。
##
## 游戏一启动就读取 res://data/ 下的规则、角色、地图、机会卡、AI 参数和台词，
## 其他脚本直接用 Data.rules、Data.characters、Data.maps 等访问。

const JsonUtil = preload("res://scripts/core/json_util.gd")
const Board = preload("res://scripts/core/board.gd")
const DataCheck = preload("res://scripts/core/data_check.gd")

const RULES_PATH := "res://data/rules.json"
const CHARACTERS_PATH := "res://data/characters.json"
const CARDS_PATH := "res://data/cards/chance.json"
const AI_PATH := "res://data/ai/profiles.json"
const LINES_PATH := "res://data/lines/speech.json"
const MAPS_DIR := "res://data/maps"

var rules: Dictionary = {}
var characters: Array = []
var maps: Dictionary = {}  ## 地图 id -> Board
var cards: Array = []  ## 机会卡列表
var special_events: Array = []  ## 不在牌堆里的特殊事件（古董、倒塌等）
var ai_profiles: Dictionary = {}  ## AI 参数 id -> {参数名: 数值}
var lines: Dictionary = {}  ## 整个 lines/speech.json
var errors: Array = []  ## 读取或校验时发现的问题，主界面会显示出来


func _ready() -> void:
	reload()


func reload() -> void:
	errors.clear()
	rules = JsonUtil.load_dict(RULES_PATH, errors)
	var chars := JsonUtil.load_dict(CHARACTERS_PATH, errors)
	characters = chars.get("characters", [])
	var cards_file := JsonUtil.load_dict(CARDS_PATH, errors)
	cards = cards_file.get("cards", [])
	special_events = cards_file.get("special_events", [])
	var ai := JsonUtil.load_dict(AI_PATH, errors)
	ai_profiles = ai.get("profiles", {})
	lines = JsonUtil.load_dict(LINES_PATH, errors)

	errors.append_array(DataCheck.check_characters(characters, ai, lines))
	errors.append_array(DataCheck.check_cards(cards_file, characters))

	maps.clear()
	for file in DirAccess.get_files_at(MAPS_DIR):
		if not file.ends_with(".json"):
			continue
		var d := JsonUtil.load_dict(MAPS_DIR.path_join(file), errors)
		if d.is_empty():
			continue
		var board := Board.new()
		for e in board.load_from(d):
			errors.append("%s：%s" % [file, e])
		maps[board.id] = board
	if not maps.has(str(rules.get("default_map", ""))):
		errors.append("rules.json 的 default_map 找不到对应地图")
	for e in errors:
		push_warning(e)


## 当前默认地图；没有地图时返回 null。
func default_map() -> Board:
	var wanted := str(rules.get("default_map", ""))
	if maps.has(wanted):
		return maps[wanted]
	if not maps.is_empty():
		return maps.values()[0]
	return null


## 按 id 找角色；找不到返回空字典。
func character(id: String) -> Dictionary:
	for c in characters:
		if str(c.get("id", "")) == id:
			return c
	return {}


## 随机取一句台词。condition 是事件名（如 "TO_JAIL"），找不到时返回空字符串。
func random_line(character_id: String, condition: String) -> String:
	var c := character(character_id)
	var set_id := str(c.get("lines", character_id))
	var options: Array = lines.get("characters", {}).get(set_id, {}).get(condition, [])
	if options.is_empty():
		return ""
	return str(options.pick_random())
