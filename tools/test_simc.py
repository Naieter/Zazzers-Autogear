"""Test the SimulationCraft output parsing without needing simc installed.

The exact shape of simc's json2 has moved between versions, so the parser hunts
for the scale factors rather than indexing a fixed path. These fixtures cover
the shapes seen in the wild plus the naming variants (crit vs crit_rating), and
one deliberately wrong document to prove a miss is reported rather than
silently returning nothing useful.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "agent"))

from qeagent.simc import _walk_for_dps, _walk_for_scale_factors, normalise  # noqa: E402

NESTED = {
    "sim": {
        "players": [{
            "name": "Zazzers",
            "collected_data": {"dps": {"mean": 1234567.8}},
            "scale_factors": {
                "int": 1.0, "crit_rating": 0.41, "haste_rating": 0.53,
                "mastery_rating": 0.38, "versatility_rating": 0.44,
            },
        }]
    }
}

FLAT_NAMES = {
    "sim": {"players": [{
        "scale_factors": {
            "agility": 8.42, "crit": 3.10, "haste": 4.02,
            "mastery": 2.88, "vers": 3.30, "wdps": 5.61,
        },
    }]}
}

DEEPER = {"a": {"b": [{"c": {"players": [{"scale_factors": {"str": 2.0, "crit": 1.0}}]}}]}}

NO_FACTORS = {"sim": {"players": [{"collected_data": {"dps": {"mean": 5.0}}}]}}


def check(name, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + ("" if ok else f"  {detail}"))
    return ok


def main() -> int:
    ok = True

    print("standard json2 shape")
    sf = _walk_for_scale_factors(NESTED)
    w, raw = normalise(sf)
    ok &= check("finds scale factors", sf is not None)
    ok &= check("primary normalised to 1.0", w.get("intellect") == 1.0, str(w))
    ok &= check("_rating suffix stripped", w.get("crit") == 0.41 and w.get("haste") == 0.53, str(w))
    ok &= check("reads dps", _walk_for_dps(NESTED) == 1234567.8)

    print("short stat names, unnormalised values")
    w, _ = normalise(_walk_for_scale_factors(FLAT_NAMES))
    ok &= check("agility becomes 1.0", w.get("agility") == 1.0, str(w))
    ok &= check("others scaled to it", abs(w.get("crit", 0) - 3.10 / 8.42) < 1e-4, str(w))
    ok &= check("weapon dps mapped", "weaponDPS" in w, str(w))

    print("factors buried somewhere unexpected")
    w, _ = normalise(_walk_for_scale_factors(DEEPER))
    ok &= check("still found", w.get("strength") == 1.0, str(w))

    print("no scale factors at all")
    ok &= check("reports a miss", _walk_for_scale_factors(NO_FACTORS) is None)

    print("junk values are ignored, not crashed on")
    w, _ = normalise({"int": 1.0, "crit": None, "notes": "hello", "haste": 0.5})
    ok &= check("survives", w == {"intellect": 1.0, "haste": 0.5}, str(w))

    print("\n" + ("ALL PASS" if ok else "FAILURES ABOVE"))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
