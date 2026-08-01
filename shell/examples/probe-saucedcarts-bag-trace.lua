-- Deep trace of cart→bag transfer: inspect every intermediate value so we
-- can see WHERE the silent no-op happens.

local p = getOnlinePlayers():get(0)
local inv = p:getInventory()

-- Find a bag.
local bag, bagCont
for i = 0, inv:getItems():size() - 1 do
    local it = inv:getItems():get(i)
    if it and it.getItemContainer then
        local c = it:getItemContainer()
        if c and not SaucedCarts.safeIsCart(it) then bag = it; bagCont = c; break end
    end
end

-- Spawn cart + bottle.
local cart = instanceItem("SaucedCarts.ShoppingCart")
inv:AddItem(cart)
local cartCont = cart:getItemContainer()
local bottle = instanceItem("Base.PopBottle")
cartCont:AddItem(bottle)

local lines = {}
local function add(fmt, ...) table.insert(lines, string.format(fmt, ...)) end

-- 1. Find the item — is it found?
local find = SaucedCarts.CartTransferInterceptor.findItemNearPlayer
local found = find(p, bottle:getID())
add("findItemNearPlayer: %s (id=%s)", tostring(found ~= nil), tostring(found and found:getID()))
add("  item:getContainer() type=%s", tostring(found and found:getContainer() and found:getContainer():getType()))
add("  item:getContainer() == cartCont : %s", tostring(found and found:getContainer() == cartCont))

-- 2. Find the cart.
local findCart = SaucedCarts.CartTransferInterceptor.findCartNearPlayer
local foundCart = findCart(p, cart:getID())
add("findCartNearPlayer: %s (id=%s)", tostring(foundCart ~= nil), tostring(foundCart and foundCart:getID()))

-- 3. Find the bag via recursive helper.
local recursive = SaucedCarts.CartTransferInterceptor.findInventoryItemRecursive
local foundBag = recursive(inv, bag:getID())
add("findInventoryItemRecursive(bagId): %s (id=%s)", tostring(foundBag ~= nil), tostring(foundBag and foundBag:getID()))
add("  foundBag == bag : %s", tostring(foundBag == bag))
add("  foundBag:getItemContainer() == bagCont : %s",
    tostring(foundBag and foundBag:getItemContainer() == bagCont))

-- 4. Check bag container capacity / hasRoomFor.
add("bagCont:hasRoomFor(p, bottle) = %s", tostring(bagCont:hasRoomFor(p, bottle)))
add("bagCont:getCapacity() = %s", tostring(bagCont.getCapacity and bagCont:getCapacity()))
add("bagCont:getCapacityWeight() = %s", tostring(bagCont.getCapacityWeight and bagCont:getCapacityWeight()))
add("bottle weight = %s", tostring(bottle.getActualWeight and bottle:getActualWeight()))

-- 5. Directly invoke performCartTransfer — is it returning false?
local ok, result = pcall(function()
    return SaucedCarts.performCartTransfer(p, bottle, cartCont, bagCont)
end)
add("performCartTransfer: ok=%s result=%s", tostring(ok), tostring(result))

-- 6. Where is the item now?
local inCart = cartCont:getItemById(bottle:getID()) ~= nil
local inBag  = bagCont:getItemById(bottle:getID())  ~= nil
add("AFTER performCartTransfer direct: inCart=%s inBag=%s", tostring(inCart), tostring(inBag))

-- Cleanup.
if inCart then cartCont:Remove(bottle) end
if inBag  then bagCont:Remove(bottle)  end
inv:Remove(cart)

return table.concat(lines, "\n")
