local ADDON, ns = ...
local E = {}
ns.Export = E

-- item:ID:enchant:g1:g2:g3:g4:suffix:unique:level:specID:mask:context:numBonus:<bonus...>:numMods:<type:value...>
local function parseItemString(link)
    -- Take everything between |Hitem: and |h without assuming it is numeric.
    -- Retail item strings can carry a crafterGUID such as Player-1084-0AB6C7D2,
    -- and a digits-only pattern fails the whole match on the first letter --
    -- which silently dropped crafted and personal-crafted gear from the export.
    local body = link:match("|Hitem:([^|]+)|h") or link:match("^item:(.+)$")
    if not body then return nil end

    -- Split on every colon so field positions survive; anything non-numeric
    -- (the GUID) becomes 0 and is simply not used.
    local f = {}
    for token in (body .. ":"):gmatch("([^:]*):") do f[#f + 1] = tonumber(token) or 0 end

    local out = { id = f[1], enchant = f[2], gems = { f[3], f[4], f[5], f[6] } }

    local idx = 14
    local numBonus = f[13] or 0
    out.bonus = {}
    for i = 0, numBonus - 1 do
        local v = f[idx + i]
        if v and v ~= 0 then out.bonus[#out.bonus + 1] = v end
    end
    idx = idx + numBonus

    local numMods = f[idx] or 0
    idx = idx + 1
    out.mods = {}
    for i = 0, numMods - 1 do
        local mType, mValue = f[idx + i * 2], f[idx + i * 2 + 1]
        if mType then out.mods[mType] = mValue end
    end

    return out
end

-- One SimC gear line. QE Live's importer reads exactly this shape.
function E:ItemLine(slotName, link, comment)
    local p = parseItemString(link)
    if not p or p.id == 0 then return nil end

    local parts = { ("%s=,id=%d"):format(slotName, p.id) }
    if #p.bonus > 0 then
        parts[#parts + 1] = "bonus_id=" .. table.concat(p.bonus, "/")
    end
    if p.enchant and p.enchant ~= 0 then
        parts[#parts + 1] = "enchant_id=" .. p.enchant
    end
    local gems = {}
    for _, g in ipairs(p.gems) do if g ~= 0 then gems[#gems + 1] = g end end
    if #gems > 0 then parts[#parts + 1] = "gem_id=" .. table.concat(gems, "/") end

    -- Modifier 29/30 carry the two chosen crafted stats on crafted gear.
    local c1, c2 = p.mods[29], p.mods[30]
    if c1 and c1 ~= 0 then
        parts[#parts + 1] = "crafted_stats=" .. c1 .. (c2 and c2 ~= 0 and ("/" .. c2) or "")
    end
    if p.mods[9] and p.mods[9] ~= 0 then
        parts[#parts + 1] = "drop_level=" .. p.mods[9]
    end

    local line = table.concat(parts, ",")
    return comment and ("# " .. line) or line
end

local REGIONS = { "us", "kr", "eu", "tw", "cn" }

function E:Build(includeBank)
    local specIndex = GetSpecialization()
    if not specIndex then return nil, "no specialisation selected" end
    local specID, specName = GetSpecializationInfo(specIndex)

    local _, classFile = UnitClass("player")
    local _, raceFile = UnitRace("player")
    local name = UnitName("player")

    local lines = {}
    local function add(s) lines[#lines + 1] = s end

    add(("# QE AutoGear %s - generated in game"):format(ns.VERSION))
    add(("# %s"):format(specName or "?"))
    add("")
    add(("%s=\"%s\""):format(ns.Tokenize(classFile), name))
    add("level=" .. UnitLevel("player"))
    add("race=" .. ns.Tokenize(raceFile))
    add("region=" .. (REGIONS[GetCurrentRegion() or 1] or "us"))
    add("server=" .. ns.Tokenize(GetRealmName(), "-"))
    add("role=attack")
    add("spec=" .. ns.Tokenize(specName or ""))

    if C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_Traits then
        local cfg = C_ClassTalents.GetActiveConfigID()
        if cfg then
            local ok, str = pcall(C_Traits.GenerateImportString, cfg)
            if ok and str and str ~= "" then add("talents=" .. str) end
        end
    end
    add("")

    local equipped, candidates = ns.Scanner:ScanAll(includeBank)

    for _, slot in ipairs(ns.INV_SLOTS) do
        local link = GetInventoryItemLink("player", slot.id)
        if link then
            local line = self:ItemLine(slot.simc, link)
            if line then add(line) end
        end
    end

    add("")
    add("### Gear from Bags")
    add("#")

    local seen, bagCount = {}, 0
    for _, c in ipairs(candidates) do
        if c.where.bag and not seen[c.link] then
            seen[c.link] = true
            local slotName = ns.INV_SLOTS[1].simc
            for _, s in ipairs(ns.INV_SLOTS) do
                local legal = ns.Scanner:LegalSlots(c)
                if legal and legal[1] == s.id then slotName = s.simc break end
            end
            local line = self:ItemLine(slotName, c.link, true)
            if line then add(line); bagCount = bagCount + 1 end
        end
    end

    local text = table.concat(lines, "\n")
    return text, { specID = specID, specName = specName, bagItems = bagCount }
end
