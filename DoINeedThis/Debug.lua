local _, ns = ...

-- ---------------------------------------------------------------------------
-- API availability check (/dint api)
-- ---------------------------------------------------------------------------
local function Has(path)
    local t = _G
    for part in path:gmatch("[^.]+") do
        if type(t) ~= "table" then return false end
        t = t[part]
    end
    return type(t) == "function"
end

local API_CHECKS = {
    "C_QuestLog.GetAllCompletedQuestIDs",
    "GetQuestsCompleted",
    "C_QuestLog.IsQuestFlaggedCompleted",
    "IsQuestFlaggedCompleted",
    "C_QuestLog.GetQuestInfo",
    "C_QuestLog.GetTitleForQuestID",
    "C_QuestLog.RequestLoadQuestByID",
    "C_Item.GetItemCount",
    "C_Container.GetContainerItemInfo",
    "GetQuestItemLink",
    "GetQuestLogLeaderBoard",
    "C_QuestLog.IsOnQuest",
    "C_QuestLog.GetLogIndexForQuestID",
    "GetQuestLogIndexByID",
    "GetNumQuestLogEntries",
    "GetQuestLogTitle",
    "C_QuestLog.GetNumQuestLogEntries",
    "C_QuestLog.GetInfo",
    "GetQuestID",
    "GetNumQuestItems",
    "GetQuestItemInfo",
    "GetTitleText",
    "C_Timer.After",
}

function ns:CheckAPI()
    ns:Print("API check:")
    for _, path in ipairs(API_CHECKS) do
        print(("  %s %s"):format(Has(path) and "|cff00ff00yes|r" or "|cffff4040no |r", path))
    end
end

-- ---------------------------------------------------------------------------
-- Completed quests (/dint completed [filter])
-- ---------------------------------------------------------------------------
local function GetCompletedIDs()
    if Has("C_QuestLog.GetAllCompletedQuestIDs") then
        return C_QuestLog.GetAllCompletedQuestIDs(), "C_QuestLog.GetAllCompletedQuestIDs"
    end
    if Has("GetQuestsCompleted") then
        local ids = {}
        for id in pairs(GetQuestsCompleted()) do ids[#ids + 1] = id end
        return ids, "GetQuestsCompleted"
    end
    return nil
end

local function GetQuestTitle(id)
    if Has("C_QuestLog.GetTitleForQuestID") then
        local title = C_QuestLog.GetTitleForQuestID(id)
        if title and title ~= "" then return title end
    end
    if Has("C_QuestLog.GetQuestInfo") then
        local title = C_QuestLog.GetQuestInfo(id)
        if title and title ~= "" then return title end
    end
    return nil
end

-- Snapshot is saved to DoINeedThisDB.debug.completed["Name-Realm"] so it can be
-- read straight out of the SavedVariables file after a /reload.
local function Snapshot(ids, source, filter)
    table.sort(ids)
    local list, missing, matches = {}, 0, {}
    for _, id in ipairs(ids) do
        local title = GetQuestTitle(id)
        if not title then missing = missing + 1 end
        list[#list + 1] = { id = id, name = title }
        if filter and title and title:lower():find(filter, 1, true) then
            matches[#matches + 1] = ("  %d  %s"):format(id, title)
        end
    end

    ns.db.debug = ns.db.debug or {}
    ns.db.debug.completed = ns.db.debug.completed or {}
    ns.db.debug.completed[ns.playerName .. "-" .. ns.realm] = {
        faction = ns.faction,
        source = source,
        time = time(),
        quests = list,
    }

    ns:Print(("%d completed quests via %s (%d without a cached name)."):format(#ids, source, missing))
    if filter then
        ns:Print(("%d match \"%s\":"):format(#matches, filter))
        for _, line in ipairs(matches) do print(line) end
    else
        ns:Print("Saved to SavedVariables. /reload to write the file, or use /dint completed <text> to search.")
    end
end

function ns:DumpCompleted(filter)
    local ids, source = GetCompletedIDs()
    if not ids then
        ns:Print("This client has no completed-quest list API. Run /dint api for details.")
        return
    end
    if filter == "" then filter = nil end

    -- Ask the client to load uncached quest names, retrying a few times because
    -- the server answers slowly. Hidden "flag" quests never get a name, so we
    -- stop once a retry makes no progress.
    local canRequest = Has("C_QuestLog.RequestLoadQuestByID")
    local MAX_TRIES, DELAY = 5, 3
    local tries, lastMissing = 0, math.huge

    local function Attempt()
        local missing = 0
        for _, id in ipairs(ids) do
            if not GetQuestTitle(id) then
                missing = missing + 1
                if canRequest then C_QuestLog.RequestLoadQuestByID(id) end
            end
        end
        tries = tries + 1
        if missing == 0 or not canRequest or tries > MAX_TRIES or missing >= lastMissing then
            Snapshot(ids, source, filter)
            return
        end
        lastMissing = missing
        ns:Print(("Loading %d quest names (attempt %d)..."):format(missing, tries))
        C_Timer.After(DELAY, Attempt)
    end

    Attempt()
end
