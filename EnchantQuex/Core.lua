local ADDON, ns = ...
local Data = ns.Data

local EQ = {}
ns.EQ = EQ
_G.EnchantQuex = EQ

local DEFAULTS = {
  enabled = true,
  maxIlvlDistance = 5,        -- how far to look for a neighbouring item level table
  alwaysShowBreakdown = false,-- otherwise hold Shift
  overrides = {},             -- ["quality:classID:ilvl"] = { [matID] = { chance, avgQty } }
  minimap = { hide = false, angle = 225 },
}

EQ.CLASS_WEAPON, EQ.CLASS_ARMOR = 2, 4
EQ.QUALITY_NAMES = { [2] = "Uncommon", [3] = "Rare", [4] = "Epic" }
EQ.CLASS_NAMES = { [EQ.CLASS_WEAPON] = "Weapon", [EQ.CLASS_ARMOR] = "Armor" }
local NOT_DISENCHANTABLE_SLOTS = { INVTYPE_BODY = true, INVTYPE_TABARD = true }

EQ.LABEL_COLOR = "|cffb48ef9"
local EST_ICON = "|TInterface\\COMMON\\help-i:14:14:0:0:64:64:10:54:10:54|t"
local EST_TEXT = "|cffffb000est.|r"

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

-- Callbacks run once SavedVariables are available (used by Options / MinimapButton).
ns.onLoad = {}

--------------------------------------------------------------------------------
-- Disenchant tables
--------------------------------------------------------------------------------

function EQ.Key(quality, classID, ilvl)
  return quality .. ":" .. classID .. ":" .. ilvl
end

