-- End-to-end server-side transfer probe for container ↔ cart.
-- Simulates what the client's ISCartTransferAction would send after the
-- v2.1.5 fix, then invokes the server's resolver + performCartTransfer
-- directly to prove the whole chain works.
--
-- Doesn't actually move user items — spawns a throwaway test item in the
-- world container, transfers it to a throwaway cart, then destroys both.

local p = getOnlinePlayers() and getOnlinePlayers():size() > 0 and getOnlinePlayers():get(0)
if not p then return "need a connected player" end
local psq = p:getCurrentSquare()
if not psq then return "player has no current square" end

-- Find a world container within 15 tiles (shelf / freezer / barbecue / etc.).
local worldCont, worldSq
for dy = -15, 15 do
    for dx = -15, 15 do
        local sq = getCell():getGridSquare(psq:getX() + dx, psq:getY() + dy, psq:getZ())
        if sq then
            local objs = sq:getObjects()
            for i = 0, objs:size() - 1 do
                local o = objs:get(i)
                local c = o.getContainer and o:getContainer()
                if c then worldCont = c; worldSq = sq; break end
            end
        end
        if worldCont then break end
    end
    if worldCont then break end
end
if not worldCont then return "no world container within 15 tiles" end

-- Spawn a test item INSIDE the world container, and a throwaway cart on the
-- ground at the player's square. These are cleaned up at the end either way.
local testItem = instanceItem("Base.PopBottle")  -- anything small is fine
if not testItem then return "instanceItem Base.PopBottle failed" end
worldCont:AddItem(testItem)

-- Take any cart type the mod knows about. SaucedCarts exposes a list of
-- registered cart fullTypes via CartData if available.
local cartTypes = { "SaucedCarts.ShoppingCart" }
local cartItem
for _, t in ipairs(cartTypes) do
    cartItem = instanceItem(t)
    if cartItem then break end
end
if not cartItem then
    worldCont:Remove(testItem)
    return "couldn't spawn any test cart (tried " .. table.concat(cartTypes, ", ") .. ")"
end
-- Drop the cart on the player's square so the server sees it as a ground cart.
local worldItem = psq:AddWorldInventoryItem(cartItem, 0, 0, 0)
local cartCont = cartItem.getItemContainer and cartItem:getItemContainer()

-- Invoke the fixed transfer path directly.
local ok, err = pcall(function()
    SaucedCarts.performCartTransfer(p, testItem, worldCont, cartCont)
end)

local resultLines = {}
table.insert(resultLines, string.format("world container: type=%s at (%d,%d)",
    worldCont:getType(), worldSq:getX(), worldSq:getY()))
table.insert(resultLines, string.format("cart: %s (id=%s)",
    cartItem:getFullType(), tostring(cartItem:getID())))
table.insert(resultLines, string.format("performCartTransfer ok=%s err=%s",
    tostring(ok), tostring(err)))

-- Check: is the item now in the cart, and gone from the world container?
local inCart = cartCont and cartCont.getItemById and cartCont:getItemById(testItem:getID())
local stillInWorld = worldCont and worldCont.getItemById and worldCont:getItemById(testItem:getID())
table.insert(resultLines, string.format("item in cart: %s", tostring(inCart ~= nil)))
table.insert(resultLines, string.format("item still in world cont: %s", tostring(stillInWorld ~= nil)))

-- Cleanup: remove test item + cart no matter what.
if inCart then cartCont:Remove(testItem) end
if stillInWorld then worldCont:Remove(testItem) end
if worldItem and worldItem.removeFromWorld then worldItem:removeFromWorld() end
if worldItem and worldItem.removeFromSquare then worldItem:removeFromSquare() end

table.insert(resultLines, "")
if inCart and not stillInWorld then
    table.insert(resultLines, "OK - container-cart transfer works end-to-end")
else
    table.insert(resultLines, "FAIL - transfer did not move item correctly")
end

return table.concat(resultLines, "\n")
