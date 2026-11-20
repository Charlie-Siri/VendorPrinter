-- Core: namespace, saved variables, event dispatch, shared helpers, slash commands.
local addonName, ns = ...

ns.name = addonName
local log = ns.Logger("Core")

local DB_DEFAULTS = {
    version = 1,
    vendor = {},        -- [itemID] = lowest seen vendor price per unit (copper)
    vendorLimited = {}, -- [itemID] = true when the vendor only has limited stock
    vendorSource = {},  -- [itemID] = { npc, zone } of the cheapest vendor seen (for flips)
    ah = {},            -- [itemID] = avg unit price of the cheapest `ahDepth` units in the last scan (copper)
    ahMin = {},         -- [itemID] = cheapest single unit price in the last scan
    ahSupply = {},      -- [itemID] = units counted into the depth price (< ahDepth means thin supply)
    ahQuick = {},       -- [itemID] = true while the AH price is only the cheapest listing (quick pass)
    ahListed = {},      -- [itemID] = total units listed on the AH (competition when selling)
    ahScanTime = nil,   -- time() when the last full AH scan finished
    ahReagentScanTime = nil, -- time() when the last reagent-only scan finished
    ahScanStarted = 0,  -- time() when the last AH scan was requested (15 min server throttle)
    settings = {
        learnedOnly = false,
        showIncomplete = true,
        autoScanAH = true,
        ahDepth = 20,   -- units averaged for the AH price
        crafts = 10,    -- crafts used for shopping lists
        search = "",
        progressChat = "milestones", -- chat progress for long scans: milestones (every 10%), all, off
        tooltip = true, -- add prices and recipe usage to item tooltips
        tab = "vendor", -- window view: vendor (craft -> vendor), ah (craft -> AH), flips (vendor -> AH)
        merchantAlert = true, -- highlight + panel + chat line at vendors selling AH flips
        merchantSound = true, -- coin sound with the merchant alert
        flipMinProfit = 100,  -- copper per unit a flip must make to trigger the merchant alert
        flipMinROI = 0.10,    -- and profit / vendor price at least this
        ahPanel = true,       -- scan buttons docked to the AH window
        modules = {
            ah = true,    -- craft -> sell on AH: tab, output prices in scans, tooltip line
            flips = true, -- buy from vendor -> sell on AH: tab, vendor items in scans, tooltip line
        },
    },
}

local CHAR_DEFAULTS = {
    professions = {},   -- [professionName] = { scanned = time(), recipes = { [recipeID] = {...} } }
}

local function ApplyDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if target[k] == nil then
            if type(v) == "table" then
                target[k] = {}
                ApplyDefaults(target[k], v)
            else
                target[k] = v
            end
        elseif type(v) == "table" and type(target[k]) == "table" then
            ApplyDefaults(target[k], v)
        end
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local handlers = {}
-- Events too frequent to log each time (their handlers log what matters).
local QUIET_EVENTS = {
    GET_ITEM_INFO_RECEIVED = true,
    COMMODITY_SEARCH_RESULTS_UPDATED = true,
    ITEM_SEARCH_RESULTS_UPDATED = true,
    AUCTION_HOUSE_BROWSE_RESULTS_UPDATED = true,
    AUCTION_HOUSE_BROWSE_RESULTS_ADDED = true,
}

-- Register a handler. Unknown events (API differences between clients) are logged and skipped instead of erroring.
function ns.On(event, fn)
    if not handlers[event] then
        local ok, err = pcall(eventFrame.RegisterEvent, eventFrame, event)
        if not ok then
            log.warn("Event %s not available on this client, handler skipped: %s", event, err)
            return false
        end
        handlers[event] = {}
    end
    table.insert(handlers[event], fn)
    return true
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then return end
    if not QUIET_EVENTS[event] then
        log.debug("Event %s (%s, %s)", event, tostring((...)), tostring((select(2, ...))))
    end
    for i = 1, #list do
        ns.SafeCall("Event:" .. event, list[i], event, ...)
    end
end)

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function StripColors(text)
    return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- Chat message for the user; also recorded in the log.
function ns.Print(msg, ...)
    if select("#", ...) > 0 then msg = msg:format(...) end
    print("|cff33ff99Vendor Printer|r: " .. msg)
    log.info("Chat: %s", StripColors(msg))
end

local timers = {}
-- Run fn once after `delay` seconds of quiet; repeated calls restart the wait.
function ns.Debounce(key, delay, fn)
    if timers[key] then timers[key]:Cancel() end
    timers[key] = C_Timer.NewTimer(delay, function()
        timers[key] = nil
        ns.SafeCall("Debounce:" .. key, fn)
    end)
