local ADDON, ns = ...
local EQ = ns.EQ

-- Disenchant scan: an auction house tab listing every disenchantable weapon and
-- armor item in Auctionator's price database (filled by its full scan) with its
-- lowest buyout, its expected disenchant value, and the cost as a percentage of
-- that value (lower is better). Filters for cost, value and % are saved in
-- EnchantQuexDB.deScan. Clicking a row searches for the item in Auctionator's
-- Shopping tab.
--
-- The item list is read from Auctionator.Database.db (item ID -> { m = last
-- lowest buyout, ... }). That table is internal to Auctionator, so every access
-- is guarded and the tab says so if it isn't there.
--
-- The tab is added to the (modern) auction house with LibAHTab, which ships with
-- Auctionator.

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local RequestLoadItemDataByID = C_Item and C_Item.RequestLoadItemDataByID

local ROW_HEIGHT = 20
local TAB_ID = "EnchantQuexDisenchant"
local TAB_TEXT = "Disenchant"
local TAB_HEADER = "EnchantQuex - Disenchant scan"

-- Right-hand columns; the item name fills the space left of them.
local COLUMNS = {
  { key = "ilvl", title = "iLvl", width = 40 },
  { key = "qty", title = "Available", width = 60 },
  { key = "cost", title = "Cost", width = 130 },
  { key = "value", title = "DE value", width = 130 },
  { key = "pct", title = "% of value", width = 80 },
}

local panel, ui
local all = {}     -- every candidate: { id, name, icon, quality, ilvl, cost, value, partial, pct, qty, qtyKnown, age }
local shown = {}   -- `all` filtered and sorted
local waiting = 0  -- items skipped because their info isn't cached yet
local offset = 0   -- first visible index into `shown`

local function settings()
  return EnchantQuexDB.deScan
end

--------------------------------------------------------------------------------
-- Building the list
--------------------------------------------------------------------------------

local function priceDB()
  local db = Auctionator and Auctionator.Database
  return db and type(db.db) == "table" and db.db
end

local function priceAge(itemID)
  local api = Auctionator and Auctionator.API and Auctionator.API.v1
  if not (api and api.GetAuctionAgeByItemID) then return nil end
  local ok, age = pcall(api.GetAuctionAgeByItemID, ADDON, itemID)
  if ok then return age end
end

-- itemID -> "pending" / "failed" for items whose info was requested this session.
-- Each item is requested once: re-requesting thousands of items on every rebuild
-- made the client evict and reload them in a loop, and the list flickered.
local requested = {}

-- { name, quality, ilvl, equipLoc } from EnchantQuexDB.itemInfo, else from the
-- client's item cache (then saved), else requested and nil for now.
local function itemInfo(id)
  local cache = EnchantQuexDB.itemInfo
  if cache[id] then return cache[id] end
  local name, _, quality, ilvl, _, _, _, _, equipLoc = GetItemInfo(id)
  if name then
    cache[id] = { name, quality, ilvl, equipLoc }
    requested[id] = nil
    return cache[id]
  end
  if not requested[id] then
    requested[id] = "pending"
    if RequestLoadItemDataByID then RequestLoadItemDataByID(id) end
  end
end

-- Highest quantity listed on the most recent day Auctionator saw the item (the
-- total across all prices, not only the lowest), or nil if it wasn't recorded.
local function available(entry)
  local day, qty
  for d, n in pairs(type(entry.a) == "table" and entry.a or {}) do
    d = tonumber(d)
    if d and (not day or d > day) then day, qty = d, n end
  end
  return qty
end

-- Returns false when Auctionator's price database isn't available.
local function collect()
  wipe(all)
  waiting = 0
  local db = priceDB()
  if not db then return false end
  for key, entry in pairs(db) do
    local id = tonumber(key) -- skips "g:"/"gr:" variant keys; the plain key holds the lowest of them
    local cost = id and type(entry) == "table" and entry.m
    local classID = cost and cost > 0 and select(6, GetItemInfoInstant(id))
    if classID == EQ.CLASS_WEAPON or classID == EQ.CLASS_ARMOR then
      local info = itemInfo(id)
      if not info then
        if requested[id] == "pending" then waiting = waiting + 1 end
      else
        local name, quality, ilvl, equipLoc = unpack(info)
        local value, _, missing = EQ:GetOutcomeValue(EQ:GetOutcomeByInfo(quality, classID, ilvl, equipLoc))
        if value and value > 0 then
          local qty = available(entry)
          all[#all + 1] = {
            id = id, name = name, quality = quality, ilvl = ilvl,
            icon = select(5, GetItemInfoInstant(id)),
            cost = cost, value = value, partial = missing > 0, pct = cost / value * 100,
            qty = qty or 0, qtyKnown = qty ~= nil,
            age = priceAge(id),
          }
        end
      end
    end
  end
  return true
