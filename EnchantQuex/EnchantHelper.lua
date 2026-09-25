local _, ns = ...
local EQ = ns.EQ

-- Enchanting helper. In the trade window, hover the other player's "Will not be
-- traded" slot and scroll the mouse wheel to cycle through the enchants you know
-- that fit that item and that you have the materials for. Each wheel step puts the
-- next enchant on the item (it is only cast once both sides accept the trade).
--
-- Forever uses the retail professions UI (ProfessionsFrame / C_TradeSkillUI). Enchant
-- recipes can't be cast by name, so like the Enchant button we call CraftEnchant,
-- which needs the Enchanting window open and a hardware event (the wheel). If the
-- window isn't showing Enchanting, the wheel opens it instead.
--
-- Known enchants and their reagents are learned whenever the Enchanting window is
-- open and saved per character in EnchantQuexCharDB.enchants:
--   ["Enchant Bracer - Minor Health"] = { id = recipeID, target = "Bracer", reagents = {{ id, count }...} }

local SLOT = TRADE_ENCHANT_SLOT or 7
local ENCHANTING_SKILL = 333 -- skill line ID
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemCount = (C_Item and C_Item.GetItemCount) or GetItemCount
local GetSpellName = (C_Spell and C_Spell.GetSpellName) or GetSpellInfo
local ENCHANTING = GetSpellName(7411) or "Enchanting"
local TS = C_TradeSkillUI or {}

-- Which "Enchant <target> - ..." recipes fit each equip slot.
local WEAPON = { Weapon = true }
local TARGETS = {
  INVTYPE_WRIST = { Bracer = true },
  INVTYPE_CHEST = { Chest = true },
  INVTYPE_ROBE = { Chest = true },
  INVTYPE_CLOAK = { Cloak = true },
  INVTYPE_FEET = { Boots = true },
  INVTYPE_HAND = { Gloves = true },
  INVTYPE_SHIELD = { Shield = true },
  INVTYPE_WEAPON = WEAPON,
  INVTYPE_WEAPONMAINHAND = WEAPON,
  INVTYPE_WEAPONOFFHAND = WEAPON,
  INVTYPE_2HWEAPON = { Weapon = true, ["2H Weapon"] = true },
}

--------------------------------------------------------------------------------
-- The Enchanting window
--------------------------------------------------------------------------------

local windowOpen = false -- between TRADE_SKILL_SHOW and TRADE_SKILL_CLOSE

-- True when the professions window is open on Enchanting and its recipes are loaded.
-- It can open on another profession first, so the shown profession is checked too.
local function enchantingOpen()
  if not (windowOpen or (ProfessionsFrame and ProfessionsFrame:IsShown())) then return false end
  if TS.IsTradeSkillReady and not TS.IsTradeSkillReady() then return false end
  if TS.IsTradeSkillLinked and TS.IsTradeSkillLinked() then return false end
  local info = TS.GetBaseProfessionInfo and TS.GetBaseProfessionInfo()
  return info ~= nil and (info.professionID == ENCHANTING_SKILL or info.professionName == ENCHANTING)
end

local function openEnchantingWindow()
  if TS.OpenTradeSkill then TS.OpenTradeSkill(ENCHANTING_SKILL) end
end

