-- Prices: vendor prices recorded from merchants, AH prices from a full scan or a reagent-only scan.
local _, ns = ...
local log = ns.Logger("Prices")

local AH_THROTTLE = 15 * 60   -- Blizzard allows one full AH scan per 15 minutes
local CHUNK = 2000            -- listings processed per frame, avoids freezing on big scans
local SCAN_TIMEOUT = 90       -- seconds to wait for the server's full scan data

-- Searched and nothing listed: drop every AH field rather than trust stale ones.
local function ClearAHPrice(itemID)
    local db = ns.db
    db.ah[itemID], db.ahMin[itemID], db.ahSupply[itemID], db.ahQuick[itemID], db.ahListed[itemID] = nil, nil, nil, nil, nil
end

local function ItemLabel(itemID)
    local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)) or nil
    return name and ("%d (%s)"):format(itemID, name) or tostring(itemID)
end

---------------------------------------------------------------------------
-- Vendor prices
---------------------------------------------------------------------------
local function GetMerchantEntry(index)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local info = C_MerchantFrame.GetItemInfo(index)
        if info then return info.price, info.stackCount, info.hasExtendedCost, info.numAvailable end
        return nil
    end
    local _, _, price, quantity, numAvailable, _, _, extendedCost = GetMerchantItemInfo(index)
    return price, quantity, extendedCost, numAvailable
end

local function ScanMerchant()
    local vendor, limited, sources, unlimited = ns.db.vendor, ns.db.vendorLimited, ns.db.vendorSource, ns.db.vendorUnlimited
    local count = GetMerchantNumItems()
    local added, lowered, skipped = 0, 0, 0
    local npc = UnitName("npc") or "?"
    local zone = (GetZoneText and GetZoneText()) or ""
    log.info("Scanning merchant %q in %q: %d items", npc, zone, count)
    local merchantItems = {}   -- [merchant index] = { itemID, unit, available } for flip alerts
    for i = 1, count do
        local itemID = GetMerchantItemID(i)
        local price, stack, extendedCost, numAvailable = GetMerchantEntry(i)
        -- Skip items that cost currencies/tokens: only plain gold purchases count.
        if itemID and price and price > 0 and not extendedCost then
            local unit = price / math.max(stack or 1, 1)
            merchantItems[i] = { itemID = itemID, unit = unit, available = numAvailable }
            local old = vendor[itemID]
            if old == nil then
                added = added + 1
                vendor[itemID] = unit
                log.debug("Vendor price new: item %s = %.2fc/unit (price %d for stack %d, available %s)",
                    ItemLabel(itemID), unit, price, stack or 1, tostring(numAvailable))
            elseif unit < old then
                lowered = lowered + 1
                vendor[itemID] = unit
                log.debug("Vendor price lowered: item %s %.2fc -> %.2fc/unit", ItemLabel(itemID), old, unit)
            end
            -- Where to buy it (for flips): the vendor with the lowest price seen.
            if vendor[itemID] == unit then sources[itemID] = { npc = npc, zone = zone } end
            -- numAvailable is -1 for unlimited stock.
            if not (numAvailable and numAvailable >= 0) and (unlimited[itemID] == nil or unit < unlimited[itemID]) then
                unlimited[itemID] = unit
            end
            if numAvailable and numAvailable >= 0 then
                if not limited[itemID] then log.debug("Item %s is limited stock (%d available)", ItemLabel(itemID), numAvailable) end
                limited[itemID] = true
            else
                limited[itemID] = nil
            end
        else
            skipped = skipped + 1
            log.debug("Merchant slot %d skipped: itemID=%s price=%s extendedCost=%s",
                i, tostring(itemID), tostring(price), tostring(extendedCost))
        end
    end
    log.info("Merchant scan done: %d new, %d lowered, %d skipped (currency/free/unknown), %d vendor prices total",
        added, lowered, skipped, ns.CountKeys(vendor))
    if added > 0 then
        ns.Print("Recorded %d new vendor price%s.", added, added == 1 and "" or "s")
    end
    if added > 0 or lowered > 0 then ns.Refresh() end
    if ns.OnMerchantScanned then ns.OnMerchantScanned(merchantItems, npc, zone) end
