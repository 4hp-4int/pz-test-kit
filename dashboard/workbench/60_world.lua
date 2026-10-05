--[[
    The real world in the workbench VM: PZEngine.loadWorld (tile definitions +
    metagrid + ServerMap, once) and PZEngine.loadCell (the game's CellLoader
    over a cell's chunks, at REAL world coordinates).

    Tools:  worldStatus{}                       loaded? what's loaded
            worldLoad{map}                      boot the world ("Muldraugh, KY")
            worldArea{x, y, r}                  load the chunks covering a box
            worldSquare{x, y, z}                one square: room, objects, verbs' raw data
            worldTiles{x0, y0, x1, y1, zLo, zHi} sprite stacks for drawing an area

    Square lookups run with GameServer.server set: IsoCell.getGridSquare
    answers from ServerMap only on a server (IsoCell.java:3345), which is
    where loadCell registers chunks. getCell() stays the kit's mock.
]]

local try = WB.try
local W = WB.world or { loaded = false, chunks = {} }
WB.world = W

local function s(v) if v == nil then return nil end return tostring(v) end

-- The kit's SandboxVars mock carries only what tests set; world code reads
-- vanilla options (scrap: LevelForDismantleXPCutoff). Fill every MISSING key
-- from the engine's SandboxOptions defaults, laid out as toTable does
-- (SandboxOptions.java:1397: tableName page, else top level).
function WB.fillSandboxDefaults()
    local so = try(function() return SandboxOptions.instance end)
    if not (so and SandboxVars) then return 0 end
    local added = 0
    for i = 0, (try(function() return so:getNumOptions() end) or 0) - 1 do
        local o = so:getOptionByIndex(i)
        local page = try(function() return o:getTableName() end)
        local key = tostring(o:getShortName())
        local t = SandboxVars
        if page then
            page = tostring(page)
            if type(SandboxVars[page]) ~= "table" then SandboxVars[page] = {} end
            t = SandboxVars[page]
        end
        if t[key] == nil then
            local v = try(function() return o:asConfigOption():getValueAsObject() end)
            if v ~= nil then t[key] = v; added = added + 1 end
        end
    end
    return added
end
pcall(WB.fillSandboxDefaults)

local function asServer(fn)
    local prev = PZEngine.setServer and PZEngine.setServer(true)
    local ok, a, b = pcall(fn)
    if PZEngine.setServer then PZEngine.setServer(prev) end
    if not ok then error(a, 0) end
    return a, b
end

local function need()
    if not (PZEngine and PZEngine.available()) then error("engine unavailable in this mod context") end
    if not PZEngine.loadWorld then error("this kit's engine bridge has no loadWorld (rebuild the kit)") end
end

function W.ensure(map)
    need()
    if W.loaded then return true end
    local t, err = PZEngine.loadWorld(map)
    if not t then error("loadWorld: " .. tostring(err), 0) end
    W.loaded, W.summary, W.map = true, t, map or "Muldraugh, KY"
    return true
end

-- Load every chunk overlapping [x0..x1] x [y0..y1] (cells may straddle).
function W.loadBox(x0, y0, x1, y1)
    W.ensure()
    local wx0, wy0, wx1, wy1 = math.floor(x0 / 8), math.floor(y0 / 8), math.floor(x1 / 8), math.floor(y1 / 8)
    local n, ms = 0, 0
    for cx = math.floor(wx0 / 32), math.floor(wx1 / 32) do
        for cy = math.floor(wy0 / 32), math.floor(wy1 / 32) do
            local lx0, ly0 = math.max(0, wx0 - cx * 32), math.max(0, wy0 - cy * 32)
            local lx1, ly1 = math.min(31, wx1 - cx * 32), math.min(31, wy1 - cy * 32)
            local r, err = PZEngine.loadCell(cx, cy, lx0, ly0, lx1, ly1)
            if not r then error("loadCell " .. cx .. "," .. cy .. ": " .. tostring(err), 0) end
            local c = tonumber(r:match("chunks=(%d+)")) or 0
            n = n + c
            ms = ms + (tonumber(r:match("ms=(%d+)")) or 0)
        end
    end
    W.chunkCount = (W.chunkCount or 0) + n
    return n, ms
end

function W.square(x, y, z)
    return asServer(function() return PZEngine.cell():getGridSquare(x, y, z or 0) end)
end

local function spriteName(o)
    local spr = try(function() return o:getSprite() end)
    return spr and try(function() return spr:getName() end) or nil
end

-- Tile properties worth seeing at a glance (the ones that decide behaviour).
local PROPS = { "CustomName", "GroupName", "CustomItem", "IsMoveAble", "Material", "Material2", "CanScrap",
                "ContainerCapacity", "container", "Facing", "IsWaterCollector", "PickUpWeight", "IsoType",
                "EntityScriptName", "LightRadius", "WaterAmount", "waterAmount", "DoorWallN", "DoorWallW" }

local function propsOf(o)
    local spr = try(function() return o:getSprite() end)
    local pc = spr and try(function() return spr:getProperties() end)
    if not pc then return nil end
    local out, any = {}, false
    for _, k in ipairs(PROPS) do
        local v = try(function() return pc:get(k) end)
        if v ~= nil and v ~= "" then out[k] = s(v); any = true end
    end
    return any and out or nil
end

local COMPONENTS = { "SpriteConfig", "UiConfig", "CraftBench", "CraftLogic", "FurnaceLogic", "MashingLogic", "DryingLogic",
                     "FluidContainer", "Resources", "Script", "Parts", "Lua", "CraftRecipe", "AnimalFeedingTrough" }

local function componentsOf(o)
    if not (ComponentType and try(function() return o:hasComponents() end)) then return nil end
    local out = {}
    for _, name in ipairs(COMPONENTS) do
        local ct = ComponentType[name]
        if ct and try(function() return o:hasComponent(ct) end) then out[#out + 1] = name end
    end
    return out
end

local function containersOf(o)
    local n = try(function() return o:getContainerCount() end) or 0
    if n == 0 then return nil end
    local out = {}
    for i = 0, n - 1 do
        local c = o:getContainerByIndex(i)
        out[#out + 1] = { type = s(try(function() return c:getType() end)), items = try(function() return c:getItems():size() end) or 0,
                          capacity = try(function() return c:getCapacity() end), ref = WB.ref(c) }
    end
    return out
end

local function fluidOf(o)
    local fc = try(function() return o:getFluidContainer() end)
    if not fc then return nil end
    return { amount = try(function() return fc:getAmount() end), capacity = try(function() return fc:getCapacity() end),
             fluid = s(try(function() return fc:getPrimaryFluid():getFluidTypeString() end)) or s(try(function() return fc:getPrimaryFluid() end)),
             ref = WB.ref(fc) }
end

function W.objectInfo(o, i)
    return {
        index = i, class = WB.className(o), sprite = spriteName(o),
        name = s(try(function() return o:getObjectName() end)),
        entity = s(try(function() return o:getEntityScript() and o:getEntityScript():getName() end)),
        components = componentsOf(o), containers = containersOf(o), fluid = fluidOf(o), props = propsOf(o),
        ref = WB.ref(o),
    }
end

function W.squareInfo(sq)
    local room = try(function() return sq:getRoom() end)
    local info = {
        x = sq:getX(), y = sq:getY(), z = sq:getZ(), ref = WB.ref(sq),
        room = room and s(try(function() return room:getName() end)) or nil,
        building = room and try(function() return room:getBuilding() ~= nil end) or false,
        outside = try(function() return sq:isOutside() end),
        objects = {}, items = {},
    }
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do info.objects[#info.objects + 1] = W.objectInfo(objs:get(i), i) end
    local wobs = try(function() return sq:getWorldObjects() end)
    if wobs then
        for i = 0, wobs:size() - 1 do
            local it = try(function() return wobs:get(i):getItem() end)
            if it then info.items[#info.items + 1] = { fullType = s(it:getFullType()), name = s(it:getDisplayName()), ref = WB.ref(it) } end
        end
    end
    return info
end

-- ── tools ─────────────────────────────────────────────────────────────────
WB.register("worldStatus", function()
    return { available = PZEngine and PZEngine.loadWorld ~= nil, loaded = W.loaded, map = W.map, summary = W.summary, chunks = W.chunkCount or 0 }
end)

WB.register("worldLoad", function(a)
    W.ensure(a.map)
    return { loaded = true, map = W.map, summary = W.summary }
end)

WB.register("worldArea", function(a)
    local x, y, r = math.floor(a.x), math.floor(a.y), math.floor(a.r or 8)
    local n, ms = W.loadBox(x - r, y - r, x + r, y + r)
    return { chunks = n, ms = ms, total = W.chunkCount }
end)

WB.register("worldSquare", function(a)
    W.ensure()
    local x, y, z = math.floor(a.x), math.floor(a.y), math.floor(a.z or 0)
    if a.load ~= false then W.loadBox(x - 8, y - 8, x + 8, y + 8) end
    local sq = W.square(x, y, z)
    if not sq then return { x = x, y = y, z = z, empty = true } end
    return asServer(function() return W.squareInfo(sq) end)
end)

-- Sprite stacks per tile for the browser renderer (pzmap's atlases). Capped
-- at 48x48 tiles; z range defaults to the ground floor.
WB.register("worldTiles", function(a)
    W.ensure()
    local x0, y0 = math.floor(a.x0), math.floor(a.y0)
    local x1, y1 = math.min(math.floor(a.x1), x0 + 47), math.min(math.floor(a.y1), y0 + 47)
    local zLo, zHi = math.floor(a.zLo or 0), math.floor(a.zHi or 0)
    if a.load ~= false then W.loadBox(x0, y0, x1, y1) end
    local tiles = {}
    asServer(function()
        local cell = PZEngine.cell()
        for z = zLo, zHi do
            for x = x0, x1 do
                for y = y0, y1 do
                    local sq = cell:getGridSquare(x, y, z)
                    if sq then
                        local objs, names = sq:getObjects(), {}
                        for i = 0, objs:size() - 1 do
                            local n = spriteName(objs:get(i))
                            if n then names[#names + 1] = n end
                        end
                        if #names > 0 then tiles[#tiles + 1] = { x = x, y = y, z = z, s = names } end
                    end
                end
            end
        end
    end)
    return { x0 = x0, y0 = y0, x1 = x1, y1 = y1, zLo = zLo, zHi = zHi, tiles = tiles }
end)