end

-- C_Timer.After with errors logged.
function ns.After(delay, label, fn)
    C_Timer.After(delay, function() ns.SafeCall(label, fn) end)
end

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local RequestItem = C_Item and C_Item.RequestLoadItemDataByID
local requested = {}

local function Request(itemID)
    if not requested[itemID] then
        requested[itemID] = true
        log.debug("Item %d not cached, requesting item data", itemID)
    end
    if RequestItem then RequestItem(itemID) end
end

-- Vendor sell price per unit, or nil while the item isn't cached yet.
function ns.GetSellPrice(itemID)
    local sell = select(11, GetItemInfo(itemID))
    if sell == nil then Request(itemID) end
    return sell
end

-- Colored item link (or a placeholder while loading).
function ns.GetItemLink(itemID)
    local name, link = GetItemInfo(itemID)
    if not name then
        Request(itemID)
        return "|cff888888item " .. itemID .. "|r"
    end
    return link or name
end

function ns.Money(copper)
    if copper == nil then return "|cff888888?|r" end
    local negative = copper < 0
    copper = math.floor(math.abs(copper) + 0.5)
    local text
    if GetMoneyString then
        text = GetMoneyString(copper, true)
    else
        text = ("%dg %ds %dc"):format(math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100)
    end
    if negative then text = "|cffff5050-|r" .. text end
    return text
end

function ns.CountKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Called whenever data changes; UI.lua replaces this.
function ns.Refresh() end

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------
local function AddonVersion()
    local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    return getMeta and getMeta(addonName, "Version") or "?"
end

ns.On("ADDON_LOADED", function(_, loaded)
    if loaded ~= addonName then return end
    ns.InitLog()
    VendorPrinterDB = VendorPrinterDB or {}
    VendorPrinterCharDB = VendorPrinterCharDB or {}
    ApplyDefaults(VendorPrinterDB, DB_DEFAULTS)
    ApplyDefaults(VendorPrinterCharDB, CHAR_DEFAULTS)
    ns.db = VendorPrinterDB
    ns.char = VendorPrinterCharDB

    local version, build, _, interface = GetBuildInfo()
    local recipes = 0
    for _, prof in pairs(ns.char.professions) do recipes = recipes + ns.CountKeys(prof.recipes) end
    log.info("==================== session start ====================")
    log.info("VendorPrinter %s | client %s build %s interface %s | character %s",
        AddonVersion(), tostring(version), tostring(build), tostring(interface), tostring(UnitName("player")))
    log.info("Loaded data: %d recipes in %d professions, %d vendor prices, %d AH prices (full scan %s, reagents %s)",
        recipes, ns.CountKeys(ns.char.professions), ns.CountKeys(ns.db.vendor), ns.CountKeys(ns.db.ah),
        ns.db.ahScanTime and date("%Y-%m-%d %H:%M", ns.db.ahScanTime) or "never",
        ns.db.ahReagentScanTime and date("%Y-%m-%d %H:%M", ns.db.ahReagentScanTime) or "never")
    local s = ns.db.settings
    log.info("Settings: learnedOnly=%s showIncomplete=%s autoScanAH=%s ahDepth=%s crafts=%s search=%q tab=%s modules: ah=%s flips=%s tooltip=%s",
        tostring(s.learnedOnly), tostring(s.showIncomplete), tostring(s.autoScanAH), tostring(s.ahDepth),
        tostring(s.crafts), tostring(s.search), tostring(s.tab), tostring(s.modules.ah), tostring(s.modules.flips),
        tostring(s.tooltip))
end)

ns.On("PLAYER_LOGOUT", function()
    log.info("Logout/reload: saving data")
end)

-- Item data arrives asynchronously; refresh once a burst of loads settles.
ns.On("GET_ITEM_INFO_RECEIVED", function()
    ns.Debounce("itemInfo", 0.3, function() ns.Refresh() end)
end)

