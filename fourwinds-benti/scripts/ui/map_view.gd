extends Node2D
## 地图层：格子、房子、棋子。放在默认画布上，跟着 Camera2D 移动；界面层（HUD）在 CanvasLayer 里不动。
##
## - 位置换算全部走 iso.gd；图片全部走 art.gd（找不到图就画色块）。
## - 每格 pos 是棋子走的“路面格”。空地（land）、企业和公共建筑另有一个“路边格”放地基和房子：
##   地图里写了 lot: [x, y] 就用它；没写就取直路往外侧（远离地图中心）的那一格；拐角格没有路边格，画在路面上。
##   普通路面（road）和分身格（带 site，见 board.gd）没有路边格，也不写名字。
## - 只读 game 的状态来画，不改规则状态。
## - 鼠标左键拖动 / 右键拖动平移镜头，滚轮缩放，单击格子发 tile_clicked。

signal tile_clicked(tile: int)

const Board = preload("res://scripts/core/board.gd")
const Game = preload("res://scripts/core/game.gd")
const Iso = preload("res://scripts/ui/iso.gd")
const Art = preload("res://scripts/ui/art.gd")

const TYPE_COLORS := {
	"start": Color("#f5f5f5"),
	"land": Color("#d7ccc8"),
	"company": Color("#ffb74d"),
	"chance": Color("#ffd54f"),
	"bank": Color("#4db6ac"),
	"tax": Color("#90a4ae"),
	"jail": Color("#616161"),
	"park": Color("#aed581"),
	"church": Color("#ce93d8"),
	"government": Color("#7986cb"),
	"casino": Color("#f06292"),
	"race_course": Color("#a1887f"),
	"road": Color("#8d8a7e"),
}
const TYPE_NAMES := {
	"start": "起点", "land": "空地", "company": "企业", "chance": "运气",
	"bank": "银行", "tax": "税务局", "jail": "巡捕房", "park": "公园",
	"church": "教堂", "government": "市政厅", "casino": "赌场", "race_course": "赛马场",
	"road": "路",
}
## 公共建筑在路边格上画成多高的方块（像素）
const BUILDING_HEIGHT := 26.0
const GRASS_MARGIN := 4                 ## 地图四周多铺几圈草地
const DRAG_THRESHOLD := 6.0             ## 按下后移动超过这么多像素算拖动，不算点击
## 同一格站了几个人时，各自往哪边挪一点（像素）
const TOKEN_SLOTS := [Vector2(0, -2), Vector2(-16, 2), Vector2(16, 2), Vector2(0, 8)]
## Flag 图里 4 个箭头的顺序
const ARROW_FRAMES := {"up_left": 0, "up_right": 1, "down_right": 2, "down_left": 3}

var board: Board = null
var game: Game = null
var camera: Camera2D = null
var player_colors: Array = []

var highlight: Array = []           ## 要高亮的格子（选方向）
var hover_highlight: Array = []     ## 鼠标停在建房按钮上时要占的地
var info_tile: int = -1             ## 点中的格子

var _font: Font
var _road_cell: Dictionary = {}     ## 格子编号 → 路面格（Vector2）
var _lot_cell: Dictionary = {}      ## 格子编号 → 路边格（Vector2），拐角格没有
var _cell_tile: Dictionary = {}     ## Vector2i → 格子编号（点击判定）
var _grass: Rect2i
var _token_tile: Array = []
var _facing: Array = []
var _press_pos := Vector2.ZERO
var _pressed := false
var _dragging := false


func setup(p_board: Board, p_game: Game, colors: Array) -> void:
	board = p_board
	game = p_game
	player_colors = colors
	_font = ThemeDB.fallback_font
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_token_tile.clear()
	_facing.clear()
	for p in game.players:
		_token_tile.append(p.pos)
		_facing.append("down_left")
	_layout()
	queue_redraw()


# ───────────────────────── 给外面用的 ─────────────────────────

## 棋子挪到某格（事件播放时一步步调用）；朝向按这一步的方向
func move_token(player: int, tile: int) -> void:
	var from: int = _token_tile[player]
	if from != tile:
		var delta: Vector2 = _road_cell[tile] - _road_cell[from]
		if absf(delta.x) + absf(delta.y) <= 1.5:   # 只有相邻一步才转向，传送不转
			_facing[player] = Iso.facing(delta)
	_token_tile[player] = tile
	queue_redraw()


func sync_tokens() -> void:
	for p in game.players:
		if _token_tile[p.index] != p.pos:
			move_token(p.index, p.pos)


