"""Reader for .cit city/map files (Cit/*.cit and Sub/Story*.cit).

The layout below was taken from the game's own loader (City::load in 1940.exe,
found by disassembly) and cross-checked against identifier names left in the
developer's precompiled header (Map.lib, see docs/analysis.md).

File = CITY_PROPERTY (88 bytes)
     + int32 origin_x, int32 size           (map is size x size grid cells)
     + uint8 has_blocks
     + size*size block records              (x from origin_x, y from 0)
     + 128 building slots                   (int32 class id, 0 = empty)
     + 6 person slots                       (uint8 flag, 0 = empty)

Every block record starts with int32 class id, followed by fields read by
that class's load(); derived classes read their parent's fields first.
Every building record reads its own extra fields first, then the shared
Building fields.
"""
from __future__ import annotations

import struct
from pathlib import Path

from fw_formats import gbk

BLOCK_CLASSES = {
    0: "NONE", 1: "BASE", 2: "BLOCK", 3: "BUYABLE_BASE", 4: "COMPANY_BASE",
    5: "CROSS_ROAD", 6: "LAND", 7: "NULL_BLOCK", 8: "PUBLIC_BASE", 9: "ROAD",
    10: "SURFACE",
}

BUILDING_CLASSES = {
    0: "NONE", 1: "BANK", 2: "BUILDING", 3: "CASINO", 4: "CHANCE", 5: "CHURCH",
    6: "COMPANY", 7: "DOUBLE_LINE_BUILDING", 8: "FUNCTION_BUILDING",
    9: "GOVERNMENT", 10: "HOUSE", 11: "KKK_HOUSE", 12: "LAWER_HOUSE",
    13: "PARK", 14: "PUBLIC_SET", 15: "RACE_COURSE", 16: "RENT_HOUSE",
    17: "SINGLE_LINE_BUILDING", 18: "TAX_HOUSE", 19: "WATCH_MAN_HOUSE",
}

PERSON_IDS = {
    0: "NV_XS 董莺雨", 1: "LIU_LE 四毛", 2: "MAI_B 包德利", 3: "FU_JXJ 陈玛丽",
    4: "JIAO_JH 赛珍珠", 5: "HEI_B 冯全篾", 6: "WAI_GR 发达而", 7: "BAO_SP 金如山",
    8: "PERSON_NONE",
}

COMPANY_GROUPS = {
    0: "TRANSPORT 运输业", 1: "PUBLIC 公共事业", 2: "FOOD 饮食业",
    3: "CIGARETTE 烟草业", 4: "NEWSPAPER 报社", 5: "WEAVING 纺织业",
    6: "SHOP 商业", 7: "ENTERTAINMENT 娱乐业",
}

BUILDING_SPRITE_KINDS = [
    "FLAT_HOUSE", "HOTEL_HOUSE", "SUPER_HOTEL_HOUSE", "FLOOR_HOUSE",
    "SUPER_FLOOR_HOUSE", "VILLA_HOUSE", "TAX_HOUSE", "KKK_HOUSE", "LAWER_HOUSE",
    "RENT_HOUSE", "RAIL_ROAD", "YARD", "ELECTRIC_BUS_COM", "LAMP_COM",
    "COAL_COM", "TELEPHONE_COM", "WATER_COM", "FOOD_COM", "CIGARETTE_COM",
    "NEWSPAPER_OFFICE", "WEAVING_COM", "SHOP", "NIGHTCLUB", "PARK", "CHANCE",
    "BANK", "CHURCH", "WATCHMAN_HOUSE", "GOVERMENT", "CASINO", "RACE_COURSE",
]

# Field order of CITY_PROPERTY, as declared in const.h (names from the PCH).
CITY_PROPERTY_FIELDS = [
    "uCost_FLAT_HOUSE", "uCost_HOTEL_HOUSE", "uCost_FLOOR_HOUSE",
    "uCost_VILLA_HOUSE", "uCost_UPDATE", "uCost_FUNCTION_HOUSE",
    "uRent_BLANK_LAND", "uRent_FLAT_HOUSE", "uRent_HOTEL_HOUSE",
    "uRent_SUPER_HOTEL_HOUSE", "uRent_FLOOR_HOUSE", "uRent_SUPER_FLOOR_HOUSE",
    "uRent_VILLA_HOUSE", "uPrice_BLANK_LAND",
]


class Reader:
    def __init__(self, data: bytes):
        self.d = data
        self.p = 0

    def take(self, n: int) -> bytes:
        if self.p + n > len(self.d):
            raise EOFError(f"need {n} bytes at {self.p}, file is {len(self.d)}")
        b = self.d[self.p:self.p + n]
        self.p += n
        return b

    def i32(self) -> int:
        return struct.unpack("<i", self.take(4))[0]

    def i16(self) -> int:
        return struct.unpack("<h", self.take(2))[0]

    def u8(self) -> int:
        return self.take(1)[0]

    def text(self, n: int) -> str:
        return gbk(self.take(n))


def _block_core(r: Reader, rec: dict) -> None:
    # Block::load reads field +0xA then +0x8: grid x then grid y
    rec["x"] = r.i16()
    rec["y"] = r.i16()


def _base(r: Reader, rec: dict) -> None:
    _block_core(r, rec)
    rec["building_index"] = r.i32()   # +0x10, index into the building list
    rec["frame"] = r.i16()            # +0x0C, which slice of the building sprite


