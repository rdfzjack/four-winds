extends Control
## 棋盘画面 + 热座：把 Game（规则）画出来，人类用按钮操作，AI 用 SimpleAI 自动走。
##
## 画面只做两件事：
##   1. 人类点按钮 → 调 Game 的方法（roll / buy / build ...）
##   2. 每次操作后把 game.drain_events() 里的事件按顺序播放（棋子一步步走、写日志、冒台词）
## 规则全在 scripts/core/game.gd，这里不改任何规则状态。

const Board = preload("res://scripts/core/board.gd")
const Game = preload("res://scripts/core/game.gd")
const SimpleAI = preload("res://scripts/core/simple_ai.gd")

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
const STATUS_NAMES := {
	"jail": "坐牢", "park": "游览公园", "charity": "慈善", "thief": "小偷", "arsonist": "纵火犯",
	"robber": "抢劫犯", "believer": "信徒", "free_rent": "免租", "double_rent": "租金加倍",
	"half_rent": "租金减半",
}
const PERMIT_NAMES := {"gang": "黑帮", "fortune_teller": "算命铺", "pawnshop": "当铺"}
## 骰子点数的位置（3×3 格子里的哪几格，从左上数 0-8）
const PIPS := {
	1: [4], 2: [0, 8], 3: [0, 4, 8], 4: [0, 2, 6, 8], 5: [0, 2, 4, 6, 8], 6: [0, 2, 3, 5, 6, 8],
}

const BACKGROUND := Color("#1e2a24")
const LEFT_WIDTH := 270.0
const RIGHT_WIDTH := 330.0
const MARGIN := 12.0
const AI_DELAY := 0.45
const STEP_DELAY := 0.13

var board: Board = null
var game: Game = null
var font: Font

var _specs: Array = []
var _token_tile: Array = []     ## 每个玩家的棋子画在哪一格（跟着事件一步步更新）
var _dice: Array = []
var _highlight: Array = []      ## 要高亮的格子（选方向、悬停在建房按钮上）
var _hover_highlight: Array = []
var _info_tile: int = -1
var _busy: bool = false
var _fast: bool = false
var _centers: Dictionary = {}
var _cell: float = 40.0

var _left: VBoxContainer
var _right: VBoxContainer
var _cards: Array = []          ## 每个玩家一张：{panel, label, bubble}
var _info_label: Label
var _head_label: Label
var _controls: VBoxContainer
var _log: RichTextLabel
var _overlay: Control
var _overlay_box: VBoxContainer


func _ready() -> void:
	font = get_theme_default_font()
	board = Data.default_map()
	_specs = Data.start_specs
	if _specs.is_empty():
		for i in range(mini(4, Data.characters.size())):
			_specs.append({"character": str(Data.characters[i]["id"]), "human": i == 0})
	game = Game.new()
	var cards_file := {"cards": Data.cards, "special_events": Data.special_events}
	var errors := game.setup(board, Data.rules, cards_file, Data.characters, _specs)
	if not errors.is_empty():
		push_error("开局失败：" + str(errors))
		return
	game.start()
	for p in game.players:
		_token_tile.append(p.pos)
	_build_ui()
	resized.connect(_on_resized)
	_on_resized()
	_refresh()
	_advance()


# ───────────────────────── 搭界面 ─────────────────────────

func _build_ui() -> void:
	_left = VBoxContainer.new()
	_left.add_theme_constant_override("separation", 6)
	add_child(_left)
	for p in game.players:
		_add_player_card(p)
	_info_label = _make_label(_left, "点棋盘上的格子看详情", 13, Color("#b0bec5"))
	_info_label.custom_minimum_size = Vector2(LEFT_WIDTH - 2.0 * MARGIN, 60)

	_right = VBoxContainer.new()
	_right.add_theme_constant_override("separation", 6)
	add_child(_right)
	var top := HBoxContainer.new()
	_right.add_child(top)
	_head_label = _make_label(top, "", 17, Color.WHITE)
	_head_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var fast := CheckButton.new()
	fast.text = "快速"
	fast.toggled.connect(func(on: bool) -> void: _fast = on)
	top.add_child(fast)
	var menu := Button.new()
	menu.text = "菜单"
	menu.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://scenes/main.tscn"))
	top.add_child(menu)

	_controls = VBoxContainer.new()
	_controls.add_theme_constant_override("separation", 6)
	_controls.custom_minimum_size = Vector2(0, 250)
	_right.add_child(_controls)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.add_theme_font_size_override("normal_font_size", 13)
	_right.add_child(_log)

	_overlay = ColorRect.new()
	(_overlay as ColorRect).color = Color(0, 0, 0, 0.6)
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.visible = false
	add_child(_overlay)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	_overlay_box = VBoxContainer.new()
	_overlay_box.custom_minimum_size = Vector2(560, 0)
	_overlay_box.add_theme_constant_override("separation", 6)
	panel.add_child(_overlay_box)


