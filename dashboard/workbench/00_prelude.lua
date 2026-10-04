--[[
    Engine Workbench prelude - loaded first into the resident bridge VM.

    WB.register(name, fn)   a tool: fn(args) -> any Lua value (encoded to JSON)
    WB.call(name, args)     dispatcher the server invokes; always returns JSON
    WB.json(v)              JSON encoder (Java objects become ref descriptors)
    WB.ref(obj) / WB.deref  handle table so the browser can point back at Java
                            objects it was shown (object explorer drill-down)
]]

WB = WB or {}
WB.tools = WB.tools or {}
WB.refs = WB.refs or {}
WB.refIds = WB.refIds or {}     -- obj -> id (Java objects are valid table keys)
WB.nextRef = WB.nextRef or 0

function WB.register(name, fn) WB.tools[name] = fn end

-- ── refs ──────────────────────────────────────────────────────────────────
function WB.ref(obj)
    local id = WB.refIds[obj]
    if id then return id end
    WB.nextRef = WB.nextRef + 1
    id = WB.nextRef
    WB.refs[id] = obj
    WB.refIds[obj] = id
    return id
end
function WB.deref(id) return WB.refs[tonumber(id)] end
function WB.clearRefs() WB.refs, WB.refIds = {}, {} end

-- ── Java introspection helpers ────────────────────────────────────────────
-- Kahlua keeps per-class metatables; a Java value's methods are the keys of
-- its metatable's __index (inherited ones come via the superclass chain the
-- exposer wires). Everything here degrades to "opaque" for classes the
-- engine never exposed.
function WB.isJava(v)
    local t = type(v)
    return t == "userdata" or (t ~= "nil" and t ~= "boolean" and t ~= "number" and t ~= "string"
        and t ~= "table" and t ~= "function")
end

function WB.methodsOf(v)
    local names, seen = {}, {}
    local mt = getmetatable(v)
    local depth = 0
    while type(mt) == "table" and depth < 20 do
        local idx = rawget(mt, "__index")
        if type(idx) == "table" then
            for k in pairs(idx) do
                if type(k) == "string" and not seen[k] then seen[k] = true; names[#names + 1] = k end
            end
            mt = getmetatable(idx)
        else
            break
        end
        depth = depth + 1
    end
    table.sort(names)
    return names
end

function WB.className(v)
    if not WB.isJava(v) then return type(v) end
    local ok, c = pcall(function() return v:getClass() end)
    if ok and c then
        local ok2, n = pcall(function() return c:getName() end)
        if ok2 and n then return tostring(n) end
    end
    -- No getClass in engine mode (Object isn't exposed), so read toString:
    -- "pkg.Class@hash", items' "Base.Axe:pkg.Class@hash", "IsoPlayer{...}".
    local s = tostring(v)
    local cls = s:match("([%a_][%w_%.%$]*)@%x+$")
    if cls and cls:find("%.") then return cls end
    cls = s:match("^(%u[%w_]*)%s*[{%[(]")
    return cls or "java object"
end

-- ── JSON ──────────────────────────────────────────────────────────────────
-- Escape only ASCII control bytes: Kahlua strings are Java strings, and its
-- %c class also matches non-ASCII chars (an em dash came out as \u0014).
local function esc(s)
    return (s:gsub('[%z\1-\31"\\]', function(c)
        if c == '"' then return '\\"' elseif c == "\\" then return "\\\\"
        elseif c == "\n" then return "\\n" elseif c == "\r" then return "\\r" elseif c == "\t" then return "\\t"
        else return string.format("\\u%04x", c:byte()) end
    end))
end

local function isArray(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
        n = n + 1
    end
    for i = 1, n do if t[i] == nil then return false end end
    return n > 0
end

-- Java values: a descriptor the browser renders as a clickable object.
function WB.describe(v)
    local s = tostring(v)
    if #s > 200 then s = s:sub(1, 200) .. "..." end
    return { ["$java"] = true, ref = WB.ref(v), class = WB.className(v), str = s }
end

local encode
encode = function(v, depth, seen)
    local t = type(v)
    if v == nil then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return '"' .. tostring(v) .. '"' end
        if v % 1 == 0 and v > -1e15 and v < 1e15 then return string.format("%d", v) end
        return string.format("%.10g", v)
    end
    if t == "string" then return '"' .. esc(v) .. '"' end
    if t == "function" then return '{"$fn":true}' end
    if t == "table" then
        if depth > 12 then return '"<table: too deep>"' end
        if seen[v] then return '"<cycle>"' end
        seen[v] = true
        local parts = {}
        if isArray(v) then
            for i = 1, #v do parts[i] = encode(v[i], depth + 1, seen) end
            seen[v] = nil
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            parts[#parts + 1] = '"' .. esc(tostring(k)) .. '":' .. encode(v[k], depth + 1, seen)
        end
        seen[v] = nil
        if #parts == 0 then return "{}" end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return encode(WB.describe(v), depth, seen)
end
function WB.json(v) return encode(v, 0, {}) end

-- ── dispatcher ────────────────────────────────────────────────────────────
function WB.call(name, args)
    local fn = WB.tools[name]
    if not fn then return WB.json({ error = "no such tool: " .. tostring(name) }) end
    local ok, res, trace = pcall(fn, args or {})
    if not ok then
        local msg = tostring(res)
        if trace ~= nil then msg = msg .. "\n" .. tostring(trace) end
        return WB.json({ error = msg })
    end
    return WB.json(res)
end

-- ── tiny helpers shared by tools ──────────────────────────────────────────
-- java List -> lua array (nil-safe). Collections whose class the engine never
-- exposed (unmodifiable views, HashSets...) have no callable size/get; for
-- those the only window is toString's "[a, b, c]", so elements come back as
-- STRINGS (WB.listIsText is set so callers can tell).
function WB.list(jlist)
    local out = {}
    WB.listIsText = false
    if jlist == nil then return out end
    local ok, n = pcall(function() return jlist:size() end)
    if ok and type(n) == "number" then
        for i = 0, n - 1 do out[#out + 1] = jlist:get(i) end
        return out
    end
    WB.listIsText = true
    local str = tostring(jlist)
    local body = str:match("^%[(.*)%]$")
    if body and body ~= "" then
        for part in (body .. ", "):gmatch("(.-), ") do out[#out + 1] = part end
    end
    return out
end

function WB.try(fn, ...)          -- value or nil, never throws
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

WB.register("ping", function()
    return { ok = true, engine = PZEngine and PZEngine.available() or false }
end)

-- How many items an input amount takes: the engine counts USES, so
-- "item 32 [CeramicCrucible_Iron]" is 2 crucibles of 20 uses, while
-- "item 10 tags[base:charcoal]" is 10 lumps (1 use each).
function WB.itemsForAmount(fullType, amount)
    amount = tonumber(amount) or 1
    local per = 1
    if fullType and PZEngine and PZEngine.instanceItem then
        local ok, it = pcall(PZEngine.instanceItem, fullType)
        local u = ok and it and WB.try(function() return it:getCurrentUses() end)
        if type(u) == "number" and u > 1 then per = u end
    end
    return math.max(1, math.ceil(amount / per)), per
end

function WB.info()
    local tools = {}
    for k in pairs(WB.tools) do tools[#tools + 1] = k end
    table.sort(tools)
    return {
        engine = PZEngine ~= nil and PZEngine.available() or false,
        bootError = PZEngine and PZEngine.bootError and PZEngine.bootError() or nil,
        gameVersion = PZTestKit and PZTestKit.gameVersion or nil,
        tools = tools,
    }
end
