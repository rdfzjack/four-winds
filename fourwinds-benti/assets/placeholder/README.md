# 占位素材（原版《上海大富翁1940》）

由 `tools/copy_placeholder.py` 从 `extracted/images/` 生成，不要手改；要换图改 `scripts/ui/art.gd` 的路径表。
只自用，不发布。换成作者自己的素材后，整个 `placeholder/` 目录删掉即可（画面会退回色块）。

| 文件 | 来源（原版文件） | 取了哪些 | 用途 |
|---|---|---|---|
| `Surface.png` / `Surface.json` | `Sprite/Surface.spr`（解包：`extracted/images/Sprite/Surface.png`） | 全部 | 地表（草地、水边） |
| `Road.png` / `Road.json` | `Sprite/Road.spr`（解包：`extracted/images/Sprite/Road.png`） | 全部 | 道路：帧 0、1 是带虚线的直路，其余是无标线路面 |
| `Base.png` / `Base.json` | `Sprite/Base.spr`（解包：`extracted/images/Sprite/Base.png`） | 第 1 组 | 地基：帧 0 是路边的空地 |
| `Flag.png` / `Flag.json` | `Sprite/Flag.spr`（解包：`extracted/images/Sprite/Flag.png`） | 全部 | 格子标记：帧 0–3 是方向箭头，帧 4 白框，帧 5 黄框（选中） |
| `Saizi.png` / `Saizi.json` | `Sprite/Saizi.spr`（解包：`extracted/images/Sprite/Saizi.png`） | 第 2 组 | 骰子：只取第 2 组（1–6 点各一帧），滚动动画那组不要 |
| `Wai_g.png` / `Wai_g.json` | `Sprite/Wai_g.spr`（解包：`extracted/images/Sprite/Wai_g.png`） | 全部 | 外国人走路图（4 个朝向 × 8 帧），占位给斐斐 |
| `Hei_b.png` / `Hei_b.json` | `Sprite/Hei_b.spr`（解包：`extracted/images/Sprite/Hei_b.png`） | 全部 | 黑帮走路图，占位给小九 |
| `Mai_b.png` / `Mai_b.json` | `Sprite/Mai_b.spr`（解包：`extracted/images/Sprite/Mai_b.png`） | 全部 | 买办走路图，占位给孔雀 |
| `Tu_c.png` / `Tu_c.json` | `Sprite/Tu_c.spr`（解包：`extracted/images/Sprite/Tu_c.png`） | 全部 | 土财主走路图，占位给理理 |
| `Sign.png` / `Sign.json` | `Sprite/Base.spr`（原版文件，用 `Sprite/1940.col` 调色板） | 第 2 帧 | 地主牌：第 1 组是旗杆，第 2 组是旗面灰度（原版色号 56、184–191），画面乘上主人颜色 |
