# 四方来财 / Four Winds

用 Godot 4 重做 1998 年《上海大富翁1940》的换皮版本，自用，不公开发布原版素材。
作者对 Godot 不熟，说明要简单直白；作者在自己的 Windows 电脑上用 Godot 4.7 测试。

先读 `docs/plan.md`：进度、作者定下的做事方式、规则现状、下一步的交接。每完成一步就更新进度表，做完的步骤只留结论。

需要时再查（不用开场全读）：
- `docs/design.md`：设计文档（角色、城市、远期新规则）。和作者最新指示冲突时以作者为准。
- `docs/original_rules.md`：反汇编确认的原版规则和数值。
- `docs/campaigns.md`：个人主线的关卡数据格式、条件类型、判定时机、进度文件。
- `docs/campaign_brief.md`：作者和其他 AI 讨论主线剧情用的简报，同时是 8b 要作者交付的清单。
- `docs/analysis.md`：原版文件格式和数据结构（`.cit` 地图、AI 参数、台词等）。

## 目录

| 位置 | 内容 |
|---|---|
| `shanghai1940/` | 原版游戏文件。**只读，不要修改或删除** |
| `tools/re/` | 反汇编工具：`disasm_exe.py` 生成带中文字符串注释的 `1940.exe` 汇编清单，已识别的函数会标上名字 |
| `tools/` | Python 工具：解包原版（`extract_all.py`）、拷占位素材（`copy_placeholder.py`）、生成游戏数据初版（`build_game_data.py`，默认不覆盖已有文件）、原版 `.cit` 地图转我们的地图（`cit_to_map.py`，用法见文件开头）、校验 Godot 数据（`validate_data.py`） |
| `extracted/` | 原版解包结果，只作参考。**不要整个拷进 Godot 项目**（85MB，会拖慢编辑器） |
| `fourwinds-benti/` | Godot 项目 |
| `fourwinds-benti/data/` | 所有规则数值、角色、地图、机会卡、AI 参数（JSON），作者会自己改 |
| `fourwinds-benti/data/lines/` | 台词：每个角色一个纯文本文件（`斐斐.txt`…）+ 事件表 `events.json`。写法见 `docs/lines.md` |
| `fourwinds-benti/data/campaigns/` | 个人主线关卡，每个角色一个文件（`david.json`…）。现在只有示例关，格式见 `docs/campaigns.md` |
| `fourwinds-benti/data/reference/` | 原版城市价格参考，游戏不读 |
| `fourwinds-benti/scripts/core/` | 规则逻辑。只处理数据，**不依赖画面节点**，能在无头模式下测试。`game.gd` 是一局游戏的全部规则（用法见文件开头的注释），`board.gd` 是地图，`player.gd` 是玩家数据，`streets.gd` 是街道进度（凑大房子还差什么），`ai.gd` 是 AI 入口（`AI.step(game)`，按玩家的 AI 版本分派），`ai_profiles.gd` 按“角色 + 形态”取 AI 参数，`brain.gd` 是原版 AI，`lines_db.gd` 读台词文件并按条件筛句子，`speech.gd` 决定“谁在什么时候对谁说哪句”（`plan(events)`，画面只负责显示），`scenario.gd` 关卡（开局设置 + 胜负条件，`Game.scenario`，没有关卡时规则完全不变），`profile.gd` 玩家进度（`user://profile.json`，和对局存档分开），`save_game.gd` 存档 / 读档（用法见文件开头；`Game.export_state` / `import_state` 是整局状态，改了 `Game`、`Player`、`Speech` 里要跨回合保留的变量，要同步改这几个函数，`tests/save_tests.gd` 会报不一致） |
| `fourwinds-benti/scripts/ui/` | 画面和操作：`main.gd` 选座位，`table.gd` 棋盘和热座（驱动游戏、界面层），`map_view.gd` 地图层，`map_camera.gd` 镜头，`iso.gd` 等距换算（**格子 ↔ 位置只走这里**），`art.gd` 素材路径表（**图片只从这里拿**），`save_panel.gd` 存档位列表（存档、读档共用），`campaign_panel.gd` 个人主线入口（选角色 → 关卡 → 简介） |
| `fourwinds-benti/assets/placeholder/` | 原版素材占位，由 `tools/copy_placeholder.py` 生成，来源见目录里的 `README.md`。换成作者的素材后整个删掉 |
| `fourwinds-benti/scripts/autoload/` | 全局单例（`Data` 读取 data/ 下的所有数据） |
| `fourwinds-benti/tests/` | 无头测试 `run_tests.gd` |

