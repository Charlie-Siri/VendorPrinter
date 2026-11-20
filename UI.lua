-- UI: one movable window with three views (tabs):
--   vendor: craft -> sell to vendor   ah: craft -> sell on AH   flips: buy from vendor -> sell on AH
local _, ns = ...
local log = ns.Logger("UI")

local WIDTH, HEIGHT = 740, 480
local ROW_H = 20
local LIST_TOP = -102
local COL = { nameWidth = 250, costRight = 380, sellRight = 490, profitRight = 600, pctRight = 668, moneyWidth = 108, pctWidth = 62 }

local TABS = {
    { key = "vendor", label = "Vendor", tip = "Craft, then sell to a vendor (the original Vendor Printer view)." },
    { key = "ah", label = "AH sale", tip = "Craft, then sell on the AH at the cheapest listing price, minus the 5% AH cut.", module = "ah" },
    { key = "flips", label = "Flips", tip = "Buy from a vendor, sell on the AH for more (after the 5% cut). Only vendors you've visited.", module = "flips" },
}
local HEADERS = {
    vendor = { "Recipe", "Cost", "Sells for", "Profit", "Profit %" },
    ah = { "Recipe", "Cost", "AH net", "Profit", "Profit %" },
    flips = { "Item", "Vendor price", "AH net", "Profit each", "Profit %" },
}

local frame, scroll, content, statusText, scanButton, reagentButton, emptyText
local headers, tabButtons = {}, {}
local rowPool = {}
local stats = { vendor = 0, ah = 0 }

local function CurrentTab()
    local tab = ns.db.settings.tab or "vendor"
    if tab ~= "vendor" and not ns.db.settings.modules[tab] then tab = "vendor" end
    return tab
end

local function ProfitText(data)
    if data.sell == nil then
        return data.mode == "ah" and "|cff888888no AH price|r" or "|cff888888loading...|r"
    end
    if data.profit == nil then return "|cff888888missing prices|r" end
    if data.profit > 0 then return "|cff40ff40" .. ns.Money(data.profit) .. "|r" end
    return ns.Money(data.profit)
end

-- Profit as a share of the cost: (what it sells for - cost) / cost. On the AH tab "sells for" is the AH price after the cut.
local function PercentText(roi)
    if roi == nil then return "|cff888888-|r" end
    local text = ("%+.0f%%"):format(roi * 100)
    if roi > 0 then return "|cff40ff40" .. text .. "|r" end
    if roi < 0 then return "|cffff6060" .. text .. "|r" end
    return text
end

local function WarningSuffix(warning)
    return warning and (" |cffff8040(" .. warning .. ")|r") or ""
end

local function SourceText(source)
    if not source then return "a vendor" end
    return source.npc .. ((source.zone and source.zone ~= "") and (" (" .. source.zone .. ")") or "")
end

---------------------------------------------------------------------------
-- Click actions (chat output)
---------------------------------------------------------------------------
local SOURCE_LABELS = { Vendor = "Buy from a vendor", AH = "Buy on the Auction House" }

function ns.PrintShoppingList(data)
    local crafts = math.max(ns.db.settings.crafts or 1, 1)
    local list = ns.ShoppingList(data, crafts)
    local valueLabel = data.mode == "ah" and "AH value (after cut)" or "Vendor value"
    log.info("Shopping list [%s]: %dx %q (recipe %d): %d vendor, %d AH, %d unpriced items, cost %.0fc, value %s, profit %s",
        data.mode, crafts, data.recipe.name or "?", data.recipeID or 0, #list.Vendor, #list.AH, #list.Missing, list.cost,
        tostring(list.revenue), tostring(list.profit))
    ns.Print("Shopping list for %dx %s (sell %s):", crafts, data.recipe.name or "?",
        data.mode == "ah" and "on the AH" or "to a vendor")
    for _, source in ipairs({ "Vendor", "AH" }) do
        if #list[source] > 0 then
            print("  |cffffd100" .. SOURCE_LABELS[source] .. ":|r")
            for _, entry in ipairs(list[source]) do
                print(("    %dx %s  %s%s"):format(entry.qty, ns.GetItemLink(entry.itemID),
                    ns.Money(entry.total), WarningSuffix(entry.warning)))
            end
        end
    end
    if #list.Missing > 0 then
        print("  |cffff5050No price yet:|r")
        for _, entry in ipairs(list.Missing) do
            print(("    %dx %s"):format(entry.qty, ns.GetItemLink(entry.itemID)))
        end
    end
    local profit = list.profit and ((list.profit > 0 and "|cff40ff40" or "") .. ns.Money(list.profit) .. "|r") or "?"
    print(("  Cost %s  |  %s %s  |  Profit %s"):format(ns.Money(list.cost), valueLabel, ns.Money(list.revenue), profit))
    if data.mode == "ah" and data.listed then
        print(("  |cff999999%d already listed on the AH: selling may take time.|r"):format(data.listed))
    end
