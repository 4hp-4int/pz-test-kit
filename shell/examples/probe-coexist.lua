-- COEXISTENCE TEST: instead of ceding, can VPS's appliedClipBonus machinery
-- stack its capacity affix ON TOP of mod-managed capacity through the
-- realistic mod<->VPS interleaving? Cede is bypassed (Compat off + flag clear)
-- so the additive clipSize path actually runs.
--
-- Lifecycle per magazine weapon (scriptBase S, drum = S+25, affix = +A):
--   A mod sets drum            -> setMaxAmmo(S+25)
--   B VPS applies affix        -> reapply ; want S+25+A
--   C B42 field reset          -> setMaxAmmo(S)
--   D VPS reapply (fire window)-> reapply ; BUG if not S+25+A (orig power00456)
--   E mod re-applies drum,then -> setMaxAmmo(S+25); reapply ; want S+25+A
local V, WD, SM = VorpallySauced, VorpallySauced.WeaponData, VorpallySauced.StatModifiers
local clipSfx, A
for i, s in ipairs(V.FirearmSuffixes) do
    if s.stat == "clipSize" then clipSfx, A = i, (s.value or 0) break end
end

local items = getScriptManager():getAllItems()
local R = {}
local function row(m) R[m] = R[m] or { mag=0, B=0, D=0, E=0 }; return R[m] end
local fails = {}
local function note(s) if #fails < 16 then fails[#fails+1] = s end end

local sv, dv = V.Compat.SWMG, V.Compat.DynamicMagazines

for i = 0, items:size() - 1 do
    local sc = items:get(i)
    local mod = sc:getModuleName()
    if mod == "Base" or mod == "MarzGuns" then
        local ft = mod .. "." .. sc:getName()
        local ok, w = pcall(instanceItem, ft)
        if ok and w and w.isRanged and w:isRanged() and WD.isValidFirearm(w)
           and w.getMagazineType and (w:getMagazineType() or "") ~= "" then
            local g = row(mod); g.mag = g.mag + 1
            local S = w:getMaxAmmo() or 0
            local drum, want = S + 25, S + 25 + A
            local d = WD.getOrCreateModData(w); d.isFirearm = true
            d.suffixId = clipSfx; d.dynamicCapacity = nil
            WD.rt(d.weaponId).appliedClipBonus = 0
            V.Compat.SWMG, V.Compat.DynamicMagazines = false, false  -- run additive path

            w:setMaxAmmo(drum)                 -- A: mod sets drum
            SM.reapplyUpgrades(w)              -- B: VPS applies affix
            local capB = w:getMaxAmmo()
            if capB == want then g.B = g.B + 1
            elseif #fails < 16 then note(ft.." B want "..want.." got "..tostring(capB)) end

            w:setMaxAmmo(S)                    -- C: B42 field reset
            SM.reapplyUpgrades(w)              -- D: VPS reapply in the reset window
            local capD = w:getMaxAmmo()
            if capD == want then g.D = g.D + 1 end

            w:setMaxAmmo(drum)                 -- E: mod re-applies drum, then VPS
            SM.reapplyUpgrades(w)
            local capE = w:getMaxAmmo()
            if capE == want then g.E = g.E + 1
            elseif #fails < 16 then note(ft.." E want "..want.." got "..tostring(capE).." (B="..tostring(capB).." D="..tostring(capD)..")") end

            V.Compat.SWMG, V.Compat.DynamicMagazines = sv, dv
        end
    end
end

local o = { string.format("== COEXISTENCE (additive on mod capacity) == affix +%s", tostring(A)) }
for m, g in pairs(R) do
    o[#o+1] = string.format("[%s] mag=%d | B apply-on-drum=%d/%d | D survive-fieldreset=%d/%d | E mod-reapplies-then-VPS=%d/%d",
        m, g.mag, g.B, g.mag, g.D, g.mag, g.E, g.mag)
end
o[#o+1] = "-- sample failures --"
for _, f in ipairs(fails) do o[#o+1] = "  "..f end
if #fails == 0 then o[#o+1] = "  none" end
return table.concat(o, "\n")
