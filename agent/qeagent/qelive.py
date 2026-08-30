"""Drive questionablyepic.com/live with a real browser and read the answer back.

QE Live is a client-side app with no public API, so the only honest way to get
a Top Gear result is to do what a person does: paste the SimC string into the
import dialog, press GO!, and read the winning set off the page.

Selectors verified against the live site (August 2026):
  header spec picker   div.MuiSelect-select
  import dialog opener button whose TEXT is "Import Gear". Note its aria-label
                       is "Insert a SimC string to import your gear.", which
                       overrides the accessible name - so these must be matched
                       on text content, never with get_by_role(name=...).
  paste box            textarea#simcentry
  confirm              button with text "SUBMIT"
  run                  button with text "GO!"
Results are scraped through the Wowhead links QE renders for every item, which
survives cosmetic redesigns far better than a class-name selector would.
"""

from __future__ import annotations

import re
import time
from dataclasses import dataclass

from playwright.sync_api import TimeoutError as PWTimeout
from playwright.sync_api import sync_playwright

TOPGEAR_URL = "https://questionablyepic.com/live/topgear"

# WoW spec id -> words that must all appear in the QE Live spec label.
SPEC_KEYWORDS = {
    65: ("holy", "paladin"),
    105: ("resto", "druid"),
    256: ("disc", "priest"),
    257: ("holy", "priest"),
    264: ("resto", "shaman"),
    270: ("mistweaver", "monk"),
    1468: ("pres", "evoker"),
}

SPEC_FROM_SIMC = {
    ("paladin", "holy"): 65,
    ("druid", "restoration"): 105,
    ("priest", "discipline"): 256,
    ("priest", "holy"): 257,
    ("shaman", "restoration"): 264,
    ("monk", "mistweaver"): 270,
    ("evoker", "preservation"): 1468,
}

# Pull enough item ids out of the page to cover a full 16-slot set.
_EXTRACT_SET = """
() => {
  // The winning set is the topmost container holding a full set's worth of
  // items. The "Close Alternatives" panels further down also render item
  // icons, so anchoring on the highest such container is what keeps their
  // items from being mixed into the answer.
  const groups = new Map();
  document.querySelectorAll('a[href*="item="]').forEach(a => {
    let n = a.parentElement;
    for (let d = 0; d < 12 && n; d++, n = n.parentElement) {
      const c = n.querySelectorAll('a[href*="item="]').length;
      if (c >= 12 && c <= 20) { groups.set(n, c); break; }
    }
  });
  if (!groups.size) return { set: [], total: 0 };
  const best = [...groups.keys()]
    .sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top)[0];
  const items = [];
  best.querySelectorAll('a[href*="item="]').forEach(a => {
    const src = a.getAttribute('href') || a.getAttribute('data-wowhead') || '';
    const m = src.match(/item=(\d+)/);
    if (!m) return;
    const wh = a.getAttribute('data-wowhead') || '';
    const bonus = (wh.match(/bonus=([\d:]+)/) || [])[1] || '';
    items.push({ id: parseInt(m[1], 10), bonus: bonus.replace(/:/g, '/') });
  });
  return { set: items, total: groups.get(best) };
}
"""

_EXTRACT_WEIGHTS = """
() => {
  const text = document.body.innerText;
  const stats = ['Intellect','Critical Strike','Crit','Haste','Mastery','Versatility','Leech'];
  const out = {};
  stats.forEach(s => {
    const re = new RegExp(s + '\\\\s*[:=]?\\\\s*([0-9]*\\\\.?[0-9]+)', 'i');
    const m = text.match(re);
    if (m) out[s.toLowerCase()] = parseFloat(m[1]);
  });
  return out;
}
"""


@dataclass
class Result:
    ok: bool
    items: list[dict]
    weights: dict
    gain: float | None = None
    note: str = ""
    error: str = ""


