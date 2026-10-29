extends Camera2D
## 地图镜头：只移动地图层，界面层（CanvasLayer）不受影响。
##
## - focus()：回合开始时平滑移到当前玩家，并恢复自动跟随。
## - follow()：棋子走动时调用；玩家手动拖过镜头后，这一回合不再自动跟随，
##   直到下一回合开始或点“回到当前角色”。
## - 方向键 / WASD 平移，滚轮缩放（缩放由 map_view 转过来调 zoom_step）。
## - view_shift：界面层左右两栏挡住了一部分屏幕，镜头“对准”的是中间空出来的那块的中心。

const FOLLOW_SPEED := 7.0       ## 越大越快贴上目标
const KEY_PAN_SPEED := 700.0    ## 方向键平移速度（屏幕像素 / 秒）
const ZOOMS := [0.5, 0.65, 0.8, 1.0, 1.25, 1.5]

var following := true
var bounds := Rect2()           ## 地图范围，镜头中心不出这个框
var view_shift := Vector2.ZERO  ## 屏幕上“可见中心”相对屏幕中心偏多少（像素）

var _target := Vector2.ZERO
var _zoom_index := 3


func _ready() -> void:
	ignore_rotation = true
	zoom = Vector2.ONE * ZOOMS[_zoom_index]


## 平滑移到 world_pos（snap = 立刻跳过去），并恢复自动跟随
func focus(world_pos: Vector2, snap: bool = false) -> void:
	following = true
	_target = _clamp(world_pos - view_shift / zoom.x)
	if snap:
		position = _target


## 自动跟随时才移动
func follow(world_pos: Vector2) -> void:
	if following:
		_target = _clamp(world_pos - view_shift / zoom.x)


## 按屏幕像素平移（拖动、方向键），会打断自动跟随
func pan_screen(screen_delta: Vector2) -> void:
	following = false
	position = _clamp(position + screen_delta / zoom.x)
	_target = position


func zoom_step(direction: int) -> void:
	var before := view_shift / zoom.x
	_zoom_index = clampi(_zoom_index + direction, 0, ZOOMS.size() - 1)
	zoom = Vector2.ONE * ZOOMS[_zoom_index]
	# 缩放时保持“可见中心”看着的那一点不动
	var shift := view_shift / zoom.x - before
	position = _clamp(position - shift)
	_target = _clamp(_target - shift)


func _process(delta: float) -> void:
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_A):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_UP) or Input.is_key_pressed(KEY_W):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_DOWN) or Input.is_key_pressed(KEY_S):
		dir.y += 1.0
	if dir != Vector2.ZERO:
		pan_screen(dir.normalized() * KEY_PAN_SPEED * delta)
		return
	position = position.lerp(_target, 1.0 - exp(-FOLLOW_SPEED * delta))


func _clamp(p: Vector2) -> Vector2:
	if bounds.size == Vector2.ZERO:
		return p
	var s := view_shift / zoom.x
	return (p + s).clamp(bounds.position, bounds.end) - s
