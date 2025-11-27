-- TurtleRogueRotation.lua
-- Automates rogue rotation via /RogueRotation and /BackstabRotation macros
-- Incorporates a robust, non-toggling attack logic using action slots.

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
local RUPTURE_EMERGENCY_TIME = 2 -- Envenom expiry window for emergency Rupture
local TfB_WAIT_BUFFER = 0.5 -- Time buffer (seconds) to wait beyond tasteTime for safe clip

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

-- Attack Logic Variables
local AtkSpell -- The action slot number for the main attack spell

-- Frame is kept for compatibility
local f = CreateFrame("Frame")

-- ====================================================================
-- 2. ATTACK LOGIC (Based on User's Reliable Method) ⚔️
-- ====================================================================

local function print(text, name, r, g, b, frame, delay)
    if not text or string.len(text) == 0 then
        text = " "
    end
    if not name or name == AceConsole then
        (frame or DEFAULT_CHAT_FRAME):AddMessage(text, r, g, b, nil, delay or 5)
    else
        (frame or DEFAULT_CHAT_FRAME):AddMessage("|cffffff78" .. tostring(name) .. ":|r " .. text, r, g, b, nil, delay or 5)
    end
end

-- Function to locate the main attack spell slot (typically in the 12-72 range)
local function findAttackSpell()
    AtkSpell = nil -- Reset in case of re-scan
    -- Scan the main action bar slots (12-72 is often a safe range for searching)
    for AtkSlot = 1, NUM_ACTIONBAR_BUTTONS + NUM_ACTIONBAR_BUTTONS do
        if IsAttackAction(AtkSlot) then
            AtkSpell = AtkSlot
            return
        end
    end
end

-- Non-toggling attack start: calls the attack action if it's not currently active
local function startAttack()
    if not AtkSpell then
        findAttackSpell()
    end

    if AtkSpell and not IsCurrentAction(AtkSpell) then
        UseAction(AtkSpell)
    end
end

-- Non-toggling attack stop: calls the attack action if it IS currently active
local function stopAttack()
    if AtkSpell and IsCurrentAction(AtkSpell) then
        UseAction(AtkSpell)
    end
end

-- The function that is called from the rotation
local function StartOrContinueAttack()
    startAttack()
end

-- ====================================================================
-- 3. HELPERS ⏱️
-- ====================================================================

-- Talent Check Function: Only checks for Taste for Blood (TfB) now.
local function InitializeTalentRank()
    local targetTfB = "Taste for Blood"
    local currentTfBRank = 0

    -- Iterate through all three talent tabs to find the current ranks
    for tab = 1, 3 do
        for index = 1, 32 do
            local name, _, rank = GetTalentInfo(tab, index)
            if rank and rank > 0 then
                if name == targetTfB then
                    currentTfBRank = rank
                end
            end
        end
    end

    -- Update TfB Rank
    if currentTfBRank ~= LAST_CHECKED_TASTE_FOR_BLOOD_RANK then
        TASTE_FOR_BLOOD_RANK = currentTfBRank
        local debugMsg
        if TASTE_FOR_BLOOD_RANK > 0 then
            debugMsg = string.format("|cff00aaff[DEBUG] Talent Check Update: '%s' Rank %d detected. TfB logic ENABLED.|r", targetTfB, TASTE_FOR_BLOOD_RANK)
        else
            debugMsg = string.format("|cff00aaff[DEBUG] Talent Check Update: '%s' NOT detected. Eviscerate logic ENABLED.|r", targetTfB)
        end
        DEFAULT_CHAT_FRAME:AddMessage(debugMsg)
        LAST_CHECKED_TASTE_FOR_BLOOD_RANK = currentTfBRank
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

-- ====================================================================
-- 4. UTILITIES (Poison Check & Combat Events) 🐍
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
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_ENTER_COMBAT" then
        IsInCombatAndFirstRupturePending = true
    elseif event == "PLAYER_LEAVE_COMBAT" then
        IsInCombatAndFirstRupturePending = false
    elseif event == "ADDON_LOADED" then
        -- Initialize attack action slot on load
        findAttackSpell()
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff88TurtleRogueRotation loaded. Attack slot: " .. tostring(AtkSpell or "NIL") .. ". Commands: /rr, /bs, /startattack, /stopattack.|r")
    end
end)


