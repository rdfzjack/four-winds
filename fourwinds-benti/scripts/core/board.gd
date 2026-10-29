extends RefCounted
## 棋盘（地图）。
##
## 棋盘按“路网”存：每个格子的 next 列出从这里可以走到的下一格。
## - 一圈的地图：每格只有一个 next。
## - 有岔路的地图：路口格子有多个 next，走到这里时由玩家（或 AI）选方向。
## 规则代码只通过 next_tiles() / walk() 移动，所以以后加岔路不用改规则。
##
## 这个脚本只处理数据，不依赖任何画面节点，可以在无头模式下测试。

const TILE_TYPES := [
	"start",       # 起点
	"land",        # 可买的空地，属于某个街道组
	"company",     # 企业
	"chance",      # 运气（机会卡）
	"bank",        # 银行
	"tax",         # 税务局
	"jail",        # 巡捕房
	"park",        # 公园
	"church",      # 教堂
	"government",  # 市政厅
	"casino",      # 赌场
	"race_course", # 赛马场
]

var id: String = ""
var display_name: String = ""
var start_tile: int = 0
var tiles: Array = []         ## 每格一个 Dictionary，下标就是格子编号
var groups: Dictionary = {}   ## 街道组 id -> {name, color}
var prices: Dictionary = {}   ## 这张地图的建房成本、租金、空地基准价


## 从地图 JSON（已解析成 Dictionary）读取。返回错误列表，空列表表示没问题。
func load_from(d: Dictionary) -> Array:
	var errors: Array = []
	id = str(d.get("id", ""))
	display_name = str(d.get("name", id))
	start_tile = int(d.get("start_tile", 0))
	groups = d.get("groups", {})
	prices = d.get("prices", {})
	tiles = []
	var raw_tiles: Array = d.get("tiles", [])
	for raw in raw_tiles:
		var t: Dictionary = raw.duplicate(true)
		t["id"] = int(t.get("id", -1))
		var nexts: Array = []
		for n in t.get("next", []):
			nexts.append(int(n))
		t["next"] = nexts
		tiles.append(t)
	errors.append_array(validate())
	return errors


func tile_count() -> int:
	return tiles.size()


func get_tile(index: int) -> Dictionary:
	return tiles[index]


## 从 index 出发可以走到的格子。
func next_tiles(index: int) -> Array:
	return tiles[index]["next"]


## 这一格是不是路口（有不止一个方向可走）。
func is_crossroad(index: int) -> bool:
	return next_tiles(index).size() > 1


## 从 from 出发走 steps 步，返回经过的格子（不含起点，最后一个是落点）。
## choices：遇到路口时依次使用的方向（next 里的第几个）；用完或没给就走第一个方向。
func walk(from: int, steps: int, choices: Array = []) -> Array:
	var path: Array = []
	var current := from
	var choice_i := 0
	for _s in range(steps):
		var options := next_tiles(current)
		var pick := 0
		if options.size() > 1 and choice_i < choices.size():
			pick = clampi(int(choices[choice_i]), 0, options.size() - 1)
			choice_i += 1
		current = options[pick]
		path.append(current)
	return path


## 第一块地是 start 的、同一条街上沿路连续的 n 块地（房子占地用）。
## 返回所有可能的走法（路口会产生多条），每条是格子编号的数组，第一个是 start。
## 只看地图本身，不看谁拥有。
func lot_chains(start: int, n: int) -> Array:
	var result: Array = []
	if tiles[start]["type"] != "land":
		return result
	_extend_chain([start], n, result)
	return result


func _extend_chain(chain: Array, n: int, result: Array) -> void:
	if chain.size() == n:
		result.append(chain.duplicate())
		return
	var last: int = chain[chain.size() - 1]
	for nx in next_tiles(last):
		var t: Dictionary = tiles[nx]
		if t["type"] != "land" or t.get("group", "") != tiles[chain[0]].get("group", ""):
			continue
		if chain.has(nx):
			continue
		chain.append(nx)
		_extend_chain(chain, n, result)
		chain.pop_back()


## 这张地图里最长的一条街（同一街道组、沿路连续的地）有几块。
func longest_street() -> int:
	var best := 0
	for i in range(tiles.size()):
		if tiles[i]["type"] != "land":
			continue
		var n := 1
		while not lot_chains(i, n + 1).is_empty():
			n += 1
		best = maxi(best, n)
	return best


## 离 from 最近（沿路往前走的步数最少）的某类格子；找不到返回 -1。
func nearest_of_type(from: int, tile_type: String) -> int:
	var seen := {from: true}
	var queue := [from]
	while not queue.is_empty():
		var cur: int = queue.pop_front()
		for nx in next_tiles(cur):
			if seen.has(nx):
				continue
			if tiles[nx]["type"] == tile_type:
				return nx
			seen[nx] = true
			queue.append(nx)
	return -1


## 检查地图数据是否完整。返回错误列表。
func validate() -> Array:
	var errors: Array = []
	if id == "":
		errors.append("地图缺少 id")
	if tiles.is_empty():
		errors.append("地图没有格子")
		return errors
	var n := tiles.size()
	for i in range(n):
		var t: Dictionary = tiles[i]
		var label := "第 %d 格" % i
		if t["id"] != i:
			errors.append("%s 的 id 是 %d，应该等于它在列表里的位置 %d" % [label, t["id"], i])
		var tile_type := str(t.get("type", ""))
		if not TILE_TYPES.has(tile_type):
			errors.append("%s 的类型 \"%s\" 不认识" % [label, tile_type])
		var nexts: Array = t["next"]
		if nexts.is_empty():
			errors.append("%s 没有下一格（next 为空）" % label)
		for nx in nexts:
			if nx < 0 or nx >= n:
				errors.append("%s 的下一格 %d 超出范围" % [label, nx])
		if tile_type == "land":
			var g := str(t.get("group", ""))
			if not groups.has(g):
				errors.append("%s 的街道组 \"%s\" 没有在 groups 里定义" % [label, g])
			if not t.has("price_pct"):
				errors.append("%s 缺少 price_pct（地价系数）" % label)
			if not t.has("build_cost_pct"):
				errors.append("%s 缺少 build_cost_pct（建房系数）" % label)
		if tile_type == "company":
			if not t.has("price") or not t.has("rent"):
				errors.append("%s 是企业，需要 price 和 rent" % label)
		var pos: Variant = t.get("pos", null)
		if not (pos is Array and pos.size() == 2):
			errors.append("%s 缺少 pos（画面坐标 [x, y]）" % label)
	if start_tile < 0 or start_tile >= n:
		errors.append("start_tile %d 超出范围" % start_tile)
		return errors
	if not errors.is_empty():
		return errors
	# 从起点出发，每一格都要能走到
	var seen := {start_tile: true}
	var queue := [start_tile]
	while not queue.is_empty():
		var cur: int = queue.pop_front()
		for nx in next_tiles(cur):
			if not seen.has(nx):
				seen[nx] = true
				queue.append(nx)
	if seen.size() != n:
		var missing: Array = []
		for i in range(n):
			if not seen.has(i):
				missing.append(i)
		errors.append("从起点走不到这些格子：%s" % str(missing))
	return errors
