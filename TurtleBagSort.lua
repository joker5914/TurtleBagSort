-- TurtleBagSort: Simple, macro-friendly bag sorter for Turtle WoW (1.12)
-- Works alongside Bagnon (we only move items, we don't draw frames)

local ADDON = ...
local TBS = {}
TurtleBagSortDB = TurtleBagSortDB or {}

-- ---------------------------
-- Config / Profiles
-- ---------------------------
-- Profiles define category priority + secondary sort.
-- priority: lower index = earlier placement (top-left in unified views)
-- secondary: "rarityDesc|nameAsc|countDesc"
local DEFAULT_PROFILE = {
  name = "type",
  priority = { "Quest", "Consumable", "Trade Goods", "Reagent", "Container", "Weapon", "Armor", "Misc", "Junk" },
  secondary = "rarityDesc|nameAsc|countDesc",
}

local RARITY_FALLBACK = 1 -- if we fail to detect, assume common

local PROFILES = {
  ["type"]   = DEFAULT_PROFILE,
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

-- Allow user override persisted in SavedVariables later
local function getActiveProfile()
  local key = (TurtleBagSortDB and TurtleBagSortDB.profile) or "type"
  return PROFILES[key] or DEFAULT_PROFILE
end

-- ---------------------------
-- Utils: item/category data
-- ---------------------------
local function safeGetItemInfo(link)
  -- Vanilla/Turtle: GetItemInfo exists but sometimes returns nil; do basic guards.
  if not link then return nil end
  local name, _, quality, _, _, itemType, itemSubType = GetItemInfo(link)
  return {
    name = name or (tostring(link):match("%[(.+)%]")) or "<?>",
    quality = quality or RARITY_FALLBACK,
    itemType = itemType or "Misc",
    itemSubType = itemSubType or "",
  }
end

local function getContainerItemLink(bag, slot)
  if GetContainerItemLink then
    return GetContainerItemLink(bag, slot)
  end
  -- Fallback (very old clients): try tooltip scrape if needed (skipped here).
  return nil
end

local function isLocked(bag, slot)
  local _, _, locked = GetContainerItemInfo(bag, slot)
  return locked
end

local function getCount(bag, slot)
  local _, count = GetContainerItemInfo(bag, slot)
  return count or 1
end

local function isEmptySlot(bag, slot)
  local texture = GetContainerItemInfo(bag, slot)
  return texture == nil
end

-- Map itemType to our coarse categories
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

-- ---------------------------
-- Slot enumeration
-- ---------------------------
local function allBagSlots()
  local slots = {}
  for bag = 0, 4 do -- player bags only; bank not handled in this v1
    local num = GetContainerNumSlots(bag)
    if num and num > 0 then
      for slot = 1, num do
        table.insert(slots, {bag=bag, slot=slot})
      end
    end
  end
  return slots
end

-- ---------------------------
-- Key functions for sorting
-- ---------------------------
local function makeItemRecord(bag, slot, profile)
  local link = getContainerItemLink(bag, slot)
  if not link then return nil end
  local meta = safeGetItemInfo(link)
  local cat  = mapItemTypeToCategory(meta)
  local count = getCount(bag, slot)
  local catRank = 999
  for i, c in ipairs(profile.priority) do
    if c == cat then catRank = i; break end
  end
  return {
    bag=bag, slot=slot, link=link,
    name=meta.name, quality=meta.quality or RARITY_FALLBACK,
    category=cat, catRank=catRank, count=count,
  }
end

local function secondaryComparator(a, b, spec)
  -- spec like "rarityDesc|nameAsc|countDesc"
  local function cmpRarityDesc() if a.quality ~= b.quality then return a.quality > b.quality end end
  local function cmpNameAsc()   if a.name    ~= b.name    then return a.name    < b.name    end end
  local function cmpCountDesc() if a.count   ~= b.count   then return a.count   > b.count   end end
  for token in string.gmatch(spec, "([^|]+)") do
    if token == "rarityDesc" then
      local r = cmpRarityDesc(); if r ~= nil then return r end
    elseif token == "nameAsc" then
      local r = cmpNameAsc(); if r ~= nil then return r end
    elseif token == "countDesc" then
      local r = cmpCountDesc(); if r ~= nil then return r end
    end
  end
  return false
end

local function sortPlan(profile)
  local slots = allBagSlots()
  local items = {}
  local empties = {}

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

  -- Desired target order is: items (sorted), then empty slots
  local targets = {}
  for _, s in ipairs(slots) do table.insert(targets, {bag=s.bag, slot=s.slot}) end

  return items, empties, targets
end

-- ---------------------------
-- Swap engine
-- ---------------------------
local function slotKey(s) return s.bag .. ":" .. s.slot end

local function buildCurrentMap()
  local map = {}
  for bag=0,4 do
    local n = GetContainerNumSlots(bag)
    if n and n > 0 then
      for slot=1,n do
        local link = getContainerItemLink(bag, slot)
        map[slotKey({bag=bag, slot=slot})] = link
      end
    end
  end
  return map
end

local function pickup(bag, slot) ClearCursor(); PickupContainerItem(bag, slot) end
local function swap(a, b)
  -- swap item at a with item at b
  if isLocked(a.bag, a.slot) or isLocked(b.bag, b.slot) then return false end
  pickup(a.bag, a.slot); PickupContainerItem(b.bag, b.slot); ClearCursor()
  return true
end

local function moveIntoEmpty(from, empty)
  if isLocked(from.bag, from.slot) or isLocked(empty.bag, empty.slot) then return false end
  pickup(from.bag, from.slot); PickupContainerItem(empty.bag, empty.slot); ClearCursor()
  return true
end

-- Compute and execute placements to transform current → desired order in a single pass.
local function executeSort(profile)
  if InCombatLockdown and InCombatLockdown() then
    DEFAULT_CHAT_FRAME:AddMessage("|cffff5555TurtleBagSort: cannot sort in combat.|r")
    return
  end

  local items, empties, targets = sortPlan(profile)
  -- Flatten desired links in target order (items first, empties are implicitly nil)
  local desired = {}
  for i=1,#targets do desired[i] = nil end
  for i, rec in ipairs(items) do desired[i] = rec.link end

  -- Current state by linear index over targets
  local current = {}
  for i, tgt in ipairs(targets) do
    current[i] = getContainerItemLink(tgt.bag, tgt.slot)
  end

  local getSlotByIndex = function(idx) return targets[idx] end

  -- Two-phase: 1) move mismatched items into their desired slots (using empties as scratch),
  -- 2) compact any stragglers.
  local emptyQueue = {}
  for _, s in ipairs(targets) do
    if isEmptySlot(s.bag, s.slot) then table.insert(emptyQueue, {bag=s.bag, slot=s.slot}) end
  end

  local function popEmpty()
    return table.remove(emptyQueue) -- last; order doesn't matter
  end

  -- Build index of link -> list of positions (because duplicates exist)
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

  local currentIndex = indexPositions(current)
  local desiredIndex = indexPositions(desired)

  local function takePosition(list)
    if not list or #list == 0 then return nil end
    return table.remove(list, 1)
  end

  -- Ensure each desired position holds one of its desired link copies
  for dPos, wantLink in ipairs(desired) do
    if wantLink then
      local cLink = current[dPos]
      if cLink ~= wantLink then
        -- find a current position that has wantLink
        local srcPos = takePosition(currentIndex[wantLink])
        if srcPos then
          if srcPos ~= dPos then
            -- Move item from srcPos → dPos, using direct swap if target occupied, else move into empty
            local srcSlot = getSlotByIndex(srcPos)
            local dstSlot = getSlotByIndex(dPos)
            local ok
            if not isEmptySlot(dstSlot.bag, dstSlot.slot) then
              ok = swap(srcSlot, dstSlot)
            else
              ok = moveIntoEmpty(srcSlot, dstSlot)
            end
            if ok then
              local tmp = current[dPos]; current[dPos] = current[srcPos]; current[srcPos] = tmp
            end
          end
        else
          -- desired link not found in current (shouldn't happen), skip
        end
      end
    else
      -- desired is empty; we don't force an item here
    end
  end

  DEFAULT_CHAT_FRAME:AddMessage("|cff55ff55TurtleBagSort: sorted using profile '" .. getActiveProfile().name .. "'.|r")
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
  if msg == "type" or msg == "rarity" or msg == "junk" then
    TurtleBagSortDB.profile = msg
    DEFAULT_CHAT_FRAME:AddMessage("|cff88ff88TurtleBagSort: profile set to '" .. msg .. "'. Use /bagsort to sort.|r")
    return
  end
  if msg == "help" then
    DEFAULT_CHAT_FRAME:AddMessage("|cffffff88TurtleBagSort commands:|r")
    DEFAULT_CHAT_FRAME:AddMessage("  /bagsort           - Sort using current profile")
    DEFAULT_CHAT_FRAME:AddMessage("  /bagsort type      - Prioritize type (default)")
    DEFAULT_CHAT_FRAME:AddMessage("  /bagsort rarity    - Prioritize rarity")
    DEFAULT_CHAT_FRAME:AddMessage("  /bagsort junk      - Pull junk forward, then others")
    DEFAULT_CHAT_FRAME:AddMessage("  /bagsort help      - This help")
    return
  end
  DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00TurtleBagSort: unknown command. Try /bagsort help|r")
end

-- ---------------------------
-- AddOnLoaded banner (and Bagnon detection)
-- ---------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
  local bagnonLoaded = IsAddOnLoaded and IsAddOnLoaded("Bagnon")
  DEFAULT_CHAT_FRAME:AddMessage("|cff00d1ffTurtleBagSort loaded.|r " ..
    (bagnonLoaded and "|cff88ff88(Bagnon detected)|r" or "|cffffaa00(Bagnon not detected)|r") ..
    "  Use |cffffff00/bagsort|r or set profile with |cffffff00/bagsort type|r, |cffffff00/bagsort rarity|r, |cffffff00/bagsort junk|r.")
end)
