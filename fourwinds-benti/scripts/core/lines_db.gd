extends RefCounted
## 台词库：读 data/lines/ 下的事件表（events.json）和每个角色一个的台词文本文件，按条件挑一句。
## 不依赖画面，无头测试能用。谁在什么时候说话由 speech.gd 决定，这里只管“这个人在这个事件下有哪些句子可抽”。
##
## 台词文件（角色昵称.txt，里形态是 昵称·里.txt）的写法：
##   # 来源：作者            ← 从这行起的句子都标这个来源（名字要在 events.json 的 sources 里）
##   ## 付高额租金           ← 事件名（要在 events.json 的 events 里）
##   - 这笔我记下了。         ← 一句台词；句首可以有条件，句尾 [表情] 可省
##   - （对孔雀）教授，你是认真的吗？ [生气]
##   - （斐斐在场时）哇，盖好了～斐斐你看！
##   - （只在上海）衡山路的梧桐，只有我配得上。
## 条件：（对某某）、（对某某表）、（对某某里）、（某某在场时）、（只在某地图）；可以连写几个，要全满足。
## 其他以 # 开头的行是注释，空行忽略。台词两头的 “” 会去掉。
## 读不懂的行记进 errors（带文件名和行号），不会让游戏崩。

const SET_SEPARATOR := "·"

var events: Dictionary = {}          ## 事件中文名 -> {id, mood, priority, chance, cooldown}
var event_names: Dictionary = {}     ## 事件 id -> 中文名
var sources: Dictionary = {}         ## 来源名 -> 权重（0 = 关）
var moods: Array = []
var settings: Dictionary = {}
var errors: Array = []

## "角色id|front" 或 "角色id|back" -> {事件中文名: [句子]}；句子 = {text, mood, source, conds, where}
var _sets: Dictionary = {}
var _chars_by_name: Dictionary = {}  ## 昵称 / 全名 -> 角色 id
var _maps: Array = []                ## [{id, name}]


## 读事件表。events_file 是 events.json 读出来的字典。
func setup(events_file: Dictionary, characters: Array, maps: Array) -> void:
	events.clear()
	event_names.clear()
	_sets.clear()
	errors.clear()
	sources = _without_notes(events_file.get("sources", {}))
	moods = events_file.get("moods", {}).get("list", [])
	settings = events_file.get("settings", {})
	for key in events_file.get("events", {}):
		if str(key).begins_with("_"):
			continue
		var e: Dictionary = events_file["events"][key]
		events[str(key)] = e
		event_names[str(e.get("id", ""))] = str(key)
		if not moods.has(str(e.get("mood", ""))):
			errors.append("events.json：事件 %s 的默认表情 %s 不在表情列表里" % [key, e.get("mood", "")])
	_chars_by_name.clear()
	for c in characters:
		_chars_by_name[str(c.get("nickname", ""))] = str(c.get("id", ""))
		_chars_by_name[str(c.get("name", ""))] = str(c.get("id", ""))
	_maps = maps


static func _without_notes(d: Dictionary) -> Dictionary:
	var out := {}
	for k in d:
		if not str(k).begins_with("_"):
			out[str(k)] = d[k]
	return out


## 读 dir 下所有 .txt 台词文件
func load_dir(dir: String) -> void:
	var files := DirAccess.get_files_at(dir)
	files.sort()
	for f in files:
		if f.ends_with(".txt"):
			add_file(f, FileAccess.get_file_as_string(dir.path_join(f)))


## 加一个台词文件。name 是文件名（如 "斐斐.txt"，决定是谁的台词），text 是内容。
func add_file(file_name: String, text: String) -> void:
	var stem := file_name.get_basename()
	var parts := stem.split(SET_SEPARATOR)
	var who := str(_chars_by_name.get(parts[0], ""))
	var form := "front"
	if parts.size() > 1:
		form = "back" if parts[1] == "里" else ("front" if parts[1] == "表" else "?")
	if who == "" or form == "?" or parts.size() > 2:
		errors.append("%s：文件名要写 角色昵称.txt（里形态 昵称·里.txt）" % file_name)
		return
	var key := "%s|%s" % [who, form]
	if not _sets.has(key):
		_sets[key] = {}
	var source := ""
	var event := ""
	var n := 0
	for raw in text.split("\n"):
		n += 1
		var line := raw.strip_edges()
		var where := "%s 第 %d 行" % [file_name, n]
		if line == "":
			continue
		if line.begins_with("##"):
			event = line.substr(2).strip_edges()
			if not events.has(event):
				errors.append("%s：没有叫“%s”的事件（看 data/lines/events.json）" % [where, event])
				event = "?"
		elif line.begins_with("#"):
			var body := line.substr(1).strip_edges()
			if body.begins_with("来源"):
				source = body.substr(2).lstrip("：: ").strip_edges()
				if not sources.has(source):
					errors.append("%s：来源“%s”不在 events.json 的 sources 里" % [where, source])
					source = "?"
		elif line.begins_with("- "):
			if event == "" or source == "":
				errors.append("%s：句子前面要先有“# 来源：”和“## 事件名”" % where)
			elif event != "?" and source != "?":
				var parsed := _parse_line(line.substr(2).strip_edges(), where)
				if not parsed.is_empty():
					parsed["source"] = source
					parsed["where"] = where
					if not _sets[key].has(event):
						_sets[key][event] = []
					_sets[key][event].append(parsed)
		else:
			errors.append("%s：这行看不懂（句子要以“- ”开头）" % where)


