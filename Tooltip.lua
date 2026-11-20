-- Tooltip: adds AH / vendor prices and recipe usage to item tooltips
-- (bags, profession reagent icons, links... anywhere WoW shows an item tooltip).
local _, ns = ...
local log = ns.Logger("Tooltip")

local logged = {}            -- itemIDs already logged this session (tooltips refresh constantly)
local usage, usageVersion    -- [itemID] = number of recorded recipes using it, rebuilt when recipes change
local crafted = {}           -- [itemID] = true if one of your recipes makes it (rebuilt with `usage`)

local function AgoText(t)
    if not t then return nil end
    local seconds = time() - t
    if seconds < 60 then return "just now" end
    if SecondsToTime then return SecondsToTime(seconds, true) .. " ago" end
    return math.floor(seconds / 60) .. " min ago"
end

local function UsageCount(itemID)
    if usageVersion ~= ns.recipesVersion or not usage then
        usage, usageVersion, crafted = {}, ns.recipesVersion, {}
        local recipes = 0
        for _, prof in pairs(ns.char.professions) do
            for _, recipe in pairs(prof.recipes) do
                recipes = recipes + 1
                crafted[recipe.output] = true
                local seen = {}
                for _, slot in ipairs(recipe.reagents) do
                    for _, id in ipairs(slot.ids) do
                        if not seen[id] then
                            seen[id] = true
                            usage[id] = (usage[id] or 0) + 1
                        end
                    end
                end
            end
        end
        log.debug("Reagent usage index rebuilt: %d reagents across %d recipes", ns.CountKeys(usage), recipes)
    end
    return usage[itemID]
end

local GOLD, WHITE, GREY = { 1, 0.82, 0 }, { 1, 1, 1 }, { 0.6, 0.6, 0.6 }

local function AddLines(tooltip, itemID)
    local db = ns.db
    if not db or not db.settings.tooltip then return end
    local ah, vendor = db.ah[itemID], db.vendor[itemID]
    local uses = UsageCount(itemID)
    local isCrafted = crafted[itemID] and db.settings.modules.ah
    if not ah and not vendor and not uses and not isCrafted then return end

    local depth = db.settings.ahDepth or 20
    tooltip:AddLine("Vendor Printer", 0.2, 1, 0.6)

    if ah then
        local label = db.ahQuick[itemID] and "  AH (cheapest listing)" or ("  AH (avg of cheapest %d)"):format(depth)
        local right = ns.Money(ah)
        local supply = db.ahSupply[itemID]
        if supply and supply < depth then right = right .. (" |cffff8040(only %d listed)|r"):format(supply) end
        tooltip:AddDoubleLine(label, right, GOLD[1], GOLD[2], GOLD[3], WHITE[1], WHITE[2], WHITE[3])
    elseif uses then
        tooltip:AddDoubleLine("  AH", "|cff888888no price (not listed or not scanned)|r", GOLD[1], GOLD[2], GOLD[3])
    end

    if vendor then
        local right = ns.Money(vendor) .. (db.vendorLimited[itemID] and " |cffff8040(limited stock)|r" or "")
        tooltip:AddDoubleLine("  Vendor buy", right, GOLD[1], GOLD[2], GOLD[3], WHITE[1], WHITE[2], WHITE[3])
    end

    if ah and vendor then
        local _, source = ns.BestReagentPrice(itemID)
        tooltip:AddDoubleLine("  Cheapest", source == "AH" and "Auction House" or "Vendor",
            GOLD[1], GOLD[2], GOLD[3], 0.25, 1, 0.25)
    end

    -- Flip: bought from a vendor, worth more on the AH after the cut.
    local flip = db.settings.modules.flips and ns.FlipProfit(itemID)
    if flip and flip > 0 then
        tooltip:AddDoubleLine("  AH flip profit", ("|cff40ff40%s|r each"):format(ns.Money(flip)),
            0.25, 1, 0.25, WHITE[1], WHITE[2], WHITE[3])
        local listed = db.ahListed[itemID]
        tooltip:AddLine(("  Buy at vendor, sell on AH at %s%s"):format(ns.Money(db.ahMin[itemID]),
            listed and (" (%d listed)"):format(listed) or ""), GREY[1], GREY[2], GREY[3])
        local source = db.vendorSource[itemID]
        if source then
            tooltip:AddLine(("  Sold by %s%s"):format(source.npc, source.zone ~= "" and (" (" .. source.zone .. ")") or ""),
                GREY[1], GREY[2], GREY[3])
        end
    end

    -- You can craft this: what it nets on the AH after the cut.
    if isCrafted then
        local net = ns.AHNet(itemID)
        if net then
            local listed = db.ahListed[itemID]
            tooltip:AddDoubleLine("  You craft this: AH net", ns.Money(net) .. (listed and (" |cff999999(%d listed)|r"):format(listed) or ""),
                GOLD[1], GOLD[2], GOLD[3], WHITE[1], WHITE[2], WHITE[3])
        else
            tooltip:AddDoubleLine("  You craft this", "|cff888888no AH price|r", GOLD[1], GOLD[2], GOLD[3])
        end
    end

    if uses then
        tooltip:AddLine(("  Reagent in %d of your recipes"):format(uses), WHITE[1], WHITE[2], WHITE[3])
    end

    if ah then
        local newest = math.max(db.ahScanTime or 0, db.ahReagentScanTime or 0)
        local ago = AgoText(newest > 0 and newest or nil)
        if ago then tooltip:AddLine("  AH prices from " .. ago, GREY[1], GREY[2], GREY[3]) end
    end

    if not logged[itemID] then
        logged[itemID] = true
        log.debug("Tooltip for item %d: ah=%s%s ahMin=%s vendor=%s%s uses=%s crafted=%s flip=%s", itemID, tostring(ah),
            db.ahQuick[itemID] and " (quick)" or "", tostring(db.ahMin[itemID]), tostring(vendor),
            db.vendorLimited[itemID] and " (limited)" or "", tostring(uses), tostring(isCrafted), tostring(flip))
    end
end

local function Handle(tooltip, itemID)
    if not itemID then return end
    -- Prices don't matter mid-fight, and combat tooltips may carry restricted values.
    if InCombatLockdown and InCombatLockdown() then return end
    -- Skip the side-by-side comparison tooltips so lines don't appear three times.
    if tooltip == _G.ShoppingTooltip1 or tooltip == _G.ShoppingTooltip2 then return end
    ns.SafeCall("Tooltip", AddLines, tooltip, itemID)
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        Handle(tooltip, data and data.id)
    end)
    log.info("Tooltip hook installed (TooltipDataProcessor)")
elseif GameTooltip and GameTooltip.HookScript then
    GameTooltip:HookScript("OnTooltipSetItem", function(tooltip)
        local _, link = tooltip:GetItem()
        Handle(tooltip, link and tonumber(link:match("item:(%d+)")))
    end)
    log.info("Tooltip hook installed (OnTooltipSetItem fallback)")
else
    log.warn("No tooltip hook available on this client; item tooltips won't show prices")
end
