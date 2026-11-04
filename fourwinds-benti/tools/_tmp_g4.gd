extends SceneTree
var frames := 0
func _process(_d: float) -> bool:
	frames += 1
	if frames == 1:
		var data = root.get_node("Data")
		data.start_stage = {"character": "giorgio", "stage": 3}
		change_scene_to_file("res://scenes/table.tscn")
	if frames == 60:
		print("OK 第 60 帧", current_scene)
		quit()
	return false
