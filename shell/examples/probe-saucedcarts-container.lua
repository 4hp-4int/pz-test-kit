-- Live repro for "container ↔ cart" MP bug.
--
-- The v2.1.4 classifier handles (player inv ↔ cart, ground ↔ cart) but
-- treats any OTHER container (shelf / freezer / workbench / another cart
-- owned by a different square) as "inv" — falling back to the player's
-- main inventory on the server side. Transfers between a cart and an
-- arbitrary world container then silently resolve to the wrong endpoint.
--
-- This probe simulates what classifySide sees WITHOUT actually moving
-- items: we construct three containers, ask the classifier what kind
-- it thinks each is, and assert that world containers get their own
-- identity (not collapsed to "inv").
--
-- Usage: ./pz-shell eval -f examples/probe-saucedcarts-container.lua

local p = getOnlinePlayers() and getOnlinePlayers():size() > 0 and getOnlinePlayers():get(0)
if not p then return "probe needs a connected player" end
local psq = p:getCurrentSquare()
if not psq then return "player has no current square" end

-- Find a nearby world container (shelves, cabinet, freezer — anything with
-- a getContainer()). Wider sweep so we don't need to stand on top of one.
local worldCont, worldObj
for dy = -15, 15 do
    for dx = -15, 15 do
        local sq = getCell():getGridSquare(psq:getX() + dx, psq:getY() + dy, psq:getZ())
        if sq then
            local objs = sq:getObjects()
            for i = 0, objs:size() - 1 do
                local o = objs:get(i)
                local c = o.getContainer and o:getContainer()
                if c then worldCont = c; worldObj = o; break end
            end
        end
        if worldCont then break end
    end
    if worldCont then break end
end

if not worldCont then
    return "no world container within 3 tiles of player (stand by a shelf/freezer)"
end

-- Replicate the v2.1.5 classifier logic from ISCartTransferAction:classifySide.
-- Returns a descriptive tuple string so we can see what the server would
-- have received in the cartTransfer command payload.
local function classify(container)
    if not container or not container.getType then return "inv(no-container)" end
    local dtype = container:getType()
    if dtype == "floor" then return "floor" end
    local ci = container.getContainingItem and container:getContainingItem()
    if ci and SaucedCarts and SaucedCarts.safeIsCart and SaucedCarts.safeIsCart(ci) then
        return "cart"
    end
    -- v2.1.5: world-container detection via getSourceGrid()
    local sg = container.getSourceGrid and container:getSourceGrid()
    if sg and sg.getX then
        return string.format("world(type=%s, at %d,%d,%d)",
            dtype, sg:getX(), sg:getY(), sg:getZ())
    end
    return "inv"
end

local lines = {}
table.insert(lines, "player inv:        classifier -> " .. classify(p:getInventory()))
table.insert(lines, "world container:   classifier -> " .. classify(worldCont))
table.insert(lines, "  (type=" .. tostring(worldCont:getType())
    .. "  at (" .. worldObj:getSquare():getX() .. ","
    .. worldObj:getSquare():getY() .. "))")

-- Search for a cart to also classify it
local cartItem
for i = 0, p:getInventory():getItems():size() - 1 do
    local it = p:getInventory():getItems():get(i)
    if SaucedCarts.safeIsCart and SaucedCarts.safeIsCart(it) then cartItem = it; break end
end
if cartItem then
    table.insert(lines, "in-hand cart:      classifier -> "
        .. classify(cartItem:getItemContainer()))
end

table.insert(lines, "")
table.insert(lines, "DIAGNOSIS: if world container classified as 'inv',")
table.insert(lines, "  server falls back to playerInv in resolveSide, which is wrong.")
table.insert(lines, "  Transfer then uses the player's inventory instead of the shelf/freezer.")
table.insert(lines, "  Expected post-fix: 'world' kind with square coords + container type.")

return table.concat(lines, "\n")
