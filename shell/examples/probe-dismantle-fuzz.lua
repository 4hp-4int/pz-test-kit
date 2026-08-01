-- Exhaustive fuzz: drive EVERY vanilla dismantleable weapon's real output set
-- through CraftTransfer._planSoulRouting and verify the soul routes to the
-- head/blade (never a handle, never lost). Output sets derived directly from
-- media/scripts/generated/recipes/recipes_disassembly.txt.

local CT = VorpallySauced.CraftTransfer
local WD = VorpallySauced.WeaponData
if not CT or not CT._planSoulRouting then return "FAIL: _planSoulRouting not loaded (old build?)" end

-- recipe type: "dismantle" (soul->non-weapon head) or "reforge" (soul->reclaimed weapon)
-- Each case: { input, recipe, outs = { ... } }  (outs in real output order)
local LONG = {  -- DismantleLongImplement: { head, handle }
  {"Base.LongMace",{"Base.MaceHead","Base.LongHandle_Broken"}},
  {"Base.LongMace_Stone",{"Base.StoneMaceHead","Base.LongStick_Broken"}},
  {"Base.Axe_Old",{"Base.OldAxeHead","Base.LongHandle_Broken"}},
  {"Base.PickAxe",{"Base.PickAxeHead","Base.LongHandle_Broken"}},
  {"Base.Sledgehammer",{"Base.SledgehammerHead","Base.LongHandle_Broken"}},
  {"Base.WoodAxe",{"Base.WoodAxeHead","Base.LongHandle_Broken"}},
  {"Base.Axe",{"Base.FireAxeHead","Base.LongHandle_Broken"}},
  {"Base.GardenFork",{"Base.GardenForkHead","Base.GardenToolHandle_Broken"}},
  {"Base.GardenHoe",{"Base.GardenHoeHead","Base.LongStick_Broken"}},
  {"Base.Rake",{"Base.RakeHead","Base.LongStick_Broken"}},
  {"Base.Scythe",{"Base.ScytheBlade","Base.LongStick_Broken"}},
  {"Base.Shovel",{"Base.SpadeHead","Base.GardenToolHandle_Broken"}},
  {"Base.SpearCrude",{"Base.CrudeBlade","Base.LongStick_Broken"}},
  {"Base.SpearCrudeLong",{"Base.LongCrudeBlade","Base.LongStick_Broken"}},
  {"Base.SpearStoneLong",{"Base.StoneBladeLong","Base.LongStick_Broken"}},
  {"Base.SpearStone",{"Base.StoneBlade","Base.LongStick_Broken"}},
  {"Base.Spear_BoneLong",{"Base.SharpBone_Long","Base.LongStick_Broken"}},
  {"Base.Spear_Bone",{"Base.SharpBoneFragment","Base.LongStick_Broken"}},
  {"Base.SpearLong",{"Base.SpearLongHead","Base.LongStick_Broken"}},
  {"Base.SpearShort",{"Base.SpearHead","Base.LongStick_Broken"}},
  {"Base.AxeStone",{"Base.SharpedStone","Base.Branch_Broken"}},
  {"Base.HammerStone",{"Base.Stone2","Base.Branch_Broken"}},
  {"Base.StoneAxeLarge",{"Base.StoneAxeHead","Base.LongHandle_Broken"}},
  {"Base.StoneMaul",{"Base.StoneMaulHead","Base.LongHandle_Broken"}},
}
local SHORT = {  -- DismantleShortImplement: { head }
  {"Base.BallPeenHammer",{"Base.BallPeenHammerHead"}},
  {"Base.ClubHammer",{"Base.ClubHammerHead"}},
  {"Base.Hammer",{"Base.ClawhammerHead"}},
  {"Base.HandAxe",{"Base.HandAxeHead"}},
  {"Base.HandAxe_Old",{"Base.OldAxeHead"}},
  {"Base.Mace",{"Base.MaceHead"}},
  {"Base.Mace_Stone",{"Base.StoneMaceHead"}},
  {"Base.SmithingHammer",{"Base.SmithingHammerHead"}},
  {"Base.Hatchet_Bone",{"Base.HatchetHead_Bone"}},
}
local BLADE = {  -- DismantleBlade: { blade }
  {"Base.CrudeKnife",{"Base.CrudeBlade"}},
  {"Base.CrudeShortSword",{"Base.CrudeShortSwordBlade"}},
  {"Base.CrudeSword",{"Base.CrudeSwordBlade"}},
  {"Base.CrudeSword_Broken",{"Base.CrudeSwordBlade_Broken"}},
  {"Base.HandScythe",{"Base.HandScytheBlade"}},
  {"Base.HuntingKnife",{"Base.HuntingKnifeBlade"}},
  {"Base.KitchenKnife",{"Base.KitchenKnifeBlade"}},
  {"Base.LargeKnife",{"Base.LargeKnifeBlade"}},
  {"Base.LongCrudeKnife",{"Base.LongCrudeBlade"}},
  {"Base.Machete",{"Base.MacheteBlade"}},
  {"Base.MeatCleaver",{"Base.MeatCleaverBlade"}},
  {"Base.ShortSword",{"Base.ShortSwordBlade"}},
  {"Base.Sword",{"Base.SwordBlade"}},
  {"Base.Sword_Broken",{"Base.SwordBlade_Broken"}},
  {"Base.FlintKnife",{"Base.StoneBlade"}},
  {"Base.StoneKnifeLong",{"Base.StoneBladeLong"}},
}
local SPEAR = {  -- ReclaimFromSpear: { reclaimedWeapon, LongStick }
  {"Base.SpearKnifeSmall",{"Base.SmallKnife","Base.LongStick"}},
  {"Base.SpearLargeKnife",{"Base.LargeKnife","Base.LongStick"}},
  {"Base.SpearScrapKnife",{"Base.LargeKnife_Scrap","Base.LongStick"}},
  {"Base.SpearFightingKnife",{"Base.FightingKnife","Base.LongStick"}},
  {"Base.SpearHandFork",{"Base.HandFork","Base.LongStick"}},
  {"Base.SpearHuntingKnife",{"Base.HuntingKnife","Base.LongStick"}},
  {"Base.SpearKnife",{"Base.KitchenKnife","Base.LongStick"}},
  {"Base.SpearScissors",{"Base.Scissors","Base.LongStick"}},
  {"Base.SpearScrewdriver",{"Base.Screwdriver","Base.LongStick"}},
  {"Base.Spear_Plunger",{"Base.Plunger","Base.LongStick"}},
  {"Base.SpearSteakKnife",{"Base.SteakKnife","Base.LongStick"}},
}

