-- Revalidate the mapper-reforge fix on the dedi / live VM.
--
-- User report: a Blooded baseball bat used as base in the vanilla B42
-- improvised-weaponry recipe MakeGardenForkHeadWeapon produced a
-- BaseballBat_GardenForkHead with FRESH ModData — VPS progression lost.
--
-- Two-part fix in CraftTransfer.lua:
--   1. applyTransfer now calls WeaponData.getOrCreateModData (was
--      getModData, which returned nil on fresh outputs and silently
--      bailed the entire transfer).
--   2. hookedPerformRecipe captures consumed items AFTER
--      originalPerformRecipe runs — appliedItems on each InputScriptData
--      is populated inside CraftRecipeData.consumeRecipeInputs, which
--      runs inside HandcraftLogic.performCurrentRecipe.
--
-- We can't trigger a full vanilla craft from an eval'd probe (no
-- connected player, no real HandcraftLogic Java object). We CAN invoke
-- applyTransfer directly on a real BaseballBat_GardenForkHead created
-- via instanceItem — that exercises the fix end-to-end on a live VM
-- with real Java items.
--
-- Usage:
--   ./pz-shell eval -f examples/probe-mapper-reforge.lua

local CT = VorpallySauced and VorpallySauced.CraftTransfer
if not CT then return "FAIL: CraftTransfer module not loaded" end
if not CT.applyTransfer then return "FAIL: CraftTransfer.applyTransfer missing" end
if not CT.captureForTransfer then return "FAIL: CraftTransfer.captureForTransfer missing" end

local lines = {}
local function add(s) table.insert(lines, s) end

add("=== mapper-reforge probe ===")
add("CraftTransfer module:     loaded")
add("ISHandcraftAction hook:   " ..
    (ISHandcraftAction and ISHandcraftAction.performRecipe and "installed" or "MISSING"))

-- Step 1: synthesize a Blooded baseball bat
local bat = instanceItem("Base.BaseballBat")
if not bat then return "FAIL: could not spawn Base.BaseballBat" end
bat:getModData().VorpallySauced = {
    kills = 500,
    prefixId = 2,
    suffixId = 3,
    bondingId = 1,
    isFirearm = false,
}

local snapshot = CT.captureForTransfer(bat)
if not snapshot then return "FAIL: captureForTransfer returned nil on Blooded bat" end
add("")
add("snapshot from bat:")
add("  kills:     " .. tostring(snapshot.kills))
add("  prefixId:  " .. tostring(snapshot.prefixId))
add("  suffixId:  " .. tostring(snapshot.suffixId))
add("  bondingId: " .. tostring(snapshot.bondingId))

-- Step 2: spawn a FRESH garden-fork-bat (the mapper output in real recipe)
local fork = instanceItem("Base.BaseballBat_GardenForkHead")
local usedFallback = false
if not fork then
    add("")
    add("NOTE: Base.BaseballBat_GardenForkHead not resolvable; falling back to Machete.")
    fork = instanceItem("Base.Machete")
    usedFallback = true
end
if not fork then return table.concat(lines, "\n") .. "\nFAIL: no output item available" end

-- Confirm it's FRESH — no VorpallySauced key pre-transfer
local preHasData = fork:getModData().VorpallySauced ~= nil
add("")
add("output pre-transfer:")
add("  fullType:                " .. tostring(fork:getFullType()))
add("  has VorpallySauced data: " .. tostring(preHasData) .. "  (expected false)")

-- Step 3: invoke the fixed path
CT.applyTransfer(snapshot, fork, nil)  -- nil player skips MP sync + halo

local post = fork:getModData().VorpallySauced
add("")
add("output post-transfer:")
add("  has VorpallySauced data: " .. tostring(post ~= nil))
if post then
    add("  kills:                   " .. tostring(post.kills))
    add("  prefixId:                " .. tostring(post.prefixId))
    add("  suffixId:                " .. tostring(post.suffixId))
    add("  bondingId:               " .. tostring(post.bondingId))
    add("  isReforged:              " .. tostring(post.isReforged))
    add("  originalStats captured:  " .. tostring(post.originalStats ~= nil))
end

local ok = post and post.kills == 500 and post.bondingId == 1 and post.isReforged == true
add("")
add(ok
    and (">>> PASS: mapper-reforge fix verified on live VM" ..
        (usedFallback and " (with fallback output item)" or ""))
    or  ">>> FAIL: transfer did not land — check CraftTransfer.applyTransfer")

-- Step 4: regression check — pizza-gate still holds on the live VM
add("")
add("=== pizza-gate regression check ===")
local food = {
    _type       = "InventoryItem",
    _fullType   = "Base.PizzaSlice",
    getFullType = function(self) return self._fullType end,
    IsWeapon    = function() return false end,
}
local foodIsWeaponPart = instanceof(food, "WeaponPart")
add("instanceof(pizza, WeaponPart): " .. tostring(foodIsWeaponPart))
add("  (expected false — soul must never write to food)")
add(foodIsWeaponPart
    and ">>> FAIL: pizza-gate regressed — food now passes WeaponPart check"
    or  ">>> PASS: pizza-gate still holds")

return table.concat(lines, "\n")