func _add_player_card(p) -> void:
	var ch: Dictionary = Data.character(p.character)
	var color := Color(str(ch.get("color", "#ffffff")))
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(LEFT_WIDTH - 2.0 * MARGIN, 0)
	_left.add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)
	var label := _make_label(box, "", 13, color.lightened(0.5))
	var bubble := _make_label(box, "", 12, Color("#fff59d"))
	_cards.append({"panel": panel, "label": label, "bubble": bubble, "color": color})


func _make_label(parent: Node, text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	parent.add_child(l)
	return l


func _on_resized() -> void:
	_left.position = Vector2(MARGIN, MARGIN)
	_left.size = Vector2(LEFT_WIDTH - 2.0 * MARGIN, size.y - 2.0 * MARGIN)
	_right.position = Vector2(size.x - RIGHT_WIDTH, MARGIN)
	_right.size = Vector2(RIGHT_WIDTH - MARGIN, size.y - 2.0 * MARGIN)
	_compute_layout()
	queue_redraw()


## 算出每格的中心和格子大小，让整张地图放进中间的区域
func _compute_layout() -> void:
	_centers.clear()
	if board == null or board.tile_count() == 0:
		return
	var min_p := Vector2(INF, INF)
	var max_p := Vector2(-INF, -INF)
	for t in board.tiles:
		var p := Vector2(t["pos"][0], t["pos"][1])
		min_p = min_p.min(p)
		max_p = max_p.max(p)
	var cols := max_p.x - min_p.x + 1.0
	var rows := max_p.y - min_p.y + 1.0
	var area := Rect2(LEFT_WIDTH, MARGIN, size.x - LEFT_WIDTH - RIGHT_WIDTH - 10.0,
			size.y - 2.0 * MARGIN)
	_cell = minf(area.size.x / cols, area.size.y / rows)
	var origin := area.position + (area.size - Vector2(cols, rows) * _cell) / 2.0
	for t in board.tiles:
		var gp := Vector2(t["pos"][0], t["pos"][1]) - min_p
		_centers[t["id"]] = origin + (gp + Vector2(0.5, 0.5)) * _cell


# ───────────────────────── 驱动游戏 ─────────────────────────

## 播放积压的事件；轮到 AI 就让 AI 走一步；一直做到需要人类操作或游戏结束。
func _advance() -> void:
	if _busy:
		return
	_busy = true
	_clear_controls()
	while true:
		await _play(game.drain_events())
		_sync_tokens()
		_refresh()
		if game.phase == "over":
			break
		if game.player().human:
			break
		await _wait(AI_DELAY)
		if not SimpleAI.step(game):
			break
	_busy = false
	if game.phase == "over":
		_show_game_over()
	else:
		_show_controls()


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds * (0.15 if _fast else 1.0)).timeout


func _play(events: Array) -> void:
	for ev in events:
		var delay := _handle_event(ev)
		_refresh()
		queue_redraw()
		if delay > 0.0:
			await _wait(delay)


## 人类操作后立刻把事件记进日志（不播动画，建房对话框用）
func _flush_events() -> void:
	for ev in game.drain_events():
		_handle_event(ev)
	_sync_tokens()
	_refresh()
	queue_redraw()


func _sync_tokens() -> void:
	for p in game.players:
		_token_tile[p.index] = p.pos
	queue_redraw()


# ───────────────────────── 事件 → 日志 / 台词 / 动画 ─────────────────────────

