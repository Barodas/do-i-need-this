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
local function ActiveQuestIDs()
    local active = {}
    for i = 1, GetNumQuestLogEntries() do
        local _, _, _, isHeader, _, _, _, questID = GetQuestLogTitle(i)
        if not isHeader and questID then
            active[questID] = true
        end
    end
    return active
end

function ns:ScanQuests()
    local active = ActiveQuestIDs()
    for questID, quest in pairs(ns.Quests) do
        local state
        if not quest.repeatable and IsQuestFlaggedCompleted(questID) then
            state = "done"
        elseif active[questID] then
            state = "active"
        end
        ns.char.quests[questID] = state
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

ns:On("QUEST_ACCEPTED", function()
    if ns.char then ns:ScanQuests() end
end)
