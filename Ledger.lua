-- Ledger: the gold Vendor Printer actually earns you.
-- Records what you pay (vendor and AH purchases) and what you get (vendor sales, AH sale mail), carries
-- reagent costs into crafted items (oldest stock first), and books profit when a tracked item sells.
-- Stored per character in VendorPrinterCharDB.ledger.
local addonName, ns = ...
local log = ns.Logger("Ledger")

local MAX_TX = 1000        -- recent transactions kept for the report
local CONFIRM_WINDOW = 5   -- seconds a purchase or sale waits for the money to change (else the server refused it)
local CRAFT_WINDOW = 10    -- seconds a craft waits for its product to reach the bags

local L                    -- VendorPrinterCharDB.ledger
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemCount = (C_Item and C_Item.GetItemCount) or GetItemCount

-- Report order and labels.
ns.ACTIVITIES = {
    { key = "craftVendor", label = "Craft, sell to vendor" },
    { key = "craftAH", label = "Craft, sell on AH" },
    { key = "flip", label = "Vendor -> AH flips" },
    { key = "resale", label = "Other resales" },
}

local function Today(offsetDays) return date("%Y-%m-%d", time() - (offsetDays or 0) * 86400) end

local function ItemLabel(itemID)
    local name = GetItemInfo(itemID)
    return name and ("%d (%s)"):format(itemID, name) or tostring(itemID)
end

local function Bump(t, key, fields)
    local e = t[key] or {}
    t[key] = e
    for k, v in pairs(fields) do e[k] = (e[k] or 0) + v end
end

local function Changed()
    if ns.RefreshReport then ns.RefreshReport() end
end

