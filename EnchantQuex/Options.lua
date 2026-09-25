local ADDON, ns = ...
local EQ = ns.EQ
local Data = ns.Data

-- Options panel (game Settings > AddOns > EnchantQuex): general settings plus an
-- editor for per (rarity, class, item level) material table overrides.

local panel = CreateFrame("Frame")
panel.name = "EnchantQuex"
local category

-- Materials in display order: dusts, essences, shards, crystal.
local MAT_ORDER = {
  10940, 11083, 11137, 11176, 16204,
  10938, 10939, 10998, 11082, 11134, 11135, 11174, 11175, 16202, 16203,
  10978, 11084, 11138, 11139, 11177, 11178, 14343, 14344,
  20725,
}

local ROW_HEIGHT = 22
local sel = { quality = 2, classID = EQ.CLASS_ARMOR, ilvl = 20 }
local ui = { rows = {}, qualityRadios = {}, classRadios = {} }

--------------------------------------------------------------------------------
-- Widget helpers
--------------------------------------------------------------------------------

local function label(parent, text, font)
  local fs = parent:CreateFontString(nil, "ARTWORK", font or "GameFontHighlight")
  fs:SetText(text)
  return fs
end

local function checkbox(parent, text, get, set)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  cb:SetSize(26, 26)
  local l = label(cb, text)
  l:SetPoint("LEFT", cb, "RIGHT", 2, 0)
  cb:SetScript("OnClick", function(self) set(self:GetChecked()) end)
  cb.Refresh = function(self) self:SetChecked(get()) end
  return cb
end

local function editBox(parent, width, onChange)
  local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  eb:SetSize(width, 20)
  eb:SetAutoFocus(false)
  eb:SetJustifyH("RIGHT")
  eb:SetScript("OnEnterPressed", eb.ClearFocus)
  eb:SetScript("OnEscapePressed", eb.ClearFocus)
  if onChange then eb:SetScript("OnTextChanged", function(self, user) onChange(self, user) end) end
  return eb
end

local function button(parent, text, width, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width, 22)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

