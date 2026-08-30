"""Install QE AutoGear into WoW: copy the addon, create the inbox stubs.

    python tools/install.py                 # auto-detect the WoW install
    python tools/install.py --wow "D:/World of Warcraft/_retail_"
    python tools/install.py --link          # junction instead of copy (dev)
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "agent"))

from qeagent.bridge import ADDON_NAME, addons_dir, ensure_stubs, find_wow  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--wow", help="path to the _retail_ folder")
    ap.add_argument("--link", action="store_true",
                    help="make a directory junction instead of copying")
    ap.add_argument("--quiet", action="store_true",
                    help="skip the developer next-steps footer (used by the launcher)")
    args = ap.parse_args()

    try:
        wow = find_wow(args.wow)
    except FileNotFoundError as exc:
        print(f"error: {exc}")
        return 2

    addons = addons_dir(wow)
    source = ROOT / "addon" / ADDON_NAME
    target = addons / ADDON_NAME

    if not source.is_dir():
        print(f"error: {source} is missing")
        return 2

    if target.exists() or target.is_symlink():
        if target.is_symlink() or (target.is_dir() and not (target / "Util.lua").exists()):
            print(f"leaving existing {target} alone")
        else:
            shutil.rmtree(target)

    if args.link:
        subprocess.run(["cmd", "/c", "mklink", "/J", str(target), str(source)], check=True)
        print(f"junction: {target} -> {source}")
    elif not target.exists():
        shutil.copytree(source, target)
        print(f"copied:   {target}")

    made = ensure_stubs(addons)
    print(f"inbox:    {addons}\\{ADDON_NAME}_P01 .. _P24 ({made} written)")
    print(f"shots:    {wow / 'Screenshots'}")
    if not args.quiet:
        print()
        print("Next:")
        print("  cd agent && pip install -r requirements.txt && playwright install chromium")
        print("  python -m qeagent")
        print("Then in game: /qeg run")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
