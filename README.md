# QE AutoGear

Scans your gear, race and spec in game, runs it through **Questionably Epic Live**,
and equips the winning set out of your bags. No copying, no pasting, no `/reload`.

```
/qeg run
```

---

## How it closes the loop

WoW addons have no networking — the Lua sandbox has no sockets, no HTTP, nothing.
SavedVariables only reach disk on logout or `/reload`. So the loop is closed
through two channels that do not need either.

| Leg | Channel | Mechanism |
|---|---|---|
| Game → PC | **screenshot** | The addon paints the payload as a grid of flat-coloured squares in the corner of the screen and calls `Screenshot()`. With `screenshotFormat=png` the file on disk is lossless. |
| PC → internet | **Playwright** | A real Chromium session drives questionablyepic.com/live: import the SimC string, press GO!, read the resulting set off the page. |
| PC → Game | **LoadOnDemand addon** | The agent rewrites `Payload.lua` inside a LoD stub. WoW reads a LoD addon's Lua from disk *at `LoadAddOn()` time*, so fresh data arrives mid-session. |

### The pixel protocol

A 64 × 16 grid of 10px cells anchored to the top-left of the window
(`SetIgnoreParentScale(true)`, so UI scale cannot smear it).

- Row 0 is a **ruler**: magenta at column 0, cyan at column 63. Cell size is
  measured across that 62-cell span, never from a single square — a sub-pixel
  error in one square compounds to several cells of drift by the far edge when
  the client renders below native resolution.
- Every other cell carries **three 4-bit nibbles**, one per colour channel, at
  17 units per step. That leaves ±8 of slack per channel — enough to survive
  render scaling and colour management, not enough to survive JPEG (which is why
  the addon forces PNG and the decoder checks a CRC).
- Frame = `"QEAG" | proto | flags | frame u16 | frames u16 | len u16 | job u32 |
  crc16 | chunk`, giving **1422 payload bytes per screenshot**. A full character
  with bags is 2–4 frames, captured **1.2s apart** — WoW names screenshots to
  one-second resolution, so faster than that and two frames collide on the same
  filename and the later one destroys the earlier.

The agent deletes the grid screenshots after decoding, and ignores any image
that does not carry the ruler and a valid QEAG magic — your own screenshots
are untouched, and never reported as corrupt.

### The return leg

The agent writes the same payload into **all 24 inbox stubs** at once. That
removes the need for a handshake in the direction we cannot talk: the addon
loads whichever slot it likes, whenever it likes, and finds either `pending` or
the answer. Each stub can only be loaded once per session, so 24 is the budget
per login; `/reload` resets it. `/qeg diag` shows what is left.

---

## Install

```bash
python tools/install.py
cd agent && pip install -r requirements.txt && playwright install chromium
python -m qeagent
```

`install.py` finds your WoW install, copies the addon, and generates the 24 inbox
stubs. Pass `--wow "D:/World of Warcraft/_retail_"` if auto-detection misses, or
`--link` to junction the folder instead of copying while you are editing it.

Leave `python -m qeagent` running in a terminal. Then in game:

| Command | Does |
|---|---|
| `/qeg` | open the panel |
| `/qeg run` | the whole loop: export → QE Live → equip |
| `/qeg local` | optimise from stored stat weights only, no round trip |
| `/qeg equip` | apply the last result |
| `/qeg autoequip on` | swap without asking |
| `/qeg autorun on` | re-run automatically on loot and spec change |
| `/qeg bank on` | include bank items |
| `/qeg export` | show the SimC string to paste in by hand |
| `/qeg diag` | is the agent connected, slots left, capacity |

With `autoequip` and `autorun` both on, looting an upgrade re-runs QE Live and
re-gears you without you touching anything.

---

## What it actually does in game

**Scanner** reads every equipped and bagged item: stats, item level, tier set id,
unique-equipped, weapon DPS off the tooltip (there is no API for it), and whether
red tooltip text says you cannot use it.