## 棋子脚底在地图层上的位置（镜头跟随用）
func token_position(player: int) -> Vector2:
	return Iso.to_world(_road_cell[_token_tile[player]])


func tile_position(tile: int) -> Vector2:
	return Iso.to_world(_road_cell[tile])


## 整张地图（含草地）在地图层上的范围，镜头不会移出这个范围
func world_bounds() -> Rect2:
	var r := Rect2()
	var first := true
	for corner in [_grass.position, _grass.end, Vector2i(_grass.position.x, _grass.end.y),
			Vector2i(_grass.end.x, _grass.position.y)]:
		var w := Iso.to_world(Vector2(corner))
		if first:
			r = Rect2(w, Vector2.ZERO)
			first = false
		else:
			r = r.expand(w)
	return r


## 地图层位置 → 格子编号（没点在格子上是 -1）
func tile_at(world: Vector2) -> int:
	return int(_cell_tile.get(Iso.to_cell(world), -1))


# ───────────────────────── 布局：路面格、路边格 ─────────────────────────

func _layout() -> void:
	_road_cell.clear()
	_lot_cell.clear()
	_cell_tile.clear()
	var prev := {}
	var centre := Vector2.ZERO
	for t in board.tiles:
		var c := Vector2(t["pos"][0], t["pos"][1])
		_road_cell[int(t["id"])] = c
		_cell_tile[Vector2i(c)] = int(t["id"])
		centre += c
		for nx in t["next"]:
			prev[int(nx)] = prev.get(int(nx), []) + [int(t["id"])]
	centre /= maxf(1.0, board.tile_count())
	for t in board.tiles:
		var id := int(t["id"])
		if str(t["type"]) == "start" or _is_bare_road(t):
			continue
		var lot = null
		if t.has("lot"):
			lot = Vector2(t["lot"][0], t["lot"][1])
		elif prev.get(id, []).size() == 1 and t["next"].size() == 1:
			lot = _outside_cell(id, int(prev[id][0]), int(t["next"][0]), centre)
		if lot != null and not _cell_tile.has(Vector2i(lot)):
			_lot_cell[id] = lot
			_cell_tile[Vector2i(lot)] = id
	var lo := Vector2i(1 << 20, 1 << 20)
	var hi := -lo
	for cell in _cell_tile:
		lo = Vector2i(mini(lo.x, cell.x), mini(lo.y, cell.y))
		hi = Vector2i(maxi(hi.x, cell.x), maxi(hi.y, cell.y))
	_grass = Rect2i(lo - Vector2i.ONE * GRASS_MARGIN, hi - lo + Vector2i.ONE * (2 * GRASS_MARGIN + 1))


## 直路上的格子：取垂直于路、离地图中心更远的那一格；拐角返回 null
func _outside_cell(id: int, from: int, to: int, centre: Vector2):
	var here: Vector2 = _road_cell[id]
	var d_in: Vector2 = here - _road_cell[from]
	var d_out: Vector2 = _road_cell[to] - here
	if not d_in.is_equal_approx(d_out) or absf(d_in.x) + absf(d_in.y) != 1.0:
		return null
	var n := Vector2(d_in.y, -d_in.x)
	if n.dot(here - centre) < 0.0:
		n = -n
	return here + n


# ───────────────────────── 输入：拖动、缩放、点击 ─────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button != null:
		match button.button_index:
			MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
				if button.pressed:
					_pressed = true
					_dragging = false
					_press_pos = button.position
				elif _pressed:
					_pressed = false
					if not _dragging and button.button_index == MOUSE_BUTTON_LEFT:
						tile_clicked.emit(tile_at(get_global_mouse_position()))
					_dragging = false
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				if button.pressed and camera != null:
					camera.zoom_step(1 if button.button_index == MOUSE_BUTTON_WHEEL_UP else -1)
				get_viewport().set_input_as_handled()
		return
	var motion := event as InputEventMouseMotion
	if motion != null and _pressed:
		if not _dragging and motion.position.distance_to(_press_pos) > DRAG_THRESHOLD:
			_dragging = true
		if _dragging and camera != null:
			camera.pan_screen(-motion.relative)
		get_viewport().set_input_as_handled()


# ───────────────────────── 画 ─────────────────────────

