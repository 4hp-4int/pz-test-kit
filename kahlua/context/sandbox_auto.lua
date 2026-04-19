--[[
    PZ Test Kit — sandbox-options.txt auto-discovery
    =================================================
    Populates SandboxVars from the mod's media/sandbox-options.txt so tests
    don't need to duplicate defaults in pz-test.lua. Reads the file content
    from `_pz_sandbox_source` (set by Java), parses each `option` block, and
    writes the default into SandboxVars[modName][optionName] IF and ONLY IF
    that slot is currently nil.

    Never overwrites explicit pz-test.lua `sandbox = { ... }` values — those
    already ran via config_loader.lua before this helper loads.

    Parse rules (match vanilla B42 sandbox-options.txt):
        option ModName.OptionName
        {
            type    = boolean | integer | double | string | enum,
            default = <value>,
            ...
        }
]]

if type(_pz_sandbox_source) ~= "string" then return end
SandboxVars = SandboxVars or {}

local function coerce(kind, raw)
    kind = kind and kind:lower() or nil
    if kind == "boolean" then
        if raw == "true"  then return true  end
        if raw == "false" then return false end
        return nil
    elseif kind == "integer" or kind == "double" then
        return tonumber(raw)
    elseif kind == "enum" then
        return tonumber(raw) or raw
    else
        -- strip quotes if present, else return as-is
        local stripped = raw:match("^\"(.*)\"$")
        return stripped or raw
    end
end

local count = 0

-- Scan each `option ModName.OptionName { ... }` block. Lua patterns can't
-- match nested braces so we capture everything up to the next `}`.
for modName, optName, body in
    _pz_sandbox_source:gmatch("option%s+([%w_]+)%.([%w_]+)%s*{(.-)}")
do
    local kind    = body:match("type%s*=%s*([%w_]+)")
    local default = body:match("default%s*=%s*([^,\n]+)")
    if kind and default then
        default = default:gsub("^%s+", ""):gsub("%s+$", "")
        local value = coerce(kind, default)
        if value ~= nil then
            SandboxVars[modName] = SandboxVars[modName] or {}
            if SandboxVars[modName][optName] == nil then
                SandboxVars[modName][optName] = value
                count = count + 1
            end
        end
    end
end

if count > 0 then
    print("[PZTestKit] Auto-discovered " .. count ..
          " sandbox default(s) from media/sandbox-options.txt")
end