**Export** builds a SimulationCraft-format string — class, level, race, region,
realm, spec, talent import string, all 16 equipped items with bonus/gem/enchant/
crafted-stat ids, plus the `### Gear from Bags` block. This is the exact format
QE Live's `IMPORT GEAR` box wants.

**Optimizer** takes QE Live's winning set and matches each item id back to a
*physical* item you own, preferring an exact bonus-id match so an upgraded copy
is never confused with a base one. If QE Live is unreachable it falls back to
scoring locally against stat weights, handling ring and trinket pairs,
unique-equipped, two-handers vs. dual wield (including Titan's Grip), and tier
set bonuses.

**Equipper** re-resolves each item's location immediately before moving it, so
ring and trinket shuffles cannot lose an item mid-swap, and refuses to run in
combat — it queues and finishes when you drop out.

---

## Known limits — read these

**QE Live models healers only.** Verified against the live site: Holy Paladin,
Restoration Druid, Discipline Priest, Holy Priest, Restoration Shaman, Mistweaver
Monk, Preservation Evoker. On any other spec `/qeg run` says so and falls back to
the local optimizer. That is a limit of the site, not the addon.

**The screenshot bridge needs the game rendering.** Windowed, borderless or
fullscreen all work, but a minimised client paints nothing. The addon switches
`screenshotFormat` to `png` for the capture and restores your setting afterwards.

**The LoD hot-read is load-bearing, and confirmed.** The return leg depends on
WoW reading a LoadOnDemand addon's Lua from disk at `LoadAddOn()` time rather
than from a login-time cache. Verified directly: a nonce written to the stubs
*after* login was read back mid-session with no reload. If it ever stops
holding, the symptom is unmistakable — `/qeg run` sends fine and then times out
with *"no answer from the QE agent"* while the agent's terminal shows the job
completing. `/qeg export` and the paste-weights box still work in that case.

**The scraper reads a site that can change.** Selectors were checked against QE
Live in August 2026 (`textarea#simcentry`, SUBMIT, GO!), and the results scrape
goes through the Wowhead `item=` links QE renders, which survives redesigns far
better than class names. If it breaks, run `python -m qeagent --show-browser` to
watch what the automation is doing.

**Verified on a live client** (Preservation Evoker, 12.1.0.69497, Aug 2026):
capture, decode, LoadOnDemand hot-read, QE Live import, Top Gear, and the
scrape all work end to end. A full run is about 12 seconds. `tools/selftest.py`
passes all six cases; run it first if you change the protocol.

Things that had to be got right, recorded so they are not undone by accident:

- **WoW runs Lua 5.1** — no `&`, `>>`, `~` or `//`. Use the `bit` library and
  `math.floor`. `lupa`'s `lua51` runtime will catch a regression here.
- **`SetIgnoreParentScale` does not give raw pixels.** At 0.711 uiScale a
  nominal 10px cell renders at ~14px. Cell size must always be measured, never
  assumed.
- **QE Live's buttons carry descriptive `aria-label`s** that override their
  visible text, so `get_by_role(name=...)` cannot find "Import Gear". Match on
  text content.
- **Importing only auto-selects equipped gear.** Bag items arrive unselected, so
  Top Gear has nothing to compare against, and with no weapon selected `GO!`
  stays disabled and shows no error. The agent clicks the rest of the pool in —
  with real mouse events, each card scrolled into view, since React ignores
  synthetic clicks and offscreen cards cannot be clicked at all.
- **Retail item strings can contain a crafterGUID** (`Player-1084-0AB6C7D2`).
  A digits-only pattern fails the whole match on the first letter and silently
  drops that item from the export.
- **Trinket and ring slots are interchangeable.** Anything already worn keeps
  its current slot, or the plan proposes swapping two trinkets with each other
  for no gain.

**The scraper reads a site that can change.** If it breaks, run
`python -m qeagent --show-browser` to watch, and check `~/.qeagent/debug/` —
every failure leaves a screenshot, the page HTML, and the exact SimC string.
