-- Feasibility: a PRECISE per-weapon cede using each framework's own registry.
--   Gunworks/SWMG owns a weapon IFF Magazine.GetProfileForGun(w) ~= nil
--   GGS owns a weapon IFF getDynamicMagazineType(w) ~= nil (player swapped)
-- Everything else with a magazine is currently ceded by the BLANKET rule but
-- neither framework actually manages it -> VPS could support capacity affixes.
local V, WD = VorpallySauced, VorpallySauced.WeaponData
local MAG
do local ok, m = pcall(require, "WeaponSystems/Utils/Magazine"); if ok then MAG = m end end

local items = getScriptManager():getAllItems()
local R = {}
local function row(m) R[m] = R[m] or { mag=0, gwOwned=0, ggsOwned=0, free=0 }; return R[m] end
local freeSamples, gwSamples = {}, {}

for i = 0, items:size() - 1 do
    local s = items:get(i)
    local mod = s:getModuleName()
    if mod == "Base" or mod == "MarzGuns" then
        local ft = mod .. "." .. s:getName()
        local ok, w = pcall(instanceItem, ft)
        if ok and w and w.isRanged and w:isRanged() and WD.isValidFirearm(w)
           and w.getMagazineType and (w:getMagazineType() or "") ~= "" then
            local g = row(mod); g.mag = g.mag + 1
            local gwProfile = MAG and MAG.GetProfileForGun and MAG.GetProfileForGun(w) or nil
            local ggsType   = V.getDynamicMagazineType and V.getDynamicMagazineType(w) or nil
            if gwProfile then
                g.gwOwned = g.gwOwned + 1
                if #gwSamples < 8 then gwSamples[#gwSamples+1] = ft.." -> "..tostring(gwProfile) end
            elseif ggsType then
                g.ggsOwned = g.ggsOwned + 1
            else
                g.free = g.free + 1
                if #freeSamples < 10 then freeSamples[#freeSamples+1] = ft end
            end
        end
    end
end

local o = { "== PRECISE-CEDE FEASIBILITY ==  Magazine module="..tostring(MAG ~= nil)
            .."  SWMG="..tostring(V.Compat and V.Compat.SWMG)
            .."  GGS="..tostring(V.Compat and V.Compat.DynamicMagazines) }
for m, g in pairs(R) do
    o[#o+1] = string.format(
        "[%s] magazine=%d | Gunworks-registered(cede justified)=%d | GGS-swapped=%d | NEITHER manages (VPS COULD support)=%d",
        m, g.mag, g.gwOwned, g.ggsOwned, g.free)
end
o[#o+1] = "-- sample Gunworks-registered (correctly ceded) --"
for _, f in ipairs(gwSamples) do o[#o+1] = "  "..f end
o[#o+1] = "-- sample NEITHER-manages (currently ceded by blanket, but free) --"
for _, f in ipairs(freeSamples) do o[#o+1] = "  "..f end
return table.concat(o, "\n")
