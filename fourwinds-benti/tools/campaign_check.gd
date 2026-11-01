extends SceneTree
## 个人主线的画面检查：依次截 角色列表、关卡列表、关前简介、棋盘开局、结算页（不能用 --headless）：
##   xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 \
##     --script res://tools/campaign_check.gd -- 输出目录
## 会写进度文件（user://profile.json）：脚本里先把路径换成临时文件，不弄脏真进度。

const Profile = preload("res://scripts/core/profile.gd")

var out_dir := "/tmp"
var frames := 0
var panel: Node = null
var table: Node = null


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0]
	Profile.path = "user://campaign_check_profile.json"
	change_scene_to_file.call_deferred("res://scenes/main.tscn")


func _shot(name: String) -> void:
	root.get_texture().get_image().save_png(out_dir.path_join(name + ".png"))
	print("截图：", name)


func _process(_delta: float) -> bool:
	frames += 1
	var data = root.get_node("Data")
	match frames:
		5:
			current_scene._open_campaign()
		12:
			panel = current_scene._overlay.find_children("*", "VBoxContainer", true, false)[0]
			_shot("1_characters")
			panel._show_stages("david")
		20:
			_shot("2_stages")
			panel._show_briefing("david", 0)
		28:
			_shot("3_briefing")
			data.start_stage = {"character": "david", "stage": 0}
			change_scene_to_file("res://scenes/table.tscn")
		60:
			table = current_scene
			_shot("4_table")
			var g = table.game
			g.rules = g.rules.duplicate(true)
			g.rules["houses"]["collapse_chance"] = 2000000000
			g.rules["houses"]["antique_chance_by_lots"] = {"1": 2000000000, "2": 2000000000,
					"3": 2000000000, "4": 2000000000}
			g.grant_lots(0, [6, 7])
			g.players[0].cash = 5000
			table._do(func() -> void: g.build(0, "villa", [4, 5, 6, 7]))
		300:
			_shot("5_result")
			print("结果：", table.game.scenario.result, " ", table.game.scenario.reason)
			var p := Profile.load_profile()
			print("进度：", p)
			DirAccess.remove_absolute(Profile.path)
			quit()
	return false
