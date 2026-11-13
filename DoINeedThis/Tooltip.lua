local _, ns = ...

-- Adds "who needs this" lines to item tooltips for tracked items, using the
-- current realm/faction's characters.

local function AddLines(tooltip, itemID)
    if not itemID or not ns.group or not ns.trackedItems[itemID] then return end
    local s = ns:Summarize(ns.group, ns.faction)[itemID]
    if not s then return end

    local added = false
    for _, name in ipairs(ns.group.priority) do
        local e = s.chars[name]
        -- Show characters who still need it, or who hold some in the bank.
        if e and (e.required > 0 or e.bank > 0) then
            if not added then
                tooltip:AddLine(" ")
                tooltip:AddLine("Do I Need This?", 1, 0.82, 0)
                added = true
            end
            tooltip:AddDoubleLine(ns:CharName(ns.group, name), ns:StatusText(e))
        end
    end
    if added then tooltip:Show() end
end

local function ItemIDFromTooltip(tooltip)
    if not tooltip.GetItem then return nil end
    local _, link = tooltip:GetItem()
    return link and tonumber(link:match("item:(%d+)"))
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
        AddLines(tooltip, data and data.id or ItemIDFromTooltip(tooltip))
    end)
else
    for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
        tooltip:HookScript("OnTooltipSetItem", function(self)
            AddLines(self, ItemIDFromTooltip(self))
        end)
    end
end
