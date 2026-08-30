"""Upload the built addon zip to CurseForge.

Reads its credentials from the environment so no token ever lands in the repo:

    CF_TOKEN    an API token from https://legacy.curseforge.com/account/api-tokens
    CF_PROJECT  the numeric project id, shown on the project page

Run by .github/workflows/release.yml when both are present as repository
secrets, and skipped entirely when they are not.

Deliberately dependency-free: it runs in a release job that should not need
anything the addon itself does not.
"""

from __future__ import annotations

import json
import mimetypes
import os
import re
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
API = "https://wow.curseforge.com/api"


def toc_value(key: str) -> str:
    toc = (ROOT / "addon" / "QEAutoGear" / "QEAutoGear.toc").read_text(encoding="utf-8")
    for line in toc.splitlines():
        if line.strip().startswith(f"## {key}:"):
            return line.split(":", 1)[1].strip()
    raise SystemExit(f"no '## {key}:' in the toc")


def interface_to_version(iface: str) -> str:
    """110207 -> 11.2.7, 120100 -> 12.1.0"""
    n = iface.strip()
    if len(n) != 5 and len(n) != 6:
        raise ValueError(iface)
    n = n.zfill(6)
    return f"{int(n[0:2])}.{int(n[2:4])}.{int(n[4:6])}"


def request(path: str, token: str, data=None, headers=None):
    req = urllib.request.Request(f"{API}{path}", data=data)
    req.add_header("X-Api-Token", token)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))


def game_version_ids(token: str, interfaces: list[str]) -> list[int]:
    """Map our declared interface numbers onto CurseForge's version ids."""
    versions = request("/game/versions", token)
    wanted = {interface_to_version(i) for i in interfaces}
    ids = [v["id"] for v in versions if v.get("name") in wanted]
    if not ids:
        available = sorted({v.get("name", "") for v in versions})[-6:]
        raise SystemExit(
            f"none of {sorted(wanted)} are known to CurseForge.\n"
            f"Most recent versions there: {available}\n"
            "Update '## Interface:' in the toc, or wait for CurseForge to add it."
        )
    return ids


def multipart(fields: dict[str, str], filepath: Path) -> tuple[bytes, str]:
    """Hand-rolled so this needs no third-party HTTP library."""
    boundary = uuid.uuid4().hex
    out = bytearray()
    for name, value in fields.items():
        out += f"--{boundary}\r\n".encode()
        out += f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode()
        out += value.encode("utf-8") + b"\r\n"

    ctype = mimetypes.guess_type(filepath.name)[0] or "application/octet-stream"
    out += f"--{boundary}\r\n".encode()
    out += (f'Content-Disposition: form-data; name="file"; '
            f'filename="{filepath.name}"\r\n').encode()
    out += f"Content-Type: {ctype}\r\n\r\n".encode()
    out += filepath.read_bytes() + b"\r\n"
    out += f"--{boundary}--\r\n".encode()
    return bytes(out), f"multipart/form-data; boundary={boundary}"


def main() -> int:
    token = os.environ.get("CF_TOKEN", "").strip()
    project = os.environ.get("CF_PROJECT", "").strip()
    if not token or not project:
        print("CF_TOKEN / CF_PROJECT are not set - nothing to upload.")
        return 0

    version = toc_value("Version")
    interfaces = [x.strip() for x in toc_value("Interface").split(",")]

    zips = sorted((ROOT / "dist").glob("QEAutoGear-*.zip"))
    if not zips:
        raise SystemExit("no zip in dist/ - run tools/package.py first")
    zip_path = zips[-1]

    changelog = (ROOT / "CHANGELOG.md")
    notes = changelog.read_text(encoding="utf-8") if changelog.exists() else version

    ids = game_version_ids(token, interfaces)
    print(f"uploading {zip_path.name} for game version ids {ids}")

    metadata = {
        "changelog": notes,
        "changelogType": "markdown",
        "displayName": f"QE AutoGear {version}",
        "gameVersions": ids,
        "releaseType": "release",
    }
    body, content_type = multipart({"metadata": json.dumps(metadata)}, zip_path)

    try:
        result = request(f"/projects/{project}/upload-file", token, data=body,
                         headers={"Content-Type": content_type})
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:500]
        print(f"CurseForge rejected the upload ({exc.code}):\n{detail}", file=sys.stderr)
        return 1

    print(f"uploaded. file id {result.get('id')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