ns.On("ADDON_LOADED", function(_, loaded)
    if loaded ~= addonName then return end
    ns.char.ledger = ns.char.ledger or {}
    L = ns.char.ledger
    for _, key in ipairs({ "lots", "tx", "days", "items", "activities", "totals" }) do L[key] = L[key] or {} end
    L.started = L.started or time()
    local stock = 0
    for _ in pairs(L.lots) do stock = stock + 1 end
    log.info("Ledger: %d transactions, %d items in stock, tracking since %s", #L.tx, stock, date("%Y-%m-%d", L.started))
end)

function ns.GetLedger() return L end

---------------------------------------------------------------------------
-- Which purchases count: reagents of your recipes, and vendor items with an AH price (flip candidates)
---------------------------------------------------------------------------
local reagents, reagentsVersion
local function IsReagent(itemID)
    if not reagents or reagentsVersion ~= ns.recipesVersion then
        reagents, reagentsVersion = {}, ns.recipesVersion
        for _, prof in pairs(ns.char.professions) do
            for _, recipe in pairs(prof.recipes) do
                for _, slot in ipairs(recipe.reagents) do
                    for _, id in ipairs(slot.ids) do reagents[id] = true end
                end
            end
        end
    end
    return reagents[itemID]
end

local function IsTrackedBuy(itemID, source)
    return IsReagent(itemID) or (source == "vendor" and ns.db.ahMin[itemID] ~= nil)
end

---------------------------------------------------------------------------
-- Stock: lots of { q = units, c = unit cost, o = origin (vendor|ah|craft), e = cost partly estimated }
---------------------------------------------------------------------------
local function AddLot(itemID, qty, unitCost, origin, estimated)
    local lots = L.lots[itemID] or {}
    L.lots[itemID] = lots
    lots[#lots + 1] = { q = qty, c = unitCost, o = origin, e = estimated or nil, t = time() }
end

-- Takes up to `qty` units, oldest first. Returns cost, units found, the main origin, units with an estimated cost.
local function TakeLots(itemID, qty)
    local lots = L.lots[itemID]
    local cost, found, estimated, byOrigin = 0, 0, 0, {}
    while lots and lots[1] and found < qty do
        local lot = lots[1]
        local take = math.min(lot.q, qty - found)
        cost = cost + take * lot.c
        found = found + take
        if lot.e then estimated = estimated + take end
        byOrigin[lot.o] = (byOrigin[lot.o] or 0) + take
        lot.q = lot.q - take
        if lot.q <= 0 then table.remove(lots, 1) end
    end
    if lots and #lots == 0 then L.lots[itemID] = nil end
    local origin, most = nil, 0
    for o, n in pairs(byOrigin) do
        if n > most then origin, most = o, n end
    end
    return cost, found, origin, estimated
end

local function AddTx(tx)
    tx.t = time()
    local list = L.tx
    list[#list + 1] = tx
    if #list > MAX_TX + 100 then
        local keep = {}
        for i = #list - MAX_TX + 1, #list do keep[#keep + 1] = list[i] end
        L.tx = keep
    end
    Changed()
end

local function RecordBuy(itemID, qty, total, source)
    if qty <= 0 or total <= 0 then return end
    AddLot(itemID, qty, total / qty, source)
    Bump(L.days, Today(), { spent = total })
    AddTx({ k = "buy", i = itemID, q = qty, m = total, s = source })
    log.info("Bought %dx %s for %.0fc (%s)", qty, ItemLabel(itemID), total, source)
end

local function RecordSale(itemID, qty, revenue, channel)
    local cost, found, origin, estimated = TakeLots(itemID, qty)
    if found <= 0 then
        AddTx({ k = "sell", i = itemID, q = qty, m = revenue, s = channel, u = true })
        log.debug("Sold %dx %s for %.0fc (%s): not bought or crafted while tracking, not counted", qty, ItemLabel(itemID), revenue, channel)
        return
    end
    -- Only the tracked units count; the rest (looted, owned before tracking) are left out.
    local share = revenue * found / qty
    local profit = share - cost
    local activity
    if origin == "craft" then activity = channel == "ah" and "craftAH" or "craftVendor"
    elseif origin == "vendor" and channel == "ah" then activity = "flip"
    else activity = "resale" end
    local fields = { revenue = share, cost = cost, profit = profit, sales = 1, units = found }
    Bump(L.days, Today(), fields)
    Bump(L.activities, activity, fields)
    Bump(L.items, itemID, fields)
    Bump(L, "totals", { cost = cost, estimatedCost = estimated > 0 and cost * estimated / found or 0 })
    AddTx({ k = "sell", i = itemID, q = qty, m = revenue, s = channel, p = profit, a = activity, tq = found,
        e = estimated > 0 or nil })
    log.info("Sold %dx %s for %.0fc (%s, %s): %d tracked, cost %.0fc, profit %.0fc%s", qty, ItemLabel(itemID), revenue,
        channel, activity, found, cost, profit, estimated > 0 and (" (%d units at estimated cost)"):format(estimated) or "")
end

---------------------------------------------------------------------------
-- Money confirmation: a purchase or sale counts once the money actually changes
---------------------------------------------------------------------------
local expected = {}   -- { amount (copper, + received / - paid), fn(amount), t }
local lastMoney

local function Expect(amount, fn)
    expected[#expected + 1] = { amount = amount, fn = fn, t = GetTime() }
end

ns.On("PLAYER_LOGIN", function() lastMoney = GetMoney() end)
ns.On("PLAYER_MONEY", function()
    local money = GetMoney()
    if not lastMoney then lastMoney = money return end
    local delta = money - lastMoney
    lastMoney = money
    local now = GetTime()
    local candidates, used = {}, {}
    for _, e in ipairs(expected) do
        if now - e.t <= CONFIRM_WINDOW and delta ~= 0 and (e.amount > 0) == (delta > 0) then candidates[#candidates + 1] = e end
    end
    local remaining = delta
    for i, e in ipairs(candidates) do
        if remaining == 0 then break end
        -- Several requests can land in one money update; the last candidate takes what's left.
        if i == #candidates then
            used[e] = true
            ns.SafeCall("Ledger", e.fn, remaining)
            remaining = 0
        elseif math.abs(remaining) >= math.abs(e.amount) - 1 then
            used[e] = true
            ns.SafeCall("Ledger", e.fn, e.amount)
            remaining = remaining - e.amount
        end
    end
    local keep = {}
    for _, e in ipairs(expected) do
        if not used[e] then
            if now - e.t <= CONFIRM_WINDOW then keep[#keep + 1] = e
            else log.debug("Expected money change of %.0fc never came: request refused", e.amount) end
        end
    end
    expected = keep
end)

---------------------------------------------------------------------------
-- Vendor purchases and sales
---------------------------------------------------------------------------
-- Unit price and stack size of a merchant slot, or nil for currency items and free ones.
local function MerchantUnitPrice(index)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local info = C_MerchantFrame.GetItemInfo(index)
        if not info or info.hasExtendedCost or not info.price or info.price <= 0 then return nil end
        local stack = math.max(info.stackCount or 1, 1)
        return info.price / stack, stack
    end
    local _, _, price, stack, _, _, _, extendedCost = GetMerchantItemInfo(index)
    if extendedCost or not price or price <= 0 then return nil end
    stack = math.max(stack or 1, 1)
    return price / stack, stack
end

if BuyMerchantItem then
    hooksecurefunc("BuyMerchantItem", function(index, quantity)
        local itemID = GetMerchantItemID(index)
        local unit, stack = MerchantUnitPrice(index)
        if not (itemID and unit) or not IsTrackedBuy(itemID, "vendor") then return end
        Expect(-unit * (quantity or stack), function(amount)
            local paid = -amount
            RecordBuy(itemID, math.max(1, math.floor(paid / unit + 0.5)), paid, "vendor")
        end)
    end)
end

if C_Container and C_Container.UseContainerItem then
    hooksecurefunc(C_Container, "UseContainerItem", function(bag, slot)
        if not (L and MerchantFrame and MerchantFrame:IsShown()) then return end
        local info = C_Container.GetContainerItemInfo(bag, slot)
        local itemID = info and info.itemID
        if not itemID or not L.lots[itemID] then return end   -- only stock with a known cost matters
        local sell = ns.GetSellPrice(itemID)
        if not sell or sell <= 0 then return end
        local qty = info.stackCount or 1
        Expect(sell * qty, function(amount) RecordSale(itemID, qty, amount, "vendor") end)
    end)
end

---------------------------------------------------------------------------
-- AH purchases: commodities (start -> price -> confirm) and item buyouts
---------------------------------------------------------------------------
local commodity        -- { itemID, quantity, total } of the purchase in progress
local auctions = {}    -- [auctionID] = { itemID, quantity, buyout } from item searches

if C_AuctionHouse then
    if C_AuctionHouse.StartCommoditiesPurchase then
        hooksecurefunc(C_AuctionHouse, "StartCommoditiesPurchase", function(itemID, quantity)
            commodity = { itemID = itemID, quantity = quantity }
        end)
    end
    if C_AuctionHouse.PlaceBid then
        hooksecurefunc(C_AuctionHouse, "PlaceBid", function(auctionID, bidAmount)
            local a = auctions[auctionID]
            if not a or not a.buyout or bidAmount < a.buyout or not IsTrackedBuy(a.itemID, "ah") then return end
            Expect(-bidAmount, function(amount) RecordBuy(a.itemID, a.quantity, -amount, "ah") end)
        end)
    end
end

ns.On("COMMODITY_PRICE_UPDATED", function(_, unitPrice, totalPrice)
    if commodity then commodity.total = totalPrice end
end)
ns.On("COMMODITY_PURCHASE_SUCCEEDED", function()
    local c = commodity
    commodity = nil
    if not c or not IsTrackedBuy(c.itemID, "ah") then return end
    local total = c.total
    if not total then
        total = (ns.db.ahMin[c.itemID] or 0) * c.quantity
        log.warn("AH purchase of %s: no price update seen, using the cheapest known price", ItemLabel(c.itemID))
    end
    RecordBuy(c.itemID, c.quantity, total, "ah")
end)
ns.On("COMMODITY_PURCHASE_FAILED", function() commodity = nil end)
ns.On("ITEM_SEARCH_RESULTS_UPDATED", function(_, itemKey)
    if not (itemKey and itemKey.itemID) then return end
    for i = 1, C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0 do
        local info = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        if info and info.auctionID then
            auctions[info.auctionID] = { itemID = itemKey.itemID, quantity = info.quantity or 1, buyout = info.buyoutAmount }
        end
    end
end)
ns.On("AUCTION_HOUSE_CLOSED", function()
    wipe(auctions)
    commodity = nil
end)

---------------------------------------------------------------------------
-- AH sales: the "Auction successful" mail's invoice says what sold, how many and for how much
---------------------------------------------------------------------------
local function ItemIDByName(name)
    local _, link = GetItemInfo(name)
    local id = link and tonumber(link:match("item:(%d+)"))
    if id then return id end
    for itemID in pairs(L.lots) do
        if GetItemInfo(itemID) == name then return itemID end
    end
end

local function OnMailMoney(index)
    if not (L and GetInboxHeaderInfo and GetInboxInvoiceInfo) then return end
    local _, _, _, _, money = GetInboxHeaderInfo(index)
    if not money or money <= 0 then return end
    local invoiceType, itemName, _, bid, _, _, consignment, _, _, count = GetInboxInvoiceInfo(index)
    if invoiceType ~= "seller" or not itemName or not bid then return end
    local itemID = ItemIDByName(itemName)
    if not itemID or not L.lots[itemID] then
        log.debug("AH sale of %q: not in tracked stock, not counted", itemName)
        return
    end
    if not count then
        -- Older clients don't report the count: estimate it from the cheapest known price.
        count = math.max(1, math.floor(bid / math.max(ns.db.ahMin[itemID] or bid, 1) + 0.5))
        log.warn("AH sale of %s: invoice has no count, estimated %d", ItemLabel(itemID), count)
    end
    -- Revenue is the sale price minus the AH cut; the refunded deposit isn't income.
    local revenue = bid - (consignment or 0)
    Expect(money, function() RecordSale(itemID, count, revenue, "ah") end)
end
if TakeInboxMoney then hooksecurefunc("TakeInboxMoney", OnMailMoney) end
if AutoLootMailItem then hooksecurefunc("AutoLootMailItem", OnMailMoney) end

---------------------------------------------------------------------------
-- Crafts: the cast succeeds, then the product reaches the bags; reagent cost moves into the product
---------------------------------------------------------------------------
local pendingCrafts = {}   -- { recipeID, output, before, cost, estimated, qmin, t }

local function FindRecipe(recipeID)
    for _, prof in pairs(ns.char.professions) do
        local recipe = prof.recipes[recipeID]
        if recipe then return recipe end
    end
end

local function ResolveCrafts(force)
    if #pendingCrafts == 0 then return end
    local groups, order = {}, {}
    for _, p in ipairs(pendingCrafts) do
        if not groups[p.output] then groups[p.output] = {}; order[#order + 1] = p.output end
        table.insert(groups[p.output], p)
    end
    local keep = {}
    for _, output in ipairs(order) do
        local group = groups[output]
        local produced = GetItemCount(output, true) - group[1].before
        local needed = 0
        for _, p in ipairs(group) do needed = needed + p.qmin end
        local expired = force or GetTime() - group[#group].t > CRAFT_WINDOW
        if produced >= needed or expired then
            -- Split what arrived between the crafts; without a count, assume the minimum output.
            local per = produced >= needed and produced / #group or nil
            for _, p in ipairs(group) do
                local qty = per or p.qmin
                AddLot(output, qty, p.cost / qty, "craft", p.estimated)
                AddTx({ k = "craft", i = output, q = qty, m = p.cost, r = p.recipeID, e = p.estimated or nil })
                log.info("Crafted %sx %s (recipe %d), reagent cost %.0fc%s", tostring(qty), ItemLabel(output), p.recipeID,
                    p.cost, p.estimated and " (partly estimated)" or "")
            end
        else
            for _, p in ipairs(group) do keep[#keep + 1] = p end
        end
    end
    pendingCrafts = keep
end

local castFrame = CreateFrame("Frame")
castFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
castFrame:SetScript("OnEvent", function(_, _, unit, _, spellID)
    ns.SafeCall("Event:UNIT_SPELLCAST_SUCCEEDED", function()
        if not L then return end
        local recipe = FindRecipe(spellID)   -- profession recipe IDs are their spell IDs
        if not recipe then return end
        local cost, estimated = 0, false
        for _, slot in ipairs(recipe.reagents) do
            local id = slot.ids[1]
            for _, candidate in ipairs(slot.ids) do
                if L.lots[candidate] then id = candidate break end
            end
            local c, found, _, est = TakeLots(id, slot.qty)
            local missing = slot.qty - found
            if missing > 0 then
                -- Reagents you already had (or gathered) cost what they'd cost to buy now.
                c = c + missing * (ns.BestReagentPrice(id) or ns.db.vendor[id] or 0)
                estimated = true
            end
            if est > 0 then estimated = true end
            cost = cost + c
        end
        pendingCrafts[#pendingCrafts + 1] = { recipeID = spellID, output = recipe.output, before = GetItemCount(recipe.output, true),
            cost = cost, estimated = estimated, qmin = math.max(recipe.qmin or 1, 1), t = GetTime() }
        ns.After(CRAFT_WINDOW + 1, "CraftTimeout", function() ResolveCrafts(false) end)
    end)
end)
ns.On("BAG_UPDATE_DELAYED", function() ResolveCrafts(false) end)

---------------------------------------------------------------------------
-- Report helpers
---------------------------------------------------------------------------
-- Totals over the last `days` days (nil = all time): profit, revenue, cost, sales, spent.
function ns.LedgerPeriod(days)
    local out = { profit = 0, revenue = 0, cost = 0, sales = 0, spent = 0 }
    local from = days and Today(days - 1) or nil
    for day, e in pairs(L.days) do
        if not from or day >= from then
            for k in pairs(out) do out[k] = out[k] + (e[k] or 0) end
        end
    end
    return out
end

-- Units and cost of stock bought or crafted but not sold yet.
function ns.LedgerStock()
    local units, cost = 0, 0
    for _, lots in pairs(L.lots) do
        for _, lot in ipairs(lots) do
            units = units + lot.q
            cost = cost + lot.q * lot.c
        end
    end
    return units, cost
end

function ns.ResetLedger()
    wipe(L)
    for _, key in ipairs({ "lots", "tx", "days", "items", "activities", "totals" }) do L[key] = {} end
    L.started = time()
    pendingCrafts, expected = {}, {}
    log.info("Ledger reset")
    Changed()
end
