extends Control
## 界面层上的骰子：有素材画素材（art.gd 的 dice），没有就画白方块和点。

const Art = preload("res://scripts/ui/art.gd")
## 没有素材时，点数画在 3×3 格子里的哪几格（从左上数 0-8）
const PIPS := {
	1: [4], 2: [0, 8], 3: [0, 4, 8], 4: [0, 2, 6, 8], 5: [0, 2, 4, 6, 8], 6: [0, 2, 3, 5, 6, 8],
}
const SIZE := Vector2(116, 81)

var values: Array = []:
	set(v):
		values = v
		queue_redraw()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(SIZE.x * 2, SIZE.y)


func _draw() -> void:
	var x := (size.x - SIZE.x * values.size()) / 2.0
	for v in values:
		var f := Art.frame("dice", int(v) - 1)
		if not f.is_empty():
			draw_texture(f["tex"], Vector2(x, 0))
		else:
			_draw_plain(Vector2(x + 20, 10), 56.0, int(v))
		x += SIZE.x


func _draw_plain(top_left: Vector2, d: float, value: int) -> void:
	draw_rect(Rect2(top_left, Vector2(d, d)), Color.WHITE)
	draw_rect(Rect2(top_left, Vector2(d, d)), Color.BLACK, false, 2.0)
	for k in PIPS.get(value, []):
		var cx := top_left.x + d * (0.2 + 0.3 * (int(k) % 3))
		var cy := top_left.y + d * (0.2 + 0.3 * (int(k) / 3))
		draw_circle(Vector2(cx, cy), d * 0.07, Color.BLACK)