def _buyable(r: Reader, rec: dict) -> None:
    _base(r, rec)
    rec["owner"] = r.i32()            # +0x14, PERSON_ID of owner, 8 = nobody


def _road(r: Reader, rec: dict) -> None:
    _block_core(r, rec)
    rec["road_frame"] = r.i16()       # +0x0C
    rec["road_1"] = r.i16()           # +0x0E


def read_block(r: Reader) -> dict:
    cls = r.i32()
    rec: dict = {"class": BLOCK_CLASSES.get(cls, f"UNKNOWN_{cls}")}
    if cls in (2, 7):                         # BLOCK, NULL_BLOCK
        _block_core(r, rec)
    elif cls in (1, 8):                       # BASE, PUBLIC_BASE
        _base(r, rec)
    elif cls in (3, 4):                       # BUYABLE_BASE, COMPANY_BASE
        _buyable(r, rec)
    elif cls == 9:                            # ROAD
        _road(r, rec)
    elif cls == 5:                            # CROSS_ROAD
        _road(r, rec)
        v = r.i32()
        rec["arrow_dir"] = v & 3              # dirArrowToward: N/E/S/W
        rec["arrow_prefer"] = v >> 2          # nArrowPrefer
    elif cls == 6:                            # LAND
        _buyable(r, rec)
        rec["land_flag"] = r.u8()             # +0x38, meaning not confirmed (mortgaged?)
        rec["name"] = r.text(32).strip()      # +0x18, street name
        rec["base_value_pct"] = r.i32()       # +0x40, not used by the price display; likely the original %
        rec["value_pct"] = r.i32()            # +0x3C, price = pct*uPrice_BLANK_LAND/100, rent = pct*uRent_BLANK_LAND/100
    elif cls == 10:                           # SURFACE
        _block_core(r, rec)
        rec["surface_frame"] = r.i16()        # +0x0C
        rec["surface_1"] = r.i16()            # +0x0E
        if r.u8():
            rec["decorate"] = r.i32()         # Decorate id (tree etc.)
    else:
        raise ValueError(f"unknown block class {cls} at {r.p - 4}")
    return rec


def read_building(r: Reader, cls: int) -> dict:
    rec: dict = {"class": BUILDING_CLASSES.get(cls, f"UNKNOWN_{cls}"), "class_id": cls}
    if cls == 10:                              # HOUSE: own field, then SingleLine
        rec["house_level"] = r.i32()           # +0x5C
        rec["line_value"] = r.i16()            # +0x58
    elif cls in (8, 11, 12, 16, 17):           # single-line family
        rec["line_value"] = r.i16()            # +0x58
    elif cls == 6:                             # COMPANY
        rec["company_flag"] = r.u8()           # +0x60, meaning not confirmed
        rec["company_group"] = r.i32()         # +0x64, COMPANY_GROUP (industry)
        n = r.i32()
        rec["describe"] = r.text(n) if n else ""
        rec["price"] = r.i32()                 # +0x58, purchase price (万圆)
        rec["rent"] = r.i32()                  # +0x5C, base rent (万圆)
    # shared Building::load
    rec["direction"] = r.i32()                 # +0x10, 0..3 = N/E/S/W (door facing)
    rec["owner"] = r.i32()                     # +0x04, PERSON_ID, 8 = nobody
    rec["sprite_kind"] = r.i32()               # +0x0C, BUILDING_SPRITE_KIND
    r.take(32)                                 # +0x14, uninitialised memory in shipped files
    rec["name"] = r.text(32).strip()           # +0x34, display name
    return rec


def read_person(r: Reader) -> dict:
    rec: dict = {"ai": r.u8()}  # bAIPlayer
    n = r.i32()
    rec["cards"] = [r.i32() for _ in range(n)]
    rec["value_9c"] = r.i32()
    rec["person_id"] = r.i32()                 # PERSON_ID (who this is)
    rec["grid"] = [r.i32(), r.i32()]
    rec["name"] = r.text(32).strip()
    rec["value_88"] = r.i32()
    rec["money_98"] = r.i32()                  # 2000 at start: cash or deposit (uCash/uDepot)
    rec["money_94"] = r.i32()
    rec["value_84"] = r.i32()
    rec["value_80"] = r.i32()
    return rec


def read_city(path: Path) -> dict:
    r = Reader(Path(path).read_bytes())
    city: dict = {"file": Path(path).name}
    city["name"] = r.text(16)
    city["ai_file"] = r.text(16)
    city["property"] = {k: r.i32() for k in CITY_PROPERTY_FIELDS}
    city["origin_x"] = r.i32()
    city["size"] = r.i32()
    blocks = []
    if r.u8():
        for _ in range(city["size"] * city["size"]):
            blocks.append(read_block(r))
    city["blocks"] = blocks
    buildings = []
    for slot in range(128):
        cls = r.i32()
        if cls:
            b = read_building(r, cls)
            b["slot"] = slot
            buildings.append(b)
    city["buildings"] = buildings
    persons = []
    for slot in range(6):
        if r.u8():
            p = read_person(r)
            p["slot"] = slot
            persons.append(p)
    city["persons"] = persons
    city["_bytes_read"] = r.p
    city["_bytes_total"] = len(r.d)
    return city