## 处理一个事件：更新画面状态、写日志、冒台词。返回播放完要停多久（秒）。
func _handle_event(ev: Dictionary) -> float:
	var type := str(ev["type"])
	match type:
		"step":
			_token_tile[int(ev["player"])] = int(ev["tile"])
			return STEP_DELAY
		"teleport":
			_token_tile[int(ev["player"])] = int(ev["tile"])
		"jailed":
			_token_tile[int(ev["player"])] = game.players[int(ev["player"])].pos
		"rolled":
			_dice = ev["dice"]
		"turn_start":
			_dice = []
	var text := _describe(ev)
	if text != "":
		_log.append_text(text + "\n")
	_speak(ev)
	return _delay_for(type)


func _delay_for(type: String) -> float:
	match type:
		"turn_start", "status_end", "deposit", "withdraw", "declined", "random_direction":
			return 0.15
		"rolled":
			return 0.7
		"card", "bankrupt", "game_over":
			return 1.2
		_:
			return 0.6


func _pname(i: int) -> String:
	var c: Color = _cards[i]["color"]
	return "[color=#%s]%s[/color]" % [c.lightened(0.35).to_html(false), game.players[i].display_name]


func _tname(i: int) -> String:
	var t: Dictionary = board.get_tile(i)
	return str(t.get("name", TYPE_NAMES.get(str(t["type"]), "")))


func _house_name(kind: String) -> String:
	for lv in Data.rules["houses"]["levels"]:
		if str(lv["id"]) == kind:
			return str(lv["name"])
	return kind


# gdlint: disable=max-returns
func _describe(ev: Dictionary) -> String:
	var pi := int(ev.get("player", -1))
	match str(ev["type"]):
		"turn_start":
			return "[color=#90a4ae]── 第 %d 天 · %s 的回合 ──[/color]" % [int(ev["day"]), _pname(pi)]
		"rolled":
			var parts: Array = []
			for d in ev["dice"]:
				parts.append(str(int(d)))
			return "%s 掷出 %s = %d 步" % [_pname(pi), " + ".join(parts), int(ev["steps"])]
		"random_direction":
			return "%s 在路口被带向 %s" % [_pname(pi), _tname(int(ev["tile"]))]
		"stolen":
			return "%s 偷走了 %s 的 %d 万" % [_pname(int(ev["thief"])), _pname(int(ev["victim"])),
					int(ev["amount"])]
		"alms":
			return "%s 施舍给 %s %d 万" % [_pname(int(ev["giver"])), _pname(int(ev["receiver"])),
					int(ev["amount"])]
		"donation":
			return "%s 向教堂捐了 %d 万" % [_pname(pi), int(ev["amount"])]
		"deposit":
			return "%s 存入银行 %d 万" % [_pname(pi), int(ev["amount"])]
		"withdraw":
			return "%s 从银行取出 %d 万" % [_pname(pi), int(ev["amount"])]
		"tax":
			return "%s 缴税 %d 万" % [_pname(pi), int(ev["amount"])]
		"permit":
			return "%s 在市政厅领到特许证：%s（暂时还不能建）" % [_pname(pi),
					PERMIT_NAMES.get(str(ev["permit"]), str(ev["permit"]))]
		"race":
			return "%s 在赛马场得了第 %d 名，奖金 %d 万" % [_pname(pi), int(ev["rank"]), int(ev["prize"])]
		"arson":
			return "%s 放火烧了 %s 的房子" % [_pname(pi), _pname(int(ev["owner"]))]
		"robbed":
			return "%s 抢走了 %s 的 %s" % [_pname(pi), _pname(int(ev["from"])), _tname(int(ev["tile"]))]
		"cannot_afford":
			return "%s 买不起 %s（要 %d 万）" % [_pname(pi), _tname(int(ev["tile"])), int(ev["price"])]
		"rent_waived":
			var why := {
				"mortgaged": "地在抵押中", "jail": "主人在坐牢", "park": "主人在游览",
				"charity": "主人在做慈善", "free_rent": "自己有免租状态",
			}
			return "%s 在 %s 免付租金（%s）" % [_pname(pi), _tname(int(ev["tile"])),
					why.get(str(ev["reason"]), str(ev["reason"]))]
		"rent":
			return "%s 在 %s 付给 %s 租金 %d 万" % [_pname(pi), _tname(int(ev["tile"])),
					_pname(int(ev["owner"])), int(ev["amount"])]
		"bought":
			return "%s 买下 %s，花了 %d 万" % [_pname(pi), _tname(int(ev["tile"])), int(ev["price"])]
		"declined":
			return "%s 没有买 %s" % [_pname(pi), _tname(int(ev["tile"]))]
		"bail_paid":
			return "%s 交了 %d 万保释金" % [_pname(pi), int(ev["amount"])]
		"jailed":
			return "%s 被关进巡捕房 %d 天" % [_pname(pi), int(ev["days"])]
		"card":
			return "%s 抽到运气牌：%s" % [_pname(pi), str(ev["text"])]
		"teleport":
			return "%s 被送到 %s" % [_pname(pi), _tname(int(ev["tile"]))]
		"confiscated":
			return "%s 的 %s 被没收了" % [_pname(pi), _tname(int(ev["tile"]))]
		"house_smashed":
			return "%s 的一栋房子被砸了" % _pname(pi)
		"built":
			return "%s 建成%s，花了 %d 万" % [_pname(pi), _house_name(str(ev["kind"])), int(ev["cost"])]
		"antique":
			return "%s 挖到古董，得 %d 万" % [_pname(pi), int(ev["amount"])]
		"collapse":
			return "%s 刚盖的房子倒塌了！" % _pname(pi)
		"upgraded":
			return "%s 的房子升级成%s" % [_pname(pi), _house_name(str(ev["kind"]))]
		"removed":
			return "%s 拆了房子，退回 %d 万" % [_pname(pi), int(ev["refund"])]
		"bankrupt":
			return "[color=#ef5350]%s 破产了！[/color]" % _pname(pi)
		"game_over":
			if int(ev["winner"]) >= 0:
				return "[color=#ffd54f]游戏结束，%s 获胜！[/color]" % _pname(int(ev["winner"]))
			return "[color=#ffd54f]游戏结束[/color]"
		"status":
			return "%s 进入状态：%s" % [_pname(pi), STATUS_NAMES.get(str(ev["kind"]), str(ev["kind"]))]
		"skip_turn":
			return "%s 这回合不能动（%s）" % [_pname(pi), STATUS_NAMES.get(str(ev["reason"]), "")]
		"status_end":
			return "%s 的状态结束：%s" % [_pname(pi), STATUS_NAMES.get(str(ev["kind"]), "")]
		"payday":
			return "%s 领到银行利息 %d 万" % [_pname(pi), int(ev["amount"])]
		_:
			return ""


