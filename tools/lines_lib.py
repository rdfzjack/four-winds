"""台词文件（fourwinds-benti/data/lines/*.txt）的读法。validate_data.py 和 lines_report.py 共用。

写法和游戏里的读法（scripts/core/lines_db.gd）保持一致；改了一边记得改另一边。
"""
from __future__ import annotations

import json
import re
from pathlib import Path

MOOD_RE = re.compile(r"\s*[\[［]([^\]］]+)[\]］]\s*$")


class Lines:
    def __init__(self, proj: Path):
        self.proj = proj
        self.errors: list[str] = []
        self.events: dict = {}
        self.sources: dict = {}
        self.moods: list = []
        self.chars: dict = {}      # 昵称 / 全名 -> 角色 id
        self.nicknames: dict = {}  # 角色 id -> 昵称
        self.maps: list = []       # [(id, name)]
        # (角色 id, 形态) -> 事件中文名 -> [{text, mood, source, conds, where}]
        self.sets: dict = {}
        self._load()

    def _load(self) -> None:
        d = self.proj / "data/lines"
        try:
            ev = json.loads((d / "events.json").read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError) as e:
            self.errors.append(f"lines/events.json 读不了：{e}")
            return
        self.sources = {k: v for k, v in ev.get("sources", {}).items() if not k.startswith("_")}
        self.moods = ev.get("moods", {}).get("list", [])
        self.events = {k: v for k, v in ev.get("events", {}).items() if not k.startswith("_")}
        for k, e in self.events.items():
            if e.get("mood") not in self.moods:
                self.errors.append(f"events.json：事件 {k} 的默认表情 {e.get('mood')} 不在表情列表里")
        ids = [e.get("id") for e in self.events.values()]
        if len(set(ids)) != len(ids):
            self.errors.append("events.json：事件 id 有重复")
        for c in json.loads((self.proj / "data/characters.json").read_text(encoding="utf-8"))["characters"]:
            self.chars[c.get("nickname", "")] = c["id"]
            self.chars[c.get("name", "")] = c["id"]
            self.nicknames[c["id"]] = c.get("nickname", c["id"])
        for f in sorted((self.proj / "data/maps").glob("*.json")):
            m = json.loads(f.read_text(encoding="utf-8"))
            self.maps.append((m.get("id"), m.get("name", "")))
        for f in sorted(d.glob("*.txt")):
            self._add_file(f.name, f.read_text(encoding="utf-8"))

    def _add_file(self, name: str, text: str) -> None:
        stem = name[:-4]
        parts = stem.split("·")
        who = self.chars.get(parts[0], "")
        form = "front"
        if len(parts) > 1:
            form = {"里": "back", "表": "front"}.get(parts[1], "?")
        if not who or form == "?" or len(parts) > 2:
            self.errors.append(f"{name}：文件名要写 角色昵称.txt（里形态 昵称·里.txt）")
            return
        out = self.sets.setdefault((who, form), {})
        source = event = ""
        for n, raw in enumerate(text.split("\n"), 1):
            line = raw.strip()
            where = f"{name} 第 {n} 行"
            if not line:
                continue
            if line.startswith("##"):
                event = line[2:].strip()
                if event not in self.events:
                    self.errors.append(f"{where}：没有叫“{event}”的事件（看 data/lines/events.json）")
                    event = "?"
            elif line.startswith("#"):
                body = line[1:].strip()
                if body.startswith("来源"):
                    source = body[2:].lstrip("：: ").strip()
                    if source not in self.sources:
                        self.errors.append(f"{where}：来源“{source}”不在 events.json 的 sources 里")
                        source = "?"
            elif line.startswith("- "):
                if not event or not source:
                    self.errors.append(f"{where}：句子前面要先有“# 来源：”和“## 事件名”")
                elif event != "?" and source != "?":
                    parsed = self._parse_line(line[2:].strip(), where)
                    if parsed:
                        parsed.update(source=source, where=where)
                        out.setdefault(event, []).append(parsed)
            else:
                self.errors.append(f"{where}：这行看不懂（句子要以“- ”开头）")

    def _parse_line(self, body: str, where: str):
        conds = []
        while body.startswith(("（", "(")):
            close = body.find("）" if body.startswith("（") else ")")
            if close < 0:
                self.errors.append(f"{where}：条件括号没有关上")
                return None
            if not self._check_cond(body[1:close].strip(), where):
                return None
            conds.append(body[1:close].strip())
            body = body[close + 1:].strip()
        mood = ""
        m = MOOD_RE.search(body)
        if m:
            mood = m.group(1).strip()
            body = body[:m.start()].strip()
            if mood not in self.moods:
                self.errors.append(f"{where}：表情“{mood}”不存在（有：{'、'.join(self.moods)}）")
                return None
        for a, b in (("“", "”"), ('"', '"')):
            if len(body) >= 2 and body.startswith(a) and body.endswith(b):
                body = body[1:-1].strip()
        if not body:
            self.errors.append(f"{where}：台词是空的")
            return None
        return {"text": body, "mood": mood, "conds": conds}

    def _check_cond(self, c: str, where: str) -> bool:
        if c.startswith("只在"):
            name = c[2:].strip()
            ok = any(name in (mid, mname, mname.split("（")[0]) for mid, mname in self.maps)
            if not ok:
                self.errors.append(f"{where}：条件“{c}”里的地图不存在")
            return ok
        if c.endswith("在场时"):
            ok = c[:-3].strip() in self.chars
        elif c.startswith("对"):
            name = c[1:].strip()
            if name not in self.chars and name[-1:] in ("表", "里"):
                name = name[:-1]
            ok = name in self.chars
        else:
            self.errors.append(f"{where}：看不懂条件“{c}”（可以写：对某某 / 某某在场时 / 只在某地图）")
            return False
        if not ok:
            self.errors.append(f"{where}：条件“{c}”里的角色不存在")
        return ok