end

function ns.PrintFlip(data)
    local qty = math.max(ns.db.settings.crafts or 1, 1)
    log.info("Flip details: item %d x%d buy %.0fc net %.0fc profit %.0fc listed %s source %s", data.itemID, qty,
        data.buy, data.net, data.profit, tostring(data.listed), SourceText(data.source))
    ns.Print("Flip: %s", ns.GetItemLink(data.itemID))
    print(("  Buy from %s for %s each%s"):format(SourceText(data.source), ns.Money(data.buy),
        data.limited and " |cffff8040(limited stock)|r" or ""))
    print(("  Sell on the AH at %s (cheapest listing%s), you get %s after the 5%% cut"):format(
        ns.Money(ns.db.ahMin[data.itemID]), data.listed and (", %d listed"):format(data.listed) or "", ns.Money(data.net)))
    print(("  Profit %s each, %s for %d  (%+.0f%%)"):format(ns.Money(data.profit), ns.Money(data.profit * qty), qty,
        data.roi * 100))
end

---------------------------------------------------------------------------
-- Row tooltips
---------------------------------------------------------------------------
local function ShowRecipeTooltip(row, data)
    local recipe = data.recipe
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(recipe.name or "?", 1, 1, 1)
    GameTooltip:AddLine(data.profession .. (recipe.learned and "" or "  |cffff8040(not learned)|r"), 0.7, 0.7, 0.7)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Reagents per craft", 1, 0.82, 0)
    for _, part in ipairs(data.parts) do
        local left = ("%dx %s"):format(part.qty, ns.GetItemLink(part.itemID))
        local right
        if part.unit then
            right = ns.Money(part.unit * part.qty) .. " |cff999999(" .. part.source .. ")|r" .. WarningSuffix(part.warning)
        else
            right = "|cffff5050no price|r"
        end
        GameTooltip:AddDoubleLine(left, right, 1, 1, 1, 1, 1, 1)
    end
    GameTooltip:AddLine(" ")
    local qtyText = (recipe.qmin == recipe.qmax) and tostring(recipe.qmin) or ("%d-%d"):format(recipe.qmin, recipe.qmax)
    local eachLabel = data.mode == "ah" and " each on AH (after cut)" or " each"
    GameTooltip:AddDoubleLine(("Output: %sx %s"):format(qtyText, ns.GetItemLink(recipe.output)),
        ns.Money(data.sell) .. eachLabel, 1, 1, 1, 1, 1, 1)
    if data.mode == "ah" and data.listed then
        GameTooltip:AddDoubleLine("Competition", ("%d listed on the AH"):format(data.listed), 1, 0.82, 0, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("Cost", ns.Money(data.complete and data.cost or nil), 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine(data.mode == "ah" and "AH value" or "Vendor value", ns.Money(data.revenue), 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Profit per craft", ProfitText(data), 1, 0.82, 0, 1, 1, 1)
    if data.roi then
        GameTooltip:AddDoubleLine("Profit % (of cost)", ("%+.0f%%"):format(data.roi * 100), 1, 0.82, 0, 1, 1, 1)
    end
    if not recipe.learned and recipe.source then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("How to learn", 1, 0.82, 0)
        GameTooltip:AddLine(recipe.source, 1, 1, 1, true)
    end
    if not data.complete then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Visit a vendor that sells the missing reagents, or scan the AH.", 0.6, 0.6, 0.6, true)
    end
    if data.mode == "ah" then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("AH sales aren't guaranteed: check how many are listed before crafting a lot.", 0.6, 0.6, 0.6, true)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(("Click: open the recipe in your %s window and print a shopping list (%d crafts)"):format(
        data.profession or "profession", ns.db.settings.crafts or 1), 0.5, 0.8, 1, true)
    GameTooltip:Show()
end

local function ShowFlipTooltip(row, data)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    -- The item's own tooltip; Tooltip.lua appends the flip and price lines.
    GameTooltip:SetItemByID(data.itemID)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click to print where to buy and how much it makes", 0.5, 0.8, 1)
    GameTooltip:Show()
end

local function ShowTooltip(row)
    local data = row.data
    if not data then return end
    if row.kind == "flip" then ShowFlipTooltip(row, data) else ShowRecipeTooltip(row, data) end
end

local function MoneyText(parent)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetWidth(COL.moneyWidth)
    fs:SetJustifyH("RIGHT")
    return fs
end

local function GetRow(i)
    local row = rowPool[i]
    if row then return row end

    row = CreateFrame("Button", nil, content)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i - 1) * ROW_H)
    row:SetPoint("RIGHT", content, "RIGHT")
    row:RegisterForClicks("LeftButtonUp")

    if i % 2 == 0 then
        local stripe = row:CreateTexture(nil, "BACKGROUND")
        stripe:SetAllPoints()
        stripe:SetColorTexture(1, 1, 1, 0.03)
    end
    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.10)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.name:SetWidth(COL.nameWidth)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.cost = MoneyText(row)
    row.cost:SetPoint("RIGHT", row, "LEFT", COL.costRight, 0)
    row.sell = MoneyText(row)
    row.sell:SetPoint("RIGHT", row, "LEFT", COL.sellRight, 0)
    row.profit = MoneyText(row)
    row.profit:SetPoint("RIGHT", row, "LEFT", COL.profitRight, 0)
    row.pct = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.pct:SetWidth(COL.pctWidth)
    row.pct:SetJustifyH("RIGHT")
    row.pct:SetPoint("RIGHT", row, "LEFT", COL.pctRight, 0)

    row:SetScript("OnEnter", ShowTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self)
        if not self.data then return end
        if self.kind == "flip" then
            ns.PrintFlip(self.data)
        else
            -- the click is the hardware event the client wants before it opens a profession window
            ns.OpenRecipe(self.data.recipeID, self.data.profession, self.data.recipe.name)
            ns.PrintShoppingList(self.data)
        end
    end)

    rowPool[i] = row
    return row
