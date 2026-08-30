"""The companion agent.

Watches WoW's Screenshots folder, decodes anything the addon painted there,
runs it through QE Live in a real browser, and writes the winning gear set back
into the game's LoadOnDemand inbox. Nothing in the loop needs a human.
"""

from __future__ import annotations

import argparse
import sys
import time
import traceback
from pathlib import Path

from . import __version__
from .bridge import addons_dir, ensure_stubs, find_wow, publish, screenshots_dir
from .decode import Assembler, DecodeError, NotOurImage, decode_image
from .qelive import QELive, spec_from_simc

IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".tga"}

# Slot ids the addon uses, in the order QE Live lists a gear set.
SET_SLOT_ORDER = [1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17]

WEIGHT_KEYS = {
    "intellect": "intellect",
    "crit": "crit",
    "critical strike": "crit",
    "haste": "haste",
    "mastery": "mastery",
    "versatility": "versatility",
    "leech": "leech",
}


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def _normalise_weights(raw: dict) -> dict:
    out = {}
    for key, value in (raw or {}).items():
        mapped = WEIGHT_KEYS.get(str(key).lower())
        if mapped and isinstance(value, (int, float)) and 0 < value < 100:
            out[mapped] = float(value)
    # Only useful if we actually got a primary stat to normalise against.
    return out if "intellect" in out else {}


def _as_set(items: list[dict]) -> list[dict]:
    """Send ids and bonus ids only.

    QE Live lists the winning set in a two-column layout whose reading order is
    not slot order (the weapon lands seventh, before gloves), so any positional
    slot hint we attached would be wrong. The addon resolves each item to a
    legal slot itself.
    """
    out = []
    for item in items[:len(SET_SLOT_ORDER)]:
        entry = {"id": int(item["id"])}
        if item.get("bonus"):
            entry["bonus"] = str(item["bonus"])
        out.append(entry)
    return out


