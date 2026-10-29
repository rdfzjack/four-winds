"""Shared readers for the original "上海大富翁1940" (Shanghai 1940) data files.

Formats were reverse-engineered from the files themselves; see docs/analysis.md.
Every reader here only reads the original files, never writes to them.

    .col   palette: 8-byte header + 256 RGB triples (8-bit per channel)
    .pic   one image: 32-byte header + pixels (raw or RLE)
    .spr   sprite sheet: groups (animations / directions) of frames, each frame
           uses the same 32-byte header + RLE body as .pic
    .idx   9 recolor tables x 256 bytes (owner colors)
"""
from __future__ import annotations

import struct
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------- palette


def read_palette(path: Path) -> list[tuple[int, int, int]]:
    d = Path(path).read_bytes()
    if len(d) != 776:
        raise ValueError(f"{path}: expected 776 bytes, got {len(d)}")
    body = d[8:]
    return [tuple(body[i * 3:i * 3 + 3]) for i in range(256)]


def read_color_idx(path: Path) -> list[bytes]:
    d = Path(path).read_bytes()
    return [d[i * 256:(i + 1) * 256] for i in range(len(d) // 256)]


# ---------------------------------------------------------------- images

# RLE control bytes (per row, runs never cross a row end)
RLE_SHADOW = 0xF8   # F8 n      -> n shadow pixels (darken what is below)
RLE_LITERAL = 0xF9  # F9 n ...  -> n palette indices follow
RLE_SKIP = 0xFA     # FA n      -> n fully transparent pixels

# pixel kinds in a decoded frame
TRANSPARENT = -1
SHADOW = -2


@dataclass
class Frame:
    width: int
    height: int
    mode: int            # 0 = raw, 1/2 = RLE
    x: int               # header field 0 (screen position for .pic)
    y: int               # header field 1
    hot_x: int           # header field 2 (anchor / hotspot)
    hot_y: int           # header field 3
    prefix: int = 0      # 4-byte value before each .spr frame (step offset for walkers)
    pixels: list[int] = field(default_factory=list, repr=False)  # index, -1 or -2


def decode_body(body: bytes, w: int, h: int, mode: int) -> list[int]:
    if mode == 0:
        if len(body) < w * h:
            raise ValueError("raw body too short")
        return list(body[:w * h])
    out: list[int] = []
    p = 0
    n_body = len(body)
    while p < n_body:
        c = body[p]
        if c == RLE_LITERAL:
            n = body[p + 1]
            out.extend(body[p + 2:p + 2 + n])
            p += 2 + n
        elif c == RLE_SKIP:
            out.extend([TRANSPARENT] * body[p + 1])
            p += 2
        elif c == RLE_SHADOW:
            out.extend([SHADOW] * body[p + 1])
            p += 2
        else:
            raise ValueError(f"unknown RLE byte {c:#x} at {p}")
    if len(out) != w * h:
        raise ValueError(f"RLE decoded {len(out)} px, expected {w * h}")
    return out


def _frame_from_header(hdr: tuple, body: bytes, prefix: int = 0) -> Frame:
    x, y, hx, hy, size, mode, h, w = hdr
    return Frame(w, h, mode, x, y, hx, hy, prefix, decode_body(body, w, h, mode))


def read_pic(path: Path) -> Frame:
    d = Path(path).read_bytes()
    hdr = struct.unpack_from("<8i", d, 0)
    size = hdr[4]
    if 32 + size != len(d):
        raise ValueError(f"{path}: size field {size} does not match file")
    return _frame_from_header(hdr, d[32:32 + size])


@dataclass
class Sprite:
    default_group: int
    header_extra: tuple[int, int]   # two fields that look like leftover memory
    groups: list[list[Frame]]
    group_params: list[int]


def read_spr(path: Path) -> Sprite:
    d = Path(path).read_bytes()
    default_group, n_groups, e1, e2 = struct.unpack_from("<4i", d, 0)
    p = 16
    groups, params = [], []
    for _ in range(n_groups):
        gparam, n_frames = struct.unpack_from("<2i", d, p)
        p += 8
        frames = []
        for _ in range(n_frames):
            prefix = struct.unpack_from("<i", d, p)[0]
            hdr = struct.unpack_from("<8i", d, p + 4)
            p += 36
            frames.append(_frame_from_header(hdr, d[p:p + hdr[4]], prefix))
            p += hdr[4]
        groups.append(frames)
        params.append(gparam)
    if p != len(d):
        raise ValueError(f"{path}: parsed {p} of {len(d)} bytes")
    return Sprite(default_group, (e1, e2), groups, params)


def frame_to_image(frame: Frame, palette, shadow_alpha: int = 110):
    """Return a PIL RGBA image. Shadow pixels become translucent black."""
    from PIL import Image

    img = Image.new("RGBA", (frame.width, frame.height))
    px = []
    for v in frame.pixels:
        if v == TRANSPARENT:
            px.append((0, 0, 0, 0))
        elif v == SHADOW:
            px.append((0, 0, 0, shadow_alpha))
        else:
            r, g, b = palette[v]
            px.append((r, g, b, 255))
    img.putdata(px)
    return img


# ---------------------------------------------------------------- text


def gbk(b: bytes) -> str:
    """Decode a NUL-terminated GBK byte string."""
    return b.split(b"\0", 1)[0].decode("gbk", errors="replace")
