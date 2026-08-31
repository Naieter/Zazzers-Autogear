local ADDON, ns = ...
local Eq = {}
ns.Equipper = Eq

local GetContainerItemLink = C_Container.GetContainerItemLink
local GetContainerNumSlots = C_Container.GetContainerNumSlots
local PickupContainerItem  = C_Container.PickupContainerItem

local queue, running = {}, false
-- Slots we have already satisfied. Protects them from being raided as the
-- source for a later swap (matters for ring and trinket shuffles).
local settled = {}

local function bagList(includeBank)
    local bags = { 0, 1, 2, 3, 4 }
    if Enum.BagIndex and Enum.BagIndex.ReagentBag then bags[#bags + 1] = Enum.BagIndex.ReagentBag end
    if includeBank then
        bags[#bags + 1] = BANK_CONTAINER or -1
        for b = 5, 12 do bags[#bags + 1] = b end
    end
    return bags
end

-- Resolved fresh at every step: an earlier swap may have moved the item.
local function findLink(link, includeBank)
    for _, slot in ipairs(ns.INV_SLOTS) do
        if not settled[slot.id] and GetInventoryItemLink("player", slot.id) == link then
            return { equipped = slot.id }
        end
    end
    for _, bag in ipairs(bagList(includeBank)) do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            if GetContainerItemLink(bag, slot) == link then return { bag = bag, slot = slot } end
        end
    end
    return nil
end

local swapped, skipped

local function finish()
    running = false
    wipe(settled)
    if skipped > 0 then
        ns.Print("done - %d piece(s) swapped, %d skipped.", swapped, skipped)
    else
        ns.Print("done - %d piece(s) swapped.", swapped)
    end
    if ns.UI then ns.UI:Refresh() end
end

-- Equipping a bind-on-equip item raises a confirmation dialog. That is the
-- player's decision to make - it destroys the item's trade and sell value - so
-- the queue waits rather than answering it.
local BIND_POPUPS = {
    "EQUIP_BIND", "EQUIP_BIND_TRADEABLE", "EQUIP_BIND_REFUNDABLE",
    "EQUIP_BIND_TRADEABLE_REFUNDABLE", "END_BOUND_TRADEABLE", "END_REFUND",
}

local function bindPopupVisible()
    if not StaticPopup_Visible then return nil end
    for _, which in ipairs(BIND_POPUPS) do
        if StaticPopup_Visible(which) then return which end
    end
    return nil
end

local step

-- Equipping is not instant, and it can silently fail: the wrong armour class,
-- a level requirement, a full bag with nowhere for the displaced item. Confirm
-- the slot actually holds what we asked for before claiming it swapped.
local function verify(task, previous, waited, warned)
    local now = GetInventoryItemLink("player", task.slot)
    local slotName = ns.SLOT_NAME[task.slot] or ("Slot " .. task.slot)

    if now == task.link then
        if GetCursorInfo() then ClearCursor() end
        swapped = swapped + 1
        if previous then
            ns.Detail("|cffaaaaaa%s:|r %s  |cff888888->|r  %s", slotName, previous, task.link)
        else
            ns.Detail("|cffaaaaaa%s:|r %s  |cff888888(was empty)|r", slotName, task.link)
        end
        settled[task.slot] = true
        return C_Timer.After(0.10, step)
    end

    if bindPopupVisible() then
        if not warned then
            ns.Print("|cffff8800%s binds when equipped|r - confirm the dialog and it "
                     .. "will carry on.", task.link)
        end
        if waited < 120 then
            return C_Timer.After(0.5, function() verify(task, previous, waited + 1, true) end)
        end
    elseif waited < 10 then
        return C_Timer.After(0.25, function() verify(task, previous, waited + 1, warned) end)
    end

    if GetCursorInfo() then ClearCursor() end
    skipped = skipped + 1
    ns.Print("|cffff4444could not equip|r %s into %s%s.", task.link, slotName,
             now and (" - still wearing " .. now) or "")
    settled[task.slot] = true
    C_Timer.After(0.10, step)
end

function step()
    if #queue == 0 then return finish() end

    if InCombatLockdown() then
        ns.Print("in combat - holding %d remaining swap(s) until you drop out.", #queue)
        C_Timer.After(2, step)
        return
    end

    local task = table.remove(queue, 1)

    if GetInventoryItemLink("player", task.slot) == task.link then
        settled[task.slot] = true
        return step()
    end

    local where = findLink(task.link, task.includeBank)
    if not where then
        skipped = skipped + 1
        ns.Print("|cffff8800lost track of|r %s - skipping that slot.", task.link)
        return C_Timer.After(0.05, step)
    end

    -- Read what is coming off now rather than trusting the plan's snapshot:
    -- an earlier swap in this same queue may already have moved it.
    local previous = GetInventoryItemLink("player", task.slot)

    ClearCursor()
    if where.equipped then
        PickupInventoryItem(where.equipped)
    else
        PickupContainerItem(where.bag, where.slot)
    end

    if not GetCursorInfo() then
        skipped = skipped + 1
        ns.Print("|cffff4444could not pick up|r %s.", task.link)
        settled[task.slot] = true
        return C_Timer.After(0.10, step)
    end

    EquipCursorItem(task.slot)
    -- Deliberately no ClearCursor() here. A bind-on-equip item leaves a
    -- confirmation dialog with the item still on the cursor; clearing it
    -- cancels the equip. verify() tidies up once the outcome is known.
    verify(task, previous, 0, false)
end

function Eq:Apply(result, includeBank)
    if running then
        ns.Print("already applying a set.")
        return
    end
    if InCombatLockdown() then
        ns.Print("|cffff8800can't swap gear in combat.|r Queued until you leave combat.")
        ns.pendingApply = { result = result, includeBank = includeBank }
        return
    end

    wipe(queue)
    wipe(settled)
    swapped, skipped = 0, 0

    for _, change in ipairs(result.changes) do
        queue[#queue + 1] = { slot = change.slot, link = change.to, includeBank = includeBank }
    end

    if #queue == 0 then
        ns.Print("already wearing the best set - nothing to swap.")
        return
    end

    ns.Print("swapping %d piece(s)...", #queue)
    running = true
    step()
end

function Eq:IsRunning() return running end
