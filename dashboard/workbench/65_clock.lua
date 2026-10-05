--[[
    The world clock: advance the engine's real GameTime and fire the timed
    events on their real boundaries.

    Tools:  clockStatus{}
            clockAdvance{minutes, events, refs}

    World age is GameTime.getWorldAgeHours(): nightsSurvived * 24 plus the
    time of day past 07:00 (a night is "survived" at 7am; GameTime.java:1189).
    Setting those two reproduces any world age exactly.

    Events: EveryOneMinute each game minute (only for advances up to a day:
    past that it is thousands of dispatches for little), EveryTenMinutes,
    EveryHours on the hour and EveryDays at the 7am rollover, through the
    kit's Events (every Lua listener a mod or vanilla file registered).
    Listener errors are collected, not swallowed.

    Items: whatever refs are passed are aged by the engine's own code after
    the advance (Food.updateAge: lastAged vs world age, the same arithmetic
    the game runs when a container updates), so rot, staleness and
    cooking-state timers move for real. Corpses age via PZEngine.updateBodies.
]]

local try = WB.try
local C = WB.clock or {}
WB.clock = C

local function gt()
    local g = PZEngine and PZEngine.gameTime and PZEngine.gameTime()
    if not g then error("no engine GameTime (engine unavailable in this mod context)") end
    return g
end

function C.age() return gt():getWorldAgeHours() end

function C.setAge(h)
    local g = gt()
    local nights = math.floor(h / 24)
    local tod = h - nights * 24 + 7
    if tod >= 24 then tod = tod - 24 end
    g:setNightsSurvived(nights)
    g:setTimeOfDay(tod)
end

local function status()
    local g = gt()
    local h = C.age()
    local tod = g:getTimeOfDay()
    return { hours = h, day = math.floor(h / 24) + 1, nights = g:getNightsSurvived(),
             clock = string.format("%02d:%02d", math.floor(tod), math.floor((tod % 1) * 60 + 0.5) % 60) }
end
C.status = status

local function fire(name, errors, counts)
    counts[name] = (counts[name] or 0) + 1
    local evt = Events and rawget(Events, name)
    if not (evt and evt._listeners) then return end
    local snapshot = {}
    for i, fn in ipairs(evt._listeners) do snapshot[i] = fn end
    for _, fn in ipairs(snapshot) do
        local ok, err = pcall(fn)
        if not ok and #errors < 8 then errors[#errors + 1] = name .. ": " .. tostring(err) end
    end
end

local function listeners(name)
    local evt = Events and rawget(Events, name)
    return evt and evt._listeners and #evt._listeners or 0
end

WB.register("clockStatus", function()
    local st = status()
    st.listeners = { EveryOneMinute = listeners("EveryOneMinute"), EveryTenMinutes = listeners("EveryTenMinutes"),
                     EveryHours = listeners("EveryHours"), EveryDays = listeners("EveryDays") }
    return st
end)

WB.register("clockAdvance", function(a)
    local total = math.max(0, math.min(math.floor(tonumber(a.minutes) or 60), 60 * 24 * 60))
    local events = a.events ~= false
    local perMinute = events and total <= 24 * 60
    local h0 = C.age()
    local m0 = math.floor(h0 * 60 + 0.5)
    local counts, errors = {}, {}
    for m = 1, total do
        C.setAge(h0 + m / 60)
        if events then
            local abs = m0 + m
            if perMinute then fire("EveryOneMinute", errors, counts) end
            if abs % 10 == 0 then fire("EveryTenMinutes", errors, counts) end
            if abs % 60 == 0 then fire("EveryHours", errors, counts) end
            if abs % 1440 == 0 then fire("EveryDays", errors, counts) end
        end
    end
    -- Items age by the engine's own code against the new world age.
    local aged, itemErrors = 0, {}
    for _, ref in ipairs(a.refs or {}) do
        local it = WB.deref(ref)
        if it then
            local ok, err = pcall(function()
                if instanceof(it, "Food") then it:updateAge() end
            end)
            if ok then aged = aged + 1 elseif #itemErrors < 5 then itemErrors[#itemErrors + 1] = tostring(err) end
        end
    end
    local bodies
    if a.bodies ~= false and PZEngine.updateBodies then bodies = PZEngine.updateBodies() end
    local st = status()
    st.advanced = total
    st.fired = counts
    st.errors = errors
    st.aged = aged
    st.itemErrors = itemErrors
    st.bodiesError = bodies
    return st
end)
