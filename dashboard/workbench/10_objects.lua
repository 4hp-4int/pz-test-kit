--[[
    Object explorer: look inside any value a tool or the console returned.

    inspect{ref}                 class, Lua-exposed methods, list elements, table entries
    invoke{ref, method, args}    call obj:method(args...) - args are literals or {"$ref": N}
    getters{ref, methods}        call many zero-arg methods at once (snapshot)

    Values that aren't scalars come back as refs, so every result is itself
    explorable: the browser drills by ref number.
]]

local function summarize(v)
    local t = type(v)
    if v == nil then return { ["$nil"] = true } end
    if t == "number" or t == "boolean" or t == "string" then return v end
    if t == "function" then return { ["$fn"] = true } end
    if t == "table" then
        local n = 0
        for _ in pairs(v) do n = n + 1 end
        return { ["$table"] = true, ref = WB.ref(v), count = n }
    end
    return WB.describe(v)
end
WB.summarize = summarize

local function resolveArg(a)
    if type(a) == "table" and a["$ref"] then return WB.deref(a["$ref"]) end
    if type(a) == "table" and a["$nil"] then return nil end
    return a
end

WB.register("inspect", function(a)
    local v = WB.deref(a.ref)
    if v == nil then error("ref " .. tostring(a.ref) .. " is gone (VM restarted?)") end
    local t = type(v)
    if t == "table" then
        local entries, n = {}, 0
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
        for _, k in ipairs(keys) do
            n = n + 1
            if n <= 500 then entries[#entries + 1] = { key = tostring(k), value = summarize(v[k]) } end
        end
        return { kind = "table", ref = a.ref, count = n, entries = entries, str = tostring(v) }
    end
    if not WB.isJava(v) then return { kind = t, value = summarize(v) } end
    local methods = WB.methodsOf(v)
    local out = { kind = "java", ref = a.ref, class = WB.className(v), str = tostring(v), methods = methods }
    -- List-like (exposed ArrayList & co): show elements.
    local okn, n = pcall(function() return v:size() end)
    if okn and type(n) == "number" then
        out.size = n
        local okg = pcall(function() return v:get(0) end)
        if okg or n == 0 then
            out.elements = {}
            for i = 0, math.min(n, 200) - 1 do out.elements[#out.elements + 1] = summarize(v:get(i)) end
        end
    end
    return out
end)

WB.register("invoke", function(a)
    local v = WB.deref(a.ref)
    if v == nil then error("ref " .. tostring(a.ref) .. " is gone") end
    local m = tostring(a.method)
    local f = v[m]
    if type(f) ~= "function" then error(m .. " is not a method on this object") end
    local args = {}
    for i, x in ipairs(a.args or {}) do args[i] = resolveArg(x) end
    local n = #(a.args or {})
    local t0 = _pz_now_ms and _pz_now_ms() or nil
    local res = { pcall(f, v, unpack(args, 1, n)) }
    local ms = t0 and (_pz_now_ms() - t0) or nil
    if not res[1] then return { ok = false, error = tostring(res[2]), ms = ms } end
    return { ok = true, value = summarize(res[2]), ms = ms }
end)

-- Snapshot: call each named zero-arg method, collect scalars + refs.
WB.register("getters", function(a)
    local v = WB.deref(a.ref)
    if v == nil then error("ref " .. tostring(a.ref) .. " is gone") end
    local out, failed = {}, {}
    for _, m in ipairs(a.methods or {}) do
        local f = v[m]
        if type(f) == "function" then
            local ok, r = pcall(f, v)
            if ok then out[m] = summarize(r) else failed[m] = tostring(r):sub(1, 160) end
        end
    end
    return { values = out, failed = failed }
end)

-- Give a console/global expression a ref (used by deep links like #obj=expr).
WB.register("refOf", function(a)
    local compile = _pz_compile or loadstring
    local chunk, err = compile("return " .. tostring(a.expr), "refOf")
    if not chunk then error(err) end
    local ok, v = pcall(chunk)
    if not ok then error(v) end
    return summarize(v)
end)