## 一句台词：（条件）… 正文 [表情]。读错返回空字典并记错误
func _parse_line(body: String, where: String) -> Dictionary:
	var conds: Array = []
	while body.begins_with("（") or body.begins_with("("):
		var close := body.find("）") if body.begins_with("（") else body.find(")")
		if close < 0:
			errors.append("%s：条件括号没有关上" % where)
			return {}
		var c := _parse_cond(body.substr(1, close - 1).strip_edges(), where)
		if c.is_empty():
			return {}
		conds.append(c)
		body = body.substr(close + 1).strip_edges()
	var mood := ""
	var re := RegEx.create_from_string("\\s*[\\[［]([^\\]］]+)[\\]］]\\s*$")
	var m := re.search(body)
	if m != null:
		mood = m.get_string(1).strip_edges()
		body = body.substr(0, m.get_start()).strip_edges()
		if not moods.has(mood):
			errors.append("%s：表情“%s”不存在（有：%s）" % [where, mood, "、".join(moods)])
			return {}
	for pair in [["“", "”"], ["\"", "\""]]:
		if body.length() >= 2 and body.begins_with(pair[0]) and body.ends_with(pair[1]):
			body = body.substr(1, body.length() - 2).strip_edges()
	if body == "":
		errors.append("%s：台词是空的" % where)
		return {}
	return {"text": body, "mood": mood, "conds": conds}


# gdlint: disable=max-returns
func _parse_cond(c: String, where: String) -> Dictionary:
	if c.begins_with("只在"):
		var ids := _match_maps(c.substr(2).strip_edges())
		if ids.is_empty():
			errors.append("%s：条件“%s”里的地图不存在" % [where, c])
			return {}
		return {"kind": "map", "maps": ids}
	if c.ends_with("在场时"):
		var who := str(_chars_by_name.get(c.left(c.length() - 3).strip_edges(), ""))
		if who == "":
			errors.append("%s：条件“%s”里的角色不存在" % [where, c])
			return {}
		return {"kind": "present", "id": who}
	if c.begins_with("对"):
		var name := c.substr(1).strip_edges()
		var form := ""
		if not _chars_by_name.has(name):
			if name.ends_with("表"):
				form = "front"
			elif name.ends_with("里"):
				form = "back"
			if form != "":
				name = name.left(name.length() - 1)
		var who2 := str(_chars_by_name.get(name, ""))
		if who2 == "":
			errors.append("%s：条件“%s”里的角色不存在" % [where, c])
			return {}
		return {"kind": "target", "id": who2, "form": form}
	errors.append("%s：看不懂条件“%s”（可以写：对某某 / 某某在场时 / 只在某地图）" % [where, c])
	return {}

# gdlint: enable=max-returns


## 地图名匹配：先按完整名字或 id，没有再按名字括号前的部分（“上海”匹配所有叫“上海（……）”的）
func _match_maps(name: String) -> Array:
	var exact: Array = []
	var loose: Array = []
	for m in _maps:
		var full := str(m["name"])
		if name == full or name == str(m["id"]):
			exact.append(str(m["id"]))
		elif name == full.split("（")[0]:
			loose.append(str(m["id"]))
	return exact if not exact.is_empty() else loose


# ───────────────────────── 查询 ─────────────────────────

## 角色有台词的事件数、句数等统计用：返回 {事件中文名: [句子]}（只含这个角色这个形态自己的文件）
func lines_of(character_id: String, form: String) -> Dictionary:
	return _sets.get("%s|%s" % [character_id, form], {})


## 所有有台词的角色 / 形态键 "id|form"
func set_keys() -> Array:
	return _sets.keys()


## 说话人 speaker（角色 id + 形态）在事件 event（中文名）下能抽的句子，带权重。
## ctx = {target: 对象角色 id（没有对象是 ""）, target_form, present: [在场的别的角色 id], map: 地图 id}
## 里形态在自己的文件里找不到合条件的句子时，用表形态的。返回 [{line, weight}]
func pool(character_id: String, form: String, event: String, ctx: Dictionary) -> Array:
	var out: Array = []
	if form == "back":
		out = _pool_in(_sets.get("%s|back" % character_id, {}), event, ctx)
	if out.is_empty():
		out = _pool_in(_sets.get("%s|front" % character_id, {}), event, ctx)
	return out


func _pool_in(by_event: Dictionary, event: String, ctx: Dictionary) -> Array:
	var out: Array = []
	for line in by_event.get(event, []):
		var weight := float(sources.get(line["source"], 0.0))
		if weight <= 0.0:
			continue
		var ok := true
		for c in line["conds"]:
			var w := _cond_weight(c, ctx)
			if w <= 0.0:
				ok = false
				break
			weight *= w
		if ok:
			out.append({"line": line, "weight": weight})
	return out


## 这个条件满足时的权重倍数；不满足返回 0
func _cond_weight(c: Dictionary, ctx: Dictionary) -> float:
	match str(c["kind"]):
		"target":
			if str(ctx.get("target", "")) != str(c["id"]):
				return 0.0
			if str(c["form"]) != "" and str(ctx.get("target_form", "")) != str(c["form"]):
				return 0.0
			return float(settings.get("weight_target", 4))
		"present":
			return float(settings.get("weight_present", 2)) if ctx.get("present",
					[]).has(str(c["id"])) else 0.0
		"map":
			return float(settings.get("weight_map", 3)) if c["maps"].has(str(ctx.get("map",
					""))) else 0.0
	return 0.0
