extends SceneTree
## AI 评测场景（无头）。在 fourwinds-benti/ 里运行：
##   godot --headless --script res://tools/ai_scenarios.gd -- [AI 版本 ...]
## 不写版本时跑 standard_v2（新框架标准 AI）和 standard（旧框架标准 AI）对比。
## 场景和期望见 tools/ai_scenarios_lib.gd 和 docs/ai_design.md 的 H 节。

const Lib = preload("res://tools/ai_scenarios_lib.gd")


func _init() -> void:
	var versions: Array = Array(OS.get_cmdline_user_args())
	if versions.is_empty():
		versions = ["standard_v2", "standard"]
	var lib := Lib.new()
	var errors := lib.prepare()
	if not errors.is_empty():
		print("数据读取失败：", errors)
		quit(1)
		return
	var table := {}
	for v in versions:
		table[v] = lib.run(v)
	var head := "| # | 局面 | 应该 |"
	var line := "|---|---|---|"
	for v in versions:
		head += " %s |" % v
		line += "---|"
	print(head)
	print(line)
	var rows: Array = table[versions[0]]
	for i in range(rows.size()):
		var row := "| %s | %s | %s |" % [rows[i]["id"], rows[i]["what"], rows[i]["expect"]]
		for v in versions:
			var r: Dictionary = table[v][i]
			var mark := "❔" if r["ok"] == null else ("✅" if r["ok"] else "❌")
			row += " %s %s |" % [mark, r["got"]]
		print(row)
	for v in versions:
		var passed := 0
		var judged := 0
		for r in table[v]:
			if r["ok"] != null:
				judged += 1
				if r["ok"]:
					passed += 1
		print("%s：%d / %d 过（待定的不算）" % [v, passed, judged])
	quit()
