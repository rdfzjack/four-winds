extends Node
## 全局数据（自动加载，名字是 Data）。
##
## 游戏一启动就读取 res://data/ 下的规则、角色、地图、机会卡、AI 参数和台词，
## 其他脚本直接用 Data.rules、Data.characters、Data.maps 等访问。

const JsonUtil = preload("res://scripts/core/json_util.gd")
const Board = preload("res://scripts/core/board.gd")
const DataCheck = preload("res://scripts/core/data_check.gd")
const LinesDb = preload("res://scripts/core/lines_db.gd")
const SaveGame = preload("res://scripts/core/save_game.gd")
const Scenario = preload("res://scripts/core/scenario.gd")

const RULES_PATH := "res://data/rules.json"
const CHARACTERS_PATH := "res://data/characters.json"
const EXTRAS_PATH := "res://data/extra_characters.json"
const CARDS_PATH := "res://data/cards/chance.json"
const AI_PATH := "res://data/ai/profiles.json"
const LINES_DIR := "res://data/lines"
const MAPS_DIR := "res://data/maps"
const CAMPAIGNS_DIR := "res://data/campaigns"

var rules: Dictionary = {}
var characters: Array = []
var extras: Array = []  ## 路人（只在个人主线关卡里出现，data/extra_characters.json）
var maps: Dictionary = {}  ## 地图 id -> Board
var cards: Array = []  ## 机会卡列表
var special_events: Array = []  ## 不在牌堆里的特殊事件（古董、倒塌等）
var ai_profiles: Dictionary = {}  ## AI 参数组 id -> {形态: {参数名: 数值}}（AI 自己用 ai_profiles.gd 读）
var lines: LinesDb = null  ## 台词库（data/lines/ 下的事件表和每个角色的台词文件）
var campaigns: Dictionary = {}  ## 角色 id -> 个人主线 {name, stages: [关卡数据]}（data/campaigns/<角色 id>.json）
var errors: Array = []  ## 读取或校验时发现的问题，主界面会显示出来
## 主界面选好的座位，开局时交给棋盘画面：[{character: 角色 id, human: bool}, ...]（格式见 Game.setup）
var start_specs: Array = []
var start_map: String = ""   ## 主界面选的地图 id；空 = 默认地图
## 个人主线：主界面选好关卡后交给棋盘画面 {character: 角色 id, stage: 第几关（0 起）}；空 = 自由模式。
## 棋盘画面开局时拿走并清空，之后记在画面自己身上
var start_stage: Dictionary = {}
## 调试：交易时在按钮上面显示 AI 心里算的账（底价、得失、开价），主界面勾选。正式玩时关着
var debug_ai: bool = false
## 路口全部随机（像原版），主界面勾选；不勾 = 按地图（现在的地图都是能选方向）
var crossroads_random: bool = false
## 读档读出来的东西（SaveGame.load_slot 的结果），交给棋盘画面接着玩；棋盘画面拿走后清空
var resume: Dictionary = {}


func _ready() -> void:
	reload()


func reload() -> void:
	errors.clear()
	rules = JsonUtil.load_dict(RULES_PATH, errors)
	var chars := JsonUtil.load_dict(CHARACTERS_PATH, errors)
	characters = chars.get("characters", [])
	extras = JsonUtil.load_dict(EXTRAS_PATH, errors).get("characters", [])
	var cards_file := JsonUtil.load_dict(CARDS_PATH, errors)
	cards = cards_file.get("cards", [])
	special_events = cards_file.get("special_events", [])
	var ai := JsonUtil.load_dict(AI_PATH, errors)
	ai_profiles = ai.get("profiles", {})
	errors.append_array(DataCheck.check_characters(characters, ai))
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
	_load_campaigns()
	lines = _load_lines()
	if not maps.has(str(rules.get("default_map", ""))):
		errors.append("rules.json 的 default_map 找不到对应地图")
	for e in errors:
		push_warning(e)


## 读个人主线：每个角色一个文件，读完逐关检查（地图、座位、条件写错了记进 errors）
func _load_campaigns() -> void:
	campaigns.clear()
	for file in DirAccess.get_files_at(CAMPAIGNS_DIR):
		if not file.ends_with(".json"):
			continue
		var d := JsonUtil.load_dict(CAMPAIGNS_DIR.path_join(file), errors)
		if d.is_empty():
			continue
		var cid := str(d.get("character", ""))
		var playable := false
		for c in characters:
			playable = playable or str(c.get("id", "")) == cid
		if not playable:
			errors.append("%s：主线的角色“%s”不是可选角色" % [file, cid])
			continue
		var seen := {}
		for stage in d.get("stages", []):
			if seen.has(str(stage.get("id", ""))):
				errors.append("%s：关卡 id“%s”重复" % [file, str(stage.get("id", ""))])
			seen[str(stage.get("id", ""))] = true
			for e in Scenario.validate(stage, maps, all_characters(), rules):
				errors.append("%s：%s" % [file, e])
		campaigns[cid] = d


## 某个角色的主线关卡列表（没有主线返回空数组）
func stages_of(cid: String) -> Array:
	return campaigns.get(cid, {}).get("stages", [])


## 当前默认地图；没有地图时返回 null。
func default_map() -> Board:
	var wanted := str(rules.get("default_map", ""))
	if maps.has(wanted):
		return maps[wanted]
	if not maps.is_empty():
		return maps.values()[0]
	return null


## 这局用的地图：主界面选过就用选的，否则用默认地图。
func selected_map() -> Board:
	if maps.has(start_map):
		return maps[start_map]
	return default_map()


## 可选角色 + 路人（开局、显示名字、头像都用它；主界面选座位只用 characters）
func all_characters() -> Array:
	return characters + extras


## 按 id 找角色（含路人）；找不到返回空字典。
func character(id: String) -> Dictionary:
	for c in all_characters():
		if str(c.get("id", "")) == id:
			return c
	return {}


## 读台词：事件表 + 每个角色一个的 .txt。读不懂的行记进 errors（带文件名和行号）
func _load_lines() -> LinesDb:
	var db := LinesDb.new()
	var map_info: Array = []
	for id in maps:
		map_info.append({"id": id, "name": maps[id].display_name})
	var events_file := JsonUtil.load_dict(LINES_DIR.path_join("events.json"), errors)
	db.setup(events_file, characters, map_info)
	db.load_dir(LINES_DIR)
	errors.append_array(db.errors)
	return db


## 读存档 slot，成功就记在 resume 里（然后切到棋盘画面）。成功返回 ""，否则返回原因
func resume_from_save(slot: String) -> String:
	var r := SaveGame.load_slot(slot, maps, rules,
			{"cards": cards, "special_events": special_events}, all_characters())
	if str(r["error"]) != "":
		return str(r["error"])
	resume = r
	return ""
