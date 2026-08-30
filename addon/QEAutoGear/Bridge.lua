local ADDON, ns = ...
local B = {}
ns.Bridge = B

--[[--------------------------------------------------------------------------
  Getting data OUT of the game.

  Addon Lua has no networking, and SavedVariables only reach disk on logout or
  /reload. So instead we paint the payload as a grid of flat-coloured squares in
  the corner of the screen and call Screenshot(). With screenshotFormat=png the
  file on disk is lossless, so the companion agent can read the bytes straight
  back out of the image. No reload, no user action.

  Each cell carries three 4-bit nibbles, one per colour channel, at 17 units per
  step. That leaves +/-8 of slack per channel, so the decode survives render
  scaling, sharpening, and mild colour management.

  Getting data BACK IN: the agent writes Payload.lua inside a LoadOnDemand stub
  addon, and we LoadAddOn() it. LoD addons are read from disk at load time, so
  the fresh contents arrive mid-session.
----------------------------------------------------------------------------]]

local MAGIC       = { 81, 69, 65, 71 } -- "QEAG"
local HEADER_LEN  = 18
local COLS, ROWS  = 64, 16
local CELL        = 10
-- Row 0 is the ruler: magenta at column 0, cyan at the far column. The agent
-- measures cell size across that whole span, so a client rendering below native
-- resolution cannot accumulate positioning error across the grid. Data starts
-- on row 1.
local DATA_START  = COLS

local frame, cells

local function buildFrame()
    if frame then return end
    frame = CreateFrame("Frame", "QEAutoGearBridgeFrame", UIParent)
    frame:SetFrameStrata("TOOLTIP")
    frame:SetFrameLevel(9999)
    -- Draw in raw screen pixels, so UI scale cannot smear the grid.
    if frame.SetIgnoreParentScale then frame:SetIgnoreParentScale(true) end
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
    frame:SetSize(COLS * CELL, ROWS * CELL)
    frame:Hide()

    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 1)

    cells = {}
    for i = 0, COLS * ROWS - 1 do
        local col, row = i % COLS, math.floor(i / COLS)
        local t = frame:CreateTexture(nil, "ARTWORK")
        t:SetSize(CELL, CELL)
        t:SetPoint("TOPLEFT", frame, "TOPLEFT", col * CELL, -row * CELL)
        t:SetColorTexture(0, 0, 0, 1)
        cells[i] = t
    end
end

function B:Capacity()
    return math.floor((COLS * ROWS - DATA_START) * 3 / 2) - HEADER_LEN
end

local function paint(bytes)
    buildFrame()
    for i = 0, DATA_START - 1 do cells[i]:SetColorTexture(0, 0, 0, 1) end
    cells[0]:SetColorTexture(1, 0, 1, 1)        -- ruler origin
    cells[COLS - 1]:SetColorTexture(0, 1, 1, 1) -- ruler end

    -- Flatten the byte stream to nibbles, three per cell.
    local nibbles, n = {}, 0
    for i = 1, #bytes do
        local b = bytes[i]
        n = n + 1; nibbles[n] = math.floor(b / 16)
        n = n + 1; nibbles[n] = b % 16
    end

    local cell = DATA_START
    for i = 1, n, 3 do
        local r = (nibbles[i] or 0) * 17
        local g = (nibbles[i + 1] or 0) * 17
        local b = (nibbles[i + 2] or 0) * 17
        local t = cells[cell]
        if not t then break end
        t:SetColorTexture(r / 255, g / 255, b / 255, 1)
        cell = cell + 1
    end
    for i = cell, COLS * ROWS - 1 do
        cells[i]:SetColorTexture(0, 0, 0, 1)
    end
end

