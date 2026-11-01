# 个人主线：关卡数据格式

每个角色一条主线，一个文件：`fourwinds-benti/data/campaigns/<角色 id>.json`（作者以后自己改）。读取和检查在 `Data._load_campaigns`，写错了会显示在主界面的“数据有 N 个问题”里。规则逻辑在 `scripts/core/scenario.gd`，进度保存在 `scripts/core/profile.gd`。

**现有数据**（8b 进行中）：`eric.json`（理理 3 关）已按作者的讨论稿填好；`david.json`（斐斐）第 3 关按讨论稿，第 1、2 关作者还没定，是带 `example` 标记的占位（目标取自讨论稿的候选，对手也是占位，只为让第 3 关能打到）；孔雀、小九还没有。开局资金、预置地产、百分比、限时都是起点数字，等逐关跑模拟后标定。测试用的示例关在 `tests/fixtures/example_campaign.json`（游戏不读）。关卡内容（剧情、对手、目标）以作者为准，不要替作者编。

**主线用的地图**（原版地图数据换皮，地名、企业名重新包装，行业类别是机制）：`berlin`（Story11，柏林·舍讷贝格）、`london`（Story23）、`shanghai_concession`（Story15）、`riviera`（Story35，蔚蓝海岸）、`newyork`（Story17，纺织换成 `finance` 金融）；理理第 2 关用已有的 `shanghai_west`（没有改它的街名）。`berlin` 最长的街只有 3 块，写了 `short_streets_ok`，盖不了别墅。

## 文件

```json
{
 "character": "david",
 "name": "主线名",
 "stages": [ 关卡, 关卡, ... ]
}
```

## 一关

| 字段 | 说明 |
|---|---|
| `id` | 关卡 id，同一个文件里不能重复 |
| `name` | 关卡名 |
| `example` | 可选，`true` = 示例占位数据 |
| `map` | 地图 id（`data/maps/` 里的文件名，不含 `.json`） |
| `intro` | 关前简介（叙述文字，不是台词） |
| `outro_win` / `outro_lose` | 关后文字（胜 / 负） |
| `seats` | 座位列表（见下），2 到 `rules.json` 的 `max_players`（现在是 4）个 |
| `win` / `lose` | 条件列表（见下） |

### 座位

| 字段 | 说明 |
|---|---|
| `character` | 角色 id。同一关里一个角色只能坐一个位置 |
| `player` | `true` = 玩家自己（人类）。要有且只有一个 |
| `form` | 可选，`front`（表，默认）/ `back`（里，8c 之前还没有里形态的 AI） |
| `ai` | 对手的 AI 版本，可选，默认 `new_v2`（角色 AI）；`standard_v2` 是没有性格的标准 AI |
| `cash` / `deposit` | 开局现金 / 存款，不写就用 `rules.json` 的 `starting_cash` / `starting_deposit` |
| `props` | 开局已有的地产，列表。`{"tile": 格子编号}` 一块地或企业；`{"tiles": [a, b], "house": "hotel"}` 几块连成一排的地上盖好房子（`house` 是房屋 id：`flat` / `hotel` / `super_hotel` / `floor` / `super_floor` / `villa`，块数要对得上） |

**格子编号要写正格**，不能写分身格（见 `board.gd` 开头的说明；校验会报错）。不收钱，也不检查够不够钱。

### 条件

`win` / `lose` 都是条件列表，**满足其中任意一条就结束**。同时满足胜和负时按**负**算。条件 = `{"type": 类型, ...参数}`。`who` 写座位号（从 0 数）、`"player"`（玩家自己）、`"others"`（除玩家以外的所有人）或座位号列表，不写默认 `"player"`。

| 类型 | 参数 | 意思 |
|---|---|---|
| `bankrupt` | `who`，`mode`（`any` 任意一个 / `all` 全部，默认 `any`） | 破产。击败所有对手 = `{"type":"bankrupt","who":"others","mode":"all"}` |
| `build_house` | `who`，`kind`（房屋 id 或列表），`count`（默认 1） | 名下有这种房子。“首先建成别墅”= 胜里写玩家建别墅、负里写 `who: "others"` 建别墅 |
| `control_industry` | `who`，`industry`（地图企业的 `industry`），可选 `industry_name`（显示用） | 拥有这个行业的全部企业（地图里至少有一家） |
| `control_street` | `who`，`group`（街道组 id，不写 = 任意一条街），可选 `group_name` | 拥有这条街的全部地 |
| `own_lots_pct` | `who`，`pct` | 拥有全图 pct% 以上的地 |
| `assets_at_least` | `who`，`amount`（万圆） | 总资产达到这个数（破产的人不算） |
| `days_over` | `days` | 天数超过 days：第 `days` 天走完、进入第 `days+1` 天的那一刻 |

“击败某人”= `bankrupt` 那个人。“一个月内”要写 `days_over` 的天数；一个月暂定 30 天（作者定，示例关用）。

新增条件类型：在 `scenario.gd` 的 `TYPES` 里登记一行，写一个判断（`cond_met` 里加一个分支）和一句 `describe` 的说明，在 `tests/scenario_tests.gd` 里加通过 / 不通过的例子。

**还没有的类型**：保护同伴不破产（依赖同伴 AI 的行为，放到后面）；保护以外的“同伴”概念也没有。

## 判定什么时候发生

`Game` 在这些时刻问关卡“有结果吗”：建房 / 升级 / 买地 / 拍卖成交 / 交易成交之后、有人破产之后、每个人回合开始时、新的一天开始时。**机会卡直接送的房子或地不会立刻判**，下一个回合开始时才判。

结果出来时：`Game` 发 `scenario_won` / `scenario_lost`（带 `reason`），再发 `game_over`，`phase` 变成 `over`；胜了 `winner` 是玩家座位，负了是 -1。

如果没有条件命中，但对局本身结束了（只剩一个人、人类全部破产）：只剩玩家一个人算胜，其他算负。

没有关卡时（`game.scenario == null`，自由模式）以上全部不起作用：用 18 局（3 张地图 × 3 个种子 × 2 种 AI）对比过，改之前改之后的整局状态逐字一样。

## 存档

整个关卡数据和结果存在 `Game.export_state` 的 `scenario` 里（存档自带关卡，之后改 `data/` 不影响已经存的那一局）；棋盘画面的存档 `extra.campaign` 记着“哪个角色第几关”，读档后通关还能记进度。没有 `scenario` 的旧存档读成自由模式。

## 进度（profile）

`user://profile.json`（Windows：`%APPDATA%\Godot\app_userdata\<项目名>\profile.json`）：

```json
{"version": 1, "characters": {"david": {"next": 1, "cleared": false}}, "back_unlocked": []}
```

`next` = 下一关的下标（0 起）。已通关的关可以重玩，不会让进度倒退；通关最后一关时 `cleared` 变 `true`，角色 id 加进 `back_unlocked`。文件不存在、损坏、版本不对都当全新。里形态的 AI 现在没有（8c），主界面选座位暂时不放里形态选项，只记解锁标记。

## 界面入口

主界面“个人主线”→ 选角色 → 关卡列表（已通关 / 当前 / 未解锁）→ 关前简介（对手、开局钱、胜负条件）→ 开始。棋盘左侧显示胜负条件；结算页有胜 / 负文字，胜了有“下一关”，败了有“重试本关”。样子都是临时的，放到“界面与手感”统一做。
