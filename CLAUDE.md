# 四方来财 / Four Winds

用 Godot 4 重做 1998 年《上海大富翁1940》的换皮版本，自用，不公开发布原版素材。
作者对 Godot 不熟，说明要简单直白；作者在自己的 Windows 电脑上用 Godot 4.7 测试。

先读：
- `docs/design.md`：设计文档（角色、城市、远期新规则）。和作者最新指示冲突时以作者为准。
- `docs/plan.md`：开发计划和当前进度。每完成一步就更新进度表。
- `docs/analysis.md`：原版文件格式和数据结构。
- `docs/original_rules.md`：反汇编确认的原版规则和数值（第 2 步按它实现规则）。

## 目录

| 位置 | 内容 |
|---|---|
| `shanghai1940/` | 原版游戏文件。**只读，不要修改或删除** |
| `tools/re/` | 反汇编工具：`disasm_exe.py` 生成带中文字符串注释的 `1940.exe` 汇编清单，已识别的函数会标上名字 |
| `tools/` | Python 工具：解包原版（`extract_all.py`）、生成游戏数据初版（`build_game_data.py`，默认不覆盖已有文件）、校验 Godot 数据（`validate_data.py`） |
| `extracted/` | 原版解包结果，只作参考。**不要整个拷进 Godot 项目**（85MB，会拖慢编辑器） |
| `fourwinds-benti/` | Godot 项目 |
| `fourwinds-benti/data/` | 所有规则数值、角色、地图、机会卡、AI 参数、台词（JSON），作者会自己改 |
| `fourwinds-benti/data/reference/` | 原版城市价格参考，游戏不读 |
| `fourwinds-benti/scripts/core/` | 规则逻辑。只处理数据，**不依赖画面节点**，能在无头模式下测试。`game.gd` 是一局游戏的全部规则（用法见文件开头的注释），`board.gd` 是地图，`player.gd` 是玩家数据 |
| `fourwinds-benti/scripts/ui/` | 画面和操作 |
| `fourwinds-benti/scripts/autoload/` | 全局单例（`Data` 读取 data/ 下的所有数据） |
| `fourwinds-benti/tests/` | 无头测试 `run_tests.gd` |

## 约定

- 规则和画面分开：`scripts/core/` 里的脚本不访问场景树和节点。
- 数值不写死在代码里，放 `data/*.json`。`data/` 里的文件生成后归作者所有，不要用 `build_game_data.py --force` 覆盖作者的修改。
- 台词是“事件 → 句子列表”，游戏随机挑一句；4 个角色的台词目前是草稿。
- 每张地图至少要有一条街（同一个 `group`）有 ≥ 4 块沿路连续的地，别墅要占 4 块；`validate_data.py` 会检查。
- 地图按“路网”存：每格的 `next` 列出可去的下一格。一圈 = 每格一个 next；岔路 = 多个 next。规则只通过 `Board.walk()` / `next_tiles()` 移动。
- 脚本之间用 `const X = preload("res://...")` 引用，不用 `class_name`（无头测试时全局类缓存可能不存在）。
- JSON 读出的数字是浮点数，当整数用要 `int()`。
- 导出游戏后如果读不到数据，检查导出预设，把 `*.json` 加进“非资源文件”过滤器。
- 代码注释和说明文字用中文，标识符用英文。
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

云端截图能查排版，手感仍需作者在 Windows 上按 F5 确认。
Godot 生成的 `*.uid` 文件要提交进仓库。
