#!/usr/bin/env python3
"""台词统计：角色 × 事件的句数（按来源分开），列出哪些事件还没台词，方便看该补哪里。

    python3 tools/lines_report.py [--project fourwinds-benti] [--only 斐斐]

每格写“总句数”，括号里是来源分布（作者 / AI 写 / 占位 各几句）。
事件分两类：原版场合 / 交易 / 新场合。某个角色某个事件是 0 句，就是“还没台词”（游戏里这时不说话，
性格时刻没台词会退回普通的接受 / 拒绝 / 还价）。
"""
from __future__ import annotations

import argparse
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from lines_lib import Lines  # noqa: E402

# 不一定每个角色都要有的事件（性格时刻只有对应性格的角色才有）
OPTIONAL = {"被压价", "讨价还价", "放水让价", "领先时放宽", "落后时损人不利己", "按错", "买到喜欢的街", "输"}


def pad(text: str, width: int) -> str:
    """补空格到显示宽度 width（汉字占 2 格）"""
    used = sum(2 if ord(ch) > 127 else 1 for ch in text)
    return text + " " * max(1, width - used)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--project", default=str(ROOT / "fourwinds-benti"))
    ap.add_argument("--only", default="", help="只看这个角色（昵称）")
    a = ap.parse_args()
    lines = Lines(Path(a.project))
    for e in lines.errors:
        print("问题：", e)
    keys = sorted(lines.sets, key=lambda k: (lines.nicknames.get(k[0], k[0]), k[1]))
    if a.only:
        keys = [k for k in keys if lines.nicknames.get(k[0]) == a.only]
    names = [f"{lines.nicknames[k[0]]}{'·里' if k[1] == 'back' else ''}" for k in keys]
    print(pad("事件", 16) + "".join(pad(n, 18) for n in names))
    missing: dict[str, list[str]] = {}
    for ev in lines.events:
        cells = []
        for k, n in zip(keys, names):
            sentences = lines.sets[k].get(ev, [])
            c = Counter(s["source"] for s in sentences)
            cells.append(pad(f"{len(sentences)}" + (f"（{'/'.join(str(c.get(s, 0)) for s in lines.sources)}）" if sentences else ""), 18))
            if not sentences and ev not in OPTIONAL:
                missing.setdefault(n, []).append(ev)
        print(pad(ev, 16) + "".join(cells))
    print(f"\n括号里的顺序：{' / '.join(lines.sources)}")
    for n in names:
        total = sum(len(v) for k, nn in zip(keys, names) if nn == n for v in lines.sets[k].values())
        print(f"{n}：共 {total} 句；还没台词的事件：{'、'.join(missing.get(n, [])) or '无'}")
    return 1 if lines.errors else 0


if __name__ == "__main__":
    sys.exit(main())
