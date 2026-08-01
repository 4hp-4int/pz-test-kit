-- Magazine display-name base across the full arsenal. getCleanBaseName now
-- delegates to WeaponData.cleanItemName, so test that directly per magazine.
-- PRE-FIX = old getCleanBaseName logic (script:getDisplayName() else
-- mag:getName()) replicated inline → before/after.
local V, WD = VorpallySauced, VorpallySauced.WeaponData
local items = getScriptManager():getAllItems()

local function rawFulltypeShaped(s, full)
    return (not s) or s == "" or s == full
        or (s:find("%.") and s:match("^[%w_]+%.[%w_]+$"))
end

-- collect unique magazine types referenced by Base+MarzGuns firearms
local seen, mags = {}, {}
for i = 0, items:size() - 1 do
    local sc = items:get(i)
    local mod = sc:getModuleName()
    if mod == "Base" or mod == "MarzGuns" then
        local ok, w = pcall(instanceItem, mod .. "." .. sc:getName())
        if ok and w and w.isRanged and w:isRanged() and WD.isValidFirearm(w) then
            local mt = w.getMagazineType and w:getMagazineType()
            if mt and mt ~= "" and not seen[mt] then
                seen[mt] = true; mags[#mags+1] = mt
            end
        end
    end
end

local total, preBad, postBad = 0, 0, 0
local preS, postS = {}, {}
for _, mt in ipairs(mags) do
    local ok, mag = pcall(instanceItem, mt)
    if ok and mag then
        total = total + 1
        local s = mag.getScriptItem and mag:getScriptItem()
        local full = s and s.getFullName and s:getFullName()
        -- PRE-FIX old getCleanBaseName
        local dn = s and s.getDisplayName and s:getDisplayName()
        local oldName = (dn and dn ~= "") and dn or (mag.getName and mag:getName()) or "Magazine"
        if rawFulltypeShaped(oldName, full) then
            preBad = preBad + 1
            if #preS < 10 then preS[#preS+1] = mt.." -> '"..tostring(oldName).."'" end
        end
        -- POST-FIX (what getCleanBaseName now returns)
        local newName = WD.cleanItemName and WD.cleanItemName(mag, "Magazine")
        if rawFulltypeShaped(newName, full) then
            postBad = postBad + 1
            if #postS < 10 then postS[#postS+1] = mt.." -> '"..tostring(newName).."'" end
        end
    end
end

local o = {
    string.format("== MAGAZINE-NAME ARSENAL == unique mag types=%d", total),
    string.format("PRE-FIX  raw-fulltype base names = %d", preBad),
    string.format("POST-FIX raw-fulltype base names = %d", postBad),
    "-- sample PRE-FIX bad --",
}
for _, s in ipairs(preS) do o[#o+1] = "  " .. s end
o[#o+1] = "-- POST-FIX bad (should be none) --"
for _, s in ipairs(postS) do o[#o+1] = "  " .. s end
if postBad == 0 then o[#o+1] = "  NONE — every magazine base name is clean" end
return table.concat(o, "\n")