def spec_from_simc(simc: str) -> int | None:
    """Read the spec back out of the string we generated in game."""
    cls = None
    spec = None
    for line in simc.splitlines():
        line = line.strip()
        m = re.match(r"^([a-z_]+)=\"", line)
        if m and cls is None and m.group(1) not in ("spec", "talents", "role", "level"):
            cls = m.group(1)
        if line.startswith("spec="):
            spec = line.split("=", 1)[1].strip()
    if cls and spec:
        return SPEC_FROM_SIMC.get((cls, spec))
    return None


class QELive:
    """A warm browser session. Keeping the page alive makes a run take seconds."""

    def __init__(self, headless: bool = True, profile_dir=None, timeout: int = 120):
        self.headless = headless
        self.profile_dir = profile_dir
        self.timeout = timeout * 1000
        self._pw = None
        self._ctx = None
        self._page = None

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, *exc):
        self.stop()

    def start(self):
        self._pw = sync_playwright().start()
        if self.profile_dir:
            self._ctx = self._pw.chromium.launch_persistent_context(
                str(self.profile_dir), headless=self.headless,
                viewport={"width": 1600, "height": 1000},
            )
            self._page = self._ctx.pages[0] if self._ctx.pages else self._ctx.new_page()
        else:
            browser = self._pw.chromium.launch(headless=self.headless)
            self._ctx = browser.new_context(viewport={"width": 1600, "height": 1000})
            self._page = self._ctx.new_page()
        self._page.set_default_timeout(self.timeout)
        self._goto_topgear()

    def stop(self):
        for closer in (self._ctx, self._pw):
            try:
                closer.close() if closer else None
            except Exception:
                pass
        self._pw = self._ctx = self._page = None

    # -- page plumbing ----------------------------------------------------

    def _goto_topgear(self):
        page = self._page
        page.goto(TOPGEAR_URL, wait_until="domcontentloaded")
        page.wait_for_timeout(1500)
        self._dismiss_welcome()

    def _btn(self, pattern, root=None):
        """Match buttons on visible text. get_by_role uses the accessible name,
        which QE Live overrides with descriptive aria-labels."""
        return (root or self._page).locator("button").filter(has_text=pattern)

    def _dismiss_welcome(self):
        """First visit shows an era/class chooser behind a BEGIN! button."""
        page = self._page
        try:
            begin = self._btn(re.compile(r"^begin!?$", re.I))
            if begin.count() and begin.first.is_visible():
                begin.first.click()
                page.wait_for_timeout(1200)
        except Exception:
            pass

    def _select_spec(self, spec_id: int) -> bool:
        words = SPEC_KEYWORDS.get(spec_id)
        if not words:
            return False
        page = self._page

        current = page.evaluate(
            "() => { const e = document.querySelector('.MuiSelect-select');"
            " return e ? e.innerText.trim() : ''; }"
        )
        if all(w in current.lower() for w in words):
            return True

        page.click(".MuiSelect-select")
        page.wait_for_timeout(400)
        options = page.locator("li[role='option'], [role='option']")
        for i in range(options.count()):
            label = (options.nth(i).inner_text() or "").lower()
            if all(w in label for w in words):
                options.nth(i).click()
                page.wait_for_timeout(1200)
                return True
        page.keyboard.press("Escape")
        return False

    def _import(self, simc: str, options: dict):
        page = self._page
        buttons = self._btn(re.compile(r"import\s+gear", re.I))
        if not buttons.count():
            raise RuntimeError("no Import Gear button on the page")
        buttons.last.click()
        page.wait_for_selector("textarea#simcentry", timeout=15000)

        page.fill("textarea#simcentry", simc)

        dialog = page.locator("[role='dialog']")
        for label, want in options.items():
            try:
                box = dialog.get_by_label(re.compile(label, re.I))
                if box.count() and box.first.is_checked() != want:
                    box.first.click()
            except Exception:
                pass

        self._btn(re.compile(r"^submit$", re.I), dialog).last.click()
        page.wait_for_timeout(2500)

    def _select_all(self) -> tuple[int, int]:
        """Put every imported item into the candidate pool.

        Importing only auto-selects what was equipped, so Top Gear would other-
        wise have nothing from the bags to compare against - and with no weapon
        selected it refuses to run at all. A selected card has a goldenrod 3px
        border; unselected is grey. React ignores synthetic .click(), and cards
        below the fold cannot be clicked at all, so each one is scrolled to the
        middle of the viewport and clicked with a real mouse event.
        """
        page = self._page
        next_card = """() => {
          const SEL = 'rgb(218, 165, 32)';
          for (const a of document.querySelectorAll('a[href*="item="]')) {
            let n = a, card = null;
            for (let d = 0; d < 10 && n; d++) { n = n.parentElement;
              if (n && /MuiCard-root/.test(n.className || '')) { card = n; break; } }
            if (!card) continue;
            if (getComputedStyle(card).borderColor === SEL) continue;
            card.scrollIntoView({ block: 'center' });
            const r = card.getBoundingClientRect();
            if (r.width < 10) continue;
            return { x: r.x, y: r.y, w: r.width, h: r.height };
          }
          return null;
        }"""
        clicked = 0
        for _ in range(80):
            box = page.evaluate(next_card)
            if not box:
                break
            # 55% across lands on the item name, clear of the Wowhead anchor on
            # the left and the settings cog on the right.
            page.mouse.click(box["x"] + box["w"] * 0.55, box["y"] + box["h"] / 2)
            clicked += 1
            page.wait_for_timeout(120)
        page.wait_for_timeout(1200)

        selected = total = 0
        m = re.search(r"Selected Items:\s*(\d+)\s*/\s*(\d+)", page.inner_text("body"))
        if m:
            selected, total = int(m.group(1)), int(m.group(2))
        return selected, total

    def _run(self) -> None:
        # Go! stays disabled until a gear set has actually been imported, so
        # this doubles as confirmation that the import was accepted.
        page = self._page
        page.wait_for_function(
            """() => { const b = [...document.querySelectorAll('button')]
                 .find(x => /^go!?$/i.test((x.textContent || '').trim()));
               return !!b && !b.disabled; }""",
            timeout=30000)
        self._btn(re.compile(r"^go!?$", re.I)).last.click()

    def _await_results(self, deadline: float) -> dict:
        page = self._page
        best = {"set": [], "total": 0}
        while time.time() < deadline:
            page.wait_for_timeout(1200)
            try:
                data = page.evaluate(_EXTRACT_SET)
            except Exception:
                continue
            if len(data.get("set", [])) >= 8:
                # Give the table one more beat to finish painting, then re-read.
                page.wait_for_timeout(1500)
                try:
                    data = page.evaluate(_EXTRACT_SET)
                except Exception:
                    pass
                return data
            if data.get("total", 0) > best["total"]:
                best = data
        return best

    # -- public API -------------------------------------------------------

    def run(self, simc: str, spec_id: int | None = None,
            import_options: dict | None = None) -> Result:
        page = self._page
        if page is None:
            return Result(False, [], {}, error="browser not started")

        spec_id = spec_id or spec_from_simc(simc)
        note = []

        try:
            self._goto_topgear()

            if spec_id and not self._select_spec(spec_id):
                note.append("could not switch spec on the site; used whatever was selected")

            self._import(simc, import_options or {})

            selected, total = self._select_all()
            if total:
                note.append(f"selected {selected}/{total} items")

            self._run()

            deadline = time.time() + (self.timeout / 1000)
            data = self._await_results(deadline)
            items = data.get("set", [])

            if not items:
                return Result(False, [], {}, error="QE Live returned no gear set "
                                                   "(import may have been rejected)")

            try:
                weights = page.evaluate(_EXTRACT_WEIGHTS)
            except Exception:
                weights = {}

            return Result(True, items[:18], weights, note="; ".join(note))

        except PWTimeout as exc:
            return Result(False, [], {}, error=f"timed out: {exc}")
        except Exception as exc:  # noqa: BLE001 - surfaced to the user in game
            return Result(False, [], {}, error=f"{type(exc).__name__}: {exc}")

    def screenshot(self, path):
        if self._page:
            self._page.screenshot(path=str(path), full_page=True)

    def page_html(self) -> str:
        return self._page.content() if self._page else ""