end

ns.On("MERCHANT_SHOW", function() ns.Debounce("merchant", 0.2, ScanMerchant) end)
ns.On("MERCHANT_UPDATE", function() ns.Debounce("merchant", 0.2, ScanMerchant) end)

---------------------------------------------------------------------------
-- Full AH scan (ReplicateItems)
---------------------------------------------------------------------------
ns.ahOpen = false
local scanPending = false
local fullScanStartedAt = 0

function ns.AHScanCooldown()
    local remaining = AH_THROTTLE - (time() - (ns.db.ahScanStarted or 0))
    return remaining > 0 and remaining or 0
end

function ns.StartAHScan(manual)
    local function refuse(reason, chat)
        log.info("Full scan not started (%s): %s", manual and "manual" or "auto", reason)
        if manual and chat then ns.Print(chat) end
    end
    if not (C_AuctionHouse and C_AuctionHouse.ReplicateItems) then
        return refuse("C_AuctionHouse.ReplicateItems missing", "This client has no full AH scan API (C_AuctionHouse.ReplicateItems).")
    end
    if not ns.ahOpen then
        return refuse("AH not open", "Open the Auction House first.")
    end
    if scanPending then
        return refuse("full scan already running (" .. tostring(scanPending) .. ")", "A scan is already running.")
    end
    local cooldown = ns.AHScanCooldown()
    if cooldown > 0 then
        return refuse(("cooldown %ds left"):format(cooldown),
            ("Next full scan available in %d:%02d."):format(math.floor(cooldown / 60), cooldown % 60))
    end
    -- A full scan covers every reagent, so a running reagent scan is pointless.
    if ns.IsReagentScanning() then
        log.info("Stopping reagent scan: full scan supersedes it")
        ns.StopReagentScan()
    end
    ns.db.ahScanStarted = time()
    scanPending = true
    fullScanStartedAt = GetTime()
    log.info("Full scan requested (%s), ReplicateItems() sent", manual and "manual" or "auto")
    ns.Print("Scanning the Auction House...")
    ns.Progress.Start("Full AH scan")
    ns.Progress.Phase("downloading", 0, "waiting for server")
    C_AuctionHouse.ReplicateItems()
    -- If the server never answers (throttled, AH closed mid-scan), don't stay stuck on "Scanning...".
    ns.After(SCAN_TIMEOUT, "FullScanTimeout", function()
        if scanPending == true then
            scanPending = false
            ns.Progress.Finish("Full scan: no answer from the server")
            log.warn("Full scan timed out after %ds with no REPLICATE_ITEM_LIST_UPDATE", SCAN_TIMEOUT)
            ns.Print("The AH didn't return scan data. Try again later with /vp scan.")
            ns.Refresh()
        end
    end)
    ns.Refresh()
end

-- Average unit price of the cheapest `depth` units, so one cheap listing doesn't fake a margin.
local function DepthPrice(listings, depth)
    table.sort(listings, function(a, b) return a[1] < b[1] end)
    local taken, total = 0, 0
    for _, listing in ipairs(listings) do
        local take = math.min(listing[2], depth - taken)
        total = total + listing[1] * take
        taken = taken + take
        if taken >= depth then break end
    end
    -- Fewer units listed than `depth`: average what exists.
    return total / taken, listings[1][1], taken
end

