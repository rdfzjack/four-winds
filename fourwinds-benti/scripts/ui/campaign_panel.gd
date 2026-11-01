extends VBoxContainer
## 个人主线入口（主界面的弹层里用）：选角色 → 关卡列表 → 关前简介 → 开局。
## 只求能用，不美化。开局的办法：把 {character, stage} 放进 Data.start_stage，再切到棋盘画面。

signal closed

const Scenario = preload("res://scripts/core/scenario.gd")
const Profile = preload("res://scripts/core/profile.gd")

var _profile: Dictionary = {}


func _init() -> void:
	add_theme_constant_override("separation", 8)


func setup() -> void:
	_profile = Profile.load_profile()
	_show_characters()


func _clear() -> void:
	for c in get_children():
		c.queue_free()
		remove_child(c)


func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(560, 0)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	add_child(l)
	return l


func _button(text: String, action: Callable, disabled: bool = false) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 44)
	b.disabled = disabled
	b.pressed.connect(action)
	add_child(b)
	return b


# ───────────────────────── 选角色 ─────────────────────────

func _show_characters() -> void:
	_clear()
	_label("个人主线", 26, Color.WHITE)
	_label("选一个角色，打他的主线。", 14, Color("#b0bec5"))
	for c in Data.characters:
		var cid := str(c.get("id", ""))
		var stages := Data.stages_of(cid)
		var text := "%s（%s）" % [c.get("nickname", "?"), c.get("name", "")]
		if stages.is_empty():
			text += " · 还没有关卡"
		else:
			var nxt := mini(Profile.next_stage(_profile, cid), stages.size())
			text += " · 已通关 %d / %d 关" % [nxt, stages.size()]
			if Profile.back_unlocked(_profile, cid):
				text += " · 里形态已解锁"
		_button(text, func() -> void: _show_stages(cid), stages.is_empty())
	_button("返回", func() -> void: closed.emit())


# ───────────────────────── 关卡列表 ─────────────────────────

func _show_stages(cid: String) -> void:
	_clear()
	var camp: Dictionary = Data.campaigns.get(cid, {})
	_label(str(camp.get("name", cid)), 26, Color.WHITE)
	var stages := Data.stages_of(cid)
	for i in range(stages.size()):
		var status := Profile.stage_status(_profile, cid, i, stages.size())
		var mark: String = {"cleared": "已通关", "current": "当前", "locked": "还没打到（测试阶段可直接选）"}[status]
		var stage: Dictionary = stages[i]
		_button("第 %d 关 · %s · %s" % [i + 1, str(stage.get("name", "")), mark],
				func() -> void: _show_briefing(cid, i))
	_button("返回", _show_characters)


# ───────────────────────── 关前简介 ─────────────────────────

func _show_briefing(cid: String, index: int) -> void:
	_clear()
	var stage: Dictionary = Data.stage_for(cid, index)
	var sc := Scenario.new(stage)
	var names := sc.seat_names(Data.all_characters())
	_label("第 %d 关 · %s" % [index + 1, str(stage.get("name", ""))], 26, Color.WHITE)
	var board = Data.maps.get(str(stage.get("map", "")))
	_label("地图：%s" % (board.display_name if board != null else "（找不到）"), 14, Color("#b0bec5"))
	var intro := str(stage.get("intro", ""))
	if intro != "":
		_label(intro, 16, Color("#cfd8dc"))
	_label(sc.goals_text(names), 16, Color("#ffd54f"))
	_label("开局资金（调试：在这里改只对这次运行有效，不写进文件；改完点“开始”）", 13, Color("#b0bec5"))
	for i in range(names.size()):
		_seat_row(cid, index, i, names[i], i == sc.player_seat)
	var cross := CheckBox.new()
	cross.text = "这一关的路口默认全部随机（下面单独指定的除外）"
	cross.button_pressed = str(stage.get("crossroad", "")) == "random"
	cross.toggled.connect(func(on: bool) -> void:
			var st := _editable(cid, index)
			if on:
				st["crossroad"] = "random"
			else:
				st.erase("crossroad"))
	add_child(cross)
	if board != null:
		_label("每个路口单独设置（地图上路口处一直显示“自选 / 随机”和出口箭头）", 13, Color("#b0bec5"))
		for t in board.tiles:
			if board.is_crossroad(int(t["id"])):
				_crossroad_row(cid, index, board, int(t["id"]))
	_button("开始", func() -> void:
			Data.start_stage = {"character": cid, "stage": index}
			get_tree().change_scene_to_file("res://scenes/table.tscn"))
	_button("复制这一关的数据（JSON，要永久改就粘进 data/campaigns/%s.json）" % cid, func() -> void:
			DisplayServer.clipboard_set(JSON.stringify(Data.stage_for(cid, index), "  ")))
	_button("恢复默认", func() -> void:
			Data.stage_override.erase("%s:%d" % [cid, index])
			_show_briefing(cid, index))
	_button("返回", func() -> void: _show_stages(cid))


