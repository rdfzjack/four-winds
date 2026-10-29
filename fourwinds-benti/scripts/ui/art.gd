extends RefCounted
## 素材路径表：画面代码只通过这里拿图。**换素材只改下面的 SPRITES 表。**
##
## 每种图是一张拼图 PNG + 同名 JSON（格式见 tools/copy_placeholder.py 开头）：
##   groups[组][帧] = {rect: [x, y, w, h], pivot: [px, py]}
## pivot 是帧里对准参考点的像素：地面图块对准菱形中心，人物对准脚底。
## 找不到文件时 frame() 返回空字典，画面会退回色块，所以删掉 assets/placeholder/ 也不会报错。

const P := "res://assets/placeholder/"

## 用途 → {sheet: 不带扩展名的路径, group: 第几组, frames: 用哪些帧}
## 人物（walker_*）的 4 个朝向在 FACING_GROUPS 里，不写 group。
const SPRITES := {
	"grass": {"sheet": P + "Surface", "group": 0, "frames": [
		0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18]},
	"road_x": {"sheet": P + "Road", "group": 0, "frames": [1]},       ## 沿格子 x 方向的直路（带虚线）
	"road_y": {"sheet": P + "Road", "group": 0, "frames": [0]},       ## 沿格子 y 方向的直路
	"road_plain": {"sheet": P + "Road", "group": 0, "frames": [2, 3, 4, 5, 6, 7, 8, 9, 10]},
	"lot": {"sheet": P + "Base", "group": 0, "frames": [0]},          ## 路边可买的空地
	"select": {"sheet": P + "Flag", "group": 0, "frames": [5]},       ## 选中 / 高亮框
	"outline": {"sheet": P + "Flag", "group": 0, "frames": [4]},      ## 普通白框（路口）
	"arrow": {"sheet": P + "Flag", "group": 0, "frames": [0, 1, 2, 3]},  ## 方向箭头：↖ ↗ ↘ ↙
	"dice": {"sheet": P + "Saizi", "group": 0, "frames": [0, 1, 2, 3, 4, 5]},  ## 1–6 点
	"walker_david": {"sheet": P + "Wai_g"},
	"walker_giorgio": {"sheet": P + "Hei_b"},
	"walker_marcel": {"sheet": P + "Mai_b"},
	"walker_eric": {"sheet": P + "Tu_c"},
}
## 人物拼图里第几组是哪个朝向（原版走路图：4 组 × 8 帧）
const FACING_GROUPS := {"up_left": 0, "up_right": 1, "down_left": 2, "down_right": 3}

static var _sheets: Dictionary = {}   ## 路径 → {tex: Texture2D, groups: Array}，读不到是 {}
static var _frames: Dictionary = {}   ## 缓存好的 AtlasTexture


## 取一帧：返回 {tex: Texture2D, pivot: Vector2}；没有这张图时返回 {}
## index 是 SPRITES[key].frames 里的第几个（超出就取余，方便按格子随机挑地表）
static func frame(key: String, index: int = 0, group: int = -1) -> Dictionary:
	var spec: Dictionary = SPRITES.get(key, {})
	if spec.is_empty():
		return {}
	var g := group if group >= 0 else int(spec.get("group", 0))
	var f := index
	if spec.has("frames"):
		var list: Array = spec["frames"]
		f = int(list[posmod(index, list.size())])
	var cache_key := "%s:%d:%d" % [key, g, f]
	if _frames.has(cache_key):
		return _frames[cache_key]
	var result := {}
	var sheet := _sheet(str(spec["sheet"]))
	if not sheet.is_empty() and g < sheet["groups"].size():
		var frames: Array = sheet["groups"][g]
		if f < frames.size():
			var r: Array = frames[f]["rect"]
			var atlas := AtlasTexture.new()
			atlas.atlas = sheet["tex"]
			atlas.region = Rect2(r[0], r[1], r[2], r[3])
			var pv: Array = frames[f]["pivot"]
			result = {"tex": atlas, "pivot": Vector2(pv[0], pv[1])}
	_frames[cache_key] = result
	return result


## 人物某个朝向的一帧（不动时用第 0 帧）
static func walker(character_id: String, facing: String, index: int = 0) -> Dictionary:
	return frame("walker_" + character_id, index, int(FACING_GROUPS.get(facing, 2)))


## 这一种图有几帧可挑（地表随机用）
static func frame_count(key: String) -> int:
	var spec: Dictionary = SPRITES.get(key, {})
	return (spec["frames"] as Array).size() if spec.has("frames") else 1


static func _sheet(path: String) -> Dictionary:
	if _sheets.has(path):
		return _sheets[path]
	var result := {}
	if ResourceLoader.exists(path + ".png") and FileAccess.file_exists(path + ".json"):
		var data = JSON.parse_string(FileAccess.get_file_as_string(path + ".json"))
		var tex = load(path + ".png")
		if data is Dictionary and tex is Texture2D:
			result = {"tex": tex, "groups": data["groups"]}
	_sheets[path] = result
	return result
