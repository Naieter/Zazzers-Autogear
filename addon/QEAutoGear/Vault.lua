local ADDON, ns = ...
local V = {}
ns.Vault = V

--[[--------------------------------------------------------------------------
  Marks Great Vault rewards as best-in-slot, an upgrade, or neither, using the
  same stat weights the optimiser uses -- so the vault answer and the gear the
  addon equips can never disagree.

  What a reward is worth depends on what it would replace, and for rings and
  trinkets that is the weaker of the two you are wearing, not "the ring slot".
  Comparing against a single slot would call a ring an upgrade when it is worse
  than both of the ones already on.
----------------------------------------------------------------------------]]

local function scoreOf(info, weights)
    return ns.Optimizer:Score(info, weights, nil, 0)
end

-- Every activity the vault is currently offering, deduplicated by id.
local function rewardActivities()
    if not (C_WeeklyRewards and C_WeeklyRewards.GetActivities) then return {} end

    local seen, out = {}, {}
    local function collect(list)
        if type(list) ~= "table" then return end
        for _, activity in ipairs(list) do
            if activity and activity.id and not seen[activity.id] then
                seen[activity.id] = true
                out[#out + 1] = activity
            end
        end
    end

    local ok, all = pcall(C_WeeklyRewards.GetActivities)
    if ok then collect(all) end

    -- Older clients want the type; ask for each in turn if the bare call was empty.
    if #out == 0 and Enum and Enum.WeeklyRewardChestThresholdType then
        for _, t in pairs(Enum.WeeklyRewardChestThresholdType) do
            if type(t) == "number" then
                local ok2, list = pcall(C_WeeklyRewards.GetActivities, t)
                if ok2 then collect(list) end
            end
        end
    end
    return out
end

local function rewardLink(activity)
    if not (C_WeeklyRewards and C_WeeklyRewards.GetExampleRewardItemHyperlinks) then
        return nil
    end
    local ok, link = pcall(C_WeeklyRewards.GetExampleRewardItemHyperlinks, activity.id)
    if ok and link and link ~= "" then return link end
    return nil
end

-- Returns a list of { link, slot, tag, gain, verdict, activityId }, plus a
-- reason string when there is nothing to say.
function V:Evaluate()
    local specIndex = GetSpecialization()
    local specID = specIndex and GetSpecializationInfo(specIndex)
    if not specID then return nil, "no specialisation selected" end

    local weights, weightSource = ns.Weights:Get(specID)
    local equipped, candidates = ns.Scanner:ScanAll(QEAutoGearDB and QEAutoGearDB.includeBank)

    local activities = rewardActivities()
    if #activities == 0 then
        return nil, "the vault has nothing to show yet this week"
    end

    local results, pending = {}, 0

    for _, activity in ipairs(activities) do
        local link = rewardLink(activity)
        if link then
            local info = ns.Scanner:Inspect(link)
            if not info then
                pending = pending + 1
            else
                local legal = ns.Scanner:LegalSlots(info) or {}
                local score = scoreOf(info, weights)

                -- Best of everything you own that could go in those slots, and
                -- the weakest thing currently occupying one of them.
                local bestOwned, worstEquipped = 0, nil
                for _, c in ipairs(candidates) do
                    for _, cs in ipairs(ns.Scanner:LegalSlots(c) or {}) do
                        for _, ls in ipairs(legal) do
                            if cs == ls then
                                local s = scoreOf(c, weights)
                                if s > bestOwned then bestOwned = s end
                            end
                        end
                    end
                end
                for _, slotID in ipairs(legal) do
                    local have = equipped[slotID]
                    local s = have and scoreOf(have, weights) or 0
                    if worstEquipped == nil or s < worstEquipped then worstEquipped = s end
                end
                worstEquipped = worstEquipped or 0

                local verdict, tag
                if score > bestOwned then
                    verdict, tag = "bis", "|cff00ff00BiS|r"
                elseif score > worstEquipped then
                    verdict, tag = "upgrade", "|cffffff00Upgrade|r"
                else
                    verdict, tag = "none", "|cff888888No gain|r"
                end

                local gain
                if worstEquipped > 0 then gain = score / worstEquipped - 1 end

                results[#results + 1] = {
                    activityId = activity.id, link = link, verdict = verdict,
                    tag = tag, gain = gain, score = score,
                    slot = ns.SLOT_NAME[legal[1]] or "?",
                    level = activity.level, threshold = activity.threshold,
                }
            end
        end
    end

    if #results == 0 then
        if pending > 0 then
            return nil, "still loading vault items from the server - try again in a second"
        end
        return nil, "the vault has nothing to show yet this week"
    end

    return results, nil, weightSource
end

function V:Report()
    local results, err, weightSource = self:Evaluate()
    if not results then
        ns.Print("|cffff8800%s|r", err)
        return
    end

    ns.Print("Great Vault, scored with %s weights:", weightSource or "?")
    for _, r in ipairs(results) do
        local gain = r.gain and (" |cff888888(%+.1f%%)|r"):format(r.gain * 100) or ""
        ns.Detail("%s  %s  |cffaaaaaa%s|r%s", r.tag, r.link, r.slot, gain)
    end
    ns.Detail("|cff888888BiS means nothing you own beats it. Upgrade means it beats "
              .. "the weaker piece it would replace.|r")
end

----------------------------------------------------------------------------
-- Overlay on Blizzard's vault window
----------------------------------------------------------------------------

local hooked = false

local function decorate(frame)
    if not (frame and frame.Activities) then return end

    local results = V:Evaluate()
    local byActivity = {}
    for _, r in ipairs(results or {}) do byActivity[r.activityId] = r end

    for _, activityFrame in ipairs(frame.Activities) do
        local label = activityFrame.qeagVerdict
        if not label then
            label = activityFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            label:SetPoint("BOTTOM", activityFrame, "BOTTOM", 0, -14)
            activityFrame.qeagVerdict = label
        end
        local r = activityFrame.info and byActivity[activityFrame.info.id]
        label:SetText(r and r.tag or "")
    end
end

local function hookVault()
    if hooked then return end
    local frame = _G.WeeklyRewardsFrame
    if not frame then return end
    hooked = true

    -- Deferred: the reward frames are populated after these fire.
    local function refresh(self)
        C_Timer.After(0, function() pcall(decorate, self) end)
    end

    frame:HookScript("OnShow", refresh)
    for _, method in ipairs({ "Refresh", "SetUpConditionalActivities" }) do
        if type(frame[method]) == "function" then
            hooksecurefunc(frame, method, refresh)
        end
    end
end

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("ADDON_LOADED")
watcher:SetScript("OnEvent", function(self, _, addon)
    local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    if addon == "Blizzard_WeeklyRewards" or (loaded and loaded("Blizzard_WeeklyRewards")) then
        pcall(hookVault)
        if hooked then self:UnregisterEvent("ADDON_LOADED") end
    end
end)
