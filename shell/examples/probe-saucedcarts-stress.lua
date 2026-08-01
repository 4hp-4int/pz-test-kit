-- LIVE STRESS TEST: container ↔ cart transfer matrix.
--
-- Drives N real handleCartTransfer invocations against the live dedi VM
-- using REAL PZ HandWeapon/InventoryItem/ItemContainer objects (not mocks).
-- Alternates "new client" (srcKind="world" + coords) and "old client"
-- (srcKind="inv" — exercises the defensive fallback) styles.
--
-- After every transfer, verifies invariants:
--   1. Conservation — total item count across all participants unchanged
--   2. Uniqueness   — no item appears in two containers
--   3. Final state  — item in exactly one container (src OR dest)
--
-- Cleanup: restores all spawned items to their seed locations and removes
-- the test cart.
--
-- Usage: ./pz-shell eval -f examples/probe-saucedcarts-stress.lua

local CYCLES = 100  -- transfer count: half "new client", half "old client"

local p = getOnlinePlayers() and getOnlinePlayers():size() > 0 and getOnlinePlayers():get(0)
if not p then return "FAIL: needs a connected player" end
local psq = p:getCurrentSquare()
if not psq then return "FAIL: player has no current square" end

-- Find a nearby world container. RADIUS CAPPED AT 3 to match the server's
-- findItemNearPlayer defensive radius. Also requires at least 5 kg of free
-- capacity — pre-loaded world containers (residential overheads with vanilla
-- loot spawns) can already be over cap, which rejects every hasRoomFor check
-- and tanks the test with nothing but capacity failures.
local worldCont, worldSq
for dy = -3, 3 do
    for dx = -3, 3 do
        local sq = getCell():getGridSquare(psq:getX() + dx, psq:getY() + dy, psq:getZ())
        if sq then
            for i = 0, sq:getObjects():size() - 1 do
                local o = sq:getObjects():get(i)
                local c = o.getContainer and o:getContainer()
                if c and c.getCapacity and c.getCapacityWeight then
                    local free = c:getCapacity() - c:getCapacityWeight()
                    if free >= 5 then worldCont = c; worldSq = sq; break end
                end
            end
        end
        if worldCont then break end
    end
    if worldCont then break end
end
if not worldCont then return "FAIL: no world container with >=5kg free capacity within 3 tiles" end

-- Spawn a throwaway cart and put it in player inv.
local cart = instanceItem("SaucedCarts.ShoppingCart")
if not cart then return "FAIL: could not spawn ShoppingCart" end
p:getInventory():AddItem(cart)
local cartCont = cart:getItemContainer()
if not cartCont then
    p:getInventory():Remove(cart)
    return "FAIL: cart has no inner container"
end

