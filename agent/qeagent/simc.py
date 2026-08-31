"""Run SimulationCraft locally to get stat weights.

Healers sim on QE Live, which is JavaScript in a browser and costs the site
nothing to automate. Everyone else sims on Raidbots, which runs SimulationCraft
on hardware they pay for and whose robots.txt asks automation to stay off the
API -- so this runs the same engine on your own machine instead. Same maths, no
one else's compute, no rate limit, and it works offline.

simc is asked for scale factors rather than a gear comparison. Comparing every
combination of what is in your bags would take hours; scale factors take one
run, and the addon already knows how to pick the best set from a set of weights.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

# Where a Windows user is most likely to have unzipped it.
CANDIDATE_DIRS = [
    Path(r"C:\Program Files\SimulationCraft"),
    Path(r"C:\Program Files (x86)\SimulationCraft"),
    Path(r"C:\SimulationCraft"),
    Path(r"D:\SimulationCraft"),
    Path.home() / "SimulationCraft",
    Path.home() / "Downloads" / "SimulationCraft",
]

# simc's own names for stats, mapped onto the addon's. Keys are matched after
# lowercasing and dropping a trailing "_rating", so both "crit" and
# "crit_rating" land on the same place.
STAT_ALIASES = {
    "int": "intellect", "intellect": "intellect",
    "agi": "agility", "agility": "agility",
    "str": "strength", "strength": "strength",
    "sta": "stamina", "stamina": "stamina",
    "crit": "crit", "critical_strike": "crit",
    "haste": "haste",
    "mastery": "mastery",
    "vers": "versatility", "versatility": "versatility",
    "leech": "leech",
    "speed": "speed",
    "avoidance": "avoidance",
    "wdps": "weaponDPS", "weapon_dps": "weaponDPS",
    "weapon_offhand_dps": "weaponOffhandDPS",
}

PRIMARIES = ("intellect", "agility", "strength")


@dataclass
class SimCResult:
    ok: bool
    weights: dict = field(default_factory=dict)
    raw_keys: list = field(default_factory=list)
    dps: float | None = None
    seconds: float | None = None
    error: str = ""


def find_exe(explicit: str | None = None) -> Path | None:
    """Locate simc.exe: an explicit path, then PATH, then the usual folders."""
    if explicit:
        p = Path(explicit)
        if p.is_file():
            return p
        if p.is_dir():
            for name in ("simc.exe", "simc"):
                if (p / name).is_file():
                    return p / name
        return None

    found = shutil.which("simc") or shutil.which("simc.exe")
    if found:
        return Path(found)

    for base in CANDIDATE_DIRS:
        if not base.is_dir():
            continue
        for name in ("simc.exe", "simc"):
            if (base / name).is_file():
                return base / name
        # Release zips unpack into a versioned subfolder.
        for child in sorted(base.glob("*/simc.exe")) + sorted(base.glob("*/simc")):
            if child.is_file():
                return child
    return None


def _walk_for_scale_factors(node):
    """Find the scale factors wherever simc decided to put them.

    The exact shape of json2 has moved between simc versions, so this looks for
    the key rather than assuming a path through the document.
    """
    if isinstance(node, dict):
        sf = node.get("scale_factors")
        if isinstance(sf, dict) and sf:
            return sf
        for value in node.values():
            found = _walk_for_scale_factors(value)
            if found:
                return found
    elif isinstance(node, list):
        for value in node:
            found = _walk_for_scale_factors(value)
            if found:
                return found
    return None


def _walk_for_dps(node):
    if isinstance(node, dict):
        collected = node.get("collected_data")
        if isinstance(collected, dict):
            dps = collected.get("dps")
            if isinstance(dps, dict) and "mean" in dps:
                return float(dps["mean"])
        for value in node.values():
            found = _walk_for_dps(value)
            if found is not None:
                return found
    elif isinstance(node, list):
        for value in node:
            found = _walk_for_dps(value)
            if found is not None:
                return found
    return None


def normalise(scale_factors: dict) -> tuple[dict, list]:
    """simc's stat names to the addon's, normalised so the primary stat is 1.0."""
    out, raw = {}, sorted(scale_factors.keys())
    for key, value in scale_factors.items():
        if not isinstance(value, (int, float)):
            continue
        name = str(key).strip().lower().replace(" ", "_")
        if name.endswith("_rating"):
            name = name[: -len("_rating")]
        mapped = STAT_ALIASES.get(name)
        if mapped:
            out[mapped] = float(value)

    primary = next((out[p] for p in PRIMARIES if out.get(p)), None)
    if primary and primary > 0:
        out = {k: round(v / primary, 4) for k, v in out.items()}
    return out, raw


class SimC:
    def __init__(self, exe: Path | None = None, target_error: float = 0.3,
                 threads: int = 0, timeout: int = 900):
        self.exe = exe
        self.target_error = target_error
        self.threads = threads or (os.cpu_count() or 4)
        self.timeout = timeout

    def available(self) -> bool:
        return self.exe is not None and Path(self.exe).is_file()

    def scale_factors(self, simc_profile: str) -> SimCResult:
        if not self.available():
            return SimCResult(False, error="simc not found")

        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            profile = tmp / "character.simc"
            out_json = tmp / "result.json"
            profile.write_text(simc_profile, encoding="utf-8")

            cmd = [
                str(self.exe), str(profile),
                "calculate_scale_factors=1",
                f"target_error={self.target_error}",
                f"threads={self.threads}",
                f"json2={out_json}",
                "html=",           # nothing to render
                "iterations=0",    # let target_error decide when to stop
            ]

            import time
            started = time.time()
            try:
                proc = subprocess.run(cmd, capture_output=True, text=True,
                                      timeout=self.timeout)
            except subprocess.TimeoutExpired:
                return SimCResult(False, error=f"simc timed out after {self.timeout}s")
            elapsed = time.time() - started

            if not out_json.exists():
                tail = (proc.stderr or proc.stdout or "").strip()[-400:]
                return SimCResult(False, error=f"simc produced no output:\n{tail}")

            try:
                data = json.loads(out_json.read_text(encoding="utf-8", errors="replace"))
            except json.JSONDecodeError as exc:
                return SimCResult(False, error=f"could not read simc output: {exc}")

        sf = _walk_for_scale_factors(data)
        if not sf:
            return SimCResult(False, error="simc ran but reported no scale factors "
                                           "(the profile may have failed to load)")

        weights, raw = normalise(sf)
        if not any(weights.get(p) for p in PRIMARIES):
            return SimCResult(False, raw_keys=raw,
                              error=f"no primary stat among simc's factors: {raw}")

        return SimCResult(True, weights=weights, raw_keys=raw,
                          dps=_walk_for_dps(data), seconds=elapsed)
