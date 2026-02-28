-- ====================================================================
-- ROGUE ROTATION ADDON  (1.12 / SuperWoW / NamPower)
-- ====================================================================

-- ====================================================================
-- 1. CONSTANTS
-- ====================================================================

local ADDON_PREFIX       = "|cff00ff88[RR]|r "
local HUGE               = 999999   -- Lua 5.0 has no math.huge

local ENERGY_TICK        = 20
local ENERGY_TICK_TIME   = 2.0
local ENERGY_DEFAULT_MAX = 100

-- Buff emergency threshold: must refresh within this many seconds.
local REFRESH_EMERGENCY  = 1.0

-- TfB duration threshold: above this we prefer Eviscerate over Rupture.
-- Below this we hold 5 CP and sync Rupture with the soonest 1CP buff expiry.
local TFB_EVIS_THRESHOLD = 9.0

local SPELL_IDS = {
    ["Noxious Assault"] = 52714,
    ["Envenom"]         = 52531,
    ["Slice and Dice"]  = 5171,
    ["Rupture"]         = 1943,
    ["Eviscerate"]      = 2098,
    ["Backstab"]        = 53,
    ["Surprise Attack"] = 11,
}

local SPELL_COST_FALLBACK = {
    ["Noxious Assault"] = 45,
    ["Envenom"]         = 20,
    ["Slice and Dice"]  = 20,
    ["Rupture"]         = 20,
    ["Eviscerate"]      = 30,
    ["Backstab"]        = 60,
    ["Surprise Attack"] = 10,
}

local TRACKED_BUFF_ICONS = {
    ["Slice and Dice"]  = "Interface\\Icons\\Ability_Rogue_SliceDice",
    ["Taste for Blood"] = "Interface\\Icons\\INV_Misc_Bone_09",
    ["Envenom"]         = "Interface\\Icons\\INV_Sword_31",
}

-- ====================================================================
-- 2. STATE
-- ====================================================================

local AtkSpell             = nil
local SpellCostCache       = {}
local TASTE_FOR_BLOOD_RANK = 0
local CRIT_SOURCE          = "fallback"
local CRIT_CACHE_VALUE     = nil
local CRIT_CACHE_TIME      = -999
local CRIT_CACHE_TTL       = 60

local BuffDurations = {
    ["Slice and Dice"]  = 0,
    ["Taste for Blood"] = 0,
    ["Envenom"]         = 0,
}

-- ====================================================================
-- 3. UTILITY
-- ====================================================================

local function rrPrint(msg)
    DEFAULT_CHAT_FRAME:AddMessage(ADDON_PREFIX .. tostring(msg))
end

-- ====================================================================
-- 4. SPELL COST
-- ====================================================================

local function ScanSpellCostFromTooltip(spellName)
    local scanner = getglobal("RR_CostScanner")
    if not scanner then
        scanner = CreateFrame("GameTooltip", "RR_CostScanner", nil, "GameTooltipTemplate")
    end
    scanner:SetOwner(WorldFrame, "ANCHOR_NONE")
    local i = 1
    while true do
        local name = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then break end
        if name == spellName then
            scanner:ClearLines()
            scanner:SetSpell(i, BOOKTYPE_SPELL)
            for line = 1, 6 do
                local region = getglobal("RR_CostScannerTextLeft" .. line)
                if region then
                    local text = region:GetText()
                    if text then
                        local cost = string.match(text, "(%d+) Energy")
                        if cost then return tonumber(cost) end
                    end
                end
            end
            return nil
        end
        i = i + 1
    end
    return nil
end

local function GetSpellCost(spellName)
    if SpellCostCache[spellName] then return SpellCostCache[spellName] end
    local cost = nil
    if GetSpellRecField and SPELL_IDS[spellName] then
        local raw = GetSpellRecField(SPELL_IDS[spellName], "manaCost")
        if raw and raw > 0 then cost = raw end
    end
    if not cost then cost = ScanSpellCostFromTooltip(spellName) end
    if not cost then cost = SPELL_COST_FALLBACK[spellName] or 0 end
    SpellCostCache[spellName] = cost
    return cost
end

local function InvalidateSpellCostCache()
    SpellCostCache = {}
end

-- ====================================================================
-- 5. ENERGY MODEL
-- ====================================================================

local function GetMaxEnergy()
    local raw = UnitManaMax("player")
    return (raw and raw > 0) and raw or ENERGY_DEFAULT_MAX