-- ====================================================================
-- 5. ROTATIONS 🔪
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
    local currentMaxEnergy = UnitManaMax("player")

    StartOrContinueAttack() -- Calls the reliable startAttack function

    local envenomTime = GetBuffRemaining("Envenom")
    local tasteTime = GetBuffRemaining("Taste for Blood")
    local sndTime = GetBuffRemaining("Slice and Dice")

    local maxCP = 5

    -- P1: Envenom: Cast only if expired (cp <= 4 constraint)
    if envenomTime <= 0 and cp >= 2 and cp <= 4 then
        CastSpellByName("Envenom")
        return
    end

    -- P2: EMERGENCY RUPTURE if Envenom is dropping (TfB Priority)
    if hasTfBTalent and envenomTime > 0 and envenomTime <= RUPTURE_EMERGENCY_TIME and cp >= 4 then
        CastSpellByName("Rupture")
        return
    end

    -- P3: Rupture (TfB High CP Dump) / Eviscerate (Non-TfB High CP Dump)

    -- TfB: Rupture is the preferred finisher when TfB is enabled (Prio over SnD).
    if hasTfBTalent and cp >= maxCP then
        -- ENERGY-SAVING CHECK FOR TfB CLIP:
        if tasteTime > 0 then
            -- Time in seconds until energy hits the DYNAMIC MAX ENERGY (assuming 10 energy/sec)
            local timeToMaxEnergy = (currentMaxEnergy - energy) / 10
            -- Time we want to wait before casting Rupture to avoid clipping TfB
            local requiredWaitTime = tasteTime + TfB_WAIT_BUFFER

            -- If we will hit max energy BEFORE TfB expires, we must cast Rupture immediately.
            if timeToMaxEnergy < requiredWaitTime then
                CastSpellByName("Rupture")
                return
            end

            -- Otherwise (if we can wait safely without energy cap), return to continue generating energy.
            return
        end

        -- If tasteTime is <= 0 (or not applicable), cast Rupture normally at max CP
        CastSpellByName("Rupture")
        return
    end

    -- Non-TfB: Eviscerate high value dump
    if not hasTfBTalent then
        if cp >= maxCP and envenomTime > 0 and energy >= 60 then
            CastSpellByName("Eviscerate")
            return
        end
    end


    -- P4: Slice and Dice Refresh: Cast only if expired (cp <= 3 constraint)
    if envenomTime > 0 and sndTime <= 0 and cp >= 1 and cp <= 3 then
        CastSpellByName("Slice and Dice")
        return
    end

    -- P5: Eviscerate (Damage Dump - ONLY if TfB NOT active, buffs are UP AND CP are capped)
    if not hasTfBTalent and cp == maxCP and envenomTime > 0 and sndTime > 0 then
        -- TfB check for Eviscerate: must be safe (only relevant if TfB is enabled)
        local isTfBSafe = not hasTfBTalent or (tasteTime > 0)
        if isTfBSafe then
            CastSpellByName("Eviscerate")
            return
        end
    end

    -- P6: Eviscerate (Fallback dump if CP is capped and P4 was missed due to other conditions)
    if not hasTfBTalent and cp == maxCP and envenomTime > 0 and sndTime > 0 then
        CastSpellByName("Eviscerate")
        return
    end

    -- P7: Generators / Poison Reminder (Noxious Assault)
    if cp < maxCP and energy >= 45 then
        CastSpellByName("Noxious Assault")
        return
    end
end

---

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

    StartOrContinueAttack() -- Conditional attack start

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
-- 6. ROTATION SLASH COMMANDS
-- ====================================================================

SlashCmdList["ROGUEROTATION"] = function(msg) RogueRotation() end
SLASH_ROGUEROTATION1 = "/RogueRotation"
SLASH_ROGUEROTATION2 = "/rr"

SlashCmdList["BACKSTABROTATION"] = function(msg) BackstabRotation() end
SLASH_BACKSTABROTATION1 = "/BackstabRotation"
SLASH_BACKSTABROTATION2 = "/bs"

-- ====================================================================
-- 7. ATTACK UTILITY SLASH COMMANDS (From User Input)
-- ====================================================================

-- The attack logic initialization now happens on ADDON_LOADED event
SLASH_FINDATTACK1 = "/findattack"
SLASH_STARTATTACK1 = "/startattack"
SLASH_STOPATTACK1 = "/stopattack"

function SlashCmdList.FINDATTACK(msg, editbox)
    findAttackSpell()
    if AtkSpell == nil then
        print("Attack skill not found", "ATTACK FINDER", 1, 0.2, 0.2)
    else
        print("Found Attack skill at slot |cff1eff00".. tostring(AtkSpell) .. "|r", "ATTACK FINDER", 0.5, 0.8, 1)
    end
end

function SlashCmdList.STARTATTACK(msg, editbox)
    startAttack()
end

function SlashCmdList.STOPATTACK(msg, editbox)
    stopAttack()
end
