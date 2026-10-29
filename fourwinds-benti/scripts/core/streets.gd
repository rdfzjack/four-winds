extends RefCounted
## 街道进度：凑大房子还差什么。只读 Game 的状态，不改规则状态，不依赖画面。

## 每条街的情况（玩家在上面有地的街才列出）：凑大房子还差什么。AI 和建房界面都用它。
## 用法：Streets.progress(game, 玩家编号)
## 返回 [{group, name, total: 这条街几块地, mine: 自己有几块, free: 还没主人的几块,
##         others: 别人有几块, run: 自己的空地或平房（没抵押）沿路最多连着几块}]
## 平房也算进 run：并排的平房可以合并成大房子（Game.merge）
static func progress(game, pi: int) -> Array:
	var out: Array = []
	var by_group := {}
	for t in game.board.tiles:
		if str(t["type"]) != "land" or t.has("site"):
			continue
		var g := str(t.get("group", ""))
		if not by_group.has(g):
			by_group[g] = {"group": g, "name": str(game.board.groups.get(g, {}).get("name", g)),
					"total": 0, "mine": 0, "free": 0, "others": 0, "run": 0}
		var info: Dictionary = by_group[g]
		var id := int(t["id"])
		var o: int = game.owner_of(id)
		info["total"] += 1
		if o == pi:
			info["mine"] += 1
		elif o < 0:
			info["free"] += 1
		else:
			info["others"] += 1
		if _is_free_lot(game, pi, id):
			var n := 1
			while _free_chain_exists(game, pi, id, n + 1):
				n += 1
			info["run"] = maxi(int(info["run"]), n)
	for g in by_group:
		if int(by_group[g]["mine"]) > 0:
			out.append(by_group[g])
	return out


## 自己的、没抵押、空着或只有一栋平房的地
static func _is_free_lot(game, pi: int, tile: int) -> bool:
	if game.owner_of(tile) != pi or game.props[tile]["mortgaged"]:
		return false
	var hid: int = game.house_at(tile)
	return hid == 0 or str(game.houses[hid]["kind"]) == "flat"


static func _free_chain_exists(game, pi: int, start: int, n: int) -> bool:
	for chain in game.board.lot_chains(start, n):
		var ok := true
		for t in chain:
			ok = ok and _is_free_lot(game, pi, int(t))
		if ok:
			return true
	return false
