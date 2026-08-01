-- Diagnose: what does classifySide return when the container is an equipped
-- bag (inner container of a backpack / satchel / holster in player inv)?
-- Theory: it falls through to "inv", routing the transfer to playerInv on
-- the server rather than the bag's container.

local p = getOnlinePlayers() and getOnlinePlayers():size() > 0 and getOnlinePlayers():get(0)
if not p then return "FAIL: need connected player" end

local inv = p:getInventory()
local items = inv:getItems()

local lines = {}
table.insert(lines, string.format("scanning %d items in player inv...", items:size()))

-- Find any InventoryItem with an inner container (a bag).
local bag, bagCont
for i = 0, items:size() - 1 do
    local it = items:get(i)
    if it and it.getItemContainer then
        local c = it:getItemContainer()
        if c then
            bag = it
            bagCont = c
            break
        end
    end
end

if not bag then
    table.insert(lines, "no item with inner container found in player inv")
    table.insert(lines, "(equip a backpack/bag and re-run)")
    return table.concat(lines, "\n")
end

table.insert(lines, string.format("bag: %s id=%s", bag:getFullType(), tostring(bag:getID())))
table.insert(lines, string.format("bag container type=%s", bagCont:getType()))

-- Run classifySide on the bag container.
local kind, cartId, sqX, sqY, sqZ, contType =
    ISCartTransferAction.classifySide(bagCont, nil)
table.insert(lines, string.format("classifySide => kind=%s cartId=%s sqX=%s sqY=%s sqZ=%s contType=%s",
    tostring(kind), tostring(cartId), tostring(sqX), tostring(sqY), tostring(sqZ), tostring(contType)))

-- Inspect the raw field getters that classifySide consults.
local ci = bagCont.getContainingItem and bagCont:getContainingItem()
local sg = bagCont.getSourceGrid and bagCont:getSourceGrid()
table.insert(lines, string.format("getContainingItem => %s (isCart=%s)",
    ci and ci:getFullType() or "nil",
    tostring(ci and SaucedCarts.safeIsCart(ci) or false)))
table.insert(lines, string.format("getSourceGrid => %s", tostring(sg)))

return table.concat(lines, "\n")
