local ADDON_NAME, ns = ...

ns.VERSION = "0.1.0"
local DB_VERSION = 1

-- ---------------------------------------------------------------------------
-- Event dispatch
-- ---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
local handlers = {}

function ns:On(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        frame:RegisterEvent(event)
    end
    table.insert(handlers[event], fn)
end

frame:SetScript("OnEvent", function(_, event, ...)
    for _, fn in ipairs(handlers[event]) do
        fn(event, ...)
    end
end)

function ns:Print(...)
    print("|cffffd100DoINeedThis?|r", ...)
end

-- ---------------------------------------------------------------------------
-- Saved data
--   DoINeedThisDB = {
--     version  = n,
--     settings = { ... },
--     realms   = { [realm] = { [faction] = group } },
--   }
--   group = {
--     characters = { [name] = char },
--     priority   = { name, ... },   -- highest priority first
--     fallback   = name | nil,      -- receives excess items
--   }
--   char = { class, level, lastSeen, quests = { [questID] = "done"|"active" },
--            items = { [itemID] = { bags = n, bank = n, mail = n } } }
-- ---------------------------------------------------------------------------
local function InitDB()
    DoINeedThisDB = DoINeedThisDB or {}
    local db = DoINeedThisDB
    db.version = db.version or DB_VERSION
    db.settings = db.settings or {}
    db.realms = db.realms or {}
    ns.db = db
end

function ns:GetGroup(realm, faction)
    local realms = ns.db.realms
    realms[realm] = realms[realm] or {}
    local r = realms[realm]
    r[faction] = r[faction] or { characters = {}, priority = {}, fallback = nil }
    return r[faction]
end

local function InitCharacter()
    local name = UnitName("player")
    local realm = GetRealmName()
    local faction = UnitFactionGroup("player")
    local group = ns:GetGroup(realm, faction)

    local char = group.characters[name] or {}
    char.class = select(2, UnitClass("player"))
    char.level = UnitLevel("player")
    char.quests = char.quests or {}
    char.items = char.items or {}
    group.characters[name] = char

    if not tContains(group.priority, name) then
        table.insert(group.priority, name)
    end

    ns.playerName, ns.realm, ns.faction = name, realm, faction
    ns.char, ns.group = char, group
end

ns:On("ADDON_LOADED", function(_, addon)
    if addon == ADDON_NAME then
        InitDB()
    end
end)

ns:On("PLAYER_LOGIN", function()
    InitCharacter()
    ns:MergeLearned()
    ns:BuildTrackedItems()
    ns:ScanAll()
end)

ns:On("PLAYER_LEVEL_UP", function(_, level)
    if ns.char then ns.char.level = level end
end)

ns:On("PLAYER_LOGOUT", function()
    if ns.char then ns.char.lastSeen = time() end
end)

-- ---------------------------------------------------------------------------
-- Slash command (debug dump for now; replaced by the main window later)
-- ---------------------------------------------------------------------------
local function Dump()
    if not next(ns.Quests) then
        ns:Print("No quests configured yet (Data/Quests.lua).")
        return
    end
    ns:ScanAll()
    ns:Print(("%s - %s"):format(ns.realm, ns.faction))
    for _, name in ipairs(ns.group.priority) do
        local char = ns.group.characters[name]
        print(("  |cffffffff%s|r (%s %d)"):format(name, char.class or "?", char.level or 0))
        for questID, quest in pairs(ns.Quests) do
            print(("    [%s] %s"):format(char.quests[questID] or "todo", quest.name or questID))
            for itemID, count in pairs(quest.items) do
                local held = char.items[itemID] or {}
                print(("      item %d: bags %d, bank %d, mail %d / %d"):format(
                    itemID, held.bags or 0, held.bank or 0, held.mail or 0, count))
            end
        end
    end
end

SLASH_DOINEEDTHIS1 = "/dint"
SlashCmdList.DOINEEDTHIS = function(msg)
    msg = strtrim(msg or ""):lower()
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    if cmd == "scan" then
        ns:ScanAll()
        ns:Print("Rescanned.")
    elseif cmd == "api" then
        ns:CheckAPI()
    elseif cmd == "completed" then
        ns:DumpCompleted(rest)
    elseif cmd == "learned" then
        ns:ListLearned()
    elseif cmd == "config" or cmd == "settings" then
        ns:OpenOptions()
    elseif cmd == "dump" then
        Dump()
    elseif cmd == "" then
        ns:ScanAll()
        ns:ToggleMainFrame()
    else
        ns:Print("Commands: /dint (window), /dint config, /dint dump, /dint scan, /dint learned, /dint completed [text], /dint api")
    end
end
