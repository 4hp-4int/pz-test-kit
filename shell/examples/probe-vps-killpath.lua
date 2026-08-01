-- VPS MP kill-path probe. Counts the three server-side events VPS kill
-- attribution depends on, and captures last-hit / last-death detail.
-- Install once, have a connected client swing at + kill a zombie, then
-- re-eval this file to read the accumulated counters.

_VPSPROBE = _VPSPROBE or { hit = 0, whc = 0, dead = 0 }

if not _VPSPROBE.installed then
    local KA = VorpallySauced and VorpallySauced.KillAttribution

    Events.OnHitZombie.Add(function(z, w, bp, wp)
        _VPSPROBE.hit = _VPSPROBE.hit + 1
        _VPSPROBE.lastHit = {
            zid     = z and tostring(z:getID()) or "nil",
            isZ     = z and instanceof(z, "IsoZombie") or false,
            wielder = w and (instanceof(w, "IsoPlayer") and (w:getUsername() or "?") or "NON-PLAYER") or "nil",
            wpn     = wp and wp:getDisplayName() or "nil",
        }
    end)

    Events.OnWeaponHitCharacter.Add(function(w, t, wp, d)
        _VPSPROBE.whc = _VPSPROBE.whc + 1
    end)

    Events.OnZombieDead.Add(function(z)
        _VPSPROBE.dead = _VPSPROBE.dead + 1
        local bind
        if KA and z then
            local ok, r = pcall(function() return KA.read(z, getTimestampMs()) end)
            bind = ok and r or ("read-err:" .. tostring(r))
        end
        _VPSPROBE.lastDead = {
            zid      = z and tostring(z:getID()) or "nil",
            hasBind  = bind ~= nil and type(bind) == "table",
            bindWid  = (type(bind) == "table" and tostring(bind.wid)) or tostring(bind),
        }
    end)

    _VPSPROBE.installed = true
    _VPSPROBE.KA_present = KA ~= nil
    return "probe installed (hit/whc/dead counters armed); KA_present=" .. tostring(KA ~= nil)
end

return string.format(
    "hit=%d whc=%d dead=%d | lastHit=%s | lastDead=%s | KA=%s",
    _VPSPROBE.hit, _VPSPROBE.whc, _VPSPROBE.dead,
    _VPSPROBE.lastHit and (_VPSPROBE.lastHit.wielder .. "/" .. _VPSPROBE.lastHit.wpn
        .. "/z" .. _VPSPROBE.lastHit.zid .. "/isZ=" .. tostring(_VPSPROBE.lastHit.isZ)) or "none",
    _VPSPROBE.lastDead and ("z" .. _VPSPROBE.lastDead.zid
        .. "/bind=" .. tostring(_VPSPROBE.lastDead.hasBind)
        .. "/wid=" .. tostring(_VPSPROBE.lastDead.bindWid)) or "none",
    tostring(_VPSPROBE.KA_present)
)
