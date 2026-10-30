# gdlint: disable=max-file-lines
extends Node
## 棋盘画面 + 热座：把 Game（规则）画出来，人类用按钮操作，AI 用 AI.step（现在是原版 AI）自动走。
##
## 画面分两层：
##   - 地图层（map_view.gd，跟着 map_camera.gd 的镜头移动）：格子、房子、棋子
##   - 界面层（CanvasLayer，钉在屏幕上）：玩家卡片、按钮、日志、骰子、对话框
## 新界面（拍卖、交易、剧情对话、立绘）都加在界面层 _ui 下面（拍卖、交易现在是右边的按钮 + 对话框）。
##
## 这个脚本做三件事：
##   1. 人类点按钮 → 调 Game 的方法（roll / buy / build ...）
##   2. 每次操作后把 game.drain_events() 里的事件按顺序播放（棋子一步步走、写日志、冒台词）
##   3. 告诉地图层要高亮什么、棋子到哪了、镜头跟谁
## 规则全在 scripts/core/game.gd，这里不改任何规则状态。

const Board = preload("res://scripts/core/board.gd")
const Game = preload("res://scripts/core/game.gd")
const AI = preload("res://scripts/core/ai.gd")
const MapView = preload("res://scripts/ui/map_view.gd")
const MapCamera = preload("res://scripts/ui/map_camera.gd")
const DiceView = preload("res://scripts/ui/dice_view.gd")

const STATUS_NAMES := {
	"jail": "坐牢", "park": "游览公园", "charity": "慈善", "thief": "小偷", "arsonist": "纵火犯",
	"robber": "抢劫犯", "believer": "信徒", "free_rent": "免租", "double_rent": "租金加倍",
	"half_rent": "租金减半",
}
const PERMIT_NAMES := {"gang": "黑帮", "fortune_teller": "算命铺", "pawnshop": "当铺"}

const BACKGROUND := Color("#1e2a24")
const PANEL_COLOR := Color(0.1, 0.14, 0.12, 0.92)
const LEFT_WIDTH := 270.0
const RIGHT_WIDTH := 330.0
const MARGIN := 12.0
const AI_DELAY := 0.45
const STEP_DELAY := 0.13

var board: Board = null
var game: Game = null

var _specs: Array = []
var _busy: bool = false
var _fast: bool = false

var _map: MapView
var _camera: MapCamera
var _ui: Control                ## 界面层的根，所有 HUD 控件放在它下面
var _dice: DiceView
var _left: VBoxContainer
var _right: VBoxContainer
var _left_panel: PanelContainer
var _right_panel: PanelContainer
var _cards: Array = []          ## 每个玩家一张：{panel, label, bubble}
var _info_label: Label
var _head_label: Label
var _controls: VBoxContainer
var _log: RichTextLabel
var _overlay: Control
var _overlay_box: VBoxContainer
## 交易对话框的草稿：offer 的各项（give / get 是地块列表）+ counter（是不是还价）
var _trade: Dictionary = {}


func _ready() -> void:
	RenderingServer.set_default_clear_color(BACKGROUND)
	board = Data.selected_map()
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
	_build_map()
	_build_ui()
	get_viewport().size_changed.connect(_on_resized)
	_on_resized()
	_camera.focus(_map.token_position(game.current), true)
	_refresh()
	_advance()


# ───────────────────────── 搭画面 ─────────────────────────

func _build_map() -> void:
	var colors: Array = []
	for p in game.players:
		colors.append(Color(str(Data.character(p.character).get("color", "#ffffff"))))
	_map = MapView.new()
	add_child(_map)
	_camera = MapCamera.new()
	_map.camera = _camera
	add_child(_camera)
	_camera.make_current()
	_map.setup(board, game, colors)
	_camera.bounds = _map.world_bounds()
	_map.tile_clicked.connect(_on_tile_clicked)


