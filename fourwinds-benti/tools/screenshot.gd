extends SceneTree
## 截一张主界面的图，用来在云端检查画面（需要虚拟显示器，不能用 --headless）：
##   xvfb-run -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 --script res://tools/screenshot.gd -- 输出.png

var frames := 0
var out_path := "user://screenshot.png"


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_path = args[0]
	change_scene_to_file.call_deferred("res://scenes/main.tscn")


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 10:
		var img := root.get_texture().get_image()
		img.save_png(out_path)
		print("截图已保存：", out_path)
		quit()
	return false
