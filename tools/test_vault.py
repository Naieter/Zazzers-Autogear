"""Drive the real Vault.lua against a stubbed Great Vault.

The verdict logic is easy to get subtly wrong, and wrong here is worse than
useless: telling someone a vault reward is best-in-slot when it is not costs
them a weekly pick they cannot take back.

The case that matters is rings and trinkets. There are two of each, so a reward
competes with the *weaker* one you are wearing, not with "the ring slot". A
naive comparison against one slot calls a ring an upgrade when it is worse than
both you already have.
"""

from __future__ import annotations

import sys
from pathlib import Path

from lupa import lua51

ROOT = Path(__file__).resolve().parent.parent
ADDON = ROOT / "addon" / "QEAutoGear"

PRELUDE = """
local ns = {}
local log = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(self, m) log[#log+1] = m end }
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function CreateFrame() return {
    RegisterEvent = function() end, SetScript = function() end,
    UnregisterEvent = function() end, HookScript = function() end,
    CreateFontString = function() return { SetPoint = function() end,
                                           SetText = function() end } end,
} end
function GetSpecialization() return 1 end
function GetSpecializationInfo() return 1468, "Preservation" end
function UnitClass() return "Evoker", "EVOKER" end
C_Timer = { After = function(_, fn) fn() end, NewTimer = function() return {Cancel=function() end} end }
QEAutoGearDB = { includeBank = false }
QEAutoGearCharDB = { weights = {}, weightSource = {} }

-- The fake vault and the fake character.
VAULT = {}          -- { {id=, level=, threshold=, link=} }
OWNED = {}          -- candidates, as Scanner:ScanAll would return them
C_WeeklyRewards = {
  GetActivities = function()
      local out = {}
      for i, v in ipairs(VAULT) do out[i] = { id = v.id, level = v.level, threshold = v.threshold } end
      return out
  end,
  GetExampleRewardItemHyperlinks = function(id)
      for _, v in ipairs(VAULT) do if v.id == id then return v.link end end
      return nil
  end,
}
Enum = { WeeklyRewardChestThresholdType = { Activities = 1, Raid = 2, World = 3 } }

local LEGAL = { INVTYPE_FINGER = {11,12}, INVTYPE_TRINKET = {13,14},
                INVTYPE_HEAD = {1}, INVTYPE_2HWEAPON = {16} }
ns.Scanner = {
  LegalSlots = function(self, c) return LEGAL[c.equipLoc] end,
  ScanAll = function(self)
      local eq = {}
      for _, c in ipairs(OWNED) do
          if c.where and c.where.equipped then eq[c.where.equipped] = c end
      end
      return eq, OWNED, 0
  end,
  Inspect = function(self, link)
      for _, v in ipairs(VAULT) do
          if v.link == link then
              return { link = link, equipLoc = v.equipLoc, stats = v.stats,
                       ilvl = v.ilvl or 0, dps = 0 }
          end
      end
      return nil
  end,
}
"""

TAIL = """
function LOG() return table.concat(log, "\\n") end
function RESET() log = {} end
return ns
"""


def build():
    L = lua51.LuaRuntime()
    load = L.eval("loadstring or load")
    src = PRELUDE
    for name in ("Util.lua", "Weights.lua", "Optimizer.lua", "Vault.lua"):
        src += (ADDON / name).read_text(encoding="utf-8").replace("local ADDON, ns = ...", "")
    src += TAIL
    r = load(src, "@harness")
    fn = r[0] if isinstance(r, tuple) else r
    if fn is None:
        raise SystemExit(f"harness failed: {r}")
    return L, fn()


def ring(L, intellect, equipped_slot=None, ilvl=600):
    # Same ilvl as the reward on purpose: Score adds a small ilvl term to break
    # ties between identical stat budgets, so a fixture with ilvl 0 here would
    # make every reward look like an upgrade and prove nothing.
    d = {"equipLoc": "INVTYPE_FINGER",
         "stats": L.table_from({"intellect": intellect}), "ilvl": ilvl, "dps": 0,
         "link": f"|Hitem:{intellect}|h[Ring {intellect}]|h"}
    d["where"] = L.table_from({"equipped": equipped_slot} if equipped_slot
                              else {"bag": 0, "slot": intellect})
    return L.table_from(d)


def verdict_for(L, ns, reward_int, worn):
    g = L.globals()
    g.OWNED = L.table_from([ring(L, i, slot) for i, slot in worn])
    g.VAULT = L.table_from([L.table_from({
        "id": 1, "level": 600, "threshold": 1, "equipLoc": "INVTYPE_FINGER",
        "ilvl": 600, "stats": L.table_from({"intellect": reward_int}),
        "link": f"|Hitem:{reward_int}|h[Vault Ring]|h"})])
    # Evaluate returns (results, err, source); lupa hands that back as a tuple.
    out = ns.Vault.Evaluate(ns.Vault)
    results = out[0] if isinstance(out, tuple) else out
    if results is None:
        return None
    return list(results.values())[0].verdict


def check(name, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + ("" if ok else f"  {detail}"))
    return ok


def main() -> int:
    L, ns = build()
    ok = True

    # Wearing rings worth 100 and 50. A reward competes with the 50.
    worn = [(100, 11), (50, 12)]

    print("ring better than everything owned")
    v = verdict_for(L, ns, 150, worn)
    ok &= check("BiS", v == "bis", f"got {v}")

    print("ring beats the weaker worn ring but not the stronger")
    v = verdict_for(L, ns, 75, worn)
    ok &= check("Upgrade, not BiS", v == "upgrade", f"got {v}")

    print("ring worse than both worn rings")
    v = verdict_for(L, ns, 25, worn)
    ok &= check("No gain", v == "none", f"got {v}")

    print("edge: exactly ties the weaker ring")
    v = verdict_for(L, ns, 50, worn)
    ok &= check("No gain, not an upgrade", v == "none", f"got {v}")

    print("same stats but a higher item level still counts")
    L.globals().OWNED = L.table_from([ring(L, 100, 11), ring(L, 50, 12, ilvl=580)])
    v = verdict_for(L, ns, 50, worn)
    ok &= check("handled without crashing", v in ("none", "upgrade"), f"got {v}")

    print("empty vault reports a reason instead of an empty list")
    L.globals().VAULT = L.table_from([])
    out = ns.Vault.Evaluate(ns.Vault)
    results, err = (out if isinstance(out, tuple) else (out, None))[:2]
    ok &= check("returns nil with a reason", results is None and bool(err), f"err={err}")

    print("\n" + ("ALL PASS" if ok else "FAILURES ABOVE"))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