local function basicReagents(recipeID)
  local reagents = {}
  local schematic = TS.GetRecipeSchematic and TS.GetRecipeSchematic(recipeID, false)
  if not schematic then return reagents end
  local basic = Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
  for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
    local first = slot.reagents and slot.reagents[1]
    if first and first.itemID and (basic == nil or slot.reagentType == basic) then
      reagents[#reagents + 1] = { id = first.itemID, count = slot.quantityRequired or 1 }
    end
  end
  return reagents
end

-- Merges rather than replaces, so a filtered or partly loaded list never forgets recipes.
local function learn()
  if not enchantingOpen() or not TS.GetAllRecipeIDs then return end
  local known = EnchantQuexCharDB.enchants
  for _, recipeID in ipairs(TS.GetAllRecipeIDs()) do
    local info = TS.GetRecipeInfo(recipeID)
    local target = info and info.learned and info.name and info.name:match("^Enchant (.-) %- ")
    if target then
      known[info.name] = { id = recipeID, target = target, reagents = basicReagents(recipeID) }
    end
  end
end

--------------------------------------------------------------------------------
-- Choosing and applying an enchant
--------------------------------------------------------------------------------

local function canMake(enchant)
  if not enchant.id then return false end -- saved by an older version
  for _, r in ipairs(enchant.reagents) do
    if GetItemCount(r.id) < r.count then return false end
  end
  return true
end

-- Sorted names of the enchants that fit the item in the other player's enchant slot
-- and that you have the materials for.
function EQ:GetTradeEnchants()
  local list = {}
  local link = GetTradeTargetItemLink(SLOT)
  local equipLoc = link and select(9, GetItemInfo(link))
  local targets = equipLoc and TARGETS[equipLoc]
  if not targets then return list end
  for name, enchant in pairs(EnchantQuexCharDB.enchants) do
    if targets[enchant.target] and canMake(enchant) then list[#list + 1] = name end
  end
  table.sort(list)
  return list
end

-- The enchant we last put on the current item; cleared when the item changes.
local current = { link = nil, name = nil }

-- The enchant after (dir = 1) or before (dir = -1) the current one.
local function nextEnchant(dir)
  local list = EQ:GetTradeEnchants()
  if #list == 0 then return nil end
  local index
  if current.link == GetTradeTargetItemLink(SLOT) then
    for i, name in ipairs(list) do
      if name == current.name then index = i break end
    end
  end
  if index then
    index = (index - 1 + dir) % #list + 1
  else
    index = dir > 0 and 1 or #list
  end
  return list[index]
end

-- Casts the enchant without a target and drops the targeting cursor on the trade slot.
local function apply(name)
  local recipeID = EnchantQuexCharDB.enchants[name].id
  if SpellIsTargeting() then SpellStopTargeting() end
  if TS.CraftEnchant then
    TS.CraftEnchant(recipeID, 1, {})
  else
    TS.CraftRecipe(recipeID, 1, {})
  end
  if SpellIsTargeting() then
    ClickTargetTradeButton(SLOT)
    current.link, current.name = GetTradeTargetItemLink(SLOT), name
  end
end

local function onWheel(slotButton, delta)
  if not EnchantQuexDB.enchantHelper or not GetTradeTargetItemLink(SLOT) then return end
  if not enchantingOpen() then
    openEnchantingWindow() -- also how the recipes get learned the first time
  else
    local name = nextEnchant(delta > 0 and 1 or -1)
    if name then apply(name) end
  end
  if slotButton:IsMouseOver() then slotButton:GetScript("OnEnter")(slotButton) end
end

--------------------------------------------------------------------------------
-- Trade slot hooks
--------------------------------------------------------------------------------

local function addTooltipHint()
  if not EnchantQuexDB.enchantHelper or not GetTradeTargetItemLink(SLOT) then return end
  local label = EQ.LABEL_COLOR .. "Enchant|r "
  if not next(EnchantQuexCharDB.enchants) then
    if GetSpellName(ENCHANTING) then
      GameTooltip:AddLine(label .. "|cff808080Scroll to open your Enchanting window so EnchantQuex learns your recipes.|r",
        1, 1, 1, true)
      GameTooltip:Show()
    end
    return
  end
  local list = EQ:GetTradeEnchants()
  if #list == 0 then
    GameTooltip:AddLine(label .. "|cff808080No enchants for this slot that you have materials for.|r", 1, 1, 1, true)
  else
    local pos = ""
    for i, name in ipairs(list) do
      if name == current.name and current.link == GetTradeTargetItemLink(SLOT) then pos = i .. "/" end
    end
    GameTooltip:AddLine(format("%s|cff808080Scroll to cycle enchants (%s%d)|r", label, pos, #list), 1, 1, 1)
    if not enchantingOpen() then
      GameTooltip:AddLine("|cff808080The first scroll opens your Enchanting window.|r", 1, 1, 1)
    end
  end
  GameTooltip:Show()
end

local function hookTradeSlot()
  local slotButton = _G["TradeRecipientItem" .. SLOT .. "ItemButton"]
  if not slotButton then return end
  slotButton:EnableMouseWheel(true)
  slotButton:SetScript("OnMouseWheel", onWheel)
  slotButton:HookScript("OnEnter", addTooltipHint)
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event)
  if event == "TRADE_SKILL_SHOW" then
    windowOpen = true
    learn()
  elseif event == "TRADE_SKILL_CLOSE" then
    windowOpen = false
  elseif event == "TRADE_CLOSED" then
    current.link, current.name = nil, nil
  else -- recipe list (re)loaded or the window switched profession
    learn()
  end
end)

table.insert(ns.onLoad, function()
  EnchantQuexCharDB = EnchantQuexCharDB or {}
  EnchantQuexCharDB.enchants = EnchantQuexCharDB.enchants or {}
  for _, e in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE", "TRADE_SKILL_LIST_UPDATE",
                       "TRADE_SKILL_DATA_SOURCE_CHANGED", "TRADE_CLOSED" }) do
    pcall(events.RegisterEvent, events, e) -- in case the client lacks one
  end
  hookTradeSlot()
end)

function EQ:NumKnownEnchants()
  local n = 0
  for _ in pairs(EnchantQuexCharDB.enchants) do n = n + 1 end
  return n
end