local function mklist(arr) return { _a = arr, size = function(s) return #s._a end, get = function(s,i) return s._a[i+1] end } end

local fails, warns, pass = {}, {}, 0
local total = 0

local function run(group, expectMode)
  for _, c in ipairs(group) do
    total = total + 1
    local input, outFTs = c[1], c[2]
    -- Build output instanceItems; record any that fail to spawn.
    local items, missing = {}, {}
    for _, ft in ipairs(outFTs) do
      local it = instanceItem(ft)
      if it then table.insert(items, it) else table.insert(missing, ft) end
    end
    if #missing > 0 then
      table.insert(warns, input.." : missing outputs "..table.concat(missing, ","))
    end
    if #items == 0 then
      table.insert(fails, input.." : NO outputs spawned -> soul would be lost")
    else
      local plan = CT._planSoulRouting(mklist(items))
      -- The TRUE invariant, regardless of reforge/dismantle mode:
      --   1. soul not lost (mode ~= none)
      --   2. the chosen carrier is the HEAD/BLADE = first output (outs[1])
      --   3. NO handle byproduct ever receives the soul
      local head = outFTs[1]
      local handleFT = (expectMode == "dismantle") and outFTs[2] or nil  -- LONG handle / nil
      -- Which fullType(s) got the soul?
      local carriers = {}
      if plan.mode == "reforge" then carriers[plan.item:getFullType()] = true
      elseif plan.mode == "dismantle" then for _,it in ipairs(plan.items) do carriers[it:getFullType()] = true end end
      local ok, why = true, nil
      if plan.mode == "none" then ok=false; why="soul LOST (mode none)"
      elseif not carriers[head] then ok=false; why="head '"..head.."' did NOT get soul (got "..plan.mode..")"
      elseif handleFT and carriers[handleFT] then ok=false; why="HANDLE '"..handleFT.."' got the soul (the bug!)" end
      if ok then pass = pass + 1
      else table.insert(fails, input.." ["..table.concat(outFTs,",").."] -> "..tostring(why)) end
    end
  end
end

run(LONG, "dismantle")
run(SHORT, "dismantle")
run(BLADE, "dismantle")
run(SPEAR, "reforge")

local out = {}
table.insert(out, string.format("FUZZ: %d cases, %d pass, %d FAIL, %d warn", total, pass, #fails, #warns))
if #fails > 0 then table.insert(out, "--- FAILURES ---"); for _,f in ipairs(fails) do table.insert(out, "  "..f) end end
if #warns > 0 then table.insert(out, "--- WARN (missing outputs, may be modded/renamed) ---"); for _,w in ipairs(warns) do table.insert(out, "  "..w) end end
return table.concat(out, "\n")
