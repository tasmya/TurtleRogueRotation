-- TurtleRogueRotation.lua
-- SuperWoW-enabled addon for Turtle WoW 1.12
-- Automates rogue rotation via /RogueRotation and /BackstabRotation macros

-- ====================================================================
-- 1. CONFIGURATION AND GLOBAL STATE 🛠️
-- ====================================================================

-- TASTE FOR BLOOD LOGIC: This variable is now set dynamically by talent check.
local TASTE_FOR_BLOOD_RANK = 0
local LAST_CHECKED_TASTE_FOR_BLOOD_RANK = -1 -- Track previous state for conditional debug print

-- NEW COMBAT STATE FOR INITIAL RUPTURE PULL
local IsInCombatAndFirstRupturePending = false

-- TUNED SAFETY WINDOWS (Buffs only cast when expired: <= 0 in RogueRotation)
local MIN_SAFE_TASTE_DURATION = 5
local MIN_SAFE_SND_DURATION = 2

-- Buff Icon Textures
local TRACKED_BUFF_ICONS = {
    ["Slice and Dice"] = "Interface\\Icons\\Ability_Rogue_SliceDice",
    ["Taste for Blood"] = "Interface\\Icons\\INV_Misc_Bone_09",
    ["Envenom"] = "Interface\\Icons\\INV_Sword_31",
}

-- Stores the currently known duration for the two tracked buffs
local KnownBuffDurations = {
    ["Slice and Dice"] = 0,
    ["Taste for Blood"] = 0,
    ["Envenom"] = 0,
}

-- Frame is kept for compatibility
local f = CreateFrame("Frame")

-- ====================================================================
-- 2. HELPERS ⏱️
-- ====================================================================

-- Talent Check Function: Performs the check and prints the debug if the rank changes.
local function InitializeTalentRank()
    local targetTalentName = "Taste for Blood"
    local currentRank = 0

    -- Iterate through all three talent tabs to find the current rank
    for tab = 1, 3 do
        for index = 1, 32 do
            local name, _, rank = GetTalentInfo(tab, index)
            if name == targetTalentName and rank and rank > 0 then
                currentRank = rank
                break
            end
        end
    end

    -- Check if the rank has changed (or if it's the very first run)
    if currentRank ~= LAST_CHECKED_TASTE_FOR_BLOOD_RANK then
        TASTE_FOR_BLOOD_RANK = currentRank

        -- Print NEW DEBUG OUTPUT (as requested)
        local debugMsg
        if TASTE_FOR_BLOOD_RANK > 0 then
            debugMsg = string.format("|cff00aaff[DEBUG] Talent Check Update: '%s' Rank %d detected. TfB logic ENABLED.|r", targetTalentName, TASTE_FOR_BLOOD_RANK)
        else
            debugMsg = string.format("|cff00aaff[DEBUG] Talent Check Update: '%s' NOT detected. Eviscerate logic ENABLED.|r", targetTalentName)
        end
        DEFAULT_CHAT_FRAME:AddMessage(debugMsg)

        LAST_CHECKED_TASTE_FOR_BLOOD_RANK = currentRank
    end
end

local function HasTasteForBloodTalent()
    return TASTE_FOR_BLOOD_RANK > 0
end

local function UpdateKnownBuffDurations()
    KnownBuffDurations["Slice and Dice"] = 0
    KnownBuffDurations["Taste for Blood"] = 0
    KnownBuffDurations["Envenom"] = 0

    for i = 0, 29 do
        local icon = GetPlayerBuffTexture(i)

        if icon == nil then break end

        local time = GetPlayerBuffTimeLeft(i)

        if icon == TRACKED_BUFF_ICONS["Slice and Dice"] then
            KnownBuffDurations["Slice and Dice"] = time
        elseif icon == TRACKED_BUFF_ICONS["Taste for Blood"] then
            KnownBuffDurations["Taste for Blood"] = time
        elseif icon == TRACKED_BUFF_ICONS["Envenom"] then
            KnownBuffDurations["Envenom"] = time
        end
    end
end

local function GetBuffRemaining(buffName)
    UpdateKnownBuffDurations()
    return KnownBuffDurations[buffName] or 0
end

local function GetCP()
    return _G.GetComboPoints("player", "target") or 0
end

local function HasBuff(unit, buffName)
    return GetBuffRemaining(buffName) > 0
end

local function StartOrContinueAttack()
    if not (UnitIsUnit("target", "player") and UnitAffectingCombat("player")) then
        AttackTarget()
    end
end

-- ====================================================================
-- 3. UTILITIES (Poison Check & Combat Events) 🐍
-- ====================================================================

local function CheckPoison()
    local hasMain, _, chargesMain, _, hasOff, chargesOff = GetWeaponEnchantInfo()
    local warn = false

    if not hasMain or (chargesMain and chargesMain < 15) then
        warn = true
    end
    if not hasOff or (chargesOff and chargesOff < 15) then
        warn = true
    end

    if warn then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff2020WARNING: Poison missing or low on weapon(s)!|r")
    end
end

-- Event Handler: Reset combat state when entering/leaving combat
f:RegisterEvent("PLAYER_ENTER_COMBAT")
f:RegisterEvent("PLAYER_LEAVE_COMBAT")
f:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_ENTER_COMBAT" then
        IsInCombatAndFirstRupturePending = true
    elseif event == "PLAYER_LEAVE_COMBAT" then
        IsInCombatAndFirstRupturePending = false
    end

    -- Keep the ADDON_LOADED logic for initialization
    if event == "ADDON_LOADED" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff88TurtleRogueRotation loaded. Commands: /rr, /bs. Talent check runs per macro press.|r")
    end
end)


