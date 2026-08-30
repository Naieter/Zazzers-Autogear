"""Read the addon's on-screen data grid back out of a screenshot.

Protocol (must stay in lockstep with addon/QEAutoGear/Bridge.lua):

  grid          64 cols x 16 rows of CELL-pixel squares, anchored to the
                top-left corner of the game window
  row 0         the ruler: magenta at column 0, cyan at column 63. Cell size is
                measured across that 62-cell span, not from one square, so a
                sub-pixel error cannot compound across the grid.
  rows 1..15    three 4-bit nibbles each, one per colour channel, at 17 units
                per step, so every channel has +/-8 of slack

  byte stream   "QEAG" | proto u8 | flags u8 | frame u16 | frames u16 |
                len u16 | job u32 | crc16 u16 | <chunk>
"""

from __future__ import annotations

import struct
from dataclasses import dataclass, field

import numpy as np
from PIL import Image

MAGIC = b"QEAG"
COLS, ROWS = 64, 16
DATA_START = 64  # row 0 is the ruler
HEADER_LEN = 18
NOMINAL_CELL = 10

MAGENTA = np.array([255, 0, 255], dtype=np.int16)
CYAN = np.array([0, 255, 255], dtype=np.int16)
SEARCH = 600  # only the top-left corner can contain the grid


class DecodeError(Exception):
    """Something was wrong with an image that carries our locator."""


class NotOurImage(DecodeError):
    """Not one of our frames.

    Anything that fails before the QEAG magic is verified. A normal game
    screenshot contains plenty of magenta-ish pixels, so a partial ruler match
    is not evidence of a corrupted frame - only a matched magic is.
    """


def _crc16(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc & 0xFFFF


def _locate(px: np.ndarray) -> tuple[int, int, float]:
    """Find the grid origin, then measure cell size across the whole ruler row."""
    corner = px[:SEARCH, :SEARCH].astype(np.int16)
    mask = np.abs(corner - MAGENTA).max(axis=2) <= 40
    if not mask.any():
        raise NotOurImage("no ruler origin found")

    ys, xs = np.nonzero(mask)
    y0, x0 = int(ys.min()), int(xs.min())

    run = 0
    row = mask[min(y0 + 1, mask.shape[0] - 1)]
    while x0 + run < row.shape[0] and row[x0 + run]:
        run += 1
    if run < 2:
        raise NotOurImage(f"ruler origin too small ({run}px)")

    # Scan the middle of the ruler row for the far marker.
    scan_y = min(y0 + max(1, run // 2), px.shape[0] - 1)
    line = px[scan_y].astype(np.int16)
    cyan = np.nonzero(np.abs(line - CYAN).max(axis=1) <= 60)[0]
    cyan = cyan[cyan > x0 + run]
    if cyan.size == 0:
        raise NotOurImage("ruler end marker not found")

    span = int(cyan.min()) - x0
    cell = span / (COLS - 1)
    if cell < 2:
        raise NotOurImage(f"cell size {cell:.2f}px is too small to sample")
    if not 0.6 < cell / run < 1.7:
        raise NotOurImage(f"ruler disagrees: span implies {cell:.2f}px, origin is {run}px")

    return x0, y0, cell


def _sample(px: np.ndarray, x0: int, y0: int, cell: float) -> np.ndarray:
    """Median of a small window at each cell's true centre.

    Centres are computed in float and rounded per cell rather than stepped by a
    truncated integer, so positioning error cannot accumulate across the 64
    columns. That matters when the client renders below native resolution and a
    cell is only a few pixels wide.
    """
    out = np.zeros((COLS * ROWS, 3), dtype=np.uint8)
    half = max(0, int(cell * 0.22))
    h, w = px.shape[0], px.shape[1]
    for i in range(COLS * ROWS):
        c, r = i % COLS, i // COLS
        cx = int(round(x0 + (c + 0.5) * cell))
        cy = int(round(y0 + (r + 0.5) * cell))
        y1, y2 = max(0, cy - half), min(h, cy + half + 1)
        x1, x2 = max(0, cx - half), min(w, cx + half + 1)
        patch = px[y1:y2, x1:x2]
        if patch.size == 0:
            continue
        out[i] = np.median(patch.reshape(-1, patch.shape[-1])[:, :3], axis=0)
    return out


def _to_bytes(cells: np.ndarray) -> bytes:
    nibbles = np.clip(np.rint(cells[DATA_START:, :3].astype(np.float32) / 17.0), 0, 15)
    flat = nibbles.reshape(-1).astype(np.uint8)
    if len(flat) % 2:
        flat = flat[:-1]
    return bytes((flat[0::2] << 4) | flat[1::2])


@dataclass
class Frame:
    proto: int
    flags: int
    index: int
    total: int
    job: int
    chunk: bytes


def decode_image(path) -> Frame:
    with Image.open(path) as im:
        px = np.asarray(im.convert("RGB"))

    x0, y0, cell = _locate(px)
    raw = _to_bytes(_sample(px, x0, y0, cell))

    if raw[:4] != MAGIC:
        raise NotOurImage(f"bad magic {raw[:4]!r} (ruler at {x0},{y0} cell {cell:.1f})")

    proto, flags, index, total, length, job, crc = struct.unpack_from(">BBHHHIH", raw, 4)
    chunk = raw[HEADER_LEN:HEADER_LEN + length]
    if len(chunk) != length:
        raise DecodeError(f"truncated chunk: wanted {length}, got {len(chunk)}")
    if length and _crc16(chunk) != crc:
        raise DecodeError("crc mismatch - screenshot was resampled or compressed lossily")

    return Frame(proto, flags, index, total, job, chunk)


@dataclass
class Assembler:
    """Collects multi-frame transmissions until a job is complete."""

    jobs: dict[int, dict[int, bytes]] = field(default_factory=dict)
    totals: dict[int, int] = field(default_factory=dict)

    def add(self, frame: Frame) -> str | None:
        parts = self.jobs.setdefault(frame.job, {})
        parts[frame.index] = frame.chunk
        self.totals[frame.job] = frame.total

        if len(parts) < frame.total:
            return None

        payload = b"".join(parts[i] for i in range(frame.total))
        self.jobs.pop(frame.job, None)
        self.totals.pop(frame.job, None)
        return payload.decode("utf-8", errors="replace")

    def progress(self, job: int) -> tuple[int, int]:
        return len(self.jobs.get(job, {})), self.totals.get(job, 0)
