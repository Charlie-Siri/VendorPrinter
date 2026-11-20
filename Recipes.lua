-- Recipes: reads the open profession window (learned and unlearned recipes) into per-character data.
local _, ns = ...
local log = ns.Logger("Recipes")

local BASIC = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic

-- This scan reruns on every craft (TRADE_SKILL_LIST_UPDATE), so per-recipe lines are logged
-- only when something is new or changed, and skips only once per session.
local skipLogged = {}

local function CanScan()
    local T = C_TradeSkillUI
    if not (T and T.GetAllRecipeIDs and T.GetRecipeInfo and T.GetRecipeSchematic) then
        return false, "C_TradeSkillUI API missing"
    end
    -- Don't record someone else's profession (links, guild view, NPC crafting).
    if T.IsTradeSkillLinked and T.IsTradeSkillLinked() then return false, "linked profession (someone else's)" end
    if T.IsTradeSkillGuild and T.IsTradeSkillGuild() then return false, "guild profession view" end
    if T.IsNPCCrafting and T.IsNPCCrafting() then return false, "NPC crafting" end
    if T.IsTradeSkillReady and not T.IsTradeSkillReady() then return false, "profession data not ready yet" end
    return true
end

local function IsRequiredSlot(slot)
    if slot.required ~= nil then return slot.required end
    return BASIC == nil or slot.reagentType == BASIC
end

local function Skip(recipeID, name, reason)
    if not skipLogged[recipeID] then
        skipLogged[recipeID] = true
        log.debug("Recipe %d %q skipped: %s", recipeID, tostring(name), reason)
    end
    return nil
end

