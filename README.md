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

**This only works for healers.** Questionably Epic Live only models these seven
specs, and there is nothing the addon can do about that:

Holy Paladin · Restoration Druid · Discipline Priest · Holy Priest ·
Restoration Shaman · Mistweaver Monk · Preservation Evoker

On any other spec it will tell you so and fall back to a simpler built-in
calculation.

**Windows only, for now.** The one-click installer is a Windows batch file.

**It will not change your gear without asking.** The first time it finds
something better it shows you the list and waits. You turn on automatic swapping
yourself, if you want it.

---

## Install

1. On this page, click the green **Code** button, then **Download ZIP**.
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
| `/qeg run` | Works out your best set and shows you what would change |
| `/qeg equip` | Actually puts that set on |
| `/qeg` | Opens a window with the same thing, plus tick boxes |
| `/qeg diag` | Tells you whether the helper is connected |

A run takes about 12 seconds. You will see the screen flicker once or twice —
that is the addon taking a picture of itself, which is genuinely how it gets
your gear out of the game. Nothing is wrong.

### Starting it for you

Double-click **`Auto-start on or off.bat`** and pick **1**. The helper will
start by itself, minimised, whenever you log in to Windows — so the only thing
you ever do is play. Pick **2** in the same file to turn it back off.

It puts an ordinary shortcut in your Startup folder. Nothing hidden, no admin
rights, and you can delete it by hand if you would rather.

### Letting it do everything

If you want it to gear you up without being asked:

```
/qeg autoequip on
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

**"QE Live only models healers"** — your spec is not one of the seven above.
Working as intended.

**It suggests gear you do not want** — nothing is applied until you type
`/qeg equip`, so you can ignore it.

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
- **It opens a browser you cannot see**, to load questionablyepic.com and run the
  numbers exactly as if you had done it by hand.
- **It sends your gear, spec and talents to that website, and nothing else.** No
  account details, nothing about other players, and nothing to anywhere except
  Questionably Epic Live.
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
