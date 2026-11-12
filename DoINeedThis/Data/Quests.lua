local _, ns = ...

--[[
Static quest -> item requirements.

  [questID] = {
      name       = "Quest Name",            -- display only
      items      = { [itemID] = count },    -- items turned in for the quest
      faction    = "Alliance" | "Horde",    -- omit if both factions can do it
      minLevel   = 40,                      -- optional, informational (we still send to low levels)
      class      = "MAGE",                  -- optional, class-restricted quests
      requires   = { questID, ... },        -- optional prerequisite quests
      repeatable = true,                    -- optional, never counts as "done"
  },
]]

ns.Quests = {
}
