-- Does the framework ACTUALLY own each magazine weapon's capacity, or is the
-- blanket cede over-broad? Method (same one that proved SWMG ignores the
-- nailgun): VPS-set a +7 bump, run SWMG's own StatsFactory.ReapplyAllModifiers,
-- check if it clobbered it. GGS writes capacity ONLY on explicit player
-- mag-swap (MagazineTypeNow) -> a fresh/default weapon is NOT GGS-owned, and
-- VPS already detects the swapped case via getDynamicMagazineType.
local V, WD = VorpallySauced, VorpallySauced.WeaponData
local SF
do local ok, m = pcall(require, "WeaponSystems/Utils/StatsFactory"); if ok then SF = m end end

local items = getScriptManager():getAllItems()
local R = {}
local function row(m) R[m] = R[m] or { mag=0, swmgOwned=0, swmgFree=0 }; return R[m] end
local freeSamples, ownedSamples = {}, {}

for i = 0, items:size() - 1 do
    local s = items:get(i)
    local mod = s:getModuleName()
    if mod == "Base" or mod == "MarzGuns" then
        local ft = mod .. "." .. s:getName()
        local ok, w = pcall(instanceItem, ft)
        if ok and w and w.isRanged and w:isRanged() and WD.isValidFirearm(w)
           and w.getMagazineType and (w:getMagazineType() or "") ~= "" then
            local g = row(mod); g.mag = g.mag + 1
            local m0 = w:getMaxAmmo() or 0
            w:setMaxAmmo(m0 + 7)                       -- simulate a VPS capacity affix
            if SF and SF.ReapplyAllModifiers then pcall(SF.ReapplyAllModifiers, w) end
            local after = w:getMaxAmmo() or 0
            if after == m0 + 7 then
                g.swmgFree = g.swmgFree + 1            -- SWMG did NOT touch it
                if #freeSamples < 8 then freeSamples[#freeSamples+1] = ft end
            else
                g.swmgOwned = g.swmgOwned + 1          -- SWMG reset it -> truly owned
                if #ownedSamples < 8 then ownedSamples[#ownedSamples+1] = ft.." ("..(m0+7).."->"..after..")" end
            end
        end
    end
end

local o = { "== MAGAZINE-WEAPON OWNERSHIP == SWMG="..tostring(V.Compat and V.Compat.SWMG)
            .." DynMag(GGS)="..tostring(V.Compat and V.Compat.DynamicMagazines)
            .." StatsFactory="..tostring(SF ~= nil) }
for m, g in pairs(R) do
    o[#o+1] = string.format("[%s] magazine weapons=%d | SWMG-OWNED=%d | SWMG-FREE (VPS could support)=%d",
        m, g.mag, g.swmgOwned, g.swmgFree)
end
o[#o+1] = "-- sample SWMG-FREE (currently ceded but framework doesn't touch) --"
for _, f in ipairs(freeSamples) do o[#o+1] = "  "..f end
o[#o+1] = "-- sample SWMG-OWNED (cede justified) --"
for _, f in ipairs(ownedSamples) do o[#o+1] = "  "..f end
o[#o+1] = "NOTE: GGS owns capacity ONLY after a player mag-swap (MagazineTypeNow);"
o[#o+1] = "default GGS mag weapons are NOT GGS-owned (getDynamicMagazineType=nil)."
return table.concat(o, "\n")
