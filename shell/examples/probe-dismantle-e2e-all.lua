-- COMPREHENSIVE, TRUSTWORTHY end-to-end dismantle fuzz.
-- For every vanilla dismantleable weapon: clean the container, give the player a
-- single Blooded copy + the minimal tool, run the REAL dismantle, and VERIFY my
-- exact weapon was the item consumed (so the result can't be faked by clutter or
-- a tool/input collision), then check where the soul landed.
--
-- Result categories (honest, non-overlapping):
--   PASS          my weapon consumed, soul on a head/blade (not a handle), not lost
--   FAIL_HANDLE   soul landed on a broken-handle byproduct          <- the real bug
--   FAIL_LOST     my weapon consumed but NO output carries the soul <- the real bug
--   NOT_WEAPON    isValidAnyWeapon=false (VPS can't Blood it; nothing to route)
--   HARNESS_MISS  my weapon was NOT consumed (recipe dismantled something else)
--   SKIP_SPAWN    instanceItem failed (item doesn't exist on this build)

local p = getOnlinePlayers and getOnlinePlayers():get(0)
if not p then return "NO PLAYER — log onto the dedi first." end
local inv = p:getInventory()
local WD = VorpallySauced.WeaponData
local CT = VorpallySauced.CraftTransfer

local recipes = getScriptManager():getAllCraftRecipes()
local function findRec(name) for i=0,recipes:size()-1 do if recipes:get(i):getName()==name then return recipes:get(i) end end end
local R = {
  blade = findRec("DismantleBlade"),
  long  = findRec("DismantleLongImplement"),
  short = findRec("DismantleShortImplement"),
  spear = findRec("ReclaimFromSpear"),
}

local BLADE = {"Base.CrudeKnife","Base.CrudeShortSword","Base.CrudeSword","Base.CrudeSword_Broken","Base.HandScythe","Base.HandScytheForged","Base.HuntingKnife","Base.HuntingKnifeForged","Base.KitchenKnife","Base.KitchenKnifeForged","Base.LargeKnife","Base.LongCrudeKnife","Base.Machete","Base.MacheteForged","Base.MeatCleaver","Base.MeatCleaverForged","Base.ShortSword","Base.Sword","Base.Sword_Broken","Base.FlintKnife","Base.StoneKnifeLong"}
local LONG = {"Base.Axe_Old","Base.LongMace","Base.LongMace_Stone","Base.PickAxe","Base.PickAxeForged","Base.Sledgehammer","Base.SledgehammerForged","Base.Sledgehammer2","Base.WoodAxe","Base.WoodAxeForged","Base.Axe","Base.GardenHoe","Base.GardenFork","Base.GardenHoeForged","Base.Rake","Base.Scythe","Base.ScytheForged","Base.Shovel","Base.SpadeForged","Base.SpearCrude","Base.SpearCrudeLong","Base.SpearLong","Base.SpearShort","Base.SpearStoneLong","Base.SpearStone","Base.Spear_BoneLong","Base.Spear_Bone","Base.AxeStone","Base.HammerStone","Base.StoneAxeLarge","Base.StoneMaul"}
local SHORT = {"Base.BallPeenHammer","Base.BallPeenHammerForged","Base.ClubHammer","Base.ClubHammerForged","Base.Hammer","Base.HammerForged","Base.HandAxe","Base.HandAxeForged","Base.HandAxe_Old","Base.Mace","Base.Mace_Stone","Base.SmithingHammer","Base.Hatchet_Bone"}
local SPEAR = {"Base.SpearKnifeSmall","Base.SpearLargeKnife","Base.SpearScrapKnife","Base.SpearFightingKnife","Base.SpearHandFork","Base.SpearHuntingKnife","Base.SpearKnife","Base.SpearScissors","Base.SpearScrewdriver","Base.Spear_Plunger","Base.SpearSteakKnife"}

local cases = {}
for _,ft in ipairs(BLADE) do table.insert(cases, {ft, R.blade, true}) end
for _,ft in ipairs(LONG)  do table.insert(cases, {ft, R.long,  true}) end
for _,ft in ipairs(SHORT) do table.insert(cases, {ft, R.short, true}) end
for _,ft in ipairs(SPEAR) do table.insert(cases, {ft, R.spear, false}) end

-- Aggressively remove our test clutter so input selection is unambiguous:
-- byproduct heads/blades/handles, hammers, any VPS-bonded weapon, any soul carrier.
local function purge()
  local items = inv:getItems()
  local rm = {}
  for i=0,items:size()-1 do
    local it = items:get(i); local ft = it:getFullType(); local md = it:getModData()
    local clutter = (md and md.VorpallySauced_Transfer) ~= nil
      or ft:find("Hammer",1,true) or ft:find("Head",1,true) or ft:find("Blade",1,true)
      or ft:find("Handle",1,true) or ft:find("_Broken",1,true) or ft:find("LongStick",1,true)
      or ft:find("Stick",1,true)
    if not clutter then
      local data = WD.getModData(it)
      if data and (data.bondingId or (data.kills and data.kills >= 900000)) then clutter = true end
    end
    if clutter then table.insert(rm, it) end
  end
  for _,it in ipairs(rm) do pcall(function() inv:Remove(it) end) end
  return #rm
end

local purged0 = purge()

local counts = { PASS=0, FAIL_HANDLE=0, FAIL_LOST=0, NOT_WEAPON=0, HARNESS_MISS=0, SKIP_SPAWN=0 }
local detail = {}
local k = 900000

for _, c in ipairs(cases) do
  local ft, rec, needsTool = c[1], c[2], c[3]
  purge()
  k = k + 1
  local toolItem = nil
  if needsTool then
    toolItem = inv:AddItem((ft == "Base.Hammer") and "Base.BallPeenHammer" or "Base.Hammer")
  end
  local w = inv:AddItem(ft)
  if not w then counts.SKIP_SPAWN = counts.SKIP_SPAWN + 1; table.insert(detail, "SKIP_SPAWN  "..ft)
  elseif not WD.isValidAnyWeapon(w) then
    counts.NOT_WEAPON = counts.NOT_WEAPON + 1; table.insert(detail, "NOT_WEAPON  "..ft)
    purge()
  else
    local wId = w:getID()
    local d = WD.getOrCreateModData(w)
    d.kills=k; d.isFirearm=false; d.bondingId=1; d.prefixId=1; d.suffixId=1
    d.prefixThreshold,d.suffixThreshold,d.bondingThreshold=0,0,0
    local logic = HandcraftLogic.new(p, nil, nil)
    local conts = ArrayList.new(); conts:add(inv); logic:setContainers(conts)
    logic:setRecipe(rec)
    -- Explicitly assign inputs (vanilla's manual-input path) so MY Blooded weapon
    -- is pinned to the consumable slot — not left to auto-select, which grabs the
    -- tool hammer when the weapon is also a hammer.
    logic:setManualSelectInputs(true); logic:clearManualInputs()
    if needsTool then
      local tList = ArrayList.new(); tList:add(toolItem)
      local wList = ArrayList.new(); wList:add(w)
      pcall(function() logic:setManualInputsFor(rec:getIOForIndex(0), tList) end)  -- tool slot
      pcall(function() logic:setManualInputsFor(rec:getIOForIndex(1), wList) end)  -- dismantle target
    else
      local wList = ArrayList.new(); wList:add(w)
      pcall(function() logic:setManualInputsFor(rec:getIOForIndex(0), wList) end)  -- target (spear, no tool)
    end
    pcall(function() logic:canPerformCurrentRecipe() end)  -- required: populates manual-input cached data
    pcall(function() ISHandcraftAction.performRecipe({ logic = logic, character = p }) end)
    -- Did the recipe destroy MY exact weapon? If not, the harness selected the
    -- wrong input — that result tells us nothing about routing.
    local stillThere = inv:getItemWithID(wId) ~= nil
    if stillThere then
      counts.HARNESS_MISS = counts.HARNESS_MISS + 1; table.insert(detail, "HARNESS_MISS "..ft.." (my weapon not consumed)")
    else
      local outs = ArrayList.new(); pcall(function() logic:getCreatedOutputItems(outs) end)
      local carrier, handleCarrier = nil, nil
      for i=0,outs:size()-1 do
        local it = outs:get(i); local md = it:getModData()
        local snap = md and md.VorpallySauced_Transfer
        local hit = (snap and snap.kills == k)
        if not hit then local data = WD.getModData(it); if data and data.kills == k and data.bondingId then hit = true end end
        if hit then
          carrier = it:getFullType()
          if WD.isValidAnyWeapon(it) and CT._isBrokenHandleOutput(it) then handleCarrier = it:getFullType() end
        end
      end
      if handleCarrier then counts.FAIL_HANDLE = counts.FAIL_HANDLE+1; table.insert(detail, "FAIL_HANDLE "..ft.." -> "..handleCarrier)
      elseif not carrier then counts.FAIL_LOST = counts.FAIL_LOST+1; table.insert(detail, "FAIL_LOST  "..ft)
      else counts.PASS = counts.PASS+1 end
    end
    purge()
  end
end
purge()

local out = {}
table.insert(out, string.format("purged %d clutter at start; %d cases", purged0, #cases))
table.insert(out, string.format("PASS=%d  FAIL_HANDLE=%d  FAIL_LOST=%d  NOT_WEAPON=%d  HARNESS_MISS=%d  SKIP_SPAWN=%d",
  counts.PASS, counts.FAIL_HANDLE, counts.FAIL_LOST, counts.NOT_WEAPON, counts.HARNESS_MISS, counts.SKIP_SPAWN))
for _, d in ipairs(detail) do table.insert(out, "  "..d) end
return table.concat(out, "\n")
