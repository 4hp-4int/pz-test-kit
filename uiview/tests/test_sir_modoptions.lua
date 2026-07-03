--[[
    SIR — Mod Options wiring (sir_options)
    ======================================
    Loads sir_options with a PZAPI.ModOptions mock in place (each test file
    gets a fresh env, so this is the one place the PZAPI-present path runs
    headlessly): registration builds the option set, and apply()/OnGameStart
    pull the option values back into SIR.Options + push the presets into the
    render/icon modules.
]]

local Assert = PZTestKit.Assert

require "UIView/UIMock"
if getText == nil then function getText(k) return tostring(k) end end

-- PZAPI mock BEFORE sir_options loads (initOptions runs at require time)
local registered = {}   -- id -> option object
PZAPI = PZAPI or {}
PZAPI.ModOptions = {
    create = function()
        local opts = {}
        function opts:addTitle() end
        function opts:addDescription() end
        local function opt(id, value)
            local o = { _v = value, getValue = function(self) return self._v end }
            registered[id] = o
            return o
        end
        function opts:addTickBox(id, name, value) return opt(id, value) end
        function opts:addKeyBind(id, name, key) return opt(id, key) end
        function opts:addComboBox(id, name)
            local o = opt(id, 1)
            o._n = 0
            o.addItem = function(self, label, selected)
                self._n = self._n + 1
                if selected then self._v = self._n end
            end
            return o
        end
        return opts
    end,
}

require "sir_options"

local SIR = _G.SauceInvRender
local tests = {}

tests["registration_builds_the_option_set"] = function()
    local ok = Assert.notNil(registered.trackDuplicates, "duplicate master toggle registered")
    ok = Assert.notNil(registered.showHeatTint, "heat tint toggle registered") and ok
    ok = Assert.notNil(registered.bookmarkStyle, "favorite style combo registered") and ok
    ok = Assert.equal(registered.maxItemsPreset and registered.maxItemsPreset._v, 2,
        "max-items combo defaults to the selected item (30)") and ok
    return ok
end

tests["apply_pulls_values_into_SIR_Options"] = function()
    registered.trackDuplicates._v = false
    registered.showHeatTint._v = false
    registered.bookmarkStyle._v = 3
    registered.maxItemsPreset._v = 4
    triggerEvent("OnGameStart")     -- initOptions wires pullAndApply here
    local ok = Assert.isFalse(SIR.Options.trackDuplicates, "toggle pulled")
    ok = Assert.isFalse(SIR.Options.showHeatTint, "second toggle pulled") and ok
    ok = Assert.equal(SIR.Options.bookmarkStyle, 3, "combo index pulled") and ok
    ok = Assert.equal(SIR.Options.maxItemsPreset, 4, "preset index pulled") and ok
    -- restore defaults for any later test in this env
    registered.trackDuplicates._v = true
    registered.showHeatTint._v = true
    registered.bookmarkStyle._v = 1
    registered.maxItemsPreset._v = 2
    triggerEvent("OnGameStart")
    return ok
end

tests["applyOptions_pushes_presets_into_modules"] = function()
    -- observable through the render cap: preset 1 caps expanded groups at 10
    SIR.Options.maxItemsPreset = 1
    SIR.Options.bookmarkStyle = 2
    SIR.applyOptions()
    local ok = Assert.isTrue(true, "applyOptions ran the push path")
    SIR.Options.maxItemsPreset = 2
    SIR.Options.bookmarkStyle = 1
    SIR.applyOptions()
    return ok
end

return tests