# gdlint: enable=max-returns


## 按事件挑一句台词（台词表见 data/lines/speech.json）
func _speak(ev: Dictionary) -> void:
	var who := -1
	var cond := ""
	match str(ev["type"]):
		"rent":
			who = int(ev["player"])
			cond = {"big": "GIVE_MUCH_MONEY", "small": "GIVE_LITTLE_MONEY"}.get(str(ev["scale"]), "")
		"jailed":
			who = int(ev["player"])
			cond = "TO_JAIL"
		"built":
			if str(ev["kind"]) == "villa":
				who = int(ev["player"])
				cond = "BUILD_VILLA"
		"antique":
			who = int(ev["player"])
			cond = "GOOD_LUCK"
		"collapse":
			who = int(ev["player"])
			cond = "BAD_LUCK"
		"stolen":
			_say(int(ev["victim"]), "BEEN_STOLEN")
			who = int(ev["thief"])
			cond = "STEAL"
		"alms":
			who = int(ev["receiver"])
			cond = "GET_CHARITY"
		"card":
			who = int(ev["player"])
			cond = _card_mood(int(ev["card"]))
	if who >= 0 and cond != "":
		_say(who, cond)


## 机会卡带来的钱是正还是负 → 好运 / 倒霉；没有金额的卡不说话
func _card_mood(card_id: int) -> String:
	for c in Data.cards:
		if int(c["id"]) != card_id:
			continue
		for e in c.get("effects", []):
			if str(e["op"]) == "money":
				return "GOOD_LUCK" if int(e["amount"]) > 0 else "BAD_LUCK"
	return ""