---------------------------------------------------------------------------
-- Debug: first-run check on a client whose API isn't fully known yet
---------------------------------------------------------------------------
-- "A|B" means either one is enough (the addon falls back from A to B).
local API_CHECKS = {
    "C_TradeSkillUI.GetAllRecipeIDs", "C_TradeSkillUI.GetRecipeInfo", "C_TradeSkillUI.GetRecipeSchematic",
    "C_TradeSkillUI.GetBaseProfessionInfo", "C_TradeSkillUI.GetRecipeSourceText", "C_TradeSkillUI.IsTradeSkillReady",
    "C_AuctionHouse.ReplicateItems", "C_AuctionHouse.GetNumReplicateItems", "C_AuctionHouse.GetReplicateItemInfo",
    "C_AuctionHouse.SendSearchQuery", "C_AuctionHouse.MakeItemKey", "C_AuctionHouse.IsThrottledMessageSystemReady",
    "C_AuctionHouse.SearchForItemKeys", "C_AuctionHouse.GetBrowseResults", "C_AuctionHouse.HasFullBrowseResults",
    "C_AuctionHouse.RequestMoreBrowseResults",
    "C_AuctionHouse.GetNumCommoditySearchResults", "C_AuctionHouse.GetCommoditySearchResultInfo",
    "C_AuctionHouse.GetNumItemSearchResults", "C_AuctionHouse.GetItemSearchResultInfo",
    "C_MerchantFrame.GetItemInfo|GetMerchantItemInfo", "GetMerchantItemID",
    "C_Item.GetItemInfo|GetItemInfo", "C_Item.RequestLoadItemDataByID", "GetMoneyString",
    "TooltipDataProcessor.AddTooltipPostCall|GameTooltip.HookScript",
    "MerchantFrame_UpdateMerchantInfo", "C_Item.GetItemIconByID",
    -- Earnings ledger
    "BuyMerchantItem", "C_Container.UseContainerItem", "C_AuctionHouse.StartCommoditiesPurchase",
    "C_AuctionHouse.PlaceBid", "TakeInboxMoney", "AutoLootMailItem", "GetInboxHeaderInfo", "GetInboxInvoiceInfo",
}

local function Resolve(path)
    local value = _G
    for part in path:gmatch("[^%.]+") do
        if type(value) ~= "table" then return nil end
        value = value[part]
    end
    return value
end

