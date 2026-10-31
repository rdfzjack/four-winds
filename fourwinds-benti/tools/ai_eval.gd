extends SceneTree
## “AI 对 AI”评测工具（无头，不开窗口）。在 fourwinds-benti/ 里运行：
##   godot --headless --script res://tools/ai_eval.gd -- [选项...]
## 选项（都可省略）：
##   seats=david,giorgio,marcel,eric   座位，2–4 个。每个写成 角色[:形态[:AI 版本]]，
##                                     形态 front（表，默认）/ back（里），AI 版本 original（默认，原版）/
##                                     standard_v2（新框架标准 AI）/ new_v2（新框架角色 AI）/ new、standard（旧框架）
##                                     例：seats=david:front:new,eric::original
##   games=40      局数
##   days=300      每局最多几天（到了还没打完算超时，统计“超时领先”= 总资产最多）
##   map=shanghai  地图 id（data/maps/ 下的文件名）
##   cross=random  所有路口随机走（同主界面的“路口全部随机”）；不写 = 按地图（现在的地图路口都能选）
##   seed=1        第一局的随机种子（第 k 局用 seed + k，同样的选项结果完全一样）
##   rel=0         初始好感：一个数 = 所有人之间；“a>b:数”= 座位 a 对座位 b（座位从 0 数），逗号分隔
##                 例：rel=0,0>1:-30,1>0:20
##   set=键:值,...  临时改 AI 参数（不改 profiles.json），调参用。键只写参数名 = 所有角色、所有形态；
##                 写成“角色/形态:参数” = 只改这一个（standard/front = 标准 AI；新框架角色 AI 写 角色/front_v2，
##                 例 set=eric/front_v2:ask_up_pct:20。注意：改 standard/front 不会影响新框架角色 AI，要分别改）。
##                 例：set=value_horizon_days:60   set=eric/front:value_horizon_days:60
##   json=路径     另存一份原始计数（JSON），方便以后对比
## 每局座位顺序轮转（谁先走轮着来），统计按座位记。指标说明见 docs/ai_design.md 的 E 节。

const Lib = preload("res://tools/ai_eval_lib.gd")


func _init() -> void:
	var ev := Lib.new()
	var json_path := ""
	var seat_text := "david,giorgio,marcel,eric"
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		var value := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"seats":
				seat_text = value
			"games":
				ev.games = int(value)
			"days":
				ev.max_days = int(value)
			"map":
				ev.map_id = value
			"cross":
				ev.crossroads = value
			"seed":
				ev.seed_start = int(value)
			"rel":
				for item in value.split(","):
					if item.contains(">"):
						var pair := item.split(":")
						var ab := pair[0].split(">")
						ev.pair_relations[Vector2i(int(ab[0]), int(ab[1]))] = int(pair[1])
					elif item != "":
						ev.default_relation = int(item)
			"json":
				json_path = value
			"set":
				for item in value.split(","):
					var cut := item.rfind(":")
					if cut > 0:
						ev.overrides[item.substr(0, cut)] = float(item.substr(cut + 1))
			_:
				printerr("不认识的选项：%s（用法见 tools/ai_eval.gd 开头）" % arg)
				quit(1)
				return
	for s in seat_text.split(","):
		ev.seats.append(Lib.parse_seat(s))
	var errors := ev.prepare()
	if not errors.is_empty():
		printerr("\n".join(errors))
		quit(1)
		return
	var started := Time.get_ticks_msec()
	var report := ev.run()
	print(ev.format_report(report))
	print("\n用时 %.1f 秒" % ((Time.get_ticks_msec() - started) / 1000.0))
	if json_path != "":
		var f := FileAccess.open(json_path, FileAccess.WRITE)
		f.store_string(JSON.stringify({"seats": ev.seats, "report": report}, " "))
	quit(0)