-- The material table for a (quality, class, ilvl) key, or nil:
-- { mats = {{id, chance, qty}...}, override = bool, samples = n, items = n }
-- chance is 0..1 per disenchant, qty the average stack when it drops.
function EQ:GetTable(key)
  local o = EnchantQuexDB.overrides[key]
  if o then
    local mats = {}
    for id, v in pairs(o) do mats[#mats + 1] = { id = id, chance = v[1], qty = v[2] } end
    return { mats = mats, override = true }
  end
  local b = Data.buckets[key]
  if b then
    local mats = {}
    for i = 3, #b, 3 do mats[#mats + 1] = { id = b[i], chance = b[i + 1], qty = b[i + 2] } end
    return { mats = mats, override = false, samples = b[1], items = b[2] }
  end
end

-- Exact table, else the nearest ilvl within maxIlvlDistance (more data wins ties).
local function findTable(quality, classID, ilvl)
  local t = EQ:GetTable(EQ.Key(quality, classID, ilvl))
  if t then return t, ilvl end
  for d = 1, EnchantQuexDB.maxIlvlDistance do
    local lo = EQ:GetTable(EQ.Key(quality, classID, ilvl - d))
    local hi = EQ:GetTable(EQ.Key(quality, classID, ilvl + d))
    if lo and hi then
      if (hi.samples or 0) > (lo.samples or 0) then return hi, ilvl + d end
      return lo, ilvl - d
    elseif lo or hi then
      return lo or hi, lo and ilvl - d or ilvl + d
    end
  end
end

-- Returns nil if the item cannot be disenchanted / has no data, else the table
-- from GetTable plus: estimated (bool), quality, classID, ilvl, tableIlvl.
function EQ:GetOutcome(item)
  local _, _, quality, ilvl, _, _, _, _, equipLoc, _, _, classID = GetItemInfo(item)
  if not quality then return nil end -- not cached yet
  if (classID ~= EQ.CLASS_WEAPON and classID ~= EQ.CLASS_ARMOR) or not EQ.QUALITY_NAMES[quality]
      or NOT_DISENCHANTABLE_SLOTS[equipLoc] then
    return nil
  end
  local t, tableIlvl = findTable(quality, classID, ilvl)
  if not t then return nil end
  t.estimated = tableIlvl ~= ilvl
  t.quality, t.classID, t.ilvl, t.tableIlvl = quality, classID, ilvl, tableIlvl
  return t
end

--------------------------------------------------------------------------------
-- Auctionator pricing
--------------------------------------------------------------------------------

local function auctionatorAPI()
  return Auctionator and Auctionator.API and Auctionator.API.v1
end

function EQ:HasPriceSource()
  local api = auctionatorAPI()
  return api ~= nil and api.GetAuctionPriceByItemID ~= nil
end

-- Returns the Auctionator price of a material in copper, or nil.
function EQ:GetMatPrice(matID)
  if not self:HasPriceSource() then return nil end
  local ok, value = pcall(auctionatorAPI().GetAuctionPriceByItemID, ADDON, matID)
  if ok and value and value > 0 then return value end
end

-- Days since Auctionator last saw the material on the AH (0 = today), or nil.
function EQ:GetMatPriceAge(matID)
  local api = auctionatorAPI()
  if not (api and api.GetAuctionAgeByItemID) then return nil end
  local ok, age = pcall(api.GetAuctionAgeByItemID, ADDON, matID)
  if ok then return age end
end

-- Returns totalCopper, outcome, missingPrices (count of mats without a price).
function EQ:GetValue(item)
  local outcome = self:GetOutcome(item)
  if not outcome then return nil end
  local total, missing = 0, 0
  for _, m in ipairs(outcome.mats) do
    m.expected = m.chance * m.qty
    m.price = self:GetMatPrice(m.id)
    if m.price then
      m.value = m.expected * m.price
      total = total + m.value
    else
      missing = missing + 1
    end
  end
  return floor(total + 0.5), outcome, missing
end

--------------------------------------------------------------------------------
-- Formatting helpers
--------------------------------------------------------------------------------

-- Modern clients (Forever included) moved this under C_CurrencyInfo.
local GetCoinTextureString = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or GetCoinTextureString

local COIN_ICON = "|TInterface\\MoneyFrame\\UI-%sIcon:0:0:2:0|t"

function EQ.Money(copper)
  copper = floor(copper + 0.5)
  if GetCoinTextureString then return GetCoinTextureString(copper) end
  local g, s, c = floor(copper / 10000), floor(copper / 100) % 100, copper % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = g .. format(COIN_ICON, "Gold") end
  if s > 0 or g > 0 then parts[#parts + 1] = s .. format(COIN_ICON, "Silver") end
  parts[#parts + 1] = c .. format(COIN_ICON, "Copper")
  return table.concat(parts, " ")
end

function EQ.MatName(matID)
  return (GetItemInfo(matID)) or Data.mats[matID] or ("item " .. matID)
end

function EQ.Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage(EQ.LABEL_COLOR .. "EnchantQuex|r: " .. msg)
end

--------------------------------------------------------------------------------
-- Tooltip
--------------------------------------------------------------------------------

function EQ:AddToTooltip(tt, link)
  if not EnchantQuexDB.enabled or not link then return end
  local total, outcome, missing = self:GetValue(link)
  if not total then return end

  local label = EQ.LABEL_COLOR .. "Disenchant|r"
  if outcome.estimated then label = label .. " " .. EST_ICON .. EST_TEXT end

  local right
  if not self:HasPriceSource() then
    right = "|cff808080Auctionator not loaded|r"
  elseif missing == #outcome.mats then
    right = "|cff808080no AH data|r"
  else
    right = EQ.Money(total) .. (missing > 0 and " |cff808080+?|r" or "")
  end
  tt:AddDoubleLine(label, right, 1, 1, 1, 1, 1, 1)

  if EnchantQuexDB.alwaysShowBreakdown or IsShiftKeyDown() then
    table.sort(outcome.mats, function(a, b) return a.expected > b.expected end)
    for _, m in ipairs(outcome.mats) do
      tt:AddDoubleLine(format("   %.2fx %s |cff808080(%d%%)|r", m.expected, EQ.MatName(m.id), floor(m.chance * 100 + 0.5)),
                       m.value and EQ.Money(m.value) or "|cff808080?|r",
                       0.8, 0.8, 0.8, 1, 1, 1)
    end
    local group = format("%s %s ilvl %d", EQ.QUALITY_NAMES[outcome.quality], EQ.CLASS_NAMES[outcome.classID]:lower(),
                         outcome.tableIlvl)
    local src
    if outcome.override then
      src = "Your override for " .. group
    else
      src = format("%s (%d items, %d disenchants)", group, outcome.items, outcome.samples)
    end
    if outcome.estimated then src = "Nearest data: " .. src end
    tt:AddLine("   |cff808080" .. src .. "|r")
  end
  tt:Show()
end

local function onTooltipItem(tt)
  if tt.GetItem then
    local _, link = tt:GetItem()
    EQ:AddToTooltip(tt, link)
  end
end

local function hookTooltips()
  if TooltipDataProcessor and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, onTooltipItem)
    return
  end
  for _, name in ipairs({ "GameTooltip", "ItemRefTooltip", "ShoppingTooltip1", "ShoppingTooltip2" }) do
    local tt = _G[name]
    if tt then tt:HookScript("OnTooltipSetItem", onTooltipItem) end
  end
end

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

local function showStatus()
  local db, n = EnchantQuexDB, 0
  for _ in pairs(db.overrides) do n = n + 1 end
  EQ.Print(format("%s, ilvl distance %d, breakdown %s, %d override(s). Data from %s.",
    db.enabled and "enabled" or "disabled", db.maxIlvlDistance,
    db.alwaysShowBreakdown and "always" or "on Shift", n, Data.generated))
  if not EQ:HasPriceSource() then EQ.Print("|cffff6060Auctionator is not loaded - no prices.|r") end
end

SLASH_ENCHANTQUEX1 = "/enchantquex"
SLASH_ENCHANTQUEX2 = "/eqx"
SlashCmdList.ENCHANTQUEX = function(input)
  local cmd, arg = strtrim(input or ""):match("^(%S*)%s*(.-)$")
  cmd = cmd:lower()
  local db = EnchantQuexDB
  if cmd == "" then
    EQ:OpenOptions()
    return
  elseif cmd == "toggle" then
    db.enabled = not db.enabled
  elseif cmd == "distance" and tonumber(arg) then
    db.maxIlvlDistance = max(0, floor(tonumber(arg)))
  elseif cmd == "breakdown" then
    db.alwaysShowBreakdown = not db.alwaysShowBreakdown
  elseif cmd == "minimap" then
    EQ:SetMinimapShown(db.minimap.hide)
  elseif cmd == "prices" then
    for matID in pairs(Data.mats) do
      local p, age = EQ:GetMatPrice(matID), EQ:GetMatPriceAge(matID)
      local seen = age and (age == 0 and " (today)" or format(" (%d days old)", age)) or ""
      EQ.Print(format("%s: %s%s", EQ.MatName(matID), p and EQ.Money(p) or "no data", seen))
    end
    return
  elseif cmd ~= "status" then
    EQ.Print("/eqx (options) | status | toggle | distance <n> | breakdown | minimap | prices")
    return
  end
  showStatus()
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("MODIFIER_STATE_CHANGED")
frame:SetScript("OnEvent", function(self, event, name)
  if event == "MODIFIER_STATE_CHANGED" then
    -- redraw so the Shift breakdown appears/disappears without re-hovering
    if name:find("SHIFT") and GameTooltip:IsShown() and GameTooltip.RefreshData then
      GameTooltip:RefreshData()
    end
    return
  end
  if name ~= ADDON then return end
  EnchantQuexDB = EnchantQuexDB or {}
  for k, v in pairs(DEFAULTS) do
    if EnchantQuexDB[k] == nil then EnchantQuexDB[k] = v end
  end
  EnchantQuexDB.minSamples = nil -- removed setting
  hookTooltips()
  for _, fn in ipairs(ns.onLoad) do fn() end
  self:UnregisterEvent("ADDON_LOADED")
end)
