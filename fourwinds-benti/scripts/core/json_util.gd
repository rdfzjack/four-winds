extends RefCounted
## 读取 res://data/ 里的 JSON 文件。
##
## 注意：JSON 里的数字读出来都是浮点数（例如 3 会变成 3.0），
## 需要当整数用时要先 int()。


## 读取一个 JSON 文件。文件不存在或格式错误时返回 null，并把原因写进 errors。
static func load_json(path: String, errors: Array) -> Variant:
	if not FileAccess.file_exists(path):
		errors.append("找不到数据文件：%s" % path)
		return null
	var text := FileAccess.get_file_as_string(path)
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		errors.append("JSON 格式错误：%s 第 %d 行：%s" % [path, json.get_error_line(), json.get_error_message()])
		return null
	return json.data


## 读取一个顶层是 {} 的 JSON 文件；失败时返回空字典。
static func load_dict(path: String, errors: Array) -> Dictionary:
	var data: Variant = load_json(path, errors)
	if data is Dictionary:
		return data
	if data != null:
		errors.append("%s 的最外层应该是 { }" % path)
	return {}
