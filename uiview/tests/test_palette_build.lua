--[[ pal_build — enumerate buildable-now entities and hand off to the ghost cursor.
     Was 24% covered. Tests: buildable recipes become "Build: X" rows (cursor=true),
     dedup by recipe name, and running a row activates placement without error. ]]
local Assert    = PZTestKit.Assert
local CraftMock = require "UIView/CraftMock"
require "palette/pal_craft"     -- SP.recipeName / SP.recipeDetail
require "palette/pal_build"
local SP = _G.SaucePalette
local B  = SP.Build

local function jlist(t) return { size = function() return #t end, get = function(_, i) return t[i + 1] end } end

local function buildRecipe(nm)
    return {
        getName = function() return nm end, getTranslationName = function() return nm end,
        getInputs = function() return jlist({}) end, getOutputs = function() return jlist({}) end,
        getIconTexture = function() return nil end,
        getToolBoth = function() return nil end, getToolRight = function() return nil end,
        getToolLeft = function() return nil end,
    }
end

local function info(recipe)
    return { getRecipe = function() return { getCraftRecipe = function() return recipe end } end }
end

-- install CraftMock + the build globals (catalog of `infos`, BuildLogic, cursor).
local function buildEnv(infos, fn)
    SP.Build._infos = nil
    CraftMock.install({})
    local s = {}
    for _, n in ipairs({ "ISBuildIsoEntity", "BuildLogic", "getCell" }) do s[n] = _G[n] end
    _G.ISBuildIsoEntity = {
        GetAllBuildableEntities = function() return infos end,
        predicateMaterial = function() return true end,
        new = function() return {} end,
    }
    _G.BuildLogic = { new = function() return {
        setContainers = function() end,
        setRecipe = function(self, r) self._r = r end,
        canPerformCurrentRecipe = function(self) return self._r ~= nil end,
    } end }
    _G.getCell = function() return { setDrag = function() end } end
    local ok, err = pcall(fn)
    for k, v in pairs(s) do _G[k] = v end
    CraftMock.restore(); SP.Build._infos = nil
    if not ok then error(err) end
end

local tests = {}

tests["enumerates_buildable_now"] = function()
    local cmds
    buildEnv({ info(buildRecipe("Wooden Wall")) }, function() cmds = B.collect(0) end)
    if not Assert.equal(#cmds, 1, "one buildable row") then return false end
    local c = cmds[1]
    if not Assert.equal(c.category, "build", "build category") then return false end
    if not Assert.equal(c.cursor, true, "hands off to a ghost cursor") then return false end
    return Assert.isTrue(c.label:find("Wooden Wall", 1, true) ~= nil, "labelled with the recipe (Build: Wooden Wall)")
end

tests["dedupes_by_recipe_name"] = function()
    -- two sprite variants share one recipe -> one row (the cursor handles orientation)
    local r = buildRecipe("Wooden Wall")
    local cmds
    buildEnv({ info(r), info(r) }, function() cmds = B.collect(0) end)
    return Assert.equal(#cmds, 1, "sprite variants of one recipe collapse to a single row")
end

tests["run_activates_placement_without_error"] = function()
    local ranOk
    buildEnv({ info(buildRecipe("Wooden Wall")) }, function()
        local cmds = B.collect(0)
        ranOk = pcall(function() cmds[1].run() end)
    end)
    return Assert.equal(ranOk, true, "running a build row activates the placement cursor cleanly")
end

return tests
