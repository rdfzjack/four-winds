extends Node
## 全局数据（自动加载，名字是 Data）。
##
## 游戏一启动就读取 res://data/ 下的规则、角色和所有地图，
## 其他脚本直接用 Data.rules、Data.characters、Data.maps 访问。

const JsonUtil = preload("res://scripts/core/json_util.gd")
const Board = preload("res://scripts/core/board.gd")

const RULES_PATH := "res://data/rules.json"
const CHARACTERS_PATH := "res://data/characters.json"
const MAPS_DIR := "res://data/maps"

var rules: Dictionary = {}
var characters: Array = []
var maps: Dictionary = {}     ## 地图 id -> Board
var errors: Array = []        ## 读取或校验时发现的问题，主界面会显示出来


func _ready() -> void:
	reload()


func reload() -> void:
	errors.clear()
	rules = JsonUtil.load_dict(RULES_PATH, errors)
	var chars := JsonUtil.load_dict(CHARACTERS_PATH, errors)
	characters = chars.get("characters", [])
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
