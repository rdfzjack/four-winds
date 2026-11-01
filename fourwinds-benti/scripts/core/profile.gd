extends RefCounted
## 玩家进度（和对局存档分开）：每个角色的个人主线打到第几关、哪些主线通关、哪些里形态解锁了。
## 存在 user://profile.json，有版本号；读不到或坏了就当全新（不崩）；写入先写临时文件再改名。
##
## 数据（Dictionary）：
##   {"version": 1, "characters": {角色 id: {"next": 下一关的下标（0 起）, "cleared": 主线是不是通关了}},
##    "back_unlocked": [角色 id, ...]}
## 用法：
##   var p := Profile.load_profile()           # 永远返回一份可用的数据
##   Profile.stage_status(p, "david", i, n)    # "cleared" / "current" / "locked"
##   Profile.mark_cleared(p, "david", i, n)    # 通关第 i 关（共 n 关）；通关最后一关时解锁里形态
##   Profile.save_profile(p)                   # 返回 "" 成功，否则原因

const VERSION := 1

## 文件位置（测试里会改成别的，免得弄脏真文件）
static var path: String = "user://profile.json"


static func fresh() -> Dictionary:
	return {"version": VERSION, "characters": {}, "back_unlocked": []}


## 读进度。文件不存在、读不懂、版本不对都返回全新的（不在输出里报错）。
static func load_profile() -> Dictionary:
	if not FileAccess.file_exists(path):
		return fresh()
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not (json.data is Dictionary):
		return fresh()
	var d: Dictionary = json.data
	if int(d.get("version", 0)) != VERSION or not (d.get("characters", null) is Dictionary):
		return fresh()
	var out := fresh()
	for cid in d["characters"]:
		var e = d["characters"][cid]
		if e is Dictionary:
			out["characters"][str(cid)] = {"next": maxi(0, int(e.get("next", 0))),
					"cleared": bool(e.get("cleared", false))}
	if d.get("back_unlocked", []) is Array:
		for cid in d["back_unlocked"]:
			if not out["back_unlocked"].has(str(cid)):
				out["back_unlocked"].append(str(cid))
	return out


static func save_profile(p: Dictionary) -> String:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return "存不了进度：%s" % error_string(FileAccess.get_open_error())
	f.store_string(JSON.stringify(p, "\t"))
	f.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		return "存不了进度：%s" % error_string(err)
	return ""


## 这个角色下一关是第几关（0 起）；没记录 = 0
static func next_stage(p: Dictionary, cid: String) -> int:
	return int(p["characters"].get(cid, {}).get("next", 0))


## 第 i 关的状态：已通关的和当前的都能玩（可以重玩已通关的关），后面的未解锁
static func stage_status(p: Dictionary, cid: String, i: int, total: int) -> String:
	var nxt := mini(next_stage(p, cid), total)
	if i < nxt:
		return "cleared"
	if i == nxt:
		return "current"
	return "locked"


## 通关第 i 关（共 total 关）。重玩已通关的关不会让进度倒退。通关最后一关：主线通关 + 解锁里形态。
static func mark_cleared(p: Dictionary, cid: String, i: int, total: int) -> void:
	var e: Dictionary = p["characters"].get(cid, {"next": 0, "cleared": false})
	e["next"] = maxi(int(e["next"]), i + 1)
	if i + 1 >= total:
		e["cleared"] = true
		if not p["back_unlocked"].has(cid):
			p["back_unlocked"].append(cid)
	p["characters"][cid] = e


static func main_cleared(p: Dictionary, cid: String) -> bool:
	return bool(p["characters"].get(cid, {}).get("cleared", false))


static func back_unlocked(p: Dictionary, cid: String) -> bool:
	return p["back_unlocked"].has(cid)
