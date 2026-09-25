local _, ns = ...
local EQ = ns.EQ

-- Standard round minimap button (same look as LibDBIcon), dragged around the
-- minimap edge; the angle is saved in EnchantQuexDB.minimap.angle.

local RADIUS_OFFSET = 10
local button

local function updatePosition()
  local angle = math.rad(EnchantQuexDB.minimap.angle)
  local r = Minimap:GetWidth() / 2 + RADIUS_OFFSET
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

local function onDragUpdate()
  local mx, my = Minimap:GetCenter()
  local px, py = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  EnchantQuexDB.minimap.angle = math.deg(math.atan2(py / scale - my, px / scale - mx)) % 360
  updatePosition()
end

local function create()
  button = CreateFrame("Button", "EnchantQuexMinimapButton", Minimap)
  button:SetSize(31, 31)
  button:SetFrameStrata("MEDIUM")
  button:SetFrameLevel(8)
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  button:RegisterForDrag("LeftButton")
  button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local bg = button:CreateTexture(nil, "BACKGROUND")
  bg:SetSize(20, 20)
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetPoint("TOPLEFT", 7, -5)

  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetSize(17, 17)
  icon:SetTexture("Interface\\Icons\\Trade_Engraving") -- Enchanting
  icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
  icon:SetPoint("TOPLEFT", 7, -6)

  local border = button:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetPoint("TOPLEFT")

  button:SetScript("OnClick", function() EQ:OpenOptions() end)
  button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", onDragUpdate) end)
  button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("EnchantQuex")
    GameTooltip:AddLine("Click: options and overrides", 1, 1, 1)
    GameTooltip:AddLine("Drag: move button", 1, 1, 1)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)
  updatePosition()
end

function EQ:SetMinimapShown(shown)
  EnchantQuexDB.minimap.hide = not shown
  if button then button:SetShown(shown) end
end

table.insert(ns.onLoad, function()
  create()
  button:SetShown(not EnchantQuexDB.minimap.hide)
end)
