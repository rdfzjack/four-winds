extends RefCounted
## 一个玩家（只有数据，没有画面）。

var index: int = 0          ## 在 Game.players 里的位置
var character: String = ""  ## 角色 id（对应 characters.json）
var display_name: String = ""
var human: bool = false
var form: String = "front"  ## 角色形态：front 表 / back 里（开局选定，对局中不切换）
var ai: String = "original" ## 用哪个 AI（见 scripts/core/ai.gd 的 VERSIONS），人类也留着不用
var cash: int = 0           ## 现金（买地、建房只能用现金）
var deposit: int = 0        ## 银行存款
var pos: int = 0            ## 所在格子编号
var bankrupt: bool = false
## 当前状态，同一时间只有一种。空字典 = 没有状态。
## {"kind": "jail", "days": 3}；days = -1 表示一直持续到触发为止（小偷）。
var status: Dictionary = {}
var church_passes: int = 0  ## 路过教堂的次数（每路过两次捐一次）
var permit: String = ""     ## 市政厅发的特许证（建特许建筑用，还没做）
## 原版 AI 的记忆（brain.gd）：cash_need = 掷骰前想建房还差多少现金，路过银行时多取。存档时要一起存。
var ai_memory: Dictionary = {}
## 关系值：对手的玩家编号 -> 我对他的好感（单向，A 对 B 和 B 对 A 各一份；没有记录 = 0）。
## 用玩家编号不用角色 id，因为同一角色的表和里可以同局。存档时要一起存（JSON 读回后键是字符串，要 int()）。
var relations: Dictionary = {}


func status_kind() -> String:
	return str(status.get("kind", ""))
