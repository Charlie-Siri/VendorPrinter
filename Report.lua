-- Report: earnings window (/vp report, or Earnings in the main window). Numbers come from Ledger.lua.
local _, ns = ...
local log = ns.Logger("Report")

local WIDTH, HEIGHT = 560, 530
local ROW_H = 16
local BEST_ROWS, RECENT_ROWS = 6, 8
local GREEN, RED, GREY = "|cff40ff40", "|cffff5050", "|cff9d9d9d"

local frame
local periods, activityRows, bestRows, recentRows = {}, {}, {}, {}
local footer

local function Signed(copper)
    if copper == nil then return GREY .. "-|r" end
    local color = copper > 0.5 and GREEN or (copper < -0.5 and RED or "")
    return color .. ns.Money(copper) .. (color ~= "" and "|r" or "")
end

local function Ago(t)
    local s = time() - t
    if s < 60 then return "now" end
    if s < 3600 then return math.floor(s / 60) .. "m" end
    if s < 86400 then return math.floor(s / 3600) .. "h" end
    return math.floor(s / 86400) .. "d"
end

local CHANNEL = { vendor = "vendor", ah = "AH" }

local function TxText(tx)
    local item = ns.GetItemLink(tx.i)
    local qty = tx.q == math.floor(tx.q) and tostring(tx.q) or ("%.1f"):format(tx.q)
    if tx.k == "buy" then
        return ("Bought %sx %s for %s (%s)"):format(qty, item, ns.Money(tx.m), CHANNEL[tx.s] or tx.s)
    elseif tx.k == "craft" then
        return ("Crafted %sx %s, reagents %s%s"):format(qty, item, ns.Money(tx.m), tx.e and GREY .. " (est.)|r" or "")
    elseif tx.u then
        return GREY .. ("Sold %sx %s for %s (%s), not tracked"):format(qty, item, ns.Money(tx.m), CHANNEL[tx.s] or tx.s) .. "|r"
    end
    return ("Sold %sx %s for %s (%s): %s%s"):format(qty, item, ns.Money(tx.m), CHANNEL[tx.s] or tx.s, Signed(tx.p),
        tx.e and GREY .. " (est.)|r" or "")
end

---------------------------------------------------------------------------
-- Layout helpers
---------------------------------------------------------------------------
local function Text(parent, font, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
end

local function Heading(label, y)
    local fs = Text(frame, "GameFontNormal")
    fs:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, y)
    fs:SetText(label)
    return fs
end

-- A row of right-aligned money columns after a left label.
local COLS = { 300, 360, 430, 530 }   -- right edges: sales, revenue, cost, profit
local function TableRow(y, header)
    local row = { cells = {} }
    row.label = Text(frame, header and "GameFontNormalSmall" or "GameFontHighlightSmall")
    row.label:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, y)
    row.label:SetWidth(220)
    for i, right in ipairs(COLS) do
        local cell = Text(frame, header and "GameFontNormalSmall" or "GameFontHighlightSmall", "RIGHT")
        cell:SetPoint("TOPRIGHT", frame, "TOPLEFT", right, y)
        cell:SetWidth(i == 1 and 50 or 80)
        row.cells[i] = cell
    end
    return row
end