end

---------------------------------------------------------------------------
-- Updates
---------------------------------------------------------------------------
local function AgoText(t)
    if not t then return "never" end
    local seconds = time() - t
    if seconds < 60 then return "just now" end
    if SecondsToTime then return SecondsToTime(seconds, true) .. " ago" end
    return math.floor(seconds / 60) .. " min ago"
end

-- Cheap: uses cached counts, safe to call every second.
local function UpdateStatus()
    statusText:SetText(("Vendor prices: %d   |   AH prices: %d (full scan %s, item scan %s)"):format(
        stats.vendor, stats.ah, AgoText(ns.db.ahScanTime), AgoText(ns.db.ahReagentScanTime)))

    local text, enabled = ns.FullScanButtonState()
    scanButton:SetText(text)
    scanButton:SetEnabled(enabled)
    text, enabled = ns.ItemScanButtonState()
    reagentButton:SetText(text)
    reagentButton:SetEnabled(enabled)
end

local function UpdateTabs()
    local current = CurrentTab()
    for _, button in ipairs(tabButtons) do
        local tab = button.tab
        local enabled = not tab.module or ns.db.settings.modules[tab.module]
        button:SetEnabled(enabled)
        button:SetText(tab.key == current and ("[" .. tab.label .. "]") or tab.label)
        if tab.key == current then button:LockHighlight() else button:UnlockHighlight() end
    end
    for i, text in ipairs(HEADERS[current]) do headers[i]:SetText(text) end
end

local function RenderRecipeRow(row, data)
    local recipe = data.recipe
    local name = recipe.name or "?"
    if data.mode == "ah" and data.listed then name = name .. (" |cff999999(%d listed)|r"):format(data.listed) end
    if recipe.learned then
        row.name:SetText(name)
    else
        row.name:SetText("|cff9d9d9d" .. (recipe.name or "?") .. " (not learned)|r")
    end
    row.cost:SetText(ns.Money(data.complete and data.cost or nil))
    row.sell:SetText(ns.Money(data.revenue))
    row.profit:SetText(ProfitText(data))
    row.pct:SetText(PercentText(data.roi))
