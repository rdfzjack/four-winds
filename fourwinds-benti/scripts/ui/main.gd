extends Control
## 主界面：选座位（每个位置选人类 / 各种 AI / 空，再选角色），然后开始热座对局。
## 同时显示数据检查结果，数据读取有问题时在这里能看到。

const SEAT_COUNT := 4
const SEAT_KINDS := ["人类", "标准 AI（新框架）", "角色 AI（新框架）", "角色 AI（旧框架）", "标准 AI（旧框架）",
		"原版 AI", "空"]
## 每种座位对应的 AI 版本（见 scripts/core/ai.gd）。标准 AI = 没有性格、按“认真玩家”打
const SEAT_AI := ["", "standard_v2", "new_v2", "new", "standard", "original", ""]
## AI 版本名字后面加的标记，对局里分得清（新框架角色 AI 不加，就是角色本人）
const SEAT_SUFFIX := {"standard_v2": "·标准", "new": "·旧角色", "standard": "·旧标准", "original": "·原版"}
const EMPTY_KIND := 6
const DEFAULT_KINDS := [0, 1, 1, 1]
const BACKGROUND := Color("#1e2a24")
const SaveGame = preload("res://scripts/core/save_game.gd")
const SavePanel = preload("res://scripts/ui/save_panel.gd")

var _kind_boxes: Array = []
var _char_boxes: Array = []
var _hint: Label = null
var _map_box: OptionButton = null
var _map_ids: Array = []
var _overlay: Control = null   ## 读档的弹层


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
	_label(box, "热座：每个位置选人类或 AI（标准 AI 没有性格；角色 AI 带性格；名字后面的标记分得清是哪种 AI）", 15,
			Color("#b0bec5"))
	box.add_child(HSeparator.new())

	for i in range(SEAT_COUNT):
		_add_seat(box, i)

	var cross := CheckBox.new()
	cross.text = "路口全部随机（像原版；不勾 = 走到路口自己选方向）"
	cross.button_pressed = Data.crossroads_random
	cross.toggled.connect(func(on: bool) -> void: Data.crossroads_random = on)
	box.add_child(cross)

	var debug := CheckBox.new()
	debug.text = "调试：交易时显示 AI 心里算的账（底价、得失、开价）"
	debug.button_pressed = Data.debug_ai
	debug.toggled.connect(func(on: bool) -> void: Data.debug_ai = on)
	box.add_child(debug)

	_hint = _label(box, "", 14, Color("#ef9a9a"))
	var start := Button.new()
	start.text = "开始游戏"
	start.custom_minimum_size = Vector2(0, 48)
	start.add_theme_font_size_override("font_size", 20)
	start.pressed.connect(_on_start)
	box.add_child(start)
	_add_load_buttons(box)

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
	kind.custom_minimum_size = Vector2(190, 40)
	row.add_child(kind)

	var who := OptionButton.new()
	for c in Data.characters:
		who.add_item("%s（%s）· %s" % [c.get("nickname", "?"), c.get("name", ""), c.get("identity",
				"")])
	who.select(mini(i, Data.characters.size() - 1))
	who.custom_minimum_size = Vector2(320, 40)
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
		if kind == EMPTY_KIND:
			continue
		var cid := str(Data.characters[_char_boxes[i].selected].get("id", ""))
		if used.has(cid):
			_hint.text = "同一个角色不能坐两个位置，请换一个。"
			return
		used[cid] = true
		var spec := {"character": cid, "human": kind == 0}
		if SEAT_AI[kind] != "":
			spec["ai"] = SEAT_AI[kind]
		if SEAT_SUFFIX.has(SEAT_AI[kind]):
			spec["name_suffix"] = SEAT_SUFFIX[SEAT_AI[kind]]
		specs.append(spec)
	if specs.size() < 2:
		_hint.text = "至少要 2 个玩家。"
		return
	if _map_ids.is_empty():
		_hint.text = "没有读到地图，看下面的数据问题。"
		return
	Data.start_map = str(_map_ids[_map_box.selected])
	Data.start_specs = specs
	get_tree().change_scene_to_file("res://scenes/table.tscn")


## 开始游戏下面两个按钮：继续最近的存档（含自动存档）、打开存档列表读档
func _add_load_buttons(parent: Node) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)
	var latest := _latest_save()
	var cont := Button.new()
	cont.custom_minimum_size = Vector2(0, 44)
	cont.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if latest.is_empty():
		cont.text = "继续最近的存档（还没有存档）"
		cont.disabled = true
	else:
		cont.text = "继续最近的存档：%s · 第 %d 天 · %s" % [
			"自动存档" if latest["slot"] == SaveGame.AUTO else "存档 %s" % latest["slot"],
			int(latest["day"]), latest["map_name"]]
		cont.pressed.connect(func() -> void: _load(str(latest["slot"])))
	row.add_child(cont)
	var pick := Button.new()
	pick.text = "读取存档…"
	pick.custom_minimum_size = Vector2(160, 44)
	pick.pressed.connect(_open_load_list)
	row.add_child(pick)


## 存档时间最新的那个存档位（没有存档返回空字典）
func _latest_save() -> Dictionary:
	var best := {}
	for m in SaveGame.slots():
		if m["empty"] or m.get("broken", false):
			continue
		if best.is_empty() or str(m["saved_at"]) > str(best["saved_at"]):
			best = m
	return best


func _open_load_list() -> void:
	if _overlay != null:
		_overlay.queue_free()
	_overlay = ColorRect.new()
	(_overlay as ColorRect).color = Color(0, 0, 0, 0.7)
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_overlay)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(center)
	var frame := PanelContainer.new()
	center.add_child(frame)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(620, 0)
	box.add_theme_constant_override("separation", 8)
	frame.add_child(box)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 430)
	box.add_child(scroll)
	var panel := SavePanel.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(panel)
	panel.setup("load")
	panel.picked.connect(func(slot: String) -> void: _load(slot, panel))
	var close := Button.new()
	close.text = "返回"
	close.custom_minimum_size = Vector2(0, 40)
	close.pressed.connect(func() -> void:
			_overlay.queue_free()
			_overlay = null)
	box.add_child(close)


func _load(slot: String, panel: SavePanel = null) -> void:
	var err := Data.resume_from_save(slot)
	if err != "":
		if panel != null:
			panel.show_message(err, false)
		else:
			_hint.text = err
		return
	get_tree().change_scene_to_file("res://scenes/table.tscn")
