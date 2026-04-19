local tests = {}

tests["probe_newindex_existing_key"] = function()
    local t = { x = 10 }
    setmetatable(t, { __newindex = function(_, k, v) error("blocked " .. tostring(k)) end })
    local ok, err = pcall(function() t.x = 20 end)
    print("[probe] existing-key write ok =", ok, "t.x =", t.x, "err =", err)
    return ok
end

tests["probe_newindex_new_key"] = function()
    local t = { x = 10 }
    setmetatable(t, { __newindex = function(_, k, v) error("blocked " .. tostring(k)) end })
    local ok, err = pcall(function() t.y = 30 end)
    print("[probe] new-key write ok =", ok, "err =", err)
    return not ok
end

return tests
