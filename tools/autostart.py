"""Start the helper automatically when Windows starts.

Puts a shortcut in the Startup folder. That is the least surprising place to
put it: it is visible, it needs no admin rights, and a user can delete it by
hand without knowing anything about this project.

    python tools/autostart.py            # say whether it is on
    python tools/autostart.py --enable
    python tools/autostart.py --disable
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LAUNCHER = ROOT / "Run QE AutoGear.bat"
SHORTCUT_NAME = "QE AutoGear.lnk"


def startup_dir() -> Path:
    appdata = os.environ.get("APPDATA")
    if not appdata:
        raise RuntimeError("APPDATA is not set - is this Windows?")
    return Path(appdata) / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "Startup"


def shortcut_path() -> Path:
    return startup_dir() / SHORTCUT_NAME


def _powershell(script: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
        capture_output=True, text=True,
    )


def enable() -> int:
    if not LAUNCHER.exists():
        print(f"error: cannot find {LAUNCHER.name} next to this project")
        return 2

    target = shortcut_path()
    target.parent.mkdir(parents=True, exist_ok=True)

    # WindowStyle 7 is minimised: the helper needs to keep running, but it does
    # not need to take over the screen every time you log in.
    script = (
        f"$s = (New-Object -ComObject WScript.Shell).CreateShortcut('{target}');"
        f"$s.TargetPath = '{LAUNCHER}';"
        f"$s.WorkingDirectory = '{ROOT}';"
        "$s.WindowStyle = 7;"
        "$s.Description = 'Starts the QE AutoGear helper';"
        "$s.Save()"
    )
    result = _powershell(script)
    if result.returncode != 0 or not target.exists():
        print("error: could not create the shortcut")
        if result.stderr.strip():
            print(result.stderr.strip()[:300])
        return 1

    print("Auto-start is ON.")
    print(f"  {target}")
    print("The helper will start minimised whenever you log in to Windows.")
    return 0


def disable() -> int:
    target = shortcut_path()
    if target.exists():
        target.unlink()
        print("Auto-start is OFF. The shortcut has been removed.")
    else:
        print("Auto-start was already off.")
    return 0


def status() -> int:
    target = shortcut_path()
    if target.exists():
        print("Auto-start is ON.")
        print(f"  {target}")
    else:
        print("Auto-start is OFF.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    group = ap.add_mutually_exclusive_group()
    group.add_argument("--enable", action="store_true")
    group.add_argument("--disable", action="store_true")
    args = ap.parse_args()

    if sys.platform != "win32":
        print("Auto-start is Windows only.")
        return 2

    if args.enable:
        return enable()
    if args.disable:
        return disable()
    return status()


if __name__ == "__main__":
    raise SystemExit(main())
