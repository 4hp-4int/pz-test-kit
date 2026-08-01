-- Live-trace KillAttribution decision points to find where onZombieDead
-- bails for the dropped kills. Wraps the module-table fns (call-through,
-- behavior-preserving) and records a per-call ring buffer.
--
-- Usage:
--   eval -f probe-vps-katrace.lua            -> installs (or prints trace)
--   eval 'return _KATRACE_RESET()'           -> clears the ring buffer
--   (kill zombies, then re-eval the file to dump the trace)

local KA = VorpallySauced and VorpallySauced.KillAttribution
if not KA then return "no KillAttribution module" end

_KATRACE = _KATRACE or { log = {}, n = 0 }

function _KATRACE_RESET()
    _KATRACE.log = {}
    _KATRACE.n = 0
    return "trace cleared"
end

local function rec(s)
    _KATRACE.n = _KATRACE.n + 1
    _KATRACE.log[#_KATRACE.log + 1] = _KATRACE.n .. ":" .. s
    if #_KATRACE.log > 60 then table.remove(_KATRACE.log, 1) end
end

if not _KATRACE.installed then
    local o_read   = KA.read
    local o_mark   = KA.markCredited
    local o_killer = KA.resolveKiller
    local o_weapon = KA.resolveCreditWeapon

    KA.read = function(z, now)
        local b = o_read(z, now)
        local zid = z and z.getID and tostring(z:getID()) or "?"
        rec("read z" .. zid .. " -> " .. (b and ("bind wid=" .. tostring(b.wid)
            .. " cred=" .. tostring(b.credited) .. " fire=" .. tostring(b.fire)) or "NIL"))
        return b
    end

    KA.markCredited = function(z)
        local r = o_mark(z)
        local zid = z and z.getID and tostring(z:getID()) or "?"
        rec("markCredited z" .. zid .. " -> " .. tostring(r) .. (r and "" or "  <== BAIL (already credited)"))
        return r
    end

    KA.resolveKiller = function(entry, bind)
        local k = o_killer(entry, bind)
        rec("resolveKiller entry=" .. tostring(entry ~= nil) .. " bind=" .. tostring(bind ~= nil)
            .. " -> " .. (k and (k.getUsername and (k:getUsername() or "?") or "obj")
            or "NIL  <== BAIL (no killer)")
            .. (k and k:isDead() and "  <== BAIL (killer dead)" or ""))
        return k
    end

    KA.resolveCreditWeapon = function(killer, wid)
        local w = o_weapon(killer, wid)
        local cur = killer and killer.getPrimaryHandItem and killer:getPrimaryHandItem()
        rec("resolveCreditWeapon wid=" .. tostring(wid)
            .. " primary=" .. (cur and tostring(cur:getID()) or "nil")
            .. " -> " .. (w and ("FOUND " .. w:getDisplayName()) or "NIL  <== BAIL (weapon gone)"))
        return w
    end

    _KATRACE.installed = true
    return "katrace installed; reset with: eval 'return _KATRACE_RESET()'"
end

if #_KATRACE.log == 0 then return "trace empty (kill zombies, then re-run)" end
return "TRACE (" .. #_KATRACE.log .. " entries):\n" .. table.concat(_KATRACE.log, "\n")
