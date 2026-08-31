# CurseForge listing

Copy the description below into the project page. Everything above the line is
setup notes, not part of the listing.

## Setting the project up (one-time, has to be done by a human)

1. Sign in at <https://legacy.curseforge.com/> and create a project:
   **World of Warcraft → Addons → Create Project**.
2. Name: `QE AutoGear`. Category: **Character Advancement** (or *Bags &
   Inventory*). Licence: **MIT**.
3. Paste the description below.
4. Note the **numeric project id** from the project page URL.
5. Create an API token at <https://legacy.curseforge.com/account/api-tokens>.
6. In GitHub → Settings → Secrets and variables → Actions, add:
   - `CURSEFORGE_PROJECT_ID` — the number from step 4
   - `CURSEFORGE_TOKEN` — the token from step 5

After that, pushing a `v*` tag builds the zip, attaches it to a GitHub release,
and uploads it to CurseForge automatically.

To upload by hand instead, run `python tools/package.py` and drag
`dist/QEAutoGear-1.0.0.zip` into the project's Files tab.

---

## Description

**Type `/qeg run`. It works out the best gear set you own and puts it on.**

QE AutoGear reads your gear, spec and talents, works out which of the items you
are carrying make the best set, and equips them. The maths comes from
[Questionably Epic Live](https://questionablyepic.com/live) — the site healers
already use to compare gear.

### Healers only

Questionably Epic Live models these seven specs, and the addon cannot do better
than the site it relies on:

Holy Paladin · Restoration Druid · Discipline Priest · Holy Priest ·
Restoration Shaman · Mistweaver Monk · Preservation Evoker

On any other spec it says so, and falls back to ranking your gear against stat
weights you can paste in yourself.

### Commands

| Command | What it does |
|---|---|
| `/qeg` | Open the window |
| `/qeg export` | Copy your gear as a SimC string, to paste into QE Live |
| `/qeg weights` | Paste stat weights back from QE Live |
| `/qeg local` | Find the best set you own using those weights |
| `/qeg equip` | Put that set on |

Asking for a run equips the result — nothing happens unless you ask. Gear is
never swapped in combat; it waits until you drop out. `/qeg autoequip off` if
you would rather be shown the list and apply it yourself.

### Want it fully automatic?

This addon on its own uses the copy-and-paste route above, which is all most
people need.

There is also an optional companion helper that removes the copying entirely:
`/qeg run` sends your gear to QE Live, gets the answer, and equips it, in about
twelve seconds. Loot an upgrade and it can re-gear you on its own.

It cannot be distributed through CurseForge, because it is a small program
rather than an addon. It is free and open source here:

**<https://github.com/Naieter/Zazzers-Autogear>**

### Details

- Handles ring and trinket pairs, unique-equipped items, two-handers versus dual
  wield including Titan's Grip, and tier set bonuses.
- Leaves gear you already wear in the slot it is already in, so it will not
  suggest swapping two trinkets with each other for no gain.
- Reads your bags, and optionally your bank.
- Open source, MIT licensed.

Questionably Epic is not affiliated with this addon. Please do not send them
bug reports about it — use the
[issue tracker](https://github.com/Naieter/Zazzers-Autogear/issues).