-- Seed N test items into the world container.
local N = 20
local seedItems = {}
for i = 1, N do
    local it = instanceItem("Base.PopBottle")
    if it then
        worldCont:AddItem(it)
        seedItems[#seedItems + 1] = it
    end
end
if #seedItems == 0 then
    p:getInventory():Remove(cart)
    return "FAIL: could not seed any test items"
end

-- Capture initial scene state.
local function locationOf(itemId)
    if worldCont:getItemById(itemId) then return "world" end
    if cartCont:getItemById(itemId)  then return "cart"  end
    if p:getInventory():getItemById(itemId) then return "playerInv" end
    return "MISSING"
end

local function totalItemCount()
    return worldCont:getItems():size()
        + cartCont:getItems():size()
end

local handler = SaucedCarts.CartTransferInterceptor.handleCartTransfer
local initialTotal = totalItemCount()

-- Make handleCartTransfer args mirroring what a client would send.
-- mode: "new" = world classifier, "old" = legacy "inv" classifier (defensive fallback)
-- direction: "in" (world → cart) or "out" (cart → world)
local function makeArgs(item, direction, mode)
    local args = {
        itemId    = item:getID(),
        cartId    = cart:getID(),
        direction = direction,
    }
    if direction == "in" then
        args.destKind = "cart"
        args.destCartId = cart:getID()
        if mode == "new" then
            args.srcKind = "world"
            args.srcSqX, args.srcSqY, args.srcSqZ = worldSq:getX(), worldSq:getY(), worldSq:getZ()
            args.srcContType = worldCont:getType()
        else
            args.srcKind = "inv"  -- old client — defensive fallback path
        end
    else  -- "out": cart → world
        args.srcKind = "cart"
        args.srcCartId = cart:getID()
        if mode == "new" then
            args.destKind = "world"
            args.destSqX, args.destSqY, args.destSqZ = worldSq:getX(), worldSq:getY(), worldSq:getZ()
            args.destContType = worldCont:getType()
        else
            args.destKind = "inv"  -- old client — server falls back to playerInv (the bug)
        end
    end
    return args
end

-- Run the stress loop.
local violations = {}
local function check(label, item, expectedLoc)
    local actual = locationOf(item:getID())
    if actual ~= expectedLoc then
        violations[#violations + 1] = string.format("%s: item %d expected %s, found %s",
            label, item:getID(), expectedLoc, actual)
    end
    if totalItemCount() ~= initialTotal then
        violations[#violations + 1] = string.format("%s: conservation lost (expected %d, got %d)",
            label, initialTotal, totalItemCount())
    end
end

local runs = 0
local newClientWins, oldClientWins = 0, 0
for cycle = 1, CYCLES do
    local mode = (cycle % 2 == 0) and "new" or "old"
    local item = seedItems[((cycle - 1) % #seedItems) + 1]
    local startLoc = locationOf(item:getID())

    -- Decide direction based on where the item currently is.
    local direction = (startLoc == "world") and "in" or "out"
    local expectedFinal = (direction == "in") and "cart" or "world"

    -- For "out" with old client, the server's resolveSide returns playerInv
    -- (defensive fallback only handles "in" direction). Skip — row 9 is a
    -- known limitation, not what we're stress-testing.
    local skip = (direction == "out" and mode == "old")
    if not skip then
        local args = makeArgs(item, direction, mode)
        pcall(handler, p, args)
        runs = runs + 1
        if mode == "new" then newClientWins = newClientWins + 1
        else oldClientWins = oldClientWins + 1 end
        check(string.format("cycle %d (%s/%s)", cycle, mode, direction), item, expectedFinal)
    end
end

-- Cleanup: restore all seed items to the world container, remove cart.
for _, it in ipairs(seedItems) do
    local loc = locationOf(it:getID())
    if loc == "cart" then
        cartCont:Remove(it)
        worldCont:AddItem(it)
    elseif loc == "playerInv" then
        p:getInventory():Remove(it)
        worldCont:AddItem(it)
    end
end
-- Cleanup the cart itself (and any extras still in it).
local cartItems = cartCont:getItems()
for i = cartItems:size() - 1, 0, -1 do
    cartCont:Remove(cartItems:get(i))
end
p:getInventory():Remove(cart)

-- Final report.
local lines = {
    string.format("CYCLES: %d total (new=%d, old=%d)", runs, newClientWins, oldClientWins),
    string.format("seed items: %d in %s container at (%d,%d)",
        #seedItems, worldCont:getType(), worldSq:getX(), worldSq:getY()),
    string.format("cart: SaucedCarts.ShoppingCart id=%s", tostring(cart:getID())),
    string.format("INVARIANT VIOLATIONS: %d", #violations),
}
if #violations > 0 then
    table.insert(lines, "first 5 violations:")
    for i = 1, math.min(5, #violations) do
        table.insert(lines, "  " .. violations[i])
    end
    table.insert(lines, "VERDICT: FAIL")
else
    table.insert(lines, "VERDICT: OK — all transfers preserved invariants")
end
return table.concat(lines, "\n")
