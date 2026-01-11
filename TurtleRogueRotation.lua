-- TurtleRogueRotation.lua
-- Automates rogue rotation via /RogueRotation and /BackstabRotation macros
-- Incorporates a robust, non-toggling attack logic using action slots.

-- ====================================================================
-- 1. CONFIGURATION AND GLOBAL STATE
-- ====================================================================

local TASTE_FOR_BLOOD_RANK = 0
local LAST_CHECKED_TASTE_FOR_BLOOD_RANK = -1

local IsInCombatAndFirstRupturePending = false

local MIN_SAFE_TASTE_DURATION = 5
local MIN_SAFE_SND_DURATION = 2
local RUPTURE_EMERGENCY_TIME = 2
local TfB_WAIT_BUFFER = 0.5

local TRACKED_BUFF_ICONS = {
    ["Slice and Dice"] = "Interface\\Icons\\Ability_Rogue_SliceDice",
    ["Taste for Blood"] = "Interface\\Icons\\INV_Misc_Bone_09",
    ["Envenom"] = "Interface\\Icons\\INV_Sword_31",
}

local KnownBuffDurations = {
    ["Slice and Dice"] = 0,
    ["Taste for Blood"] = 0,
    ["Envenom"] = 0,
}

local AtkSpell
local f = CreateFrame("Frame")

-- ====================================================================
-- 2. ATTACK LOGIC
-- ====================================================================

local function print(text, name, r, g, b, frame, delay)
    if not text or string.len(text) == 0 then text = " " end
    if not name or name == AceConsole then
        (frame or DEFAULT_CHAT_FRAME):AddMessage(text, r, g, b, nil, delay or 5)
    else
        (frame or DEFAULT_CHAT_FRAME):AddMessage("|cffffff78" .. tostring(name) .. ":|r " .. text, r, g, b, nil, delay or 5)
    end
end

local function findAttackSpell()
    AtkSpell = nil
    for AtkSlot = 1, 108 do
        if IsAttackAction(AtkSlot) then
            AtkSpell = AtkSlot
            return
        end
    end
end

local function startAttack()
    if not AtkSpell then findAttackSpell() end
    if AtkSpell and type(AtkSpell) == "number" then
        if not IsCurrentAction(AtkSpell) then UseAction(AtkSpell) end
    end
end

local function stopAttack()
    if AtkSpell and type(AtkSpell) == "number" then
        if IsCurrentAction(AtkSpell) then UseAction(AtkSpell) end
    end
end

local function StartOrContinueAttack()
    startAttack()
    if UnitExists("target") and UnitCanAttack("player", "target") and (not AtkSpell or not IsCurrentAction(AtkSpell)) then
        AttackTarget()
    end
end

-- ====================================================================
-- 3. HELPERS
-- ====================================================================

local function InitializeTalentRank()
    local targetTfB = "Taste for Blood"
    local currentTfBRank = 0

    for tab = 1, 3 do
        for index = 1, 32 do
            local name, _, rank = GetTalentInfo(tab, index)
            if rank and rank > 0 and name == targetTfB then
                currentTfBRank = rank
            end
        end
    end

    if currentTfBRank ~= LAST_CHECKED_TASTE_FOR_BLOOD_RANK then
        TASTE_FOR_BLOOD_RANK = currentTfBRank
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
    return GetComboPoints("player", "target") or 0
end

-- ====================================================================
-- 4. UTILITIES
-- ====================================================================

local function CheckPoison()
    local hasMain, _, chargesMain, _, hasOff, chargesOff = GetWeaponEnchantInfo()
    if not hasMain or (chargesMain and chargesMain < 15)
       or not hasOff or (chargesOff and chargesOff < 15) then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff2020WARNING: Poison missing or low!|r")
    end
end

f:RegisterEvent("PLAYER_ENTER_COMBAT")
f:RegisterEvent("PLAYER_LEAVE_COMBAT")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_ENTER_COMBAT" then
        IsInCombatAndFirstRupturePending = true
    elseif event == "PLAYER_LEAVE_COMBAT" then
        IsInCombatAndFirstRupturePending = false
    elseif event == "ADDON_LOADED" then
        findAttackSpell()
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff88TurtleRogueRotation loaded.|r")
    end
end)

-- ====================================================================
-- 5. ROTATIONS
-- ====================================================================