## 左右两栏的底板（挡住鼠标，点在上面不会点到地图）
func _panel(child: Control) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_COLOR
	style.set_content_margin_all(MARGIN / 2.0)
	panel.add_theme_stylebox_override("panel", style)
	panel.add_child(child)
	_ui.add_child(panel)
	return panel


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_ui = Control.new()
	_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_ui)

	_left = VBoxContainer.new()
	_left.add_theme_constant_override("separation", 6)
	_left_panel = _panel(_left)
	for p in game.players:
		_add_player_card(p)
	_info_label = _make_label(_left, "点棋盘上的格子看详情", 13, Color("#b0bec5"))
	_info_label.custom_minimum_size = Vector2(LEFT_WIDTH - 2.0 * MARGIN, 60)

	_right = VBoxContainer.new()
	_right.add_theme_constant_override("separation", 6)
	_right_panel = _panel(_right)
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
	var home := Button.new()
	home.text = "回到当前角色"
	home.tooltip_text = "镜头回到当前玩家（拖动地图、方向键 / WASD 平移，滚轮缩放）"
	home.pressed.connect(func() -> void: _camera.focus(_map.token_position(game.current)))
	_right.add_child(home)

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
	_ui.add_child(_overlay)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	_overlay_box = VBoxContainer.new()
	_overlay_box.custom_minimum_size = Vector2(560, 0)
	_overlay_box.add_theme_constant_override("separation", 6)
	panel.add_child(_overlay_box)

	_dice = DiceView.new()
	_ui.add_child(_dice)
	_ui.move_child(_dice, 0)


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
	var view := get_viewport().get_visible_rect().size
	_left_panel.position = Vector2(MARGIN, MARGIN)
	_left_panel.size = Vector2(LEFT_WIDTH - 2.0 * MARGIN, view.y - 2.0 * MARGIN)
	_right_panel.position = Vector2(view.x - RIGHT_WIDTH, MARGIN)
	_right_panel.size = Vector2(RIGHT_WIDTH - MARGIN, view.y - 2.0 * MARGIN)
	_dice.position = Vector2(LEFT_WIDTH, MARGIN)
	_dice.size = Vector2(view.x - LEFT_WIDTH - RIGHT_WIDTH, DiceView.SIZE.y)
	# 镜头对准左右两栏之间空出来的那块
	_camera.view_shift = Vector2((LEFT_WIDTH - RIGHT_WIDTH) / 2.0, 0.0)


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
		if game.players[game.actor()].human:
			break
		await _wait(AI_DELAY)
		if not AI.step(game):
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
		_map.queue_redraw()
		if delay > 0.0:
			await _wait(delay)


## 人类操作后立刻把事件记进日志（不播动画，建房对话框用）
func _flush_events() -> void:
	for ev in game.drain_events():
		_handle_event(ev)
	_sync_tokens()
	_refresh()
	_map.queue_redraw()


func _sync_tokens() -> void:
	_map.sync_tokens()


# ───────────────────────── 事件 → 日志 / 台词 / 动画 ─────────────────────────

## 处理一个事件：更新画面状态、写日志、冒台词。返回播放完要停多久（秒）。
func _handle_event(ev: Dictionary) -> float:
	var type := str(ev["type"])
	match type:
		"step":
			_move_token(int(ev["player"]), int(ev["tile"]))
			return STEP_DELAY
		"teleport":
			_move_token(int(ev["player"]), int(ev["tile"]))
		"jailed":
			_move_token(int(ev["player"]), game.players[int(ev["player"])].pos)
		"rolled":
			_dice.values = ev["dice"]
		"turn_start":
			_dice.values = []
			_camera.focus(_map.token_position(int(ev["player"])))
	var text := _describe(ev)
	if text != "":
		_log.append_text(text + "\n")
	_speak(ev)
	return _delay_for(type)


## 棋子挪一格，镜头跟着（玩家手动拖过镜头就不跟，见 map_camera.gd）
func _move_token(player: int, tile: int) -> void:
	_map.move_token(player, tile)
	_camera.follow(_map.token_position(player))


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
	var t: Dictionary = board.get_tile(board.site(i))  # 分身格用它代表的那块地 / 建筑的名字
	return str(t.get("name", MapView.TYPE_NAMES.get(str(t["type"]), "")))


