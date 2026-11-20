-- Progress: on-screen bar + chat milestones + ETA for long-running actions (scans).
-- Usage: ns.Progress.Start("Reagent scan"); ns.Progress.Update(done, total, "quick pass"); ns.Progress.Finish("Done ...")
local _, ns = ...
local log = ns.Logger("Progress")

local Progress = {}
ns.Progress = Progress

local bar            -- the on-screen frame, created on first use
local state = nil    -- { title, started, phase, phaseStarted, done, total, lastMilestone, waitingText }
local HIDE_AFTER = 5 -- seconds the final message stays on screen

local function FormatDuration(seconds)
    seconds = math.max(0, math.floor(seconds + 0.5))
    if seconds >= 60 then return ("%dm %02ds"):format(math.floor(seconds / 60), seconds % 60) end
    return seconds .. "s"
end

-- Estimated time left from the average time per item in the current phase.
local function Eta()
    if not state or not state.total or state.total == 0 or state.done == 0 then return nil end
    local elapsed = GetTime() - state.phaseStarted
    local perItem = elapsed / state.done
    return perItem * (state.total - state.done)
end

local function StatusText()
    if not state then return "" end
    local parts = { state.title }
    if state.phase then parts[#parts + 1] = state.phase end
    if state.total and state.total > 0 then
        parts[#parts + 1] = ("%d/%d (%d%%)"):format(state.done, state.total, math.floor(state.done / state.total * 100))
        local eta = Eta()
        if eta then parts[#parts + 1] = "ETA " .. FormatDuration(eta) end
    elseif state.waitingText then
        parts[#parts + 1] = ("%s %s"):format(state.waitingText, FormatDuration(GetTime() - state.phaseStarted))
    end
    return table.concat(parts, "  ·  ")
end

local function CreateBar()
    bar = CreateFrame("Frame", "VendorPrinterProgressBar", UIParent)
    bar:SetSize(360, 26)
    local pos = ns.db.settings.progressPos
    if pos then
        bar:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        bar:SetPoint("TOP", UIParent, "TOP", 0, -140)
    end
    bar:SetFrameStrata("DIALOG")
    bar:SetMovable(true)
    bar:EnableMouse(true)
    bar:SetClampedToScreen(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", bar.StartMoving)
    bar:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        ns.db.settings.progressPos = { point, relPoint, x, y }
        log.debug("Progress bar moved to %s %s %.0f %.0f", point, relPoint, x, y)
    end)

    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.7)

    bar.status = CreateFrame("StatusBar", nil, bar)
    bar.status:SetPoint("TOPLEFT", 2, -2)
    bar.status:SetPoint("BOTTOMRIGHT", -2, 2)
    bar.status:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar.status:SetStatusBarColor(0.2, 0.75, 0.35)
    bar.status:SetMinMaxValues(0, 1)

    bar.text = bar.status:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.text:SetPoint("CENTER")

    bar:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Vendor Printer")
        GameTooltip:AddLine("Drag to move. Chat updates: /vp progress <milestones|all|off>.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    bar:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Keep elapsed/ETA ticking between updates.
    local elapsed = 0
    bar:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed < 0.25 then return end
        elapsed = 0
        if state then bar.text:SetText(StatusText()) end
    end)
    bar:Hide()
end

local function Redraw()
    if not bar then CreateBar() end
    if state.total and state.total > 0 then
        bar.status:SetValue(state.done / state.total)
    else
        -- Indeterminate (waiting on the server): show a thin sliver.
        bar.status:SetValue(0.02)
    end
    bar.text:SetText(StatusText())
    bar:Show()
end

local function ChatMode() return ns.db.settings.progressChat or "milestones" end

function Progress.Start(title)
    state = { title = title, started = GetTime(), phaseStarted = GetTime(), done = 0, total = 0, lastMilestone = -1 }
    log.info("Progress start: %s", title)
    if bar then bar.hideToken = nil end
    Redraw()
end

-- New phase with its own counter and ETA (e.g. "quick pass" -> "detail pass").
function Progress.Phase(phase, total, waitingText)
    if not state then return end
    state.phase, state.total, state.done = phase, total or 0, 0
    state.phaseStarted, state.lastMilestone, state.waitingText = GetTime(), -1, waitingText
    log.info("Progress phase: %s / %s (%d items)", state.title, tostring(phase), total or 0)
    if ChatMode() ~= "off" and total and total > 0 then
        ns.Print("%s: %s, %d to go.", state.title, phase, total)
    end
    Redraw()
end

function Progress.Update(done, total)
    if not state then return end
    state.done = done
    if total then state.total = total end
    Redraw()

    local mode = ChatMode()
    if mode == "off" or state.total == 0 then return end
    local eta = Eta()
    local etaText = eta and (", ETA " .. FormatDuration(eta)) or ""
    if mode == "all" then
        print(("|cff33ff99Vendor Printer|r: %s %d/%d%s"):format(state.phase or state.title, done, state.total, etaText))
    else
        local milestone = math.floor(done / state.total * 10)   -- every 10%
        if milestone > state.lastMilestone and done < state.total then
            state.lastMilestone = milestone
            if milestone > 0 then
                print(("|cff33ff99Vendor Printer|r: %s %d%% (%d/%d)%s"):format(
                    state.phase or state.title, milestone * 10, done, state.total, etaText))
            end
        end
    end
end

function Progress.Finish(text)
    if not state then return end
    local total = GetTime() - state.started
    log.info("Progress finish: %s after %s: %s", state.title, FormatDuration(total), tostring(text))
    state = nil
    if not bar then return end
    bar.status:SetValue(1)
    bar.text:SetText(text or "Done")
    local token = {}
    bar.hideToken = token
    C_Timer.After(HIDE_AFTER, function()
        if bar.hideToken == token and not state then bar:Hide() end
    end)
end

function Progress.IsActive() return state ~= nil end

function Progress.FormatDuration(seconds) return FormatDuration(seconds) end
