"""Compile every addon file under a real Lua 5.1 runtime.

WoW runs Lua 5.1. The 5.3 operators (`&`, `|`, `~`, `>>`, `<<`, `//`) are a
syntax error there, but they parse fine in any newer Lua and in your head, so
this class of bug reaches the client silently and breaks the addon at load.

Before trusting the result, the check proves itself: it feeds the runtime two
snippets that 5.1 must reject. If those compile, the runtime is not 5.1 and a
pass here would mean nothing.
"""

from __future__ import annotations

import sys
from pathlib import Path

ADDON = Path(__file__).resolve().parent.parent / "addon" / "QEAutoGear"

# Must NOT compile under 5.1. If any of these pass, the guard is worthless.
POISON = [
    ("bitwise and", "local x = 5 & 3"),
    ("integer division", "local x = 7 // 2"),
    ("right shift", "local x = 8 >> 1"),
]


def main() -> int:
    try:
        from lupa import lua51
    except ImportError:
        print("lupa is not installed - run: pip install lupa", file=sys.stderr)
        return 2

    runtime = lua51.LuaRuntime()
    load = runtime.eval("loadstring or load")

    def compile_(source: str, chunkname: str):
        result = load(source, "@" + chunkname)
        # lupa returns either the function or a (nil, message) pair.
        if isinstance(result, tuple):
            return result[0], result[1]
        return result, None

    print("verifying the runtime really is Lua 5.1")
    for name, snippet in POISON:
        fn, _ = compile_(snippet, "poison")
        if fn is not None:
            print(f"  [BAD] {name} compiled - this runtime is not 5.1, "
                  f"the check below proves nothing", file=sys.stderr)
            return 2
        print(f"  [ok] rejects {name}")

    files = sorted(ADDON.glob("*.lua"))
    if not files:
        print(f"no Lua files found in {ADDON}", file=sys.stderr)
        return 2

    print(f"\nchecking {len(files)} file(s) in {ADDON.name}")
    failed = 0
    for path in files:
        fn, err = compile_(path.read_text(encoding="utf-8"), path.name)
        if fn is None:
            failed += 1
            print(f"  [FAIL] {path.name}: {err}", file=sys.stderr)
        else:
            print(f"  [ok] {path.name}")

    print("\n" + ("ALL PASS" if not failed else f"{failed} FILE(S) FAILED"))
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
