extends VBoxContainer
## 存档位列表（存档和读档共用）：每个存档位一行，显示天数、地图、玩家、存档时间，右边是操作按钮。
## 用法：
##   var panel := SavePanel.new()
##   panel.setup("save" 或 "load", 读档前要不要二次确认)
##   panel.picked.connect(func(slot: String) -> void: ...)   点了某个存档位的存 / 读按钮
##   panel.show_message("已存档", true)                       在列表上方写一句结果
## 覆盖已有存档、删除存档、（需要时）读档，都要点两次才生效，第一次点会提示。不碰游戏本身，只管列表和点击。

signal picked(slot: String)

const SaveGame = preload("res://scripts/core/save_game.gd")

var mode: String = "save"
var confirm_load: bool = false
var _armed: String = ""       ## 等第二次点击确认的操作："save:1" / "load:1" / "del:1"
var _message: String = ""
var _message_ok: bool = true


func setup(p_mode: String, p_confirm_load: bool = false) -> void:
	mode = p_mode
	confirm_load = p_confirm_load
	add_theme_constant_override("separation", 6)
	_rebuild()


func show_message(text: String, ok: bool) -> void:
	_message = text
	_message_ok = ok
	_armed = ""
	_rebuild()


func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
	var title := "存档" if mode == "save" else "读档"
	_label(self, title, 20, Color.WHITE)
	if _message != "":
		_label(self, _message, 14, Color("#81c784") if _message_ok else Color("#ef9a9a"))
	for m in SaveGame.slots():
		if mode == "save" and m["slot"] == SaveGame.AUTO:
			continue  # 自动存档位只由游戏自己写
		if mode == "load" and m["empty"] and m["slot"] == SaveGame.AUTO:
			continue
		_add_row(m)
	if mode == "load" and not _any_save():
		_label(self, "还没有存档", 14, Color("#90a4ae"))


func _any_save() -> bool:
	for m in SaveGame.slots():
		if not m["empty"]:
			return true
	return false


func _add_row(m: Dictionary) -> void:
	var slot: String = m["slot"]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	add_child(row)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(info)
	var name := "自动存档（每天开始时）" if slot == SaveGame.AUTO else "存档 %s" % slot
	_label(info, name, 16, Color.WHITE)
	_label(info, _describe(m), 13, Color("#b0bec5"))

	var act := Button.new()
	act.custom_minimum_size = Vector2(150, 40)
	var key := "%s:%s" % [mode, slot]
	var broken: bool = not m["empty"] and m.get("broken", false)
	if mode == "save":
		act.text = "存到这里" if m["empty"] else ("再点一次覆盖" if _armed == key else "覆盖")
	else:
		act.text = "读取" if not confirm_load else ("再点一次读取" if _armed == key else "读取")
		act.disabled = m["empty"] or broken
	act.pressed.connect(func() -> void: _on_action(key, slot, bool(m["empty"])))
	row.add_child(act)
	if not m["empty"]:
		var del := Button.new()
		del.custom_minimum_size = Vector2(90, 40)
		del.text = "再点删除" if _armed == "del:" + slot else "删除"
		del.pressed.connect(func() -> void: _on_delete(slot))
		row.add_child(del)


func _on_action(key: String, slot: String, empty: bool) -> void:
	var needs_confirm := (mode == "save" and not empty) or (mode == "load" and confirm_load)
	if needs_confirm and _armed != key:
		_armed = key
		_message = ""
		if mode == "load":
			_message = "读取会丢掉现在这局没存的进度，再点一次确认"
			_message_ok = false
		_rebuild()
		return
	_armed = ""
	picked.emit(slot)


func _on_delete(slot: String) -> void:
	if _armed != "del:" + slot:
		_armed = "del:" + slot
		_rebuild()
		return
	SaveGame.delete(slot)
	show_message("已删除", true)


## 一行摘要：第 12 天 · 地图 · 玩家 · 时间
func _describe(m: Dictionary) -> String:
	if m["empty"]:
		return "（空）"
	if m.get("broken", false):
		return "（存档文件损坏，读不了，可以删除）"
	var names: Array = []
	for p in m["players"]:
		names.append("%s%s" % [p["name"], "（人类）" if p["human"] else ""])
	var when := str(m["saved_at"]).substr(5, 11).replace("T", " ")
	return "第 %d 天 · %s · %s · %s" % [int(m["day"]), m["map_name"], "、".join(names), when]


func _label(parent: Node, text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	parent.add_child(l)
	return l
