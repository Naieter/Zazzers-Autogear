local ADDON, ns = ...
local Core = {}
ns.Core = Core

local DEFAULTS = {
    autoEquip     = true,   -- asking for a run means "gear me up"; just do it
    autoRun       = false,  -- kick off a run on loot / spec change
    includeBank   = false,
    tierBonus     = 0.05,   -- local scoring only; QE Live models sets properly
    debug         = false,
    nextSlot      = 1,
}

local POLL_SCHEDULE = { 5, 9, 14, 20, 28, 40, 55, 75 }

local job = nil

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")

----------------------------------------------------------------------------
-- Job lifecycle
----------------------------------------------------------------------------

local function cancelJob(reason)
    if not job then return end
    for _, t in ipairs(job.timers) do t:Cancel() end
    if reason then ns.Print(reason) end
    job = nil
    if ns.UI then ns.UI:Refresh() end
end

function Core:JobActive() return job ~= nil end
function Core:JobInfo() return job end

local function poll()
    if not job then return end
    local ok, err = ns.Bridge:PollOnce()
    if not ok and err == "out of payload slots" then
        cancelJob("|cffff8800out of inbox slots for this session.|r /reload resets them.")
    end
end

function Core:StartJob()
    if job then
        ns.Print("a run is already in flight (%ds ago).", math.floor(GetTime() - job.started))
        return
    end
    if InCombatLockdown() then
        ns.Print("|cffff8800not while in combat.|r")
        return
    end

    local specIndex = GetSpecialization()
    local specID = specIndex and GetSpecializationInfo(specIndex)
    if not ns.Bridge:CompanionInstalled() then
        -- Addon-only install. Sending frames nothing will ever read would just
        -- time out after 83 seconds and look broken, so offer the manual route.
        local site = ns.SimSite(specID or 0)
        ns.Print("|cffff8800the companion helper is not installed|r, so nothing can be "
                 .. "sent to %s automatically.", site)
        ns.Print("Use |cffffff00/qeg export|r to copy your gear, run it through "
                 .. "%s, then |cffffff00/qeg weights|r to paste the numbers back.",
                 site)
        ns.Print("Full automation: |cffffff00github.com/Naieter/Zazzers-Autogear|r")
        ns.Print("Meanwhile, here is the best set using your stored stat weights:")
        return self:RunLocal(false)
    end

    local text, meta = ns.Export:Build(QEAutoGearDB.includeBank)
    if not text then
        ns.Print("|cffff4444export failed:|r %s", meta or "unknown")
        return
    end

    local id = ns.HashString(text .. tostring(GetTime())) % 0xFFFFFFFF
    job = { id = id, started = GetTime(), timers = {}, meta = meta }
    QEAutoGearDB.lastExport = text

    local seen = QEAutoGearDB.agentSeen
    if not seen or (time() - seen) > 900 then
        -- Say so now rather than after a 83 second timeout.
        ns.Print("|cffff8800the agent has not been heard from.|r Start it in the "
                 .. "agent folder with |cffffff00python -m qeagent|r, or this "
                 .. "run will time out.")
    end

    ns.Print("sending %d items to %s (%s)...", (meta.bagItems or 0) + 16, ns.SimSite(specID or 0), meta.specName or "?")

    ns.Bridge:Send(text, id, function(frames)
        if not job then return end
        ns.Debug("sent %d frame(s), waiting on the agent", frames)
        for _, delay in ipairs(POLL_SCHEDULE) do
            job.timers[#job.timers + 1] = C_Timer.NewTimer(delay, poll)
        end
        job.timers[#job.timers + 1] = C_Timer.NewTimer(POLL_SCHEDULE[#POLL_SCHEDULE] + 8, function()
            cancelJob("|cffff8800no answer from the QE agent.|r Is qeagent running? Try |cffffff00/qeg diag|r.")
        end)
    end)

    if ns.UI then ns.UI:Refresh() end
end

-- A payload stub just loaded and handed us its contents.
function Core:OnResult(data)
    -- Only count this as a live sighting if the payload is recent. The stubs
    -- keep their last contents on disk forever, so a stale one from a previous
    -- session would otherwise look like a running agent. time() is real epoch
    -- time in game and the agent stamps ts the same way, so they compare.
    if data.daemon and data.ts and math.abs(time() - data.ts) < 300 then
        QEAutoGearDB.agentVersion = data.daemon
        QEAutoGearDB.agentSeen = time()
    end

    if not job or (data.job or 0) ~= job.id then
        if data.status == "ok" and data.job and data.job ~= 0 then
            ns.Debug("ignoring result for stale job %s", tostring(data.job))
        end
        return
    end

    if data.status == "pending" then
        ns.Debug("agent still working")
        return
    end

    if data.status == "error" then
        cancelJob(("|cffff4444QE agent error:|r %s"):format(data.err or "unknown"))
        return
    end

    if data.status ~= "ok" then return end

    local elapsed = GetTime() - job.started
    local specID = job.meta and job.meta.specID
    cancelJob(nil)

    if data.weights and specID then
        ns.Weights:Set(specID, data.weights, data.source or "QE Live")
        ns.Debug("stored %s weights for spec %d", data.source or "QE Live", specID)
    end

    local result
    if data.set and #data.set > 0 then
        result = ns.Optimizer:PlanFromSet(data.set, QEAutoGearDB.includeBank)
        result.source = "QE Live Top Gear"
        result.qeGain = data.gain
        if #result.missing > 0 then
            ns.Print("|cffff8800%d recommended item(s) are not in your bags|r - using what you have.",
                     #result.missing)
        end
    else
        result = ns.Optimizer:Run({ includeBank = QEAutoGearDB.includeBank, tierBonus = 0 })
        if result then result.source = (data.source or "QE Live") .. " stat weights" end
    end

    if not result then
        ns.Print("|cffff4444could not build a gear plan from that result.|r")
        return
    end

    ns.lastResult = result
    local gainText = data.gain and (" (+%.2f%% by QE Live)"):format(data.gain * 100) or ""
    ns.Print("answer in %.1fs: %d change(s)%s.", elapsed, #result.changes, gainText)

    if #result.changes == 0 then
        ns.Print("you are already wearing the best set it found.")
    elseif QEAutoGearDB.autoEquip then
        ns.Equipper:Apply(result, QEAutoGearDB.includeBank)
    else
        ns.Print("type |cffffff00/qeg equip|r to apply, or turn on |cffffff00/qeg autoequip on|r.")
        if ns.UI then ns.UI:Show() end
    end

    if ns.UI then ns.UI:Refresh() end
end

----------------------------------------------------------------------------
-- Offline path: score straight from stat weights, no round trip
----------------------------------------------------------------------------

function Core:RunLocal(autoApply)
    local result, err = ns.Optimizer:Run({
        includeBank = QEAutoGearDB.includeBank,
        tierBonus   = QEAutoGearDB.tierBonus,
    })
    if not result then
        ns.Print("|cffff4444%s|r", err or "optimisation failed")
        return
    end
    result.source = "local weights (" .. (result.weightSource or "?") .. ")"
    ns.lastResult = result

    if #result.changes == 0 then
        ns.Print("no upgrades in your bags - already optimal for these weights.")
    else
        ns.Print("%d upgrade(s) found, %+.2f%% score.", #result.changes, result.gain * 100)
        if autoApply or QEAutoGearDB.autoEquip then
            ns.Equipper:Apply(result, QEAutoGearDB.includeBank)
        else
            if ns.UI then ns.UI:Show() end
        end
    end
    if ns.UI then ns.UI:Refresh() end
    return result
end

----------------------------------------------------------------------------
-- Triggers
----------------------------------------------------------------------------

local autoPending
local function scheduleAuto()
    if not QEAutoGearDB.autoRun then return end
    if autoPending then autoPending:Cancel() end
    autoPending = C_Timer.NewTimer(6, function()
        autoPending = nil
        if InCombatLockdown() or ns.Equipper:IsRunning() or job then return end
        Core:StartJob()
    end)
end

frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        QEAutoGearDB = QEAutoGearDB or {}
        for k, v in pairs(DEFAULTS) do
            if QEAutoGearDB[k] == nil then QEAutoGearDB[k] = v end
        end
        QEAutoGearDB.nextSlot = 1 -- stub loads do not survive a session

        -- Profiles created before 1.0.3 hold an explicit autoEquip = false from
        -- the old default, which DEFAULTS above cannot override. Flip it once,
        -- and record that we did so a later "off" is never undone.
        if (QEAutoGearDB.settingsVersion or 1) < 2 then
            QEAutoGearDB.autoEquip = true
            QEAutoGearDB.settingsVersion = 2
        end
        QEAutoGearCharDB = QEAutoGearCharDB or {}
        QEAutoGearCharDB.weights = QEAutoGearCharDB.weights or {}
        QEAutoGearCharDB.weightSource = QEAutoGearCharDB.weightSource or {}

    elseif event == "PLAYER_LOGIN" then
        ns.Print("v%s loaded. |cffffff00/qeg|r for the panel, |cffffff00/qeg run|r to optimise.",
                 ns.VERSION)
        -- Burn one stub to see whether the companion agent is alive.
        C_Timer.After(3, function() ns.Bridge:PollOnce() end)

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" and arg1 == "player" then
        ns.Scanner:WipeCache()
        scheduleAuto()

    elseif event == "BAG_UPDATE_DELAYED" then
        scheduleAuto()

    elseif event == "PLAYER_REGEN_ENABLED" then
        if ns.pendingApply then
            local p = ns.pendingApply
            ns.pendingApply = nil
            ns.Equipper:Apply(p.result, p.includeBank)
        end
    end
end)

----------------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------------

local function onOff(v) return v and "|cff44ff44on|r" or "|cffff4444off|r" end

SLASH_QEAUTOGEAR1 = "/qeg"
SLASH_QEAUTOGEAR2 = "/qeautogear"
SlashCmdList.QEAUTOGEAR = function(msg)
    local cmd, rest = msg:lower():match("^(%S*)%s*(.-)$")

    if cmd == "" then
        if ns.UI then ns.UI:Toggle() end

    elseif cmd == "run" or cmd == "go" then
        Core:StartJob()

    elseif cmd == "local" then
        Core:RunLocal(false)

    elseif cmd == "equip" or cmd == "apply" then
        if ns.lastResult then
            ns.Equipper:Apply(ns.lastResult, QEAutoGearDB.includeBank)
        else
            ns.Print("nothing to apply - run |cffffff00/qeg run|r first.")
        end

    elseif cmd == "export" then
        local text = ns.Export:Build(QEAutoGearDB.includeBank)
        if text and ns.UI then ns.UI:ShowText("SimC export - paste into QE Live", text) end

    elseif cmd == "weights" then
        if ns.UI then ns.UI:ShowWeightsImport() end

    elseif cmd == "autoequip" then
        QEAutoGearDB.autoEquip = (rest == "on") or (rest == "" and not QEAutoGearDB.autoEquip)
        ns.Print("auto-equip %s.", onOff(QEAutoGearDB.autoEquip))

    elseif cmd == "autorun" then
        QEAutoGearDB.autoRun = (rest == "on") or (rest == "" and not QEAutoGearDB.autoRun)
        ns.Print("auto-run on loot/spec change %s.", onOff(QEAutoGearDB.autoRun))

    elseif cmd == "bank" then
        QEAutoGearDB.includeBank = (rest == "on") or (rest == "" and not QEAutoGearDB.includeBank)
        ns.Print("include bank %s.", onOff(QEAutoGearDB.includeBank))

    elseif cmd == "debug" then
        QEAutoGearDB.debug = not QEAutoGearDB.debug
        ns.Print("debug %s.", onOff(QEAutoGearDB.debug))

    elseif cmd == "test" then
        -- Capture leg only: paint a known payload, screenshot it, no agent
        -- and no QE Live involved. Whatever lands in Screenshots must decode
        -- back to exactly this string.
        local sample = "QEAG-SELFTEST|" .. (UnitName("player") or "?") .. "|"
            .. date("%Y%m%d-%H%M%S") .. "|"
        sample = sample .. ("0123456789abcdefghijklmnopqrstuvwxyz"):rep(30)
        ns.Print("capture test: %d bytes, job 4242. Check the Screenshots folder.", #sample)
        ns.Bridge:Send(sample, 4242, function(frames)
            ns.Print("painted %d frame(s). Decode with: |cffffff00python -m qeagent --decode <file>|r", frames)
        end)

    elseif cmd == "poll" then
        -- Return leg only: force-load the next inbox stub right now.
        local ok, err = ns.Bridge:PollOnce()
        ns.Print("polled inbox: %s. %d slot(s) left.",
                 ok and "loaded" or ("failed - " .. tostring(err)), ns.Bridge:SlotsRemaining())

    elseif cmd == "slots" then
        -- Ground truth for what the exporter can actually see in each slot.
        for _, slot in ipairs(ns.INV_SLOTS) do
            local link = GetInventoryItemLink("player", slot.id)
            local line = link and ns.Export:ItemLine(slot.simc, link) or nil
            if not link then
                ns.Print("|cff888888%s (%d): empty|r", slot.simc, slot.id)
            elseif not line then
                ns.Print("|cffff4444%s (%d): LINK OK BUT PARSE FAILED|r %s", slot.simc, slot.id, link)
            else
                ns.Print("%s (%d): %s", slot.simc, slot.id, line)
            end
        end

    elseif cmd == "vault" then
        ns.Vault:Report()

    elseif cmd == "diag" then
        local seen = QEAutoGearDB.agentSeen
        ns.Print("agent: %s", seen and ("v" .. (QEAutoGearDB.agentVersion or "?") ..
                 ", last heard " .. (time() - seen) .. "s ago") or "|cffff4444never seen|r")
        ns.Print("inbox slots left this session: %d/%d", ns.Bridge:SlotsRemaining(), ns.PAYLOAD_SLOTS)
        ns.Print("bridge capacity: %d bytes/frame", ns.Bridge:Capacity())
        ns.Print("screenshot dir: <WoW>\\Screenshots - agent must be watching it")
        local spec = GetSpecialization()
        local id = spec and GetSpecializationInfo(spec)
        local site = ns.SimSite(id)
        ns.Print("spec %s: sims on %s%s", tostring(id), site,
                 ns.QE_SPECS[id] and " (automatic)" or " (export and paste)")

    else
        ns.Print("commands:")
        print("  /qeg            - open the panel")
        print("  /qeg run        - full auto: export -> QE Live -> equip")
        print("  /qeg local      - optimise from stored stat weights only")
        print("  /qeg equip      - apply the last result")
        print("  /qeg export     - show the SimC string to paste manually")
        print("  /qeg weights    - paste stat weights in by hand")
        print("  /qeg autoequip [on|off] - swap without asking")
        print("  /qeg autorun [on|off]   - re-run on loot and spec change")
        print("  /qeg bank [on|off]      - include bank items")
        print("  /qeg vault      - mark Great Vault rewards as BiS or upgrade")
        print("  /qeg diag       - connection and capacity check")
    end
end