local function ReadRecipe(recipeID)
    local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
    if not info then return Skip(recipeID, nil, "no recipe info") end
    if info.isRecraft then return Skip(recipeID, info.name, "recraft") end
    if info.isDummyRecipe then return Skip(recipeID, info.name, "dummy recipe") end

    local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
    if not schematic then return Skip(recipeID, info.name, "no schematic") end
    -- Recipes without an item output (enchants, etc.) can't be sold to a vendor.
    if not schematic.outputItemID then return Skip(recipeID, info.name, "no item output (enchant/other)") end

    local reagents, optionalSlots = {}, 0
    for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
        if IsRequiredSlot(slot) and (slot.quantityRequired or 0) > 0 then
            local ids = {}
            for _, reagent in ipairs(slot.reagents or {}) do
                if reagent.itemID then ids[#ids + 1] = reagent.itemID end
            end
            if #ids > 0 then
                reagents[#reagents + 1] = { ids = ids, qty = slot.quantityRequired }
            end
        else
            optionalSlots = optionalSlots + 1
        end
    end

    local qmin = schematic.quantityMin or 1
    local recipe = {
        name = info.name,
        learned = info.learned and true or false,
        output = schematic.outputItemID,
        qmin = qmin,
        qmax = schematic.quantityMax or qmin,
        reagents = reagents,
        optionalSlots = optionalSlots,
    }
    if not recipe.learned and C_TradeSkillUI.GetRecipeSourceText then
        local ok, source = pcall(C_TradeSkillUI.GetRecipeSourceText, recipeID)
        if ok and source and source ~= "" then
            recipe.source = source
        elseif not ok then
            log.debug("GetRecipeSourceText(%d) failed: %s", recipeID, tostring(source))
        end
    end
    return recipe
end

local function DescribeReagents(recipe)
    local parts = {}
    for _, slot in ipairs(recipe.reagents) do
        parts[#parts + 1] = ("%dx %s"):format(slot.qty, table.concat(slot.ids, "/"))
    end
    return table.concat(parts, ", ")
end

function ns.ScanRecipes()
    local ok, reason = CanScan()
    if not ok then
        log.debug("Recipe scan skipped: %s", reason)
        return
    end
    local profInfo = C_TradeSkillUI.GetBaseProfessionInfo and C_TradeSkillUI.GetBaseProfessionInfo()
    local profName = profInfo and profInfo.professionName
    if not profName or profName == "" then
        log.debug("Recipe scan skipped: no profession name (GetBaseProfessionInfo=%s)", tostring(profInfo))
        return
    end

    local ids = C_TradeSkillUI.GetAllRecipeIDs()
    if not ids or #ids == 0 then
        log.debug("Recipe scan skipped: %s has no recipe IDs yet", profName)
        return
    end

    -- Merge rather than replace: the window may only expose part of the list (filters, expansion tiers).
    local prof = ns.char.professions[profName]
    if not prof then
        prof = { recipes = {} }
        ns.char.professions[profName] = prof
        log.info("New profession recorded: %s (skill %s/%s)", profName,
            tostring(profInfo.skillLevel), tostring(profInfo.maxSkillLevel))
    end
    prof.skillLineID = profInfo.professionID or prof.skillLineID   -- lets a row click open this window later
    local before = ns.CountKeys(prof.recipes)
    local learnedBefore = 0
    for _, recipe in pairs(prof.recipes) do
        if recipe.learned then learnedBefore = learnedBefore + 1 end
    end

    local read, added, newlyLearned = 0, 0, 0
    for _, recipeID in ipairs(ids) do
        local recipe = ReadRecipe(recipeID)
        if recipe then
            read = read + 1
            local old = prof.recipes[recipeID]
            if not old then
                added = added + 1
                log.debug("Recipe %d %q added: learned=%s output=%d x%d-%d reagents=[%s]%s", recipeID, recipe.name,
                    tostring(recipe.learned), recipe.output, recipe.qmin, recipe.qmax, DescribeReagents(recipe),
                    recipe.optionalSlots > 0 and (" (%d optional slots ignored)"):format(recipe.optionalSlots) or "")
            elseif recipe.learned and not old.learned then
                newlyLearned = newlyLearned + 1
                log.info("Recipe %d %q is now learned", recipeID, recipe.name)
            end
            prof.recipes[recipeID] = recipe
        end
    end
    prof.scanned = time()

    local count, learned = 0, 0
    for _, recipe in pairs(prof.recipes) do
        count = count + 1
        if recipe.learned then learned = learned + 1 end
    end
    local changed = count ~= before or learned ~= learnedBefore
    if changed or added > 0 then
        ns.recipesVersion = (ns.recipesVersion or 0) + 1   -- invalidates the tooltip's reagent usage index
    end
    ns.Log(changed and "INFO" or "DEBUG", "Recipes",
        "Scan %s: %d recipe IDs, %d with item output, %d added, %d newly learned -> %d stored (%d learned)",
        profName, #ids, read, added, newlyLearned, count, learned)
    if changed then
        ns.Print("%s: %d craftable-item recipes (%d learned).", profName, count, learned)
    end
    ns.Refresh()
end

---------------------------------------------------------------------------
-- Opening a recipe from the /vp window (row click)
---------------------------------------------------------------------------
-- Opens the profession window on the recipe. Must run from a click (the client wants a hardware event).
local pendingSelect = nil
function ns.OpenRecipe(recipeID, profName, recipeName)
    local T = C_TradeSkillUI
    if not (T and recipeID) then return false end
    if InCombatLockdown and InCombatLockdown() then
        ns.Print("Can't open the %s window in combat.", tostring(profName))
        return false
    end
    if T.OpenRecipe then
        local ok, err = pcall(T.OpenRecipe, recipeID)
        log.info("Open recipe %d %q (%s): %s", recipeID, tostring(recipeName), tostring(profName), ok and "ok" or tostring(err))
        if ok then return true end
    end
    -- Fallback: open the profession, then select the recipe once its list is ready.
    local prof = profName and ns.char.professions[profName]
    if prof and prof.skillLineID and T.OpenTradeSkill then
        pendingSelect = { id = recipeID, at = GetTime() }
        local ok, err = pcall(T.OpenTradeSkill, prof.skillLineID)
        log.info("Open %s (skill line %d) for recipe %d: %s", profName, prof.skillLineID, recipeID, ok and "ok" or tostring(err))
        if ok then return true end
    end
    ns.Print("Open your %s window to see %s (the game didn't let the addon open it).", tostring(profName), tostring(recipeName))
    return false
end

local function SelectPending()
    local p = pendingSelect
    if not p or GetTime() - p.at > 5 then pendingSelect = nil return end
    pendingSelect = nil
    local T = C_TradeSkillUI
    if T.OpenRecipe then
        local ok = pcall(T.OpenRecipe, p.id)
        log.debug("Selected recipe %d after the window opened: %s", p.id, ok and "ok" or "failed")
    end
end

local function QueueScan(event)
    ns.Debounce("recipes", 0.5, ns.ScanRecipes)
end

ns.On("TRADE_SKILL_SHOW", QueueScan)
ns.On("TRADE_SKILL_LIST_UPDATE", QueueScan)
ns.On("TRADE_SKILL_LIST_UPDATE", function() if pendingSelect then SelectPending() end end)
ns.On("TRADE_SKILL_DATA_SOURCE_CHANGED", QueueScan)
ns.On("TRADE_SKILL_CLOSE", function() log.debug("Profession window closed") end)
