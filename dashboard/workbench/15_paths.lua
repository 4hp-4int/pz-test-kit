--[[
    Reproducible object paths for deep links.

    A ref number only lives as long as the VM; a PATH survives restarts:
        resolvePath{expr, steps}   steps = { "getScriptItem", "#3", ".kills" }
          "name"  call zero-arg method      "#i"  list:get(i)      ".k"  table field
    Returns the summarized value (with a fresh ref) or the step that failed.
]]

local compile = _pz_compile or loadstring

WB.register("resolvePath", function(a)
    local v
    if a.ref then
        v = WB.deref(a.ref)
        if v == nil then error("ref " .. tostring(a.ref) .. " is gone (VM restarted) - re-run the source") end
    else
        local chunk, err = compile("return " .. tostring(a.expr), "path")
        if not chunk then error(err) end
        local ok, r = pcall(chunk)
        if not ok then error(r) end
        v = r
    end
    for i, step in ipairs(a.steps or {}) do
        local ok, r = pcall(function()
            local c = step:sub(1, 1)
            if c == "#" then return v:get(tonumber(step:sub(2))) end
            if c == "." then
                local k = step:sub(2)
                local n = tonumber(k)
                if v[k] == nil and n then return v[n] end
                return v[k]
            end
            local f = v[step]
            if type(f) ~= "function" then error(step .. " is not a method") end
            return f(v)
        end)
        if not ok then return { failedAt = i, step = step, error = tostring(r) } end
        v = r
        if v == nil then return { value = { ["$nil"] = true }, nilAt = i } end
    end
    return { value = WB.summarize(v) }
end)
