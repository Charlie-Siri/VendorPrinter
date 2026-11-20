-- AHPanel: small panel docked to the right of the Auction House window with the scan buttons.
local _, ns = ...
local log = ns.Logger("AHPanel")

local panel

local function Update()
    if not panel then return end
    local text, enabled = ns.FullScanButtonState()
    panel.full:SetText(text)
    panel.full:SetEnabled(enabled)
    text, enabled = ns.ItemScanButtonState()
    panel.items:SetText(text)
    panel.items:SetEnabled(enabled)

    local newest = math.max(ns.db.ahScanTime or 0, ns.db.ahReagentScanTime or 0)
    if newest > 0 then
        local age = time() - newest
        panel.status:SetText("Prices: " .. (age < 60 and "just now" or
            ((SecondsToTime and SecondsToTime(age, true) or (math.floor(age / 60) .. " min")) .. " old")))
    else
        panel.status:SetText("No AH prices yet")
    end
end

local function Button(label, y, onClick, tipTitle, tipBody)
    local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    button:SetSize(136, 22)
    button:SetPoint("TOP", panel, "TOP", 0, y)
    button:SetText(label)
    button:SetScript("OnClick", onClick)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(tipTitle)
        GameTooltip:AddLine(type(tipBody) == "function" and tipBody() or tipBody, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return button
end

local function CreatePanel()
    local parent = _G.AuctionHouseFrame
    if not parent then
        log.warn("AuctionHouseFrame not found: AH panel not created (use /vp scan instead)")
        return
    end
    panel = CreateFrame("Frame", "VendorPrinterAHPanel", parent, "BackdropTemplate")
    panel:SetSize(160, 132)
    panel:SetPoint("TOPLEFT", parent, "TOPRIGHT", 2, -28)
    panel:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    panel:SetBackdropColor(0, 0, 0, 0.85)

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -10)
    title:SetText("Vendor Printer")

    panel.full = Button("Full scan", -30, function()
        log.info("AH panel: full scan clicked")
        ns.StartAHScan(true)
    end, "Full AH scan", "Every listing in one request: prices reagents, crafted items and flips. Allowed once per 15 minutes.")

    panel.items = Button("Scan items", -56, function()
        log.info("AH panel: item scan clicked (%s)", ns.IsReagentScanning() and "stop" or "start")
        ns.StartReagentScan(true)
    end, "Scan your items", function()
        local list, counts = ns.ScanTargets()
        return ("Checks %d items (%d reagents, %d crafted, %d vendor). No cooldown. Click again to stop.")
            :format(#list, counts.reagents, counts.outputs, counts.vendor)
    end)

    Button("Open list", -82, function()
        log.info("AH panel: open list clicked")
        ns.ToggleWindow()
    end, "Vendor Printer", "Open the recipe and flip list (/vp).")

    panel.status = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.status:SetPoint("BOTTOM", 0, 12)

    local elapsed = 0
    panel:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed >= 0.5 then
            elapsed = 0
            Update()
        end
    end)
    log.info("AH panel created")
end

ns.On("AUCTION_HOUSE_SHOW", function()
    if not ns.db.settings.ahPanel then return end
    if not panel then CreatePanel() end
    if panel then
        panel:Show()
        Update()
    end
end)

function ns.SetAHPanelShown(shown)
    if panel then panel:SetShown(shown and ns.ahOpen) end
end
