-- COMPLETENESS / before-after: run the SAME arsenal checks but against the
-- PRE-FIX code paths, replicated inline (the real fix is entangled with the
-- coexistence work in the same files, so simulate the old logic in-VM):
--   OLD originalName  = script:getDisplayName() (raw) else weapon name
--   OLD preserveDynamicMagazineType = setMagazineType(value) UNCONDITIONALLY
-- Expect NON-zero counts here (proves the probe detects the bug; the fixed
-- run showed 0/0).
local V, WD = VorpallySauced, VorpallySauced.WeaponData
local items = getScriptManager():getAllItems()
local R = {}
local function row(m) R[m]=R[m] or {n=0, badName=0, npePushed=0}; return R[m] end
local fails = {}
local function note(s) if #fails < 16 then fails[#fails+1]=s end end

for i = 0, items:size() - 1 do
    local sc = items:get(i)
    local mod = sc:getModuleName()
    if mod == "Base" or mod == "MarzGuns" then
        local ft = mod .. "." .. sc:getName()
        local ok, w = pcall(instanceItem, ft)
        if ok and w and w.isRanged and w:isRanged() and WD.isValidFirearm(w) then
            local g = row(mod); g.n = g.n + 1
            local s = w:getScriptItem()
            local full = s and s:getFullName()

            -- OLD originalName capture (pre-fix createDefaultData)
            local dn = s and s:getDisplayName()
            local oldName = (dn and dn ~= "") and dn
                or (w.getDisplayName and w:getDisplayName())
            if (not oldName) or oldName == "" or oldName == full
               or (oldName:find("%.") and oldName:match("^[%w_]+%.[%w_]+$")) then
                g.badName = g.badName + 1
                if #fails < 16 then note(ft.." OLD originalName='"..tostring(oldName).."'") end
            end

            -- OLD preserveDynamicMagazineType (pre-fix: unconditional set)
            if w.setMagazineType and w.getMagazineType then
                local bare = "45Magazine30_THOMPSON_BARE_NOPE"
                local current = w:getMagazineType()
                if current ~= bare then
                    w:setMagazineType(bare)   -- exactly what the old code did
                end
                if w:getMagazineType() == bare then
                    g.npePushed = g.npePushed + 1   -- vanilla CreateItem(this)->null->NPE
                end
            end
        end
    end
end

local o = { "== PRE-FIX (simulated old behavior) — for before/after ==" }
for m, g in pairs(R) do
    o[#o+1] = string.format("[%s] firearms=%d | raw-fulltype-name=%d | unresolvable-magType-pushed=%d",
        m, g.n, g.badName, g.npePushed)
end
o[#o+1] = "-- sample bad names (cap 16) --"
for _, f in ipairs(fails) do o[#o+1] = "  "..f end
return table.concat(o, "\n")