func _say(pi: int, cond: String) -> void:
	var line := Data.random_line(game.players[pi].character, cond)
	if line == "":
		return
	_cards[pi]["bubble"].text = "“%s”" % line
	_log.append_text("    [i]%s：“%s”[/i]\n" % [_pname(pi), line])


# ───────────────────────── 左边：玩家卡片 ─────────────────────────

func _refresh() -> void:
	if game == null:
		return
	for p in game.players:
		var card: Dictionary = _cards[p.index]
		var lands := 0
		var company := 0
		for tile in game.props:
			if game.owner_of(tile) == p.index:
				if str(board.get_tile(tile)["type"]) == "company":
					company += 1
				else:
					lands += 1
		var text := "%s（%s）%s\n现金 %d · 存款 %d\n总资产 %d · 地 %d · 企业 %d" % [
			p.display_name, Data.character(p.character).get("name", ""),
			"  ◀ 轮到" if p.index == game.current and game.phase != "over" else "",
			p.cash, p.deposit, game.total_assets(p.index), lands, company,
		]
		if p.bankrupt:
			text = "%s —— 已破产" % p.display_name
		elif p.status_kind() != "":
			var days := int(p.status.get("days", 0))
			text += "\n状态：%s%s" % [STATUS_NAMES.get(p.status_kind(), p.status_kind()),
					"" if days <= 0 else "（剩 %d 天）" % days]
		card["label"].text = text
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.2, 0.28, 0.24) if p.index == game.current else Color(0.14, 0.19, 0.17)
		style.border_color = card["color"]
		style.set_border_width_all(3 if p.index == game.current else 1)
		style.set_content_margin_all(6)
		card["panel"].add_theme_stylebox_override("panel", style)
	_head_label.text = "第 %d 天 · %s" % [game.day, game.player().display_name]


# ───────────────────────── 右边：操作区 ─────────────────────────

func _clear_controls() -> void:
	_highlight = []
	for c in _controls.get_children():
		c.queue_free()
	queue_redraw()


func _button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 36)
	b.pressed.connect(on_press)
	_controls.add_child(b)
	return b


func _show_controls() -> void:
	_clear_controls()
	if game.phase == "over" or not game.player().human:
		return
	var p = game.player()
	_make_label(_controls, "轮到 %s（现金 %d · 存款 %d）" % [p.display_name, p.cash, p.deposit], 14,
			Color.WHITE)
	if game.phase == "pre_roll":
		_button("掷骰子", _on_roll)
		_button("房产：建房 / 升级 / 拆房", _open_house_dialog)
		return
	match str(game.pending["type"]):
		"choose_direction":
			_make_label(_controls, "前面是十字路口，往哪边走？", 14, Color("#fff59d"))
			_highlight = game.pending["options"].duplicate()
			for tile in game.pending["options"]:
				var t: int = tile
				_button("往 %s" % _tname(t), func() -> void: _do(func() -> void:
						game.choose_direction(t)))
		"bank":
			_show_bank_controls(p)
		"buy_land", "buy_company":
			var tile: int = game.pending["tile"]
			var price: int = game.pending["price"]
			_make_label(_controls, "%s 还没有主人，%d 万。买吗？" % [_tname(tile), price], 14,
					Color("#fff59d"))
			_button("买下（%d 万）" % price, func() -> void: _do(game.buy))
			_button("不买", func() -> void: _do(game.decline))
		"bail":
			var amount: int = game.pending["amount"]
			_make_label(_controls, "你被抓进巡捕房！交 %d 万保释金，还是坐牢？" % amount, 14,
					Color("#fff59d"))
			_button("交保释金（%d 万）" % amount, func() -> void: _do(func() -> void: game.bail(true)))
			_button("坐牢", func() -> void: _do(func() -> void: game.bail(false)))
	queue_redraw()