func _house_name(kind: String) -> String:
	return _map.house_name(kind)


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
			return "%s %s%s，花了 %d 万" % [_pname(pi), "改建成" if ev.get("rebuild", false) else "建成",
					_house_name(str(ev["kind"])), int(ev["cost"])]
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
		"mortgaged":
			if ev["seized"]:
				return "%s 抵押了 %s，银行强行扣留应付款项，一分没拿到！" % [_pname(pi), _tname(int(ev["tile"]))]
			return "%s 抵押了 %s，得 %d 万" % [_pname(pi), _tname(int(ev["tile"])), int(ev["amount"])]
		"unmortgaged":
			return "%s 赎回了 %s，付 %d 万" % [_pname(pi), _tname(int(ev["tile"])), int(ev["cost"])]
		"auction_start":
			return "%s 拍卖 %s，起拍价 %d 万" % [_pname(pi), _tname(int(ev["tile"])), int(ev["price"])]
		"auction_bid":
			return "%s 出价 %d 万" % [_pname(pi), int(ev["price"])]
		"auction_pass":
			return "%s 不再出价%s" % [_pname(pi), "（现金不够）" if ev.get("auto", false) else ""]
		"auction_sold":
			return "%s 以 %d 万拍下 %s" % [_pname(pi), int(ev["price"]), _tname(int(ev["tile"]))]
		"auction_government":
			return "没人出价，政府按起拍价 %d 万收回 %s" % [int(ev["price"]), _tname(int(ev["tile"]))]
		"trade_proposed":
			return "%s 提议交易：%s" % [_pname(pi), _offer_text(ev["offer"])]
		"trade_countered":
			return "%s 还价：%s" % [_pname(pi), _offer_text(ev["offer"])]
		"trade_done":
			return "交易成交：%s" % _offer_text(ev["offer"])
		"trade_rejected":
			return "%s 拒绝了交易" % _pname(pi)
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
		"trade_done":
			who = int(ev["offer"]["from"])
			cond = "TRADE_OK"
		"trade_rejected":
			# 被拒的一方说话：对方拒绝了发起人的提议，或发起人拒绝了还价
			var o: Dictionary = ev["offer"]
			who = int(o["from"]) if int(ev["player"]) == int(o["to"]) else int(o["to"])
			cond = "TRADE_NOT_OK"
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
	_map.highlight = []
	_map.routes = []
	for c in _controls.get_children():
		c.queue_free()
	_map.queue_redraw()


func _button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 36)
	b.pressed.connect(on_press)
	_controls.add_child(b)
	return b


func _show_controls() -> void:
	_clear_controls()
	if game.phase == "over" or not game.players[game.actor()].human:
		return
	var p = game.players[game.actor()]
	_make_label(_controls, "轮到 %s（现金 %d · 存款 %d）" % [p.display_name, p.cash, p.deposit], 14,
			Color.WHITE)
	if game.phase == "pre_roll":
		_button("掷骰子", _on_roll)
		_button("房产：建房 / 升级 / 拆房", _open_house_dialog)
		_button("抵押 / 赎回", _open_mortgage_dialog)
		_button("拍卖", _open_auction_dialog)
		_button("交易", func() -> void: _open_trade_dialog({}))
		return
	match str(game.pending["type"]):
		"choose_direction":
			_make_label(_controls, "前面是十字路口，点地图上的路或这里的按钮选方向", 14, Color("#fff59d"))
			_map.highlight = game.pending["options"].duplicate()
			_map.routes = game.direction_routes()
			for i in _map.routes.size():
				var r: Dictionary = _map.routes[i]
				var t: int = r["option"]
				var last: int = r["tiles"][-1]
				var where := "落在 %s" % _tname(last) if r["ends"] else "走到 %s 的路口再选" % _tname(last)
				var b := _button(where, func() -> void: _do(func() -> void: game.choose_direction(t)))
				b.modulate = MapView.ROUTE_COLORS[i % MapView.ROUTE_COLORS.size()]
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
		"auction":
			_show_auction_controls(p)
		"trade":
			_show_trade_controls()
	_map.queue_redraw()


