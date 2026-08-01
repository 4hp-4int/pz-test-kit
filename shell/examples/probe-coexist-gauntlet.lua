-- Coexistence-aware full gauntlet across Base+MarzGuns. Per magazine weapon
-- exercise BOTH mod mechanisms and require modBase + affix, surviving a B42
-- field reset:
--   Clip-part path  : attach mag as Clip WeaponPart, setMaxAmmo(magCap)
--   GGS path        : md.MagazineTypeNow = magType (getDynamicMagazineType)
-- Loose-ammo: script default + affix.
local V, WD, SM = VorpallySauced, VorpallySauced.WeaponData, VorpallySauced.StatModifiers
local clipSfx, A
for i, s in ipairs(V.FirearmSuffixes) do
    if s.stat == "clipSize" then clipSfx, A = i, (s.value or 0) break end
end

local items = getScriptManager():getAllItems()
local R = {}
local function row(m) R[m]=R[m] or {loose=0,looseOK=0, clip=0,clipOK=0,clipRst=0, ggs=0,ggsOK=0,ggsRst=0}; return R[m] end
local fails = {}
local function note(s) if #fails < 24 then fails[#fails+1]=s end end

local function freshAffixed(ft)
    local ok, w = pcall(instanceItem, ft); if not ok or not w then return nil end
    local d = WD.getOrCreateModData(w); d.isFirearm = true
    d.suffixId = clipSfx; d.dynamicCapacity = nil
    WD.rt(d.weaponId).appliedClipBonus = 0
    return w
end

for i = 0, items:size() - 1 do
    local sc = items:get(i)
    local mod = sc:getModuleName()
    if mod == "Base" or mod == "MarzGuns" then
        local ft = mod .. "." .. sc:getName()
        local pr = instanceItem(ft)
        if pr and pr.isRanged and pr:isRanged() and WD.isValidFirearm(pr) then
            local g = row(mod)
            local magType = pr.getMagazineType and pr:getMagazineType() or ""
            if magType == "" then
                local w = freshAffixed(ft); if w then
                    g.loose = g.loose + 1
                    local m0 = w:getMaxAmmo()
                    SM.reapplyUpgrades(w)
                    if w:getMaxAmmo() == m0 + A then g.looseOK = g.looseOK + 1
                    else note(ft.." LOOSE want "..(m0+A).." got "..tostring(w:getMaxAmmo())) end
                end
            else
                local okm, mag = pcall(instanceItem, magType)
                local magCap = (okm and mag and mag.getMaxAmmo and mag:getMaxAmmo()) or 0
                -- Clip-part path
                local w = freshAffixed(ft)
                if w and magCap > 0 then
                    g.clip = g.clip + 1
                    if w.attachWeaponPart and mag and instanceof(mag, "WeaponPart") then
                        pcall(function() if w.canAttachWeaponPart==nil or w:canAttachWeaponPart(mag) then w:attachWeaponPart(mag) end end)
                    end
                    w:setMaxAmmo(magCap)
                    local want = magCap + A
                    SM.reapplyUpgrades(w)
                    local cA = w:getMaxAmmo()
                    if cA == want then g.clipOK = g.clipOK + 1
                    else note(ft.." CLIP want "..want.." got "..tostring(cA).." rt="..tostring(w:getWeaponReloadType())) end
                    w:setMaxAmmo(7); SM.reapplyUpgrades(w)
                    if w:getMaxAmmo() == want then g.clipRst = g.clipRst + 1
                    elseif cA == want then note(ft.." CLIP reset drift -> "..tostring(w:getMaxAmmo())) end
                end
                -- GGS MagazineTypeNow path
                local w2 = freshAffixed(ft)
                if w2 and magCap > 0 then
                    g.ggs = g.ggs + 1
                    w2:getModData().MagazineTypeNow = magType
                    w2:setMaxAmmo(magCap)
                    local want = magCap + A
                    SM.reapplyUpgrades(w2)
                    local cA = w2:getMaxAmmo()
                    if cA == want then g.ggsOK = g.ggsOK + 1
                    else note(ft.." GGS want "..want.." got "..tostring(cA)) end
                    w2:setMaxAmmo(7); SM.reapplyUpgrades(w2)
                    if w2:getMaxAmmo() == want then g.ggsRst = g.ggsRst + 1
                    elseif cA == want then note(ft.." GGS reset drift -> "..tostring(w2:getMaxAmmo())) end
                end
            end
        end
    end
end

local o = { string.format("== COEXISTENCE GAUNTLET == affix +%s SWMG=%s GGS=%s",
    tostring(A), tostring(V.Compat and V.Compat.SWMG), tostring(V.Compat and V.Compat.DynamicMagazines)) }
for m, g in pairs(R) do
    o[#o+1] = string.format("[%s] loose %d/%d | CLIP apply %d/%d reset %d/%d | GGS apply %d/%d reset %d/%d",
        m, g.looseOK, g.loose, g.clipOK, g.clip, g.clipRst, g.clip, g.ggsOK, g.ggs, g.ggsRst, g.ggs)
end
o[#o+1] = "-- failures (cap 24) --"
for _, f in ipairs(fails) do o[#o+1] = "  " .. f end
if #fails == 0 then o[#o+1] = "  NONE — coexistence clean across the arsenal" end
return table.concat(o, "\n")
