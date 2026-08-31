# Changelog

## 1.0.4

- Releases now include the whole package, not just the addon. The download on
  the Releases page had no launcher and no helper in it, so `/qeg run` could
  not work for anyone who got it there.

## 1.0.3

- Gear is now equipped automatically when you run it, instead of showing a list
  and waiting. Asking for a run means gear me up. **Upgrading turns this on**,
  including for existing settings; `/qeg autoequip off` restores the old
  behaviour.
- Nothing runs on its own unless you also turn on `/qeg autorun`, and gear is
  still never swapped in combat.

## 1.0.2

- Fixed a swap being reported as done when it had not happened. The addon now
  checks the slot really holds the new item before saying so, and tells you
  what went wrong when it does not.
- Bind-on-equip items work. The confirmation dialog was being cancelled the
  instant it appeared, so the item never equipped; it now waits for you to
  answer it.

## 1.0.1

- Swapping gear now prints a line per piece saying what came off and what went
  on, with both items linked so you can hover or click them.

## 1.0.0

First release.

Type `/qeg run` and it works out the best gear set you own and puts it on,
using [Questionably Epic Live](https://questionablyepic.com/live) to do the
maths.

**Healers only** — Holy Paladin, Restoration Druid, Discipline Priest, Holy
Priest, Restoration Shaman, Mistweaver Monk, Preservation Evoker. That is the
list QE Live models; on anything else the addon says so and falls back to
scoring locally against stat weights.

### Two ways to run it

**Addon on its own** (this is what you get from CurseForge). `/qeg export`
copies your gear as a SimC string to paste into QE Live, `/qeg weights` pastes
the numbers back, and `/qeg local` finds the best set you own. No other software
needed.

**Addon plus the companion helper** (from
[GitHub](https://github.com/Naieter/Zazzers-Autogear)). The whole thing happens
by itself: `/qeg run` sends your gear, gets an answer back, and equips it in
about twelve seconds. Turn on `/qeg autorun` and looting an upgrade re-gears you
without you doing anything.

### Also

- Never swaps gear in combat; queues and finishes when you drop out.
- Never swaps anything until you say so, unless you turn on `/qeg autoequip`.
- Handles ring and trinket pairs, unique-equipped items, two-handers versus dual
  wield including Titan's Grip, and tier set bonuses.
- Leaves gear you are already wearing in the slot it is already in, so it never
  proposes swapping two trinkets with each other for no gain.
