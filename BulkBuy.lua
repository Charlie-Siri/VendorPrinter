-- BulkBuy: Alt+click an item at a vendor to buy any amount. The game caps one purchase at a stack (usually 20),
-- so the addon splits the amount into purchases (193 -> 9 x 20 + 1 x 13), sends them one at a time, and stops early
-- when the vendor sells out, your money runs out, or the items stop arriving (bags full).
local _, ns = ...
local log = ns.Logger("BulkBuy")

local TICK = 0.3          -- seconds between checks while buying
local ARRIVE_TIMEOUT = 3  -- seconds to wait for a purchase to show up in the bags

local dialog, job
local hooked = {}

-- What one merchant slot sells: per-lot price, items per lot, lots in stock (-1 = unlimited), items per purchase.
local function SlotInfo(index)
    local name, price, lot, available
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local ok, info = pcall(C_MerchantFrame.GetItemInfo, index)
        if ok and type(info) == "table" then name, price, lot, available = info.name, info.price, info.stackCount, info.numAvailable end
    end
    if not name and GetMerchantItemInfo then
        local _
        name, _, price, lot, available = GetMerchantItemInfo(index)
    end
    if not name then return nil end
    lot = math.max(lot or 1, 1)
    local perBuy = math.max(GetMerchantItemMaxStack and GetMerchantItemMaxStack(index) or 20, 1)
    if lot > 1 then perBuy = math.max(lot, math.floor(perBuy / lot) * lot) end
    return {
        index = index, name = name, itemID = GetMerchantItemID and GetMerchantItemID(index), price = price or 0,
        lot = lot, available = available or -1, perBuy = perBuy,
        link = GetMerchantItemLink and GetMerchantItemLink(index),
    }
end

local function UnitPrice(info) return info.price / info.lot end

