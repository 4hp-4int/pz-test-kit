--[[
    Lua console: eval free-form source against the resident env.
    Tries `return <src>` first so bare expressions print their value.
    `_` is the last result; `$N` in the source becomes WB.deref(N) so any
    object shown in the explorer can be used by number.
]]

local compile = _pz_compile or loadstring

WB.register("eval", function(args)
    local src = tostring(args.src or "")
    src = src:gsub("%$(%d+)", "WB.deref(%1)")
    local chunk = compile("return " .. src, "console")
    if not chunk then
        local err
        chunk, err = compile(src, "console")
        if not chunk then return { error = tostring(err) } end
    end
    local function pack(...) return { n = select("#", ...), ... } end
    local res = pack(pcall(chunk))
    if not res[1] then
        local msg = tostring(res[2])
        if res[3] ~= nil then msg = msg .. "\n" .. tostring(res[3]) end
        return { error = msg }
    end
    local out, n = {}, 0
    for i = 2, res.n do n = i - 1; out[n] = res[i] end
    _ = out[1]
    -- Encode nils explicitly so `return nil, 2` keeps its shape.
    local vals = {}
    for i = 1, n do vals[i] = out[i] == nil and { ["$nil"] = true } or out[i] end
    return { values = vals, count = n }
end)
