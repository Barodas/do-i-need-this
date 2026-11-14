local _, ns = ...

--[[
Mailing items to the characters that need them.

  - "Do I Need This?" button beside the mailbox opens a preview of the plan
    (ns:PlanDistribution for the current character's bags).
  - "Send all" attaches and sends one mail at a time, up to 12 attachments
    each, waiting for the server to confirm each mail before the next.
  - Every sent item is added to the recipient's "mail" count straight away
    (alt mail is instant), and logged in DoINeedThisDB.mailLog.
  - When any character opens their mailbox, the mail count is replaced by
    what's actually in the inbox.
]]

local MAX_ATTACHMENTS = ATTACHMENTS_MAX_SEND or 12
local MAX_RECEIVE = ATTACHMENTS_MAX_RECEIVE or 16
local LOG_LIMIT = 100
local SUBJECT = "Do I Need This?"

local NUM_BAGS = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4

local mailOpen = false
local sending = false
local cancelRequested = false
local preview, button

local function Gray(s) return "|cff808080" .. s .. "|r" end

-- ---------------------------------------------------------------------------
-- Inbox scan: what's sitting in this character's mailbox
-- ---------------------------------------------------------------------------
function ns:ScanInbox()
    if not ns.char then return end
    local totals = {}
    for i = 1, GetInboxNumItems() do
        for a = 1, MAX_RECEIVE do
            local _, itemID, _, count = GetInboxItem(i, a)
            if itemID and ns.trackedItems[itemID] then
                totals[itemID] = (totals[itemID] or 0) + (count or 1)
            end
        end
    end
    for itemID in pairs(ns.trackedItems) do
        local rec = ns.char.items[itemID]
        if rec or totals[itemID] then
            rec = rec or { bags = 0, bank = 0, mail = 0 }
            rec.mail = totals[itemID] or 0
            ns.char.items[itemID] = rec
        end
    end
    ns:Changed()
end

-- ---------------------------------------------------------------------------
-- Coroutine helpers: the send process waits for timers and mail events.
-- ---------------------------------------------------------------------------
local co, waitId, waitingForMail = nil, 0, false
local lastError

local function Resume(id, result)
    if id ~= waitId or not co or coroutine.status(co) ~= "suspended" then return end
    waitId = waitId + 1          -- ignore any other pending callbacks for this wait
    waitingForMail = false
    local ok, err = coroutine.resume(co, result)
    if not ok then
        sending = false
        ns:Print("Mailing stopped by an error: " .. tostring(err))
        ns:RefreshMailPreview()
    end
end

local function Wait(seconds)
    local id = waitId
    C_Timer.After(seconds, function() Resume(id, "TIMEOUT") end)
    return coroutine.yield()
end

local function WaitForMail(timeout)
    waitingForMail = true
    return Wait(timeout)
end

-- ---------------------------------------------------------------------------
-- Bag helpers
-- ---------------------------------------------------------------------------
local function FindStacks(itemID)
    local stacks, locked = {}, 0
    for bag = 0, NUM_BAGS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID == itemID then
                if info.isLocked then
                    locked = locked + 1
                else
                    stacks[#stacks + 1] = { bag = bag, slot = slot, count = info.stackCount }
                end
            end
        end
    end
    table.sort(stacks, function(a, b) return a.count < b.count end)
    return stacks, locked
end

local function SendFrameEmpty()
    for i = 1, MAX_ATTACHMENTS do
        if GetSendMailItem(i) then return false end
    end
    return true
end

-- An empty slot in a normal bag (family 0), so profession/soul bags are skipped.
local function FindEmptySlot()
    for bag = 0, NUM_BAGS do
        local free, family = C_Container.GetContainerNumFreeSlots(bag)
        if free and free > 0 and family == 0 then
            for slot = 1, C_Container.GetContainerNumSlots(bag) do
                if not C_Container.GetContainerItemInfo(bag, slot) then
                    return bag, slot
                end
            end
        end
    end
end

-- Mail attaches whole bag stacks, so a partial amount is split off into an
-- empty bag slot first. Returns the new stack, or nil plus a reason.
local function SplitToEmptySlot(stack, count)
    local bag, slot = FindEmptySlot()
    if not bag then return nil, "no free bag slot to split a stack into" end
    ClearCursor()
    C_Container.SplitContainerItem(stack.bag, stack.slot, count)
    if not CursorHasItem() then Wait(0.2) end
    C_Container.PickupContainerItem(bag, slot)   -- drop the split part
    for _ = 1, 20 do                              -- wait up to ~2s for the server
        Wait(0.1)
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info and info.stackCount == count and not info.isLocked then
            local source = C_Container.GetContainerItemInfo(stack.bag, stack.slot)
            if not source or not source.isLocked then
                return { bag = bag, slot = slot, count = count }
            end
        end
    end
    ClearCursor()
    return nil, "splitting a stack timed out"
end

-- Put `count` of the stack at bag/slot into attachment slot `index`.
local function Attach(stack, count, index)
    if count < stack.count then
        local split, reason = SplitToEmptySlot(stack, count)
        if not split then return false, reason end
        stack = split
    end
    ClearCursor()
    C_Container.PickupContainerItem(stack.bag, stack.slot)
    if not CursorHasItem() then Wait(0.2) end
    ClickSendMailItemButton(index)
    Wait(0.3)
    if not GetSendMailItem(index) then
        ClearCursor()
        return false, "the item didn't attach"
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Ledger
-- ---------------------------------------------------------------------------
local function Record(recipient, attached)
    local char = ns.group.characters[recipient]
    local parts = {}
    for itemID, count in pairs(attached) do
        if char then
            local rec = char.items[itemID] or { bags = 0, bank = 0, mail = 0 }
            rec.mail = (rec.mail or 0) + count
            char.items[itemID] = rec
        end
        parts[#parts + 1] = ("%d:%d"):format(itemID, count)
    end

    ns.db.mailLog = ns.db.mailLog or {}
    table.insert(ns.db.mailLog, 1, {
        time = time(), from = ns.playerName, to = recipient,
        realm = ns.realm, faction = ns.faction, items = table.concat(parts, ","),
    })
    while #ns.db.mailLog > LOG_LIMIT do table.remove(ns.db.mailLog) end
    ns:Changed()
end

-- ---------------------------------------------------------------------------
-- Send process
-- ---------------------------------------------------------------------------
local status = ""
local function SetStatus(text)
    status = text
    ns:RefreshMailPreview()
end

-- "Do I Need This?: Bear Meat x3, Okra x2", or the item total if that's too
-- long for a subject line.
local SUBJECT_MAX = 64
local function Subject(attached)
    local parts, total = {}, 0
    for itemID, count in pairs(attached) do
        local _, _, plain = ns:ItemName(itemID)
        parts[#parts + 1] = ("%s x%d"):format(plain or ("item " .. itemID), count)
        total = total + count
    end
    table.sort(parts)
    local subject = ("%s: %s"):format(SUBJECT, table.concat(parts, ", "))
    if #subject > SUBJECT_MAX then
        subject = ("%s: %d items"):format(SUBJECT, total)
    end
    return subject
end

-- Sends one mail to `recipient` from `remaining` ({ [itemID] = count }).
-- Returns the attached items, or nil plus a reason.
local function SendOneMail(recipient, remaining)
    local attached, index = {}, 0
    for itemID, need in pairs(remaining) do
        while need > 0 and index < MAX_ATTACHMENTS do
            local stacks, locked = FindStacks(itemID)
            if #stacks == 0 then
                if locked > 0 then break end    -- try again in the next mail
                need = 0                         -- items are gone; skip them
                break
            end
            -- Prefer a whole stack that fits, otherwise split the smallest.
            local stack = stacks[1]
            for _, s in ipairs(stacks) do
                if s.count <= need then stack = s end
            end
            local take = math.min(stack.count, need)
            index = index + 1
            local ok, why = Attach(stack, take, index)
            if not ok then
                return nil, ("couldn't attach %s: %s"):format((ns:ItemName(itemID)), why or "unknown")
            end
            need = need - take
            attached[itemID] = (attached[itemID] or 0) + take
        end
        remaining[itemID] = need
    end
    if index == 0 then return attached end

    local name, subject = ns:MailName(recipient), Subject(attached)

    -- Fill the Send Mail form too, so it's visible who the mail is going to.
    -- No body text: a mail with text stays in the inbox after the items are
    -- taken and has to be deleted by hand.
    if SendMailNameEditBox then SendMailNameEditBox:SetText(name) end
    if SendMailSubjectEditBox then SendMailSubjectEditBox:SetText(subject) end
    if SendMailBodyEditBox then SendMailBodyEditBox:SetText("") end

    lastError = nil
    SendMail(name, subject, "")
    -- Client-side errors (e.g. a bad name) can arrive during the call itself.
    local result = lastError and "ERROR" or WaitForMail(20)

    if result ~= "MAIL_SEND_SUCCESS" then
        if not SendFrameEmpty() then ClearSendMail() end
        local reason = lastError
            or (result == "TIMEOUT" and "no reply from the server")
            or "the server rejected the mail"
        return nil, ("%s (to \"%s\")"):format(reason, name)
    end
    Record(recipient, attached)
    return attached
end

local function Remaining(items)
    for _, count in pairs(items) do
        if count > 0 then return true end
    end
    return false
end

local function SendAll()
    local plan = ns:PlanDistribution(ns.group, ns.faction, ns.playerName)
    local sent, mails = 0, 0

    for recipient, items in pairs(plan) do
        local remaining = {}
        for itemID, count in pairs(items) do remaining[itemID] = count end

        while Remaining(remaining) do
            if cancelRequested or not mailOpen then
                SetStatus("Stopped.")
                return
            end
            SetStatus(("Sending to %s..."):format(recipient))
            local attached, reason = SendOneMail(recipient, remaining)
            if not attached then
                SetStatus(("Stopped: %s."):format(reason))
                ns:Print(("Mailing to %s stopped: %s."):format(recipient, reason))
                return
            end
            if not next(attached) then break end    -- nothing attachable; move on
            mails = mails + 1
            for _, count in pairs(attached) do sent = sent + count end
            Wait(0.5)                                 -- let bag locks clear
        end
    end

    SetStatus(("Done: %d items in %d mails."):format(sent, mails))
    if mails > 0 then ns:Print(("Sent %d items in %d mails."):format(sent, mails)) end
end

function ns:StartSending()
    if sending then return end
    if not mailOpen then return end
    if not SendFrameEmpty() then
        SetStatus("Clear the items already attached in Send Mail first.")
        return
    end
    if MailFrameTab_OnClick then MailFrameTab_OnClick(nil, 2) end   -- Send Mail tab
    ns:ScanBags()
    sending, cancelRequested = true, false
    co = coroutine.create(function()
        SendAll()
        sending = false
        ns:RefreshMailPreview()
    end)
    waitId = waitId + 1
    local ok, err = coroutine.resume(co)
    if not ok then
        sending = false
        ns:Print("Mailing stopped by an error: " .. tostring(err))
    end
    ns:RefreshMailPreview()
end

-- ---------------------------------------------------------------------------
-- UI: button beside the mailbox and a preview panel
-- ---------------------------------------------------------------------------
local function CreatePreview()
    local ok, f = pcall(CreateFrame, "Frame", "DoINeedThisMailPreview", MailFrame, "BasicFrameTemplateWithInset")
    if not ok then
        f = CreateFrame("Frame", "DoINeedThisMailPreview", MailFrame)
        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.85)
    end
    f:SetSize(300, 340)
    f:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", 4, 0)
    f:Hide()

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    if f.TitleBg then f.title:SetPoint("LEFT", f.TitleBg, "LEFT", 6, 0) else f.title:SetPoint("TOP", 0, -6) end
    f.title:SetText("Do I Need This?")

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -30)
    scroll:SetPoint("BOTTOMRIGHT", -32, 64)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(250, 1)
    scroll:SetScrollChild(content)

    f.text = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.text:SetPoint("TOPLEFT")
    f.text:SetWidth(250)
    f.text:SetJustifyH("LEFT")
    f.text:SetSpacing(3)
    f.content = content

    f.status = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.status:SetPoint("BOTTOMLEFT", 14, 40)
    f.status:SetPoint("BOTTOMRIGHT", -14, 40)
    f.status:SetJustifyH("LEFT")

    f.send = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.send:SetSize(120, 22)
    f.send:SetPoint("BOTTOMLEFT", 12, 12)
    f.send:SetScript("OnClick", function()
        if not sending then ns:StartSending() end
    end)

    -- "Overview" normally; "Stop" while sending.
    f.second = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.second:SetSize(120, 22)
    f.second:SetPoint("BOTTOMRIGHT", -12, 12)
    f.second:SetScript("OnClick", function()
        if not sending then
            ns:ToggleMainFrame()
        else
            cancelRequested = true
        end
    end)

    f:SetScript("OnShow", function() status = ""; ns:RefreshMailPreview() end)
    return f
end

function ns:RefreshMailPreview()
    if not preview or not preview:IsShown() or not ns.group then return end
    local group = ns.group
    local plan = sending and {} or ns:PlanDistribution(group, ns.faction, ns.playerName)

    local lines, total = {}, 0
    for _, name in ipairs(group.priority) do
        local items = plan[name]
        if items then
            local label = ns:CharName(group, name)
            if name == group.fallback then label = label .. Gray(" (fallback)") end
            if ns:MailName(name) == name then
                label = label .. " |cffffd100(log in once to record full name)|r"
            else
                label = label .. Gray(" -> " .. ns:MailName(name))
            end
            lines[#lines + 1] = label
            for itemID, count in pairs(items) do
                lines[#lines + 1] = ("    %s x%d"):format(ns:ItemName(itemID), count)
                total = total + count
            end
        end
    end
    if sending then
        lines = { Gray("Sending...") }
    elseif #lines == 0 then
        lines = { Gray("Nothing in your bags is needed by your other characters.") }
    end

    preview.text:SetText(table.concat(lines, "\n"))
    preview.content:SetHeight(math.max(1, preview.text:GetStringHeight()))
    preview.status:SetText(status)
    if sending then
        preview.send:SetText("Sending...")
        preview.send:SetEnabled(false)
    else
        preview.send:SetText(("Send all (%d)"):format(total))
        preview.send:SetEnabled(total > 0)
    end
    preview.second:SetText(sending and "Stop" or "Overview")
end

local function CreateButton()
    button = CreateFrame("Button", "DoINeedThisMailButton", MailFrame, "UIPanelButtonTemplate")
    button:SetSize(130, 22)
    button:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", 4, 24)
    button:SetText("Do I Need This?")
    button:SetScript("OnClick", function()
        preview = preview or CreatePreview()
        preview:SetShown(not preview:IsShown())
    end)
end

ns:OnChanged(function()
    if not sending then ns:RefreshMailPreview() end
end)

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
ns:On("MAIL_SHOW", function()
    mailOpen = true
    if not button then CreateButton() end
    status = ""
    -- Open the preview automatically only when there's something to send.
    if ns.group and next(ns:PlanDistribution(ns.group, ns.faction, ns.playerName)) then
        preview = preview or CreatePreview()
        preview:Show()
    end
end)

ns:On("MAIL_CLOSED", function()
    mailOpen = false
    if sending then cancelRequested = true end
    if preview then preview:Hide() end
end)

ns:On("MAIL_INBOX_UPDATE", function()
    ns:ScanInbox()
end)

ns:On("MAIL_SEND_SUCCESS", function()
    if waitingForMail then Resume(waitId, "MAIL_SEND_SUCCESS") end
end)

ns:On("MAIL_FAILED", function()
    if waitingForMail then Resume(waitId, "MAIL_FAILED") end
end)

-- Error text shown by the game (e.g. a bad recipient name) while sending.
ns:On("UI_ERROR_MESSAGE", function(_, _, message)
    if not sending or not message then return end
    lastError = message
    if waitingForMail then Resume(waitId, "ERROR") end
end)
