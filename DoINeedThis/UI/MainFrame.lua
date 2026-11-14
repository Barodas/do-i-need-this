local _, ns = ...

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local RequestLoadItem = C_Item and C_Item.RequestLoadItemDataByID

local WIDTH, HEIGHT, LINE_HEIGHT = 440, 480, 18

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
function ns:ItemName(itemID)
    local name, _, quality = GetItemInfo(itemID)
    if not name then
        if RequestLoadItem then RequestLoadItem(itemID) end
        return "item " .. itemID, false
    end
    local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    return color and (color.hex .. name .. "|r") or name, true, name
end

function ns:ItemIcon(itemID)
    local icon = select(5, GetItemInfoInstant(itemID))
    return icon or 134400   -- question mark
end

function ns:CharName(group, name)
    local char = group.characters[name]
    local color = char and RAID_CLASS_COLORS and RAID_CLASS_COLORS[char.class]
    return color and color.colorStr and ("|c" .. color.colorStr .. name .. "|r") or name
end

local function Gray(s) return "|cff808080" .. s .. "|r" end
local function Green(s) return "|cff40ff40" .. s .. "|r" end
local function Red(s) return "|cffff5050" .. s .. "|r" end
local function Gold(s) return "|cffffd100" .. s .. "|r" end

-- "3/8 (bags 1, bank 2, mail 0)"
function ns:HeldText(e)
    local parts = {}
    if e.bags > 0 then parts[#parts + 1] = "bags " .. e.bags end
    if e.bank > 0 then parts[#parts + 1] = "bank " .. e.bank end
    if e.mail > 0 then parts[#parts + 1] = "mail " .. e.mail end
    return #parts > 0 and ("(" .. table.concat(parts, ", ") .. ")") or ""
end

-- Status text for one character's entry for one item.
function ns:StatusText(e)
    if e.required == 0 then
        return Gray(("spare %d %s"):format(e.have, ns:HeldText(e)))
    end
    local text
    if e.short > 0 then
        text = Red(("%d/%d, needs %d"):format(e.have, e.required, e.short))
    else
        text = Green(("%d/%d"):format(math.min(e.have, e.required), e.required))
    end
    if e.bank > 0 and e.bags < e.required then
        text = text .. " " .. Gold(("collect %d from bank"):format(math.min(e.bank, e.required - e.bags)))
    elseif e.mail > 0 then
        text = text .. " " .. Gold(("%d in mailbox"):format(e.mail))
    end
    return text
end

-- ---------------------------------------------------------------------------
-- Frame
-- ---------------------------------------------------------------------------
local frame, scroll, content
local lines, usedLines = {}, 0

local function CreateMainFrame()
    local ok, f = pcall(CreateFrame, "Frame", "DoINeedThisMainFrame", UIParent, "BasicFrameTemplateWithInset")
    if not ok then
        f = CreateFrame("Frame", "DoINeedThisMainFrame", UIParent)
        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.85)
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT")
    end
    f:SetSize(WIDTH, HEIGHT)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    table.insert(UISpecialFrames, "DoINeedThisMainFrame")   -- close with Escape

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    if f.TitleBg then
        f.title:SetPoint("LEFT", f.TitleBg, "LEFT", 6, 0)
    else
        f.title:SetPoint("TOP", 0, -6)
    end

    local settings = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    settings:SetSize(80, 20)
    settings:SetPoint("TOPRIGHT", -10, -28)
    settings:SetText("Settings")
    settings:SetScript("OnClick", function() ns:OpenOptions() end)

    scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -52)
    scroll:SetPoint("BOTTOMRIGHT", -32, 12)

    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(WIDTH - 48, 1)
    scroll:SetScrollChild(content)

    f:SetScript("OnShow", function() ns:RefreshMainFrame() end)
    return f
end

-- A line: optional icon, left text, right text, optional tooltip lines.
local function GetLine()
    usedLines = usedLines + 1
    local line = lines[usedLines]
    if not line then
        line = CreateFrame("Frame", nil, content)
        line:SetHeight(LINE_HEIGHT)
        line.icon = line:CreateTexture(nil, "ARTWORK")
        line.icon:SetSize(LINE_HEIGHT - 2, LINE_HEIGHT - 2)
        line.left = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        line.left:SetJustifyH("LEFT")
        line.right = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        line.right:SetPoint("RIGHT", -2, 0)
        line.right:SetJustifyH("RIGHT")
        line:SetScript("OnEnter", function(self)
            if not self.tooltip then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            for i, text in ipairs(self.tooltip) do
                if i == 1 then GameTooltip:SetText(text) else GameTooltip:AddLine(text, 1, 1, 1) end
            end
            GameTooltip:Show()
        end)
        line:SetScript("OnLeave", GameTooltip_Hide)
        lines[usedLines] = line
    end
    line:ClearAllPoints()
    line:SetPoint("TOPLEFT", 0, -(usedLines - 1) * LINE_HEIGHT)
    line:SetPoint("RIGHT", content, "RIGHT")
    line.tooltip = nil
    line:EnableMouse(false)
    line:Show()
    return line
end

local function AddLine(left, right, opts)
    opts = opts or {}
    local line = GetLine()
    local indent = opts.indent or 0
    if opts.icon then
        line.icon:SetTexture(opts.icon)
        line.icon:SetPoint("LEFT", indent, 0)
        line.icon:Show()
        line.left:SetPoint("LEFT", indent + LINE_HEIGHT + 2, 0)
    else
        line.icon:Hide()
        line.left:SetPoint("LEFT", indent, 0)
    end
    line.left:SetFontObject(opts.header and "GameFontNormal" or "GameFontHighlightSmall")
    line.left:SetText(left or "")
    line.right:SetText(right or "")
    if opts.tooltip then
        line.tooltip = opts.tooltip
        line:EnableMouse(true)
    end
    return line
end

local function QuestTooltip(name, e)
    local tip = { name }
    for _, questID in ipairs(e.quests) do
        local quest = ns.Quests[questID]
        tip[#tip + 1] = ("%s (%d)"):format(quest and quest.name or "?", questID)
    end
    if #tip == 1 then tip[2] = "No unfinished quests need this." end
    return tip
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------
function ns:RefreshMainFrame()
    if not frame or not frame:IsShown() or not ns.group then return end
    local group, faction = ns.group, ns.faction
    frame.title:SetText(("Do I Need This?  -  %s (%s)"):format(ns.realm, faction))

    for i = 1, usedLines do lines[i]:Hide() end
    usedLines = 0

    -- What this character would mail right now, then what to take from the bank.
    ns:RenderMailing(group, faction)
    AddLine("")

    local summary = ns:Summarize(group, faction)

    -- Sort items by name (uncached names sort last by ID).
    local items = {}
    for itemID in pairs(summary) do items[#items + 1] = itemID end
    local names = {}
    for _, itemID in ipairs(items) do
        local _, _, plain = ns:ItemName(itemID)
        names[itemID] = plain or ("~" .. itemID)
    end
    table.sort(items, function(a, b) return names[a] < names[b] end)

    if #items == 0 then
        AddLine(Gray("Nothing tracked yet for this realm and faction."))
    end

    for _, itemID in ipairs(items) do
        local s = summary[itemID]
        local right = {}
        if s.short > 0 then right[#right + 1] = Red("short " .. s.short) end
        if s.spare > 0 then right[#right + 1] = Gray("spare " .. s.spare) end
        local header = AddLine((ns:ItemName(itemID)), table.concat(right, "  "), { icon = ns:ItemIcon(itemID), header = true })
        header:SetHeight(LINE_HEIGHT)

        for _, name in ipairs(group.priority) do
            local e = s.chars[name]
            if e then
                AddLine(ns:CharName(group, name), ns:StatusText(e),
                    { indent = 24, tooltip = QuestTooltip(name, e) })
            end
        end
        AddLine("")
    end

    content:SetHeight(math.max(1, usedLines * LINE_HEIGHT))
end

local function RecipientText(group, name)
    local text = ns:CharName(group, name)
    if name == group.fallback then text = text .. Gray(" (fallback)") end
    return text
end

function ns:RenderMailing(group, faction)
    local me = ns.playerName

    -- Recipients in priority order, then the fallback if it isn't in the list.
    local order = {}
    for _, name in ipairs(group.priority) do order[#order + 1] = name end
    if group.fallback and not tContains(order, group.fallback) then order[#order + 1] = group.fallback end

    AddLine(("Mailing from %s"):format(ns:CharName(group, me)), nil, { header = true })
    local plan = ns:PlanDistribution(group, faction, me)
    local any = false
    for _, name in ipairs(order) do
        for itemID, count in pairs(plan[name] or {}) do
            any = true
            AddLine(("%s  x%d"):format(ns:ItemName(itemID), count), "to " .. RecipientText(group, name),
                { indent = 24, icon = ns:ItemIcon(itemID) })
        end
    end
    if not any then AddLine(Gray("Nothing to send from this character's bags."), nil, { indent = 24 }) end

    local withdrawals = ns:PlanBankWithdrawals(group, faction, me)
    if next(withdrawals) then
        AddLine("")
        AddLine("Take from bank to send", Gray("as of last bank visit"), { header = true })
        for itemID, w in pairs(withdrawals) do
            local to = {}
            for _, name in ipairs(order) do
                if w.to[name] then to[#to + 1] = ("%s %d"):format(RecipientText(group, name), w.to[name]) end
            end
            AddLine(("%s  x%d"):format(ns:ItemName(itemID), w.total), "for " .. table.concat(to, ", "),
                { indent = 24, icon = ns:ItemIcon(itemID) })
        end
    end
end

function ns:ToggleMainFrame()
    frame = frame or CreateMainFrame()
    frame:SetShown(not frame:IsShown())
end

ns:OnChanged(function() ns:RefreshMainFrame() end)

-- Item names load asynchronously; redraw once they arrive.
local nameRefreshPending = false
ns:On("GET_ITEM_INFO_RECEIVED", function(_, itemID)
    if not frame or not frame:IsShown() or nameRefreshPending then return end
    if itemID and not ns.trackedItems[itemID] then return end
    nameRefreshPending = true
    C_Timer.After(0.5, function()
        nameRefreshPending = false
        ns:RefreshMainFrame()
    end)
end)