end

-- ====================================================================
-- 6. CRIT / CP MODEL  (cached 60s)
-- ====================================================================

local function DetectMeleeCritRate()
    if GetSpellModifiers then
        local flat, pct, hasAny = GetSpellModifiers(6603, 7)
        if pct and pct > 0 and pct < 95 then
            CRIT_SOURCE = "GetSpellModifiers(" .. string.format("%.1f", pct) .. "%)"
            return pct / 100
        end
    end
    do
        local scanner = getglobal("RR_CritScanner")
        if not scanner then
            scanner = CreateFrame("GameTooltip", "RR_CritScanner", nil, "GameTooltipTemplate")
        end
        scanner:SetOwner(WorldFrame, "ANCHOR_NONE")
        local total = 0
        for tab = 1, GetNumSpellTabs() do
            local _, _, offset, numSpells = GetSpellTabInfo(tab)
            for spell = 1, numSpells do
                scanner:ClearLines()
                scanner:SetSpell(spell + offset, BOOKTYPE_SPELL)
                local n = scanner:NumLines()
                if n then
                    for line = 1, n do
                        local r = getglobal("RR_CritScannerTextLeft" .. line)
                        if r then
                            local t = r:GetText()
                            if t then
                                local _, _, v = strfind(t, "([%d%.]+)%% chance to crit")
                                if v then total = total + tonumber(v); break end
                            end
                        end
                    end
                end
            end
        end
        if total > 0 and total < 95 then
            CRIT_SOURCE = "tooltip(" .. string.format("%.1f", total) .. "%)"
            return total / 100
        end
    end
    if GetCritChance then
        local v = GetCritChance()
        if v and v > 0 and v < 95 then CRIT_SOURCE = "GetCritChance()"; return v / 100 end
    end
    if GetUnitStat then
        local a = GetUnitStat("player", 2)
        if a and a > 0 then CRIT_SOURCE = "GetUnitStat(agi)"; return (a / 29) / 100 end
    end
    CRIT_SOURCE = "fallback(5%)"
    return 0.05
end

local function GetMeleeCritRate()
    local now = GetTime()
    if CRIT_CACHE_VALUE and (now - CRIT_CACHE_TIME) < CRIT_CACHE_TTL then
        return CRIT_CACHE_VALUE
    end
    local rate = DetectMeleeCritRate()
    CRIT_CACHE_VALUE = rate
    CRIT_CACHE_TIME  = now
    return rate
end

local function InvalidateCritCache()
    CRIT_CACHE_VALUE = nil
    CRIT_CACHE_TIME  = -999
end

local function GetExpectedCPPerCast()
    return 1.0 + GetMeleeCritRate()
end

-- ====================================================================
-- 7. BUFF TRACKER
-- ====================================================================

local function UpdateBuffDurations()
    for k in pairs(BuffDurations) do BuffDurations[k] = 0 end
    for i = 0, 29 do
        local icon = GetPlayerBuffTexture(i)
        if icon then
            local t = GetPlayerBuffTimeLeft(i) or 0
            for name, path in pairs(TRACKED_BUFF_ICONS) do
                if icon == path then BuffDurations[name] = t end
            end
        end
    end
end

-- ====================================================================
-- 8. ATTACK HELPERS
-- ====================================================================

local function findAttackSpell()
    AtkSpell = nil
    for slot = 1, 108 do
        if IsAttackAction(slot) then AtkSpell = slot; return end
    end
end

local function startAttack()
    if not AtkSpell then findAttackSpell() end
    if AtkSpell and not IsCurrentAction(AtkSpell) then UseAction(AtkSpell) end
end

local function stopAttack()
    if AtkSpell and IsCurrentAction(AtkSpell) then UseAction(AtkSpell) end
end

local function StartOrContinueAttack()
    startAttack()
    if UnitExists("target") and UnitCanAttack("player", "target") then
        if not AtkSpell or not IsCurrentAction(AtkSpell) then AttackTarget() end
    end
end

local function CheckPoison()
    local hasMain, _, chargesMain, _, hasOff, chargesOff = GetWeaponEnchantInfo()
    if not hasMain or (chargesMain and chargesMain < 15)
    or not hasOff  or (chargesOff  and chargesOff  < 15) then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff2020" .. ADDON_PREFIX .. "WARNING: Poison low!|r")
    end
end

-- ====================================================================
-- 9. TALENT DETECTION
-- ====================================================================

