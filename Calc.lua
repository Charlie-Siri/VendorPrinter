-- Calc: reagent cost (cheapest of AH/vendor) vs. what the output sells for (vendor or AH),
-- plus vendor -> AH flips.
local _, ns = ...
local log = ns.Logger("Calc")
local lastSummary = {}

ns.AH_CUT = 0.05   -- the AH keeps 5% of the sale price

-- Cheapest known unit price for an item and where it comes from.
function ns.BestReagentPrice(itemID)
    local v = ns.db.vendor[itemID]
    local a = ns.db.ah[itemID]
    if v and a then
        if v <= a then return v, "Vendor" end
        return a, "AH"
    end
    if v then return v, "Vendor" end
    if a then return a, "AH" end
    return nil, nil
end

-- What you'd get per unit selling on the AH: matching the cheapest listing, minus the AH cut.
-- (Deposit is refunded on sale, so it's ignored.)
function ns.AHNet(itemID)
    local cheapest = ns.db.ahMin[itemID]
    if not cheapest then return nil end
    return cheapest * (1 - ns.AH_CUT)
end

-- mode "vendor" (default): output sold to a vendor. mode "ah": output sold on the AH.
function ns.Evaluate(recipe, mode)
    local cost, complete, parts = 0, true, {}
    for _, slot in ipairs(recipe.reagents) do
        -- A slot may accept several items (e.g. quality tiers): use the cheapest one.
        local best, source, bestID
        for _, id in ipairs(slot.ids) do
            local price, src = ns.BestReagentPrice(id)
            if price and (best == nil or price < best) then
                best, source, bestID = price, src, id
            end
        end
        local itemID = bestID or slot.ids[1]
        local part = { itemID = itemID, qty = slot.qty, unit = best, source = source }
        if source == "Vendor" and ns.db.vendorLimited[itemID] then
            part.warning = "limited vendor stock"
        elseif source == "AH" and (ns.db.ahSupply[itemID] or 0) < (ns.db.settings.ahDepth or 20) then
            part.warning = ("only %d on AH"):format(ns.db.ahSupply[itemID] or 0)
        elseif source == "AH" and ns.db.ahQuick[itemID] then
            part.warning = "cheapest listing only"
        end
        parts[#parts + 1] = part
        if best then
            cost = cost + best * slot.qty
        else
            complete = false
        end
    end

    mode = mode or "vendor"
    local sell
    if mode == "ah" then
        sell = ns.AHNet(recipe.output)
    else
        sell = ns.GetSellPrice(recipe.output)
    end
    local qty = (recipe.qmin + recipe.qmax) / 2
    local revenue = sell and sell * qty
    local profit = (complete and revenue) and (revenue - cost) or nil
    local roi = (profit and cost > 0) and (profit / cost) or nil

    return {
        mode = mode,
        cost = cost,
        complete = complete,
        parts = parts,
        sell = sell,
        qty = qty,
        revenue = revenue,
        profit = profit,
        roi = roi,
        listed = mode == "ah" and ns.db.ahListed[recipe.output] or nil,
    }
end

-- Shopping list for `crafts` crafts of an evaluated row, grouped by where to buy.
function ns.ShoppingList(result, crafts)
    local list = { Vendor = {}, AH = {}, Missing = {}, cost = 0 }
    for _, part in ipairs(result.parts) do
        local entry = { itemID = part.itemID, qty = part.qty * crafts, warning = part.warning }
        if part.unit then
            entry.total = part.unit * entry.qty
            list.cost = list.cost + entry.total
            table.insert(list[part.source], entry)
        else
            table.insert(list.Missing, entry)
        end
    end
    list.revenue = result.revenue and result.revenue * crafts
    list.profit = (result.complete and list.revenue) and (list.revenue - list.cost) or nil
    return list
end

local function SortByProfit(a, b, nameOf)
    if a.profit and b.profit then
        if a.profit ~= b.profit then return a.profit > b.profit end
    elseif a.profit or b.profit then
        return a.profit ~= nil
    end
    return nameOf(a) < nameOf(b)
end

-- Rebuilt often (item data loading, filters); log only when the outcome changes.
local function LogSummary(mode, summary)
    if summary ~= lastSummary[mode] then
        lastSummary[mode] = summary
        log.debug(summary)
    end
end

-- All recipes of this character evaluated for `mode`, filtered and sorted best first.
function ns.BuildRows(mode)
    mode = mode or "vendor"
    local settings = ns.db.settings
    local search = (settings.search or ""):lower()
    local rows = {}
    local total, profitable, loading = 0, 0, 0
    local hidden = { search = 0, unlearned = 0, unsellable = 0, incomplete = 0 }
    for profName, prof in pairs(ns.char.professions) do
        for recipeID, recipe in pairs(prof.recipes) do
            total = total + 1
            local matches = search == "" or (recipe.name or ""):lower():find(search, 1, true)
            if not matches then
                hidden.search = hidden.search + 1
            elseif not recipe.learned and settings.learnedOnly then
                hidden.unlearned = hidden.unlearned + 1
            else
                local result = ns.Evaluate(recipe, mode)
                -- Vendor mode: output with no vendor value can never be a vendor flip.
                local sellable = mode ~= "vendor" or result.sell == nil or result.sell > 0
                -- AH mode: no AH price for the output counts as a missing price.
                local complete = result.complete and (mode ~= "ah" or result.sell ~= nil)
                if not sellable then
                    hidden.unsellable = hidden.unsellable + 1
                elseif not complete and not settings.showIncomplete then
                    hidden.incomplete = hidden.incomplete + 1
                else
                    result.recipeID = recipeID
                    result.recipe = recipe
                    result.profession = profName
                    rows[#rows + 1] = result
                    if result.profit and result.profit > 0 then profitable = profitable + 1 end
                    if mode == "vendor" and result.sell == nil then loading = loading + 1 end
                end
            end
        end
    end
    table.sort(rows, function(a, b)
        return SortByProfit(a, b, function(r) return r.recipe.name or "" end)
    end)

    local top = rows[1]
    LogSummary(mode, ("Rows[%s]: %d of %d recipes shown, %d profitable, %d awaiting item data | hidden: %d search, %d unlearned, %d unsellable, %d missing prices | top: %s"):format(
        mode, #rows, total, profitable, loading, hidden.search, hidden.unlearned, hidden.unsellable, hidden.incomplete,
        top and top.profit and ("%q %.0fc/craft"):format(top.recipe.name or "?", top.profit) or "none"))
    return rows
end

-- Profit per unit buying from a vendor and selling on the AH, or nil if not known.
function ns.FlipProfit(itemID)
    local buy, net = ns.db.vendor[itemID], ns.AHNet(itemID)
    if not (buy and net) then return nil end
    return net - buy, buy, net
end

-- Vendor items that sell on the AH for more than they cost (after the AH cut), best first.
function ns.BuildFlipRows()
    local db = ns.db
    local search = (db.settings.search or ""):lower()
    local rows = {}
    local vendorItems, priced, losing, hiddenSearch = 0, 0, 0, 0
    local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    for itemID in pairs(db.vendor) do
        vendorItems = vendorItems + 1
        local profit, buy, net = ns.FlipProfit(itemID)
        if profit then
            priced = priced + 1
            if profit > 0 then
                local name = GetItemInfo(itemID)
                if search ~= "" and not (name or ""):lower():find(search, 1, true) then
                    hiddenSearch = hiddenSearch + 1
                else
                    rows[#rows + 1] = {
                        itemID = itemID, name = name, buy = buy, net = net, profit = profit,
                        roi = profit / buy, listed = db.ahListed[itemID], limited = db.vendorLimited[itemID],
                        source = db.vendorSource[itemID], quick = db.ahQuick[itemID],
                    }
                end
            else
                losing = losing + 1
            end
        end
    end
    table.sort(rows, function(a, b)
        return SortByProfit(a, b, function(r) return r.name or "" end)
    end)
    local top = rows[1]
    LogSummary("flips", ("Rows[flips]: %d flips shown | %d vendor items, %d with AH price, %d not profitable, %d hidden by search | top: %s"):format(
        #rows, vendorItems, priced, losing, hiddenSearch,
        top and ("item %d %.0fc/unit"):format(top.itemID, top.profit) or "none"))
    return rows
end