-- ====================================================================
-- 4. ROTATIONS 🔪
-- ====================================================================

local function RogueRotation()
    InitializeTalentRank()
    CheckPoison()

    if (not UnitExists("target") or UnitIsDead("target")) and UnitAffectingCombat("player") then
        TargetNearestEnemy()
        if not UnitExists("target") or UnitIsDead("target") then return end
    end

    local cp = GetCP()
    local energy = UnitMana("player")
    local hasTfBTalent = HasTasteForBloodTalent()

    StartOrContinueAttack()

    local envenomTime = GetBuffRemaining("Envenom")
    local tasteTime = GetBuffRemaining("Taste for Blood")
    local sndTime = GetBuffRemaining("Slice and Dice")

    local maxCP = 5

    -- P1: Envenom: Cast only if expired
    if envenomTime <= 0 and cp >= 2 then
        CastSpellByName("Envenom")
        return
    end

    -- P2: Rupture / Eviscerate (TfB Logic)
    -- If TfB is present, Rupture is prioritized over SnD (P3) as the finisher.
    if hasTfBTalent then
        -- Rupture is the preferred finisher when TfB is enabled. Energy check removed.
        if cp >= maxCP then
            CastSpellByName("Rupture")
            return
        end
    end

    -- P3: Slice and Dice Refresh: Cast only if expired
    if envenomTime > 0 and sndTime <= 0 and cp >= 1 then
        CastSpellByName("Slice and Dice")
        return
    end

    -- P4: Eviscerate (Damage Dump - ONLY if TfB NOT active, buffs are UP AND CP are capped)
    if not hasTfBTalent and cp == maxCP and envenomTime > 0 and sndTime > 0 then
        -- TfB check for Eviscerate: must be safe (only relevant if TfB is enabled)
        local isTfBSafe = not hasTfBTalent or (tasteTime > 0)
        if isTfBSafe then
            CastSpellByName("Eviscerate")
            return
        end
    end

    -- P5: Eviscerate (Fallback dump if CP is capped and P4 was missed due to other conditions)
    if not hasTfBTalent and cp == maxCP and envenomTime > 0 and sndTime > 0 then
        CastSpellByName("Eviscerate")
        return
    end

    -- P6: Eviscerate if TfB is disabled and conditions for finisher are met (original P2 fallback for non-TfB)
    if not hasTfBTalent then
        if cp >= maxCP and envenomTime > 0 and energy >= 60 then
            CastSpellByName("Eviscerate")
            return
        end
    end

    -- P7: Generators / Poison Reminder (Noxious Assault)
    if cp < maxCP and energy >= 45 then
        CastSpellByName("Noxious Assault")
        return
    end
