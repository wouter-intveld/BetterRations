local ADDON, ns = ...

local DEFAULTS = {
    buffFood = false, -- allow Well Fed food in the eat macro
    healthstone = true, -- use a healthstone from the eat macro in combat
    potions = false, -- healing potion in BR Eat and mana potion in BR Drink, in combat
}

local KINDS = {
    -- placeholder: an item whose icon the empty macro shows
    { key = "eat", macro = "BR Eat", empty = "no food", placeholder = 4540 }, -- Tough Hunk of Bread
    { key = "drink", macro = "BR Drink", empty = "no drink", placeholder = 159 }, -- Refreshing Spring Water
    { key = "bandage", macro = "BR Bandage", empty = "no usable bandage", placeholder = 1251 }, -- Linen Bandage
}

-- Keys of best: the things a bag item can be good for.
local PICKS = { "eat", "drink", "bandage", "healthstone", "healthPotion", "manaPotion" }

local MAX_ACCOUNT_MACROS = 120 -- the global of this name is missing on this client
local QUESTION_MARK_ICON = 134400 -- with #showtooltip the macro shows the item's own icon

local db

local perf = { scans = 0, edits = 0, last = 0, lastKB = 0, lastReason = "", slowest = 0, slowestReason = "" }

local function Print(msg)
    print("|cff33ff99BetterRations|r: " .. msg)
end

local function Link(itemID)
    return select(2, C_Item.GetItemInfo(itemID)) or ("item " .. itemID)
end

---------------------------------------------------------------------------
-- Item classification, parsed once per itemID from the item tooltip.
-- English tooltip text only for now.
---------------------------------------------------------------------------
---@class BRItemInfo
---@field health number
---@field mana number
---@field bandage number
---@field healthstone number
---@field healthPotion number
---@field manaPotion number
---@field wellFed boolean
---@field conjured boolean

-- false marks an item with nothing to offer; nil means not parsed yet.
local itemCache = {} ---@type table<number, BRItemInfo|false>
local awaiting = {} -- item IDs whose data was requested from the server
local awaitingSpell = {} -- spell IDs of item use effects requested from the server

local function Number(s)
    return s and tonumber((s:gsub(",", ""))) or 0
end

-- From Data.lua, generated from the game's own data: works in every language.
---@return BRItemInfo|nil
local function FromData(id)
    local d = ns.DATA[id]
    if not d then return nil end
    return {
        health = d[1], mana = d[2], bandage = d[3], healthstone = d[4], healthPotion = d[5], manaPotion = d[6],
        wellFed = d[7], conjured = d[8],
    }
end

