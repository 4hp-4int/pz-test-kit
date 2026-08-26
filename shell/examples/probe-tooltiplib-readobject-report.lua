-- TOOLTIPLIB readObject TRAFFIC REPORT — read back what the recorder collected.
-- Install probe-tooltiplib-readobject-record.lua first, play, then run this.
-- Safe to run repeatedly; it only reads.
--
-- THE VERDICT LINE is the <250ms share. TooltipLib 1.6.1's baseline was 63%
-- of readObject commands arriving within 250ms of that player's previous one —
-- objects the cursor swept past while walking, that nobody ever settled on.
-- The hover-dwell gate is supposed to make those never leave the client.
--
-- Also reported: readObject's share of ALL command volume (baseline 97.5%) and
-- the rate per player-minute, which is the number to compare across sessions of
-- different lengths.

local P = _G.TLProbe
if not P or not P.installed then
    return "FAIL: recorder not installed. Run "
        .. "probe-tooltiplib-readobject-record.lua first."
end

local out = {}
local function add(s) out[#out + 1] = s end

local elapsedMs  = getTimestampMs() - P.startedAt
local elapsedMin = elapsedMs / 60000

add("=== TooltipLib readObject traffic ===")
add(string.format("window: %.1f min   commands seen: %d", elapsedMin, P.total))

-- Which commands, worst first. The baseline claim is that readObject alone was
-- 97.5% of logged command volume.
local rows = {}
for key, n in pairs(P.counts) do rows[#rows + 1] = { key = key, n = n } end
table.sort(rows, function(a, b) return a.n > b.n end)
add("")
add("command volume:")
for i = 1, #rows do
    add(string.format("  %-40s %6d  (%5.1f%%)",
        rows[i].key, rows[i].n, 100 * rows[i].n / math.max(P.total, 1)))
end

local readObjects = P.counts["TooltipLib.readObject"] or 0
if readObjects == 0 then
    add("")
    add("NO readObject commands recorded at all. Either nobody hovered a world")
    add("object, EnableMPSync is off, or the client is not running TooltipLib's")
    add("MP path. That is not evidence the gate works — it is no evidence.")
    return table.concat(out, "\n")
end

-- Per player, because gaps are only meaningful within one cursor.
add("")
add("readObject per player:")
local players = 0
for who, n in pairs(P.users) do
    players = players + 1
    add(string.format("  %-24s %6d  (%.1f/min)", who, n, n / math.max(elapsedMin, 0.01)))
end

-- THE SIGNATURE. Buckets chosen to match the commit's own reporting.
local b250, b500, b1500, b2500, over = 0, 0, 0, 0, 0
for i = 1, #P.gaps do
    local g = P.gaps[i]
    if     g < 250  then b250  = b250  + 1
    elseif g < 500  then b500  = b500  + 1
    elseif g < 1500 then b1500 = b1500 + 1
    elseif g < 2500 then b2500 = b2500 + 1
    else                 over  = over  + 1 end
end
local gaps = #P.gaps
local function pct(n) return 100 * n / math.max(gaps, 1) end

add("")
add(string.format("inter-arrival, per player (%d intervals):", gaps))
add(string.format("  <250ms   %6d  (%5.1f%%)   <- SWEEP FLOOD. baseline was 63%%", b250, pct(b250)))
add(string.format("  250-500  %6d  (%5.1f%%)", b500, pct(b500)))
add(string.format("  500-1500 %6d  (%5.1f%%)   <- below the 1500ms cooldown", b1500, pct(b1500)))
add(string.format("  1500-2500%6d  (%5.1f%%)   <- around the 2s cache TTL", b2500, pct(b2500)))
add(string.format("  >2500    %6d  (%5.1f%%)", over, pct(over)))

add("")
add(string.format("readObject share of all commands: %.1f%%  (baseline 97.5%%)",
    100 * readObjects / math.max(P.total, 1)))
add(string.format("rate: %.1f readObject/player-minute",
    readObjects / math.max(elapsedMin * math.max(players, 1), 0.01)))

add("")
if pct(b250) < 20 then
    add("READS AS FIXED: the sub-250ms sweep flood is largely gone.")
elseif pct(b250) < 45 then
    add("PARTIAL: sweep traffic reduced but still present. Check the client is")
    add("actually running TooltipLib 1.6.1 — see the caveat below.")
else
    add("READS AS NOT FIXED: sweep flood still dominant. Before believing that,")
    add("verify the CLIENT's TooltipLib version.")
end
add("")
add("CAVEAT THAT INVALIDATES EVERYTHING ABOVE IF IGNORED: the gate is CLIENT")
add("side. A Steam subscription of TooltipLib v1.6.0 — the last PRE-fix")
add("version — outranks Zomboid\\mods unless the client launches with")
add("-modfolders mods,steam,workshop. Measuring a 1.6.0 client would show the")
add("old flood and look like the fix failed. Confirm the client's TL version.")

return table.concat(out, "\n")
