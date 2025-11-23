-- TurtleRogueRotation.lua
-- SuperWoW-enabled addon for Turtle WoW 1.12
-- Automates rogue rotation via /RogueRotation macro

local f = CreateFrame("Frame")
SLASH_ROGUEROTATION1 = "/RogueRotation"

-- Tooltip scanner for 1.12 buff/debuff detection
local BuffScannerTooltip = CreateFrame("GameTooltip", "BuffScannerTooltip", UIParent, "GameTooltipTemplate")
BuffScannerTooltip:SetOwner(UIParent, "ANCHOR_NONE")

local function GetBuffName(unit, index)
    BuffScannerTooltip:ClearLines()
    BuffScannerTooltip:SetUnitBuff(unit, index)
    local name = _G["BuffScannerTooltipTextLeft1"]:GetText()
    return name
end

local function HasPlayerBuffCI(buffName)
    buffName = string.lower(buffName)
    for i = 1, 40 do
        local name = GetBuffName("player", i)
        if not name then break end
        if string.lower(name) == buffName then return true end
    end
    return false
end

local function GetCP()
    return _G.GetComboPoints("player", "target") or 0
end

-- Poison check: both weapons
local function CheckPoison()
    local hasMain, _, chargesMain, hasOff, _, chargesOff = GetWeaponEnchantInfo()
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

-- Rotation logic
local function RogueRotation()
    -- If target is missing or dead, and we are in combat, retarget nearest enemy
    if (not UnitExists("target") or UnitIsDead("target")) and UnitAffectingCombat("player") then
        TargetNearestEnemy()
        if not UnitExists("target") or UnitIsDead("target") then return end
    end

    local cp = GetCP()
    local energy = UnitMana("player")

    -- Start auto-attack
    AttackTarget()

    -- Poison check (warn only, don't block rotation)
    CheckPoison()

    -- Priority: Eviscerate if 5 CP
    if cp >= 5 then
        CastSpellByName("Eviscerate")
        return
    end

    -- Maintain Envenom (only at 2 or 3 CP)
    if not HasPlayerBuffCI("Envenom") and (cp == 2 or cp == 3) then
        CastSpellByName("Envenom")
        return
    end

    -- Maintain Slice and Dice (only at 1 or 2 CP)
    if not HasPlayerBuffCI("Slice and Dice") and (cp == 1 or cp == 2) and HasPlayerBuffCI("Envenom") then
        CastSpellByName("Slice and Dice")
        return
    end

    -- Default: build CP with Noxious Assault (requires 45 energy)
    if energy >= 45 then
        CastSpellByName("Noxious Assault")
    end
end

-- Slash command handler
function SlashCmdList.ROGUEROTATION(msg)
    RogueRotation()
end
