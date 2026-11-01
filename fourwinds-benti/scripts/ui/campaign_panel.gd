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
		var mark: String = {"cleared": "已通关", "current": "当前", "locked": "未解锁"}[status]
		var stage: Dictionary = stages[i]
		_button("第 %d 关 · %s · %s" % [i + 1, str(stage.get("name", "")), mark],
				func() -> void: _show_briefing(cid, i), status == "locked")
	_button("返回", _show_characters)


# ───────────────────────── 关前简介 ─────────────────────────

func _show_briefing(cid: String, index: int) -> void:
	_clear()
	var stage: Dictionary = Data.stages_of(cid)[index]
	var sc := Scenario.new(stage)
	var names := sc.seat_names(Data.all_characters())
	_label("第 %d 关 · %s" % [index + 1, str(stage.get("name", ""))], 26, Color.WHITE)
	var board = Data.maps.get(str(stage.get("map", "")))
	_label("地图：%s" % (board.display_name if board != null else "（找不到）"), 14, Color("#b0bec5"))
	var intro := str(stage.get("intro", ""))
	if intro != "":
		_label(intro, 16, Color("#cfd8dc"))
	var lines: Array = []
	for i in range(names.size()):
		var seat: Dictionary = stage["seats"][i]
		var cash := str(int(seat["cash"])) if seat.has("cash") else "默认"
		var deposit := str(int(seat["deposit"])) if seat.has("deposit") else "默认"
		lines.append("%s%s：现金 %s 万 · 存款 %s 万" % [names[i], "（你）" if i == sc.player_seat else "",
				cash, deposit])
	_label("\n".join(lines), 14, Color.WHITE)
	_label(sc.goals_text(names), 16, Color("#ffd54f"))
	_button("开始", func() -> void:
			Data.start_stage = {"character": cid, "stage": index}
			get_tree().change_scene_to_file("res://scenes/table.tscn"))
	_button("返回", func() -> void: _show_stages(cid))
