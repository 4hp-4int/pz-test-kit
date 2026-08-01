-- Minimal one-shot diagnostic: invoke handleCartTransfer with a SINGLE
-- "new client" style transfer and capture full error info. Runs the same
-- scene-setup logic as the stress probe but does ONE call and prints
-- everything we know about what was nil.

local p = getOnlinePlayers() and getOnlinePlayers():size() > 0 and getOnlinePlayers():get(0)
if not p then return "FAIL: needs a connected player" end
local psq = p:getCurrentSquare()
if not psq then return "FAIL: player has no current square" end

-- Find world container.
local worldCont, worldSq
for dy = -10, 10 do
    for dx = -10, 10 do
        local sq = getCell():getGridSquare(psq:getX() + dx, psq:getY() + dy, psq:getZ())
        if sq then
            for i = 0, sq:getObjects():size() - 1 do
                local o = sq:getObjects():get(i)
                local c = o.getContainer and o:getContainer()
                if c then worldCont = c; worldSq = sq; break end
            end
        end
        if worldCont then break end
    end
    if worldCont then break end
end
if not worldCont then return "FAIL: no world container within 10 tiles" end

-- Dump what methods are available on the world container.
local contType  = tostring(worldCont:getType())
local contHasType = tostring(worldCont.getType ~= nil)
local contHasAddItem = tostring(worldCont.AddItem ~= nil)
local contHasGetItemById = tostring(worldCont.getItemById ~= nil)
local contHasRemove = tostring(worldCont.Remove ~= nil)
local contHasHasRoomFor = tostring(worldCont.hasRoomFor ~= nil)
local contHasContainingItem = tostring(worldCont.getContainingItem ~= nil)
local contHasDoRemoveItem = tostring(worldCont.DoRemoveItem ~= nil)
local contHasSourceGrid = tostring(worldCont.getSourceGrid ~= nil)

-- Spawn cart.
local cart = instanceItem("SaucedCarts.ShoppingCart")
if not cart then return "FAIL: could not spawn ShoppingCart" end
p:getInventory():AddItem(cart)
local cartCont = cart:getItemContainer()
if not cartCont then
    p:getInventory():Remove(cart)
    return "FAIL: cart has no inner container"
end

-- Spawn a SINGLE test item.
local it = instanceItem("Base.PopBottle")
if not it then
    p:getInventory():Remove(cart)
    return "FAIL: could not spawn PopBottle"
end
worldCont:AddItem(it)

-- Build args mirroring a v2.1.5 client "in" transfer (world -> cart).
local args = {
    itemId     = it:getID(),
    cartId     = cart:getID(),
    direction  = "in",
    srcKind    = "world",
    srcSqX     = worldSq:getX(),
    srcSqY     = worldSq:getY(),
    srcSqZ     = worldSq:getZ(),
    srcContType= worldCont:getType(),
    destKind   = "cart",
    destCartId = cart:getID(),
}

-- Invoke.
local handler = SaucedCarts.CartTransferInterceptor
    and SaucedCarts.CartTransferInterceptor.handleCartTransfer
local handlerKind = type(handler)
local ok, err
if handler then
    ok, err = pcall(handler, p, args)
else
    ok, err = false, "handleCartTransfer is nil — CartTransferInterceptor not loaded?"
end

-- Inspect item location post-call.
local inWorld = worldCont:getItemById(it:getID()) ~= nil
local inCart  = cartCont:getItemById(it:getID())  ~= nil
local inInv   = p:getInventory():getItemById(it:getID()) ~= nil

-- Cleanup.
if inWorld then worldCont:Remove(it)  end
if inCart  then cartCont:Remove(it)   end
if inInv   then p:getInventory():Remove(it) end
p:getInventory():Remove(cart)

local lines = {
    string.format("world container type=%s at (%d,%d)", contType, worldSq:getX(), worldSq:getY()),
    string.format("  getType=%s AddItem=%s getItemById=%s Remove=%s", contHasType, contHasAddItem, contHasGetItemById, contHasRemove),
    string.format("  hasRoomFor=%s getContainingItem=%s DoRemoveItem=%s getSourceGrid=%s",
        contHasHasRoomFor, contHasContainingItem, contHasDoRemoveItem, contHasSourceGrid),
    string.format("handler type=%s", handlerKind),
    string.format("pcall ok=%s err=%s", tostring(ok), tostring(err)),
    string.format("post-call: inWorld=%s inCart=%s inInv=%s", tostring(inWorld), tostring(inCart), tostring(inInv)),
}
return table.concat(lines, "\n")
