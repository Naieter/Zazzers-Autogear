# QE AutoGear

[![CI](https://github.com/Naieter/Zazzers-Autogear/actions/workflows/ci.yml/badge.svg)](https://github.com/Naieter/Zazzers-Autogear/actions/workflows/ci.yml)

**Type `/qeg run` in World of Warcraft. It works out the best gear set you own
and puts it on.**

It does this by sending your gear to [Questionably Epic
Live](https://questionablyepic.com/live) — the site healers already use to
compare gear — running the numbers there, and equipping whatever wins. You never
copy, paste, or open a browser.

---

## Before you start

**Healers and everyone else take different routes.** Healers sim on
[Questionably Epic Live](https://questionablyepic.com/live), which the helper
drives for you with nothing to install. Every other spec sims on
**SimulationCraft**, which you install once (below) and which then runs on your
own machine — same engine Raidbots runs, no queue, no limits, works offline.

Either way `/qeg run` is the whole thing.

**For damage and tank specs, install SimulationCraft.** Get the Windows build
from [simulationcraft.org](https://www.simulationcraft.org/) and unzip it
anywhere sensible — `C:\SimulationCraft` is found automatically, or pass
`--simc "C:/SimulationCraft/simc.exe"` to the helper. Without it, those specs are told to
install it rather than left waiting.

**Windows only, for now.** The one-click installer is a Windows batch file.

**Asking for a run means it equips the result.** `/qeg run` gears you up rather
than showing you a list to approve. It will not touch your gear on its own
unless you also turn on `/qeg autorun`, and it never swaps in combat. If you
would rather see the list first, `/qeg autoequip off`.

---

## Two ways to run it

**Just the addon** — install from CurseForge like any other addon. You run the
numbers yourself (QE Live for healers, Raidbots or simc otherwise) and paste
them back: `/qeg export`, then `/qeg weights`, then `/qeg local`. Nothing else
to install.

**Addon plus helper** — the instructions below. `/qeg run` does the whole thing
by itself in about twelve seconds, and can re-gear you automatically when you
loot an upgrade. This needs the small helper program, which cannot be shipped
through CurseForge because it is not an addon.

---

## Install

1. Go to [Releases](https://github.com/Naieter/Zazzers-Autogear/releases/latest)
   and download **`QEAutoGear-Full-<version>.zip`**. (The other file there is the
   addon on its own, for people who do not want the helper.)
2. Unzip it somewhere you will not delete by accident — your Documents folder is
   fine. Not your Downloads folder.
3. Double-click **`Run QE AutoGear.bat`**.

That is it. The first run takes a few minutes because it downloads what it
needs. After that it takes a couple of seconds.

If it says Python is not installed, get it from
[python.org/downloads](https://www.python.org/downloads/) and **tick the box
that says "Add python.exe to PATH"** on the first screen of the installer — it
is easy to miss and nothing works without it. Then run the file again.

**Close World of Warcraft completely and reopen it** after the first install.
WoW only notices new addons when it starts up; reloading is not enough.

---

## Using it

Leave the black window open while you play. It is the helper that talks to the
website — closing it is what stops the addon working.

In the game:

| Type this | What happens |
|---|---|
| `/qeg run` | Works out your best set and puts it on |
| `/qeg equip` | Re-applies the last result, if you turned auto-equip off |
| `/qeg` | Opens a window with the same thing, plus tick boxes |
| `/qeg vault` | Marks your Great Vault rewards BiS / Upgrade / No gain |
| `/qeg diag` | Tells you whether the helper is connected |

A run takes about 12 seconds. You will see the screen flicker once or twice —
that is the addon taking a picture of itself, which is genuinely how it gets
your gear out of the game. Nothing is wrong.

### The Great Vault

Open the vault and each reward is labelled **BiS**, **Upgrade** or **No gain**,
scored with the same weights the addon gears you with. `/qeg vault` prints the
same thing to chat.

"BiS" means nothing you own beats it. "Upgrade" means it beats the piece it
would actually replace — for rings and trinkets that is the weaker of the two
you are wearing, not whichever slot happens to be first.

### Starting it for you

Double-click **`Auto-start on or off.bat`** and pick **1**. The helper will
start by itself, minimised, whenever you log in to Windows — so the only thing
you ever do is play. Pick **2** in the same file to turn it back off.

It puts an ordinary shortcut in your Startup folder. Nothing hidden, no admin
rights, and you can delete it by hand if you would rather.

### Letting it do everything

`/qeg run` already equips the result. If you want it to notice upgrades by
itself as well, so you never type anything at all:

```
/qeg autorun on
```

Now looting an upgrade re-runs everything and re-gears you on its own.

---

## If something goes wrong

**"No answer from the QE agent"** — the helper is not running. Double-click
`Run QE AutoGear.bat` and leave the window open. To stop this happening again,
turn on auto-start (above).

**`/qeg` does nothing at all** — WoW has not noticed the addon. Close the game
fully and start it again, then check `QE AutoGear` is ticked in the AddOns list
on the character select screen.

**"SimulationCraft is not installed"** — you are on a damage or tank spec and
simc is missing. Install it from
[simulationcraft.org](https://www.simulationcraft.org/) and restart the helper.

**It equipped something you did not want** — whatever came off is in your bags,
so put it back on. To be shown the list and decide yourself in future, type
`/qeg autoequip off`.

**Anything else** — open an
[issue](https://github.com/Naieter/Zazzers-Autogear/issues) and paste what the
black window says.

---

## What it does on your computer

Worth being plain about, because some of it looks odd if you notice it and do
not know why:

- **It takes screenshots.** That is not a metaphor. Addons are forbidden from
  using the internet, so the addon draws your gear list as a grid of coloured
  squares and photographs it, and the helper reads the squares back out. Those
  screenshots are deleted immediately afterwards. Your own screenshots are never
  touched or deleted.
- **On a healer, it opens a browser you cannot see**, to load
  questionablyepic.com and run the numbers exactly as if you had done it by hand.
  It sends your gear, spec and talents there and nothing else — no account
  details, nothing about other players, nowhere but that site.
- **On any other spec nothing leaves your computer at all.** SimulationCraft
  runs locally and the addon never contacts Raidbots or anywhere else.
- **It never types for you or plays the game for you.** It only equips items you
  already own, and never in combat.

---

## For the curious

[How it works](docs/how-it-works.md) — the protocol, the internals, and a list
of the things that turned out to be surprisingly hard.

Questionably Epic is not affiliated with this project. Please do not send them
bug reports about it.

## Licence

MIT.