func _draw() -> void:
	if board == null or game == null:
		return
	_draw_ground()
	for id in _road_cell:
		_draw_road(id)
	for id in _lot_cell:
		_draw_lot(id)
	for id in highlight:
		_draw_choice(int(id))
	for id in hover_highlight + [info_tile]:
		if int(id) >= 0:
			_draw_select(_lot_cell.get(int(id), _road_cell[int(id)]))
	# 立着的东西（房子、公共建筑、棋子）按“靠后的先画”排序
	var items: Array = []
	for id in _lot_cell:
		items.append([Iso.depth(_lot_cell[id]), 0, id])
	for t in board.tiles:
		if not _lot_cell.has(int(t["id"])) and str(t["type"]) != "land":
			items.append([Iso.depth(_road_cell[int(t["id"])]) - 0.01, 0, int(t["id"])])
	var slots := {}
	for p in game.players:
		if p.bankrupt:
			continue
		var tile: int = _token_tile[p.index]
		var n := int(slots.get(tile, 0))
		slots[tile] = n + 1
		items.append([Iso.depth(_road_cell[tile]) + 0.1 + n * 0.01, 1, p.index, n])
	items.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for it in items:
		if it[1] == 0:
			_draw_structure(int(it[2]))
		else:
			_draw_token(int(it[2]), int(it[3]))
	for t in board.tiles:
		_draw_label(t)


func _draw_ground() -> void:
	for x in range(_grass.position.x, _grass.end.x):
		for y in range(_grass.position.y, _grass.end.y):
			var cell := Vector2(x, y)
			# 按格子坐标打散挑一帧草地，每次画出来都一样
			var pick := posmod((x * 73856093) ^ (y * 19349663), 9973)
			if not _draw_frame("grass", cell, pick):
				draw_colored_polygon(Iso.diamond(cell), Color("#5b7a3a"))


func _draw_road(id: int) -> void:
	var cell: Vector2 = _road_cell[id]
	var t := board.get_tile(id)
	var key := "road_plain"
	if t["next"].size() == 1:
		var d: Vector2 = _road_cell[int(t["next"][0])] - cell
		if absf(d.y) < 0.01:
			key = "road_x"
		elif absf(d.x) < 0.01:
			key = "road_y"
	if not _draw_frame(key, cell, id):
		draw_colored_polygon(Iso.diamond(cell), Color("#8d8a7e"))
	if not _lot_cell.has(id) and str(t["type"]) != "land" and not _is_bare_road(t):
		# 拐角上的起点、巡捕房等：路面上铺一层颜色表示类型
		draw_colored_polygon(Iso.diamond(cell, 0.8), _type_color(t, 0.55))
	if board.is_crossroad(id):
		if not _draw_frame("outline", cell):
			draw_polyline(_closed(Iso.diamond(cell, 0.9)), Color.WHITE, 1.5)


func _draw_lot(id: int) -> void:
	var cell: Vector2 = _lot_cell[id]
	var t := board.get_tile(id)
	if str(t["type"]) == "land":
		if not _draw_frame("lot", cell):
			draw_colored_polygon(Iso.diamond(cell), Color("#b8a27a"))
		var g: Dictionary = board.groups.get(str(t.get("group", "")), {})
		# 街道色：靠路一侧画一道色条
		var road := Iso.to_world(_road_cell[id])
		var here := Iso.to_world(cell)
		var mid := here.lerp(road, 0.42)
		var side := (here - road).orthogonal().normalized() * Iso.TILE_W * 0.22
		draw_line(mid - side, mid + side, Color(str(g.get("color", "#ffffff"))), 4.0)
	else:
		draw_colored_polygon(Iso.diamond(cell), _type_color(t, 0.35))
	var o := game.owner_of(id) if game.props.has(id) else -1
	if o >= 0 and Art.frame("sign_tint").is_empty():
		draw_polyline(_closed(Iso.diamond(cell, 0.86)), player_colors[o], 3.0)


func _draw_choice(id: int) -> void:
	var cell: Vector2 = _road_cell[id]
	_draw_select(cell)
	var from := -1
	for p in game.players:
		if p.index == game.current:
			from = _token_tile[p.index]
	if from >= 0:
		_draw_frame("arrow", cell, int(ARROW_FRAMES.get(Iso.facing(cell - _road_cell[from]), 0)))


func _draw_select(cell: Vector2) -> void:
	if not _draw_frame("select", cell):
		draw_polyline(_closed(Iso.diamond(cell, 0.95)), Color("#fff176"), 3.0)


