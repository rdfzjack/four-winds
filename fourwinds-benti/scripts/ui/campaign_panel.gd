extends VBoxContainer
## 个人主线入口（主界面的弹层里用）：选角色 → 关卡列表 → 关前简介 → 开局。
## 只求能用，不美化。开局的办法：把 {character, stage} 放进 Data.start_stage，再切到棋盘画面。

signal closed

const Scenario = preload("res://scripts/core/scenario.gd")
const Profile = preload("res://scripts/core/profile.gd")
const StageEdit = preload("res://scripts/core/stage_edit.gd")

## 行业 id → 中文名（企业按行业分组显示用）
const INDUSTRY_NAMES := {"transport": "运输", "entertainment": "娱乐", "shop": "商业", "finance": "金融",
		"public": "公用", "food": "食品", "newspaper": "报业", "weaving": "纺织", "cigarette": "烟草"}

var _profile: Dictionary = {}
var _notice: String = ""   ## 简介页上提示一句（比如“座位已满”）


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
	_label("调试：下面改的只对这次运行有效，不写进文件；改完点“开始”", 13, Color("#b0bec5"))
	for i in range(names.size()):
		_seat_block(cid, index, i, names[i], i == sc.player_seat, board)
	_add_opponent_row(cid, index, stage)
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


## 一个座位：名字、现金、存款（数字框）、移除按钮，下面是他开局的地产 / 企业
func _seat_block(cid: String, index: int, seat_index: int, name: String, is_player: bool,
		board) -> void:
	var stage: Dictionary = Data.stage_for(cid, index)
	var seat: Dictionary = stage["seats"][seat_index]
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
	if not is_player:
		var remove := Button.new()
		remove.text = "移除这个对手"
		remove.pressed.connect(func() -> void:
				var why := StageEdit.remove_seat(_editable(cid, index), seat_index)
				if why != "":
					_notice = why
				_show_briefing(cid, index))
		row.add_child(remove)
	if board != null:
		_props_editor(cid, index, seat_index, board)


## 这个座位开局的地产 / 企业：一行摘要 + 加入（先选街 / 行业，再选具体哪块）+ 移除
func _props_editor(cid: String, index: int, seat_index: int, board) -> void:
	var seat: Dictionary = Data.stage_for(cid, index)["seats"][seat_index]
	var owned: Array = StageEdit.seat_tiles(seat)
	var names: Array = []
	for t in owned:
		names.append("%s(%d)" % [_tile_name(board, int(t)), int(t)])
	var info := Label.new()
	info.text = "　开局拥有：%s" % ("、".join(names) if not names.is_empty() else "无")
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.custom_minimum_size = Vector2(780, 0)
	info.add_theme_font_size_override("font_size", 12)
	add_child(info)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	add_child(row)
	var groups := _groups_of(board)
	var group_box := OptionButton.new()
	for g in groups:
		group_box.add_item(str(g["label"]))
	row.add_child(group_box)
	var tile_box := OptionButton.new()
	row.add_child(tile_box)
	var refill := func(gi: int) -> void:
		tile_box.clear()
		for t in groups[gi]["tiles"]:
			tile_box.add_item("%s（编号 %d）" % [_tile_name(board, int(t)), int(t)])
	group_box.item_selected.connect(refill)
	if not groups.is_empty():
		refill.call(0)
	var add_one := Button.new()
	add_one.text = "加入这块"
	add_one.pressed.connect(func() -> void:
			if tile_box.item_count > 0:
				var tile: int = groups[group_box.selected]["tiles"][tile_box.selected]
				StageEdit.grant(_editable(cid, index), seat_index, [tile])
				_show_briefing(cid, index))
	row.add_child(add_one)
	var add_all := Button.new()
	add_all.text = "整组加入"
	add_all.pressed.connect(func() -> void:
			if not groups.is_empty():
				StageEdit.grant(_editable(cid, index), seat_index, groups[group_box.selected]["tiles"])
				_show_briefing(cid, index))
	row.add_child(add_all)
	if not owned.is_empty():
		var drop := OptionButton.new()
		drop.add_item("移除一项…")
		for t in owned:
			drop.add_item("%s（编号 %d）" % [_tile_name(board, int(t)), int(t)])
		drop.item_selected.connect(func(i: int) -> void:
				if i > 0:
					StageEdit.revoke(_editable(cid, index), seat_index, int(owned[i - 1]))
					_show_briefing(cid, index))
		row.add_child(drop)
		var clear := Button.new()
		clear.text = "清空"
		clear.pressed.connect(func() -> void:
				for t in owned:
					StageEdit.revoke(_editable(cid, index), seat_index, int(t))
				_show_briefing(cid, index))
		row.add_child(clear)


## 地图上能送的东西，按组：每条街、每个行业（label 显示在下拉里，tiles 是正格编号）
func _groups_of(board) -> Array:
	var streets := {}
	var industries := {}
	for t in board.tiles:
		if t.has("site"):
			continue
		if str(t["type"]) == "land":
			var g := str(t.get("group", ""))
			if not streets.has(g):
				streets[g] = []
			streets[g].append(int(t["id"]))
		elif str(t["type"]) == "company":
			var k := str(t.get("industry", ""))
			if not industries.has(k):
				industries[k] = []
			industries[k].append(int(t["id"]))
	var out: Array = []
	for g in streets:
		var gname := str(board.groups.get(g, {}).get("name", g))
		out.append({"label": "街：%s（%d 块）" % [gname, streets[g].size()], "tiles": streets[g]})
	for k in industries:
		out.append({"label": "行业：%s（%d 家）" % [INDUSTRY_NAMES.get(k, k), industries[k].size()],
				"tiles": industries[k]})
	return out


func _tile_name(board, tile: int) -> String:
	return str(board.get_tile(board.site(tile)).get("name", "格子 %d" % tile))


## 加一个对手：选角色（不在这一关里的），钱默认和玩家一样；4 个角色用角色 AI，路人用标准 AI
func _add_opponent_row(cid: String, index: int, stage: Dictionary) -> void:
	var used := {}
	for seat in stage["seats"]:
		used[str(seat.get("character", ""))] = true
	var candidates: Array = []
	for c in Data.all_characters():
		if not used.has(str(c.get("id", ""))):
			candidates.append(c)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	add_child(row)
	var pick := OptionButton.new()
	for c in candidates:
		pick.add_item("%s（%s）" % [str(c.get("nickname", "")), str(c.get("name", ""))])
	row.add_child(pick)
	var add := Button.new()
	add.text = "添加这个对手（钱和你一样）"
	add.disabled = candidates.is_empty()
	add.pressed.connect(func() -> void:
			var st := _editable(cid, index)
			var me: Dictionary = {}
			for seat in st["seats"]:
				if bool(seat.get("player", false)):
					me = seat
			var chosen: Dictionary = candidates[pick.selected]
			var is_extra: bool = Data.extras.has(chosen)
			var why := StageEdit.add_seat(st, str(chosen["id"]), "standard_v2" if is_extra else "new_v2",
					int(me.get("cash", 1000)), int(me.get("deposit", 1000)),
					int(Data.rules.get("max_players", 4)))
			if why != "":
				_notice = why
			_show_briefing(cid, index))
	row.add_child(add)
	if not _notice.is_empty():
		_label(_notice, 13, Color("#ef9a9a"))
		_notice = ""
