-- Validate the two fixes across the FULL arsenal (Base incl. GGS + MarzGuns):
--  (1) VPS originalName is NEVER the raw "Module.Type" fulltype (the
--      "reverted to script name" / MarzGuns.THOMPSON bug).
--  (2) preserveDynamicMagazineType NEVER pushes an unresolvable magazineType
--      onto the weapon (the vanilla HandWeapon.DoTooltip NPE vector) — even
--      when GGS MagazineTypeNow holds a bare/garbage value.
local V, WD = VorpallySauced, VorpallySauced.WeaponData
local items = getScriptManager():getAllItems()
local R = {}
local function row(m) R[m]=R[m] or {n=0, badName=0, npePushed=0}; return R[m] end
local fails = {}
local function note(s) if #fails < 24 then fails[#fails+1]=s end end

for i = 0, items:size() - 1 do
    local sc = items:get(i)
    local mod = sc:getModuleName()
    if mod == "Base" or mod == "MarzGuns" then
        local ft = mod .. "." .. sc:getName()
        local ok, w = pcall(instanceItem, ft)
        if ok and w and w.isRanged and w:isRanged() and WD.isValidFirearm(w) then
            local g = row(mod); g.n = g.n + 1
            local full = w:getScriptItem() and w:getScriptItem():getFullName()

            -- (1) originalName via the real createDefaultData path
            local d = WD.getOrCreateModData(w)
            local on = d and d.originalName
            -- bad = empty, equals raw fulltype, or "Module.Type"-shaped
            local bad = (not on) or on == "" or on == full
                or (full and on == full)
                or (on:find("%.") and on:match("^[%w_]+%.[%w_]+$"))
            -- helper directly too
            local cn = WD.cleanWeaponName and WD.cleanWeaponName(w)
            if bad or (cn and (cn == full or cn:match("^[%w_]+%.[%w_]+$"))) then
                g.badName = g.badName + 1
                note(ft.." originalName='"..tostring(on).."' clean='"..tostring(cn).."' full='"..tostring(full).."'")
            end

            -- (2) feed a BARE/garbage MagazineTypeNow, ensure VPS does NOT
            -- push it onto the weapon (would NPE vanilla tooltip)
            local before = w.getMagazineType and w:getMagazineType()
            local sv = V.Compat.DynamicMagazines
            V.Compat.DynamicMagazines = true
            w:getModData().MagazineTypeNow = "45Magazine30_THOMPSON_BARE_NOPE"
            pcall(V.preserveDynamicMagazineType, w)
            local after = w.getMagazineType and w:getMagazineType()
            V.Compat.DynamicMagazines = sv
            if after == "45Magazine30_THOMPSON_BARE_NOPE" then
                -- pushed an unresolvable type → vanilla CreateItem would NPE
                g.npePushed = g.npePushed + 1
                note(ft.." preserveDynamicMagazineType pushed unresolvable '"..tostring(after).."' (was '"..tostring(before).."')")
            end
        end
    end
end

local o = { "== NAME + MAGTYPE ARSENAL VALIDATION ==" }
for m, g in pairs(R) do
    o[#o+1] = string.format("[%s] firearms=%d | raw-fulltype-name=%d | unresolvable-magType-pushed=%d",
        m, g.n, g.badName, g.npePushed)
end
o[#o+1] = "-- failures (cap 24) --"
for _, f in ipairs(fails) do o[#o+1] = "  "..f end
if #fails == 0 then o[#o+1] = "  NONE — names clean, no NPE-vector magType pushed" end
return table.concat(o, "\n")
