-- Merchant: when a vendor sells something worth flipping on the AH, make it impossible to miss:
-- green glow + profit on the merchant item buttons, a side panel listing the flips, one chat line and a sound.
local _, ns = ...
local log = ns.Logger("Merchant")

local MAX_PANEL_ROWS = 8
local STALE_AFTER = 24 * 60 * 60   -- warn when AH prices are older than a day

local flipsByIndex = {}   -- [merchant index] = flip data for the open merchant
local flipList = {}       -- same flips, best first
local panel, panelRows = nil, {}
local alertedVisit = false   -- one chat line + sound per merchant visit
local hintedNoData = false   -- one "no AH prices yet" hint per session

-- Compact money for the small text on item buttons: "+3g", "+45s", "+12c".
local function ShortMoney(copper)
    copper = math.floor(copper + 0.5)
    if copper >= 10000 then return ("%dg"):format(math.floor(copper / 10000)) end
    if copper >= 100 then return ("%ds"):format(math.floor(copper / 100)) end
    return ("%dc"):format(copper)
end

local function IsWorthIt(profit, buy)
    local s = ns.db.settings
    return profit >= (s.flipMinProfit or 100) and (profit / buy) >= (s.flipMinROI or 0.10)
end

local function NewestAHScan()
    local newest = math.max(ns.db.ahScanTime or 0, ns.db.ahReagentScanTime or 0)
    return newest > 0 and newest or nil
end

---------------------------------------------------------------------------
-- Item button highlights
---------------------------------------------------------------------------
-- Overlays live in our own table rather than as fields on Blizzard's buttons (avoids tainting their frames).
local overlays = {}

local function GetOverlay(i)
    local button = _G["MerchantItem" .. i .. "ItemButton"]
    if not button then return nil end
    if not overlays[i] then
        local overlay = CreateFrame("Frame", nil, button)
        overlay:SetAllPoints()
        overlay:SetFrameLevel(button:GetFrameLevel() + 5)
        local glow = overlay:CreateTexture(nil, "OVERLAY")
        glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        glow:SetBlendMode("ADD")
        glow:SetVertexColor(0.2, 1, 0.2)
        glow:SetPoint("CENTER")
        glow:SetSize(button:GetWidth() * 1.8, button:GetHeight() * 1.8)
        overlay.text = overlay:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        overlay.text:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
        overlay.text:SetTextColor(0.25, 1, 0.25)
        overlays[i] = overlay
    end
    return overlays[i]
end

local function UpdateOverlays()
    local perPage = MERCHANT_ITEMS_PER_PAGE or 10
    local showing = ns.db and ns.db.settings.merchantAlert and MerchantFrame and MerchantFrame:IsShown()
        and (MerchantFrame.selectedTab == nil or MerchantFrame.selectedTab == 1)   -- not on the buyback tab
    local page = (MerchantFrame and MerchantFrame.page) or 1
    for i = 1, perPage do
        local overlay = GetOverlay(i)
        if overlay then
            local flip = showing and flipsByIndex[(page - 1) * perPage + i]
            if flip then
                overlay.text:SetText("+" .. ShortMoney(flip.profit))
                overlay:Show()
            else
                overlay:Hide()
            end
        end
    end
end

---------------------------------------------------------------------------
-- Side panel
---------------------------------------------------------------------------
local function CreatePanel()
    panel = CreateFrame("Frame", "VendorPrinterMerchantPanel", MerchantFrame, "BackdropTemplate")
    panel:SetWidth(290)
    panel:SetPoint("TOPLEFT", MerchantFrame, "TOPRIGHT", 4, -24)
    panel:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    panel:SetBackdropColor(0, 0, 0, 0.85)
    panel:SetBackdropBorderColor(0.25, 1, 0.25)

    panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.title:SetPoint("TOPLEFT", 12, -10)
    panel.title:SetTextColor(0.25, 1, 0.25)
    panel.sub = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.sub:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -3)
    panel.more = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")

    for i = 1, MAX_PANEL_ROWS do
        local row = CreateFrame("Button", nil, panel)
        row:SetSize(266, 22)
        row:SetPoint("TOPLEFT", 12, -44 - (i - 1) * 24)
        local highlight = row:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetColorTexture(1, 1, 1, 0.1)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(20, 20)
        row.icon:SetPoint("LEFT")
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.name:SetWidth(150)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row.profit = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.profit:SetPoint("RIGHT")
        row.profit:SetJustifyH("RIGHT")
        row:SetScript("OnEnter", function(self)
            if not self.flip then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(self.flip.itemID)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Click for details in chat", 0.5, 0.8, 1)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:SetScript("OnClick", function(self)
            if self.flip then
                log.info("Merchant panel row clicked: item %d", self.flip.itemID)
                ns.PrintFlip(self.flip)
            end
        end)
        panelRows[i] = row
    end
end

