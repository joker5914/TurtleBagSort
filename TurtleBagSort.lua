-- TurtleBagSort v1.0.1 (Turtle 1.12 safe)
-- Key changes: VARIABLES_LOADED, no IsAddOnLoaded, conservative APIs, explicit debug

-- SavedVariables
TurtleBagSortDB = TurtleBagSortDB or {}

local RARITY_FALLBACK = 1

-- ---------------------------
-- Profiles
-- ---------------------------
local PROFILES = {
  ["type"] = {
    name = "type",
    priority = { "Quest", "Consumable", "Trade Goods", "Reagent", "Container", "Weapon", "Armor", "Misc", "Junk" },
    secondary = "rarityDesc|nameAsc|countDesc",
  },
  ["rarity"] = {
    name = "rarity",
    priority = { "Junk", "Misc", "Container", "Reagent", "Trade Goods", "Consumable", "Armor", "Weapon", "Quest" },
    secondary = "rarityDesc|nameAsc|countDesc",
  },
  ["junk"] = {
    name = "junk",
    priority = { "Junk", "Consumable", "Trade Goods", "Reagent", "Quest", "Container", "Weapon", "Armor", "Misc" },
    secondary = "nameAsc|countDesc",
  },
}

local function getActiveProfile()
  local key = TurtleBagSortDB.profile or "type"
  return PROFILES[key] or PROFILES["type"]
end

-- ---------------------------
-- Utils
-- ---------------------------
local function getContainerItemLinkCompat(bag, slot)
  if GetContainerItemLink then
    return GetContainerItemLink(bag, slot)
  end
  return nil
end

local function getItemInfoCompat(link)
  if not link then return nil end
  local name, _, quality, _, _, itemType, itemSubType = GetItemInfo(link)
  name = name or (tostring(link):match("%[(.+)%]")) or "<?>"
  return {
    name = name,
    quality = quality or RARITY_FALLBACK,
    itemType = itemType or "Misc",
    itemSubType = itemSubType or "",
  }
end

local function isEmptySlot(bag, slot)
  local texture = GetContainerItemInfo(bag, slot)
  return texture == nil
end

local function isLocked(bag, slot)
  local _, _, locked = GetContainerItemInfo(bag, slot)
  return locked
end

local function getCount(bag, slot)
  local _, count = GetContainerItemInfo(bag, slot)
  return count or 1
end

local function mapItemTypeToCategory(info)
  if not info then return "Misc" end
  local t = info.itemType or "Misc"
  if t == "Consumable" then return "Consumable"
  elseif t == "Trade Goods" then return "Trade Goods"
  elseif t == "Reagent" then return "Reagent"
  elseif t == "Quest" or t == "Quest Item" then return "Quest"
  elseif t == "Container" then return "Container"
  elseif t == "Weapon" then return "Weapon"
  elseif t == "Armor" then return "Armor"
  elseif info.quality == 0 then return "Junk"
  else return "Misc" end
end

local function allBagSlots()
  local slots = {}
  for bag = 0, 4 do
    local n = GetContainerNumSlots(bag)
    if n and n > 0 then
      for slot=1,n do
        table.insert(slots, {bag=bag, slot=slot})
      end
    end
  end
  return slots
end

local function makeItemRecord(bag, slot, profile)
  local link = getContainerItemLinkCompat(bag, slot)
  if not link then return nil end
  local meta = getItemInfoCompat(link)
  local cat = mapItemTypeToCategory(meta)
  local catRank = 999
  for i, c in ipairs(profile.priority) do
    if c == cat then catRank = i; break end
  end
  return {
    bag=bag, slot=slot, link=link,
    name=meta.name, quality=meta.quality or RARITY_FALLBACK,
    category=cat, catRank=catRank, count=getCount(bag, slot),
  }
end

local function secondaryComparator(a, b, spec)
  local function cmpRarityDesc() if a.quality ~= b.quality then return a.quality > b.quality end end
  local function cmpNameAsc()   if a.name    ~= b.name    then return a.name    < b.name    end end
  local function cmpCountDesc() if a.count   ~= b.count   then return a.count   > b.count   end end
  for token in string.gmatch(spec, "([^|]+)") do
    if token == "rarityDesc" then local r = cmpRarityDesc(); if r ~= nil then return r end
    elseif token == "nameAsc" then local r = cmpNameAsc(); if r ~= nil then return r end
    elseif token == "countDesc" then local r = cmpCountDesc(); if r ~= nil then return r end
    end
  end
  return false
end

