-- Broad sweep: every ranged firearm in Base + MarzGuns. Under live SWMG,
-- the invariant for a fresh weapon (no sticky, scriptType matches) is:
--   isDynamicCapacityWeapon == (getMagazineType() ~= "")
-- and every NON-ceded (loose-ammo) firearm must take a clipSize affix.
local V, WD, SM = VorpallySauced, VorpallySauced.WeaponData, VorpallySauced.StatModifiers
local sfxId, sfxVal
for i, s in ipairs(V.FirearmSuffixes) do
    if s.stat == "clipSize" then sfxId, sfxVal = i, s.value break end
end

local sm = getScriptManager()
local items = sm:getAllItems()
local stat = {}                       -- module -> {n, mag, loose, anomaly, clipOK, clipBad}
local anomalies, clipFails = {}, {}

for i = 0, items:size() - 1 do
    local s = items:get(i)
    local mod = s:getModuleName()
    if true then
        local ft = mod .. "." .. s:getName()
        local ok, w = pcall(instanceItem, ft)
        if ok and w and w.isRanged and w:isRanged() and WD.isValidFirearm(w) then
            local st = stat[mod] or { n=0, mag=0, loose=0, anomaly=0, clipOK=0, clipBad=0 }
            stat[mod] = st
            st.n = st.n + 1
            local mt = (w.getMagazineType and w:getMagazineType()) or ""
            local hasMag = mt ~= ""
            local d = WD.getOrCreateModData(w); d.isFirearm = true; d.dynamicCapacity = nil
            local ceded = V.isDynamicCapacityWeapon(w, d)
            if hasMag then st.mag = st.mag + 1 else st.loose = st.loose + 1 end
            -- invariant check (Compat.SWMG live == true on this dedi)
            if ceded ~= hasMag then
                st.anomaly = st.anomaly + 1
                if #anomalies < 25 then
                    anomalies[#anomalies+1] = string.format("%s magType=%q ceded=%s hasMag=%s",
                        ft, mt, tostring(ceded), tostring(hasMag))
                end
            end
            -- non-ceded must take clipSize
            if not ceded then
                local m0 = w:getMaxAmmo()
                d.suffixId = sfxId
                SM.reapplyUpgrades(w)
                if w:getMaxAmmo() > m0 then
                    st.clipOK = st.clipOK + 1
                else
                    st.clipBad = st.clipBad + 1
                    if #clipFails < 25 then
                        clipFails[#clipFails+1] = string.format("%s max %s->%s (+%s)",
                            ft, tostring(m0), tostring(w:getMaxAmmo()), tostring(sfxVal))
                    end
                end
            end
        end
    end
end

local o = { "Compat.SWMG=" .. tostring(V.Compat and V.Compat.SWMG) }
for mod, st in pairs(stat) do
    o[#o+1] = string.format(
        "[%s] firearms=%d  mag=%d loose=%d  cede-invariant-anomalies=%d  loose-clipSize OK=%d FAIL=%d",
        mod, st.n, st.mag, st.loose, st.anomaly, st.clipOK, st.clipBad)
end
o[#o+1] = "-- anomalies (ceded != hasMagType) --"
for _, a in ipairs(anomalies) do o[#o+1] = "  " .. a end
if #anomalies == 0 then o[#o+1] = "  none" end
o[#o+1] = "-- loose-ammo weapons where clipSize did NOT apply --"
for _, c in ipairs(clipFails) do o[#o+1] = "  " .. c end
if #clipFails == 0 then o[#o+1] = "  none" end
return table.concat(o, "\n")