local function UpdatePanel()
    if #flipList == 0 or not ns.db.settings.merchantAlert then
        if panel then panel:Hide() end
        return
    end
    if not panel then CreatePanel() end

    panel.title:SetText(("Vendor Printer: %d AH flip%s here!"):format(#flipList, #flipList == 1 and "" or "s"))
    local newest = NewestAHScan()
    local age = newest and (time() - newest) or nil
    local ageText = age and (SecondsToTime and SecondsToTime(age, true) or (math.floor(age / 60) .. " min")) or "?"
    if age and age > STALE_AFTER then
        panel.sub:SetText("|cffff8040AH prices are " .. ageText .. " old: rescan to confirm|r")
    else
        panel.sub:SetText("Profit each after the 5% AH cut  ·  AH prices " .. ageText .. " old")
    end

    local GetIcon = C_Item and C_Item.GetItemIconByID
    local shown = math.min(#flipList, MAX_PANEL_ROWS)
    for i = 1, MAX_PANEL_ROWS do
        local row, flip = panelRows[i], flipList[i]
        if flip and i <= shown then
            row.flip = flip
            row.icon:SetTexture(GetIcon and GetIcon(flip.itemID) or nil)
            local name = ns.GetItemLink(flip.itemID)
            if flip.available and flip.available >= 0 then name = name .. (" |cffff8040(%d left)|r"):format(flip.available) end
            row.name:SetText(name)
            row.profit:SetText("|cff40ff40+" .. ns.Money(flip.profit) .. "|r")
            row:Show()
        else
            row.flip = nil
            row:Hide()
        end
    end
    local height = 44 + shown * 24 + 10
    if #flipList > MAX_PANEL_ROWS then
        panel.more:ClearAllPoints()
        panel.more:SetPoint("TOPLEFT", 12, -44 - shown * 24 - 2)
        panel.more:SetText(("+%d more in the Flips tab (/vp)"):format(#flipList - MAX_PANEL_ROWS))
        panel.more:Show()
        height = height + 16
    else
        panel.more:Hide()
    end
    panel:SetHeight(height)
    panel:Show()
end

---------------------------------------------------------------------------
-- Called by Prices.lua after each merchant scan
---------------------------------------------------------------------------
function ns.OnMerchantScanned(items, npc, zone)
    wipe(flipsByIndex)
    wipe(flipList)
    local db = ns.db
    if not db.settings.modules.flips then
        UpdateOverlays()
        UpdatePanel()
        return
    end
    if next(db.ahMin) == nil then
        if not hintedNoData then
            hintedNoData = true
            log.info("Merchant %q: no AH prices loaded, flip check skipped", npc)
            ns.Print("Tip: do a full AH scan once and vendors will highlight items worth selling on the AH.")
        end
        UpdateOverlays()
        UpdatePanel()
        return
    end

    local checked, belowThreshold = 0, 0
    for index, item in pairs(items) do
        local net = ns.AHNet(item.itemID)
        if net then
            checked = checked + 1
            local profit = net - item.unit
            if profit > 0 and IsWorthIt(profit, item.unit) then
                local flip = {
                    index = index, itemID = item.itemID, buy = item.unit, net = net, profit = profit,
                    roi = profit / item.unit, available = item.available, limited = item.available and item.available >= 0,
                    listed = db.ahListed[item.itemID], source = { npc = npc, zone = zone },
                }
                flipsByIndex[index] = flip
                flipList[#flipList + 1] = flip
                log.debug("Flip at %q: slot %d item %d buy %.0fc AH net %.0fc profit %.0fc (%+.0f%%) listed %s available %s",
                    npc, index, item.itemID, item.unit, net, profit, profit / item.unit * 100,
                    tostring(flip.listed), tostring(item.available))
            elseif profit > 0 then
                belowThreshold = belowThreshold + 1
            end
        end
    end
    table.sort(flipList, function(a, b) return a.profit > b.profit end)
    log.info("Merchant %q flip check: %d items with AH price, %d flips, %d profitable but below threshold (min %dc, %d%%)",
        npc, checked, #flipList, belowThreshold, db.settings.flipMinProfit or 100, (db.settings.flipMinROI or 0.10) * 100)

    if #flipList > 0 and db.settings.merchantAlert and not alertedVisit then
        alertedVisit = true
        local best = flipList[1]
        ns.Print("|cff40ff40%d item%s here sell on the AH for profit|r (best: %s +%s each). See the panel next to the vendor.",
            #flipList, #flipList == 1 and "" or "s", ns.GetItemLink(best.itemID), ns.Money(best.profit))
        if db.settings.merchantSound and PlaySound and SOUNDKIT and SOUNDKIT.LOOT_WINDOW_COIN_SOUND then
            PlaySound(SOUNDKIT.LOOT_WINDOW_COIN_SOUND)
        end
    end
    UpdateOverlays()
    UpdatePanel()
end

ns.On("MERCHANT_SHOW", function() alertedVisit = false end)
ns.On("MERCHANT_CLOSED", function()
    wipe(flipsByIndex)
    wipe(flipList)
    if panel then panel:Hide() end
    UpdateOverlays()
end)

-- Re-apply highlights whenever Blizzard redraws the merchant (page flips, buyback tab).
if hooksecurefunc and MerchantFrame_UpdateMerchantInfo then
    hooksecurefunc("MerchantFrame_UpdateMerchantInfo", function() ns.SafeCall("MerchantOverlays", UpdateOverlays) end)
    log.debug("Hooked MerchantFrame_UpdateMerchantInfo")
else
    log.warn("MerchantFrame_UpdateMerchantInfo not found: item highlights won't follow page changes")
end
if hooksecurefunc and MerchantFrame_UpdateBuybackInfo then
    hooksecurefunc("MerchantFrame_UpdateBuybackInfo", function() ns.SafeCall("MerchantOverlays", UpdateOverlays) end)
end
