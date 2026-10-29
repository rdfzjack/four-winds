extends SceneTree
## 把棋盘画面自动玩一阵再截图，用来在云端检查画面和人类操作流程（不能用 --headless）：
##   xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 \
##     --script res://tools/ui_check.gd -- 输出.png [ai|human] [帧数]
## ai：全是 AI，只看对局能不能自己跑；human：位置 1 是人类，脚本替他点按钮（走和真人一样的画面代码），
## 最后 60 帧停手，截图里能看到按钮。

var out_path := "user://ui_check.png"
var mode := "ai"
var total_frames := 900
var frames := 0
var table: Node = null


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_path = args[0]
	if args.size() > 1:
		mode = args[1]
	if args.size() > 2:
		total_frames = int(args[2])


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 1:
		# 自动加载的 Data 在 _init 时还没有，到第一帧才有
		root.get_node("Data").start_specs = [
			{"character": "david", "human": mode == "human"},
			{"character": "giorgio", "human": false},
			{"character": "marcel", "human": false},
			{"character": "eric", "human": false},
		]
		change_scene_to_file("res://scenes/table.tscn")
	if frames == 5:
		table = current_scene
		table._fast = true
	if table != null and mode == "human" and not table._busy:
		if frames < total_frames - 60:
			_human_step()
		elif frames == total_frames - 10 and table.game.phase == "pre_roll":
			table._open_house_dialog()  # 最后停在掷骰前时，顺便看看房产对话框
	if frames == total_frames:
		var img := root.get_texture().get_image()
		img.save_png(out_path)
		var g = table.game
		print("截图已保存：", out_path, "；第 ", g.day, " 天，阶段 ", g.phase, "，不一致：", g.check_invariants())
		quit()
	return false


## 替人类点按钮：和画面上的按钮调用同样的函数
func _human_step() -> void:
	var g = table.game
	if g.phase == "over" or not g.player().human:
		return
	if g.phase == "pre_roll":
		if frames % 2 == 0:
			table._on_roll()
		return
	match str(g.pending["type"]):
		"choose_direction":
			var t: int = g.pending["options"][0]
			table._do(func() -> void: g.choose_direction(t))
		"bank":
			table._do(g.bank_done)
		"buy_land", "buy_company":
			table._do(g.buy)
		"bail":
			table._do(func() -> void: g.bail(true))