func _show_auction_controls(p) -> void:
	var a: Dictionary = game.pending
	var top := int(a["top"])
	_make_label(_controls, "%s 拍卖 %s（价格 %d）\n现价 %d 万%s" % [
		game.players[int(a["seller"])].display_name, _tname(int(a["tile"])),
		game.property_price(int(a["tile"])), int(a["price"]),
		"，%s 出的" % game.players[top].display_name if top >= 0 else "（起拍价，还没人出价）"],
		14, Color("#fff59d"))
	_map.highlight = [int(a["tile"])]
	for step in game.bid_steps():
		var s: int = step
		var b := _button("加 %d（出 %d 万）" % [s, int(a["price"]) + s], func() -> void: _do(func() -> void:
				game.auction_bid(s)))
		b.disabled = p.cash < int(a["price"]) + s
	_button("不出价了", func() -> void: _do(game.auction_pass))


func _show_trade_controls() -> void:
	var o: Dictionary = game.pending["offer"]
	var counter: bool = game.pending["stage"] == "counter"
	var title := "%s 还价：" % game.players[int(o["to"])].display_name if counter \
			else "%s 向你提议交易：" % game.players[int(o["from"])].display_name
	_make_label(_controls, title + _offer_text(o), 14, Color("#fff59d"))
	_map.highlight = o["give"] + o["get"]
	_button("同意", func() -> void: _do(func() -> void: game.trade_answer(true)))
	_button("拒绝", func() -> void: _do(func() -> void: game.trade_answer(false)))
	if not counter:
		_button("还价", func() -> void: _open_trade_dialog(o))


## 交易内容的文字：A 给 xx、yy 和 100 万；B 给 zz
func _offer_text(o: Dictionary) -> String:
	var sides: Array = []
	var from_side := [int(o["from"]), o["give"], int(o["give_cash"])]
	for side in [from_side, [int(o["to"]), o["get"], int(o["get_cash"])]]:
		var items: Array = []
		for t in side[1]:
			items.append(_tname(int(t)) + ("（抵押中）" if game.props[int(t)]["mortgaged"] else ""))
		if int(side[2]) > 0:
			items.append("%d 万" % int(side[2]))
		sides.append("%s 给 %s" % [game.players[side[0]].display_name,
				"、".join(items) if not items.is_empty() else "（无）"])
	return "；".join(sides)