## 路口 id 的一行：说明出口去哪，下拉选 按默认 / 自选 / 随机
func _crossroad_row(cid: String, index: int, board, id: int) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	add_child(row)
	var exits: Array = []
	for n in board.next_tiles(id):
		exits.append(_front_name(board, int(n)))
	var label := Label.new()
	label.text = "路口 %d → %s" % [id, " / ".join(exits)]
	label.custom_minimum_size = Vector2(360, 0)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(label)
	var pick := OptionButton.new()
	var base: String = "自选" if board.crossroad_mode(id) == "choice" else "随机"
	pick.add_item("按默认（地图：%s）" % base)
	pick.add_item("自选")
	pick.add_item("随机")
	var current: Dictionary = Data.stage_for(cid, index).get("crossroads", {})
	var mode := str(current.get(str(id), ""))
	pick.select(1 if mode == "choice" else (2 if mode == "random" else 0))
	pick.item_selected.connect(func(i: int) -> void:
			var st := _editable(cid, index)
			if not st.has("crossroads"):
				st["crossroads"] = {}
			if i == 0:
				st["crossroads"].erase(str(id))
			else:
				st["crossroads"][str(id)] = "choice" if i == 1 else "random")
	row.add_child(pick)


## 出口前方第一个有名字的地方（沿路往前走）
func _front_name(board, first: int) -> String:
	var cur := first
	for _i in range(12):
		var t: Dictionary = board.get_tile(cur)
		var site: int = board.site(cur)
		var nm := str(board.get_tile(site).get("name", ""))
		if nm != "" and str(board.get_tile(site)["type"]) != "road":
			return nm
		cur = int(t["next"][0])
	return "（前方）"


## 这一关的可改副本（第一次改时从 data 复制一份放进 Data.stage_override）
func _editable(cid: String, index: int) -> Dictionary:
	var key := "%s:%d" % [cid, index]
	if not Data.stage_override.has(key):
		Data.stage_override[key] = Data.stages_of(cid)[index].duplicate(true)
	return Data.stage_override[key]


func _seat_row(cid: String, index: int, seat_index: int, name: String, is_player: bool) -> void:
	var seat: Dictionary = Data.stage_for(cid, index)["seats"][seat_index]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	add_child(row)
	var label := Label.new()
	label.text = "%s%s" % [name, "（你）" if is_player else ""]
	label.custom_minimum_size = Vector2(150, 0)
	row.add_child(label)
	for field in ["cash", "deposit"]:
		var caption := Label.new()
		caption.text = "现金" if field == "cash" else "存款"
		row.add_child(caption)
		var box := SpinBox.new()
		box.min_value = 0
		box.max_value = 99999
		box.step = 100
		box.value = float(seat.get(field, Data.rules.get("starting_" + field, 0)))
		box.value_changed.connect(func(v: float) -> void:
				_editable(cid, index)["seats"][seat_index][field] = int(v))
		row.add_child(box)