-- Fallback for items Data.lua does not know, from the English tooltip.
---@return BRItemInfo|false|nil info false when the item has no use, nil when its data is not loaded yet
local function ParseTooltip(id, bag, slot)
    if not C_Item.IsItemDataCachedByID(id) then
        -- The tooltip would only say "Retrieving item information".
        awaiting[id] = true
        C_Item.RequestLoadItemDataByID(id)
        return nil
    end
    -- Recipes quote the tooltip of what they make, so judge by item class first.
    if select(6, C_Item.GetItemInfoInstant(id)) ~= Enum.ItemClass.Consumable then return false end
    -- After a cold start the "Use:" line stays missing until the item's spell
    -- is loaded, and the client does not load it by itself.
    local _, spellID = C_Item.GetItemSpell(id)
    if spellID and not C_Spell.IsSpellDataCached(spellID) then
        awaitingSpell[spellID] = true
        C_Spell.RequestLoadSpellData(spellID)
        return nil
    end
    local data = C_TooltipInfo.GetBagItem(bag, slot)
    if not data or not data.lines then return nil end
    local parts = {}
    for _, l in ipairs(data.lines) do
        if l.leftText then parts[#parts + 1] = l.leftText end
    end
    local text = table.concat(parts, "\n")
    local info = {
        health = 0, mana = 0, bandage = 0, healthstone = 0, healthPotion = 0, manaPotion = 0,
        wellFed = false, conjured = false,
    }
    local name = parts[1] or ""
    -- Food and drink require sitting; this keeps potions and healthstones out.
    if text:find("seated") then
        info.health = Number(text:match("Restores ([%d%.,]+) health"))
        info.mana = Number(text:match("([%d%.,]+) mana"))
        info.wellFed = text:lower():find("well fed") ~= nil
    elseif name:find("Healthstone") then
        info.healthstone = Number(text:match("[Rr]estores ([%d%.,]+)"))
    elseif name:find("Potion") then
        -- Potions restore a range; rank them by the low end.
        info.healthPotion = Number(text:match("Restores ([%d%.,]+) to [%d%.,]+ health"))
        info.manaPotion = Number(text:match("Restores ([%d%.,]+) to [%d%.,]+ mana"))
    end
    info.bandage = Number(text:match("Heals ([%d%.,]+) damage over"))
    for _, l in ipairs(parts) do
        if l == ITEM_CONJURED then info.conjured = true end
    end
    if info.health == 0 and info.mana == 0 and info.bandage == 0 and info.healthstone == 0
        and info.healthPotion == 0 and info.manaPotion == 0 then
        return false
    end
    return info
end

---@return BRItemInfo|false|nil
local function ParseItem(id, bag, slot)
    return FromData(id) or ParseTooltip(id, bag, slot)
end

---------------------------------------------------------------------------
-- Picking the best item per kind
---------------------------------------------------------------------------
local function Amount(kind, info)
    if kind == "eat" then
        if info.wellFed and not db.buffFood then return 0 end
        return info.health
    elseif kind == "drink" then
        return info.mana
    elseif kind == "healthstone" then
        return info.healthstone
    elseif kind == "healthPotion" then
        return db.potions and info.healthPotion or 0
    elseif kind == "manaPotion" then
        return db.potions and info.manaPotion or 0
    end
    return info.bandage
end

-- Best = most restored; at equal strength conjured wins (it vanishes on
-- logout anyway), then the smallest stack.
local function Better(a, b)
    if a.amount ~= b.amount then return a.amount > b.amount end
    if a.conjured ~= b.conjured then return a.conjured end
    return a.count < b.count
end

local best = {}
local seen = {} ---@type table<number, BRItemInfo> consumables in the bags right now
local unresolved = 0 -- items the last scan could not read yet

local function ScanBags()
    wipe(best)
    wipe(seen)
    unresolved = 0
    for bag = 0, NUM_BAG_SLOTS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local id = C_Container.GetContainerItemID(bag, slot)
            if id then
                local info = itemCache[id] ---@type BRItemInfo|false|nil
                if info == nil then
                    info = ParseItem(id, bag, slot)
                    itemCache[id] = info
                    if info == nil then unresolved = unresolved + 1 end
                end
                if info then seen[id] = info end
            end
        end
    end
    for id, info in pairs(seen) do
        -- IsUsableItem covers the level requirement and First Aid skill.
        if C_Item.IsUsableItem(id) then
            local count = C_Item.GetItemCount(id)
            for _, key in ipairs(PICKS) do
                local amount = Amount(key, info)
                if amount > 0 then
                    local c = { itemID = id, amount = amount, conjured = info.conjured, count = count }
                    if not best[key] or Better(c, best[key]) then best[key] = c end
                end
            end
        end
    end
end

-- What the macro uses in combat instead of food or drink: up to two items.
-- With two, the macro steps through them, healthstone first, then potion.
local function CombatItems(key)
    if key == "eat" then
        local stone = db.healthstone and best.healthstone or nil
        local potion = db.potions and best.healthPotion or nil
        return stone or potion, stone and potion or nil
    elseif key == "drink" then
        return db.potions and best.manaPotion or nil, nil
    end
    return nil, nil
end

---------------------------------------------------------------------------
-- Macros (account-wide). Macros can't be edited in combat.
---------------------------------------------------------------------------
local dirty = false

-- icon is only given for empty macros; filled ones show their item via #showtooltip.
local function SetMacro(name, body, icon)
    local index = GetMacroIndexByName(name)
    if index == 0 then
        local accountMacros = GetNumMacros()
        if accountMacros >= MAX_ACCOUNT_MACROS then
            Print("no free account macro slot for " .. name)
            return
        end
        CreateMacro(name, icon or QUESTION_MARK_ICON, body, nil)
        perf.edits = perf.edits + 1
        return
    end
    local _, storedIcon, storedBody = GetMacroInfo(index)
    -- The client stores bodies with a trailing newline; compare without it.
    if storedBody:gsub("%s+$", "") ~= body or (icon and storedIcon ~= icon) then
        EditMacro(index, name, icon or QUESTION_MARK_ICON, body)
        perf.edits = perf.edits + 1
    end
end

-- A freshly crafted or looted item can be unreadable for a moment (its data
-- or its spell not loaded yet). A scan that hit one is retried a few times.
local RETRIES = 3
local retriesLeft = 0
local Retry -- defined after Update; they call each other

local function Update(reason)
    -- No macro edits in combat, and on a flight path or while dead items are
    -- not usable, so a scan there would empty the macros. They run afterwards.
    if InCombatLockdown() or UnitOnTaxi("player") or UnitIsDeadOrGhost("player") then
        dirty = true
        return
    end
    dirty = false
    if reason ~= "retry" then retriesLeft = RETRIES end
    local t0, kb0 = debugprofilestop(), collectgarbage("count")
    ScanBags()
    -- The client does not redraw a macro's icon when combat starts, so [combat]
    -- icons stay on the out-of-combat item. Entering combat, which fires just
    -- before macros lock, swaps in combat-only bodies; leaving combat restores.
    local entering = reason == "PLAYER_REGEN_DISABLED"
    for _, k in ipairs(KINDS) do
        local b = best[k.key]
        local c1, c2 = CombatItems(k.key)
        local body
        -- Without food or drink the combat items stay combat-only; out of combat
        -- the macro says what is missing instead of spending a healthstone.
        local missing = ("/run if not InCombatLockdown() then print(\"|cff33ff99BetterRations|r: %s\") end"):format(k.empty)
        if entering and c1 and c2 then
            body = ("#showtooltip\n/castsequence reset=combat item:%d, item:%d"):format(c1.itemID, c2.itemID)
        elseif entering and c1 then
            body = "#showtooltip\n/use item:" .. c1.itemID
        elseif c1 and c2 and b then
            body = ("#showtooltip\n/castsequence [combat] reset=combat item:%d, item:%d; item:%d"):format(
                c1.itemID, c2.itemID, b.itemID)
        elseif c1 and c2 then
            body = ("#showtooltip [combat] item:%d; item:%d\n/castsequence [combat] reset=combat item:%d, item:%d\n%s"):format(
                c1.itemID, k.placeholder, c1.itemID, c2.itemID, missing)
        elseif c1 and b then
            body = ("#showtooltip\n/use [combat] item:%d; item:%d"):format(c1.itemID, b.itemID)
        elseif c1 then
            body = ("#showtooltip [combat] item:%d; item:%d\n/use [combat] item:%d\n%s"):format(
                c1.itemID, k.placeholder, c1.itemID, missing)
        elseif b then
            body = "#showtooltip\n/use item:" .. b.itemID
        else
            body = ("/run print(\"|cff33ff99BetterRations|r: %s\")"):format(k.empty)
        end
        -- A fixed icon would override #showtooltip, so only a fully empty macro gets one;
        -- a combat-only macro names the placeholder in its #showtooltip line instead.
        local icon = not (b or c1) and C_Item.GetItemIconByID(k.placeholder) or nil
        SetMacro(k.macro, body, icon)
    end
    if entering then dirty = true end -- restore the normal bodies after the fight
    local ms = debugprofilestop() - t0
    perf.scans = perf.scans + 1
    perf.last, perf.lastKB, perf.lastReason = ms, collectgarbage("count") - kb0, reason
    if ms > perf.slowest then perf.slowest, perf.slowestReason = ms, reason end
    if unresolved > 0 and retriesLeft > 0 then
        retriesLeft = retriesLeft - 1
        C_Timer.After(1, Retry)
    end
end

function Retry()
    Update("retry")
end

-- Bag events come in bursts; update once shortly after.
local pending, pendingReason = false, ""

local function RunPending()
    pending = false
    Update(pendingReason)
end

local function RequestUpdate(reason)
    if pending then return end
    pending, pendingReason = true, reason
    C_Timer.After(0.5, RunPending)
end


---------------------------------------------------------------------------
-- Settings panel
---------------------------------------------------------------------------
local settingsCategory

local function RegisterSettings()
    local category = Settings.RegisterVerticalLayoutCategory("|cff33ff99Better|rRations")
    local function Checkbox(key, name, tooltip)
        local setting = Settings.RegisterProxySetting(category, "BR_" .. key, Settings.VarType.Boolean, name,
            DEFAULTS[key], function() return db[key] end, function(value)
                db[key] = value
                Update("settings")
            end)
        Settings.CreateCheckbox(category, setting, tooltip)
    end
    Checkbox("buffFood", "Buff food in BR Eat",
        "Let BR Eat use food that makes you Well Fed. Off keeps buff food for when you want the buff.")
    Checkbox("healthstone", "Healthstone in combat",
        "In combat, BR Eat uses your best healthstone instead of food.")
    Checkbox("potions", "Potions in combat",
        "In combat, BR Eat uses your best healing potion (after a healthstone, if you have one) and BR Drink your best mana potion.")
    Settings.RegisterAddOnCategory(category)
    settingsCategory = category
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_BETTERRATIONS1 = "/br"
SLASH_BETTERRATIONS2 = "/betterrations"
SlashCmdList.BETTERRATIONS = function(msg)
    local cmd, arg = (msg or ""):lower():match("^(%S*)%s*(%S*)")
    if cmd == "buff" then
        db.buffFood = not db.buffFood
        Print("buff food in BR Eat " .. (db.buffFood and "on" or "off"))
        Update("buff")
    elseif cmd == "potions" then
        db.potions = not db.potions
        Print("potions in combat " .. (db.potions and "on" or "off"))
        Update("potions")
    elseif cmd == "options" or cmd == "config" then
        Settings.OpenToCategory(settingsCategory:GetID())
    elseif cmd == "perf" then
        if arg == "reset" then
            perf.scans, perf.edits, perf.slowest, perf.slowestReason = 0, 0, 0, ""
        end
        local cached, useful = 0, 0
        for _, v in pairs(itemCache) do
            cached = cached + 1
            if v then useful = useful + 1 end
        end
        UpdateAddOnMemoryUsage()
        Print(("memory %.1f KB, %d items cached (%d consumables, %d unresolved), %d scans, %d macro edits"):format(
            GetAddOnMemoryUsage(ADDON), cached, useful, unresolved, perf.scans, perf.edits))
        Print(("scan: last %.2f ms / %.1f KB (%s), slowest %.2f ms (%s)"):format(
            perf.last, perf.lastKB, perf.lastReason, perf.slowest, perf.slowestReason))
        if C_AddOnProfiler.IsEnabled() then
            local metric = Enum.AddOnProfilerMetric
            Print(("cpu recent avg %.3f ms/frame, peak %.3f ms"):format(
                C_AddOnProfiler.GetAddOnMetric(ADDON, metric.RecentAverageTime),
                C_AddOnProfiler.GetAddOnMetric(ADDON, metric.PeakTime)))
        end
    elseif cmd == "" or cmd == "status" then
        Update("status")
        for _, k in ipairs(KINDS) do
            local b = best[k.key]
            local c1, c2 = CombatItems(k.key)
            if b then
                Print(("%s: %s (%s, %d in bags)"):format(k.macro, Link(b.itemID), b.amount, b.count))
            else
                Print(k.macro .. ": " .. k.empty)
            end
            if c1 then
                local line = ("%s in combat: %s (%s, %d in bags)"):format(k.macro, Link(c1.itemID), c1.amount, c1.count)
                if c2 then
                    line = line .. (", then %s (%s, %d in bags)"):format(Link(c2.itemID), c2.amount, c2.count)
                end
                Print(line)
            end
        end
    else
        Print("commands:")
        print("  /br - show the chosen items")
        print("  /br options - open the settings")
        print("  /br perf - scan count, timing and memory; add reset to zero the counters")
        print("  /br buff - toggle Well Fed food in BR Eat (now " .. (db.buffFood and "on" or "off") .. ")")
        print("  /br potions - toggle potions in combat (now " .. (db.potions and "on" or "off") .. ")")
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        BetterRationsDB = BetterRationsDB or {}
        db = BetterRationsDB
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then db[k] = v end
        end
        frame:UnregisterEvent("ADDON_LOADED")
        RegisterSettings()
        for _, e in ipairs({
            "PLAYER_ENTERING_WORLD", "BAG_UPDATE_DELAYED", "PLAYER_LEVEL_UP",
            "SKILL_LINES_CHANGED", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "PLAYER_CONTROL_GAINED",
            "PLAYER_ALIVE", "PLAYER_UNGHOST",
            "ITEM_DATA_LOAD_RESULT", "SPELL_DATA_LOAD_RESULT",
        }) do
            frame:RegisterEvent(e)
        end
        return
    end
    if event == "ITEM_DATA_LOAD_RESULT" then
        -- Other addons request item data too; only act on our own requests.
        if awaiting[arg1] then
            awaiting[arg1] = nil
            if arg2 then RequestUpdate(event) else itemCache[arg1] = false end
        end
        return
    end
    if event == "SPELL_DATA_LOAD_RESULT" then
        if awaitingSpell[arg1] then
            awaitingSpell[arg1] = nil
            RequestUpdate(event)
        end
        return
    end
    if event == "PLAYER_REGEN_DISABLED" then
        Update(event) -- immediately: a debounced update would land after the lock
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        if dirty then Update(event) end
        return
    end
    if event == "PLAYER_ENTERING_WORLD" and arg1 then
        -- On a cold login, items can read as unusable for a few seconds
        -- (level and skills not known yet); scan again once that settles.
        C_Timer.After(5, function() RequestUpdate("login") end)
    end
    if event == "PLAYER_LEVEL_UP" or event == "PLAYER_CONTROL_GAINED"
        or event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        -- Usability lags a level-up, landing and coming back to life by a moment.
        C_Timer.After(1, function() RequestUpdate(event) end)
        return
    end
    RequestUpdate(event)
end)
