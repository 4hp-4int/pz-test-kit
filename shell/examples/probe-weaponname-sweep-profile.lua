-- WEAPONNAMES SWEEP PROFILE — measures what the VPS name reconciler actually
-- costs, on a live CLIENT with a real world loaded.
--
-- WHY A PROBE AND NOT A TEST: the sweep walks an item graph whose size is set
-- by how much loot the player is standing near — worn bags, nearby crates, a
-- car trunk, corpses, and whatever a proximity-inventory mod has aggregated
-- into the loot pane. The offline Kahlua VM has none of that, so it can prove
-- the sweep is CORRECT but can say nothing about what it COSTS. Only a client
-- standing somewhere real can.
--
-- RUN IT SOMEWHERE EXPENSIVE. Standing in an empty field measures nothing.
-- The numbers that matter come from the worst case you can construct:
--   - inside a warehouse / crate room, ideally with a full loot pane open
--   - wearing a loaded backpack, standing next to a packed car trunk
--   - with Proximity Inventory or Better Containers running, which widen the
--     displayed-container set well past the 3x3 this otherwise walks
--
-- READ: the per-surface table is the point. "the sweep is slow" is not
-- actionable; "square is 90% of it" tells you where to spend the budget.
--
--   ./pz-shell eval -f examples/probe-weaponname-sweep-profile.lua
--
-- Client-only: WeaponNames does not load on a dedicated server (it is a
-- display concern, and a dedi cannot resolve translations at all).

local ITERATIONS = 30

local Names = VorpallySauced and VorpallySauced.WeaponNames
if not Names then
    return "FAIL: WeaponNames not loaded. This is a CLIENT-only module — run "
        .. "this against a client, not the dedi."
end
if not Names.report or not Names.collectSurfaces then
    return "FAIL: this build predates the sweep profiler. Deploy and restart "
        .. "the client (PZ loads Lua once, at process start)."
end

local player = getPlayer()
if not player then return "FAIL: no local player" end

local lines = {}
local function add(s) lines[#lines + 1] = s end

-- ---------------------------------------------------------------------------
-- CENSUS. The timings below mean nothing without knowing what was in reach.
-- ---------------------------------------------------------------------------
add("=== WeaponNames sweep profile ===")

local ok, surfaces = pcall(Names.collectSurfaces, player)
add(string.format("surfaces in reach:      %s",
    ok and tostring(#surfaces) or ("ERROR " .. tostring(surfaces))))

local inv = player:getInventory()
add(string.format("top-level inv items:    %d",
    (inv and inv:getItems()) and inv:getItems():size() or -1))

-- How much the loot pane is showing is the number a proximity mod inflates,
-- so call it out separately.
local shown, containers = 0, 0
for _, get in ipairs({ getPlayerInventory, getPlayerLoot }) do
    if get then
        local page = get(player:getPlayerNum() or 0)
        local backpacks = page and page.backpacks
        if backpacks then
            for i = 1, #backpacks do
                local c = backpacks[i] and backpacks[i].inventory
                if c then
                    containers = containers + 1
                    local items = c.getItems and c:getItems()
                    if items then shown = shown + items:size() end
                end
            end
        end
    end
end
add(string.format("loot pane:              %d containers, %d items", containers, shown))

-- ---------------------------------------------------------------------------
-- MEASURE. Sweeps after the first rebuild nothing (rebuilding is idempotent),
-- so what this times is the steady-state SCAN cost — which is the thing that
-- runs on every tick that fires a container event, and therefore the thing
-- worth knowing.
-- ---------------------------------------------------------------------------
Names.resetProfile()
Names.profile(true)

local t0 = getTimestampMs()
for _ = 1, ITERATIONS do
    Names._sweep()      -- mark dirty
    Names._drain()      -- and run it now rather than waiting for OnTick
end
local wall = getTimestampMs() - t0

Names.profile(false)

add("")
add(string.format("forced %d sweeps in %d ms wall  (%.3f ms/sweep)",
    ITERATIONS, wall, wall / ITERATIONS))
add("")
add(Names.report())
add("")
add("Budget note: 'deferred' counts sweeps that hit the item cap and finished")
add("on a later frame. A non-zero number is the bound WORKING, not a fault —")
add("but if it is ~100% the reconciler is permanently behind and the cap")
add("(ITEM_BUDGET in WeaponNames.lua) is too low for this environment.")

return table.concat(lines, "\n")
