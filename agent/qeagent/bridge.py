"""Filesystem side of the bridge: find WoW, and write results back into the game.

Results travel back in through LoadOnDemand stub addons. WoW reads a LoD addon's
Lua from disk at the moment LoadAddOn() is called, so rewriting Payload.lua gets
fresh data into a running session with no /reload.

We write the same payload into every unused stub. That way the addon can load
whichever slot it likes, whenever it likes, and still find the answer - no
handshake needed in the direction we cannot talk.
"""

from __future__ import annotations

import os
import tempfile
from pathlib import Path

SLOT_COUNT = 24
ADDON_NAME = "QEAutoGear"

WOW_HINTS = [
    r"C:\Program Files (x86)\World of Warcraft",
    r"C:\Program Files\World of Warcraft",
    r"D:\World of Warcraft",
    r"D:\Games\World of Warcraft",
    r"S:\World of Warcraft",
    r"C:\Games\World of Warcraft",
]

FLAVORS = ["_retail_", "_xptr_", "_ptr_", "_beta_"]


def find_wow(explicit: str | None = None) -> Path:
    """Locate the WoW flavour directory (the one containing Interface/)."""
    if explicit:
        p = Path(explicit)
        if (p / "Interface").is_dir():
            return p
        for flavor in FLAVORS:
            if (p / flavor / "Interface").is_dir():
                return p / flavor
        raise FileNotFoundError(f"{p} does not look like a WoW install")

    for hint in WOW_HINTS:
        base = Path(hint)
        if not base.is_dir():
            continue
        for flavor in FLAVORS:
            if (base / flavor / "Interface").is_dir():
                return base / flavor

    raise FileNotFoundError(
        "could not find World of Warcraft - pass --wow <path to _retail_>"
    )


def addons_dir(wow: Path) -> Path:
    return wow / "Interface" / "AddOns"


def screenshots_dir(wow: Path) -> Path:
    d = wow / "Screenshots"
    d.mkdir(exist_ok=True)
    return d


# ---------------------------------------------------------------------------
# Lua serialisation
# ---------------------------------------------------------------------------

def _lua_string(s: str) -> str:
    out = s.replace("\\", "\\\\").replace('"', '\\"')
    out = out.replace("\n", "\\n").replace("\r", "")
    return f'"{out}"'


def lua_value(value) -> str:
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(round(value, 6) if isinstance(value, float) else value)
    if isinstance(value, str):
        return _lua_string(value)
    if isinstance(value, (list, tuple)):
        return "{ " + ", ".join(lua_value(v) for v in value) + " }"
    if isinstance(value, dict):
        parts = []
        for key, val in value.items():
            safe = str(key).isidentifier()
            label = str(key) if safe else f"[{_lua_string(str(key))}]"
            parts.append(f"{label} = {lua_value(val)}")
        return "{ " + ", ".join(parts) + " }"
    return _lua_string(str(value))


PAYLOAD_TEMPLATE = """-- Written by qeagent. Do not edit by hand.
if QEAutoGear_Ingest then
    QEAutoGear_Ingest({body})
end
"""


def slot_name(i: int) -> str:
    return f"{ADDON_NAME}_P{i:02d}"


def stub_toc(i: int) -> str:
    return (
        "## Interface: 120100, 120000, 110207\n"
        f"## Title: QE AutoGear Inbox {i:02d}\n"
        "## Author: Nathan\n"
        "## Version: 1.0.0\n"
        "## LoadOnDemand: 1\n"
        f"## Dependencies: {ADDON_NAME}\n"
        "\n"
        "Payload.lua\n"
    )


def ensure_stubs(addons: Path, count: int = SLOT_COUNT) -> int:
    """Create the LoD inbox addons if they are not already there."""
    made = 0
    for i in range(1, count + 1):
        folder = addons / slot_name(i)
        folder.mkdir(parents=True, exist_ok=True)
        toc = folder / f"{slot_name(i)}.toc"
        if not toc.exists() or toc.read_text(encoding="utf-8") != stub_toc(i):
            toc.write_text(stub_toc(i), encoding="utf-8")
            made += 1
        payload = folder / "Payload.lua"
        if not payload.exists():
            _atomic_write(payload, PAYLOAD_TEMPLATE.format(
                body=lua_value({"proto": 1, "job": 0, "status": "idle"})))
    return made


def _atomic_write(path: Path, text: str) -> None:
    """Never let the game read a half-written payload."""
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def publish(addons: Path, data: dict, count: int = SLOT_COUNT) -> int:
    """Drop the same payload into every inbox slot."""
    text = PAYLOAD_TEMPLATE.format(body=lua_value(data))
    written = 0
    for i in range(1, count + 1):
        folder = addons / slot_name(i)
        if not folder.is_dir():
            continue
        _atomic_write(folder / "Payload.lua", text)
        written += 1
    return written
