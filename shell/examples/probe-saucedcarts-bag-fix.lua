-- Verify the equipped-bag destination fix.
-- Spawns cart + PopBottle, transfers cart→bag using destKind="bag",
-- confirms the bottle lands in the bag (not in player main inv).

local p = getOnlinePlayers() and getOnlinePlayers():size() > 0 and getOnlinePlayers():get(0)
if not p then return "FAIL: need connected player" end

-- Spawn a fresh test bag (unequipped, empty) so PZ's encumbrance check
-- doesn't reject hasRoomFor. Using the player's ACTUAL equipped bag fails
-- when the char is over carry cap — that's vanilla behavior, not a bug in
-- our routing. The fix is about "item lands in the bag, not main inv", not
-- about defeating encumbrance.
local bag = instanceItem("Base.Bag_Schoolbag")
if not bag then return "FAIL: could not spawn Bag_Schoolbag" end
p:getInventory():AddItem(bag)
local bagCont = bag:getItemContainer()
if not bagCont then
    p:getInventory():Remove(bag)
    return "FAIL: test bag has no inner container"
end

-- Spawn throwaway cart, put item inside it.
local cart = instanceItem("SaucedCarts.ShoppingCart")
if not cart then return "FAIL: can't spawn cart" end
p:getInventory():AddItem(cart)
local cartCont = cart:getItemContainer()

local bottle = instanceItem("Base.PopBottle")
if not bottle then
    p:getInventory():Remove(cart)
    return "FAIL: can't spawn bottle"
end
cartCont:AddItem(bottle)

-- Snapshot starting state.
local startInCart = cartCont:getItemById(bottle:getID()) ~= nil
local startInBag  = bagCont:getItemById(bottle:getID())  ~= nil
local startInInv  = p:getInventory():getItemById(bottle:getID()) ~= nil  -- expect false

-- Build args as if client sent cart→bag transfer (direction="out",
-- destKind="bag", destCartId=bagId).
local args = {
    itemId     = bottle:getID(),
    cartId     = cart:getID(),
    direction  = "out",
    srcKind    = "cart",
    srcCartId  = cart:getID(),
    destKind   = "bag",
    destCartId = bag:getID(),
}

local handler = SaucedCarts.CartTransferInterceptor.handleCartTransfer
local ok, err = pcall(handler, p, args)

local endInCart = cartCont:getItemById(bottle:getID()) ~= nil
local endInBag  = bagCont:getItemById(bottle:getID())  ~= nil
local endInInv  = p:getInventory():getItemById(bottle:getID()) ~= nil  -- should still see via recursive

-- Cleanup.
if endInCart then cartCont:Remove(bottle) end
if endInBag  then bagCont:Remove(bottle)  end
p:getInventory():Remove(cart)

local lines = {
    string.format("bag: %s id=%s (type=%s)", bag:getFullType(), tostring(bag:getID()), bagCont:getType()),
    string.format("start: inCart=%s inBag=%s inInv(flat)=%s",
        tostring(startInCart), tostring(startInBag), tostring(startInInv)),
    string.format("handler: ok=%s err=%s", tostring(ok), tostring(err)),
    string.format("end:   inCart=%s inBag=%s inInv(flat)=%s",
        tostring(endInCart), tostring(endInBag), tostring(endInInv)),
}

if endInBag and not endInCart then
    table.insert(lines, "VERDICT: OK — item moved from cart into bag")
else
    table.insert(lines, "VERDICT: FAIL — item did NOT end up in the bag")
end

-- Also verify direction="in" (bag -> cart) works.
local bottle2 = instanceItem("Base.PopBottle")
if bottle2 then
    bagCont:AddItem(bottle2)
    local cart2 = instanceItem("SaucedCarts.ShoppingCart")
    p:getInventory():AddItem(cart2)
    local cartCont2 = cart2:getItemContainer()

    local args2 = {
        itemId     = bottle2:getID(),
        cartId     = cart2:getID(),
        direction  = "in",
        srcKind    = "bag",
        srcCartId  = bag:getID(),
        destKind   = "cart",
        destCartId = cart2:getID(),
    }
    local ok2 = pcall(handler, p, args2)
    local in2Bag  = bagCont:getItemById(bottle2:getID())   ~= nil
    local in2Cart = cartCont2:getItemById(bottle2:getID()) ~= nil

    table.insert(lines, "")
    table.insert(lines, string.format("reverse (bag->cart): ok=%s inBag=%s inCart=%s",
        tostring(ok2), tostring(in2Bag), tostring(in2Cart)))
    if in2Cart and not in2Bag then
        table.insert(lines, "REVERSE VERDICT: OK")
    else
        table.insert(lines, "REVERSE VERDICT: FAIL")
    end
    if in2Cart then cartCont2:Remove(bottle2) end
    if in2Bag  then bagCont:Remove(bottle2)   end
    p:getInventory():Remove(cart2)
end

-- Remove the test bag we spawned (vs. leaving it in player inv forever).
p:getInventory():Remove(bag)

return table.concat(lines, "\n")
