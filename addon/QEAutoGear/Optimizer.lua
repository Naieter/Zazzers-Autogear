local ADDON, ns = ...
local O = {}
ns.Optimizer = O

local INDEPENDENT = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 15 }

function O:Score(c, weights, tierSetID, tierBonus)
    local score = 0
    for stat, value in pairs(c.stats) do
        score = score + value * (weights[stat] or 0)
    end
    if c.dps and c.dps > 0 then
        score = score + c.dps * (weights.weaponDPS or 0)
    end
    -- Tiny ilvl term breaks ties between items with identical stat budgets.
    score = score + (c.ilvl or 0) * 0.001
    if tierSetID and c.setID == tierSetID and tierBonus and tierBonus > 0 then
        score = score * (1 + tierBonus)
    end
    return score
end

local function physicalKey(c)
    if c.where.equipped then return "e" .. c.where.equipped end
    return ("b%d.%d"):format(c.where.bag, c.where.slot)
end

-- Greedy top-N from a pool, honouring unique-equipped and never reusing the
-- same physical item twice. Optimal for pools this small.
local function pickDistinct(pool, n, used)
    local out = {}
    for _, c in ipairs(pool) do
        if #out >= n then break end
        local key = physicalKey(c)
        if not used[key] then
            local clash = false
            if c.uniqueEquipped then
                for _, chosen in ipairs(out) do
                    if chosen.itemID == c.itemID then clash = true break end
                end
            end
            if not clash then
                out[#out + 1] = c
                used[key] = true
            end
        end
    end
    return out
end

local function sortByScore(a, b) return a.score > b.score end

local function contains(t, v)
    for _, x in ipairs(t) do if x == v then return true end end
    return false
end

function O:Run(opts)
    opts = opts or {}
    local specIndex = GetSpecialization()
    if not specIndex then return nil, "no specialisation selected" end
    local specID = GetSpecializationInfo(specIndex)
    local weights, source = ns.Weights:Get(specID)

    local equipped, candidates, pending = ns.Scanner:ScanAll(opts.includeBank)
    if pending > 0 then
        return nil, ("still loading %d item(s) from the server - try again in a second"):format(pending)
    end

    -- The tier set we already have the most pieces of is the one worth chasing.
    local tierCount, tierSetID = {}, nil
    for _, c in ipairs(candidates) do
        if c.setID and c.where.equipped then
            tierCount[c.setID] = (tierCount[c.setID] or 0) + 1
            if not tierSetID or tierCount[c.setID] > tierCount[tierSetID] then tierSetID = c.setID end
        end
    end
    local tierBonus = opts.tierBonus or 0

    local bySlot = {}
    for _, c in ipairs(candidates) do
        c.score = self:Score(c, weights, tierSetID, tierBonus)
        for _, slotID in ipairs(ns.Scanner:LegalSlots(c) or {}) do
            bySlot[slotID] = bySlot[slotID] or {}
            table.insert(bySlot[slotID], c)
        end
    end
    for _, pool in pairs(bySlot) do table.sort(pool, sortByScore) end

    local plan, used = {}, {}

    for _, slotID in ipairs(INDEPENDENT) do
        plan[slotID] = pickDistinct(bySlot[slotID] or {}, 1, used)[1]
    end

    local rings = pickDistinct(bySlot[11] or {}, 2, used)
    plan[11], plan[12] = rings[1], rings[2]

    local trinkets = pickDistinct(bySlot[13] or {}, 2, used)
    plan[13], plan[14] = trinkets[1], trinkets[2]

    -- Weapons: a two-hander competes against the best one-hand pairing.
    local titansGrip = IsSpellKnown(46917)
    local best, bestScore = nil, -1
    local mhPool, ohPool = bySlot[16] or {}, bySlot[17] or {}

    local function consider(mh, oh)
        if mh and oh and physicalKey(mh) == physicalKey(oh) then return end
        if mh and mh.equipLoc == "INVTYPE_2HWEAPON" and oh and not titansGrip then return end
        if oh and oh.equipLoc == "INVTYPE_2HWEAPON" and not titansGrip then return end
        local total = (mh and mh.score or 0) + (oh and oh.score or 0)
        if total > bestScore then bestScore, best = total, { mh, oh } end
    end

    local LIMIT = 8
    for i = 1, math.min(LIMIT, #mhPool) do
        consider(mhPool[i], nil)
        for j = 1, math.min(LIMIT, #ohPool) do consider(mhPool[i], ohPool[j]) end
    end
    if best then plan[16], plan[17] = best[1], best[2] end

    local total, currentTotal, changes = 0, 0, {}
    for _, slot in ipairs(ns.INV_SLOTS) do
        local want, have = plan[slot.id], equipped[slot.id]
        local haveScore = have and self:Score(have, weights, tierSetID, tierBonus) or 0
        total = total + (want and want.score or 0)
        currentTotal = currentTotal + haveScore
        if want and (not have or want.link ~= have.link) then
            changes[#changes + 1] = {
                slot = slot.id,
                from = have and have.link or nil,
                to = want.link,
                gain = want.score - haveScore,
            }
        end
    end
    table.sort(changes, function(a, b) return a.gain > b.gain end)

    return {
        plan = plan, changes = changes, score = total, currentScore = currentTotal,
        gain = currentTotal > 0 and (total / currentTotal - 1) or 0,
        weightSource = source, specID = specID, tierSetID = tierSetID,
        candidateCount = #candidates,
    }
end

-- QE Live told us the exact set it wants. Match those item IDs to items we
-- actually own, then hand the equipper a plan in the same shape as a local run.
function O:PlanFromSet(set, includeBank)
    local equipped, candidates = ns.Scanner:ScanAll(includeBank)
    local plan, used, missing = {}, {}, {}

    local wanted = {}
    for _, entry in ipairs(set) do
        wanted[#wanted + 1] = {
            id = tonumber(entry.id), bonus = entry.bonus, slot = tonumber(entry.slot),
        }
    end

    -- Four passes, most conservative first.
    --
    -- An item you are already wearing keeps the slot it is already in. Trinket
    -- and ring slots are interchangeable, so without this the plan proposes
    -- swapping two trinkets with each other purely because QE Live happened to
    -- list them in the other order - a change that costs two equips and does
    -- nothing at all.
    --
    -- Exact bonus-id matches also come before loose ones, so an upgraded copy
    -- is never confused with a base one of the same item.
    local PASSES = {
        { inPlace = true,  requireBonus = true  },
        { inPlace = true,  requireBonus = false },
        { inPlace = false, requireBonus = true  },
        { inPlace = false, requireBonus = false },
    }

    for _, pass in ipairs(PASSES) do
        for _, want in ipairs(wanted) do
            if not want.matched and want.id then
                for _, c in ipairs(candidates) do
                    local key = physicalKey(c)
                    if not used[key] and c.itemID == want.id then
                        local bonusOK = true
                        if pass.requireBonus and want.bonus and want.bonus ~= "" then
                            bonusOK = c.link:find(want.bonus:gsub("/", ":"), 1, true) ~= nil
                        end

                        if bonusOK then
                            local legal = ns.Scanner:LegalSlots(c) or {}
                            local target

                            if pass.inPlace then
                                -- Only where it already sits, and only if that
                                -- is still a legal home for it.
                                local at = c.where.equipped
                                if at and contains(legal, at) then target = at end
                            else
                                for _, sl in ipairs(legal) do
                                    if not plan[sl] then target = sl break end
                                end
                            end

                            if target and not plan[target] then
                                plan[target] = c
                                used[key] = true
                                want.matched = true
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    for _, want in ipairs(wanted) do
        if not want.matched then missing[#missing + 1] = want.id end
    end

    local changes = {}
    for _, slot in ipairs(ns.INV_SLOTS) do
        local w, h = plan[slot.id], equipped[slot.id]
        if w and (not h or w.link ~= h.link) then
            changes[#changes + 1] = { slot = slot.id, from = h and h.link, to = w.link, gain = 0 }
        end
    end

    return { plan = plan, changes = changes, missing = missing, fromQE = true }
end
