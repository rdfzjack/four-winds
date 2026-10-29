#!/usr/bin/env python3
"""Annotated disassembly of the original 1940.exe, for reading the game rules.

Usage:
    python3 tools/re/disasm_exe.py [--exe shanghai1940/1940.exe] [--out /tmp/1940.asm]

Writes one big text listing of the .text section:
  * functions split at the 0xCC/0x90 padding the compiler leaves between them,
    each headed by "==== func 0x...."
  * calls through the incremental-linking jump table resolved to the real target
  * pushes / movs of addresses in .rdata/.data annotated with the GBK string
    found there (so you can grep for 缴纳财产税, 保释金, ...)
  * known C runtime / game helpers named (fread, rand, sprintf, ...)

Needs: pip install capstone pefile
The exe is only read.
"""
from __future__ import annotations

import argparse
import re
import struct
from pathlib import Path

import capstone
import pefile

ROOT = Path(__file__).resolve().parents[2]

# Addresses identified by hand while reading the code (see docs/original_rules.md).
KNOWN = {
    0x433150: "fread",
    0x4336a0: "operator_new",
    0x433320: "_assert",
    0x434080: "sprintf",
    0x434ae0: "fopen",
    0x434480: "fclose",
    0x462608: "obCity",
    0x41bc50: "random_0_to_n",          # rand() * (n + 1) / 32768
    0x426710: "Person_totalAssets",
    0x404620: "Land_price",             # value_pct * uPrice_BLANK_LAND / 100
    0x403d30: "Land_rent",
    0x413e00: "Company_rent",           # rent * 2^(same-industry count - 1)
    0x4110b0: "House_cost",
    0x411810: "FunctionBuilding_cost",
    0x406120: "payRent",
    0x404730: "Land_comeHere",
    0x406970: "CompanyBase_comeHere",
    0x405080: "Road_passHere",          # thief steals / believer gives charity
    0x4056e0: "CrossRoad_passHere",     # turn to the arrow
    0x405730: "CrossRoad_newDay",       # re-roll arrow
    0x412620: "TaxHouse_comeHere",
    0x4139b0: "WatchManHouse_comeHere", # jail / bail
    0x413430: "Church_passHere",
    0x4132f0: "Church_comeHere",
    0x413880: "Park_comeHere",
    0x4135e0: "Government_comeHere",
    0x412810: "Bank_passHere",
    0x4158d0: "Gang_passHere",
    0x411e10: "FortuneTeller_comeHere",
    0x412310: "Pawnshop_comeHere",
    0x4282e0: "RaceCourse_comeHere",
    0x412e50: "Chance_comeHere",
    0x413f90: "showChancePicture",
    0x40dd30: "buildHouseAt",
    0x40df30: "upgradeHouseAt",
    0x40cc00: "removeHouseAt",
    0x40ce70: "mortgageAt",
    0x40d250: "unmortgageAt",
    0x4112c0: "House_fitsHere",
    0x40ffe0: "SingleLine_fitsHere",
    0x423ba0: "getMoveSteps",           # two dice, cheat code STEPxy
    0x423160: "Move_proc",
    0x423c80: "goNextPerson",           # new day, Saturday interest
    0x421e00: "turnStartStateCheck",
    0x424040: "removePersonProperty",
    0x427ae0: "PubSell_finish",
    0x422600: "setSentence",
}


class Exe:
    def __init__(self, path: Path):
        self.pe = pefile.PE(str(path))
        self.base = self.pe.OPTIONAL_HEADER.ImageBase
        self.img = self.pe.get_memory_mapped_image()
        text = self.pe.sections[0]
        self.tva = self.base + text.VirtualAddress
        self.code = text.get_data()[:text.Misc_VirtualSize]
        self.data_ranges = []
        for s in self.pe.sections[1:]:
            name = s.Name.rstrip(b"\0").decode()
            if name in (".rdata", ".data"):
                a = self.base + s.VirtualAddress
                self.data_ranges.append((a, a + s.Misc_VirtualSize))
        self.md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)

    def u32(self, va: int) -> int:
        return struct.unpack_from("<I", self.img, va - self.base)[0]

    def in_data(self, va: int) -> bool:
        return any(a <= va < b for a, b in self.data_ranges)

    def string_at(self, va: int) -> str | None:
        if not self.in_data(va):
            return None
        raw = self.img[va - self.base: va - self.base + 200].split(b"\0", 1)[0]
        if len(raw) < 2:
            return None
        try:
            s = raw.decode("gbk")
        except UnicodeDecodeError:
            return None
        if not all(c.isprintable() or c in "\n\t\r" for c in s):
            return None
        return s

    def thunk(self, va: int) -> int:
        """Follow a 'jmp rel32' stub of the incremental-linking table."""
        off = va - self.tva
        if 0 <= off < len(self.code) - 5 and self.code[off] == 0xE9:
            rel = struct.unpack_from("<i", self.code, off + 1)[0]
            return va + 5 + rel
        return va

    def name(self, va: int) -> str:
        t = self.thunk(va)
        if t in KNOWN:
            return KNOWN[t]
        return f"sub_{t:06x}"


def function_starts(exe: Exe) -> list[int]:
    """Start addresses: after padding runs, plus every thunk target."""
    starts = set()
    code = exe.code
    for m in re.finditer(rb"[\xcc\x90]{2,}", code):
        nxt = m.end()
        # MSVC aligns functions to 16 bytes; this also keeps a constant such
        # as 0xCCCCCCCD inside an instruction from looking like padding
        if nxt < len(code) and code[nxt] not in (0xCC, 0x90) and (exe.tva + nxt) % 16 == 0:
            starts.add(exe.tva + nxt)
    # thunk table at the start of .text: a run of E9 rel32
    off = 0
    while off < 0x2000 and code[off] == 0xE9:
        starts.add(exe.thunk(exe.tva + off))
        off += 5
    return sorted(s for s in starts if exe.tva <= s < exe.tva + len(code))


def annotate(exe: Exe, ins) -> str:
    notes = []
    for m in re.finditer(r"0x([0-9a-f]{6,8})", ins.op_str):
        v = int(m.group(1), 16)
        if ins.mnemonic == "call" or ins.mnemonic.startswith("j"):
            if exe.thunk(v) != v or exe.thunk(v) in KNOWN:
                notes.append(exe.name(v))
            continue
        s = exe.string_at(v)
        if s is not None:
            notes.append(repr(s))
        elif v in KNOWN:
            notes.append(KNOWN[v])
    return ("    ; " + " | ".join(notes)) if notes else ""


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--exe", default=str(ROOT / "shanghai1940" / "1940.exe"))
    ap.add_argument("--out", default="/tmp/1940.asm")
    a = ap.parse_args()
    exe = Exe(Path(a.exe))
    starts = function_starts(exe)
    lines = []
    for i, s in enumerate(starts):
        end = starts[i + 1] if i + 1 < len(starts) else exe.tva + len(exe.code)
        lines.append(f"\n==== func 0x{s:06x}")
        off = s - exe.tva
        for ins in exe.md.disasm(exe.code[off:end - exe.tva], s):
            if ins.mnemonic == "int3":
                continue
            lines.append(f"{ins.address:06x}: {ins.mnemonic} {ins.op_str}{annotate(exe, ins)}")
    Path(a.out).write_text("\n".join(lines), encoding="utf-8")
    print(f"{len(starts)} functions -> {a.out}")


if __name__ == "__main__":
    main()
