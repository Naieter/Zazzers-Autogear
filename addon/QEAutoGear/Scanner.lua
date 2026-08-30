local ADDON, ns = ...
local S = {}
ns.Scanner = S

local GetItemStats     = (C_Item and C_Item.GetItemStats) or GetItemStats
local GetItemInfo      = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local GetContainerNumSlots = C_Container.GetContainerNumSlots
local GetContainerItemLink = C_Container.GetContainerItemLink

local STAT_MAP = {
    ITEM_MOD_STRENGTH_SHORT     = "strength",
    ITEM_MOD_AGILITY_SHORT      = "agility",
    ITEM_MOD_INTELLECT_SHORT    = "intellect",
    ITEM_MOD_STAMINA_SHORT      = "stamina",
    ITEM_MOD_CRIT_RATING_SHORT  = "crit",
    ITEM_MOD_HASTE_RATING_SHORT = "haste",
    ITEM_MOD_MASTERY_RATING_SHORT = "mastery",
    ITEM_MOD_VERSATILITY        = "versatility",
    ITEM_MOD_CR_LIFESTEAL_SHORT = "leech",
    ITEM_MOD_CR_SPEED_SHORT     = "speed",
    ITEM_MOD_CR_AVOIDANCE_SHORT = "avoidance",
}

-- Build a Lua pattern out of the localised "(%s damage per second)" template so
-- weapon DPS can be read off the tooltip; there is no API that returns it.
local DPS_PATTERN = "([%d%.,]+)"
do
    local tpl = _G.DPS_TEMPLATE
    if tpl then DPS_PATTERN = "^" .. tpl:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0"):gsub("%%%%s", "([%%d%%.,]+)") .. "$" end
end

local function tooltipLines(link)
    if C_TooltipInfo and C_TooltipInfo.GetHyperlink then
        local data = C_TooltipInfo.GetHyperlink(link)
        if data then
            if TooltipUtil and TooltipUtil.SurfaceArgs then TooltipUtil.SurfaceArgs(data) end
            local out = {}
            for _, line in ipairs(data.lines or {}) do
                if TooltipUtil and TooltipUtil.SurfaceArgs then TooltipUtil.SurfaceArgs(line) end
                out[#out + 1] = { text = line.leftText, color = line.leftColor }
            end
            return out
        end
    end
    return nil
end

local cache = {}

-- Everything we need to know about one item, memoised per item link.
function S:Inspect(link)
    if not link then return nil end
    if cache[link] then return cache[link] end

    local itemID, _, _, equipLoc = GetItemInfoInstant(link)
    if not itemID then return nil end
    if not ns.EQUIPLOC_SLOTS[equipLoc] then return nil end

    local name, _, quality, baseIlvl, _, _, _, _, _, _, _, classID, subclassID, _, _, setID = GetItemInfo(link)
    if not name then
        C_Item.RequestLoadItemDataByID(itemID)
        return nil, "loading"
    end

    local info = {
        link = link, itemID = itemID, name = name, quality = quality,
        equipLoc = equipLoc, classID = classID, subclassID = subclassID,
        setID = setID, ilvl = baseIlvl, stats = {}, usable = true,
        uniqueEquipped = false, dps = 0,
    }

    if C_Item.GetDetailedItemLevelInfo then
        info.ilvl = C_Item.GetDetailedItemLevelInfo(link) or baseIlvl
    end

    local stats = GetItemStats(link)
    if stats then
        for key, value in pairs(stats) do
            local mapped = STAT_MAP[key]
            if mapped then info.stats[mapped] = (info.stats[mapped] or 0) + value end
        end
    end

    local lines = tooltipLines(link)
    if lines then
        for _, line in ipairs(lines) do
            local text, c = line.text, line.color
            if text then
                if text == _G.ITEM_UNIQUE_EQUIPPABLE or text:find(_G.ITEM_UNIQUE_EQUIPPABLE or "\1", 1, true) then
                    info.uniqueEquipped = true
                end
                local dps = text:match(DPS_PATTERN)
                if dps then info.dps = tonumber((dps:gsub(",", ""))) or 0 end
                -- Red tooltip text is the game telling us we cannot use it.
                if c and c.r and c.r > 0.9 and c.g < 0.2 and c.b < 0.2 then
                    info.usable = false
                end
            end
        end
    end

    cache[link] = info
    return info
end

function S:WipeCache() wipe(cache) end

function S:LegalSlots(info)
    local slots = ns.EQUIPLOC_SLOTS[info.equipLoc]
    if info.equipLoc == "INVTYPE_WEAPON" and not CanDualWield() then return { 16 } end
    if info.equipLoc == "INVTYPE_2HWEAPON" and IsSpellKnown(46917) then return { 16, 17 } end
    return slots
end

local function bagList(includeBank)
    local bags = {}
    for b = 0, (NUM_BAG_SLOTS or 4) do bags[#bags + 1] = b end
    local reagent = Enum.BagIndex and Enum.BagIndex.ReagentBag
    if reagent then bags[#bags + 1] = reagent end
    if includeBank then
        bags[#bags + 1] = BANK_CONTAINER or -1
        for b = (NUM_BAG_SLOTS or 4) + 1, (NUM_BAG_SLOTS or 4) + (NUM_BANKBAGSLOTS or 7) do
            bags[#bags + 1] = b
        end
        if Enum.BagIndex and Enum.BagIndex.AccountBankTab_1 then
            for t = 0, 4 do bags[#bags + 1] = Enum.BagIndex.AccountBankTab_1 + t end
        end
    end
    return bags
end

-- Returns equipped[slotID] = candidate, and a flat list of every candidate found
-- anywhere (equipped + bags), each tagged with where it physically lives.
function S:ScanAll(includeBank)
    local equipped, candidates, pending = {}, {}, 0

    for _, slot in ipairs(ns.INV_SLOTS) do
        local link = GetInventoryItemLink("player", slot.id)
        if link then
            local info, why = self:Inspect(link)
            if info then
                local c = ns.CopyTable(info)
                c.where = { equipped = slot.id }
                c.currentSlot = slot.id
                equipped[slot.id] = c
                candidates[#candidates + 1] = c
            elseif why == "loading" then pending = pending + 1 end
        end
    end

    for _, bag in ipairs(bagList(includeBank)) do
        local size = GetContainerNumSlots(bag) or 0
        for slot = 1, size do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local info, why = self:Inspect(link)
                if info and info.usable then
                    local c = ns.CopyTable(info)
                    c.where = { bag = bag, slot = slot }
                    candidates[#candidates + 1] = c
                elseif why == "loading" then pending = pending + 1 end
            end
        end
    end

    return equipped, candidates, pending
end