local function u16(t, v)
    t[#t + 1] = math.floor(v / 256) % 256
    t[#t + 1] = v % 256
end

local function buildStream(chunk, frameIdx, frameTotal, jobID)
    local bytes = {}
    for _, m in ipairs(MAGIC) do bytes[#bytes + 1] = m end
    bytes[#bytes + 1] = ns.PROTOCOL
    bytes[#bytes + 1] = 0 -- flags
    u16(bytes, frameIdx)
    u16(bytes, frameTotal)
    u16(bytes, #chunk)
    bytes[#bytes + 1] = math.floor(jobID / 16777216) % 256
    bytes[#bytes + 1] = math.floor(jobID / 65536) % 256
    bytes[#bytes + 1] = math.floor(jobID / 256) % 256
    bytes[#bytes + 1] = jobID % 256

    local body = {}
    for i = 1, #chunk do body[i] = chunk:byte(i) end
    u16(bytes, #body > 0 and ns.CRC16(body, 1, #body) or 0)

    for i = 1, #body do bytes[#bytes + 1] = body[i] end
    return bytes
end

----------------------------------------------------------------------------
-- Screenshot plumbing
----------------------------------------------------------------------------

local savedCVars, filterInstalled = nil, false

local function screenshotFilter(_, _, msg)
    if msg and (msg:find("Screenshot", 1, true) or msg:find(".png", 1, true)
                or msg:find(".jpg", 1, true) or msg:find(".tga", 1, true)) then
        return true
    end
end

local function beginCapture()
    if not savedCVars then
        savedCVars = {
            format = GetCVar("screenshotFormat"),
            quality = GetCVar("screenshotQuality"),
        }
    end
    SetCVar("screenshotFormat", "png")
    SetCVar("screenshotQuality", "10")
    if not filterInstalled then
        ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", screenshotFilter)
        filterInstalled = true
    end
end

local function endCapture()
    if savedCVars then
        SetCVar("screenshotFormat", savedCVars.format or "jpg")
        SetCVar("screenshotQuality", savedCVars.quality or "6")
        savedCVars = nil
    end
    if filterInstalled then
        ChatFrame_RemoveMessageEventFilter("CHAT_MSG_SYSTEM", screenshotFilter)
        filterInstalled = false
    end
    if frame then frame:Hide() end
end

-- Emits the text as a sequence of screenshots, one frame at a time.
function B:Send(text, jobID, onDone)
    local capacity = self:Capacity()
    local chunks = {}
    for i = 1, #text, capacity do
        chunks[#chunks + 1] = text:sub(i, i + capacity - 1)
    end
    if #chunks == 0 then chunks[1] = "" end

    ns.Debug("bridge: %d bytes in %d frame(s), job %d", #text, #chunks, jobID)
    beginCapture()

    local index = 1
    local function sendNext()
        if index > #chunks then
            endCapture()
            if onDone then onDone(#chunks) end
            return
        end
        paint(buildStream(chunks[index], index - 1, #chunks, jobID))
        frame:Show()
        index = index + 1
        -- One frame to let the grid actually render, then capture.
        C_Timer.After(0.10, function()
            Screenshot()
            -- WoW names screenshots WoWScrnShot_MMDDYY_HHMMSS - one second of
            -- resolution. Two captures inside the same second collide on the
            -- filename and the later one silently destroys the earlier, losing
            -- a frame. Stay clear of that boundary.
            C_Timer.After(1.20, sendNext)
        end)
    end
    sendNext()
end

----------------------------------------------------------------------------
-- Getting results back in, via LoadOnDemand payload stubs
----------------------------------------------------------------------------

local LoadAddOn = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
local IsAddOnLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded

function B:SlotName(i) return ("QEAutoGear_P%02d"):format(i) end

function B:SlotsRemaining()
    local db = QEAutoGearDB
    return ns.PAYLOAD_SLOTS - (db.nextSlot or 1) + 1
end

-- Loads the next unused stub. Returns false when we are out for this session.
function B:PollOnce()
    local db = QEAutoGearDB
    db.nextSlot = db.nextSlot or 1
    while db.nextSlot <= ns.PAYLOAD_SLOTS do
        local name = self:SlotName(db.nextSlot)
        db.nextSlot = db.nextSlot + 1
        if not IsAddOnLoaded(name) then
            local ok, err = LoadAddOn(name)
            ns.Debug("bridge: loaded %s -> %s", name, tostring(ok or err))
            return ok and true or false, err
        end
    end
    return false, "out of payload slots"
end

-- The payload files call this. Defined globally so a freshly loaded stub can
-- reach it.
function QEAutoGear_Ingest(data)
    if type(data) ~= "table" then return end
    ns.Debug("bridge: ingest job=%s status=%s", tostring(data.job), tostring(data.status))
    if ns.Core then ns.Core:OnResult(data) end
end
