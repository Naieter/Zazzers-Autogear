"""Round-trip the screenshot bridge without WoW.

Reimplements exactly what Bridge.lua paints, renders it into an image the same
size as a real screenshot, and feeds it to the decoder the agent uses. Also
checks the awkward cases: multi-frame payloads, a downscaled render, and JPEG
compression (which must be rejected, not silently mis-decoded).
"""

from __future__ import annotations

import io
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "agent"))

from qeagent.decode import (COLS, DATA_START, HEADER_LEN, MAGIC, ROWS,  # noqa: E402
                            Assembler, DecodeError, decode_image)

CELL = 10


def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc & 0xFFFF


def capacity() -> int:
    return (COLS * ROWS - DATA_START) * 3 // 2 - HEADER_LEN


def build_stream(chunk: bytes, index: int, total: int, job: int) -> bytes:
    out = bytearray(MAGIC)
    out += bytes([1, 0])
    out += index.to_bytes(2, "big")
    out += total.to_bytes(2, "big")
    out += len(chunk).to_bytes(2, "big")
    out += job.to_bytes(4, "big")
    out += (crc16(chunk) if chunk else 0).to_bytes(2, "big")
    out += chunk
    return bytes(out)


def paint(stream: bytes, canvas=(1920, 1080)) -> Image.Image:
    """Mirror of Bridge.lua's paint(): three nibbles per cell, 17 per step."""
    img = Image.new("RGB", canvas, (24, 18, 30))  # non-black, like a real game frame
    px = np.asarray(img).copy()

    nibbles = []
    for byte in stream:
        nibbles.append(byte >> 4)
        nibbles.append(byte & 0x0F)

    colours = [(0, 0, 0)] * DATA_START
    colours[0] = (255, 0, 255)
    colours[COLS - 1] = (0, 255, 255)
    for i in range(0, len(nibbles), 3):
        trio = (nibbles[i:i + 3] + [0, 0, 0])[:3]
        colours.append(tuple(n * 17 for n in trio))
    while len(colours) < COLS * ROWS:
        colours.append((0, 0, 0))

    for i, colour in enumerate(colours[:COLS * ROWS]):
        c, r = i % COLS, i // COLS
        px[r * CELL:(r + 1) * CELL, c * CELL:(c + 1) * CELL] = colour

    return Image.fromarray(px)


def send(text: str, job: int, canvas=(1920, 1080), transform=None):
    """Produce the images the addon would have produced for this payload."""
    cap = capacity()
    chunks = [text[i:i + cap].encode("utf-8") for i in range(0, len(text), cap)] or [b""]
    images = []
    for i, chunk in enumerate(chunks):
        img = paint(build_stream(chunk, i, len(chunks), job), canvas)
        if transform:
            img = transform(img)
        images.append(img)
    return images


def receive(images, tmp: Path):
    asm = Assembler()
    result = None
    for i, img in enumerate(images):
        path = tmp / f"shot{i}.png"
        img.save(path)
        frame = decode_image(path)
        result = asm.add(frame) or result
    return result


SAMPLE = """# QE AutoGear 1.0.0 - generated in game
# Holy Paladin

paladin="Testchar"
level=80
race=night_elf
region=us
server=area-52
role=attack
spec=holy
talents=CkEAd0dPTBiFVQJ3zMzMzMzMYGYmZmZmZmZmZGzMbjZmZmZGDA

head=,id=212446,bonus_id=6652/10356/1540,gem_id=213743,enchant_id=7052
neck=,id=215136,bonus_id=6652/10353,gem_id=213482/213497
shoulder=,id=212444,bonus_id=6652/10356
back=,id=222817,bonus_id=6652/10355,enchant_id=7403
chest=,id=212449,bonus_id=6652/10356,enchant_id=7364
wrist=,id=212443,bonus_id=6652/10355,crafted_stats=40/49
hands=,id=212448,bonus_id=6652/10356
waist=,id=212447,bonus_id=6652/10355
legs=,id=212445,bonus_id=6652/10356,enchant_id=7534
feet=,id=212442,bonus_id=6652/10355,enchant_id=7418
finger1=,id=215135,bonus_id=6652/10353,enchant_id=7340
finger2=,id=178926,bonus_id=6652/10353,enchant_id=7340
trinket1=,id=219314,bonus_id=6652/10353
trinket2=,id=212454,bonus_id=6652/10353
main_hand=,id=212437,bonus_id=6652/10356,enchant_id=7463
off_hand=,id=212439,bonus_id=6652/10356

### Gear from Bags
#
""" + "\n".join(
    f"# head=,id={210000 + i},bonus_id=6652/{10350 + i % 8}"
    for i in range(90)
)


def check(name, condition, detail=""):
    mark = "PASS" if condition else "FAIL"
    print(f"  [{mark}] {name}" + (f"  {detail}" if detail and not condition else ""))
    return condition


def main() -> int:
    tmp = Path(__file__).parent / "_selftest"
    tmp.mkdir(exist_ok=True)
    ok = True

    print(f"bridge capacity: {capacity()} bytes/frame")
    print(f"sample payload:  {len(SAMPLE)} bytes "
          f"-> {-(-len(SAMPLE) // capacity())} frame(s)\n")

    print("single frame, 1920x1080")
    small = SAMPLE[:capacity() - 10]
    got = receive(send(small, 111), tmp)
    ok &= check("round trip", got == small,
                f"got {len(got or '')} of {len(small)} bytes")

    print("multi frame, 1920x1080")
    got = receive(send(SAMPLE, 222), tmp)
    ok &= check("round trip", got == SAMPLE,
                f"got {len(got or '')} of {len(SAMPLE)} bytes")

    print("4K canvas")
    got = receive(send(SAMPLE, 333, canvas=(3840, 2160)), tmp)
    ok &= check("round trip", got == SAMPLE)

    print("render scale 75% (screenshot downscaled by the client)")
    scaled = receive(
        send(SAMPLE, 444, transform=lambda im: im.resize(
            (int(im.width * 0.75), int(im.height * 0.75)), Image.BILINEAR)),
        tmp)
    ok &= check("round trip", scaled == SAMPLE,
                f"got {len(scaled or '')} of {len(SAMPLE)} bytes")

    print("lossy JPEG must be rejected, never mis-decoded")

    def jpeg(im):
        buf = io.BytesIO()
        im.save(buf, "JPEG", quality=70)
        buf.seek(0)
        return Image.open(buf).convert("RGB")

    try:
        bad = receive(send(SAMPLE, 555, transform=jpeg), tmp)
        ok &= check("rejected or clean", bad is None or bad == SAMPLE,
                    "decoded to something wrong")
    except DecodeError:
        ok &= check("rejected or clean", True)

    print("unrelated screenshot is ignored")
    plain = tmp / "player.png"
    Image.new("RGB", (1920, 1080), (90, 120, 140)).save(plain)
    try:
        decode_image(plain)
        ok &= check("raises DecodeError", False)
    except DecodeError:
        ok &= check("raises DecodeError", True)

    for f in tmp.glob("*.png"):
        f.unlink()
    tmp.rmdir()

    print("\n" + ("ALL PASS" if ok else "FAILURES ABOVE"))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