-- A group of radio buttons; `values` is a list of {value, text}.
local function radioGroup(parent, values, store, onSelect)
  local radios, prev = {}, nil
  for _, v in ipairs(values) do
    local r = CreateFrame("CheckButton", nil, parent, "UIRadioButtonTemplate")
    local l = label(r, v[2])
    l:SetPoint("LEFT", r, "RIGHT", 2, 0)
    r.value = v[1]
    if prev then r:SetPoint("LEFT", prev.labelFS, "RIGHT", 10, 0) end
    r.labelFS = l
    r:SetScript("OnClick", function(self)
      onSelect(self.value)
      for _, other in ipairs(radios) do other:SetChecked(other.value == self.value) end
    end)
    radios[#radios + 1] = r
    prev = r
  end
  store.radios = radios
  store.Refresh = function(current)
    for _, r in ipairs(radios) do r:SetChecked(r.value == current) end
  end
  return radios[1]
end

local function trimNumber(n, decimals)
  local s = format("%." .. decimals .. "f", n):gsub("0+$", ""):gsub("%.$", "")
  return s
end

--------------------------------------------------------------------------------
-- Override editor logic
--------------------------------------------------------------------------------

local function currentKey()
  return EQ.Key(sel.quality, sel.classID, sel.ilvl)
end

local function groupName(quality, classID, ilvl)
  return format("%s %s %d", EQ.QUALITY_NAMES[quality], EQ.CLASS_NAMES[classID]:lower(), ilvl)
end

local function updateExpected(row)
  local c, q = tonumber(row.chance:GetText()), tonumber(row.qty:GetText())
  if c and c > 0 then
    row.expected:SetText(trimNumber(c / 100 * (q or 1), 3))
  else
    row.expected:SetText("")
  end
end

local function refreshOverrideList()
  local names = {}
  for key in pairs(EnchantQuexDB.overrides) do
    local q, c, i = key:match("^(%d+):(%d+):(%d+)$")
    names[#names + 1] = { tonumber(q), tonumber(c), tonumber(i) }
  end
  table.sort(names, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    if a[2] ~= b[2] then return a[2] > b[2] end
    return a[3] < b[3]
  end)
  for i, n in ipairs(names) do names[i] = groupName(n[1], n[2], n[3]) end
  ui.overrideList:SetText(#names > 0 and ("Active overrides: " .. table.concat(names, ", "))
                          or "Active overrides: none")
end

-- Fill the material rows from the current effective table (override or Wowhead).
local function loadFields()
  local t = EQ:GetTable(currentKey())
  local byID = {}
  if t then for _, m in ipairs(t.mats) do byID[m.id] = m end end
  for _, row in ipairs(ui.rows) do
    local m = byID[row.matID]
    row.chance:SetText(m and trimNumber(m.chance * 100, 2) or "")
    row.qty:SetText(m and trimNumber(m.qty, 2) or "")
    updateExpected(row)
  end
  local status
  if not t then
    status = "|cffff6060No data for this combination.|r Enter a table and save to create an override."
  elseif t.override then
    status = "|cff40ff40Override active|r - this table replaces the Wowhead data."
  else
    status = format("Wowhead Classic data: %d items, %d disenchants.", t.items, t.samples)
  end
  ui.status:SetText(status)
  ui.removeButton:SetEnabled(t ~= nil and t.override)
end

local function saveOverride()
  local mats, n = {}, 0
  for _, row in ipairs(ui.rows) do
    local c, q = tonumber(row.chance:GetText()), tonumber(row.qty:GetText())
    if c and c > 0 then
      mats[row.matID] = { min(c, 100) / 100, (q and q > 0) and q or 1 }
      n = n + 1
    end
  end
  if n == 0 then
    EQ.Print("Enter a chance for at least one material, or use Remove override.")
    return
  end
  EnchantQuexDB.overrides[currentKey()] = mats
  EQ.Print("Saved override for " .. groupName(sel.quality, sel.classID, sel.ilvl) .. ".")
  loadFields()
  refreshOverrideList()
end

local function removeOverride()
  EnchantQuexDB.overrides[currentKey()] = nil
  EQ.Print("Removed override for " .. groupName(sel.quality, sel.classID, sel.ilvl) .. ".")
  loadFields()
  refreshOverrideList()
end

local function setIlvl(ilvl)
  sel.ilvl = max(1, min(100, floor(ilvl)))
  if ui.ilvl:GetText() ~= tostring(sel.ilvl) then ui.ilvl:SetText(sel.ilvl) end
  loadFields()
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

local function build()
  local title = label(panel, "EnchantQuex", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  local sub = label(panel, "Expected disenchant value from Wowhead Classic drop data ("
    .. Data.generated .. "), priced with Auctionator.", "GameFontHighlightSmall")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)

  -- General
  local db = function() return EnchantQuexDB end
  ui.enabled = checkbox(panel, "Show disenchant value in item tooltips",
    function() return db().enabled end, function(v) db().enabled = v end)
  ui.enabled:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", -4, -12)
  ui.breakdown = checkbox(panel, "Always show the material breakdown (otherwise hold Shift)",
    function() return db().alwaysShowBreakdown end, function(v) db().alwaysShowBreakdown = v end)
  ui.breakdown:SetPoint("TOPLEFT", ui.enabled, "BOTTOMLEFT", 0, -2)
  ui.minimap = checkbox(panel, "Show minimap button",
    function() return not db().minimap.hide end, function(v) EQ:SetMinimapShown(v) end)
  ui.minimap:SetPoint("TOPLEFT", ui.breakdown, "BOTTOMLEFT", 0, -2)

  local distLabel = label(panel, "Use the nearest item level with data up to this many levels away:")
  distLabel:SetPoint("TOPLEFT", ui.minimap, "BOTTOMLEFT", 4, -10)
  ui.distance = editBox(panel, 30, function(self, user)
    local v = tonumber(self:GetText())
    if user and v then db().maxIlvlDistance = max(0, floor(v)) end
  end)
  ui.distance:SetNumeric(true)
  ui.distance:SetMaxLetters(2)
  ui.distance:SetPoint("LEFT", distLabel, "RIGHT", 10, 0)

  -- Overrides
  local header = label(panel, "Material table overrides", "GameFontNormal")
  header:SetPoint("TOPLEFT", distLabel, "BOTTOMLEFT", 0, -20)
  local help = label(panel, "Choose a rarity, class and item level, edit the drop chance and average quantity "
    .. "per material, then save. An override always replaces the Wowhead data for that combination.",
    "GameFontHighlightSmall")
  help:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
  help:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
  help:SetJustifyH("LEFT")

  local qLabel = label(panel, "Rarity:")
  qLabel:SetPoint("TOPLEFT", help, "BOTTOMLEFT", 0, -12)
  local firstQ = radioGroup(panel, { { 2, "Uncommon" }, { 3, "Rare" }, { 4, "Epic" } }, ui.qualityRadios,
    function(v) sel.quality = v; loadFields() end)
  firstQ:SetPoint("LEFT", qLabel, "RIGHT", 8, 0)

  local cLabel = label(panel, "Class:")
  cLabel:SetPoint("TOPLEFT", qLabel, "BOTTOMLEFT", 0, -14)
  local firstC = radioGroup(panel, { { EQ.CLASS_ARMOR, "Armor" }, { EQ.CLASS_WEAPON, "Weapon" } }, ui.classRadios,
    function(v) sel.classID = v; loadFields() end)
  firstC:SetPoint("LEFT", cLabel, "RIGHT", 8, 0)

  local iLabel = label(panel, "Item level:")
  iLabel:SetPoint("TOPLEFT", cLabel, "BOTTOMLEFT", 0, -14)
  local minus = button(panel, "-", 24, function() setIlvl(sel.ilvl - 1) end)
  minus:SetPoint("LEFT", iLabel, "RIGHT", 8, 0)
  ui.ilvl = editBox(panel, 36, function(self, user)
    local v = tonumber(self:GetText())
    if user and v then setIlvl(v) end
  end)
  ui.ilvl:SetNumeric(true)
  ui.ilvl:SetMaxLetters(3)
  ui.ilvl:SetPoint("LEFT", minus, "RIGHT", 8, 0)
  local plus = button(panel, "+", 24, function() setIlvl(sel.ilvl + 1) end)
  plus:SetPoint("LEFT", ui.ilvl, "RIGHT", 4, 0)

  ui.status = label(panel, "", "GameFontHighlightSmall")
  ui.status:SetPoint("TOPLEFT", iLabel, "BOTTOMLEFT", 0, -10)

  -- Material grid
  local colName, colChance, colQty, colExp = 0, 200, 270, 340
  local hdr = CreateFrame("Frame", nil, panel)
  hdr:SetSize(420, 16)
  hdr:SetPoint("TOPLEFT", ui.status, "BOTTOMLEFT", 0, -8)
  for _, h in ipairs({ { colName, "Material" }, { colChance, "Chance %" }, { colQty, "Avg qty" },
                       { colExp, "Expected" } }) do
    local fs = label(hdr, h[2], "GameFontNormalSmall")
    fs:SetPoint("LEFT", h[1], 0)
  end

  local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, -4)
  scroll:SetSize(420, ROW_HEIGHT * 7)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(420, ROW_HEIGHT * #MAT_ORDER)
  scroll:SetScrollChild(content)

  for i, matID in ipairs(MAT_ORDER) do
    local row = { matID = matID }
    row.name = label(content, EQ.MatName(matID))
    row.name:SetPoint("TOPLEFT", colName, -(i - 1) * ROW_HEIGHT - 4)
    row.chance = editBox(content, 50, function() updateExpected(row) end)
    row.chance:SetPoint("TOPLEFT", colChance + 6, -(i - 1) * ROW_HEIGHT)
    row.qty = editBox(content, 50, function() updateExpected(row) end)
    row.qty:SetPoint("TOPLEFT", colQty + 6, -(i - 1) * ROW_HEIGHT)
    row.expected = label(content, "", "GameFontHighlightSmall")
    row.expected:SetPoint("TOPLEFT", colExp, -(i - 1) * ROW_HEIGHT - 5)
    ui.rows[i] = row
  end
  -- Tab moves through chance/qty boxes row by row.
  for i, row in ipairs(ui.rows) do
    local nextRow = ui.rows[i + 1] or ui.rows[1]
    row.chance:SetScript("OnTabPressed", function() row.qty:SetFocus() end)
    row.qty:SetScript("OnTabPressed", function() nextRow.chance:SetFocus() end)
  end

  local save = button(panel, "Save override", 120, saveOverride)
  save:SetPoint("TOPLEFT", scroll, "BOTTOMLEFT", 0, -10)
  ui.removeButton = button(panel, "Remove override", 130, removeOverride)
  ui.removeButton:SetPoint("LEFT", save, "RIGHT", 8, 0)
  local revert = button(panel, "Discard edits", 110, loadFields)
  revert:SetPoint("LEFT", ui.removeButton, "RIGHT", 8, 0)

  ui.overrideList = label(panel, "", "GameFontHighlightSmall")
  ui.overrideList:SetPoint("TOPLEFT", save, "BOTTOMLEFT", 0, -10)
  ui.overrideList:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
  ui.overrideList:SetJustifyH("LEFT")
end

local function refresh()
  ui.enabled:Refresh()
  ui.breakdown:Refresh()
  ui.minimap:Refresh()
  ui.distance:SetText(EnchantQuexDB.maxIlvlDistance)
  ui.qualityRadios.Refresh(sel.quality)
  ui.classRadios.Refresh(sel.classID)
  ui.ilvl:SetText(sel.ilvl)
  -- mat names may not have been cached when the panel was built
  for _, row in ipairs(ui.rows) do row.name:SetText(EQ.MatName(row.matID)) end
  loadFields()
  refreshOverrideList()
end

panel:SetScript("OnShow", refresh)

function EQ:OpenOptions()
  if Settings and Settings.OpenToCategory and category then
    Settings.OpenToCategory(category.GetID and category:GetID() or category.ID)
  elseif InterfaceOptionsFrame_OpenToCategory then
    InterfaceOptionsFrame_OpenToCategory(panel)
    InterfaceOptionsFrame_OpenToCategory(panel) -- first call may only open the frame
  end
end

table.insert(ns.onLoad, function()
  build()
  if Settings and Settings.RegisterCanvasLayoutCategory then
    category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    Settings.RegisterAddOnCategory(category)
  elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(panel)
  end
end)