func _show_bank_controls(p) -> void:
	_make_label(_controls, "路过银行：现金 %d · 存款 %d。存取款？" % [p.cash, p.deposit], 14,
			Color("#fff59d"))
	var row := HBoxContainer.new()
	_controls.add_child(row)
	for amount in [100, 500]:
		var a: int = amount
		var b := Button.new()
		b.text = "存 %d" % a
		b.disabled = p.cash < a
		b.pressed.connect(func() -> void: _bank_act(func() -> void: game.bank_deposit(a)))
		row.add_child(b)
	var all_in := Button.new()
	all_in.text = "存入全部现金"
	all_in.disabled = p.cash <= 0
	all_in.pressed.connect(func() -> void: _bank_act(func() -> void:
			game.bank_deposit(game.player().cash)))
	row.add_child(all_in)
	var row2 := HBoxContainer.new()
	_controls.add_child(row2)
	for amount in [100, 500]:
		var a: int = amount
		var b := Button.new()
		b.text = "取 %d" % a
		b.disabled = p.deposit < a
		b.pressed.connect(func() -> void: _bank_act(func() -> void: game.bank_withdraw(a)))
		row2.add_child(b)
	var all_out := Button.new()
	all_out.text = "取出全部存款"
	all_out.disabled = p.deposit <= 0
	all_out.pressed.connect(func() -> void: _bank_act(func() -> void:
			game.bank_withdraw(game.player().deposit)))
	row2.add_child(all_out)
	_button("完成，继续走", func() -> void: _do(game.bank_done))


## 存取款后留在银行：只刷新日志和按钮，不往下走
func _bank_act(action: Callable) -> void:
	action.call()
	_flush_events()
	_show_controls()


func _on_roll() -> void:
	_do(game.roll)


## 人类做一个会推进游戏的操作，然后接着播放、轮到 AI 就让 AI 走
func _do(action: Callable) -> void:
	if _busy:
		return
	action.call()
	_advance()


# ───────────────────────── 房产对话框 ─────────────────────────

func _open_house_dialog() -> void:
	_overlay.visible = true
	_rebuild_house_dialog("")


func _close_overlay() -> void:
	_overlay.visible = false
	_hover_highlight = []
	queue_redraw()
	if game.phase != "over":
		_show_controls()


func _clear_overlay_box() -> void:
	for c in _overlay_box.get_children():
		c.queue_free()


func _rebuild_house_dialog(message: String) -> void:
	_clear_overlay_box()
	_hover_highlight = []
	var p = game.player()
	_make_label(_overlay_box, "房产 · %s · 现金 %d 万（建房只能用现金）" % [p.display_name, p.cash], 18,
			Color.WHITE)
	if message != "":
		_make_label(_overlay_box, message, 14, Color("#ef9a9a"))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 380)
	_overlay_box.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	var options: Array = game.build_options(p.index)
	_section(list, "可以建的房子（%d）" % options.size())
	for o in options:
		var tiles: Array = o["tiles"]
		var text := "建%s · %s · 造价 %d" % [_house_name(str(o["kind"])), _tiles_text(tiles), int(o["cost"])]
		_dialog_button(list, text, tiles, func() -> void:
				_house_action(game.build(p.index, str(o["kind"]), tiles)))

	var upgradable: Array = []
	var mine: Array = []
	for hid in game.houses:
		var h: Dictionary = game.houses[hid]
		if h["owner"] != p.index:
			continue
		mine.append(hid)
		if game.why_cannot_upgrade(p.index, hid) == "":
			upgradable.append(hid)
	_section(list, "可以升级的房子（%d）" % upgradable.size())
	for hid in upgradable:
		var h: Dictionary = game.houses[hid]
		var id: int = hid
		var text := "%s 升级 · %s · 费用 %d" % [_house_name(str(h["kind"])), _tiles_text(h["tiles"]),
				game.upgrade_fee(h["tiles"])]
		_dialog_button(list, text, h["tiles"], func() -> void:
				_house_action(game.upgrade(p.index, id)))

	_section(list, "拆房（退还造价的一半）")
	for hid in mine:
		var h: Dictionary = game.houses[hid]
		var id: int = hid
		var refund := Game.pct_of(game.house_cost(str(h["kind"]), h["tiles"]),
				int(Data.rules["houses"]["remove_refund_pct"]))
		var text := "拆除 %s · %s · 退还 %d" % [_house_name(str(h["kind"])), _tiles_text(h["tiles"]), refund]
		_dialog_button(list, text, h["tiles"], func() -> void:
				_house_action(game.remove_house(p.index, id)))
	if mine.is_empty():
		_make_label(list, "（你还没有房子）", 13, Color("#90a4ae"))

	var close := Button.new()
	close.text = "关闭"
	close.custom_minimum_size = Vector2(0, 40)
	close.pressed.connect(_close_overlay)
	_overlay_box.add_child(close)