end

local function RenderFlipRow(row, data)
    local name = data.name or ns.GetItemLink(data.itemID)
    local notes = {}
    if data.listed then notes[#notes + 1] = data.listed .. " listed" end
    if data.limited then notes[#notes + 1] = "|cffff8040limited|r" end
    if #notes > 0 then name = name .. " |cff999999(" .. table.concat(notes, ", ") .. ")|r" end
    row.name:SetText(name)
    row.cost:SetText(ns.Money(data.buy))
    row.sell:SetText(ns.Money(data.net))
    row.profit:SetText("|cff40ff40" .. ns.Money(data.profit) .. "|r")
    row.pct:SetText(PercentText(data.roi))
end

local function EmptyMessage(tab)
    if tab == "flips" then
        if next(ns.db.vendor) == nil then return "Visit vendors to record what they sell, then scan the AH." end
        return "No profitable flips with the prices you have. Scan the AH for fresher prices."
    end
    if next(ns.char.professions) == nil then return "Open your profession window to scan your recipes." end
    if tab == "ah" and next(ns.db.ahMin) == nil then return "Scan the AH to price your crafted items." end
    return "No recipes match the current filters."
end

local function UpdateList()
    stats.vendor = ns.CountKeys(ns.db.vendor)
    stats.ah = ns.CountKeys(ns.db.ah)
    UpdateTabs()

    local tab = CurrentTab()
    local rows, kind
    if tab == "flips" then
        rows, kind = ns.BuildFlipRows(), "flip"
    else
        rows, kind = ns.BuildRows(tab), "recipe"
    end
    for i, data in ipairs(rows) do
        local row = GetRow(i)
        row.data, row.kind = data, kind
        if kind == "flip" then RenderFlipRow(row, data) else RenderRecipeRow(row, data) end
        row:Show()
    end
    for i = #rows + 1, #rowPool do
        rowPool[i]:Hide()
        rowPool[i].data = nil
    end
    content:SetHeight(math.max(#rows * ROW_H, 1))

    if #rows == 0 then
        emptyText:SetText(EmptyMessage(tab))
        emptyText:Show()
    else
        emptyText:Hide()
    end
    UpdateStatus()
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local function CreateCheck(label, x, settingKey)
    local check = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    check:SetSize(24, 24)
    check:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -28)
    local text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", check, "RIGHT", 2, 0)
    text:SetText(label)
    check:SetChecked(ns.db.settings[settingKey])
    check:SetScript("OnClick", function(self)
        ns.db.settings[settingKey] = self:GetChecked() and true or false
        log.info("Setting %s = %s", settingKey, tostring(ns.db.settings[settingKey]))
        UpdateList()
    end)
    return check
end

local function CreateInput(label, x, width)
    local text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -64)
    text:SetText(label)
    local box = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    box:SetAutoFocus(false)
    box:SetSize(width, 20)
    box:SetPoint("LEFT", text, "RIGHT", 10, 0)
    box:SetScript("OnEscapePressed", box.ClearFocus)
    box:SetScript("OnEnterPressed", box.ClearFocus)
    return box
end

local function Header(x, justify)
    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    if justify == "LEFT" then
        fs:SetPoint("TOPLEFT", frame, "TOPLEFT", x, LIST_TOP + 16)
    else
        fs:SetPoint("TOPRIGHT", frame, "TOPLEFT", x, LIST_TOP + 16)
    end
    return fs
end

local function SimpleTooltip(button, title, body)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(title)
        GameTooltip:AddLine(type(body) == "function" and body() or body, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function CreateWindow()
    frame = CreateFrame("Frame", "VendorPrinterFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()
    tinsert(UISpecialFrames, "VendorPrinterFrame")   -- close with Escape

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", frame, "TOP", 0, -6)
    title:SetText("Vendor Printer")

    -- Row 1: filters + AH scans
    CreateCheck("Learned only", 12, "learnedOnly")
    CreateCheck("Show missing prices", 120, "showIncomplete")
    CreateCheck("Auto-scan AH", 270, "autoScanAH")

    scanButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    scanButton:SetSize(120, 22)
    scanButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -30)
    scanButton:SetScript("OnClick", function()
        log.info("Full scan button clicked")
        ns.StartAHScan(true)
    end)
    SimpleTooltip(scanButton, "Full AH scan",
        "Every listing in one request. Prices everything (reagents, crafted items, flips), but allowed once per 15 minutes.")

    reagentButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    reagentButton:SetSize(110, 22)
    reagentButton:SetPoint("RIGHT", scanButton, "LEFT", -6, 0)
    reagentButton:SetScript("OnClick", function()
        log.info("Item scan button clicked (%s)", ns.IsReagentScanning() and "stop" or "start")
        ns.StartReagentScan(true)
    end)
    SimpleTooltip(reagentButton, "Scan your items", function()
        local list, counts = ns.ScanTargets()
        return ("Checks %d items: %d reagents, %d crafted items, %d vendor items. No cooldown. Quick pass: cheapest prices in a few batch requests. Detail pass: exact prices only for reagents of recipes that can still profit. Click again to stop.")
            :format(#list, counts.reagents, counts.outputs, counts.vendor)
    end)

    -- Row 2: search, crafts, view tabs
    local search = CreateInput("Search", 18, 150)
    search:SetText(ns.db.settings.search or "")
    search:SetScript("OnTextChanged", function(self)
        ns.db.settings.search = self:GetText() or ""
        ns.Debounce("search", 0.2, UpdateList)
        ns.Debounce("searchLog", 1.5, function() log.info("Search = %q", ns.db.settings.search) end)
    end)

    local crafts = CreateInput("Qty", 245, 40)
    crafts:SetNumeric(true)
    crafts:SetMaxLetters(4)
    crafts:SetText(tostring(ns.db.settings.crafts or 10))
    crafts:SetScript("OnTextChanged", function(self)
        local n = tonumber(self:GetText())
        if n and n > 0 and n ~= ns.db.settings.crafts then
            ns.db.settings.crafts = n
            ns.Debounce("craftsLog", 1.5, function() log.info("Quantity = %d", ns.db.settings.crafts) end)
        end
    end)
    SimpleTooltip(crafts, "Quantity", "Crafts used for shopping lists, or units for flip totals.")

    local previous
    for i = #TABS, 1, -1 do
        local tab = TABS[i]
        local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        button:SetSize(80, 22)
        if previous then
            button:SetPoint("RIGHT", previous, "LEFT", -4, 0)
        else
            button:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -60)
        end
        button.tab = tab
        button:SetScript("OnClick", function()
            ns.db.settings.tab = tab.key
            log.info("Tab = %s", tab.key)
            UpdateList()
        end)
        SimpleTooltip(button, tab.label, function()
            if tab.module and not ns.db.settings.modules[tab.module] then
                return tab.tip .. "\n\nTurned off. Enable with /vp module " .. tab.module .. " on"
            end
            return tab.tip
        end)
        tabButtons[#tabButtons + 1] = button
        previous = button
    end

    -- Column headers line up with row columns (rows start at x = 12 inside the frame).
    headers[1] = Header(16, "LEFT")
    headers[2] = Header(12 + COL.costRight)
    headers[3] = Header(12 + COL.sellRight)
    headers[4] = Header(12 + COL.profitRight)
    headers[5] = Header(12 + COL.pctRight)

    scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, LIST_TOP)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -32, 32)

    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(WIDTH - 50, 1)
    scroll:SetScrollChild(content)

    emptyText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    emptyText:SetPoint("CENTER", scroll, "CENTER")

    statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    statusText:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 12)

    local earnings = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    earnings:SetSize(90, 20)
    earnings:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 8)
    earnings:SetText("Earnings")
    earnings:SetScript("OnClick", function() ns.ToggleReport() end)
    SimpleTooltip(earnings, "Earnings", "Real profit from what you bought, crafted and sold (/vp report).")

    frame:SetScript("OnShow", UpdateList)
    -- Keep the scan button's cooldown and "scanned ... ago" ticking while open.
    local elapsed = 0
    frame:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed >= 1 then
            elapsed = 0
            UpdateStatus()
        end
    end)
end

function ns.ToggleWindow()
    if not frame then
        log.debug("Creating window")
        CreateWindow()
    end
    frame:SetShown(not frame:IsShown())
    log.info("Window %s (tab %s)", frame:IsShown() and "opened" or "closed", CurrentTab())
end

function ns.Refresh()
    if frame and frame:IsShown() then
        ns.Debounce("ui", 0.1, UpdateList)
    end
end
