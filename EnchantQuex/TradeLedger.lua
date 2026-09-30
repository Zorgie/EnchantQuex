local _, ns = ...
local EQ = ns.EQ

-- Trade ledger: a window (minimap button, /eqx ledger) listing each player who
-- traded you items and what you still hold of theirs. After every completed trade:
--   * items they gave you are added to their entry,
--   * items you gave back to a listed player are taken off it (never below zero),
--   * an enchant you put on their item takes that enchant's reagents off it. If
--     their materials didn't cover it the count goes negative (shown in red): you
--     used your own.
-- The X on an entry removes it. Saved per character in EnchantQuexCharDB.ledger:
--   { { name = "Player", items = { { id = itemID, link = link, count = n }... } }... }
-- most recently traded first.

local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant

local WIDTH, HEIGHT = 340, 420
local ICON, ICON_GAP, PAD = 30, 4, 6

local frame, refresh

--------------------------------------------------------------------------------
-- Ledger data
--------------------------------------------------------------------------------

local function ledger()
  return EnchantQuexCharDB.ledger
end

-- The player's entry, moved to the top; created if `create` is set.
local function entryFor(name, create)
  local list = ledger()
  for i, entry in ipairs(list) do
    if entry.name == name then
      table.remove(list, i)
      table.insert(list, 1, entry)
      return entry
    end
  end
  if create then
    local entry = { name = name, items = {} }
    table.insert(list, 1, entry)
    return entry
  end
end

local function itemIDOf(link)
  return link and tonumber(link:match("item:(%d+)"))
end

-- Adds `count` (negative to take off) of an item to an entry. Items that reach
-- zero are dropped; with `clamp` the count never goes below zero.
local function change(entry, id, link, count, clamp)
  for i, item in ipairs(entry.items) do
    if item.id == id then
      item.count = item.count + count
      if clamp and item.count < 0 then item.count = 0 end
      if item.count == 0 then table.remove(entry.items, i) end
      return
    end
  end
  if count > 0 or not clamp then
    entry.items[#entry.items + 1] = { id = id, link = link, count = count }
  end
end

-- Reagents of an enchant as named in the trade window, or nil if not learned.
local function reagentsOf(enchantName)
  local known = EnchantQuexCharDB.enchants
  local enchant = known[enchantName] or known["Enchant " .. enchantName]
  return enchant and enchant.reagents
end

local function onTradeComplete(s)
  local entry
  if #s.gotItems > 0 then
    entry = entryFor(s.target, true)
    for _, item in ipairs(s.gotItems) do
      local id = itemIDOf(item.link)
      if id then change(entry, id, item.link, item.quantity) end
    end
  else
    entry = entryFor(s.target, false)
  end
  if entry then
    for _, item in ipairs(s.gaveItems) do
      local id = itemIDOf(item.link)
      if id then change(entry, id, item.link, -item.quantity, true) end
    end
    if s.weEnchanted then
      local reagents = reagentsOf(s.weEnchanted.enchant)
      if reagents then
        for _, r in ipairs(reagents) do change(entry, r.id, nil, -r.count) end
      else
        EQ.Print(format("Unknown enchant \"%s\"; its materials were not taken off %s's ledger entry. "
          .. "Open your Enchanting window so EnchantQuex learns your recipes.", s.weEnchanted.enchant, s.target))
      end
    end
  end
  if frame and frame:IsShown() then refresh() end
end

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------

local rows = {}

local function itemButtonOnEnter(self)
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  if self.link then
    GameTooltip:SetHyperlink(self.link)
  else
    GameTooltip:SetItemByID(self.id)
  end
  GameTooltip:Show()
end

local function itemButton(row)
  local b = CreateFrame("Button", nil, row)
  b:SetSize(ICON, ICON)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetAllPoints()
  b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  b.count:SetPoint("BOTTOMRIGHT", -1, 2)
  b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  b:SetScript("OnEnter", itemButtonOnEnter)
  b:SetScript("OnLeave", GameTooltip_Hide)
  return b
end

local function createRow(parent)
  local row = CreateFrame("Frame", nil, parent)
  row.name = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  row.name:SetPoint("TOPLEFT", 4, -4)
  row.remove = CreateFrame("Button", nil, row, "UIPanelCloseButton")
  row.remove:SetSize(22, 22)
  row.remove:SetPoint("TOPRIGHT", 0, 2)
  row.remove:SetScript("OnClick", function()
    for i, entry in ipairs(ledger()) do
      if entry == row.entry then table.remove(ledger(), i) break end
    end
    refresh()
  end)
  row.remove:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Remove " .. row.entry.name)
    GameTooltip:Show()
  end)
  row.remove:SetScript("OnLeave", GameTooltip_Hide)
  row.empty = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  row.empty:SetText("Nothing left")
  row.divider = row:CreateTexture(nil, "BACKGROUND")
  row.divider:SetColorTexture(1, 1, 1, 0.1)
  row.divider:SetHeight(1)
  row.divider:SetPoint("BOTTOMLEFT")
  row.divider:SetPoint("BOTTOMRIGHT")
  row.buttons = {}
  return row
