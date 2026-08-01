-- Trace the post-resolveCreditWeapon path in onZombieDead: which WeaponData
-- endpoint is reached, and how the resolved server weapon classifies.
-- Wraps module-table fns (call-through, behavior-preserving).
--
--   eval -f probe-vps-wdtrace.lua      -> install / dump
--   eval 'return _WDT_RESET()'         -> clear buffer

local WD = VorpallySauced and VorpallySauced.WeaponData
if not WD then return "no WeaponData module" end

_WDT = _WDT or { log = {}, n = 0 }
function _WDT_RESET() _WDT.log = {}; _WDT.n = 0; return "wdt cleared" end

local function rec(s)
    _WDT.n = _WDT.n + 1
    _WDT.log[#_WDT.log + 1] = _WDT.n .. ":" .. s
    if #_WDT.log > 80 then table.remove(_WDT.log, 1) end
end

local function wdesc(w)
    if not w then return "nil" end
    local ok, ft = pcall(function() return w:getFullType() end)
    local okR, rng = pcall(function() return w:isRanged() end)
    local okW, isw = pcall(function() return w:IsWeapon() end)
    return (ok and tostring(ft) or "?") ..
        " ranged=" .. (okR and tostring(rng) or "?") ..
        " IsWeapon=" .. (okW and tostring(isw) or "?") ..
        " id=" .. tostring(w.getID and w:getID() or "?")
end

if not _WDT.installed then
    local o_vw   = WD.isValidWeapon
    local o_vf   = WD.isValidFirearm
    local o_goc  = WD.getOrCreateModData
    local o_inc  = WD.incrementKills

    WD.isValidWeapon = function(w)
        local r = o_vw(w)
        rec("isValidWeapon(" .. wdesc(w) .. ") -> " .. tostring(r) ..
            (r and "" or "  <== if not firearm too, BAIL @357"))
        return r
    end
    WD.isValidFirearm = function(w)
        local r = o_vf(w)
        rec("isValidFirearm(" .. tostring(w and w.getID and w:getID() or "?") .. ") -> " .. tostring(r))
        return r
    end
    WD.getOrCreateModData = function(w)
        local d = o_goc(w)
        rec("getOrCreateModData(id=" .. tostring(w and w.getID and w:getID() or "?")
            .. ") -> kills=" .. tostring(d and d.kills) .. " (path REACHED past validation)")
        return d
    end
    WD.incrementKills = function(w)
        local nk = o_inc(w)
        rec("incrementKills(id=" .. tostring(w and w.getID and w:getID() or "?")
            .. ") -> " .. tostring(nk) .. "  <== KILL CREDITED")
        return nk
    end

    _WDT.installed = true
    return "wdtrace installed; reset with: eval 'return _WDT_RESET()'"
end

if #_WDT.log == 0 then return "wdt empty (kill zombies, then re-run)" end
return "WDTRACE (" .. #_WDT.log .. "):\n" .. table.concat(_WDT.log, "\n")
