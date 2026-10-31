extends SceneTree
## 表形态角色评测（无头，几十秒）。在 fourwinds-benti/ 里运行：
##   godot --headless --script res://tools/ai_characters.gd -- [角色 id ...]
## 不写角色时 4 个都跑。每个角色：自己的场景（和标准 AI 比打法方向）+ 成交价区间表
## （河南南路 1 号归这个角色，对手按“标准价”的各档出价来买，每档摆 20 次，数答应 / 还价 / 拒绝）。

const Lib = preload("res://tools/ai_characters_lib.gd")
const NAMES := {"david": "斐斐", "giorgio": "小九", "marcel": "孔雀", "eric": "理理"}


func _init() -> void:
	var who: Array = Array(OS.get_cmdline_user_args())
	if who.is_empty():
		who = ["david", "giorgio", "marcel", "eric"]
	var lib := Lib.new()
	var errors := lib.prepare()
	if not errors.is_empty():
		print("数据读取失败：", errors)
		quit(1)
		return
	for c in who:
		print("\n## %s\n" % NAMES.get(c, c))
		print("| # | 局面 | 应该 | 结果 |")
		print("|---|---|---|---|")
		for r in lib.run_character(c):
			var mark := "❔" if r["ok"] == null else ("✅" if r["ok"] else "❌")
			print("| %s | %s | %s | %s %s |" % [r["id"], r["what"], r["expect"], mark, r["got"]])
	print("\n## 成交价区间表（河南南路 1 号，每档 %d 次：成交 / 还价 / 拒绝）\n" % Lib.TRIALS)
	var head := "| 出价（占标准价） |"
	var line := "|---|"
	var tables := {}
	lib.me = "david"
	lib.version = "standard_v2"
	tables["标准 AI"] = lib.price_table()
	for c in who:
		lib.me = c
		lib.version = "new_v2"
		tables[NAMES.get(c, c)] = lib.price_table()
	for k in tables:
		head += " %s（标准价 %d） |" % [k, tables[k]["price"]]
		line += "---|"
	print(head)
	print(line)
	for pct in Lib.PRICE_STEPS:
		var row := "| %d%% |" % pct
		for k in tables:
			var c: Dictionary = tables[k]["rows"][pct]
			row += " %d / %d / %d |" % [c["成交"], c["还价"], c["拒绝"]]
		print(row)
	quit()
