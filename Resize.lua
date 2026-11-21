-- Resize: a drag grip in a window's bottom-right corner. The size is saved in `store` (a SavedVariables table)
-- and restored, clamped to the bounds, when the window is built.
local _, ns = ...

function ns.MakeResizable(frame, store, minW, minH, onResize)
    frame:SetResizable(true)
    local maxW, maxH = UIParent:GetWidth(), UIParent:GetHeight()
    if frame.SetResizeBounds then
        frame:SetResizeBounds(minW, minH, maxW, maxH)
    else -- clients before SetResizeBounds
        frame:SetMinResize(minW, minH)
        frame:SetMaxResize(maxW, maxH)
    end
    if store.w and store.h then
        frame:SetSize(math.max(minW, math.min(store.w, maxW)), math.max(minH, math.min(store.h, maxH)))
    end
    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -3, 3)
    grip:SetFrameLevel(frame:GetFrameLevel() + 10)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then frame:StartSizing("BOTTOMRIGHT") end
    end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        store.w, store.h = math.floor(frame:GetWidth() + 0.5), math.floor(frame:GetHeight() + 0.5)
    end)
    if onResize then frame:HookScript("OnSizeChanged", onResize) end
    return grip
end