end

local function BackstabRotation()
    InitializeTalentRank()
    CheckPoison()

    if (not UnitExists("target") or UnitIsDead("target")) and UnitAffectingCombat("player") then
        TargetNearestEnemy()
        if not UnitExists("target") or UnitIsDead("target") then return end
    end

    local maxCP = 5
    local cp = GetCP()
    local energy = UnitMana("player")

    StartOrContinueAttack()

    local tasteTime = GetBuffRemaining("Taste for Blood")
    local sndTime = GetBuffRemaining("Slice and Dice")
    local hasTfBTalent = HasTasteForBloodTalent()

    -- P1: Prevent wasting CP if Taste for Blood is expiring soon (HOLD)
    if hasTfBTalent and tasteTime > 0 and tasteTime < MIN_SAFE_TASTE_DURATION then
        return
    end

    -- P2: Rupture / Eviscerate (TfB Logic)
    if hasTfBTalent then
        -- P2a: INITIAL PULL RUPTURE (3+ CP for quick TfB application)
        if IsInCombatAndFirstRupturePending and cp >= 3 and energy >= 60 then
            CastSpellByName("Rupture")
            IsInCombatAndFirstRupturePending = false -- Turn off initial pull flag
            return
        end

        -- P2b: NORMAL RUPTURE ROTATION (Max CP, no energy check, cast when expiring)
        if not IsInCombatAndFirstRupturePending and cp == maxCP and tasteTime < MIN_SAFE_TASTE_DURATION then
            CastSpellByName("Rupture")
            return
        end
    else
        -- Eviscerate if TfB is disabled
        if cp == maxCP and energy >= 60 then
            CastSpellByName("Eviscerate")
            return
        end
    end

    -- P3: Maintain Slice and Dice (Prioritized)
    if cp >= 2 and sndTime < MIN_SAFE_SND_DURATION then
        -- If TfB is required, ensure it's active before refreshing SnD.
        if not hasTfBTalent or (hasTfBTalent and tasteTime > 0) then
            CastSpellByName("Slice and Dice")
            return
        end
    end

    -- P4: Eviscerate (Damage Dump)
    local isTfBSafe = not hasTfBTalent or (tasteTime >= MIN_SAFE_TASTE_DURATION)

    if cp >= 3 and isTfBSafe and sndTime >= MIN_SAFE_SND_DURATION then
        CastSpellByName("Eviscerate")
        return
    end

    -- P5: Fallback: dump CP if capped
    if cp == maxCP and isTfBSafe and sndTime > 0 then
        CastSpellByName("Eviscerate")
        return
    end

    -- P6: Generators (Surprise Attack prioritised over Backstab)
    if cp < maxCP then
        -- 1. Use Surprise Attack if we have the energy (10)
        if energy >= 10 then
            CastSpellByName("Surprise Attack")
            -- NO RETURN per instruction
        end

        -- 2. Use Backstab if we have the energy (60)
        if energy >= 60 then
            CastSpellByName("Backstab")
            return
        end
    end
end

-- ====================================================================
-- 5. SLASH COMMANDS
-- ====================================================================

SlashCmdList["ROGUEROTATION"] = function(msg) RogueRotation() end
SLASH_ROGUEROTATION1 = "/RogueRotation"
SLASH_ROGUEROTATION2 = "/rr"

SlashCmdList["BACKSTABROTATION"] = function(msg) BackstabRotation() end
SLASH_BACKSTABROTATION1 = "/BackstabRotation"
SLASH_BACKSTABROTATION2 = "/bs"
