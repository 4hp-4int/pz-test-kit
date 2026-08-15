-- Browser harness: the handful of PZ globals that UIMock + pal_ui + the scene
-- need, plus Lua 5.1 -> 5.3 compat shims (Fengari is 5.3; PZ/Kahlua is 5.1).
-- Loaded before UIMock. UIMock then layers on the ISUI globals + getCore etc.

-- ── 5.1 / 5.3 compat ────────────────────────────────────────────────────────
if not math.pow then math.pow = function(a, b) return a ^ b end end
if not unpack then unpack = table.unpack end
if not table.wipe then table.wipe = function(t) for k in pairs(t) do t[k] = nil end end end

-- Fengari's table.sort mis-orders with some valid comparators (it diverges
-- from Kahlua on pal_ui's ranking sort). Replace it with a correct, stable
-- insertion sort so the browser order matches the game exactly. Lists here are
-- small (tens of rows), so the O(n^2) cost is irrelevant.
do
    local function default_lt(a, b) return a < b end
    table.sort = function(t, cmp)
        cmp = cmp or default_lt
        for i = 2, #t do
            local v, j = t[i], i - 1
            while j >= 1 and cmp(v, t[j]) do
                t[j + 1] = t[j]; j = j - 1
            end
            t[j + 1] = v
        end
    end
end

-- ── clock ────────────────────────────────────────────────────────────────────
-- Report 0, exactly like the Kahlua test harness: pal_ui reads a zero clock as
-- "headless, snap everything" (row glide, cascades), which is what an
-- event-driven embed needs — it only redraws on input, so a mid-tween frame
-- would freeze half-slid. Enter/progress animations are settled separately by
-- T.motionEnabled = false in the boot.
function getTimestampMs() return 0 end

-- ── text: no localization in the browser, just echo the key ──────────────────
function getText(key) return tostring(key or "") end

-- ── execution context ───────────────────────────────────────────────────────
function isClient() return true end
function isServer() return false end
function isCoopHost() return false end

-- ── sandbox vars ─────────────────────────────────────────────────────────────
SandboxVars = SandboxVars or {}

-- ── events (Add/Remove + triggerEvent dispatch) ──────────────────────────────
Events = {}
setmetatable(Events, { __index = function(self, k)
    local evt = { _l = {} }
    evt.Add = function(fn) table.insert(evt._l, fn) end
    evt.Remove = function(fn)
        for i = #evt._l, 1, -1 do if evt._l[i] == fn then table.remove(evt._l, i) end end
    end
    rawset(self, k, evt)
    return evt
end })
function triggerEvent(name, ...)
    local e = rawget(Events, name)
    if e and e._l then for _, fn in ipairs(e._l) do pcall(fn, ...) end end
end

-- ── misc ─────────────────────────────────────────────────────────────────────
function instanceof(o, c) return type(o) == "table" and o._type == c end
function getDebug() return false end
