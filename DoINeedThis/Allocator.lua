local _, ns = ...

--[[
Need calculation and distribution planning.

For each character in a realm/faction group:
  required = total of each item still needed by quests they haven't done
  have     = bags + bank + mail (mail = sent to them but not collected yet)
  short    = max(0, required - have)
  spare    = max(0, have - required)

Distribution (what the current character should mail, from its bags only):
  for each item, walk the priority list top to bottom:
    - the sender, at its own slot, keeps what it still needs beyond its bank/mail
    - everyone else receives up to their shortfall
  anything left goes to the group's fallback character (if it isn't the sender).
]]

local function Eligible(char, quest, faction)
    if quest.faction and quest.faction ~= faction then return false end
    if quest.class and quest.class ~= char.class then return false end
    return true
end

-- { [itemID] = { required = n, quests = { questID, ... } } }
function ns:CharRequirements(char, faction)
    local req = {}
    for questID, quest in pairs(ns.Quests) do
        if char.quests[questID] ~= "done" and Eligible(char, quest, faction) then
            for itemID, count in pairs(quest.items) do
                local r = req[itemID]
                if not r then
                    r = { required = 0, quests = {} }
                    req[itemID] = r
                end
                r.required = r.required + count
                table.insert(r.quests, questID)
            end
        end
    end
    return req
end

local function Held(char, itemID)
    local h = char.items and char.items[itemID]
    if not h then return 0, 0, 0 end
    return h.bags or 0, h.bank or 0, h.mail or 0
end
ns.Held = Held

local function IsExcluded(group, name)
    return group.excluded and group.excluded[name]
end

-- ---------------------------------------------------------------------------
-- Summary
--   summary[itemID] = {
--       short = n, spare = n,                       -- totals across the group
--       chars = { [name] = { required, bags, bank, mail, have, short, spare, quests } },
--   }
-- Cached until ns:Changed() bumps ns.dataVersion.
-- ---------------------------------------------------------------------------
ns.dataVersion = 0
local cache = {}

function ns:Summarize(group, faction)
    local key = tostring(group)
    local c = cache[key]
    if c and c.version == ns.dataVersion then return c.summary end

    local summary = {}
    for name, char in pairs(group.characters) do
        if not IsExcluded(group, name) then
            local req = ns:CharRequirements(char, faction)
            local ids = {}
            for itemID in pairs(req) do ids[itemID] = true end
            for itemID in pairs(char.items or {}) do
                if ns.trackedItems[itemID] then ids[itemID] = true end
            end

            for itemID in pairs(ids) do
                local bags, bank, mail = Held(char, itemID)
                local have = bags + bank + mail
                local r = req[itemID]
                local required = r and r.required or 0
                if required > 0 or have > 0 then
                    local e = {
                        required = required, bags = bags, bank = bank, mail = mail, have = have,
                        short = math.max(0, required - have),
                        spare = math.max(0, have - required),
                        quests = r and r.quests or {},
                    }
                    local s = summary[itemID]
                    if not s then
                        s = { short = 0, spare = 0, chars = {} }
                        summary[itemID] = s
                    end
                    s.chars[name] = e
                    s.short = s.short + e.short
                    s.spare = s.spare + e.spare
                end
            end
        end
    end

    cache[key] = { version = ns.dataVersion, summary = summary }
    return summary
end

-- ---------------------------------------------------------------------------
-- Distribution plan for the sender's bag contents (plus bank if includeBank).
--   plan = { [recipient] = { [itemID] = count } }
-- ---------------------------------------------------------------------------
function ns:PlanDistribution(group, faction, senderName, includeBank)
    local plan = {}
    local sender = group.characters[senderName]
    if not sender then return plan end

    local reqs = {}
    local function Required(name, itemID)
        if not reqs[name] then
            reqs[name] = ns:CharRequirements(group.characters[name], faction)
        end
        local r = reqs[name][itemID]
        return r and r.required or 0
    end

    local function Give(name, itemID, count)
        plan[name] = plan[name] or {}
        plan[name][itemID] = (plan[name][itemID] or 0) + count
    end

    for itemID in pairs(ns.trackedItems) do
        local senderBags, senderBank = Held(sender, itemID)
        local available = senderBags + (includeBank and senderBank or 0)
        if available > 0 then
            for _, name in ipairs(group.priority) do
                if available <= 0 then break end
                local char = group.characters[name]
                if char and not IsExcluded(group, name) then
                    local bags, bank, mail = Held(char, itemID)
                    if name == senderName then
                        -- Bank counts as already kept unless it's up for distribution too.
                        local kept = mail + (includeBank and 0 or bank)
                        local keep = math.max(0, Required(name, itemID) - kept)
                        available = available - math.min(keep, available)
                    else
                        local give = math.min(available, math.max(0, Required(name, itemID) - (bags + bank + mail)))
                        if give > 0 then
                            Give(name, itemID, give)
                            available = available - give
                        end
                    end
                end
            end

            local fallback = group.fallback
            if available > 0 and fallback and fallback ~= senderName
                and group.characters[fallback] and not IsExcluded(group, fallback) then
                Give(fallback, itemID, available)
            end
        end
    end
    return plan
end

-- Items the sender should take out of the bank so they can be mailed:
-- the extra the plan would send if the bank were in the bags.
--   { [itemID] = { total = n, to = { [recipient] = n } } }
function ns:PlanBankWithdrawals(group, faction, senderName)
    local bagsOnly = ns:PlanDistribution(group, faction, senderName, false)
    local withBank = ns:PlanDistribution(group, faction, senderName, true)
    local result = {}
    for name, items in pairs(withBank) do
        for itemID, count in pairs(items) do
            local extra = count - ((bagsOnly[name] and bagsOnly[name][itemID]) or 0)
            if extra > 0 then
                local r = result[itemID] or { total = 0, to = {} }
                r.total = r.total + extra
                r.to[name] = extra
                result[itemID] = r
            end
        end
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Change notification: invalidates the summary cache and lets UI refresh.
-- ---------------------------------------------------------------------------
local listeners = {}
function ns:OnChanged(fn) table.insert(listeners, fn) end

local pending = false
function ns:Changed()
    ns.dataVersion = ns.dataVersion + 1
    if pending then return end
    pending = true
    C_Timer.After(0.2, function()
        pending = false
        for _, fn in ipairs(listeners) do fn() end
    end)
end