local function sortPlan(profile)
  local slots = allBagSlots()
  local items, empties = {}, {}

  for _, s in ipairs(slots) do
    if isEmptySlot(s.bag, s.slot) then
      table.insert(empties, {bag=s.bag, slot=s.slot})
    else
      local rec = makeItemRecord(s.bag, s.slot, profile)
      if rec then table.insert(items, rec) end
    end
  end

  table.sort(items, function(a, b)
    if a.catRank ~= b.catRank then return a.catRank < b.catRank end
    return secondaryComparator(a, b, profile.secondary)
  end)

  local targets = {}
  for _, s in ipairs(slots) do table.insert(targets, {bag=s.bag, slot=s.slot}) end
  return items, empties, targets
end

local function pickup(bag, slot) ClearCursor(); PickupContainerItem(bag, slot) end
local function moveIntoEmpty(from, empty)
  if isLocked(from.bag, from.slot) or isLocked(empty.bag, empty.slot) then return false end
  pickup(from.bag, from.slot); PickupContainerItem(empty.bag, empty.slot); ClearCursor()
  return true
end
local function swap(a, b)
  if isLocked(a.bag, a.slot) or isLocked(b.bag, b.slot) then return false end
  pickup(a.bag, a.slot); PickupContainerItem(b.bag, b.slot); ClearCursor()
  return true
end

local function executeSort(profile)
  -- Always emit a visible message so the user knows /bagsort fired:
  DEFAULT_CHAT_FRAME:AddMessage("|cff88ccffTurtleBagSort: sorting ("..profile.name..")...|r")

  if InCombatLockdown and InCombatLockdown() then
    DEFAULT_CHAT_FRAME:AddMessage("|cffff5555TurtleBagSort: cannot sort in combat.|r")
    return
  end

  local items, _, targets = sortPlan(profile)

  -- Build desired flat list of item links for target order
  local desired = {}
  for i=1,#targets do desired[i] = nil end
  for i, rec in ipairs(items) do desired[i] = rec.link end

  local current = {}
  for i, t in ipairs(targets) do current[i] = getContainerItemLinkCompat(t.bag, t.slot) end

  local function indexPositions(vec)
    local map = {}
    for idx, link in ipairs(vec) do
      if link then
        map[link] = map[link] or {}
        table.insert(map[link], idx)
      end
    end
    return map
  end
  local curIdx = indexPositions(current)

  local function take(list) if list and #list>0 then return table.remove(list, 1) end end
  local function getSlotByIndex(i) return targets[i] end

  -- Coarse: for each desired slot, ensure it holds one matching copy
  for dPos, want in ipairs(desired) do
    if want and current[dPos] ~= want then
      local srcPos = take(curIdx[want])
      if srcPos and srcPos ~= dPos then
        local a, b = getSlotByIndex(srcPos), getSlotByIndex(dPos)
        local ok
        if current[dPos] then ok = swap(a, b) else ok = moveIntoEmpty(a, b) end
        if ok then
          local tmp = current[dPos]; current[dPos] = current[srcPos]; current[srcPos] = tmp
        end
      end
    end
  end

  DEFAULT_CHAT_FRAME:AddMessage("|cff55ff55TurtleBagSort: done.|r")
end

-- ---------------------------
-- Slash commands
-- ---------------------------
SLASH_TURTLEBAGSORT1 = "/bagsort"
SlashCmdList["TURTLEBAGSORT"] = function(msg)
  msg = string.lower(msg or "")
  if msg == "" or msg == "run" or msg == "go" then
    executeSort(getActiveProfile()); return
  end
  if PROFILES[msg] then
    TurtleBagSortDB.profile = msg
    DEFAULT_CHAT_FRAME:AddMessage("|cff88ff88TurtleBagSort: profile set to '"..msg.."'. Use /bagsort to sort.|r")
    return
  end
  DEFAULT_CHAT_FRAME:AddMessage("|cffffff88TurtleBagSort commands:|r")
  DEFAULT_CHAT_FRAME:AddMessage("  /bagsort           - Sort using current profile")
  DEFAULT_CHAT_FRAME:AddMessage("  /bagsort type      - Prioritize item type (default)")
  DEFAULT_CHAT_FRAME:AddMessage("  /bagsort rarity    - Prioritize rarity")
  DEFAULT_CHAT_FRAME:AddMessage("  /bagsort junk      - Pull greys forward")
end

-- ---------------------------
-- Loader (1.12 friendly)
-- ---------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("VARIABLES_LOADED")
f:SetScript("OnEvent", function()
  TurtleBagSortDB = TurtleBagSortDB or {}
  DEFAULT_CHAT_FRAME:AddMessage("|cff00d1ffTurtleBagSort loaded.|r Use |cffffff00/bagsort|r. Profile: |cffffff00" ..
    (TurtleBagSortDB.profile or "type") .. "|r")
end)
