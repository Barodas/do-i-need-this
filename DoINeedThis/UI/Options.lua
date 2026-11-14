local _, ns = ...

--[[
Settings panel (Game Menu > Options > AddOns > Do I Need This?, or /dint config).

Per realm/faction group:
  - priority order (up/down), highest receives items first
  - fallback character: receives items nobody needs
  - exclude: ignored for needs and mailing
  - delete: forget a character that no longer exists
]]

local ROW_HEIGHT = 26
local CONTENT_WIDTH = 580

local panel = CreateFrame("Frame")
panel.name = "Do I Need This?"
local category
local rows = {}
local selected   -- { realm, faction }

local function Gray(s) return "|cff808080" .. s .. "|r" end

-- ---------------------------------------------------------------------------
-- Groups
-- ---------------------------------------------------------------------------
local function AllGroups()
    local list = {}
    for realm, factions in pairs(ns.db.realms) do
        for faction, group in pairs(factions) do
            list[#list + 1] = { realm = realm, faction = faction, group = group }
        end
    end
    table.sort(list, function(a, b)
        if a.realm ~= b.realm then return a.realm < b.realm end
        return a.faction < b.faction
    end)
    return list
end

local function SelectedGroup()
    if not selected then selected = { realm = ns.realm, faction = ns.faction } end
    local factions = ns.db.realms[selected.realm]
    return factions and factions[selected.faction]
end

-- Keep the priority list in sync with the known characters.
local function Normalize(group)
    local seen = {}
    for i = #group.priority, 1, -1 do
        local name = group.priority[i]
        if not group.characters[name] or seen[name] then
            table.remove(group.priority, i)
        else
            seen[name] = true
        end
    end
    local missing = {}
    for name in pairs(group.characters) do
        if not seen[name] then missing[#missing + 1] = name end
    end
    table.sort(missing)
    for _, name in ipairs(missing) do table.insert(group.priority, name) end
    if group.fallback and not group.characters[group.fallback] then group.fallback = nil end
end

local function Changed()
    ns:RefreshOptions()
    ns:Changed()
end

-- ---------------------------------------------------------------------------
-- Delete confirmation
-- ---------------------------------------------------------------------------
StaticPopupDialogs["DOINEEDTHIS_DELETE_CHAR"] = {
    text = "Forget %s? Their saved quest and item data will be removed. It comes back if you log in on them again.",
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, data)
        local group, name = data.group, data.name
        group.characters[name] = nil
        if group.excluded then group.excluded[name] = nil end
        if group.fallback == name then group.fallback = nil end
        Normalize(group)
        Changed()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------
local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("Do I Need This?")

local help = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
help:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
help:SetWidth(CONTENT_WIDTH)
help:SetJustifyH("LEFT")
help:SetText("Characters higher in the list receive items first. The fallback character "
    .. "receives items nobody needs, to store or sell. Excluded characters are ignored "
    .. "for needs and mailing. Mail can only go to characters on the same realm and faction.")

-- Group selector: < Realm (Faction) >
local prevButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
prevButton:SetSize(24, 22)
prevButton:SetText("<")
prevButton:SetPoint("TOPLEFT", help, "BOTTOMLEFT", 0, -14)

local groupLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
groupLabel:SetPoint("LEFT", prevButton, "RIGHT", 8, 0)
groupLabel:SetWidth(320)

local nextButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
nextButton:SetSize(24, 22)
nextButton:SetText(">")
nextButton:SetPoint("LEFT", groupLabel, "RIGHT", 8, 0)

local function StepGroup(delta)
    local list = AllGroups()
    if #list == 0 then return end
    local index = 1
    for i, g in ipairs(list) do
        if selected and g.realm == selected.realm and g.faction == selected.faction then index = i end
    end
    index = ((index - 1 + delta) % #list) + 1
    selected = { realm = list[index].realm, faction = list[index].faction }
    ns:RefreshOptions()
end
prevButton:SetScript("OnClick", function() StepGroup(-1) end)
nextButton:SetScript("OnClick", function() StepGroup(1) end)

-- Column headers
local COL = { rank = 4, name = 30, up = 250, down = 276, fallback = 320, exclude = 390, delete = 450 }

local headerY = -14
local function Header(text, x, anchor)
    local fs = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", x, headerY)
    fs:SetText(text)
    return fs
end
local headerAnchor = CreateFrame("Frame", nil, panel)
headerAnchor:SetSize(1, 1)
headerAnchor:SetPoint("TOPLEFT", prevButton, "BOTTOMLEFT", 0, 0)
Header("#", COL.rank, headerAnchor)
Header("Character", COL.name, headerAnchor)
Header("Order", COL.up, headerAnchor)
Header("Fallback", COL.fallback - 6, headerAnchor)
Header("Exclude", COL.exclude - 6, headerAnchor)

local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", headerAnchor, "BOTTOMLEFT", 0, headerY - 18)
scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -32, 16)

local content = CreateFrame("Frame", nil, scroll)
content:SetSize(CONTENT_WIDTH, 1)
scroll:SetScrollChild(content)

local function ArrowButton(parent, x, dir)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(22, 22)
    b:SetPoint("LEFT", x, 0)
    local base = "Interface\\Buttons\\UI-ScrollBar-Scroll" .. dir .. "Button-"
    b:SetNormalTexture(base .. "Up")
    b:SetPushedTexture(base .. "Down")
    b:SetDisabledTexture(base .. "Disabled")
    b:SetHighlightTexture(base .. "Highlight", "ADD")
    return b
end

local function CreateRow(index)
    local row = CreateFrame("Frame", nil, content)
    row:SetSize(CONTENT_WIDTH, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)

    row.rank = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.rank:SetPoint("LEFT", COL.rank, 0)

    row.name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.name:SetPoint("LEFT", COL.name, 0)
    row.name:SetWidth(COL.up - COL.name - 8)
    row.name:SetJustifyH("LEFT")

    row.up = ArrowButton(row, COL.up, "Up")
    row.down = ArrowButton(row, COL.down, "Down")

    row.fallback = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.fallback:SetSize(24, 24)
    row.fallback:SetPoint("LEFT", COL.fallback, 0)

    row.exclude = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.exclude:SetSize(24, 24)
    row.exclude:SetPoint("LEFT", COL.exclude, 0)

    row.delete = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.delete:SetSize(70, 20)
    row.delete:SetPoint("LEFT", COL.delete, 0)
    row.delete:SetText(DELETE or "Delete")

    rows[index] = row
    return row
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------
function ns:RefreshOptions()
    if not panel:IsVisible() or not ns.db then return end
    local group = SelectedGroup()
    for _, row in ipairs(rows) do row:Hide() end

    if not group then
        groupLabel:SetText(Gray("No characters recorded"))
        return
    end
    Normalize(group)
    group.excluded = group.excluded or {}

    local isCurrent = selected.realm == ns.realm and selected.faction == ns.faction
    groupLabel:SetText(("%s (%s)%s"):format(selected.realm, selected.faction, isCurrent and Gray("  - current") or ""))

    local count = #group.priority
    for i, name in ipairs(group.priority) do
        local row = rows[i] or CreateRow(i)
        local char = group.characters[name]
        row:Show()
        row.rank:SetText(i)

        local label = ns:CharName(group, name) .. Gray((" %d"):format(char.level or 0))
        if name == ns.playerName and isCurrent then label = label .. Gray("  (you)") end
        if group.excluded[name] then label = Gray(name .. "  (excluded)") end
        row.name:SetText(label)

        row.up:SetEnabled(i > 1)
        row.down:SetEnabled(i < count)
        row.up:SetScript("OnClick", function()
            group.priority[i], group.priority[i - 1] = group.priority[i - 1], group.priority[i]
            Changed()
        end)
        row.down:SetScript("OnClick", function()
            group.priority[i], group.priority[i + 1] = group.priority[i + 1], group.priority[i]
            Changed()
        end)

        row.fallback:SetChecked(group.fallback == name)
        row.fallback:SetScript("OnClick", function(self)
            group.fallback = self:GetChecked() and name or nil
            Changed()
        end)

        row.exclude:SetChecked(group.excluded[name] and true or false)
        row.exclude:SetScript("OnClick", function(self)
            group.excluded[name] = self:GetChecked() and true or nil
            Changed()
        end)

        -- Can't forget the character you're logged in on.
        row.delete:SetEnabled(not (isCurrent and name == ns.playerName))
        row.delete:SetScript("OnClick", function()
            StaticPopup_Show("DOINEEDTHIS_DELETE_CHAR", name, nil, { group = group, name = name })
        end)
    end
    content:SetHeight(math.max(1, count * ROW_HEIGHT))
end

panel:SetScript("OnShow", function()
    if not selected then selected = { realm = ns.realm, faction = ns.faction } end
    ns:RefreshOptions()
end)

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------
if Settings and Settings.RegisterCanvasLayoutCategory then
    category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    Settings.RegisterAddOnCategory(category)
elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(panel)
end

function ns:OpenOptions()
    if DoINeedThisMainFrame then DoINeedThisMainFrame:Hide() end
    selected = { realm = ns.realm, faction = ns.faction }
    if category and Settings.OpenToCategory then
        Settings.OpenToCategory(category:GetID())
    elseif InterfaceOptionsFrame_OpenToCategory then
        -- Called twice: the first call can land on the wrong page.
        InterfaceOptionsFrame_OpenToCategory(panel)
        InterfaceOptionsFrame_OpenToCategory(panel)
    else
        ns:Print("Couldn't open the settings panel on this client.")
    end
end
