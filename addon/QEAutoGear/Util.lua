local ADDON, ns = ...

ns.VERSION      = "1.0.6"
ns.PROTOCOL     = 1
ns.PAYLOAD_SLOTS = 24

local PREFIX = "|cff33ff99QE AutoGear|r: "

function ns.Print(fmt, ...)
    local msg = select("#", ...) > 0 and fmt:format(...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

-- Indented and unprefixed: a full re-gear prints one line per piece, and
-- repeating the addon name down the side of all of them is just noise.
function ns.Detail(fmt, ...)
    local msg = select("#", ...) > 0 and fmt:format(...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage("    " .. msg)
end

function ns.Debug(fmt, ...)
    if not (QEAutoGearDB and QEAutoGearDB.debug) then return end
    local msg = select("#", ...) > 0 and fmt:format(...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage("|cff888888[qeag]|r " .. msg)
end

function ns.Round(v, places)
    local m = 10 ^ (places or 0)
    return math.floor(v * m + 0.5) / m
end

-- Deterministic 32-bit job id from a string + time, so payloads can be matched
-- back to the request that produced them.
function ns.HashString(s)
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 4294967296
    end
    return h
end

-- WoW runs Lua 5.1, so the 5.3 bitwise operators are not available. The bit
-- library has shipped with the client for years; the fallbacks below keep this
-- honest if it ever is not there.
local bitlib = _G.bit

local function fallbackBxor(a, b)
    local result, shift = 0, 1
    while a > 0 or b > 0 do
        local abit, bbit = a % 2, b % 2
        if abit ~= bbit then result = result + shift end
        a, b, shift = math.floor(a / 2), math.floor(b / 2), shift * 2
    end
    return result
end

ns.bxor   = bitlib and bitlib.bxor or fallbackBxor
ns.rshift = bitlib and bitlib.rshift or function(v, n) return math.floor(v / 2 ^ n) end

-- Only ever masked against 0xFF / 0x0F / 1, so modulo is exact and cheap.
function ns.mask(v, m) return v % (m + 1) end

function ns.CRC16(bytes, from, to)
    local crc = 0xFFFF
    for i = from, to do
        crc = ns.bxor(crc, bytes[i])
        for _ = 1, 8 do
            if crc % 2 == 1 then
                crc = ns.bxor(math.floor(crc / 2), 0xA001)
            else
                crc = math.floor(crc / 2)
            end
        end
    end
    return crc % 0x10000
end

function ns.CopyTable(t)
    local out = {}
    for k, v in pairs(t) do
        out[k] = type(v) == "table" and ns.CopyTable(v) or v
    end
    return out
end

-- SimC-style tokenizer: "Night Elf" -> "night_elf", "Area 52" -> "area-52"
function ns.Tokenize(s, sep)
    sep = sep or "_"
    s = s:gsub("([a-z0-9])([A-Z])", "%1 %2")
    s = s:lower():gsub("['\"]", ""):gsub("[%s%-]+", sep):gsub("[^%w" .. sep .. "]", "")
    return s
end

ns.INV_SLOTS = {
    { id = 1,  simc = "head" },
    { id = 2,  simc = "neck" },
    { id = 3,  simc = "shoulder" },
    { id = 15, simc = "back" },
    { id = 5,  simc = "chest" },
    { id = 9,  simc = "wrist" },
    { id = 10, simc = "hands" },
    { id = 6,  simc = "waist" },
    { id = 7,  simc = "legs" },
    { id = 8,  simc = "feet" },
    { id = 11, simc = "finger1" },
    { id = 12, simc = "finger2" },
    { id = 13, simc = "trinket1" },
    { id = 14, simc = "trinket2" },
    { id = 16, simc = "main_hand" },
    { id = 17, simc = "off_hand" },
}

ns.SLOT_NAME = {
    [1] = "Head", [2] = "Neck", [3] = "Shoulder", [5] = "Chest", [6] = "Waist",
    [7] = "Legs", [8] = "Feet", [9] = "Wrist", [10] = "Hands", [11] = "Ring 1",
    [12] = "Ring 2", [13] = "Trinket 1", [14] = "Trinket 2", [15] = "Back",
    [16] = "Main Hand", [17] = "Off Hand",
}

-- Which inventory slots an equipLoc is legal in.
ns.EQUIPLOC_SLOTS = {
    INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 },
    INVTYPE_CLOAK = { 15 }, INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 },
    INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 }, INVTYPE_WAIST = { 6 },
    INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 },
    INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 },
    INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 },
    INVTYPE_RANGED = { 16 }, INVTYPE_RANGEDRIGHT = { 16 },
    INVTYPE_WEAPON = { 16, 17 },
    INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_SHIELD = { 17 }, INVTYPE_HOLDABLE = { 17 },
}

-- QE Live models these seven healer specs and nothing else.
ns.QE_SPECS = {
    [65]   = "Holy Paladin",
    [105]  = "Restoration Druid",
    [256]  = "Discipline Priest",
    [257]  = "Holy Priest",
    [264]  = "Restoration Shaman",
    [270]  = "Mistweaver Monk",
    [1468] = "Preservation Evoker",
}

-- Which site does the maths for a given spec. QE Live models healers; every
-- other spec is a Raidbots job. The two are automated very differently: QE
-- Live is JavaScript in your own browser, while Raidbots runs SimulationCraft
-- on hardware they pay for, so the addon never submits a sim there by itself.
function ns.SimSite(specID)
    if ns.QE_SPECS[specID] then return "QE Live", "https://questionablyepic.com/live" end
    return "Raidbots", "https://www.raidbots.com/simbot/topgear"
end