func _show_bank_controls(p) -> void:
	_make_label(_controls, "银行：现金 %d · 存款 %d。存取款？" % [p.cash, p.deposit], 14,
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
	_button("完成", func() -> void: _do(game.bank_done))


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
	_map.hover_highlight = []
	_map.queue_redraw()
	if game.phase != "over":
		_show_controls()


func _clear_overlay_box() -> void:
	for c in _overlay_box.get_children():
		c.queue_free()


func _rebuild_house_dialog(message: String) -> void:
	_clear_overlay_box()
	_map.hover_highlight = []
	var p = game.player()
	_make_label(_overlay_box, "房产 · %s · 现金 %d 万" % [p.display_name, p.cash], 18, Color.WHITE)
	if message != "":
		_make_label(_overlay_box, message, 14, Color("#ef9a9a"))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 380)
	_overlay_box.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	# 建房（含改建）：钱不够、抵押、有人站着的也列出来，按钮变灰并写原因
	var choices: Array = game.build_choices(p.index)
	_section(list, "建房（地上有自己的小房子就是改建，只付差价）", choices.size())
	for o in choices:
		var tiles: Array = o["tiles"]
		var verb := "改建成" if not game.replaced_houses(tiles).is_empty() else "建"
		var text := "%s%s · %s · 付 %d" % [verb, _house_name(str(o["kind"])), _tiles_text(tiles),
				int(o["cost"])]
		_dialog_button(list, text, tiles, func() -> void:
				_house_action(game.build(p.index, str(o["kind"]), tiles)), str(o["why"]))

	var upgradable: Array = []
	var mine: Array = []
	for hid in game.houses:
		var h: Dictionary = game.houses[hid]
		if h["owner"] != p.index:
			continue
		mine.append(hid)
		if game.can_ever_upgrade(hid):
			upgradable.append(hid)
	_section(list, "升级", upgradable.size())
	for hid in upgradable:
		var h: Dictionary = game.houses[hid]
		var id: int = hid
		var text := "%s 升级 · %s · 费用 %d" % [_house_name(str(h["kind"])), _tiles_text(h["tiles"]),
				game.upgrade_fee(h["tiles"])]
		_dialog_button(list, text, h["tiles"], func() -> void:
				_house_action(game.upgrade(p.index, id)), game.why_cannot_upgrade(p.index, id))

	_section(list, "拆房", mine.size())
	for hid in mine:
		var h: Dictionary = game.houses[hid]
		var id: int = hid
		var refund := Game.pct_of(game.house_cost(str(h["kind"]), h["tiles"]),
				int(Data.rules["houses"]["remove_refund_pct"]))
		var text := "拆除 %s · %s · 退还 %d" % [_house_name(str(h["kind"])), _tiles_text(h["tiles"]), refund]
		_dialog_button(list, text, h["tiles"], func() -> void:
				_house_action(game.remove_house(p.index, id)))

	if choices.size() + upgradable.size() + mine.size() == 0:
		_make_label(list, "还没有能建房的地", 13, Color("#90a4ae"))

	var close := Button.new()
	close.text = "关闭"
	close.custom_minimum_size = Vector2(0, 40)
	close.pressed.connect(_close_overlay)
	_overlay_box.add_child(close)


## 一栏的标题；这一栏没有选项时不显示
func _section(parent: Node, title: String, count: int) -> void:
	if count > 0:
		_make_label(parent, title, 15, Color("#ffd54f"))


func _tiles_text(tiles: Array) -> String:
	if tiles.size() == 1:
		return _tname(int(tiles[0]))
	return "%s ~ %s" % [_tname(int(tiles[0])), _tname(int(tiles[tiles.size() - 1]))]


## why 不为空时按钮变灰，后面写上为什么不能点
func _dialog_button(parent: Node, text: String, tiles: Array, on_press: Callable,
		why: String = "") -> void:
	var b := Button.new()
	b.text = text if why == "" else "%s（%s）" % [text, why]
	b.disabled = why != ""
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.pressed.connect(on_press)
	b.mouse_entered.connect(func() -> void:
		_map.hover_highlight = tiles
		_map.queue_redraw())
	b.mouse_exited.connect(func() -> void:
		_map.hover_highlight = []
		_map.queue_redraw())
	parent.add_child(b)


func _house_action(error: String) -> void:
	_flush_events()
	_rebuild_house_dialog(error)


# ───────────────────────── 抵押 / 拍卖 / 交易对话框 ─────────────────────────

## 对话框的标题、错误提示和可滚动的列表；返回列表，选项加在里面
func _dialog_frame(title: String, message: String) -> VBoxContainer:
	_clear_overlay_box()
	_map.hover_highlight = []
	var p = game.players[game.actor()]
	_make_label(_overlay_box, "%s · %s · 现金 %d 万" % [title, p.display_name, p.cash], 18, Color.WHITE)
	if message != "":
		_make_label(_overlay_box, message, 14, Color("#ef9a9a"))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 380)
	_overlay_box.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	return list


func _add_close_button(text: String = "关闭") -> void:
	var close := Button.new()
	close.text = text
	close.custom_minimum_size = Vector2(0, 40)
	close.pressed.connect(_close_overlay)
	_overlay_box.add_child(close)


func _open_mortgage_dialog() -> void:
	_overlay.visible = true
	_rebuild_mortgage_dialog("")


