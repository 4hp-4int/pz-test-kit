-- TOOLTIPLIB readObject TRAFFIC RECORDER — install once, then play, then run
-- probe-tooltiplib-readobject-report.lua to read it back.
--
-- WHAT IS BEING VALIDATED
-- TooltipLib 1.6.1 (68f7795) claims to cut MP readObject traffic. Baseline it
-- measured on a live dedi (4 players, ~100 min):
--     41,714 readObject commands
--     97.5% of ALL logged server command volume
--     63% arriving within 250ms of the previous one   <-- the flood signature
--     13% genuine 2s-TTL refreshes
-- Cause: HookWorldObject polls getLastPicked() every frame and every world
-- object is its own cache key (x:y:z:objectIndex), so the per-object
-- REQUEST_COOLDOWN_MS never applied to objects the cursor merely swept across
-- while the player walked. Each swept object bought an immediate round trip.
-- Fix: a brand-new object must stay picked for HOVER_DWELL_MS (200ms) before it
-- earns a request; cached objects bypass the gate; cooldown 500 -> 1500ms.
--
-- WHY MEASURE HERE. The gate is CLIENT-side (MPClient.lua). The server is
-- therefore the honest place to count its effect: whatever arrives here is
-- traffic the gate did not stop.
--
-- THE SIGNATURE TO LOOK FOR: the <250ms bucket. That is the sweep flood, and
-- it is what should have collapsed. Raw totals alone prove nothing, because
-- they scale with how long you played and how much you looked at.
--
-- PASSIVE: this only adds a listener that records. It changes no dispatch and
-- does not touch TooltipLib's own handler.
--
-- Gaps are computed PER PLAYER. With several players connected, a global
-- inter-arrival would blend independent cursors and manufacture short gaps
-- that no single player produced.

if _G.TLProbe and _G.TLProbe.installed then
    return "recorder ALREADY installed (started "
        .. tostring(math.floor((getTimestampMs() - _G.TLProbe.startedAt) / 1000))
        .. "s ago, " .. tostring(_G.TLProbe.total or 0) .. " commands seen). "
        .. "Run the report probe, or restart the server to reset."
end

_G.TLProbe = {
    installed  = true,
    startedAt  = getTimestampMs(),
    total      = 0,
    counts     = {},   -- "module.command" -> count
    gaps       = {},   -- per-player readObject inter-arrival, pooled, ms
    lastByUser = {},   -- username -> last readObject timestamp
    users      = {},   -- username -> readObject count
}
local P = _G.TLProbe

Events.OnClientCommand.Add(function(module, command, player, args)
    local t = getTimestampMs()
    P.total = P.total + 1

    local key = tostring(module) .. "." .. tostring(command)
    P.counts[key] = (P.counts[key] or 0) + 1

    if module == "TooltipLib" and command == "readObject" then
        local who = "?"
        if player and player.getUsername then
            local ok, name = pcall(function() return player:getUsername() end)
            if ok and name then who = tostring(name) end
        end
        P.users[who] = (P.users[who] or 0) + 1
        local prev = P.lastByUser[who]
        if prev then P.gaps[#P.gaps + 1] = t - prev end
        P.lastByUser[who] = t
    end
end)

return "readObject recorder INSTALLED. Now play for a while — and specifically "
    .. "WALK AROUND with the cursor sweeping across world objects (crates, "
    .. "furniture, cars), which is the exact behaviour that produced the "
    .. "41,714-command baseline. Then run "
    .. "probe-tooltiplib-readobject-report.lua."