class Agent:
    def __init__(self, wow: Path, headless: bool = True, keep_shots: bool = False,
                 profile: Path | None = None, timeout: int = 120):
        self.wow = wow
        self.addons = addons_dir(wow)
        self.shots = screenshots_dir(wow)
        self.keep_shots = keep_shots
        self.assembler = Assembler()
        self.seen: set[Path] = set()
        self.result_until = 0.0
        self.qe = QELive(headless=headless, profile_dir=profile, timeout=timeout)

    # -- inbox ------------------------------------------------------------

    def announce_idle(self, force: bool = False) -> None:
        """Heartbeat, but never stomp a fresh result the game has not read yet."""
        if not force and time.time() < self.result_until:
            return
        publish(self.addons, {"proto": 1, "job": 0, "status": "idle",
                              "daemon": __version__, "ts": int(time.time())})

    def say(self, job: int, status: str, **extra) -> None:
        data = {"proto": 1, "job": job, "status": status,
                "daemon": __version__, "ts": int(time.time())}
        data.update(extra)
        publish(self.addons, data)
        if status in ("ok", "error"):
            # Hold the inbox steady long enough for the addon to poll it. The
            # idle heartbeat used to stomp errors before they were ever read.
            self.result_until = time.time() + 300

    # -- screenshots ------------------------------------------------------

    def _new_images(self) -> list[Path]:
        found = []
        for path in self.shots.iterdir():
            if path.suffix.lower() in IMAGE_SUFFIXES and path not in self.seen:
                # Skip anything still being written.
                try:
                    if time.time() - path.stat().st_mtime < 0.4:
                        continue
                except OSError:
                    continue
                found.append(path)
        return sorted(found, key=lambda p: p.stat().st_mtime)

    def _consume(self, path: Path) -> None:
        self.seen.add(path)
        if self.keep_shots:
            return
        try:
            path.unlink()
            self.seen.discard(path)
        except OSError:
            pass

    # -- the actual work --------------------------------------------------

    def handle(self, simc: str, job: int) -> None:
        # /qeg test rides the same channel, and a stray screenshot should never
        # cost a browser round trip. Require it to actually look like SimC.
        if "spec=" not in simc or "=,id=" not in simc:
            log(f"job {job}: not a gear export ({simc[:40]!r}...), ignoring")
            return

        spec = spec_from_simc(simc)
        lines = len([x for x in simc.splitlines() if x.strip()])
        log(f"job {job}: {len(simc)} bytes, {lines} lines, spec={spec}")

        self.say(job, "pending")

        started = time.time()
        result = self.qe.run(simc, spec_id=spec)
        elapsed = time.time() - started

        if not result.ok:
            log(f"job {job}: FAILED after {elapsed:.1f}s - {result.error}")
            # Headless failures are opaque, so leave evidence behind.
            debug = Path.home() / ".qeagent" / "debug"
            debug.mkdir(parents=True, exist_ok=True)
            try:
                self.qe.screenshot(debug / f"job{job}.png")
                (debug / f"job{job}.html").write_text(
                    self.qe.page_html(), encoding="utf-8", errors="replace")
                (debug / f"job{job}.simc").write_text(simc, encoding="utf-8")
                log(f"job {job}: wrote page state to {debug}")
            except Exception as exc:  # noqa: BLE001
                log(f"job {job}: could not capture debug state ({exc})")
            self.say(job, "error", err=result.error[:200])
            return

        gear = _as_set(result.items)
        weights = _normalise_weights(result.weights)
        log(f"job {job}: {len(gear)} items in {elapsed:.1f}s"
            + (f", {len(weights)} weights" if weights else ""))

        payload = {"set": gear, "note": result.note[:120]}
        if weights:
            payload["weights"] = weights
        self.say(job, "ok", **payload)

    def tick(self) -> None:
        for path in self._new_images():
            try:
                frame = decode_image(path)
            except NotOurImage:
                # A screenshot the player took themselves. Leave it alone.
                self.seen.add(path)
                continue
            except DecodeError as exc:
                # Carries our locator but would not decode - never silent, this
                # is a lost frame and the job will hang without it.
                log(f"CORRUPT FRAME {path.name}: {exc}")
                self.seen.add(path)
                continue
            except Exception as exc:  # noqa: BLE001
                log(f"decode error on {path.name}: {exc}")
                self.seen.add(path)
                continue

            got, total = self.assembler.progress(frame.job)
            log(f"frame {frame.index + 1}/{frame.total} of job {frame.job} "
                f"({len(frame.chunk)} bytes)")
            self._consume(path)

            simc = self.assembler.add(frame)
            if simc is not None:
                try:
                    self.handle(simc, frame.job)
                except Exception as exc:  # noqa: BLE001
                    log(f"job {frame.job} crashed: {exc}")
                    traceback.print_exc()
                    self.say(frame.job, "error", err=str(exc)[:200])

    def run(self, poll: float = 0.5) -> None:
        made = ensure_stubs(self.addons)
        log(f"WoW:         {self.wow}")
        log(f"screenshots: {self.shots}")
        log(f"inbox:       {self.addons} ({made} stub(s) refreshed)")
        log("starting browser...")
        self.qe.start()
        self.announce_idle(force=True)
        log(f"qeagent {__version__} ready - waiting for the addon.")

        last_beat = time.time()
        try:
            while True:
                self.tick()
                if time.time() - last_beat > 60:
                    self.announce_idle()
                    last_beat = time.time()
                time.sleep(poll)
        except KeyboardInterrupt:
            log("stopping.")
        finally:
            self.qe.stop()


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="qeagent", description=__doc__)
    ap.add_argument("--wow", help="path to the _retail_ folder")
    ap.add_argument("--show-browser", action="store_true",
                    help="run Chromium headful, useful when a selector breaks")
    ap.add_argument("--keep-screenshots", action="store_true",
                    help="do not delete the data-grid screenshots after decoding")
    ap.add_argument("--profile", help="persistent browser profile directory")
    ap.add_argument("--timeout", type=int, default=120, help="per-run timeout in seconds")
    ap.add_argument("--install", action="store_true",
                    help="create the inbox stub addons and exit")
    ap.add_argument("--decode", help="decode a single screenshot and print it, then exit")
    args = ap.parse_args(argv)

    if args.decode:
        frame = decode_image(Path(args.decode))
        print(f"job={frame.job} frame={frame.index + 1}/{frame.total} "
              f"bytes={len(frame.chunk)}")
        print(frame.chunk.decode("utf-8", errors="replace"))
        return 0

    try:
        wow = find_wow(args.wow)
    except FileNotFoundError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if args.install:
        made = ensure_stubs(addons_dir(wow))
        print(f"inbox stubs ready in {addons_dir(wow)} ({made} written)")
        return 0

    profile = Path(args.profile) if args.profile else Path.home() / ".qeagent" / "profile"
    profile.mkdir(parents=True, exist_ok=True)

    Agent(wow, headless=not args.show_browser, keep_shots=args.keep_screenshots,
          profile=profile, timeout=args.timeout).run()
    return 0