func _section(parent: Node, title: String) -> void:
	_make_label(parent, title, 15, Color("#ffd54f"))


func _tiles_text(tiles: Array) -> String:
	if tiles.size() == 1:
		return _tname(int(tiles[0]))
	return "%s ~ %s" % [_tname(int(tiles[0])), _tname(int(tiles[tiles.size() - 1]))]


func _dialog_button(parent: Node, text: String, tiles: Array, on_press: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.pressed.connect(on_press)
	b.mouse_entered.connect(func() -> void:
		_hover_highlight = tiles
		queue_redraw())
	b.mouse_exited.connect(func() -> void:
		_hover_highlight = []
		queue_redraw())
	parent.add_child(b)


func _house_action(error: String) -> void:
	_flush_events()
	_rebuild_house_dialog(error)


# ───────────────────────── 游戏结束 ─────────────────────────

func _show_game_over() -> void:
	_overlay.visible = true
	_clear_overlay_box()
	var text := "游戏结束：所有人类玩家都破产了"
	if game.winner >= 0:
		text = "游戏结束：%s 获胜！" % game.players[game.winner].display_name
	_make_label(_overlay_box, text, 24, Color("#ffd54f"))
	for p in game.players:
		_make_label(_overlay_box, "%s：总资产 %d%s" % [p.display_name, game.total_assets(p.index),
				"（破产）" if p.bankrupt else ""], 16, Color.WHITE)
	var again := Button.new()
	again.text = "回到主菜单"
	again.custom_minimum_size = Vector2(0, 44)
	again.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://scenes/main.tscn"))
	_overlay_box.add_child(again)
	var view := Button.new()
	view.text = "看看棋盘"
	view.pressed.connect(func() -> void: _overlay.visible = false)
	_overlay_box.add_child(view)


# ───────────────────────── 点格子看详情 ─────────────────────────

func _gui_input(event: InputEvent) -> void:
	var click := event as InputEventMouseButton
	if click == null or not click.pressed or click.button_index != MOUSE_BUTTON_LEFT:
		return
	_info_tile = -1
	for id in _centers:
		var c: Vector2 = _centers[id]
		if absf(click.position.x - c.x) < _cell / 2.0 and absf(click.position.y - c.y) < _cell / 2.0:
			_info_tile = int(id)
	_info_label.text = _tile_info(_info_tile)
	queue_redraw()


func _tile_info(i: int) -> String:
	if i < 0:
		return "点棋盘上的格子看详情"
	var t: Dictionary = board.get_tile(i)
	var text := "%s（%s）" % [_tname(i), TYPE_NAMES.get(str(t["type"]), "")]
	if not game.props.has(i):
		return text
	text += "\n价格 %d 万 · 现在的租金 %d 万" % [game.property_price(i), game.rent_of(i)]
	var o := game.owner_of(i)
	text += "\n主人：%s" % (game.players[o].display_name if o >= 0 else "无")
	var hid := game.house_at(i)
	if hid != 0:
		text += " · %s" % _house_name(str(game.houses[hid]["kind"]))
	return text


# ───────────────────────── 画棋盘 ─────────────────────────

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BACKGROUND)
	if board == null or game == null or _centers.is_empty():
		return
	for t in board.tiles:
		for nx in t["next"]:
			_draw_arrow(_centers[t["id"]], _centers[nx])
	var pad := _cell * 0.05
	var font_size := int(clampf(_cell * 0.17, 9.0, 15.0))
	for t in board.tiles:
		_draw_tile(t, pad, font_size)
	for i in _highlight + _hover_highlight + [_info_tile]:
		if int(i) >= 0:
			var r := _tile_rect(int(i), pad)
			draw_rect(r, Color("#fff176"), false, 4.0)
	_draw_tokens()
	_draw_dice()


func _tile_rect(id: int, pad: float) -> Rect2:
	var c: Vector2 = _centers[id]
	return Rect2(c - Vector2(_cell, _cell) / 2.0 + Vector2(pad, pad),
			Vector2(_cell, _cell) - Vector2(pad, pad) * 2.0)


