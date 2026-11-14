local _, ns = ...

--[[
"Withdraw from bank": moves what the current character needs, plus what it
should mail on, from the bank into the bags. Bank must be open.

Whole stacks are moved with UseContainerItem (the game finds bag space and
merges stacks). Partial amounts are split into an empty bag slot.
]]

local NUM_BAGS = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4

local working = false
local co

local function Wait(seconds)
    C_Timer.After(seconds, function()
        if co and coroutine.status(co) == "suspended" then
            local ok, err = coroutine.resume(co)
            if not ok then
                working = false
                ns:Print("Withdrawing stopped by an error: " .. tostring(err))
                ns:Changed()
            end
        end
    end)
    coroutine.yield()
end

local function BankContainers()
    local list = { BANK_CONTAINER or -1 }
    local first = NUM_BAGS + 1
    for bag = first, first + (NUM_BANKBAGSLOTS or 7) - 1 do
        list[#list + 1] = bag
    end
    return list
end

local function BankStacks(itemID)
    local stacks = {}
    for _, bag in ipairs(BankContainers()) do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID == itemID and not info.isLocked then
                stacks[#stacks + 1] = { bag = bag, slot = slot, count = info.stackCount }
            end
        end
    end
    table.sort(stacks, function(a, b) return a.count < b.count end)
    return stacks
end

local function EmptyBagSlot()
    for bag = 0, NUM_BAGS do
        local free, family = C_Container.GetContainerNumFreeSlots(bag)
        if free and free > 0 and family == 0 then
            for slot = 1, C_Container.GetContainerNumSlots(bag) do
                if not C_Container.GetContainerItemInfo(bag, slot) then return bag, slot end
            end
        end
    end
end

local function Withdraw(plan)
    local moved = 0
    for itemID, want in pairs(plan) do
        while want > 0 do
            if not ns.bankOpen then return moved, "the bank was closed" end
            local stacks = BankStacks(itemID)
            if #stacks == 0 then break end

            -- Prefer the largest whole stack that fits, otherwise split.
            local stack
            for _, s in ipairs(stacks) do
                if s.count <= want then stack = s end
            end

            if stack then
                C_Container.UseContainerItem(stack.bag, stack.slot)
                want = want - stack.count
                moved = moved + stack.count
            else
                local bag, slot = EmptyBagSlot()
                if not bag then return moved, "no free bag slot" end
                stack = stacks[1]
                ClearCursor()
                C_Container.SplitContainerItem(stack.bag, stack.slot, want)
                C_Container.PickupContainerItem(bag, slot)
                moved = moved + want
                want = 0
            end
            Wait(0.4)      -- let the server move it and clear the locks
        end
    end
    return moved
end

function ns:WithdrawFromBank()
    if working or not ns.bankOpen or not ns.group then return end
    local plan = ns:PlanAllWithdrawals(ns.group, ns.faction, ns.playerName)
    if not next(plan) then return end

    working = true
    ns:Changed()
    co = coroutine.create(function()
        local moved, reason = Withdraw(plan)
        working = false
        if reason then
            ns:Print(("Withdrew %d items, then stopped: %s."):format(moved, reason))
        else
            ns:Print(("Withdrew %d items from the bank."):format(moved))
        end
        ns:ScanBags()
        if ns.bankOpen then ns:ScanBank() end
    end)
    local ok, err = coroutine.resume(co)
    if not ok then
        working = false
        ns:Print("Withdrawing stopped by an error: " .. tostring(err))
        ns:Changed()
    end
end

function ns:IsWithdrawing() return working end
