local ADDON = ...

local DEFAULTS = {
    buffFood = false, -- allow Well Fed food in the eat macro
    healthstone = true, -- use a healthstone from the eat macro in combat
}

local KINDS = {
    { key = "eat", macro = "BR Eat", empty = "no food" },
    { key = "drink", macro = "BR Drink", empty = "no drink" },
    { key = "bandage", macro = "BR Bandage", empty = "no usable bandage" },
}

local MAX_ACCOUNT_MACROS = 120 -- the global of this name is missing on this client
local QUESTION_MARK_ICON = 134400 -- with #showtooltip the macro shows the item's own icon

local db

local perf = { scans = 0, edits = 0, last = 0, lastKB = 0, lastReason = "", slowest = 0, slowestReason = "" }

local function Print(msg)
    print("|cff33ff99BetterRations|r: " .. msg)
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
---@field wellFed boolean
---@field conjured boolean

local itemCache = {} ---@type table<number, BRItemInfo>

local function Number(s)
    return s and tonumber((s:gsub(",", ""))) or 0
end

local function ParseItem(bag, slot)
    local data = C_TooltipInfo.GetBagItem(bag, slot)
    if not data or not data.lines then return nil end
    local parts = {}
    for _, l in ipairs(data.lines) do
        if l.leftText then parts[#parts + 1] = l.leftText end
    end
    local text = table.concat(parts, "\n")
    local info = { health = 0, mana = 0, bandage = 0, healthstone = 0, wellFed = false, conjured = false }
    -- Food and drink require sitting; this keeps potions and healthstones out.
    if text:find("seated") then
        info.health = Number(text:match("Restores ([%d%.,]+) health"))
        info.mana = Number(text:match("([%d%.,]+) mana"))
        info.wellFed = text:lower():find("well fed") ~= nil
    end
    info.bandage = Number(text:match("Heals ([%d%.,]+) damage over"))
    if parts[1] and parts[1]:find("Healthstone") then
        info.healthstone = Number(text:match("[Rr]estores ([%d%.,]+)"))
    end
    for _, l in ipairs(parts) do
        if l == ITEM_CONJURED then info.conjured = true end
    end
    return info
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

local function ScanBags()
    wipe(best)
    local counts = {} -- total count per itemID across stacks
    local seen = {}
    for bag = 0, NUM_BAG_SLOTS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local item = C_Container.GetContainerItemInfo(bag, slot)
            if item and item.itemID then
                local id = item.itemID
                counts[id] = (counts[id] or 0) + item.stackCount
                if itemCache[id] == nil then
                    itemCache[id] = ParseItem(bag, slot) or nil
                end
                if itemCache[id] then seen[id] = true end
            end
        end
    end
    for id in pairs(seen) do
        local info = itemCache[id]
        -- IsUsableItem covers the level requirement and First Aid skill.
        if C_Item.IsUsableItem(id) then
            for _, key in ipairs({ "eat", "drink", "bandage", "healthstone" }) do
                local amount = Amount(key, info)
                if amount > 0 then
                    local c = { itemID = id, amount = amount, conjured = info.conjured, count = counts[id] }
                    if not best[key] or Better(c, best[key]) then best[key] = c end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Macros (account-wide). Macros can't be edited in combat.
---------------------------------------------------------------------------
local dirty = false

local function SetMacro(name, body)
    local index = GetMacroIndexByName(name)
    if index == 0 then
        local accountMacros = GetNumMacros()
        if accountMacros >= MAX_ACCOUNT_MACROS then
            Print("no free account macro slot for " .. name)
            return
        end
        CreateMacro(name, QUESTION_MARK_ICON, body, nil)
        perf.edits = perf.edits + 1
    elseif GetMacroBody(index) ~= body then
        EditMacro(index, name, QUESTION_MARK_ICON, body)
        perf.edits = perf.edits + 1
    end
end

local function Update(reason)
    if InCombatLockdown() then
        dirty = true
        return
    end
    dirty = false
    local t0, kb0 = debugprofilestop(), collectgarbage("count")
    ScanBags()
    for _, k in ipairs(KINDS) do
        local b = best[k.key]
        local body
        local hs = k.key == "eat" and db.healthstone and best.healthstone
        if hs and b then
            body = ("#showtooltip\n/use [combat] item:%d; item:%d"):format(hs.itemID, b.itemID)
        elseif hs then
            body = "#showtooltip\n/use item:" .. hs.itemID
        elseif b then
            body = "#showtooltip\n/use item:" .. b.itemID
        else
            body = ("/run print(\"|cff33ff99BetterRations|r: %s\")"):format(k.empty)
        end
        SetMacro(k.macro, body)
    end
    local ms = debugprofilestop() - t0
    perf.scans = perf.scans + 1
    perf.last, perf.lastKB, perf.lastReason = ms, collectgarbage("count") - kb0, reason
    if ms > perf.slowest then perf.slowest, perf.slowestReason = ms, reason end
end

-- Bag events come in bursts; update once shortly after.
local pending = false
local function RequestUpdate(reason)
    if pending then return end
    pending = true
    C_Timer.After(0.5, function()
        pending = false
        Update(reason)
    end)
end

local function LevelUpdate()
    RequestUpdate("PLAYER_LEVEL_UP")
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
    elseif cmd == "options" or cmd == "config" then
        Settings.OpenToCategory(settingsCategory:GetID())
    elseif cmd == "perf" then
        if arg == "reset" then
            perf.scans, perf.edits, perf.slowest, perf.slowestReason = 0, 0, 0, ""
        end
        local cached = 0
        for _ in pairs(itemCache) do cached = cached + 1 end
        UpdateAddOnMemoryUsage()
        Print(("memory %.1f KB, %d items cached, %d scans, %d macro edits"):format(
            GetAddOnMemoryUsage(ADDON), cached, perf.scans, perf.edits))
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
            if b then
                local link = select(2, C_Item.GetItemInfo(b.itemID)) or ("item " .. b.itemID)
                Print(("%s: %s (%s, %d in bags)"):format(k.macro, link, b.amount, b.count))
            else
                Print(k.macro .. ": " .. k.empty)
            end
        end
    else
        Print("commands:")
        print("  /br - show the chosen items")
        print("  /br options - open the settings")
        print("  /br perf - scan count, timing and memory; add reset to zero the counters")
        print("  /br buff - toggle Well Fed food in BR Eat (now " .. (db.buffFood and "on" or "off") .. ")")
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, event, arg1)
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
            "SKILL_LINES_CHANGED", "PLAYER_REGEN_ENABLED",
        }) do
            frame:RegisterEvent(e)
        end
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        if dirty then Update(event) end
        return
    end
    if event == "PLAYER_LEVEL_UP" then
        -- Usability can lag the level change by a moment.
        C_Timer.After(1, LevelUpdate)
        return
    end
    RequestUpdate(event)
end)
