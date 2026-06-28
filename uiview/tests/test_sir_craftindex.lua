--[[ sir_craftindex — the skill-lens craft reverse-index, against RecipeDB.
     Verifies it scans real-shaped recipes, filters by skill (involvesSkill),
     resolves tag inputs to items (getPossibleInputItems), merges Carpentry+Carving
     into woodwork, and tags each item tool/mat. This is the path that has no
     recipe DB in-game-headlessly — RecipeDB is what makes it testable. ]]
local Assert    = PZTestKit.Assert
local RecipeDB  = require "UIView/RecipeDB"
require "sir_craftindex"
local SIR = _G.SauceInvRender

-- build the index against the fixtures, then restore + clear so the fixture index
-- doesn't leak into other tests (which mock SIR.Craft.role differently)
local function buildUnder(fn)
    RecipeDB.install()
    SIR.Craft._index = nil
    local ok, res = pcall(function() return fn(SIR.Craft.build()) end)
    SIR.Craft._index = nil
    RecipeDB.restore()
    if not ok then error(res) end
    return res
end

local tests = {}

tests["index_maps_items_to_skills_with_roles"] = function()
    return buildUnder(function(idx)
        -- woodwork = Woodwork + Carving merged
        if not Assert.equal(idx.woodwork["Base.Log"], "mat", "log -> woodwork material") then return false end
        if not Assert.equal(idx.woodwork["Base.Plank"], "mat", "plank -> woodwork material") then return false end
        if not Assert.equal(idx.woodwork["Base.Saw"], "tool", "saw -> woodwork tool") then return false end
        if not Assert.equal(idx.woodwork["Base.GardenSaw"], "tool", "tag input resolves all items (GardenSaw)") then return false end
        if not Assert.equal(idx.woodwork["Base.WoodSculpture"], "mat", "carving input merged into woodwork") then return false end
        -- blacksmith
        if not Assert.equal(idx.blacksmith["Base.SteelIngot"], "mat", "ingot -> blacksmith material") then return false end
        if not Assert.equal(idx.blacksmith["Base.Hammer"], "tool", "hammer -> blacksmith tool") then return false end
        -- welding
        if not Assert.equal(idx.welding["Base.MetalSheet"], "mat", "sheet -> welding material") then return false end
        if not Assert.equal(idx.welding["Base.BlowTorch"], "tool", "blowtorch -> welding tool") then return false end
        return true
    end)
end

tests["skills_stay_isolated"] = function()
    return buildUnder(function(idx)
        -- a blacksmith-only material must NOT bleed into woodwork/welding
        if not Assert.equal(idx.woodwork["Base.SteelIngot"], nil, "ingot not in woodwork") then return false end
        return Assert.equal(idx.welding["Base.Log"], nil, "log not in welding")
    end)
end

return tests
