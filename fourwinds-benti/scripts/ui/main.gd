extends Control
## 主界面：选座位（每个位置选人类 / AI / 空，再选角色），然后开始热座对局。
## 同时显示数据检查结果，数据读取有问题时在这里能看到。

const SEAT_COUNT := 4
const SEAT_KINDS := ["人类", "AI", "空"]
const DEFAULT_KINDS := [0, 1, 1, 1]
const BACKGROUND := Color("#1e2a24")

var _kind_boxes: Array = []
var _char_boxes: Array = []
var _hint: Label = null
var _map_box: OptionButton = null
var _map_ids: Array = []


func _ready() -> void:
	var back := ColorRect.new()
	back.color = BACKGROUND
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(back)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(620, 0)
	box.add_theme_constant_override("separation", 10)
	center.add_child(box)

	_label(box, "四方来财 Four Winds", 36, Color.WHITE)
	_add_map_choice(box)
	_label(box, "热座：每个位置选人类或 AI", 15, Color("#b0bec5"))
	box.add_child(HSeparator.new())

	for i in range(SEAT_COUNT):
		_add_seat(box, i)

	_hint = _label(box, "", 14, Color("#ef9a9a"))
	var start := Button.new()
	start.text = "开始游戏"
	start.custom_minimum_size = Vector2(0, 48)
	start.add_theme_font_size_override("font_size", 20)
	start.pressed.connect(_on_start)
	box.add_child(start)

	box.add_child(HSeparator.new())
	if Data.errors.is_empty():
		_label(box, "✔ 数据检查通过 · 机会卡 %d 张" % Data.cards.size(), 14, Color("#81c784"))
	else:
		_label(box, "数据有 %d 个问题：" % Data.errors.size(), 15, Color("#ef5350"))
		for e in Data.errors:
			_label(box, "· " + str(e), 13, Color("#ef9a9a"))


## 选地图：data/maps 里的每张图一项，默认选 rules.json 的 default_map
func _add_map_choice(parent: Node) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)
	var title := _label(row, "地图", 18, Color.WHITE)
	title.custom_minimum_size = Vector2(80, 0)
	_map_box = OptionButton.new()
	_map_box.custom_minimum_size = Vector2(520, 40)
	row.add_child(_map_box)
	var fallback = Data.default_map()
	_map_ids = Data.maps.keys()
	_map_ids.sort()
	for id in _map_ids:
		var board = Data.maps[id]
		_map_box.add_item("%s（%d 格）" % [board.display_name, board.tile_count()])
		if fallback != null and id == fallback.id:
			_map_box.select(_map_box.item_count - 1)


func _add_seat(parent: Node, i: int) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)
	var num := _label(row, "位置 %d" % (i + 1), 18, Color.WHITE)
	num.custom_minimum_size = Vector2(80, 0)

	var kind := OptionButton.new()
	for k in SEAT_KINDS:
		kind.add_item(k)
	kind.select(DEFAULT_KINDS[i])
	kind.custom_minimum_size = Vector2(110, 40)
	row.add_child(kind)

	var who := OptionButton.new()
	for c in Data.characters:
		who.add_item("%s（%s）· %s" % [c.get("nickname", "?"), c.get("name", ""), c.get("identity", "")])
	who.select(mini(i, Data.characters.size() - 1))
	who.custom_minimum_size = Vector2(400, 40)
	row.add_child(who)
	_kind_boxes.append(kind)
	_char_boxes.append(who)


func _label(parent: Node, text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	parent.add_child(l)
	return l


func _on_start() -> void:
	var specs: Array = []
	var used := {}
	for i in range(SEAT_COUNT):
		var kind: int = _kind_boxes[i].selected
		if kind == 2:
			continue
		var cid := str(Data.characters[_char_boxes[i].selected].get("id", ""))
		if used.has(cid):
			_hint.text = "同一个角色不能坐两个位置，请换一个。"
			return
		used[cid] = true
		specs.append({"character": cid, "human": kind == 0})
	if specs.size() < 2:
		_hint.text = "至少要 2 个玩家。"
		return
	if _map_ids.is_empty():
		_hint.text = "没有读到地图，看下面的数据问题。"
		return
	Data.start_map = str(_map_ids[_map_box.selected])
	Data.start_specs = specs
	get_tree().change_scene_to_file("res://scenes/table.tscn")
