local ADDON, ns = ...
local W = {}
ns.Weights = W

-- Sane starting points so the addon is useful before QE Live has ever answered.
-- Everything here is overwritten the first time a real result comes back.
local HEALER = { intellect = 1.00, stamina = 0.01, crit = 0.42, haste = 0.45,
                 mastery = 0.40, versatility = 0.41, leech = 0.20, speed = 0.05,
                 avoidance = 0.05, weaponDPS = 0.10 }

local function healer(crit, haste, mastery, vers)
    local t = ns.CopyTable(HEALER)
    t.crit, t.haste, t.mastery, t.versatility = crit, haste, mastery, vers
    return t
end

W.defaults = {
    [65]   = healer(0.44, 0.40, 0.52, 0.42),  -- Holy Paladin
    [105]  = healer(0.40, 0.52, 0.44, 0.42),  -- Restoration Druid
    [256]  = healer(0.50, 0.46, 0.38, 0.44),  -- Discipline Priest
    [257]  = healer(0.46, 0.44, 0.42, 0.42),  -- Holy Priest
    [264]  = healer(0.44, 0.48, 0.42, 0.40),  -- Restoration Shaman
    [270]  = healer(0.46, 0.50, 0.38, 0.42),  -- Mistweaver Monk
    [1468] = healer(0.48, 0.44, 0.42, 0.42),  -- Preservation Evoker
}

local PRIMARY_BY_CLASS = {
    WARRIOR = "strength", PALADIN = "strength", DEATHKNIGHT = "strength",
    HUNTER = "agility", ROGUE = "agility", SHAMAN = "agility", MONK = "agility",
    DRUID = "agility", DEMONHUNTER = "agility", EVOKER = "intellect",
    MAGE = "intellect", WARLOCK = "intellect", PRIEST = "intellect",
}

-- Specs whose primary stat is intellect even though the class is usually not.
local INT_SPECS = { [65] = true, [105] = true, [264] = true, [270] = true,
                    [102] = true, [262] = true, [63] = true, [64] = true, [62] = true }

function W:Generic(specID, class)
    local primary = PRIMARY_BY_CLASS[class] or "intellect"
    if INT_SPECS[specID] then primary = "intellect" end
    local t = { stamina = 0.01, crit = 0.40, haste = 0.40, mastery = 0.40,
                versatility = 0.40, leech = 0.15, speed = 0.05, avoidance = 0.05,
                weaponDPS = 0.60 }
    t[primary] = 1.00
    return t
end

function W:Get(specID)
    local db = QEAutoGearCharDB
    if db and db.weights and db.weights[specID] then return db.weights[specID], db.weightSource[specID] end
    if self.defaults[specID] then return self.defaults[specID], "bundled default" end
    local _, class = UnitClass("player")
    return self:Generic(specID, class), "generic fallback"
end

function W:Set(specID, weights, source)
    local db = QEAutoGearCharDB
    db.weights = db.weights or {}
    db.weightSource = db.weightSource or {}
    -- Normalise to primary stat = 1.0 so scores stay comparable between runs.
    local primary = weights.intellect or weights.agility or weights.strength
    if primary and primary > 0 and math.abs(primary - 1) > 0.001 then
        for k, v in pairs(weights) do weights[k] = v / primary end
    end
    db.weights[specID] = weights
    db.weightSource[specID] = source or "QE Live"
end

local ALIASES = {
    int = "intellect", intellect = "intellect", intelligence = "intellect",
    agi = "agility", agility = "agility",
    str = "strength", strength = "strength",
    sta = "stamina", stamina = "stamina",
    crit = "crit", criticalstrike = "crit", critrating = "crit",
    haste = "haste", hasterating = "haste",
    mastery = "mastery", masteryrating = "mastery",
    vers = "versatility", versatility = "versatility", versrating = "versatility",
    leech = "leech", lifesteal = "leech",
    speed = "speed", avoidance = "avoidance",
    hps = "hps", dps = "weaponDPS", weapondps = "weaponDPS",
}

-- Tolerant parser: eats "Intellect: 1.00", "crit = 0.42", '"haste":0.51', CSV rows.
function W:Parse(text)
    local out, count = {}, 0
    for rawKey, value in text:gmatch("([%a][%a%s_]-)%s*[:=,]?%s*([%d%.]+)") do
        local key = ALIASES[rawKey:lower():gsub("[%s_]", "")]
        local num = tonumber(value)
        if key and num and key ~= "hps" then
            out[key] = num
            count = count + 1
        end
    end
    if count == 0 then return nil, "no recognisable stat names in that text" end
    if not (out.intellect or out.agility or out.strength) then
        return nil, "no primary stat (Intellect/Agility/Strength) found"
    end
    return out, count
end
