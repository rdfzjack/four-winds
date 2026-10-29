extends Control
## 第 0 步的主界面：确认数据能读进来，并按地图数据把棋盘画出来。
## 还不能玩，掷骰、买地这些在后面的步骤里加。

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
}
const TYPE_NAMES := {
	"start": "起点", "land": "空地", "company": "企业", "chance": "运气",
	"bank": "银行", "tax": "税务局", "jail": "巡捕房", "park": "公园",
	"church": "教堂", "government": "市政厅", "casino": "赌场", "race_course": "赛马场",
}
const Board = preload("res://scripts/core/board.gd")
const BACKGROUND := Color("#1e2a24")
const SIDE_PANEL_WIDTH := 300.0
const MARGIN := 24.0

var board: Board = null
var font: Font


func _ready() -> void:
	font = get_theme_default_font()
	board = Data.default_map()
	_build_side_panel()
	resized.connect(queue_redraw)
	queue_redraw()


func _build_side_panel() -> void:
	var panel := VBoxContainer.new()
	panel.position = Vector2(MARGIN, MARGIN)
	panel.custom_minimum_size = Vector2(SIDE_PANEL_WIDTH - MARGIN, 0)
	panel.add_theme_constant_override("separation", 6)
	add_child(panel)

	_add_label(panel, "四方来财 Four Winds", 26, Color.WHITE)
	_add_label(panel, "第 0 步：项目骨架（还不能玩）", 14, Color("#b0bec5"))

	if board != null:
		_add_label(panel, "地图：%s（%d 格）" % [board.display_name, board.tile_count()], 16, Color.WHITE)
	else:
		_add_label(panel, "没有读到地图", 16, Color("#ef5350"))

	_add_label(panel, "", 8, Color.WHITE)
	_add_label(panel, "角色", 18, Color.WHITE)
	for c in Data.characters:
		var line := "%s（%s）%s" % [c.get("name", "?"), c.get("nickname", ""), c.get("identity", "")]
		_add_label(panel, "● " + line, 15, Color(str(c.get("color", "#ffffff"))))

	_add_label(panel, "", 8, Color.WHITE)
	if Data.errors.is_empty():
		_add_label(panel, "✔ 数据检查通过", 16, Color("#81c784"))
	else:
		_add_label(panel, "数据有 %d 个问题：" % Data.errors.size(), 16, Color("#ef5350"))
		for e in Data.errors:
			_add_label(panel, "· " + str(e), 13, Color("#ef9a9a"))


func _add_label(parent: Node, text: String, font_size: int, color: Color) -> void:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(SIDE_PANEL_WIDTH - MARGIN, 0)
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	parent.add_child(l)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BACKGROUND)
	if board == null or board.tile_count() == 0:
		return

	# 算出能放下整张地图的格子大小
	var min_p := Vector2(INF, INF)
	var max_p := Vector2(-INF, -INF)
	for t in board.tiles:
		var p := Vector2(t["pos"][0], t["pos"][1])
		min_p = min_p.min(p)
		max_p = max_p.max(p)
	var cols := max_p.x - min_p.x + 1.0
	var rows := max_p.y - min_p.y + 1.0
	var area := Rect2(SIDE_PANEL_WIDTH + MARGIN, MARGIN,
			size.x - SIDE_PANEL_WIDTH - 2.0 * MARGIN, size.y - 2.0 * MARGIN)
	var cell := minf(area.size.x / cols, area.size.y / rows)
	var origin := area.position + (area.size - Vector2(cols, rows) * cell) / 2.0

	var centers := {}
	for t in board.tiles:
		var gp := Vector2(t["pos"][0], t["pos"][1]) - min_p
		centers[t["id"]] = origin + (gp + Vector2(0.5, 0.5)) * cell

	# 走向箭头：每格指向它的下一格
	for t in board.tiles:
		for nx in t["next"]:
			_draw_arrow(centers[t["id"]], centers[nx], cell)

	# 格子
	var pad := cell * 0.06
	var font_size := int(clampf(cell * 0.16, 9.0, 16.0))
	for t in board.tiles:
		var c: Vector2 = centers[t["id"]]
		var rect := Rect2(c - Vector2(cell, cell) / 2.0 + Vector2(pad, pad),
				Vector2(cell, cell) - Vector2(pad, pad) * 2.0)
		var tile_type := str(t.get("type", ""))
		draw_rect(rect, TYPE_COLORS.get(tile_type, Color.MAGENTA))
		if tile_type == "land":
			var g: Dictionary = board.groups.get(str(t.get("group", "")), {})
			var strip := Rect2(rect.position, Vector2(rect.size.x, rect.size.y * 0.22))
			draw_rect(strip, Color(str(g.get("color", "#ffffff"))))
		if board.is_crossroad(t["id"]):
			draw_rect(rect, Color("#ffeb3b"), false, 3.0)
		var name_text := str(t.get("name", TYPE_NAMES.get(tile_type, tile_type)))
		_draw_centered_text(name_text, c + Vector2(0, -cell * 0.02), rect.size.x - 4.0, font_size)
		var sub := ""
		if tile_type == "land":
			sub = "地价 %d" % _land_price(t)
		elif tile_type == "company":
			sub = "%d / 租 %d" % [int(t.get("price", 0)), int(t.get("rent", 0))]
		if sub != "":
			_draw_centered_text(sub, c + Vector2(0, cell * 0.24), rect.size.x - 4.0, maxi(font_size - 2, 8))
		_draw_centered_text(str(t["id"]), rect.position + Vector2(rect.size.x / 2.0, rect.size.y - 4.0),
				rect.size.x, maxi(font_size - 4, 8), Color(0, 0, 0, 0.45))

	# 4 个棋子都摆在起点
	var start: Vector2 = centers[board.start_tile]
	var i := 0
	for ch in Data.characters:
		var offset := Vector2((i % 2) * 2 - 1, (i >> 1) * 2 - 1) * cell * 0.18
		draw_circle(start + offset, cell * 0.11, Color(str(ch.get("color", "#ffffff"))))
		draw_arc(start + offset, cell * 0.11, 0.0, TAU, 24, Color.BLACK, 1.5)
		i += 1


## 空地价格 = 地价系数 × 本图空地基准价 ÷ 100（原版公式）
func _land_price(t: Dictionary) -> int:
	var base := int(board.prices.get("blank_land_price", 0))
	return int(t.get("price_pct", 0)) * base / 100


func _draw_arrow(from: Vector2, to: Vector2, cell: float) -> void:
	var dir := (to - from)
	if dir.length() < 1.0:
		return
	dir = dir.normalized()
	var color := Color(1, 1, 1, 0.35)
	var a := from + dir * cell * 0.42
	var b := to - dir * cell * 0.42
	draw_line(a, b, color, 2.0)
	var side := Vector2(-dir.y, dir.x)
	var head := cell * 0.08
	draw_colored_polygon(PackedVector2Array([b, b - dir * head + side * head * 0.6,
			b - dir * head - side * head * 0.6]), color)


func _draw_centered_text(text: String, center: Vector2, width: float, font_size: int,
		color: Color = Color.BLACK) -> void:
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var shown := text
	while w > width and shown.length() > 1:
		shown = shown.substr(0, shown.length() - 1)
		w = font.get_string_size(shown, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(font, Vector2(center.x - w / 2.0, center.y), shown,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
