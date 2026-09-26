-- Announces completed trades: what each side gave (item links with quantities, and
-- money) and any enchants applied through the "Will not be traded" slot. Goes to
-- party chat when in a group, otherwise /say.
--
-- The trade window is empty by the time "Trade complete" arrives, so its contents
-- are snapshotted on every change while it is open.
--
-- /say from addons is blocked outside instances unless it runs in a hardware event,
-- so outside a group and instance the announcement waits for the next key press or
-- click on the game world.

local SLOTS = MAX_TRADE_ITEMS or 7
local ENCHANT_SLOT = TRADE_ENCHANT_SLOT or 7
local MAX_MESSAGE = 255
local SendChatMessage = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage

local snapshot

local function money(copper)
  local g, s, c = floor(copper / 10000), floor(copper / 100) % 100, copper % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = g .. "g" end
  if s > 0 then parts[#parts + 1] = s .. "s" end
  if c > 0 then parts[#parts + 1] = c .. "c" end
  return table.concat(parts, " ")
end

local function itemText(link, name, quantity)
  local text = link or name
  if text and quantity and quantity > 1 then text = text .. " x" .. quantity end
  return text
end

-- The enchant name among Get*TradeItemInfo's returns: 5th for the player and 6th for
-- the target on Classic, but the order has differed between clients.
local function enchantOf(name, _, _, _, a, b)
  if not name then return nil end
  if type(a) == "string" and a ~= "" then return a end
  if type(b) == "string" and b ~= "" then return b end
end

local function takeSnapshot()
  local s = {
    player = UnitName("player"),
    target = UnitName("NPC") or (snapshot and snapshot.target) or "?",
    gave = {}, got = {},
    gaveMoney = GetPlayerTradeMoney(), gotMoney = GetTargetTradeMoney(),
  }
  for i = 1, SLOTS do
    if i == ENCHANT_SLOT then
      -- Items in the enchant slot stay with their owner; only the enchant matters.
      local enchant = enchantOf(GetTradePlayerItemInfo(i))
      if enchant then
        s.theyEnchanted = { item = itemText(GetTradePlayerItemLink(i), (GetTradePlayerItemInfo(i))), enchant = enchant }
      end
      enchant = enchantOf(GetTradeTargetItemInfo(i))
      if enchant then
        s.weEnchanted = { item = itemText(GetTradeTargetItemLink(i), (GetTradeTargetItemInfo(i))), enchant = enchant }
      end
    else
      local name, _, quantity = GetTradePlayerItemInfo(i)
      if name then s.gave[#s.gave + 1] = itemText(GetTradePlayerItemLink(i), name, quantity) end
      local tName, _, tQuantity = GetTradeTargetItemInfo(i)
      if tName then s.got[#s.got + 1] = itemText(GetTradeTargetItemLink(i), tName, tQuantity) end
    end
  end
  if s.gaveMoney > 0 then s.gave[#s.gave + 1] = money(s.gaveMoney) end
  if s.gotMoney > 0 then s.got[#s.got + 1] = money(s.gotMoney) end
  snapshot = s
end

-- "<prefix>a, b, c" split into as many messages as needed to stay under the limit.
local function addList(lines, prefix, parts)
  local line
  for _, part in ipairs(parts) do
    if line and #line + 2 + #part <= MAX_MESSAGE then
      line = line .. ", " .. part
    else
      if line then lines[#lines + 1] = line end
      line = (line and "... " or prefix) .. part
    end
  end
  if line then lines[#lines + 1] = line end
end

local function buildLines(s)
  local lines = {}
  addList(lines, format("%s traded %s: ", s.player, s.target), s.gave)
  addList(lines, format("%s traded %s: ", s.target, s.player), s.got)
  if s.weEnchanted then
    lines[#lines + 1] = format("%s enchanted %s's %s with %s", s.player, s.target, s.weEnchanted.item,
      s.weEnchanted.enchant)
  end
  if s.theyEnchanted then
    lines[#lines + 1] = format("%s enchanted %s's %s with %s", s.target, s.player, s.theyEnchanted.item,
      s.theyEnchanted.enchant)
  end
  return lines
end

--------------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------------

local pending = {} -- /say lines waiting for a hardware event

local function flushPending()
  for _, line in ipairs(pending) do SendChatMessage(line, "SAY") end
  wipe(pending)
end

local function send(lines)
  if IsInGroup() then
    for _, line in ipairs(lines) do SendChatMessage(line, "PARTY") end
  elseif IsInInstance() then
    for _, line in ipairs(lines) do SendChatMessage(line, "SAY") end
  else
    for _, line in ipairs(lines) do pending[#pending + 1] = line end
  end
end

-- Hardware events that flush pending /say lines. The keyboard catcher passes every
-- key on to the game and only listens while something is pending.
local keyCatcher = CreateFrame("Frame", nil, UIParent)
keyCatcher:SetScript("OnKeyDown", function(self)
  flushPending()
  if not InCombatLockdown() then self:EnableKeyboard(false) end
end)
WorldFrame:HookScript("OnMouseDown", function()
  if #pending > 0 then flushPending() end
end)

local function queueFlushOnKey()
  if #pending == 0 or InCombatLockdown() then return end
  keyCatcher:SetPropagateKeyboardInput(true)
  keyCatcher:EnableKeyboard(true)
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, ...)
  if event == "TRADE_SHOW" then
    snapshot = nil
    takeSnapshot()
  elseif event == "UI_INFO_MESSAGE" then
    -- (messageType, message) on current clients, (message) on old ones
    local a, b = ...
    if (a == ERR_TRADE_COMPLETE or b == ERR_TRADE_COMPLETE) and snapshot then
      local s = snapshot
      snapshot = nil
      if EnchantQuexDB.announceTrades then
        local lines = buildLines(s)
        if #lines > 0 then
          send(lines)
          queueFlushOnKey()
        end
      end
    end
  elseif TradeFrame and TradeFrame:IsShown() then
    takeSnapshot() -- items, money or accept state changed
  end
end)

for _, e in ipairs({ "TRADE_SHOW", "TRADE_PLAYER_ITEM_CHANGED", "TRADE_TARGET_ITEM_CHANGED",
                     "TRADE_MONEY_CHANGED", "TRADE_ACCEPT_UPDATE", "UI_INFO_MESSAGE" }) do
  pcall(events.RegisterEvent, events, e) -- in case the client lacks one
end
