local ADDON, ns = ...
local UI = {}
ns.UI = UI

local panel, rows, statusText

local function makeButton(parent, label, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

local function makeCheck(parent, label, get, set)
    -- Own label rather than a template-supplied one: the option templates have
    -- been renamed more than once across expansions.
    local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    c:SetSize(24, 24)
    local text = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", c, "RIGHT", 2, 0)
    text:SetText(label)
    c:SetScript("OnShow", function(self) self:SetChecked(get()) end)
    c:SetScript("OnClick", function(self)
        set(self:GetChecked() and true or false)
        UI:Refresh()
    end)
    c:SetChecked(get())
    return c
end

----------------------------------------------------------------------------
-- Scrollable text box, used for both export and paste-in
----------------------------------------------------------------------------

local textFrame

local function buildTextFrame()
    if textFrame then return textFrame end
    local f = CreateFrame("Frame", "QEAutoGearTextFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(560, 380)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()

    local scroll = CreateFrame("ScrollFrame", "$parentScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -32)
    scroll:SetPoint("BOTTOMRIGHT", -32, 44)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetFontObject(ChatFontNormal)
    edit:SetWidth(500)
    edit:SetAutoFocus(false)
    edit:SetScript("OnEscapePressed", function() f:Hide() end)
    scroll:SetScrollChild(edit)
    f.edit = edit

    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.hint:SetPoint("BOTTOMLEFT", 14, 16)

    f.action = makeButton(f, "Close", 120, function() f:Hide() end)
    f.action:SetPoint("BOTTOMRIGHT", -14, 12)

    textFrame = f
    return f
end

function UI:ShowText(title, text)
    local f = buildTextFrame()
    f.TitleText:SetText(title)
    f.edit:SetText(text)
    f.edit:SetCursorPosition(0)
    f.hint:SetText("Ctrl+C to copy. This is the string QE Live's IMPORT GEAR box wants.")
    f.action:SetText("Close")
    f.action:SetScript("OnClick", function() f:Hide() end)
    f:Show()
    C_Timer.After(0.05, function()
        f.edit:SetFocus()
        f.edit:HighlightText()
    end)
end

function UI:ShowWeightsImport()
    local f = buildTextFrame()
    f.TitleText:SetText("Paste stat weights from QE Live")
    f.edit:SetText("")
    f.hint:SetText("Anything containing stat names and numbers works, e.g. Intellect 1.0  Crit 0.42 ...")
    f.action:SetText("Import")
    f.action:SetScript("OnClick", function()
        local weights, count = ns.Weights:Parse(f.edit:GetText())
        if not weights then
            ns.Print("|cffff4444%s|r", count)
            return
        end
        local specIndex = GetSpecialization()
        local specID = specIndex and GetSpecializationInfo(specIndex)
        ns.Weights:Set(specID, weights, "pasted by hand")
        ns.Print("imported %d stat weights.", count)
        f:Hide()
        ns.Core:RunLocal(false)
    end)
    f:Show()
    C_Timer.After(0.05, function() f.edit:SetFocus() end)
end

----------------------------------------------------------------------------
-- Main panel
----------------------------------------------------------------------------

local function build()
    if panel then return end

    panel = CreateFrame("Frame", "QEAutoGearPanel", UIParent, "BasicFrameTemplateWithInset")
    panel:SetSize(460, 460)
    panel:SetPoint("CENTER")
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:SetScript("OnShow", function() UI:Refresh() end)
    panel.TitleText:SetText("QE AutoGear")
    tinsert(UISpecialFrames, "QEAutoGearPanel")
    panel:Hide()

    statusText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statusText:SetPoint("TOPLEFT", 16, -34)
    statusText:SetWidth(420)
    statusText:SetJustifyH("LEFT")
    statusText:SetSpacing(3)

    local run = makeButton(panel, "Optimise now", 130, function() ns.Core:StartJob() end)
    run:SetPoint("TOPLEFT", 16, -104)

    local localBtn = makeButton(panel, "Local only", 100, function() ns.Core:RunLocal(false) end)
    localBtn:SetPoint("LEFT", run, "RIGHT", 6, 0)

    local equip = makeButton(panel, "Equip set", 100, function()
        if ns.lastResult then
            ns.Equipper:Apply(ns.lastResult, QEAutoGearDB.includeBank)
        else
            ns.Print("nothing to apply yet.")
        end
    end)
    equip:SetPoint("LEFT", localBtn, "RIGHT", 6, 0)
    panel.equipBtn = equip

    local export = makeButton(panel, "Copy SimC string", 150, function()
        local text = ns.Export:Build(QEAutoGearDB.includeBank)
        if text then UI:ShowText("SimC export - paste into QE Live", text) end
    end)
    export:SetPoint("TOPLEFT", run, "BOTTOMLEFT", 0, -6)

    local weights = makeButton(panel, "Paste weights", 130, function() UI:ShowWeightsImport() end)
    weights:SetPoint("LEFT", export, "RIGHT", 6, 0)

    local c1 = makeCheck(panel, "Equip automatically",
        function() return QEAutoGearDB.autoEquip end,
        function(v) QEAutoGearDB.autoEquip = v end)
    c1:SetPoint("TOPLEFT", export, "BOTTOMLEFT", -4, -8)

    local c2 = makeCheck(panel, "Re-run on loot and spec change",
        function() return QEAutoGearDB.autoRun end,
        function(v) QEAutoGearDB.autoRun = v end)
    c2:SetPoint("TOPLEFT", c1, "BOTTOMLEFT", 0, -2)

    local c3 = makeCheck(panel, "Include bank",
        function() return QEAutoGearDB.includeBank end,
        function(v) QEAutoGearDB.includeBank = v end)
    c3:SetPoint("TOPLEFT", c2, "BOTTOMLEFT", 0, -2)

    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    header:SetPoint("TOPLEFT", c3, "BOTTOMLEFT", 4, -10)
    header:SetText("Proposed changes")

    rows = {}
    for i = 1, 12 do
        local row = CreateFrame("Button", nil, panel)
        row:SetSize(420, 18)
        row:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2 - (i - 1) * 18)

        row.slot = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.slot:SetPoint("LEFT", 0, 0)
        row.slot:SetWidth(70)
        row.slot:SetJustifyH("LEFT")

        row.item = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.item:SetPoint("LEFT", row.slot, "RIGHT", 4, 0)
        row.item:SetWidth(280)
        row.item:SetJustifyH("LEFT")

        row.gain = row:CreateFontString(nil, "OVERLAY", "GameFontGreenSmall")
        row.gain:SetPoint("RIGHT", 0, 0)
        row.gain:SetWidth(60)
        row.gain:SetJustifyH("RIGHT")

        row:SetScript("OnEnter", function(self)
            if not self.link then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self.link)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        rows[i] = row
    end
end

function UI:Refresh()
    if not panel or not panel:IsShown() then return end

    local db = QEAutoGearDB
    local lines = {}

    local spec = GetSpecialization()
    local specID, specName
    if spec then specID, specName = GetSpecializationInfo(spec) end
    local _, source = ns.Weights:Get(specID or 0)
    lines[#lines + 1] = ("Spec: |cffffffff%s|r   Weights: |cffffffff%s|r")
        :format(specName or "?", source or "?")

    if specID and not ns.QE_SPECS[specID] then
        lines[#lines + 1] = "|cffff8800QE Live models healers only - this spec uses local weights.|r"
    end

    local seen = db.agentSeen
    if seen and (time() - seen) < 900 then
        lines[#lines + 1] = ("Agent: |cff44ff44connected|r (v%s)   Inbox: %d slots left")
            :format(db.agentVersion or "?", ns.Bridge:SlotsRemaining())
    else
        lines[#lines + 1] = "Agent: |cffff4444not detected|r - start qeagent, or use Copy SimC string."
    end

    local job = ns.Core:JobInfo()
    if job then
        lines[#lines + 1] = ("|cffffff00Waiting on QE Live...|r (%ds)")
            :format(math.floor(GetTime() - job.started))
    elseif ns.lastResult then
        local r = ns.lastResult
        lines[#lines + 1] = ("Last result: |cffffffff%s|r, %d change(s)")
            :format(r.source or "?", #r.changes)
    end

    statusText:SetText(table.concat(lines, "\n"))

    local changes = ns.lastResult and ns.lastResult.changes or {}
    panel.equipBtn:SetEnabled(#changes > 0)

    for i, row in ipairs(rows) do
        local c = changes[i]
        if c then
            row.slot:SetText(ns.SLOT_NAME[c.slot] or ("Slot " .. c.slot))
            row.item:SetText(c.to)
            row.link = c.to
            if c.gain and c.gain > 0 then
                row.gain:SetText(("+%.0f"):format(c.gain))
            else
                row.gain:SetText("")
            end
            row:Show()
        else
            row:Hide()
        end
    end

    if #changes > #rows then
        rows[#rows].item:SetText(("... and %d more"):format(#changes - #rows + 1))
        rows[#rows].link = nil
        rows[#rows].gain:SetText("")
    end
end

function UI:Show() build(); panel:Show(); self:Refresh() end
function UI:Toggle()
    build()
    if panel:IsShown() then panel:Hide() else self:Show() end
end
