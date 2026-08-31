"""Drive the real Equipper.lua against stubbed WoW APIs.

The equipper is the only part of the addon that changes your character, and the
failure that matters is the quiet one: reporting a swap that did not happen.
That is not a syntax error and the pixel round trip cannot see it, so it needs
its own test.

Everything here loads the shipped Lua unmodified. Only the game is fake.
"""

from __future__ import annotations

import sys
from pathlib import Path

from lupa import lua51

ROOT = Path(__file__).resolve().parent.parent
ADDON = ROOT / "addon" / "QEAutoGear"

HARNESS = """
local ns = {}
local log = {}

DEFAULT_CHAT_FRAME = { AddMessage = function(self, m) log[#log+1] = m end }
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function InCombatLockdown() return false end

-- Scheduler: callbacks are collected and drained by the test, so the whole
-- queue runs to completion without real time passing.
local pending = {}
C_Timer = { After = function(_, fn) pending[#pending+1] = fn end }
function DRAIN()
    local guard = 0
    while #pending > 0 and guard < 5000 do
        local fn = table.remove(pending, 1)
        fn()
        guard = guard + 1
    end
end

-- The fake character. equipped[slot] = link, bags[i] = link.
EQUIPPED, BAGS = {}, {}
CURSOR = nil
EQUIP_SUCCEEDS = true        -- flip to model a silent refusal
POPUP = nil                  -- name of a visible confirmation dialog

function GetInventoryItemLink(_, slot) return EQUIPPED[slot] end
function PickupInventoryItem(slot) CURSOR = EQUIPPED[slot]; EQUIPPED[slot] = nil end
function GetCursorInfo() if CURSOR then return "item", 0, CURSOR end return nil end
function ClearCursor() CURSOR = nil end
function StaticPopup_Visible(which) if POPUP == which then return which end return nil end

function EquipCursorItem(slot)
    if not EQUIP_SUCCEEDS then return end      -- the bug: nothing happens
    EQUIPPED[slot] = CURSOR
    CURSOR = nil
end

C_Container = {
    GetContainerNumSlots = function(bag) if bag == 0 then return #BAGS end return 0 end,
    GetContainerItemLink = function(bag, slot) if bag == 0 then return BAGS[slot] end end,
    PickupContainerItem = function(bag, slot)
        if bag == 0 then CURSOR = BAGS[slot]; BAGS[slot] = nil end
    end,
}
Enum = { BagIndex = {} }
BANK_CONTAINER = -1

%(util)s
%(equipper)s

function LOG() return table.concat(log, "\\n") end
function RESET() log = {} end
return ns
"""


def build(case):
    L = lua51.LuaRuntime()
    load = L.eval("loadstring or load")
    src = HARNESS % {
        "util": (ADDON / "Util.lua").read_text(encoding="utf-8").replace("local ADDON, ns = ...", ""),
        "equipper": (ADDON / "Equipper.lua").read_text(encoding="utf-8").replace("local ADDON, ns = ...", ""),
    }
    result = load(src, "@harness")
    fn = result[0] if isinstance(result, tuple) else result
    if fn is None:
        raise SystemExit(f"harness failed to load: {result}")
    return L, fn()


def run(equip_succeeds: bool, popup: str | None = None):
    L, ns = build(None)
    g = L.globals()
    OLD = "|cffa335ee|Hitem:193757::::::::|h[Old Trinket]|h|r"
    NEW = "|cffa335ee|Hitem:280097::::::::|h[New Trinket]|h|r"
    g.EQUIPPED[13] = OLD
    g.BAGS[1] = NEW
    g.EQUIP_SUCCEEDS = equip_succeeds
    g.POPUP = popup

    changes = L.table_from([L.table_from({"slot": 13, "to": NEW, "from": OLD})])
    ns.Equipper.Apply(ns.Equipper, L.table_from({"changes": changes}), False)
    g.DRAIN()
    return g.LOG(), g.EQUIPPED[13], OLD, NEW


def check(name, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + ("" if ok else f"  {detail}"))
    return ok


def main() -> int:
    ok = True

    print("equip succeeds")
    log, worn, OLD, NEW = run(True)
    ok &= check("slot actually changed", worn == NEW)
    ok &= check("reports 1 swapped", "1 piece(s) swapped." in log, log)
    ok &= check("names both items", "Old Trinket" in log and "New Trinket" in log, log)

    print("equip silently fails - the bug this test exists for")
    log, worn, OLD, NEW = run(False)
    ok &= check("slot unchanged", worn == OLD, f"worn={worn}")
    ok &= check("does NOT claim a swap", "1 piece(s) swapped." not in log, log)
    ok &= check("says it could not equip", "could not equip" in log, log)
    ok &= check("counts it skipped", "0 piece(s) swapped, 1 skipped" in log, log)

    print("bind-on-equip dialog is waited on, not cancelled")
    log, worn, OLD, NEW = run(False, popup="EQUIP_BIND")
    ok &= check("tells the player to confirm", "binds when equipped" in log, log)

    print("\n" + ("ALL PASS" if ok else "FAILURES ABOVE"))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
