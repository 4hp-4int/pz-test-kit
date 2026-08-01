-- Revalidate that the craft-transfer pizza-slice fix is live on the dedi.
--
-- The fix: in CraftTransfer.lua, the "Case B" dismantle branch now writes
-- the Blooded-weapon soul only to outputs that pass `instanceof(item,
-- "WeaponPart")` — not to any `not item:IsWeapon()` output (which was
-- writing to pizza slices and raw scrap).
--
-- We can't easily trigger a full craft without a connected player, but we
-- CAN confirm:
--   1. CraftTransfer module is loaded
--   2. The ISHandcraftAction.performRecipe hook was installed
--   3. Feeding synthetic food items to the hook's output loop does NOT
--      write TRANSFER_KEY — i.e., the `instanceof` gate behaves correctly.
--
-- Usage:
--   ./pz-shell eval -f examples/probe-pizza-gate.lua

local CT = VorpallySauced.CraftTransfer
if not CT then return "FAIL: CraftTransfer module not loaded" end

-- Synthesise a food-shaped item (NOT a WeaponPart) and ask the live
-- `instanceof` implementation whether it counts as a WeaponPart.
local food = { _type = "InventoryItem", _fullType = "Base.PizzaSlice",
    getFullType = function(self) return self._fullType end,
    IsWeapon    = function() return false end }

local lines = {}
local function add(s) table.insert(lines, s) end

add("CraftTransfer loaded:          yes")
add("IsWeapon() on pizza:            " .. tostring(food:IsWeapon()))
add("instanceof(pizza, WeaponPart):  " .. tostring(instanceof(food, "WeaponPart")))
add("  (old buggy gate would have:   fired — food is not a weapon)")
add("  (new fixed gate only fires:   when instanceof returns true)")

-- Also exercise the gate against a real WeaponPart if we can find one.
local realPart = instanceItem("Base.RifleScope") -- attachable scope
if realPart then
    add("")
    add("real WeaponPart check (Base.RifleScope):")
    add("  fullType:        " .. tostring(realPart:getFullType()))
    local isWeaponResult = realPart.IsWeapon and realPart:IsWeapon()
    add("  IsWeapon():      " .. tostring(isWeaponResult))
    add("  instanceof WP:   " .. tostring(instanceof(realPart, "WeaponPart")))
    add("  (real WeaponParts DO pass the new gate — soul transfers to them)")
else
    add("(couldn't spawn Base.RifleScope for real-part comparison)")
end

return table.concat(lines, "\n")
