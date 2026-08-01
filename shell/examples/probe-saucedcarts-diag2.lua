-- Deep diagnostic: walk handleCartTransfer's resolution path STEP BY STEP
-- and capture the result of each intermediate call, so we can see WHERE
-- the silent no-op is happening.

local p = getOnlinePlayers() and getOnlinePlayers():size() > 0 and getOnlinePlayers():get(0)
if not p then return "FAIL: needs a connected player" end
local psq = p:getCurrentSquare()

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

-- Spawn cart + item.
local cart = instanceItem("SaucedCarts.ShoppingCart")
p:getInventory():AddItem(cart)
local cartCont = cart:getItemContainer()
local it = instanceItem("Base.PopBottle")
worldCont:AddItem(it)

-- Step 1: can findItemNearPlayer find the item?
local ci = SaucedCarts.CartTransferInterceptor
local found = ci.findItemNearPlayer(p, it:getID())

-- Step 2: can findCartNearPlayer find the cart?
local cartFound = ci.findCartNearPlayer(p, cart:getID())

-- Step 3: item:getContainer()
local realCont = it.getContainer and it:getContainer()
local realContType = realCont and realCont.getType and realCont:getType() or "nil"

-- Step 4: does realCont equal worldCont?
local realEqualsWorld = (realCont == worldCont)

-- Step 5: what does resolveSide return when we iterate the tile manually?
local matched
local objs = worldSq:getObjects()
for i = 0, objs:size() - 1 do
    local obj = objs:get(i)
    local cont = obj and obj.getContainer and obj:getContainer()
    if cont and cont.getType and cont:getType() == "overhead" then
        matched = cont
        break
    end
end
local matchedType = matched and matched:getType() or "nil"
local matchedEqualsWorld = (matched == worldCont)
local matchedEqualsReal  = (matched == realCont)

-- Step 6: is ISTransferAction available on server?
local hasISTransferAction = type(ISTransferAction)
local hasTransferItem = ISTransferAction and type(ISTransferAction.transferItem) or "nil"

-- Step 7: hasRoomFor on cart container
local cartHasRoom
do
    local ok, r = pcall(function() return cartCont:hasRoomFor(p, it) end)
    cartHasRoom = ok and tostring(r) or ("ERR: " .. tostring(r))
end

-- Step 8: directly call performCartTransfer with worldCont, cartCont
local ptOk, ptErr = pcall(function()
    return SaucedCarts.performCartTransfer(p, it, worldCont, cartCont)
end)

local movedToCart = cartCont:getItemById(it:getID()) ~= nil
local stillInWorld = worldCont:getItemById(it:getID()) ~= nil

-- Cleanup.
if movedToCart then cartCont:Remove(it) end
if stillInWorld then worldCont:Remove(it) end
p:getInventory():Remove(cart)

local lines = {
    string.format("findItemNearPlayer result=%s (id=%s)", tostring(found ~= nil), tostring(found and found:getID())),
    string.format("findCartNearPlayer result=%s (id=%s)", tostring(cartFound ~= nil), tostring(cartFound and cartFound:getID())),
    string.format("item:getContainer() type=%s", realContType),
    string.format("realCont == worldCont : %s", tostring(realEqualsWorld)),
    string.format("resolveSide tile-scan: matched type=%s", matchedType),
    string.format("matched == worldCont : %s", tostring(matchedEqualsWorld)),
    string.format("matched == realCont  : %s", tostring(matchedEqualsReal)),
    string.format("ISTransferAction type=%s, transferItem type=%s", hasISTransferAction, hasTransferItem),
    string.format("cartCont:hasRoomFor = %s", cartHasRoom),
    string.format("performCartTransfer: ok=%s err=%s", tostring(ptOk), tostring(ptErr)),
    string.format("post: movedToCart=%s stillInWorld=%s", tostring(movedToCart), tostring(stillInWorld)),
}
return table.concat(lines, "\n")