func _rebuild_mortgage_dialog(message: String) -> void:
	var list := _dialog_frame("抵押 / 赎回", message)
	var pi := game.current
	var can_mortgage: Array = []
	var mortgaged: Array = []
	for t in game.properties_of(pi):
		if game.why_cannot_mortgage(pi, t) == "":
			can_mortgage.append(t)
		elif game.props[t]["mortgaged"]:
			mortgaged.append(t)
	_section(list, "抵押", can_mortgage.size())
	for t in can_mortgage:
		var tile: int = t
		_dialog_button(list, "抵押 %s · 得 %d" % [_tname(tile), game.mortgage_value(tile)], [tile],
				func() -> void: _mortgage_action(game.mortgage(pi, tile)))
	_section(list, "赎回", mortgaged.size())
	for t in mortgaged:
		var tile: int = t
		_dialog_button(list, "赎回 %s · 付 %d" % [_tname(tile), game.unmortgage_cost(tile)], [tile],
				func() -> void: _mortgage_action(game.unmortgage(pi, tile)),
				game.why_cannot_unmortgage(pi, tile))
	if can_mortgage.is_empty() and mortgaged.is_empty():
		_make_label(list, "现在没有能抵押或赎回的地产", 13, Color("#90a4ae"))
	_add_close_button()


func _mortgage_action(error: String) -> void:
	_flush_events()
	_rebuild_mortgage_dialog(error)


func _open_auction_dialog() -> void:
	_overlay.visible = true
	var list := _dialog_frame("拍卖", "")
	var pi := game.current
	var count := 0
	for t in game.properties_of(pi):
		if game.why_cannot_auction(pi, t) != "":
			continue
		var tile: int = t
		count += 1
		_dialog_button(list, "拍卖 %s · 起拍 %d" % [_tname(tile), game.auction_start_price(tile)], [tile],
				func() -> void: _start_from_dialog(func() -> String: return game.start_auction(pi, tile)))
	if count == 0:
		_make_label(list, "现在没有能拍卖的地产", 13, Color("#90a4ae"))
	_add_close_button()


## 对话框里的操作会让别的玩家接着做决定（拍卖、交易）：关掉对话框，交给 _advance
func _start_from_dialog(action: Callable) -> String:
	var error: String = action.call()
	if error == "":
		_overlay.visible = false
		_map.hover_highlight = []
		_advance()
	return error


## base 为空：自己发起交易；否则是对 base 还价
func _open_trade_dialog(base: Dictionary) -> void:
	_overlay.visible = true
	if base.is_empty():
		var partner := -1
		for q in game.alive_players():
			if q.index != game.current:
				partner = q.index
				break
		_trade = {"from": game.current, "to": partner, "give": [], "get": [], "give_cash": 0,
				"get_cash": 0, "counter": false}
	else:
		_trade = base.duplicate(true)
		_trade["counter"] = true
	_rebuild_trade_dialog("")


func _rebuild_trade_dialog(message: String) -> void:
	var counter: bool = _trade["counter"]
	var list := _dialog_frame("还价" if counter else "交易", message)
	var a := int(_trade["from"])
	if not counter:
		var row := HBoxContainer.new()
		list.add_child(row)
		var who := _make_label(row, "和谁交易：", 14, Color.WHITE)
		who.autowrap_mode = TextServer.AUTOWRAP_OFF
		for q in game.alive_players():
			if q.index == a:
				continue
			var qi: int = q.index
			var b := Button.new()
			b.text = q.display_name
			b.toggle_mode = true
			b.button_pressed = qi == int(_trade["to"])
			b.pressed.connect(func() -> void:
				_trade["to"] = qi
				_trade["get"] = []
				_trade["get_cash"] = 0
				_rebuild_trade_dialog(""))
			row.add_child(b)
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 16)
	list.add_child(cols)
	_trade_column(cols, a, "give", "give_cash")
	_trade_column(cols, int(_trade["to"]), "get", "get_cash")
	var send := Button.new()
	send.text = "发出还价" if counter else "提议"
	send.custom_minimum_size = Vector2(0, 40)
	send.pressed.connect(_send_trade)
	_overlay_box.add_child(send)
	_add_close_button("取消")


