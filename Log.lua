-- Log: leveled, timestamped action log persisted in its own SavedVariable (VendorPrinterLog).
-- Written to disk on /reload or logout:
--   _forever_/WTF/Account/<ACCOUNT>/SavedVariables/VendorPrinter.lua
local addonName, ns = ...

local LEVELS = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }
local LEVEL_NAMES = { "DEBUG", "INFO", "WARN", "ERROR" }
local LEVEL_COLORS = { DEBUG = "ff9090b0", INFO = "ffffffff", WARN = "ffffb040", ERROR = "ffff4040" }
local MAX_LINES = 5000

local pending = {}   -- lines logged before SavedVariables are loaded
local store = nil    -- VendorPrinterLog once loaded

-- string.format that never throws: non-string/number args become strings, bad formats are reported inline.
local function SafeFormat(fmt, ...)
    local n = select("#", ...)
    if n == 0 then return tostring(fmt) end
    local args = { ... }
    for i = 1, n do
        local v = args[i]
        if type(v) ~= "number" and type(v) ~= "string" then args[i] = tostring(v) end
    end
    local ok, result = pcall(string.format, fmt, unpack(args, 1, n))
    if ok then return result end
    return tostring(fmt) .. " [log format error: " .. tostring(result) .. "]"
end

local function Trim()
    local lines = store.lines
    if #lines > MAX_LINES + 500 then
        local keep = {}
        for i = #lines - MAX_LINES + 1, #lines do keep[#keep + 1] = lines[i] end
        store.lines = keep
    end
end

local function Timestamp()
    return ("%s.%03d"):format(date("%Y-%m-%d %H:%M:%S"), math.floor((GetTime() % 1) * 1000))
end

local function ColorLine(line)
    local level = line:match("^%S+ %S+ (%u+)")
    local color = LEVEL_COLORS[level] or "ffffffff"
    return "|c" .. color .. line .. "|r"
end

function ns.Log(level, module, fmt, ...)
    local value = LEVELS[level] or LEVELS.INFO
    local minimum = store and LEVELS[store.settings.level] or LEVELS.DEBUG
    if value < minimum then return end
    local line = ("%s %-5s [%s] %s"):format(Timestamp(), LEVEL_NAMES[value], module, SafeFormat(fmt, ...))
    if store then
        local lines = store.lines
        lines[#lines + 1] = line
        Trim()
        if store.settings.echo then print(ColorLine(line)) end
    else
        pending[#pending + 1] = line
    end
end

-- Per-module logger: local log = ns.Logger("Prices"); log.info("...%d", n)
function ns.Logger(module)
    return {
        debug = function(...) ns.Log("DEBUG", module, ...) end,
        info = function(...) ns.Log("INFO", module, ...) end,
        warn = function(...) ns.Log("WARN", module, ...) end,
        error = function(...) ns.Log("ERROR", module, ...) end,
    }
end

-- Run fn, logging any error with its stack, then hand the error to WoW's normal error display.
function ns.SafeCall(label, fn, ...)
    local n = select("#", ...)
    local args = { ... }
    local ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, function(e)
        local stack = debugstack and debugstack(2) or ""
        ns.Log("ERROR", label, "%s\n%s", tostring(e), stack)
        return e
    end)
    if not ok and geterrorhandler then geterrorhandler()(err) end
    return ok
end

-- Attach to the SavedVariable; called first thing in ADDON_LOADED.
function ns.InitLog()
    VendorPrinterLog = VendorPrinterLog or {}
    store = VendorPrinterLog
    store.lines = store.lines or {}
    store.settings = store.settings or {}
    store.settings.level = store.settings.level or "DEBUG"
    if store.settings.echo == nil then store.settings.echo = false end
    for _, line in ipairs(pending) do store.lines[#store.lines + 1] = line end
    pending = {}
    Trim()
end

---------------------------------------------------------------------------
-- /vp log ...
---------------------------------------------------------------------------
function ns.LogCommand(args)
    local sub, rest = (args or ""):match("^(%S*)%s*(.-)$")
    if sub == "" or tonumber(sub) then
        local count = tonumber(sub) or 20
        local lines = store.lines
        ns.Print("Last %d of %d log lines:", math.min(count, #lines), #lines)
        for i = math.max(1, #lines - count + 1), #lines do print(ColorLine(lines[i])) end
    elseif sub == "level" then
        local level = rest:upper()
        if LEVELS[level] then
            store.settings.level = level
            ns.Print("Log level set to %s.", level)
        else
            ns.Print("Log level is %s. Use /vp log level debug|info|warn|error.", store.settings.level)
        end
    elseif sub == "echo" then
        store.settings.echo = rest == "on" or (rest == "" and not store.settings.echo)
        ns.Print("Log echo to chat: %s.", store.settings.echo and "on" or "off")
    elseif sub == "clear" then
        wipe(store.lines)
        ns.Print("Log cleared.")
    else
        ns.Print("Log commands: /vp log [n] | /vp log level <debug|info|warn|error> | /vp log echo [on|off] | /vp log clear")
    end
end

function ns.LogStats()
    return store and #store.lines or #pending, store and store.settings.level or "DEBUG"
end
