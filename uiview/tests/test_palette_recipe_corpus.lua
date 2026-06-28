--[[ REAL-CORPUS sweep. Runs our actual resolver over the parsed real B42 recipe
     scripts (RecipeDB.installReal -> RealRecipes.lua, from tools/parse_recipes.py),
     not hand-rolled fixtures. The point is bug-FINDING, not regression-netting: if
     ANY of the ~623 real recipe input/output shapes trips SP.Resolve or yields an
     empty verdict, this fails with the offenders. Green here means our resolver
     genuinely handles the whole shipped corpus. ]]
local Assert    = PZTestKit.Assert
local RecipeDB  = require "UIView/RecipeDB"
require "palette/pal_resolve"
local SP = _G.SaucePalette
local R  = SP.Resolve

local tests = {}

tests["resolver_handles_every_real_recipe"] = function()
    local recipes = RecipeDB.installReal()
    local errs = {}
    local outConcrete, outVarious, inConcrete, inCategory, inVarious = 0, 0, 0, 0, 0
    for _, rec in ipairs(recipes) do
        local nm = rec:getName()
        local outs = rec:getOutputs()
        for i = 0, outs:size() - 1 do
            local ok, v = pcall(function() return R.recipeOutput(outs:get(i), nil) end)
            if not ok then errs[#errs + 1] = nm .. " OUT: error " .. tostring(v)
            elseif type(v) ~= "table" or not v.name or v.name == "" then
                errs[#errs + 1] = nm .. " OUT: empty verdict"
            elseif v.kind == "various" then outVarious = outVarious + 1
            else outConcrete = outConcrete + 1 end
        end
        local ins = rec:getInputs()
        for i = 0, ins:size() - 1 do
            local ok, v = pcall(function() return R.recipeInput(ins:get(i), nil) end)
            if not ok then errs[#errs + 1] = nm .. " IN: error " .. tostring(v)
            elseif type(v) ~= "table" or not v.name or v.name == "" then
                errs[#errs + 1] = nm .. " IN: empty verdict"
            elseif v.kind == "concrete" then inConcrete = inConcrete + 1
            elseif v.kind == "category" then inCategory = inCategory + 1
            else inVarious = inVarious + 1 end
        end
    end
    RecipeDB.restore()
    if #errs > 0 then
        print("[corpus] " .. #errs .. " resolver failures (first 12):")
        for i = 1, math.min(12, #errs) do print("    " .. errs[i]) end
    end
    print(string.format("[corpus] %d recipes | outputs: concrete=%d various=%d | inputs: concrete=%d category=%d various=%d",
        #recipes, outConcrete, outVarious, inConcrete, inCategory, inVarious))
    return Assert.equal(#errs, 0, "the resolver handles every real recipe input/output (no error, no empty verdict)")
end

-- With LIVE recipe data, a mapper output must resolve to a CONCRETE item (the fix
-- that started this). Drive a fake recipeData so o:getItem(data) returns the mapped
-- result, over every real mapper output in the corpus.
tests["mapper_outputs_resolve_concrete_with_data"] = function()
    local recipes = RecipeDB.installReal()
    local mapperOuts, resolved, fails = 0, 0, {}
    local fakeData = {}     -- non-nil -> the mock returns the mapper's resolved item
    for _, rec in ipairs(recipes) do
        local outs = rec:getOutputs()
        for i = 0, outs:size() - 1 do
            local o = outs:get(i)
            local mp; pcall(function() mp = o:getOutputMapper() end)
            if mp and not mp:isEmpty() then
                mapperOuts = mapperOuts + 1
                local v = R.recipeOutput(o, fakeData)
                if v and v.kind == "concrete" and v.name and v.name ~= "" then resolved = resolved + 1
                else fails[#fails + 1] = rec:getName() end
            end
        end
    end
    RecipeDB.restore()
    if #fails > 0 then
        print("[corpus] " .. #fails .. " mapper outputs DIDN'T resolve with data (first 8):")
        for i = 1, math.min(8, #fails) do print("    " .. fails[i]) end
    end
    print(string.format("[corpus] %d mapper outputs, %d resolved concrete with live data", mapperOuts, resolved))
    if not Assert.greater(mapperOuts, 10, "the corpus has real mapper outputs to test") then return false end
    return Assert.equal(resolved, mapperOuts, "every mapper output resolves to a concrete item when given recipe data")
end

return tests