local function RogueRotation()
    InitializeTalentRank()
    CheckPoison()

    if not UnitExists("target") or UnitIsDead("target") then
        TargetNearestEnemy()
        if not UnitExists("target") or UnitIsDead("target") then return end
    end

    local cp = GetCP()
    local energy = UnitMana("player")
    local hasTfB = HasTasteForBloodTalent()
    local maxEnergy = UnitManaMax("player")

    StartOrContinueAttack()

    local envenomTime = GetBuffRemaining("Envenom")
    local tasteTime = GetBuffRemaining("Taste for Blood")
    local sndTime = GetBuffRemaining("Slice and Dice")

    local maxCP = 5

    -- P1: Envenom
    if envenomTime <= 0 and cp >= 2 and cp <= 4 then
        CastSpellByName("Envenom")
        return
    end

    -- P2: Emergency Rupture
    if hasTfB and envenomTime > 0 and envenomTime <= RUPTURE_EMERGENCY_TIME and cp >= 4 then
        CastSpellByName("Rupture")
        return
    end

    -- P3: Rupture / Eviscerate (TfB logic)
    if hasTfB and cp == maxCP then

        if tasteTime > 0 then

            -- NEW RULE:
            -- If Taste for Blood has >= 5 seconds AND we have 5 CP → Eviscerate
            if tasteTime >= 5 then
                CastSpellByName("Eviscerate")
                return
            end

            -- Otherwise: energy pooling vs TfB clipping
            local timeToMax = (maxEnergy - energy) / 10
            local requiredWait = tasteTime + TfB_WAIT_BUFFER

            if timeToMax < requiredWait then
                CastSpellByName("Rupture")
                return
            end

            return
        end

        -- Taste not active → Rupture
        CastSpellByName("Rupture")
        return
    end

    -- Non-TfB fallback Eviscerate
    if not hasTfB and cp == maxCP and envenomTime > 0 and sndTime > 0 then
        CastSpellByName("Eviscerate")
        return
    end

    -- P4: Slice and Dice
    if envenomTime > 0 and sndTime <= 0 and cp >= 1 and cp <= 3 then
        CastSpellByName("Slice and Dice")
        return
    end

    -- P5: TfB fallback Eviscerate
    if hasTfB and cp == maxCP and envenomTime > 0 and sndTime > 0 then
        CastSpellByName("Eviscerate")
        return
    end

    -- P6: Generator
    if cp < maxCP and energy >= 40 then
        CastSpellByName("Noxious Assault")
        return
    end
end

-- ====================================================================
-- BACKSTAB ROTATION (unchanged)
-- ====================================================================

local function BackstabRotation()
    InitializeTalentRank()
    CheckPoison()

    if not UnitExists("target") or UnitIsDead("target") then
        TargetNearestEnemy()
        if not UnitExists("target") or UnitIsDead("target") then return end
    end

    local maxCP = 5
    local cp = GetCP()
    local energy = UnitMana("player")

    StartOrContinueAttack()

    local tasteTime = GetBuffRemaining("Taste for Blood")
    local sndTime = GetBuffRemaining("Slice and Dice")
    local hasTfB = HasTasteForBloodTalent()

    if hasTfB and tasteTime > 0 and tasteTime < MIN_SAFE_TASTE_DURATION then
        return
    end

    if hasTfB then
        if IsInCombatAndFirstRupturePending and cp >= 3 and energy >= 60 then
            CastSpellByName("Rupture")
            IsInCombatAndFirstRupturePending = false
            return
        end

        if not IsInCombatAndFirstRupturePending and cp == maxCP and tasteTime < MIN_SAFE_TASTE_DURATION then
            CastSpellByName("Rupture")
            return
        end
    else
        if cp == maxCP and energy >= 60 then
            CastSpellByName("Eviscerate")
            return
        end
    end

    if cp >= 2 and sndTime < MIN_SAFE_SND_DURATION then
        if not hasTfB or (hasTfB and tasteTime > 0) then
            CastSpellByName("Slice and Dice")
            return
        end
    end

    local isTfBSafe = not hasTfB or (tasteTime >= MIN_SAFE_TASTE_DURATION)

    if cp >= 3 and isTfBSafe and sndTime >= MIN_SAFE_SND_DURATION then
        CastSpellByName("Eviscerate")
        return
    end

    if cp == maxCP and isTfBSafe and sndTime > 0 then
        CastSpellByName("Eviscerate")
        return
    end

    if cp < maxCP then
        if energy >= 10 then CastSpellByName("Surprise Attack") end
        if energy >= 60 then CastSpellByName("Backstab") return end
    end
end

-- ====================================================================
-- 6. SLASH COMMANDS
-- ====================================================================

SlashCmdList["ROGUEROTATION"] = function(msg) RogueRotation() end
SLASH_ROGUEROTATION1 = "/RogueRotation"
SLASH_ROGUEROTATION2 = "/rr"

SlashCmdList["BACKSTABROTATION"] = function(msg) BackstabRotation() end
SLASH_BACKSTABROTATION1 = "/BackstabRotation"
SLASH_BACKSTABROTATION2 = "/bs"

SLASH_FINDATTACK1 = "/findattack"
SLASH_STARTATTACK1 = "/startattack"
SLASH_STOPATTACK1 = "/stopattack"

function SlashCmdList.FINDATTACK(msg) findAttackSpell() end
function SlashCmdList.STARTATTACK(msg) startAttack() end
function SlashCmdList.STOPATTACK(msg) stopAttack() end
