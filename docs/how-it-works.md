# How it works

Technical notes. You do not need any of this to use the addon — see the
[README](../README.md) for that.

## The problem

WoW addons have no networking. The Lua sandbox has no sockets, no HTTP, nothing.
SavedVariables only reach disk on logout or `/reload`. So an addon cannot ask a
website anything, and cannot be told an answer.

The loop is closed through two channels that need neither.

| Leg | Channel | Mechanism |
|---|---|---|
| Game → PC | **screenshot** | The addon paints the payload as a grid of flat-coloured squares in the corner of the screen and calls `Screenshot()`. With `screenshotFormat=png` the file on disk is lossless. |
| PC → internet | **Playwright** | A real Chromium session drives questionablyepic.com/live: import the SimC string, press GO!, read the winning set off the page. |
| PC → Game | **LoadOnDemand addon** | The agent rewrites `Payload.lua` inside a LoD stub. WoW reads a LoD addon's Lua from disk *at `LoadAddOn()` time*, so fresh data arrives mid-session. |

## The pixel protocol

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
that does not carry the ruler and a valid `QEAG` magic — your own screenshots
are untouched, and never reported as corrupt.

## The return leg

The agent writes the same payload into **all 24 inbox stubs** at once. That
removes the need for a handshake in the direction we cannot talk: the addon
loads whichever slot it likes, whenever it likes, and finds either `pending` or
the answer. Each stub can only be loaded once per session, so 24 is the budget
per login; `/reload` resets it. `/qeg diag` shows what is left.

Liveness is judged on payload freshness, not presence — the stubs keep their
last contents on disk indefinitely, so a leftover from a previous session would
otherwise read as a running agent. WoW's `time()` is real epoch time and the
agent stamps `ts` the same way, so they compare directly.

## In game

**Scanner** reads every equipped and bagged item: stats, item level, tier set id,
unique-equipped, weapon DPS off the tooltip (there is no API for it), and whether
red tooltip text says you cannot use it.

**Export** builds a SimulationCraft-format string — class, level, race, region,
realm, spec, talent import string, all 16 equipped items with bonus/gem/enchant/
crafted-stat ids, plus the `### Gear from Bags` block. This is the exact format
QE Live's `IMPORT GEAR` box wants.

**Optimizer** matches each recommended item id back to a *physical* item you own,
in four passes: already-equipped-and-exact-bonus first, then loosening. If QE
Live is unreachable it falls back to scoring locally against stat weights,
handling ring and trinket pairs, unique-equipped, two-handers vs. dual wield
(including Titan's Grip), and tier set bonuses.

**Equipper** re-resolves each item's location immediately before moving it, so
ring and trinket shuffles cannot lose an item mid-swap, and refuses to run in
combat — it queues and finishes when you drop out.

## Things that had to be got right

Recorded so they are not undone by accident. Every one of these was found by
running the thing, not by reading it.

- **WoW runs Lua 5.1** — no `&`, `>>`, `~` or `//`. Use the `bit` library and
  `math.floor`. `tools/luacheck.py` catches regressions, and proves the runtime
  really is 5.1 before trusting a pass.
- **`SetIgnoreParentScale` does not give raw pixels.** At 0.711 uiScale a
  nominal 10px cell renders at ~14px. Cell size must always be measured.
- **Screenshot filenames have one-second resolution.** Frames captured closer
  than that overwrite each other and the job hangs forever waiting on a frame
  that no longer exists.
- **QE Live's buttons carry descriptive `aria-label`s** that override their
  visible text, so `get_by_role(name=...)` cannot find "Import Gear". Match on
  text content.
- **Importing only auto-selects equipped gear.** Bag items arrive unselected, so
  Top Gear has nothing to compare against, and with no weapon selected `GO!`
  stays disabled and shows no error at all. The agent clicks the rest of the
  pool in — with real mouse events, each card scrolled into view, since React
  ignores synthetic clicks and offscreen cards cannot be clicked.
- **Retail item strings can contain a crafterGUID** (`Player-1084-0AB6C7D2`).
  A digits-only pattern fails the whole match on the first letter and silently
  drops that item from the export.
- **Trinket and ring slots are interchangeable.** Anything already worn keeps
  its current slot, or the plan proposes swapping two trinkets with each other
  for no gain.

## Development

`tools/luacheck.py` compiles every addon file under a real Lua 5.1 runtime.
`tools/selftest.py` round-trips the screenshot protocol without WoW — multi
frame, 4K, a 75% downscale, JPEG rejection, and ignoring unrelated screenshots.
CI runs both on every push.

The QE Live leg is deliberately not in CI: it drives a live third-party site, so
a red build would mean "the site changed", not "this commit is broken". Check it
by hand with `python -m qeagent --show-browser`. Every failure leaves a
screenshot, the page HTML and the exact SimC string in `~/.qeagent/debug/`.

Verified end to end on a live client (Preservation Evoker, 12.1.0.69497,
August 2026). A full run takes about 12 seconds.