-- 193 at 20 per purchase -> { 20, 20, ..., 13 }
local function Plan(amount, perBuy)
    local out = {}
    while amount > 0 do
        local n = math.min(amount, perBuy)
        out[#out + 1] = n
        amount = amount - n
    end
    return out
end

---------------------------------------------------------------------------
-- The amount box
---------------------------------------------------------------------------
local function UpdatePreview()
    local info = dialog.info
    local n = tonumber(dialog.box:GetText()) or 0
    if info.lot > 1 then n = math.ceil(n / info.lot) * info.lot end
    if n <= 0 then dialog.preview:SetText("Enter an amount.") return end
    local purchases = #Plan(n, info.perBuy)
    local stock = info.available >= 0 and ("  |cffff8040Vendor has %d.|r"):format(info.available * info.lot) or ""
    dialog.preview:SetText(("%s in %d purchase%s of up to %d.%s"):format(
        ns.Money(UnitPrice(info) * n), purchases, purchases == 1 and "" or "s", info.perBuy, stock))
end

local function SetBusy(busy)
    dialog.box:SetEnabled(not busy)
    dialog.buy:SetEnabled(not busy)
    dialog.cancel:SetText(busy and "Stop" or "Cancel")
    dialog.bar:SetShown(busy)
end

local function CreateDialog()
    local d = CreateFrame("Frame", "VendorPrinterBulkBuy", UIParent, "BasicFrameTemplateWithInset")
    d:SetSize(300, 170)
    d:SetPoint("CENTER", 0, 120)
    d:SetFrameStrata("DIALOG")
    d:SetMovable(true)
    d:EnableMouse(true)
    d:RegisterForDrag("LeftButton")
    d:SetScript("OnDragStart", d.StartMoving)
    d:SetScript("OnDragStop", d.StopMovingOrSizing)
    d:Hide()
    tinsert(UISpecialFrames, "VendorPrinterBulkBuy")

    d.title = d:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    d.title:SetPoint("TOP", 0, -6)
    d.title:SetText("Buy in bulk")
    d.item = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    d.item:SetPoint("TOP", 0, -34)
    d.item:SetWidth(270)

    d.box = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
    d.box:SetSize(70, 22)
    d.box:SetPoint("TOP", d.item, "BOTTOM", -50, -10)
    d.box:SetNumeric(true)
    d.box:SetMaxLetters(5)
    d.box:SetAutoFocus(false)
    d.box:SetScript("OnTextChanged", function() ns.SafeCall("BulkPreview", UpdatePreview) end)
    d.box:SetScript("OnEnterPressed", function() d.buy:Click() end)
    d.box:SetScript("OnEscapePressed", function() d:Hide() end)
    local unit = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    unit:SetPoint("LEFT", d.box, "RIGHT", 8, 0)
    unit:SetText("items")

    d.preview = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.preview:SetPoint("TOP", d.item, "BOTTOM", 0, -40)
    d.preview:SetWidth(270)

    d.bar = CreateFrame("StatusBar", nil, d)
    d.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    d.bar:SetStatusBarColor(0.2, 0.75, 0.3)
    d.bar:SetSize(260, 14)
    d.bar:SetPoint("TOP", d.preview, "BOTTOM", 0, -6)
    d.bar:SetMinMaxValues(0, 1)
    d.bar.bg = d.bar:CreateTexture(nil, "BACKGROUND")
    d.bar.bg:SetAllPoints()
    d.bar.bg:SetColorTexture(0, 0, 0, 0.5)
    d.bar.text = d.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.bar.text:SetPoint("CENTER")
    d.bar:Hide()

    d.buy = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
    d.buy:SetSize(100, 22)
    d.buy:SetPoint("BOTTOMRIGHT", d, "BOTTOM", -4, 12)
    d.buy:SetText("Buy")
    d.buy:SetScript("OnClick", function() ns.SafeCall("BulkBuy", ns.StartBulkBuy) end)
    d.cancel = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
    d.cancel:SetSize(100, 22)
    d.cancel:SetPoint("BOTTOMLEFT", d, "BOTTOM", 4, 12)
    d.cancel:SetText("Cancel")
    d.cancel:SetScript("OnClick", function()
        if job then ns.SafeCall("BulkStop", ns.StopBulkBuy, "stopped") else d:Hide() end
    end)
    d:SetScript("OnHide", function() if job then ns.StopBulkBuy("window closed") end end)
    dialog = d
end

local function OpenDialog(index)
    if job then ns.Print("Still buying %s; stop that first.", job.info.name) return end
    local info = SlotInfo(index)
    if not info then log.warn("Alt+click on merchant slot %s: no item info", tostring(index)) return end
    if not dialog then CreateDialog() end
    dialog.info = info
    dialog.item:SetText(("%s  |cffffffff%s each|r"):format(info.link or info.name, ns.Money(UnitPrice(info))))
    dialog.box:SetText(tostring(info.perBuy))
    dialog.box:HighlightText()
    SetBusy(false)
    dialog:Show()
    dialog.box:SetFocus()
    UpdatePreview()
    log.info("Bulk buy box for %s (slot %d): %s per lot of %d, %d per purchase, stock %d", info.name, index,
        ns.Money(info.price), info.lot, info.perBuy, info.available)
end

---------------------------------------------------------------------------
-- Buying
---------------------------------------------------------------------------
local function Finish(reason)
    local j = job
    if not j then return end
    job = nil
    if j.ticker then j.ticker:Cancel() end
    local got = GetItemCount(j.info.itemID) - j.startCount
    local spent = j.startMoney - GetMoney()
    local why = reason and (" (" .. reason .. ")") or ""
    ns.Print("Bought %dx %s in %d purchase%s for %s%s.", got, j.info.link or j.info.name, j.purchases,
        j.purchases == 1 and "" or "s", ns.Money(spent), why)
    log.info("Bulk buy done: %d of %d %s, %d purchases, %.0fc%s", got, j.want, j.info.name, j.purchases, spent, why)
    if dialog then
        SetBusy(false)
        if not reason then dialog:Hide() end
    end
end

function ns.StopBulkBuy(reason) Finish(reason or "stopped") end

local function Step()
    local j = job
    if not j then return end
    if not (MerchantFrame and MerchantFrame:IsShown()) then return Finish("merchant closed") end
    local got = GetItemCount(j.info.itemID) - j.startCount
    dialog.bar:SetValue(got / j.want)
    dialog.bar.text:SetText(("%d / %d  (%d purchase%s)"):format(got, j.want, j.purchases, j.purchases == 1 and "" or "s"))
    if j.waiting then
        if got >= j.expect then
            j.waiting = false
        elseif GetTime() - j.sentAt > ARRIVE_TIMEOUT then
            return Finish("items stopped arriving: bags full?")
        else
            return
        end
    end
    local remaining = j.want - got
    if remaining <= 0 then return Finish(nil) end
    local info = SlotInfo(j.info.index)
    if not info or info.itemID ~= j.info.itemID then return Finish("the vendor's list changed") end
    if info.available == 0 then return Finish("vendor sold out") end
    local n = math.min(remaining, info.perBuy)
    if info.available > 0 then n = math.min(n, info.available * info.lot) end
    local unit = UnitPrice(info)
    if unit > 0 and n * unit > GetMoney() then
        n = math.floor(GetMoney() / unit)
        if info.lot > 1 then n = math.floor(n / info.lot) * info.lot end
        if n <= 0 then return Finish("not enough money") end
    end
    BuyMerchantItem(info.index, n)
    j.purchases = j.purchases + 1
    j.waiting, j.expect, j.sentAt = true, got + n, GetTime()
    log.debug("Purchase %d: %d x %s (%d of %d so far)", j.purchases, n, info.name, got, j.want)
end

function ns.StartBulkBuy()
    if job or not dialog or not dialog.info then return end
    local info = SlotInfo(dialog.info.index) or dialog.info
    local want = tonumber(dialog.box:GetText()) or 0
    if info.lot > 1 then want = math.ceil(want / info.lot) * info.lot end
    if want <= 0 then ns.Print("Enter how many to buy.") return end
    job = { info = info, want = want, purchases = 0, startCount = GetItemCount(info.itemID), startMoney = GetMoney() }
    log.info("Bulk buy start: %d x %s, planned %d purchases of up to %d", want, info.name, #Plan(want, info.perBuy), info.perBuy)
    SetBusy(true)
    dialog.box:ClearFocus()
    Step()
    if job then job.ticker = C_Timer.NewTicker(TICK, function() ns.SafeCall("BulkStep", Step) end) end
end

---------------------------------------------------------------------------
-- Alt+click on the merchant's item buttons
---------------------------------------------------------------------------
local function HookButtons()
    for i = 1, (MERCHANT_ITEMS_PER_PAGE or 10) do
        local button = _G["MerchantItem" .. i .. "ItemButton"]
        if button and not hooked[button] then
            hooked[button] = true
            local original = button:GetScript("OnClick")
            button:SetScript("OnClick", function(self, mouse, ...)
                if mouse == "LeftButton" and IsAltKeyDown() and (MerchantFrame.selectedTab == nil or MerchantFrame.selectedTab == 1) then
                    ns.SafeCall("BulkBuyOpen", OpenDialog, self:GetID())
                    return
                end
                if original then return original(self, mouse, ...) end
            end)
        end
    end
end

ns.On("MERCHANT_SHOW", function() HookButtons() end)
ns.On("MERCHANT_CLOSED", function()
    if job then Finish("merchant closed") end
    if dialog then dialog:Hide() end
end)
