local _, ns = ...

--[[
Learns quest item requirements from the turn-in (progress) window.

When a character opens the turn-in window for a quest that isn't in
Data/Quests.lua, and the quest wants at least one tradeable item, it is saved to
DoINeedThisDB.learned and used straight away on every character.

Entries are kept flat (no nested tables) so tools/Build-QuestData.ps1 can parse
them reliably when baking them into Data/Quests.lua:

  learned[questID] = {
      name    = "Quest Name",
      items   = "itemID:count,itemID:count",   -- tradeable items only
      faction = "Alliance" | "Horde" | "Alliance,Horde",
      by      = "Name-Realm",                    -- first character to see it
      time    = 1794449885,
  }
]]

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

-- Bind types: 0 none, 1 on pickup, 2 on equip, 3 on use, 4 quest item.
local function IsTradeable(itemID)
    local bindType = select(14, GetItemInfo(itemID))
    if bindType == nil then return nil end        -- not cached: unknown
    return bindType ~= 1 and bindType ~= 4
end

local function ParseItems(str)
    local items = {}
    for id, count in (str or ""):gmatch("(%d+):(%d+)") do
        items[tonumber(id)] = tonumber(count)
    end
    return items
end

local function AddFaction(list, faction)
    for f in (list or ""):gmatch("[^,]+") do
        if f == faction then return list end
    end
    return list and list ~= "" and (list .. "," .. faction) or faction
end

-- Copy learned quests that aren't baked into Data/Quests.lua into ns.Quests.
function ns:MergeLearned()
    local learned = ns.db.learned
    if not learned then return end
    for questID, entry in pairs(learned) do
        local quest = ns.Quests[questID]
        if not quest or quest.learned then
            local faction = entry.faction
            if faction and faction:find(",") then faction = nil end
            ns.Quests[questID] = {
                name = entry.name,
                items = ParseItems(entry.items),
                faction = faction,
                learned = true,
            }
        end
    end
end

local function OnQuestProgress()
    local questID = GetQuestID()
    if not questID or questID == 0 or not ns.char then return end

    local baked = ns.Quests[questID] and not ns.Quests[questID].learned
    if baked then return end

    local items, unknown = {}, false
    for i = 1, GetNumQuestItems() do
        local link = GetQuestItemLink("required", i)
        local _, _, count = GetQuestItemInfo("required", i)
        local itemID = link and tonumber(link:match("item:(%d+)"))
        if itemID and count then
            local tradeable = IsTradeable(itemID)
            if tradeable == nil then unknown = true end
            if tradeable ~= false then
                items[#items + 1] = ("%d:%d"):format(itemID, count)
            end
        end
    end
    if #items == 0 then return end

    ns.db.learned = ns.db.learned or {}
    local entry = ns.db.learned[questID]
    local itemStr = table.concat(items, ",")
    local isNew = not entry

    if isNew then
        entry = { by = ns.playerName .. "-" .. ns.realm, time = time() }
        ns.db.learned[questID] = entry
    end
    entry.name = GetTitleText() or entry.name
    entry.items = itemStr
    entry.faction = AddFaction(entry.faction, ns.faction)

    ns:MergeLearned()
    ns:BuildTrackedItems()
    ns:ScanBags()

    if isNew then
        ns:Print(("Learned quest: %s (%d)%s"):format(entry.name or "?", questID,
            unknown and " - some item info wasn't loaded, will be checked when baking" or ""))
    end
end

ns:On("QUEST_PROGRESS", OnQuestProgress)

-- /dint learned
function ns:ListLearned()
    local learned = ns.db.learned
    if not learned or not next(learned) then
        ns:Print("No quests learned yet. They're picked up from the turn-in window.")
        return
    end
    ns:Print("Learned quests (\"baked\" = already in Data/Quests.lua):")
    for questID, entry in pairs(learned) do
        local quest = ns.Quests[questID]
        local baked = quest and not quest.learned
        print(("  %d  %s  [%s]  %s%s"):format(questID, entry.name or "?", entry.items or "",
            entry.faction or "?", baked and "  |cff00ff00baked|r" or ""))
    end
end