end

-- Lays out one entry; returns the row's height.
local function fillRow(row, entry, width)
  row.entry = entry
  row.name:SetText(entry.name)
  local perLine = max(1, floor((width - 8 + ICON_GAP) / (ICON + ICON_GAP)))
  local top = -(row.name:GetStringHeight() + 8)
  for i, item in ipairs(entry.items) do
    local b = row.buttons[i] or itemButton(row)
    row.buttons[i] = b
    b.id, b.link = item.id, item.link
    b.icon:SetTexture(select(5, GetItemInfoInstant(item.id)) or 134400) -- question mark
    b.count:SetText(item.count)
    if item.count < 0 then b.count:SetTextColor(1, 0.25, 0.25) else b.count:SetTextColor(1, 1, 1) end
    local line, col = floor((i - 1) / perLine), (i - 1) % perLine
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", 4 + col * (ICON + ICON_GAP), top - line * (ICON + ICON_GAP))
    b:Show()
  end
  for i = #entry.items + 1, #row.buttons do row.buttons[i]:Hide() end
  row.empty:SetShown(#entry.items == 0)
  if #entry.items == 0 then
    row.empty:SetPoint("TOPLEFT", 4, top)
    return -top + row.empty:GetStringHeight() + PAD
  end
  local lines = ceil(#entry.items / perLine)
  return -top + lines * (ICON + ICON_GAP) - ICON_GAP + PAD
end

refresh = function()
  local content = frame.content
  local width = frame.scroll:GetWidth()
  if width <= 0 then width = WIDTH - 44 end -- not laid out yet
  content:SetWidth(width)
  local y = 0
  for i, entry in ipairs(ledger()) do
    local row = rows[i] or createRow(content)
    rows[i] = row
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, -y)
    row:SetWidth(width)
    local h = fillRow(row, entry, width)
    row:SetHeight(h)
    row:Show()
    y = y + h + PAD
  end
  for i = #ledger() + 1, #rows do rows[i]:Hide() end
  content:SetHeight(max(y, 1))
  frame.emptyText:SetShown(#ledger() == 0)
end

local function create()
  frame = CreateFrame("Frame", "EnchantQuexLedgerFrame", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(WIDTH, HEIGHT)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("DIALOG")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:Hide()
  tinsert(UISpecialFrames, frame:GetName()) -- Escape closes it

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  title:SetPoint("TOP", 0, -5)
  title:SetText("EnchantQuex - Trade ledger")

  local help = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  help:SetPoint("TOPLEFT", 14, -32)
  help:SetPoint("RIGHT", -14, 0)
  help:SetJustifyH("LEFT")
  help:SetText("Items players traded you. Enchants you put on their items take off the materials used.")

  frame.scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
  frame.scroll:SetPoint("TOPLEFT", help, "BOTTOMLEFT", -2, -8)
  frame.scroll:SetPoint("BOTTOMRIGHT", -30, 10)
  frame.content = CreateFrame("Frame", nil, frame.scroll)
  frame.content:SetSize(1, 1)
  frame.scroll:SetScrollChild(frame.content)

  frame.emptyText = frame:CreateFontString(nil, "ARTWORK", "GameFontDisable")
  frame.emptyText:SetPoint("CENTER", frame.scroll)
  frame.emptyText:SetText("No trades yet.")

  frame:SetScript("OnShow", refresh)
end

function EQ:ToggleLedger()
  if not frame then create() end
  frame:SetShown(not frame:IsShown())
end

table.insert(ns.onLoad, function()
  EnchantQuexCharDB = EnchantQuexCharDB or {}
  EnchantQuexCharDB.ledger = EnchantQuexCharDB.ledger or {}
end)
table.insert(ns.onTradeComplete, onTradeComplete)