local function InitializeTalentRank()
    for tab = 1, GetNumTalentTabs() do
        for i = 1, GetNumTalents(tab) do
            local name, _, _, _, rank = GetTalentInfo(tab, i)
            if name == "Taste for Blood" then TASTE_FOR_BLOOD_RANK = rank or 0; return end
        end
    end
    TASTE_FOR_BLOOD_RANK = 0
end

-- ====================================================================
-- 10. MAIN ROTATION
-- ====================================================================

local function RogueRotation()
    CheckPoison()

    if not UnitExists("target") or UnitIsDead("target") then
        TargetNearestEnemy()
        if not UnitExists("target") or UnitIsDead("target") then return end
    end
    StartOrContinueAttack()

    local cp        = GetComboPoints("player", "target") or 0
    local energy    = UnitMana("player") or 0
    local maxEnergy = GetMaxEnergy()

    -- Buffer: 10 energy from max (e.g. 90/100)
    local effectiveMax = maxEnergy - 10
    local atCap        = energy >= effectiveMax

    UpdateBuffDurations()
    local envTime   = BuffDurations["Envenom"]         or 0
    local sndTime   = BuffDurations["Slice and Dice"]  or 0
    local tasteTime = BuffDurations["Taste for Blood"] or 0

    local costEnv  = GetSpellCost("Envenom")
    local costSnd = GetSpellCost("Slice and Dice")
    local costRup  = GetSpellCost("Rupture")
    local costEvis = GetSpellCost("Eviscerate")
    local costNA   = GetSpellCost("Noxious Assault")

    -- ----------------------------------------------------------------
    -- P1A: MISSING BUFFS (1-2 CP Priority)
    -- ----------------------------------------------------------------
    -- If buffs are GONE, apply immediately regardless of energy
    if cp >= 1 and cp <= 2 then
        if envTime == 0 and energy >= costEnv then
            CastSpellByName("Envenom"); return
        end
        if sndTime == 0 and energy >= costSnd then
            CastSpellByName("Slice and Dice"); return
        end
    end

    -- ----------------------------------------------------------------
    -- P1B: SMART REFRESH (1 CP Pooling Logic)
    -- ----------------------------------------------------------------
    if cp == 1 then
        local needEnv = (envTime > 0 and envTime < 5)
        local needSnd = (sndTime > 0 and sndTime < 5)

        if needEnv or needSnd then
            -- ONLY refresh if we are pushing the 10-energy buffer cap
            if atCap then
                if needEnv and energy >= costEnv then CastSpellByName("Envenom"); return end
                if needSnd and energy >= costSnd then CastSpellByName("Slice and Dice"); return end
            else
                -- Low energy and buffs still ticking? Keep pooling.
                return
            end
        end
    end

    -- ----------------------------------------------------------------
    -- P2: 5 CP DECISIONS
    -- ----------------------------------------------------------------
    if cp == 5 then
        -- EMERGENCY OVERRIDE:
        -- If TfB < 5s AND buffs are missing AND we have energy to fix it immediately.
        local buffsMissing = (envTime == 0 or sndTime == 0)
        local costToFix = costRup + (envTime == 0 and costEnv or 0) + (sndTime == 0 and costSnd or 0)

        if tasteTime > 0 and tasteTime < 5.0 and buffsMissing and energy >= costToFix then
            CastSpellByName("Rupture"); return
        end

        -- Standard TfB expiry
        if (tasteTime == 0 or tasteTime <= REFRESH_EMERGENCY) and energy >= costRup then
            CastSpellByName("Rupture"); return
        end

        -- Eviscerate
        if tasteTime > TFB_EVIS_THRESHOLD and energy >= costEvis then
            CastSpellByName("Eviscerate"); return
        end

        -- Sync wait logic (pooling for expiring buffs)
        if tasteTime > REFRESH_EMERGENCY and tasteTime <= TFB_EVIS_THRESHOLD then
            local soonest1CP = HUGE
            if envTime > 0 then soonest1CP = math.min(soonest1CP, envTime) end
            if sndTime > 0 then soonest1CP = math.min(soonest1CP, sndTime) end

            local ruptureNow = (soonest1CP <= 3.5) or atCap or (tasteTime <= REFRESH_EMERGENCY)

            if ruptureNow and energy >= costRup then
                CastSpellByName("Rupture"); return
            end
            if not atCap then return end
        end
    end

    -- ----------------------------------------------------------------
    -- P3: BUILDER
    -- ----------------------------------------------------------------
    if cp < 5 and energy >= costNA then
        CastSpellByName("Noxious Assault"); return
    end