## 约定

- 规则和画面分开：`scripts/core/` 里的脚本不访问场景树和节点。
- 画面分两层：地图层（跟镜头动）和界面层（`CanvasLayer`，不动）。新界面（拍卖、交易、对话、立绘）加在界面层。
- 数值不写死在代码里，放 `data/*.json`。`data/` 里的文件生成后归作者所有，不要用 `build_game_data.py --force` 覆盖作者的修改。
- 台词写在 `data/lines/<角色>.txt`（一句一行，句首括号是条件，句尾方括号是表情，格式见 `docs/lines.md`），事件、概率、冷却、优先级在 `data/lines/events.json`；`python3 tools/lines_report.py` 看每个角色每个事件有几句。台词的句子来源分 作者 / AI 写 / 占位，作者的原话不要改。
- 每张地图至少要有一条街（同一个 `group`）有 ≥ 4 块沿路连续的地，别墅要占 4 块；`validate_data.py` 会检查。
- 地图按“路网”存：每格的 `next` 列出可去的下一格。一圈 = 每格一个 next；岔路 = 多个 next。规则只通过 `Board.walk()` / `next_tiles()` 移动。
- 原版地图里一块地 / 一栋建筑可能挨着几格路：一格是正格，其余是带 `site` 的分身格。地产归属、建房只认正格，规则里用 `Board.site()` 换算。
- 脚本之间用 `const X = preload("res://...")` 引用，不用 `class_name`（无头测试时全局类缓存可能不存在）。
- JSON 读出的数字是浮点数，当整数用要 `int()`。
- 导出游戏后如果读不到数据，检查导出预设，把 `*.json`、`*.txt` 加进“非资源文件”过滤器（台词是 `.txt`）。
- 代码注释和说明文字用中文，标识符用英文。
- 判断某个问题的原因之前，先用测试或无头对局验证；写进文档的结论要注明验证过没有，没验证的不要写成定论。
- 每个任务一个分支，做完开 PR，作者在 Windows 上测试后合并。提交信息不写模型名。

## 测试

云端可以从 Godot 官网下载和作者同版本的 Godot（github.com 的下载会被拦截，所以不用它）：

```bash
bash tools/setup_godot.sh
```

然后在 `fourwinds-benti/` 里运行无头测试，并把主界面跑几十帧确认没有运行时报错：

```bash
godot --headless --import
```

```bash
godot --headless --script res://tests/run_tests.gd
```

```bash
godot --headless --quit-after 60
```

数据和语法的快速检查（不需要 Godot）：

```bash
python3 tools/validate_data.py
```

```bash
pip install "gdtoolkit==4.*" && gdlint $(find fourwinds-benti/scripts fourwinds-benti/tests -name '*.gd')
```

看画面：用虚拟显示器渲染主界面截图（不能加 --headless）：

```bash
xvfb-run -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 --script res://tools/screenshot.gd -- /tmp/shot.png
```

`run_tests.gd` 最后会把棋盘画面全 AI 跑到第 3 天，画面脚本的运行时错误也能在无头测试里发现。
台词文件有没有写错：`python3 tools/validate_data.py`（同时检查地图和数据）。
`fourwinds-benti/tools/ai_eval.gd` 是“AI 对 AI”评测工具（用法见文件开头）。
`fourwinds-benti/tools/ai_scenarios.gd`（标准 AI 的固定局面场景，几秒）和 `ai_characters.gd`（表形态角色的场景 + 成交价区间表，一两分钟）检查 AI 的打法方向。工具脚本加载失败时 Godot 不会退出，运行前先 `godot --headless --check-only --script 路径` 查语法。
`fourwinds-benti/tools/ui_check.gd` 会让画面自动玩一阵再截图（`ai` 全 AI，`human` 替人类点按钮，用法见文件开头）。`tools/campaign_check.gd` 截个人主线的角色列表、关卡列表、简介、开局、结算页（用法见文件开头）。
云端截图能查排版，手感仍需作者在 Windows 上按 F5 确认。
Godot 生成的 `*.uid` 文件要提交进仓库。