## 路边格上的公共建筑 / 房子画成方块；拐角上的特殊格不画方块
func _draw_structure(id: int) -> void:
	var t := board.get_tile(id)
	if not _lot_cell.has(id):
		return
	var cell: Vector2 = _lot_cell[id]
	if str(t["type"]) == "land":
		var hid := game.house_at(id)
		if hid != 0:
			var h: Dictionary = game.houses[hid]
			_draw_box(cell, 14.0 + 8.0 * _house_level(str(h["kind"])), player_colors[int(h["owner"])])
		elif game.owner_of(id) >= 0:
			_draw_sign(cell, player_colors[game.owner_of(id)])
	else:
		_draw_box(cell, BUILDING_HEIGHT, _type_color(t, 0.0))


## 地主牌（原版：买下的空地上立一块主人颜色的牌子）
func _draw_sign(cell: Vector2, color: Color) -> void:
	var at := Iso.to_world(cell)
	var base := Art.frame("sign")
	var tint := Art.frame("sign_tint")
	if not base.is_empty():
		draw_texture(base["tex"], at - base["pivot"])
	if not tint.is_empty():
		draw_texture(tint["tex"], at - tint["pivot"], color)


func _draw_token(player: int, slot: int) -> void:
	var foot: Vector2 = token_position(player) + TOKEN_SLOTS[slot % TOKEN_SLOTS.size()]
	var p = game.players[player]
	var f := Art.walker(p.character, _facing[player])
	if not f.is_empty():
		draw_texture(f["tex"], foot - f["pivot"])
	else:
		draw_circle(foot + Vector2(0, -10), 9.0, player_colors[player])
	if player == game.current and game.phase != "over":
		# 当前玩家脚下一个小圈
		draw_arc(foot, 12.0, 0.0, TAU, 24, Color.WHITE, 2.0)


func _draw_label(t: Dictionary) -> void:
	if _is_bare_road(t):
		return
	var id := int(t["id"])
	var cell: Vector2 = _lot_cell.get(id, _road_cell[id])
	var pos := Iso.to_world(cell)
	if _lot_cell.has(id) and str(t["type"]) != "land":
		pos.y -= BUILDING_HEIGHT
	var name_text := str(t.get("name", TYPE_NAMES.get(str(t["type"]), "")))
	_text(name_text, pos + Vector2(0, -2), 12, Color.WHITE)
	if game.props.has(id):
		var sub := "%d" % game.property_price(id) if game.owner_of(id) < 0 else "租 %d" % game.rent_of(id)
		_text(sub, pos + Vector2(0, 11), 10, Color("#fff59d"))


# ───────────────────────── 小工具 ─────────────────────────

## 普通路面和分身格：不画路边格、类型色和名字
func _is_bare_road(t: Dictionary) -> bool:
	return t.has("site") or str(t["type"]) == "road"


## 按素材表画一帧，参考点对准格子中心；没有图返回 false
func _draw_frame(key: String, cell: Vector2, index: int = 0) -> bool:
	var f := Art.frame(key, index)
	if f.is_empty():
		return false
	draw_texture(f["tex"], Iso.to_world(cell) - f["pivot"])
	return true


## 等距方块：底面是这一格菱形（缩一点），往上 height 像素
func _draw_box(cell: Vector2, height: float, color: Color) -> void:
	var d := Iso.diamond(cell, 0.7)
	var up := Vector2(0, -height)
	var top := PackedVector2Array([d[0] + up, d[1] + up, d[2] + up, d[3] + up])
	draw_colored_polygon(PackedVector2Array([d[3], d[2], d[2] + up, d[3] + up]), color.darkened(0.35))
	draw_colored_polygon(PackedVector2Array([d[2], d[1], d[1] + up, d[2] + up]), color.darkened(0.15))
	draw_colored_polygon(top, color.lightened(0.15))
	draw_polyline(_closed(top), Color(0, 0, 0, 0.5), 1.0)


func _text(text: String, centre: Vector2, size: int, color: Color) -> void:
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var at := Vector2(centre.x - w / 2.0, centre.y)
	draw_string_outline(_font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 4, Color(0, 0, 0, 0.85))
	draw_string(_font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)


func _type_color(t: Dictionary, darken: float) -> Color:
	return (TYPE_COLORS.get(str(t["type"]), Color.MAGENTA) as Color).darkened(darken)


func _house_level(kind: String) -> int:
	var levels: Array = Data.rules["houses"]["levels"]
	for i in levels.size():
		if str(levels[i]["id"]) == kind:
			return i
	return 0


func _closed(points: PackedVector2Array) -> PackedVector2Array:
	var p := points.duplicate()
	p.append(points[0])
	return p