## 交易的一边：这个玩家能拿出的地产（有房子的整栋一项）和现金
func _trade_column(parent: Node, pi: int, key: String, cash_key: String) -> void:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(col)
	_make_label(col, "%s 给出" % game.players[pi].display_name, 15, Color("#ffd54f"))
	var seen := {}
	for t in game.properties_of(pi):
		if seen.has(t):
			continue
		var hid := game.house_at(t)
		var tiles: Array = [t] if hid == 0 else game.houses[hid]["tiles"].duplicate()
		for x in tiles:
			seen[x] = true
		var text := _tiles_text(tiles)
		if hid != 0:
			text += " · " + _house_name(str(game.houses[hid]["kind"]))
		else:
			text += " · %d" % game.property_price(t)
		if game.props[t]["mortgaged"]:
			text += " · 抵押中"
		var box := CheckBox.new()
		box.button_pressed = _trade[key].has(t)
		box.text = ("√ " if box.button_pressed else "") + text
		for state in ["font_pressed_color", "font_hover_pressed_color"]:
			box.add_theme_color_override(state, Color("#ffd54f"))
		box.toggled.connect(func(on: bool) -> void:
			box.text = ("√ " if on else "") + text
			for x in tiles:
				_trade[key].erase(x)
				if on:
					_trade[key].append(x))
		box.mouse_entered.connect(func() -> void:
			_map.hover_highlight = tiles
			_map.queue_redraw())
		col.add_child(box)
	var row := HBoxContainer.new()
	col.add_child(row)
	_make_label(row, "现金", 14, Color.WHITE)
	var spin := SpinBox.new()
	spin.min_value = 0
	spin.max_value = game.players[pi].cash
	spin.step = 10
	spin.value = int(_trade[cash_key])
	spin.value_changed.connect(func(v: float) -> void: _trade[cash_key] = int(v))
	row.add_child(spin)


func _send_trade() -> void:
	var offer: Dictionary = _trade.duplicate(true)
	offer.erase("counter")
	var error := ""
	if _trade["counter"]:
		error = _start_from_dialog(func() -> String: return game.trade_counter(offer))
	else:
		error = _start_from_dialog(func() -> String: return game.propose_trade(offer))
	if error != "":
		_rebuild_trade_dialog(error)


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

func _on_tile_clicked(tile: int) -> void:
	if _pick_direction_by_click(tile):
		return
	if tile >= 0:
		tile = board.site(tile)  # 点到分身格，显示它代表的那块地 / 建筑
	_map.info_tile = tile
	_info_label.text = _tile_info(tile)
	_map.queue_redraw()


## 路口选方向时点地图：点中哪个方向要走的路（或路边的地）就往哪边走。点中了返回 true
func _pick_direction_by_click(tile: int) -> bool:
	if tile < 0 or _busy or game.pending.get("type", "") != "choose_direction" \
			or not game.players[game.actor()].human:
		return false
	var best := -1
	var best_at := 1 << 30
	for r in game.direction_routes():
		for i in r["tiles"].size():
			if board.site(int(r["tiles"][i])) == board.site(tile) and i < best_at:
				best = int(r["option"])
				best_at = i
	if best < 0:
		return false
	_do(func() -> void: game.choose_direction(best))
	return true


func _tile_info(i: int) -> String:
	if i < 0:
		return "点棋盘上的格子看详情"
	var t: Dictionary = board.get_tile(i)
	var text := "%s（%s）" % [_tname(i), MapView.TYPE_NAMES.get(str(t["type"]), "")]
	if not game.props.has(i):
		return text
	text += "\n价格 %d 万 · 现在的租金 %d 万" % [game.property_price(i), game.rent_of(i)]
	var o := game.owner_of(i)
	text += "\n主人：%s" % (game.players[o].display_name if o >= 0 else "无")
	var hid := game.house_at(i)
	if hid != 0:
		text += " · %s" % _house_name(str(game.houses[hid]["kind"]))
	return text
