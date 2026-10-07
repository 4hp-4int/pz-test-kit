-- Live aggro probe: who is chasing whom, who runs each zombie, and VPS's
-- genome "lose track" window (Runtime.loseTrack), on the running dedi.
--
-- Usage (with a player connected):
--   ./pz-shell eval -f examples/probe-aggro.lua                 snapshot
--   ./pz-shell eval 'PROBE_AGGRO_FIRE = 15' ; ./pz-shell eval -f examples/probe-aggro.lua
--                                                                fire a 15 s window, then snapshot
-- Repeat the snapshot every second or two to get a timeline.
--
-- Reading it, on the SERVER:
--   owner   the client that runs the zombie's mind ("server" = nobody owns it,
--           the server simulates it). Only the owner's flags are real; the
--           server's copy of a client-run zombie takes its flags from the
--           owner's packets (NetworkZombieAI :250). So `useless` on a zombie
--           owned by a client means THAT client applied the window.
--   chasing the zombie's target is the probed player.
--   useless the engine's flag the window sets (drops target + spottedLast).

local out = {}
local function line(s) out[#out + 1] = s end

local players = getOnlinePlayers()
if not players or players:size() == 0 then return "no player online" end
local pl = players:get(0)
if PROBE_TARGET then
    for k = 0, players:size() - 1 do
        local p = players:get(k)
        if p:getUsername() == PROBE_TARGET then pl = p end
    end
end

local R = VorpallySauced and VorpallySauced.Genome and VorpallySauced.Genome.Runtime
if PROBE_AGGRO_FIRE then
    local secs = tonumber(PROBE_AGGRO_FIRE) or 15
    PROBE_AGGRO_FIRE = nil
    if R and R.loseTrack then
        local n = R.loseTrack(pl, secs, R.UNSEEN_RADIUS or 20)
        PROBE_AGGRO_FIRED_AT = getTimestampMs()
        line(string.format("FIRED: %ds window on %s (server flagged %d of its own)", secs, pl:getUsername(), n))
    else
        line("FIRED: no Runtime.loseTrack (old VPS build?)")
    end
end

local since = PROBE_AGGRO_FIRED_AT and string.format("%.1fs after fire", (getTimestampMs() - PROBE_AGGRO_FIRED_AT) / 1000) or "no fire yet"
line(string.format("player %s at %d,%d | %s | server windows open: %d",
    pl:getUsername(), math.floor(pl:getX()), math.floor(pl:getY()), since, R and R.windows and #R.windows or -1))

local list = pl:getCell():getZombieList()
local rows, chasing, useless = {}, 0, 0
for i = 0, list:size() - 1 do
    local z = list:get(i)
    local dx, dy = z:getX() - pl:getX(), z:getY() - pl:getY()
    local d = math.sqrt(dx * dx + dy * dy)
    if d <= 25 and not z:isDead() then
        local t = z:getTarget()
        local owner = "server"
        pcall(function() local op = z:getOwnerPlayer(); if op then owner = op:getUsername() end end)
        local isChasing = t == pl
        if isChasing then chasing = chasing + 1 end
        if z:isUseless() then useless = useless + 1 end
        rows[#rows + 1] = { d = d, s = string.format("  z%-6s %5.1f tiles  owner %-10s chasing %-5s useless %-5s target %s",
            tostring(z:getOnlineID()), d, owner, tostring(isChasing), tostring(z:isUseless()),
            t and (t == pl and "PLAYER" or tostring(t)) or "-") }
    end
end
table.sort(rows, function(a, b) return a.d < b.d end)
line(string.format("zombies within 25: %d | chasing the player: %d | useless: %d", #rows, chasing, useless))
for i = 1, math.min(#rows, 15) do line(rows[i].s) end
return table.concat(out, "\n")
