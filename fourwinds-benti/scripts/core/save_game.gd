extends RefCounted
## 存档 / 读档（无画面，能无头测试）。
##
## 存什么：整局的状态（Game.export_state）、台词的记忆（Speech.export_state）、日志、以及自定义的 extra。
## 不存地图、规则、机会卡（读档时用当前的数据文件；地图找不到或格子数变了就拒绝读档）。
## 每个存档位两个文件：slot_<名>.json（整局）和 slot_<名>.meta.json（给列表看的小摘要，不用读整局）。
## 位置：1–5 是手动存档位，"auto" 是自动存档（每天开始时画面自动存一次）。
##
## 用法：
##   SaveGame.save("1", game, speech, {"log": [...]})   → "" 成功，否则返回原因
##   var r := SaveGame.load_slot("1", Data.maps, Data.rules, cards_file, Data.characters)
##   r["error"] 不为空就是失败原因；成功时 r["game"]、r["speech"]（状态字典）、r["extra"]
##   SaveGame.slots() → 每个存档位的摘要列表（空位也列出）
## JSON 只有字符串键，所以整数键的字典（地产、房子、关系值……）和小数用 encode() / decode() 做了标记，
## 读回来类型和存进去时完全一样（整数还是整数）。

const Game = preload("res://scripts/core/game.gd")

const VERSION := 1
const MANUAL_SLOTS := ["1", "2", "3", "4", "5"]
const AUTO := "auto"

## 存档目录（测试里会改成别的目录，免得弄脏真存档）
static var dir: String = "user://saves"


static func slot_ids() -> Array:
	return [AUTO] + MANUAL_SLOTS


static func _path(slot: String) -> String:
	return dir.path_join("slot_%s.json" % slot)


static func _meta_path(slot: String) -> String:
	return dir.path_join("slot_%s.meta.json" % slot)


# ───────────────────────── 存 ─────────────────────────

## 存到 slot。成功返回 ""，否则返回原因。先写临时文件再改名，写到一半断电也不会毁掉原来的存档。
static func save(slot: String, game, speech = null, extra: Dictionary = {}) -> String:
	if game.phase == "over":
		return "这局已经结束了，不能存档"
	if game.phase == "idle":
		return "这局还没开始"
	var body := {
		"version": VERSION, "game": game.export_state(),
		"speech": speech.export_state() if speech != null else {}, "extra": extra,
	}
	DirAccess.make_dir_recursive_absolute(dir)
	var err := _write(_path(slot), JSON.stringify(encode(body)))
	if err == "":
		err = _write(_meta_path(slot), JSON.stringify(_make_meta(slot, game)))
	return err


static func _make_meta(slot: String, game) -> Dictionary:
	var seats: Array = []
	for p in game.players:
		seats.append({"name": p.display_name, "character": p.character, "human": p.human,
				"bankrupt": p.bankrupt, "assets": game.total_assets(p.index)})
	return {
		"version": VERSION, "slot": slot, "map": game.board.id, "map_name": game.board.display_name,
		"day": game.day, "current": game.current, "players": seats,
		"saved_at": Time.get_datetime_string_from_system(false, true),
	}


static func _write(path: String, text: String) -> String:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return "存不了：%s" % error_string(FileAccess.get_open_error())
	f.store_string(text)
	f.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var rename_err := DirAccess.rename_absolute(tmp, path)
	if rename_err != OK:
		return "存不了：%s" % error_string(rename_err)
	return ""


# ───────────────────────── 看 ─────────────────────────

## 每个存档位的摘要，按 slot_ids() 的顺序：{slot, empty: 是不是空位, 其余见 _make_meta}
## 摘要读不了（文件坏了）的位置记 {slot, empty: false, broken: true}
static func slots() -> Array:
	var out: Array = []
	for slot in slot_ids():
		out.append(meta(slot))
	return out


static func meta(slot: String) -> Dictionary:
	if not FileAccess.file_exists(_path(slot)):
		return {"slot": slot, "empty": true}
	var parsed = _parse(FileAccess.get_file_as_string(_meta_path(slot)))
	if not (parsed is Dictionary) or not parsed.has("day"):
		return {"slot": slot, "empty": false, "broken": true}
	var m: Dictionary = decode(parsed)
	m["empty"] = false
	return m


