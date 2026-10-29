extends RefCounted
## 等距换算：地图格子坐标（data/maps 里的 pos，平面网格）↔ 地图层坐标（像素）。
##
## **所有“格子 ↔ 位置”的换算只走这里**（画格子、棋子位置、点击判定、镜头目标）。
## 地图层坐标 ↔ 屏幕坐标由 Godot 的 Camera2D 负责（鼠标位置用 get_global_mouse_position()），
## 画面代码里不要自己再算。
##
## 原版图块是 80×40 的菱形：格子 x 加 1 → 往右下走半格，y 加 1 → 往左下走半格。

const TILE_W := 80.0
const TILE_H := 40.0


## 格子坐标 → 这一格菱形中心在地图层上的位置
static func to_world(cell: Vector2) -> Vector2:
	return Vector2((cell.x - cell.y) * TILE_W / 2.0, (cell.x + cell.y) * TILE_H / 2.0)


## 地图层位置 → 格子坐标（带小数）
static func to_cell_f(world: Vector2) -> Vector2:
	var u := world.x / (TILE_W / 2.0)
	var v := world.y / (TILE_H / 2.0)
	return Vector2((v + u) / 2.0, (v - u) / 2.0)


## 地图层位置 → 落在哪个格子（点击判定用）
static func to_cell(world: Vector2) -> Vector2i:
	var c := to_cell_f(world)
	return Vector2i(roundi(c.x), roundi(c.y))


## 遮挡顺序：数值小的在后面，先画
static func depth(cell: Vector2) -> float:
	return cell.x + cell.y


## 一格菱形的 4 个角（画色块、描边用），scale < 1 时往里缩
static func diamond(cell: Vector2, scale: float = 1.0) -> PackedVector2Array:
	var c := to_world(cell)
	var hw := TILE_W / 2.0 * scale
	var hh := TILE_H / 2.0 * scale
	return PackedVector2Array([
		c + Vector2(0, -hh), c + Vector2(hw, 0), c + Vector2(0, hh), c + Vector2(-hw, 0),
	])


## 格子坐标里的一步（例如从上一格走到这一格）在屏幕上朝哪边：up_left / up_right / down_left / down_right
static func facing(delta: Vector2) -> String:
	var w := to_world(delta)
	if w.y < 0.0:
		return "up_left" if w.x < 0.0 else "up_right"
	return "down_left" if w.x < 0.0 else "down_right"