end

-- A filter box's number, or nil when empty. Gold boxes are converted to copper.
local function limit(field, gold)
  local v = tonumber(settings()[field] or "")
  if v and gold then v = v * 10000 end
  return v
end

local function within(v, lo, hi)
  return (not lo or v >= lo) and (not hi or v <= hi)
end

local function applyFilters()
  local s = settings()
  local minCost, maxCost = limit("minCost", true), limit("maxCost", true)
  local minValue, maxValue = limit("minValue", true), limit("maxValue", true)
  local minPct, maxPct = limit("minPct"), limit("maxPct")
  wipe(shown)
  for _, row in ipairs(all) do
    if within(row.cost, minCost, maxCost) and within(row.value, minValue, maxValue)
        and within(row.pct, minPct, maxPct) and (not s.todayOnly or row.age == 0) then
      shown[#shown + 1] = row
    end
  end
  local key, asc = s.sortKey, s.sortAsc
  table.sort(shown, function(a, b)
    local x, y = a[key], b[key]
    if x == y then return a.name < b.name end
    if asc then return x < y end
    return x > y
  end)
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

local function pctColor(pct)
  if pct < 80 then return "|cff40ff40" end
  if pct < 100 then return "|cffffd100" end
  return "|cffff6060"
end

local function visibleRows()
  return max(1, floor(ui.list:GetHeight() / ROW_HEIGHT))
end

local function draw()
  local n = visibleRows()
  offset = max(0, min(offset, #shown - n))
  for i = 1, max(n, #ui.rows) do
    local row = ui.rows[i]
    local data = i <= n and shown[offset + i]
    if data then
      row = row or ui.createRow(i)
      row.data = data
      row.icon:SetTexture(data.icon)
      local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[data.quality]
      row.name:SetText((color and color.hex or "") .. data.name .. "|r")
      row.cols.ilvl:SetText(data.ilvl)
      row.cols.qty:SetText(data.qtyKnown and data.qty or "|cff808080?|r")
      row.cols.cost:SetText(EQ.Money(data.cost))
      row.cols.value:SetText(EQ.Money(data.value) .. (data.partial and " |cff808080+?|r" or ""))
      row.cols.pct:SetText(format("%s%d%%|r", pctColor(data.pct), floor(data.pct + 0.5)))
      row:Show()
    elseif row then
      row:Hide()
    end
  end

  local scrollMax = max(0, #shown - n)
  ui.bar:SetMinMaxValues(0, scrollMax)
  ui.bar:SetValue(offset)
  ui.bar:SetShown(scrollMax > 0)

  for _, col in ipairs(ui.headers) do
    col:GetFontString():SetTextColor(1, col.key == settings().sortKey and 1 or 0.82, col.key == settings().sortKey and 1 or 0)
  end
end

local function setStatus()
  local text
  if not priceDB() then
    text = "|cffff6060Auctionator's price database is not available.|r This tab needs Auctionator."
  elseif #all == 0 and waiting == 0 then
    text = "No disenchantable items in Auctionator's price data yet. Run a full scan from Auctionator's tab."
  else
    text = format("%d of %d items shown", #shown, #all)
    if waiting > 0 then text = text .. format(" |cff808080(%d still loading item info)|r", waiting) end
    if settings().todayOnly then text = text .. " |cff808080- only prices from today's scans|r" end
  end
  ui.status:SetText(text)
end

local function refilter()
  if not panel or not panel:IsVisible() then return end
  applyFilters()
  setStatus()
  draw()
end

local function rebuild()
  if not panel or not panel:IsVisible() then return end
  collect()
  refilter()
end

-- Rebuilds once after a burst of changes (item info arriving, a scan being saved).
local rebuildPending = false
local function scheduleRebuild(delay)
  if rebuildPending then return end
  rebuildPending = true
  C_Timer.After(delay, function()
    rebuildPending = false
    rebuild()
  end)
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

local function filterBox(parent, field, width)
  local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  eb:SetSize(width or 50, 20)
  eb:SetAutoFocus(false)
  eb:SetJustifyH("RIGHT")
  eb:SetText(settings()[field] or "")
  eb:SetScript("OnEnterPressed", eb.ClearFocus)
  eb:SetScript("OnEscapePressed", eb.ClearFocus)
  eb:SetScript("OnTextChanged", function(self, user)
    if not user then return end
    local text = strtrim(self:GetText())
    settings()[field] = text ~= "" and text or nil
    offset = 0
    refilter()
  end)
  return eb
end

-- "<label> min [ ] max [ ]" placed right of `anchor`; returns the last box.
local function rangeFilter(parent, anchor, text, minField, maxField, tooltip)
  local l = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  l:SetText(text)
  if anchor then
    l:SetPoint("LEFT", anchor, "RIGHT", 18, 0)
  else
    l:SetPoint("TOPLEFT", 10, -10)
  end
  local lo = filterBox(parent, minField)
  lo:SetPoint("LEFT", l, "RIGHT", 10, 0)
  local dash = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  dash:SetText("-")
  dash:SetPoint("LEFT", lo, "RIGHT", 4, 0)
  local hi = filterBox(parent, maxField)
  hi:SetPoint("LEFT", dash, "RIGHT", 8, 0)
  for _, eb in ipairs({ lo, hi }) do
    eb:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:SetText(tooltip, 1, 1, 1, 1, true)
      GameTooltip:Show()
    end)
    eb:SetScript("OnLeave", GameTooltip_Hide)
  end
  return hi
end

local function rowOnEnter(self)
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:SetHyperlink("item:" .. self.data.id)
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Click to search for it in Auctionator's Shopping tab.", 0.5, 0.5, 0.5)
  GameTooltip:Show()
end

local function rowOnClick(self)
  local api = Auctionator and Auctionator.API and Auctionator.API.v1
  -- Not an exact search: random-suffix items ("... of the Bear") are listed under the base name.
  if not (api and api.MultiSearch and pcall(api.MultiSearch, ADDON, { self.data.name })) then
    EQ.Print("Couldn't start an Auctionator search for " .. self.data.name .. ".")
  end
end

local function build()
  local s = settings()
  ui = { rows = {}, headers = {} }

  -- Filters
  local last = rangeFilter(panel, nil, "Cost (g)", "minCost", "maxCost",
    "Lowest buyout in gold (e.g. 1.5 = 1g 50s). Leave empty for no limit.")
  last = rangeFilter(panel, last, "DE value (g)", "minValue", "maxValue",
    "Expected disenchant value in gold. Leave empty for no limit.")
  last = rangeFilter(panel, last, "% of value", "minPct", "maxPct",
    "Cost as a percentage of the disenchant value. Below 100% is a profit on average.")

  local today = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  today:SetSize(24, 24)
  today:SetPoint("TOPLEFT", 6, -34)
  today:SetChecked(s.todayOnly)
  today:SetScript("OnClick", function(self)
    s.todayOnly = self:GetChecked()
    offset = 0
    refilter()
  end)
  local todayLabel = today:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  todayLabel:SetPoint("LEFT", today, "RIGHT", 2, 0)
  todayLabel:SetText("Only prices seen today (older prices may be gone)")

  local refresh = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  refresh:SetSize(90, 22)
  refresh:SetText(REFRESH or "Refresh")
  refresh:SetPoint("TOPRIGHT", -10, -8)
  refresh:SetScript("OnClick", rebuild)

  ui.status = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  ui.status:SetPoint("TOPRIGHT", -10, -40)
  ui.status:SetJustifyH("RIGHT")

  -- Column headers (click to sort; again to reverse)
  local header = CreateFrame("Frame", nil, panel)
  header:SetPoint("TOPLEFT", 8, -62)
  header:SetPoint("TOPRIGHT", -26, -62)
  header:SetHeight(18)
  local function headerButton(key, title, width)
    local b = CreateFrame("Button", nil, header)
    b.key = key
    b:SetHeight(18)
    if width then b:SetWidth(width) end
    b:SetNormalFontObject("GameFontNormalSmall")
    b:SetText(title)
    b:GetFontString():SetJustifyH(width and "RIGHT" or "LEFT")
    b:GetFontString():SetAllPoints()
    b:SetScript("OnClick", function()
      if s.sortKey == key then
        s.sortAsc = not s.sortAsc
      else
        s.sortKey, s.sortAsc = key, key == "pct" or key == "name" or key == "cost"
      end
      refilter()
    end)
    ui.headers[#ui.headers + 1] = b
    return b
  end
  local right
  for i = #COLUMNS, 1, -1 do
    local c = COLUMNS[i]
    local b = headerButton(c.key, c.title, c.width)
    if right then b:SetPoint("RIGHT", right, "LEFT", -8, 0) else b:SetPoint("RIGHT") end
    right = b
  end
  local nameHeader = headerButton("name", "Item")
  nameHeader:SetPoint("LEFT", 24, 0)
  nameHeader:SetPoint("RIGHT", right, "LEFT", -8, 0)

  -- List
  local inset = CreateFrame("Frame", nil, panel, "InsetFrameTemplate")
  inset:SetPoint("TOPLEFT", 4, -82)
  inset:SetPoint("BOTTOMRIGHT", -4, 4)
  ui.list = CreateFrame("Frame", nil, inset)
  ui.list:SetPoint("TOPLEFT", 4, -4)
  ui.list:SetPoint("BOTTOMRIGHT", -18, 4)
  ui.list:EnableMouseWheel(true)
  ui.list:SetScript("OnMouseWheel", function(_, delta)
    offset = offset - delta * 3
    draw()
  end)
  ui.list:SetScript("OnSizeChanged", function() if panel:IsVisible() then draw() end end)

  ui.bar = CreateFrame("Slider", nil, inset)
  ui.bar:SetOrientation("VERTICAL")
  ui.bar:SetWidth(14)
  ui.bar:SetPoint("TOPRIGHT", -3, -6)
  ui.bar:SetPoint("BOTTOMRIGHT", -3, 6)
  ui.bar:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
  ui.bar:GetThumbTexture():SetSize(16, 24)
  ui.bar:SetValueStep(1)
  if ui.bar.SetObeyStepOnDrag then ui.bar:SetObeyStepOnDrag(true) end
  local track = ui.bar:CreateTexture(nil, "BACKGROUND")
  track:SetAllPoints()
  track:SetColorTexture(0, 0, 0, 0.35)
  ui.bar:SetScript("OnValueChanged", function(_, v, user)
    if user == false then return end -- set by draw()
    local new = floor(v + 0.5)
    if new ~= offset then
      offset = new
      draw()
    end
  end)

  function ui.createRow(i)
    local row = CreateFrame("Button", nil, ui.list)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", 0, -(i - 1) * ROW_HEIGHT)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    if i % 2 == 0 then
      local stripe = row:CreateTexture(nil, "BACKGROUND")
      stripe:SetAllPoints()
      stripe:SetColorTexture(1, 1, 1, 0.04)
    end
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ROW_HEIGHT - 4, ROW_HEIGHT - 4)
    row.icon:SetPoint("LEFT", 2, 0)
    row.cols = {}
    local rightCol
    for c = #COLUMNS, 1, -1 do
      local col = COLUMNS[c]
      local fs = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
      fs:SetWidth(col.width)
      fs:SetJustifyH("RIGHT")
      if rightCol then fs:SetPoint("RIGHT", rightCol, "LEFT", -8, 0) else fs:SetPoint("RIGHT", -4, 0) end
      row.cols[col.key] = fs
      rightCol = fs
    end
    row.name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetPoint("RIGHT", rightCol, "LEFT", -8, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row:SetScript("OnEnter", rowOnEnter)
    row:SetScript("OnLeave", GameTooltip_Hide)
    row:SetScript("OnClick", rowOnClick)
    ui.rows[i] = row
    return row
  end

  panel:SetScript("OnShow", function()
    offset = 0
    rebuild()
  end)
end

--------------------------------------------------------------------------------
-- Auction house tab
--------------------------------------------------------------------------------

local function createTab()
  if panel then return true end
  local LibAHTab = LibStub and LibStub("LibAHTab-1-0", true)
  if not (AuctionHouseFrame and LibAHTab) then return false end
  panel = CreateFrame("Frame", "EnchantQuexDisenchantScanFrame", AuctionHouseFrame)
  panel:SetPoint("TOPLEFT", 4, -60)
  panel:SetPoint("BOTTOMRIGHT", -4, 27)
  LibAHTab:CreateTab(TAB_ID, panel, TAB_TEXT, TAB_HEADER)
  build()

  -- Rebuild after Auctionator saves scan results while the tab is open.
  local db = Auctionator and Auctionator.Database
  if db and type(db.SetPrice) == "function" then
    hooksecurefunc(db, "SetPrice", function()
      if panel:IsVisible() then scheduleRebuild(1) end
    end)
  end
  return true
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, ...)
  if event == "GET_ITEM_INFO_RECEIVED" then
    local itemID, success = ...
    if requested[itemID] == "pending" then
      if success == false then requested[itemID] = "failed" end
      if panel and panel:IsVisible() then scheduleRebuild(0.5) end
    end
  elseif event == "AUCTION_HOUSE_SHOW" then
    if not createTab() then
      C_Timer.After(0, createTab) -- the auction house UI may finish loading a frame later
    end
  end
end)

table.insert(ns.onLoad, function()
  for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "GET_ITEM_INFO_RECEIVED" }) do
    pcall(events.RegisterEvent, events, e)
  end
end)