## 解析 JSON；读不懂返回 null（不在输出里报错）
static func _parse(text: String) -> Variant:
	var json := JSON.new()
	return json.data if json.parse(text) == OK else null


static func delete(slot: String) -> void:
	for path in [_path(slot), _meta_path(slot)]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


# ───────────────────────── 读 ─────────────────────────

## 读 slot，装成一局游戏。maps 是 地图 id -> Board。
## 返回 {error, game, speech, extra}：error 不为空就是失败原因（其他项没有）。
static func load_slot(slot: String, maps: Dictionary, rules: Dictionary, cards_file: Dictionary,
		characters: Array) -> Dictionary:
	if not FileAccess.file_exists(_path(slot)):
		return {"error": "这个存档位是空的"}
	var parsed = _parse(FileAccess.get_file_as_string(_path(slot)))
	if not (parsed is Dictionary):
		return {"error": "存档文件坏了，读不出来"}
	if int(parsed.get("version", 0)) != VERSION:
		return {"error": "存档版本不对（存档 %s，现在是 %d）" % [str(parsed.get("version", "?")), VERSION]}
	var body: Dictionary = decode(parsed)
	var state: Dictionary = body["game"]
	var map_id := str(state.get("map", ""))
	if not maps.has(map_id):
		return {"error": "存档用的地图“%s”现在找不到了" % map_id}
	var board = maps[map_id]
	if board.tile_count() != int(state.get("tile_count", -1)):
		return {"error": "地图“%s”改过（格子数不一样），这个存档读不了" % map_id}
	var specs: Array = []
	for seat in state["players"]:
		specs.append({"character": str(seat["character"]), "human": bool(seat["human"])})
	var game = Game.new()
	var errors: Array = game.setup(board, rules, cards_file, characters, specs, 1)
	if not errors.is_empty():
		return {"error": "开局失败：%s" % str(errors)}
	var err: String = game.import_state(state)
	if err != "":
		return {"error": err}
	return {"error": "", "game": game, "speech": body.get("speech", {}), "extra": body.get("extra",
			{})}


# ───────────────────────── JSON 编码 ─────────────────────────
## 整数留作整数；小数记成 {"__f": "16 位十六进制"}（按位存，不丢精度）；键不全是字符串的字典记成 {"__d": [[键, 值], ...]}。

static func encode(v: Variant) -> Variant:
	match typeof(v):
		TYPE_DICTIONARY:
			var plain: bool = not v.has("__f") and not v.has("__d")
			for k in v:
				if typeof(k) != TYPE_STRING:
					plain = false
			if plain:
				var out := {}
				for k in v:
					out[k] = encode(v[k])
				return out
			var pairs: Array = []
			for k in v:
				pairs.append([encode(k), encode(v[k])])
			return {"__d": pairs}
		TYPE_ARRAY:
			var arr: Array = []
			for x in v:
				arr.append(encode(x))
			return arr
		TYPE_FLOAT:
			var bytes := PackedByteArray()
			bytes.resize(8)
			bytes.encode_double(0, v)
			return {"__f": bytes.hex_encode()}  # 按位存，读回来一个位都不差
		TYPE_STRING_NAME:
			return str(v)
		TYPE_INT, TYPE_STRING, TYPE_BOOL, TYPE_NIL:
			return v
	push_error("存档不认识这种数据：%s" % str(v))
	return null


static func decode(v: Variant) -> Variant:
	match typeof(v):
		TYPE_DICTIONARY:
			if v.size() == 1 and v.has("__f"):
				return str(v["__f"]).hex_decode().decode_double(0)
			if v.size() == 1 and v.has("__d"):
				var out := {}
				for pair in v["__d"]:
					out[decode(pair[0])] = decode(pair[1])
				return out
			var plain := {}
			for k in v:
				plain[k] = decode(v[k])
			return plain
		TYPE_ARRAY:
			var arr: Array = []
			for x in v:
				arr.append(decode(x))
			return arr
		TYPE_FLOAT:
			return int(v)  # JSON 里的数字都是整数存的（小数有标记）；读出来是浮点，转回整数
	return v
