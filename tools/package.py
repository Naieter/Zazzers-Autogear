"""Build the addon zip that gets uploaded to CurseForge.

Only the addon goes in. The companion helper cannot ship through CurseForge --
it installs addon folders and nothing else, so there is no way to deliver
Python, a browser, or a background process through it. The addon detects that
it is running without the helper and falls back to the manual QE Live route.

    python tools/package.py            # build dist/QEAutoGear-<version>.zip
    python tools/package.py --check    # verify only, build nothing
"""

from __future__ import annotations

import argparse
import re
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ADDON = ROOT / "addon" / "QEAutoGear"
DIST = ROOT / "dist"
TOC = ADDON / "QEAutoGear.toc"


def read_toc() -> tuple[str, list[str], list[str]]:
    """Return (version, declared interface numbers, declared file list)."""
    version, interfaces, files = None, [], []
    for raw in TOC.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line.startswith("## Version:"):
            version = line.split(":", 1)[1].strip()
        elif line.startswith("## Interface:"):
            interfaces = [x.strip() for x in line.split(":", 1)[1].split(",")]
        elif line and not line.startswith("#"):
            files.append(line)
    if not version:
        raise SystemExit("no '## Version:' in the toc")
    return version, interfaces, files


def check() -> list[str]:
    """Every problem that would ship a broken addon to strangers."""
    problems = []
    version, interfaces, files = read_toc()

    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        problems.append(f"version '{version}' is not X.Y.Z")
    if not interfaces:
        problems.append("no interface version declared")

    # A file listed in the toc but missing is a load error for every user.
    for name in files:
        if not (ADDON / name).exists():
            problems.append(f"toc lists {name}, which does not exist")

    # A Lua file on disk that the toc forgets is worse: it silently does nothing.
    listed = {f.lower() for f in files}
    for path in sorted(ADDON.glob("*.lua")):
        if path.name.lower() not in listed:
            problems.append(f"{path.name} exists but the toc does not load it")

    return problems


def build() -> Path:
    version, _, files = read_toc()
    DIST.mkdir(exist_ok=True)
    out = DIST / f"QEAutoGear-{version}.zip"

    # The zip must contain a single top-level QEAutoGear/ folder: that is what
    # every WoW addon manager expects to drop into Interface/AddOns.
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(TOC, "QEAutoGear/QEAutoGear.toc")
        for name in files:
            z.write(ADDON / name, f"QEAutoGear/{name}")

    return out


# Everything the launcher needs, and nothing that only matters in the repo.
FULL_INCLUDE = ["Run QE AutoGear.bat", "Auto-start on or off.bat",
                "README.md", "CHANGELOG.md", "LICENSE"]
FULL_TREES = ["addon", "agent", "tools", "docs"]
FULL_SKIP = {"__pycache__", ".deps-ok", "_selftest"}


def build_full() -> Path:
    """The whole thing: addon, helper, launcher.

    Without this the Releases page handed people an addon with no helper and
    no way to get one, while the README told them /qeg run does everything.
    """
    version, _, _ = read_toc()
    DIST.mkdir(exist_ok=True)
    out = DIST / f"QEAutoGear-Full-{version}.zip"
    root = f"QEAutoGear-Full-{version}"

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for name in FULL_INCLUDE:
            src = ROOT / name
            if src.exists():
                z.write(src, f"{root}/{name}")
        for tree in FULL_TREES:
            for src in sorted((ROOT / tree).rglob("*")):
                rel = src.relative_to(ROOT)
                if src.is_file() and not any(part in FULL_SKIP for part in rel.parts):
                    z.write(src, f"{root}/{rel.as_posix()}")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true", help="verify only")
    args = ap.parse_args()

    problems = check()
    for p in problems:
        print(f"  [FAIL] {p}")
    if problems:
        print(f"\n{len(problems)} problem(s) - not building")
        return 1
    print("  [ok] toc and files agree")

    if args.check:
        return 0

    for out in (build(), build_full()):
        with zipfile.ZipFile(out) as z:
            names = z.namelist()
        print()
        print(f"built {out.relative_to(ROOT)}  "
              f"({out.stat().st_size:,} bytes, {len(names)} files)")

    # The launcher is the entire point of the full zip; never ship it without.
    with zipfile.ZipFile(DIST / f"QEAutoGear-Full-{read_toc()[0]}.zip") as z:
        names = z.namelist()
    for required in ("Run QE AutoGear.bat", "agent/qeagent/daemon.py",
                     "addon/QEAutoGear/Core.lua", "tools/install.py"):
        if not any(n.endswith(required) for n in names):
            print(f"  [FAIL] full zip is missing {required}")
            return 1
    print("  [ok] full zip has the launcher, helper, addon and installer")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