local function CreateWindow()
    frame = CreateFrame("Frame", "VendorPrinterReportFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("CENTER", 40, -20)
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()
    tinsert(UISpecialFrames, "VendorPrinterReportFrame")

    local title = Text(frame, "GameFontHighlight", "CENTER")
    title:SetPoint("TOP", frame, "TOP", 0, -6)
    title:SetText("Vendor Printer: Earnings")

    -- Profit per period
    local labels = { { "Today", 1 }, { "Last 7 days", 7 }, { "Last 30 days", 30 }, { "All time", nil } }
    for i, p in ipairs(labels) do
        local x = 16 + (i - 1) * 132
        local box = { days = p[2] }
        box.label = Text(frame, "GameFontNormalSmall")
        box.label:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -36)
        box.label:SetText(p[1])
        box.value = Text(frame, "GameFontHighlightLarge")
        box.value:SetPoint("TOPLEFT", box.label, "BOTTOMLEFT", 0, -4)
        box.sub = Text(frame, "GameFontDisableSmall")
        box.sub:SetPoint("TOPLEFT", box.value, "BOTTOMLEFT", 0, -3)
        periods[i] = box
    end

    -- By activity
    Heading("By activity", -104)
    local header = TableRow(-124, true)
    header.label:SetText("Activity")
    for i, label in ipairs({ "Sales", "Revenue", "Cost", "Profit" }) do header.cells[i]:SetText(label) end
    for i, activity in ipairs(ns.ACTIVITIES) do
        local row = TableRow(-124 - i * ROW_H)
        row.label:SetText(activity.label)
        row.key = activity.key
        activityRows[i] = row
    end

    -- Best items
    Heading("Best items", -228)
    for i = 1, BEST_ROWS do
        local row = CreateFrame("Button", nil, frame)
        row:SetSize(WIDTH - 40, ROW_H)
        row:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -248 - (i - 1) * ROW_H)
        local highlight = row:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetColorTexture(1, 1, 1, 0.08)
        row.name = Text(row)
        row.name:SetPoint("LEFT", 0, 0)
        row.name:SetWidth(300)
        row.units = Text(row, nil, "RIGHT")
        row.units:SetPoint("RIGHT", row, "LEFT", COLS[2] - 20, 0)
        row.profit = Text(row, nil, "RIGHT")
        row.profit:SetPoint("RIGHT", row, "LEFT", COLS[4] - 20, 0)
        row:SetScript("OnEnter", function(self)
            if not self.itemID then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(self.itemID)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        bestRows[i] = row
    end

    -- Recent transactions
    Heading("Recent", -352)
    for i = 1, RECENT_ROWS do
        local row = {}
        row.ago = Text(frame, "GameFontDisableSmall", "RIGHT")
        row.ago:SetPoint("TOPRIGHT", frame, "TOPLEFT", 44, -372 - (i - 1) * ROW_H)
        row.ago:SetWidth(26)
        row.text = Text(frame)
        row.text:SetPoint("TOPLEFT", frame, "TOPLEFT", 52, -372 - (i - 1) * ROW_H)
        row.text:SetWidth(WIDTH - 72)
        recentRows[i] = row
    end

    footer = Text(frame, "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 12)
    footer:SetWidth(WIDTH - 130)

    local reset = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    reset:SetSize(90, 20)
    reset:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 8)
    reset:SetText("Reset")
    reset:SetScript("OnClick", function()
        StaticPopupDialogs.VENDORPRINTER_RESET_LEDGER = StaticPopupDialogs.VENDORPRINTER_RESET_LEDGER or {
            text = "Clear Vendor Printer's earnings history and tracked stock for this character?",
            button1 = YES or "Yes", button2 = NO or "No",
            OnAccept = function() ns.ResetLedger() end,
            hideOnEscape = true, timeout = 0, whileDead = true,
        }
        StaticPopup_Show("VENDORPRINTER_RESET_LEDGER")
    end)

    -- Same strata as the other Vendor Printer windows: raise on show and on click so it isn't drawn under them.
    frame:SetToplevel(true)
    frame:SetScript("OnShow", function(self) self:Raise(); ns.UpdateReport() end)
end

---------------------------------------------------------------------------
-- Update
---------------------------------------------------------------------------
function ns.UpdateReport()
    if not (frame and frame:IsShown()) then return end
    local L = ns.GetLedger()
    if not L then return end

    for _, box in ipairs(periods) do
        local p = ns.LedgerPeriod(box.days)
        box.value:SetText(Signed(p.profit))
        box.sub:SetText(("%d sale%s · %s revenue"):format(p.sales, p.sales == 1 and "" or "s", ns.Money(p.revenue)))
    end

    for _, row in ipairs(activityRows) do
        local a = L.activities[row.key]
        row.cells[1]:SetText(a and tostring(a.sales) or GREY .. "0|r")
        row.cells[2]:SetText(a and ns.Money(a.revenue) or "")
        row.cells[3]:SetText(a and ns.Money(a.cost) or "")
        row.cells[4]:SetText(a and Signed(a.profit) or "")
    end

    local best = {}
    for itemID, e in pairs(L.items) do best[#best + 1] = { itemID = itemID, profit = e.profit or 0, units = e.units or 0 } end
    table.sort(best, function(a, b) return a.profit > b.profit end)
    for i, row in ipairs(bestRows) do
        local b = best[i]
        if b then
            row.itemID = b.itemID
            row.name:SetText(ns.GetItemLink(b.itemID))
            row.units:SetText(("%d sold"):format(b.units))
            row.profit:SetText(Signed(b.profit))
            row:Show()
        else
            row.itemID = nil
            row:Hide()
        end
    end
    if #best == 0 then
        bestRows[1].name:SetText(GREY .. "Nothing sold yet. Buy reagents, craft, then sell to a vendor or on the AH.|r")
        bestRows[1].units:SetText("")
        bestRows[1].profit:SetText("")
        bestRows[1]:Show()
    end

    for i, row in ipairs(recentRows) do
        local tx = L.tx[#L.tx - i + 1]
        if tx then
            row.ago:SetText(Ago(tx.t))
            row.text:SetText(TxText(tx))
        else
            row.ago:SetText("")
            row.text:SetText("")
        end
    end

    local units, stockCost = ns.LedgerStock()
    local totals = L.totals
    local estimated = (totals.cost or 0) > 0 and math.floor((totals.estimatedCost or 0) / totals.cost * 100 + 0.5) or 0
    footer:SetText(("Unsold stock: %d units, %s at cost  ·  %d%% of costs estimated  ·  since %s"):format(
        math.floor(units + 0.5), ns.Money(stockCost), estimated, date("%Y-%m-%d", L.started)))
end

function ns.RefreshReport()
    if frame and frame:IsShown() then ns.Debounce("report", 0.2, ns.UpdateReport) end
end

function ns.ToggleReport()
    if not frame then CreateWindow() end
    frame:SetShown(not frame:IsShown())
    log.info("Report %s", frame:IsShown() and "opened" or "closed")
end

-- Item names arrive asynchronously; redraw once they do.
ns.On("GET_ITEM_INFO_RECEIVED", function() ns.RefreshReport() end)