function ns.PrintDebug()
    local version, build, _, interface = GetBuildInfo()
    ns.Print("Client %s (build %s), interface %s. TOC says %s.",
        tostring(version), tostring(build), tostring(interface),
        tostring(C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addonName, "Interface") or "?"))
    local missing = {}
    for _, check in ipairs(API_CHECKS) do
        local found = false
        for path in check:gmatch("[^|]+") do
            if type(Resolve(path)) == "function" then found = true break end
        end
        if not found then missing[#missing + 1] = check end
    end
    if #missing == 0 then
        ns.Print("All %d APIs used by the addon are present.", #API_CHECKS)
    else
        ns.Print("Missing APIs: %s", table.concat(missing, ", "))
    end
    local recipes = 0
    for _, prof in pairs(ns.char.professions) do recipes = recipes + ns.CountKeys(prof.recipes) end
    ns.Print("Data: %d recipes, %d vendor prices, %d AH prices.", recipes, ns.CountKeys(ns.db.vendor), ns.CountKeys(ns.db.ah))
    local lines, level = ns.LogStats()
    ns.Print("Log: %d lines, level %s. /reload saves it to disk.", lines, level)
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_VENDORPRINTER1 = "/vp"
SLASH_VENDORPRINTER2 = "/vendorprinter"
SlashCmdList.VENDORPRINTER = function(input)
    local cmd = strtrim(input or ""):lower()
    log.info("Slash command: /vp %s", cmd)
    if cmd:match("^log") then
        ns.LogCommand(cmd:match("^log%s*(.*)$"))
    elseif cmd == "" then
        ns.ToggleWindow()
    elseif cmd == "scan" then
        ns.StartAHScan(true)
    elseif cmd == "reagents" then
        ns.StartReagentScan(true)
    elseif cmd == "report" or cmd == "earnings" then
        ns.ToggleReport()
    elseif cmd == "debug" then
        ns.PrintDebug()
    elseif cmd:match("^module") then
        local name, state = cmd:match("^module%s+(%a+)%s*(%a*)")
        local modules = ns.db.settings.modules
        if name == "ah" or name == "flips" then
            if state == "on" then modules[name] = true
            elseif state == "off" then modules[name] = false
            else modules[name] = not modules[name] end
            ns.Print("Module %s: %s.", name == "ah" and "craft -> AH" or "vendor -> AH flips", modules[name] and "on" or "off")
            if not modules[ns.db.settings.tab] and ns.db.settings.tab ~= "vendor" then ns.db.settings.tab = "vendor" end
            ns.Refresh()
        else
            ns.Print("Modules: ah (craft -> AH) %s, flips (vendor -> AH) %s. Toggle with /vp module ah|flips [on|off].",
                modules.ah and "on" or "off", modules.flips and "on" or "off")
        end
    elseif cmd:match("^merchant") then
        local state = cmd:match("^merchant%s+(%a+)")
        local s = ns.db.settings
        if state == "on" then s.merchantAlert = true elseif state == "off" then s.merchantAlert = false
        else s.merchantAlert = not s.merchantAlert end
        ns.Print("Vendor flip alerts: %s.", s.merchantAlert and "on" or "off")
    elseif cmd == "sound" then
        ns.db.settings.merchantSound = not ns.db.settings.merchantSound
        ns.Print("Vendor flip alert sound: %s.", ns.db.settings.merchantSound and "on" or "off")
    elseif cmd:match("^flipmin") then
        local silver, roi = cmd:match("^flipmin%s+([%d%.]+)%s*(%d*)")
        local s = ns.db.settings
        if tonumber(silver) then
            s.flipMinProfit = math.floor(tonumber(silver) * 100 + 0.5)
            if tonumber(roi) then s.flipMinROI = tonumber(roi) / 100 end
        end
        ns.Print("Vendor flip alerts need at least %s profit each and %d%% return. Change: /vp flipmin <silver> [percent].",
            ns.Money(s.flipMinProfit), math.floor(s.flipMinROI * 100 + 0.5))
    elseif cmd == "ahpanel" then
        ns.db.settings.ahPanel = not ns.db.settings.ahPanel
        ns.SetAHPanelShown(ns.db.settings.ahPanel)
        ns.Print("AH scan panel: %s.", ns.db.settings.ahPanel and "on" or "off")
    elseif cmd == "tooltip" then
        ns.db.settings.tooltip = not ns.db.settings.tooltip
        ns.Print("Item tooltip prices: %s.", ns.db.settings.tooltip and "on" or "off")
    elseif cmd:match("^progress") then
        local mode = cmd:match("^progress%s+(%a+)")
        if mode == "milestones" or mode == "all" or mode == "off" then
            ns.db.settings.progressChat = mode
            ns.Print("Chat progress: %s.", mode)
        else
            ns.Print("Chat progress is %s. Use /vp progress milestones|all|off (the on-screen bar always shows).",
                ns.db.settings.progressChat)
        end
    elseif cmd:match("^depth") then
        local n = tonumber(cmd:match("^depth%s+(%d+)"))
        if n and n > 0 then
            ns.db.settings.ahDepth = n
            ns.Print("AH price now averages the cheapest %d units (applies from the next scan).", n)
        else
            ns.Print("AH depth is %d units. Change it with /vp depth <number>.", ns.db.settings.ahDepth)
        end
    elseif cmd == "reset" then
        wipe(ns.db.vendor)
        wipe(ns.db.vendorLimited)
        wipe(ns.db.vendorSource)
        wipe(ns.db.ahListed)
        wipe(ns.db.ah)
        wipe(ns.db.ahMin)
        wipe(ns.db.ahSupply)
        wipe(ns.db.ahQuick)
        ns.db.ahScanTime = nil
        ns.db.ahReagentScanTime = nil
        ns.Print("Vendor and AH prices cleared.")
        ns.Refresh()
    elseif cmd == "forget" then
        wipe(ns.char.professions)
        ns.recipesVersion = (ns.recipesVersion or 0) + 1
        ns.Print("Recipe data for this character cleared. Open your profession windows to rescan.")
        ns.Refresh()
    else
        ns.Print("Commands:")
        print("  /vp - toggle the window")
        print("  /vp scan - full AH scan (AH must be open, once per 15 min)")
        print("  /vp reagents - scan only your recipes' reagents (no cooldown; run again to stop)")
        print("  /vp report - earnings: real profit from what you bought, crafted and sold")
        print("  /vp depth <n> - average the AH price over the cheapest n units (default 20)")
        print("  /vp progress <milestones|all|off> - chat updates during scans (every 10%, every item, none)")
        print("  /vp tooltip - toggle prices on item tooltips")
        print("  /vp module ah|flips [on|off] - craft->AH and vendor->AH flip features")
        print("  /vp merchant [on|off] - vendor flip alerts (highlight, panel, chat); /vp sound - its sound")
        print("  /vp flipmin <silver> [percent] - minimum flip profit/return for alerts (default 1s, 10%)")
        print("  /vp ahpanel - toggle the scan panel next to the AH window")
        print("  /vp debug - show client version and which APIs this addon can use")
        print("  /vp reset - clear all recorded prices")
        print("  /vp forget - clear this character's recipe data")
        print("  /vp log [n] - show the last n log lines (default 20)")
        print("  /vp log level <debug|info|warn|error>, /vp log echo [on|off], /vp log clear")
    end
end
