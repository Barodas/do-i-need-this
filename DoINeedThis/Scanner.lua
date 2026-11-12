local _, ns = ...

-- API shims: modern clients moved some globals into C_* namespaces.
local GetItemCount = (C_Item and C_Item.GetItemCount) or GetItemCount
local IsQuestFlaggedCompleted = (C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted) or IsQuestFlaggedCompleted

-- Set of itemIDs referenced by any quest: { [itemID] = true }
ns.trackedItems = {}

function ns:BuildTrackedItems()
    wipe(ns.trackedItems)
    for _, quest in pairs(ns.Quests) do
        for itemID in pairs(quest.items) do
            ns.trackedItems[itemID] = true
        end
    end
end

local function ItemRecord(itemID)
    local items = ns.char.items
    items[itemID] = items[itemID] or { bags = 0, bank = 0, mail = 0 }
    return items[itemID]
end

-- ---------------------------------------------------------------------------
-- Quests
-- ---------------------------------------------------------------------------
-- Is the quest currently in the quest log? Uses whichever API the client has.
local function IsOnQuest(questID)
    if C_QuestLog and C_QuestLog.IsOnQuest then
        return C_QuestLog.IsOnQuest(questID)
    end
    if C_QuestLog and C_QuestLog.GetLogIndexForQuestID then
        return C_QuestLog.GetLogIndexForQuestID(questID) ~= nil
    end
    if GetQuestLogIndexByID then
        local index = GetQuestLogIndexByID(questID)
        return index ~= nil and index > 0
    end
    return false
end

local function ActiveQuestIDs()
    local active = {}
    for questID in pairs(ns.Quests) do
        if IsOnQuest(questID) then active[questID] = true end
    end
    return active
end

function ns:ScanQuests()
    local active = ActiveQuestIDs()
    local quests = ns.char.quests
    for questID, quest in pairs(ns.Quests) do
        if quest.repeatable then
            quests[questID] = active[questID] and "active" or nil
        elseif quests[questID] == "done" or IsQuestFlaggedCompleted(questID) then
            -- Never clear "done": completion data can be missing right after
            -- login, before the server has sent it.
            quests[questID] = "done"
        else
            quests[questID] = active[questID] and "active" or nil
        end
    end
end

-- ---------------------------------------------------------------------------
-- Bags / bank
-- ---------------------------------------------------------------------------
function ns:ScanBags()
    for itemID in pairs(ns.trackedItems) do
        ItemRecord(itemID).bags = GetItemCount(itemID) or 0
    end
end

-- Bank contents are only reliable while the bank is open, so we snapshot then.
function ns:ScanBank()
    for itemID in pairs(ns.trackedItems) do
        local bags = GetItemCount(itemID) or 0
        local total = GetItemCount(itemID, true) or 0
        ItemRecord(itemID).bank = math.max(0, total - bags)
    end
end

function ns:ScanAll()
    ns:ScanQuests()
    ns:ScanBags()
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local bankOpen = false

ns:On("BAG_UPDATE_DELAYED", function()
    if not ns.char then return end
    ns:ScanBags()
    if bankOpen then ns:ScanBank() end
end)

ns:On("BANKFRAME_OPENED", function()
    bankOpen = true
    ns:ScanBank()
end)

ns:On("BANKFRAME_CLOSED", function()
    bankOpen = false
end)

ns:On("PLAYERBANKSLOTS_CHANGED", function()
    if bankOpen then ns:ScanBank() end
end)

ns:On("QUEST_TURNED_IN", function(_, questID)
    local quest = ns.Quests[questID]
    if ns.char and quest and not quest.repeatable then
        ns.char.quests[questID] = "done"
    end
end)

-- QUEST_LOG_UPDATE fires often (and once the server has sent quest data after
-- login), so rescan at most once per second.
local questScanPending = false
ns:On("QUEST_LOG_UPDATE", function()
    if not ns.char or questScanPending then return end
    questScanPending = true
    C_Timer.After(1, function()
        questScanPending = false
        ns:ScanQuests()
    end)
end)