end

-- ====================================================================
-- 11. BACKSTAB ROTATION
-- ====================================================================

local function BackstabRotation()
    InitializeTalentRank()
    CheckPoison()

    if not UnitExists("target") or UnitIsDead("target") then
        TargetNearestEnemy()
        if not UnitExists("target") or UnitIsDead("target") then return end
    end

    local cp       = GetComboPoints("player", "target") or 0
    local energy   = UnitMana("player") or 0

    StartOrContinueAttack()
    UpdateBuffDurations()

    local tasteTime = BuffDurations["Taste for Blood"] or 0
    local sndTime   = BuffDurations["Slice and Dice"]  or 0
    local hasTfB    = TASTE_FOR_BLOOD_RANK > 0

    if hasTfB and tasteTime > 0 and tasteTime < 5 then return end

    if cp == 5 then
        if hasTfB and tasteTime < 5 and energy >= GetSpellCost("Rupture") then
            CastSpellByName("Rupture"); return
        end
        if not hasTfB and energy >= GetSpellCost("Eviscerate") then
            CastSpellByName("Eviscerate"); return
        end
    end

    if cp >= 2 and sndTime < 2 and energy >= GetSpellCost("Slice and Dice") then
        CastSpellByName("Slice and Dice"); return
    end

    if cp >= 3 and (not hasTfB or tasteTime >= 5) and sndTime >= 2
    and energy >= GetSpellCost("Eviscerate") then
        CastSpellByName("Eviscerate"); return
    end

    if cp < 5 then
        if energy >= GetSpellCost("Backstab") then CastSpellByName("Backstab"); return end
        if energy >= GetSpellCost("Surprise Attack") then CastSpellByName("Surprise Attack"); return end
    end
end

-- ====================================================================
-- 12. DEBUG
-- ====================================================================

local function DebugState()
    local cp        = GetComboPoints("player", "target") or 0
    local energy    = UnitMana("player") or 0
    local maxEnergy = GetMaxEnergy()
    UpdateBuffDurations()
    local crit = GetMeleeCritRate()
    rrPrint("========= RR Debug =========")
    rrPrint("Energy: " .. energy .. "/" .. maxEnergy .. "  CP=" .. cp)
    rrPrint("At Buffer Cap ("..(maxEnergy-10).."): " .. (energy >= (maxEnergy - 10) and "YES" or "NO"))
    rrPrint("Envenom=" .. BuffDurations["Envenom"] .. "  SnD=" .. BuffDurations["Slice and Dice"] .. "  TfB=" .. BuffDurations["Taste for Blood"])
    rrPrint("Crit=" .. string.format("%.1f", crit*100) .. "%  src=" .. CRIT_SOURCE)
    rrPrint("============================")
end

-- ====================================================================
-- 13. SLASH COMMANDS & EVENTS
-- ====================================================================

do
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_LOGIN")
    f:SetScript("OnEvent", function()
        SetCVar("NP_QuickcastTargetingSpells", "1")
    end)
end

SlashCmdList["ROGUEROTATION"] = function() RogueRotation() end
SLASH_ROGUEROTATION1 = "/RogueRotation"
SLASH_ROGUEROTATION2 = "/rr"

SlashCmdList["BACKSTABROTATION"] = function() BackstabRotation() end
SLASH_BACKSTABROTATION1 = "/BackstabRotation"
SLASH_BACKSTABROTATION2 = "/bs"

SlashCmdList["FINDATTACK"] = function() findAttackSpell() end
SLASH_FINDATTACK1 = "/findattack"

SlashCmdList["STARTATTACK"] = function() startAttack() end
SLASH_STARTATTACK1 = "/startattack"

SlashCmdList["STOPATTACK"] = function() stopAttack() end
SLASH_STOPATTACK1 = "/stopattack"

SlashCmdList["RRINIT"] = function()
    InitializeTalentRank()
    InvalidateSpellCostCache()
    InvalidateCritCache()
    rrPrint("Initialized. Buffer: 10 Energy (Cap @ 90).")
end
SLASH_RRINIT1 = "/rrinit"

SlashCmdList["RRDEBUG"] = function() DebugState() end
SLASH_RRDEBUG1 = "/rrdebug"
