--[[
    UIView — Draw-call Recorder
    ===========================
    A single display list that the mock UIElement draw methods append to.
    Every primitive is recorded in SCREEN coordinates (the element's absolute
    position is added in by the draw shim) so the HTML viewer can absolute-
    position each op with zero layout math.

    Op shapes (all coords already screen-space; colors are 0..1 floats):
        { op="rect",       x,y,w,h, r,g,b,a, el }
        { op="rectborder", x,y,w,h, r,g,b,a, el }            -- 1px stroke
        { op="text",       str,x,y, r,g,b,a, font, align, el }  align: left|centre|right
        { op="texture",    name,x,y,w,h, r,g,b,a, el }        -- name = texture path/id
        { op="itemicon",   name,x,y,w,h, el }                 -- item/script icon placeholder

    `el` is the integer id of the element that emitted the op (for hit-debug
    and grouping in the viewer). `z` is a monotonic counter = paint order.
]]

local Recorder = {}

Recorder.ops = {}
Recorder._z = 0
Recorder.frame = { width = 0, height = 0, ops = Recorder.ops }

function Recorder.reset(width, height)
    Recorder.ops = {}
    Recorder._z = 0
    Recorder.frame = { width = width or 0, height = height or 0, ops = Recorder.ops }
end

function Recorder.push(entry)
    Recorder._z = Recorder._z + 1
    entry.z = Recorder._z
    Recorder.ops[#Recorder.ops + 1] = entry
    return entry
end

-- ── JSON encoder (Lua 5.1 / Kahlua-safe) ────────────────────────────────────
-- We only emit numbers, strings, booleans, arrays and string-keyed objects,
-- which is all the display list ever contains. Arrays are detected by a 1..n
-- contiguous integer key run; everything else is an object.

local function escape_str(s)
    s = tostring(s)
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    -- ANY REMAINING CONTROL BYTE, as a JSON \u escape.
    --
    -- One mangled em-dash put a raw 0x14 into a string and made the whole
    -- scene invalid JSON. The failure was silent in the worst way: the viewer
    -- resolved ZERO textures and drew a page of placeholder boxes with no
    -- error anywhere. A display list must not be able to take the preview
    -- down because one string had a bad byte in it.
    s = s:gsub('%c', function(c) return string.format('\\u%04x', c:byte()) end)
    return s
end

local function is_array(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return n > 0
end

local encode
encode = function(v)
    local tv = type(v)
    if tv == "nil" then
        return "null"
    elseif tv == "number" then
        -- integers without trailing .0 for compactness; finite guard
        if v ~= v or v == math.huge or v == -math.huge then return "0" end
        if math.floor(v) == v then return string.format("%d", v) end
        return string.format("%.4g", v)
    elseif tv == "boolean" then
        return v and "true" or "false"
    elseif tv == "string" then
        return '"' .. escape_str(v) .. '"'
    elseif tv == "table" then
        if is_array(v) then
            local parts = {}
            for i = 1, #v do parts[i] = encode(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            -- stable-ish key order: sort string keys
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            for _, k in ipairs(keys) do
                parts[#parts + 1] = '"' .. escape_str(k) .. '":' .. encode(v[k])
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

Recorder.encode = encode

function Recorder.toJSON()
    return encode(Recorder.frame)
end

return Recorder