local function ProcessReplicate()
    local total = C_AuctionHouse.GetNumReplicateItems() or 0
    local listingsByItem = {}
    local index = 0   -- replicate indices are 0-based
    local skipped = 0
    local dataAt = GetTime()
    log.info("Full scan data arrived after %.1fs: %d listings, processing in chunks of %d",
        dataAt - fullScanStartedAt, total, CHUNK)
    ns.Progress.Phase("processing listings", total)

    local function finish()
        local depth = math.max(ns.db.settings.ahDepth or 20, 1)
        local prices, mins, supply, listed = {}, {}, {}, {}
        for itemID, listings in pairs(listingsByItem) do
            prices[itemID], mins[itemID], supply[itemID] = DepthPrice(listings, depth)
            local units = 0
            for _, listing in ipairs(listings) do units = units + listing[2] end
            listed[itemID] = units
        end
        local oldCount = ns.CountKeys(ns.db.ah)
        ns.db.ah, ns.db.ahMin, ns.db.ahSupply, ns.db.ahListed = prices, mins, supply, listed
        ns.db.ahQuick = {}   -- full scan prices are real depth prices
        ns.db.ahScanTime = time()
        scanPending = false
        local itemCount = ns.CountKeys(prices)
        local seconds = math.floor(GetTime() - fullScanStartedAt + 0.5)
        log.info("Full scan finished: %d listings (%d skipped: no buyout/count/itemID), %d items priced (was %d), depth %d, processing %.1fs, total %.1fs",
            total, skipped, itemCount, oldCount, depth, GetTime() - dataAt, GetTime() - fullScanStartedAt)
        ns.Progress.Finish(("Full scan done in %s: %d items priced"):format(ns.Progress.FormatDuration(seconds), itemCount))
        ns.Print("Full AH scan done in %ds: %d listings, %d items priced.", seconds, total, itemCount)
        ns.Refresh()
    end

    local function step()
        local last = math.min(index + CHUNK, total)
        for i = index, last - 1 do
            local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = C_AuctionHouse.GetReplicateItemInfo(i)
            if itemID and buyout and buyout > 0 and count and count > 0 then
                local list = listingsByItem[itemID]
                if not list then
                    list = {}
                    listingsByItem[itemID] = list
                end
                list[#list + 1] = { buyout / count, count }
            else
                skipped = skipped + 1
            end
        end
        index = last
        ns.Progress.Update(index, total)
        if index < total then
            ns.After(0, "FullScanChunk", step)
        else
            finish()
        end
    end
    step()
end

ns.On("REPLICATE_ITEM_LIST_UPDATE", function()
    if not scanPending then
        log.debug("REPLICATE_ITEM_LIST_UPDATE ignored: no scan of ours pending")
        return
    end
    if scanPending == "processing" then
        log.debug("REPLICATE_ITEM_LIST_UPDATE ignored: already processing")
        return
    end
    scanPending = "processing"
    ProcessReplicate()
end)

function ns.IsAHScanning() return scanPending ~= false end

---------------------------------------------------------------------------
-- Reagent scan, two passes:
--   1. Quick pass: batch "browse" searches (many items per request) give each
--      reagent's cheapest price and total quantity listed.
--   2. Detail pass: per-item searches (slow, rate-limited) for the depth price,
--      only for AH-bought reagents of recipes still profitable at the cheapest
--      prices. The depth price is never below the cheapest price, so a recipe
--      that loses money at minimum prices can be skipped safely.
-- Falls back to the detail pass for every reagent if batch search is missing.
---------------------------------------------------------------------------
local ITEM_TIMEOUT = 5           -- seconds to wait for one item's detail results
local BATCH_TIMEOUT = 10         -- seconds to wait for one quick-pass batch
local BATCH_SIZE = 50            -- item keys per quick-pass request
local AUTO_REAGENT_AGE = 10 * 60 -- auto reagent scan only if prices are older than this

local PRICE_SORT = (Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price) or 0
local SORTS = { { sortOrder = PRICE_SORT, reverseSort = false } }

local reagentScan = nil

-- Unique reagent itemIDs across all recorded professions (respects the "Learned only" filter).
function ns.NeededReagents()
    local seen, list = {}, {}
    local learnedOnly = ns.db.settings.learnedOnly
    for _, prof in pairs(ns.char.professions) do
        for _, recipe in pairs(prof.recipes) do
            if recipe.learned or not learnedOnly then
                for _, slot in ipairs(recipe.reagents) do
                    for _, id in ipairs(slot.ids) do
                        if not seen[id] then
                            seen[id] = true
                            list[#list + 1] = id
                        end
                    end
                end
            end
        end
    end
    table.sort(list)
    return list
end

-- Everything the quick pass should price: reagents, plus crafted outputs (AH module) and
-- recorded vendor items (flips module). Returns the sorted list and per-category counts.
function ns.ScanTargets()
    local seen, list = {}, {}
    local counts = { reagents = 0, outputs = 0, vendor = 0 }
    local function add(id, kind)
        if not seen[id] then
            seen[id] = true
            list[#list + 1] = id
            counts[kind] = counts[kind] + 1
        end
    end
    for _, id in ipairs(ns.NeededReagents()) do add(id, "reagents") end
    local modules, learnedOnly = ns.db.settings.modules, ns.db.settings.learnedOnly
    if modules.ah then
        for _, prof in pairs(ns.char.professions) do
            for _, recipe in pairs(prof.recipes) do
                if recipe.learned or not learnedOnly then add(recipe.output, "outputs") end
            end
        end
    end
    if modules.flips then
        for id in pairs(ns.db.vendor) do add(id, "vendor") end
    end
    table.sort(list)
    return list, counts
end

local function Depth() return math.max(ns.db.settings.ahDepth or 20, 1) end

-- Wait for the server's search rate limit, then run fn. Returns seconds waited via callback arg.
local function WhenThrottleReady(label, fn)
    local waitStart = GetTime()
    local function try()
        if not reagentScan then return end
        if not ns.ahOpen then return ns.FinishReagentScan(true, "AH closed") end
        if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
            ns.After(0.1, label, try)
            return
        end
        fn(GetTime() - waitStart)
    end
    try()
end

function ns.FinishReagentScan(stopped, reason)
    local scan = reagentScan
    if not scan then return end
    reagentScan = nil
    local seconds = GetTime() - scan.started
    log.info("Item scan %s%s after %.1fs | quick pass: %d items in %d batches, %d listed, %d not listed, %d batch timeouts (%.1fs) | detail pass: %d/%d items, %d listed, %d not listed, %d timeouts (%.1fs)",
        stopped and "stopped" or "finished", reason and (" (" .. reason .. ")") or "", seconds,
        #scan.all, scan.batchIndex, scan.quickFound, scan.quickEmpty, scan.batchTimeouts, scan.quickSeconds or 0,
        math.max((scan.index or 1) - 1, 0), #(scan.detail or {}), scan.found, scan.empty, scan.timeouts,
        scan.detailStarted and (GetTime() - scan.detailStarted) or 0)
    local secondsText = ns.Progress.FormatDuration(seconds)
    if stopped then
        ns.Progress.Finish("Item scan stopped" .. (reason and (" (" .. reason .. ")") or ""))
        ns.Print("Item scan stopped%s.", reason and (" (" .. reason .. ")") or "")
    else
        ns.db.ahReagentScanTime = time()
        ns.Progress.Finish(("Item scan done in %s"):format(secondsText))
        ns.Print("Item scan done in %s: %d items checked, %d listed on the AH, %d detail-checked.",
            secondsText, #scan.all, scan.quickFound + (scan.quickUsed and 0 or scan.found), #(scan.detail or {}))
        if scan.batchTimeouts > 0 or scan.timeouts > 0 then
            ns.Print("|cffffb040Warning:|r %d batch(es) and %d item(s) got no answer from the AH; those kept their old prices. /vp log has details.",
                scan.batchTimeouts, scan.timeouts)
        end
    end
    ns.Refresh()
end

---------------------------------------------------------------------------
-- Pass 2: detail (per item)
---------------------------------------------------------------------------
local NextDetail

local function ApplyListings(itemID, listings, kind)
    local db, scan = ns.db, reagentScan
    local elapsed = GetTime() - scan.sentAt
    local old = db.ah[itemID]
    if #listings == 0 then
        -- Searched and nothing listed: drop the old price rather than trust a stale one.
        ClearAHPrice(itemID)
        scan.empty = scan.empty + 1
        log.debug("Detail %d/%d %s: %s, no listings after %.2fs%s", scan.index, #scan.detail, ItemLabel(itemID),
            kind, elapsed, old and (" (dropped old price %.2fc)"):format(old) or "")
    else
        db.ah[itemID], db.ahMin[itemID], db.ahSupply[itemID] = DepthPrice(listings, Depth())
        db.ahQuick[itemID] = nil
        local units = 0
        for _, listing in ipairs(listings) do units = units + listing[2] end
        db.ahListed[itemID] = units
        scan.found = scan.found + 1
        log.debug("Detail %d/%d %s: %s, %d listings, depth price %.2fc (min %.2fc, %d units counted, was %s) in %.2fs",
            scan.index, #scan.detail, ItemLabel(itemID), kind, #listings, db.ah[itemID], db.ahMin[itemID],
            db.ahSupply[itemID], old and ("%.2fc"):format(old) or "none", elapsed)
    end
    scan.token = nil
    ns.Progress.Update(scan.index, #scan.detail)
    ns.After(0, "NextDetail", NextDetail)   -- leave the event handler before sending the next query
end

local function SendDetail()
    local scan = reagentScan
    local itemID = scan.current
    WhenThrottleReady("DetailThrottleWait", function(waited)
        local token = {}
        scan.token = token
        scan.sentAt = GetTime()
        scan.key = C_AuctionHouse.MakeItemKey(itemID)
        log.debug("Detail %d/%d %s: query sent (throttle wait %.2fs)", scan.index, #scan.detail, ItemLabel(itemID), waited)
        C_AuctionHouse.SendSearchQuery(scan.key, SORTS, true)
        -- No answer in time: keep whatever price we had and move on.
        ns.After(ITEM_TIMEOUT, "DetailTimeout", function()
            if reagentScan and reagentScan.token == token then
                reagentScan.token = nil
                reagentScan.timeouts = reagentScan.timeouts + 1
                log.warn("Detail %d/%d %s: no results within %ds, keeping price (%s)", reagentScan.index,
                    #reagentScan.detail, ItemLabel(itemID), ITEM_TIMEOUT,
                    ns.db.ah[itemID] and ("%.2fc"):format(ns.db.ah[itemID]) or "none")
                ns.Progress.Update(reagentScan.index, #reagentScan.detail)
                NextDetail()
            end
        end)
    end)
end

NextDetail = function()
    local scan = reagentScan
    if not scan then return end
    scan.index = scan.index + 1
    scan.current = scan.detail[scan.index]
    if not scan.current then
        ns.FinishReagentScan(false)
        return
    end
    ns.Refresh()
    SendDetail()
end

-- Would this recipe still make money (or is its value unknown) at quick-pass minimum reagent prices?
local function IsCandidate(result)
    return result.complete and (result.sell == nil or (result.profit and result.profit > 0))
end

-- AH-bought reagents of recipes still profitable (or of unknown value) at quick-pass minimum prices,
-- selling to a vendor or (AH module) on the AH.
local function BuildDetailQueue()
    local seen, list, recipes = {}, {}, 0
    local learnedOnly = ns.db.settings.learnedOnly
    local ahModule = ns.db.settings.modules.ah
    for _, prof in pairs(ns.char.professions) do
        for _, recipe in pairs(prof.recipes) do
            if recipe.learned or not learnedOnly then
                local result = ns.Evaluate(recipe, "vendor")
                local candidate = IsCandidate(result)
                if not candidate and ahModule then
                    local ahResult = ns.Evaluate(recipe, "ah")
                    if ahResult.complete and ahResult.profit and ahResult.profit > 0 then candidate = true end
                end
                if candidate then
                    recipes = recipes + 1
                    for _, part in ipairs(result.parts) do
                        if part.source == "AH" and ns.db.ahQuick[part.itemID] and not seen[part.itemID] then
                            seen[part.itemID] = true
                            list[#list + 1] = part.itemID
                        end
                    end
                end
            end
        end
    end
    table.sort(list)
    return list, recipes
end

local function StartDetailPass(queue, why)
    local scan = reagentScan
    scan.detail, scan.index, scan.detailStarted = queue, 0, GetTime()
    log.info("Detail pass: %d reagents (%s)", #queue, why)
    if #queue == 0 then
        ns.FinishReagentScan(false)
        return
    end
    ns.Progress.Phase("detail prices", #queue)
    NextDetail()
end

---------------------------------------------------------------------------
-- Pass 1: quick (batched browse search)
---------------------------------------------------------------------------
local SendBatch

local function FinishBatch(timedOut)
    local scan = reagentScan
    local batch = scan.batches[scan.batchIndex]
    local db = ns.db
    local found, empty = 0, 0
    for _, itemID in ipairs(batch) do
        local r = scan.batchResults[itemID]
        if r then
            found = found + 1
            db.ah[itemID], db.ahMin[itemID], db.ahSupply[itemID] = r.minPrice, r.minPrice, r.quantity
            db.ahListed[itemID] = r.quantity
            db.ahQuick[itemID] = true   -- cheapest price only until the detail pass refines it
        elseif not timedOut then
            empty = empty + 1
            ClearAHPrice(itemID)
        end
    end
    scan.quickFound, scan.quickEmpty = scan.quickFound + found, scan.quickEmpty + empty
    if timedOut then scan.batchTimeouts = scan.batchTimeouts + 1 end
    log.info("Quick batch %d/%d: %d items, %d listed, %d not listed%s in %.2fs (%d result pages)", scan.batchIndex,
        #scan.batches, #batch, found, empty, timedOut and ", TIMED OUT (unanswered items keep old prices)" or "",
        GetTime() - scan.sentAt, scan.pages)
    scan.batchToken = nil
    local done = math.min(scan.batchIndex * BATCH_SIZE, #scan.all)
    ns.Progress.Update(done, #scan.all)

    if scan.batchIndex < #scan.batches then
        ns.After(0, "NextBatch", SendBatch)
    else
        scan.quickSeconds = GetTime() - scan.started
        local queue, recipes = BuildDetailQueue()
        StartDetailPass(queue, ("%d recipes profitable or unknown at cheapest prices"):format(recipes))
    end
end

local function ReadBrowseResults()
    local scan = reagentScan
    local results = C_AuctionHouse.GetBrowseResults() or {}
    for _, r in ipairs(results) do
        local itemID = r.itemKey and r.itemKey.itemID
        if itemID and scan.batchSet[itemID] and r.minPrice and r.minPrice > 0 then
            local prev = scan.batchResults[itemID]
            -- Same item can appear under several keys (item levels); keep the cheapest, sum quantity.
            if prev then
                prev.minPrice = math.min(prev.minPrice, r.minPrice)
                prev.quantity = prev.quantity + (r.totalQuantity or 0)
            else
                scan.batchResults[itemID] = { minPrice = r.minPrice, quantity = r.totalQuantity or 0 }
            end
        end
    end
    scan.pages = scan.pages + 1
    if C_AuctionHouse.HasFullBrowseResults and not C_AuctionHouse.HasFullBrowseResults() then
        log.debug("Quick batch %d: page %d read (%d results so far), requesting more", scan.batchIndex, scan.pages, #results)
        C_AuctionHouse.RequestMoreBrowseResults()
    else
        FinishBatch(false)
    end
end

SendBatch = function()
    local scan = reagentScan
    if not scan then return end
    scan.batchIndex = scan.batchIndex + 1
    local batch = scan.batches[scan.batchIndex]
    WhenThrottleReady("BatchThrottleWait", function(waited)
        local keys, set = {}, {}
        for _, itemID in ipairs(batch) do
            keys[#keys + 1] = C_AuctionHouse.MakeItemKey(itemID)
            set[itemID] = true
        end
        local token = {}
        scan.batchToken, scan.batchSet, scan.batchResults, scan.pages = token, set, {}, 0
        scan.sentAt = GetTime()
        log.debug("Quick batch %d/%d: %d item keys sent (throttle wait %.2fs)", scan.batchIndex, #scan.batches, #keys, waited)
        C_AuctionHouse.SearchForItemKeys(keys, SORTS)
        ns.After(BATCH_TIMEOUT, "BatchTimeout", function()
            if reagentScan and reagentScan.batchToken == token then
                log.warn("Quick batch %d/%d: no complete results within %ds", reagentScan.batchIndex, #reagentScan.batches, BATCH_TIMEOUT)
                FinishBatch(true)
            end
        end)
    end)
end

local function OnBrowseResults(event)
    if not (reagentScan and reagentScan.batchToken) then return end
    ReadBrowseResults()
end
ns.On("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", OnBrowseResults)
ns.On("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", OnBrowseResults)

---------------------------------------------------------------------------
-- Start / stop / status
---------------------------------------------------------------------------
function ns.StartReagentScan(manual)
    local function refuse(reason, chat)
        log.info("Reagent scan not started (%s): %s", manual and "manual" or "auto", reason)
        if manual and chat then ns.Print(chat) end
    end
    local AH = C_AuctionHouse
    if not (AH and AH.SendSearchQuery and AH.MakeItemKey) then
        return refuse("SendSearchQuery/MakeItemKey missing", "This client has no AH item search API.")
    end
    if reagentScan then
        if manual then ns.FinishReagentScan(true, "stopped by you") end   -- clicking again stops it
        return
    end
    if not ns.ahOpen then
        return refuse("AH not open", "Open the Auction House first.")
    end
    if scanPending then
        return refuse("full scan running", "A full scan is running; it already covers every reagent.")
    end
    local reagents = ns.NeededReagents()
    local canBatch = AH.SearchForItemKeys and AH.GetBrowseResults and true or false
    local all, counts = reagents, { reagents = #reagents, outputs = 0, vendor = 0 }
    if canBatch then
        -- The quick pass is cheap, so it also covers crafted outputs (AH module) and vendor items (flips).
        all, counts = ns.ScanTargets()
    end
    if #all == 0 then
        return refuse("nothing to scan (no recipes or vendor items recorded)",
            "Nothing to scan yet. Open your profession windows or visit vendors first.")
    end

    reagentScan = {
        all = all, started = GetTime(), quickUsed = canBatch,
        batches = {}, batchIndex = 0, quickFound = 0, quickEmpty = 0, batchTimeouts = 0,
        index = 0, found = 0, empty = 0, timeouts = 0,
    }
    log.info("Item scan started (%s): %d items (%d reagents, %d crafted outputs, %d vendor items), learnedOnly=%s, depth %d, quick pass %s",
        manual and "manual" or "auto", #all, counts.reagents, counts.outputs, counts.vendor,
        tostring(ns.db.settings.learnedOnly), Depth(),
        canBatch and "available" or "UNAVAILABLE (SearchForItemKeys missing), detail-checking reagents only")
    ns.Print("Scanning %d items (%d reagents, %d crafted items, %d vendor items)...",
        #all, counts.reagents, counts.outputs, counts.vendor)
    ns.Progress.Start("Item scan")

    if canBatch then
        for i = 1, #all, BATCH_SIZE do
            local batch = {}
            for j = i, math.min(i + BATCH_SIZE - 1, #all) do batch[#batch + 1] = all[j] end
            reagentScan.batches[#reagentScan.batches + 1] = batch
        end
        ns.Progress.Phase("quick prices", #all)
        SendBatch()
    else
        StartDetailPass(all, "no batch search on this client")
    end
end

function ns.IsReagentScanning() return reagentScan ~= nil end

function ns.StopReagentScan()
    if reagentScan then ns.FinishReagentScan(true, "superseded by full scan") end
end

-- For the window's button: done, total, phase label.
function ns.ReagentScanProgress()
    local scan = reagentScan
    if not scan then return nil end
    if scan.detail then return math.max(scan.index - 1, 0), #scan.detail, "detail" end
    return math.min(math.max(scan.batchIndex - 1, 0) * BATCH_SIZE, #scan.all), #scan.all, "quick"
end

-- Button label + enabled state, shared by the main window and the AH panel so they always agree.
function ns.FullScanButtonState()
    if ns.IsAHScanning() then return "Scanning...", false end
    if not ns.ahOpen then return "Full scan", false end
    local cooldown = ns.AHScanCooldown()
    if cooldown > 0 then
        return ("Full scan (%d:%02d)"):format(math.floor(cooldown / 60), cooldown % 60), false
    end
    return "Full scan", true
end

function ns.ItemScanButtonState()
    local done, total, phase = ns.ReagentScanProgress()
    if done then return ("Stop %s %d/%d"):format(phase == "quick" and "Q" or "D", done, total), true end
    return "Scan items", ns.ahOpen and not ns.IsAHScanning()
end

ns.On("COMMODITY_SEARCH_RESULTS_UPDATED", function(_, itemID)
    if not (reagentScan and reagentScan.token and itemID == reagentScan.current) then return end
    local listings = {}
    for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0 do
        local info = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
        if info and info.unitPrice and info.quantity and info.quantity > 0 then
            listings[#listings + 1] = { info.unitPrice, info.quantity }
        end
    end
    ApplyListings(itemID, listings, "commodity")
end)

ns.On("ITEM_SEARCH_RESULTS_UPDATED", function(_, itemKey)
    if not (reagentScan and reagentScan.token and itemKey and itemKey.itemID == reagentScan.current) then return end
    local listings = {}
    for i = 1, C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0 do
        local info = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        local quantity = info and info.quantity or 0
        if info and info.buyoutAmount and quantity > 0 then
            listings[#listings + 1] = { info.buyoutAmount / quantity, quantity }
        end
    end
    ApplyListings(itemKey.itemID, listings, "item")
end)

---------------------------------------------------------------------------
-- Auto scan on opening the AH: full scan if allowed (fastest, covers
-- everything), otherwise the reagent scan if prices are getting old.
---------------------------------------------------------------------------
ns.On("AUCTION_HOUSE_SHOW", function()
    ns.ahOpen = true
    local cooldown = ns.AHScanCooldown()
    local newest = math.max(ns.db.ahScanTime or 0, ns.db.ahReagentScanTime or 0)
    local age = newest > 0 and (time() - newest) or nil
    log.info("AH opened: autoScan=%s, full scan cooldown %ds, newest prices %s",
        tostring(ns.db.settings.autoScanAH), cooldown, age and (age .. "s old") or "never")
    if ns.db.settings.autoScanAH then
        if cooldown == 0 then
            log.info("Auto-scan decision: full scan (off cooldown)")
            ns.StartAHScan(false)
        elseif age == nil or age > AUTO_REAGENT_AGE then
            log.info("Auto-scan decision: reagent scan (full scan on cooldown, prices older than %ds)", AUTO_REAGENT_AGE)
            ns.StartReagentScan(false)
        else
            log.info("Auto-scan decision: none (prices fresh enough)")
        end
    end
    ns.Refresh()
end)

ns.On("AUCTION_HOUSE_CLOSED", function()
    ns.ahOpen = false
    log.info("AH closed")
    if reagentScan then ns.FinishReagentScan(true, "AH closed") end
    ns.Refresh()
end)
