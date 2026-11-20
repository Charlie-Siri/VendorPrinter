-- Sort: clickable column headers cycling ascending -> descending -> off, and a stable sort for rows.
-- One column at a time; `state` is a table { key, dir } kept in settings so it survives /reload.
local _, ns = ...
local log = ns.Logger("Sort")

local ARROW = "Interface\\Buttons\\UI-SortArrow"

-- Sorts `rows` in place by `getters[state.key]`. Missing values go last in both directions;
-- ties keep the incoming order, so "off" is simply the order rows were built in.
function ns.SortRows(rows, state, getters)
    local get = state and state.key and getters[state.key]
    if not get then return rows end
    local desc = state.dir == "desc"
    local keyed = {}
    for i, row in ipairs(rows) do keyed[i] = { row = row, value = get(row), order = i } end
    table.sort(keyed, function(a, b)
        local va, vb = a.value, b.value
        if va == nil or vb == nil then
            if (va == nil) == (vb == nil) then return a.order < b.order end
            return vb == nil
        end
        if va ~= vb then
            if desc then return va > vb end
            return va < vb
        end
        return a.order < b.order
    end)
    for i, k in ipairs(keyed) do rows[i] = k.row end
    return rows
end

-- opts: parent, key, width, justify ("LEFT" | "RIGHT"), getState() -> state table, onChange()
function ns.SortHeader(opts)
    local button = CreateFrame("Button", nil, opts.parent)
    button:SetSize(opts.width, 16)
    button:EnableMouse(true)
    button:RegisterForClicks("LeftButtonUp")
    local right = opts.justify == "RIGHT"
    local text = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint(right and "RIGHT" or "LEFT")
    text:SetJustifyH(right and "RIGHT" or "LEFT")
    text:SetWordWrap(false)
    local arrow = button:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture(ARROW)
    arrow:SetSize(9, 8)
    if right then arrow:SetPoint("RIGHT", text, "LEFT", -2, 0) else arrow:SetPoint("LEFT", text, "RIGHT", 2, 0) end
    arrow:Hide()

    function button:SetLabel(label) text:SetText(label) end
    function button:Refresh()
        local state = opts.getState()
        if state.key == opts.key then
            -- The file's arrow points down: flip it for ascending.
            if state.dir == "asc" then arrow:SetTexCoord(0, 0.5625, 1, 0) else arrow:SetTexCoord(0, 0.5625, 0, 1) end
            arrow:Show()
            text:SetTextColor(1, 1, 1)
        else
            arrow:Hide()
            text:SetTextColor(1, 0.82, 0)
        end
    end

    button:SetScript("OnClick", function(self, mouse)
        log.debug("Header %q clicked (%s)", opts.key, tostring(mouse))
        ns.SafeCall("SortHeader", function()
            local state = opts.getState()
            if state.key ~= opts.key then state.key, state.dir = opts.key, "asc"
            elseif state.dir == "asc" then state.dir = "desc"
            else state.key, state.dir = nil, nil end
            self:Refresh()
            opts.onChange()
        end)
    end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(text:GetText() or "")
        GameTooltip:AddLine("Click to sort: ascending, descending, then off.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return button
end
