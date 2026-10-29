extends RefCounted
## 一个玩家（只有数据，没有画面）。

var index: int = 0          ## 在 Game.players 里的位置
var character: String = ""  ## 角色 id（对应 characters.json）
var display_name: String = ""
var human: bool = false
var cash: int = 0           ## 现金（买地、建房只能用现金）
var deposit: int = 0        ## 银行存款
var pos: int = 0            ## 所在格子编号
var bankrupt: bool = false
## 当前状态，同一时间只有一种。空字典 = 没有状态。
## {"kind": "jail", "days": 3}；days = -1 表示一直持续到触发为止（小偷）。
var status: Dictionary = {}
var church_passes: int = 0  ## 路过教堂的次数（每路过两次捐一次）
var permit: String = ""     ## 市政厅发的特许证（建特许建筑用，还没做）


func status_kind() -> String:
	return str(status.get("kind", ""))