func _draw_tile(t: Dictionary, pad: float, font_size: int) -> void:
	var id: int = t["id"]
	var c: Vector2 = _centers[id]
	var rect := _tile_rect(id, pad)
	var tile_type := str(t["type"])
	draw_rect(rect, TYPE_COLORS.get(tile_type, Color.MAGENTA))
	if tile_type == "land":
		var g: Dictionary = board.groups.get(str(t.get("group", "")), {})
		draw_rect(Rect2(rect.position, Vector2(rect.size.x, rect.size.y * 0.2)),
				Color(str(g.get("color", "#ffffff"))))
	var name_text := str(t.get("name", TYPE_NAMES.get(tile_type, tile_type)))
	_draw_centered_text(name_text, c + Vector2(0, -_cell * 0.04), rect.size.x - 4.0, font_size)
	if game.props.has(id):
		var sub := "%d" % game.property_price(id) if game.owner_of(id) < 0 else "租 %d" % game.rent_of(id)
		_draw_centered_text(sub, c + Vector2(0, _cell * 0.2), rect.size.x - 4.0,
				maxi(font_size - 2, 8), Color(0, 0, 0, 0.7))
		var o := game.owner_of(id)
		if o >= 0:
			draw_rect(rect, _cards[o]["color"], false, 3.0)
		var hid := game.house_at(id)
		if hid != 0:
			var strip := Rect2(rect.position + Vector2(0, rect.size.y * 0.72),
					Vector2(rect.size.x, rect.size.y * 0.28))
			draw_rect(strip, _cards[o]["color"])
			_draw_centered_text(_house_name(str(game.houses[hid]["kind"])),
					strip.position + Vector2(strip.size.x / 2.0, strip.size.y * 0.78),
					rect.size.x - 2.0, maxi(font_size - 2, 8), Color.WHITE)
	if board.is_crossroad(id):
		draw_rect(rect.grow(-1.0), Color("#ffeb3b"), false, 1.5)


func _draw_tokens() -> void:
	var slots := {}
	for p in game.players:
		if p.bankrupt:
			continue
		var tile: int = _token_tile[p.index]
		var n := int(slots.get(tile, 0))
		slots[tile] = n + 1
		var offset := Vector2((n % 2) * 2 - 1, (n >> 1) * 2 - 1) * _cell * 0.17
		var pos: Vector2 = _centers[tile] + offset
		var r := _cell * 0.12
		draw_circle(pos, r, _cards[p.index]["color"])
		draw_arc(pos, r, 0.0, TAU, 24, Color.WHITE if p.index == game.current else Color.BLACK, 2.0)


func _draw_dice() -> void:
	if _dice.is_empty():
		return
	var area := Rect2(LEFT_WIDTH, 0, size.x - LEFT_WIDTH - RIGHT_WIDTH, size.y)
	var d := _cell * 1.1
	var total := _dice.size() * d + (_dice.size() - 1) * d * 0.3
	var x := area.get_center().x - total / 2.0
	for v in _dice:
		_draw_die(Vector2(x, area.get_center().y - d / 2.0), d, int(v))
		x += d * 1.3


func _draw_die(top_left: Vector2, d: float, value: int) -> void:
	draw_rect(Rect2(top_left, Vector2(d, d)), Color.WHITE)
	draw_rect(Rect2(top_left, Vector2(d, d)), Color.BLACK, false, 2.0)
	for k in PIPS.get(value, []):
		var cx := top_left.x + d * (0.2 + 0.3 * (int(k) % 3))
		var cy := top_left.y + d * (0.2 + 0.3 * (int(k) / 3))
		draw_circle(Vector2(cx, cy), d * 0.07, Color.BLACK)


func _draw_arrow(from: Vector2, to: Vector2) -> void:
	var dir := to - from
	if dir.length() < 1.0:
		return
	dir = dir.normalized()
	var color := Color(1, 1, 1, 0.3)
	var a := from + dir * _cell * 0.42
	var b := to - dir * _cell * 0.42
	draw_line(a, b, color, 2.0)
	var side := Vector2(-dir.y, dir.x)
	var head := _cell * 0.08
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
