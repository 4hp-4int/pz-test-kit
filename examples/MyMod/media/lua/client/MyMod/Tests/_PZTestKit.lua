--[[
    PZ Test Kit — In-Game Framework
    ================================
    Sets up PZTestKit namespace, Assert library, mock factories, and test
    runner. Auto-loads first (underscore prefix sorts before test_ files).

    Test files self-register via PZTestKit.registerTests().
    Run from console: PZTestKit.runTests()
]]

if isServer() and not isClient() then return end

-- ============================================================================
-- PZTestKit NAMESPACE
-- ============================================================================

PZTestKit = PZTestKit or {}
PZTestKit._testFiles = {}

-- ============================================================================
-- ASSERT LIBRARY (same API as kahlua/Assert.lua)
-- ============================================================================

if not PZTestKit.Assert then
    PZTestKit.Assert = {}
    local A = PZTestKit.Assert

    local function fmt(v)
        if v == nil then return "nil" end
        if type(v) == "string" then return '"' .. v .. '"' end
        if type(v) == "number" then
            if v == math.floor(v) then return tostring(v) end
            return string.format("%.4f", v)
        end
        return tostring(v)
    end

    local function pass(l, ...) print(string.format("  [PASS] " .. l, ...)); return true end
    local function fail(l, ...) print(string.format("  [FAIL] " .. l, ...)); return false end

    function A.equal(a, e, l) l=l or ""; if a==e then return pass("%s: %s == %s",l,fmt(a),fmt(e)) else return fail("%s: expected %s, got %s",l,fmt(e),fmt(a)) end end
    function A.notEqual(a, u, l) l=l or ""; if a~=u then return pass("%s: %s ~= %s",l,fmt(a),fmt(u)) else return fail("%s: expected not %s",l,fmt(u)) end end
    function A.nearEqual(a, e, t, l) t=t or 0.001; l=l or ""; if a and e and math.abs(a-e)<=t then return pass("%s: %s ~= %s",l,fmt(a),fmt(e)) else return fail("%s: expected ~%s, got %s",l,fmt(e),fmt(a)) end end
    function A.greater(a, t, l) l=l or ""; if a>t then return pass("%s: %s > %s",l,fmt(a),fmt(t)) else return fail("%s: expected > %s, got %s",l,fmt(t),fmt(a)) end end
    function A.greaterEq(a, t, l) l=l or ""; if a>=t then return pass("%s: %s >= %s",l,fmt(a),fmt(t)) else return fail("%s: expected >= %s, got %s",l,fmt(t),fmt(a)) end end
    function A.less(a, t, l) l=l or ""; if a<t then return pass("%s: %s < %s",l,fmt(a),fmt(t)) else return fail("%s: expected < %s, got %s",l,fmt(t),fmt(a)) end end
    function A.lessEq(a, t, l) l=l or ""; if a<=t then return pass("%s: %s <= %s",l,fmt(a),fmt(t)) else return fail("%s: expected <= %s, got %s",l,fmt(t),fmt(a)) end end
    function A.notNil(v, l) l=l or "value"; if v~=nil then return pass("%s: not nil",l) else return fail("%s: expected non-nil",l) end end
    function A.isNil(v, l) l=l or "value"; if v==nil then return pass("%s: nil",l) else return fail("%s: expected nil, got %s",l,fmt(v)) end end
    function A.isTrue(v, l) l=l or ""; if v==true then return pass("%s: true",l) else return fail("%s: expected true, got %s",l,fmt(v)) end end
    function A.isFalse(v, l) l=l or ""; if v==false then return pass("%s: false",l) else return fail("%s: expected false, got %s",l,fmt(v)) end end
    function A.tableHas(t, k, l) l=l or ""; if type(t)~="table" then return fail("%s: not a table",l) end; if t[k]~=nil then return pass("%s: has '%s'",l,tostring(k)) else return fail("%s: missing '%s'",l,tostring(k)) end end
    function A.tableNotHas(t, k, l) l=l or ""; if type(t)~="table" then return fail("%s: not a table",l) end; if t[k]==nil then return pass("%s: no '%s'",l,tostring(k)) else return fail("%s: unexpected '%s'",l,tostring(k)) end end
end

-- ============================================================================
-- MOCK FACTORIES (pure Lua — work in-game for creating test fixtures)
-- ============================================================================

if not _pz_gen_id then
    _pz_next_id = _pz_next_id or 100000
    function _pz_gen_id()
        _pz_next_id = _pz_next_id + 1
        return _pz_next_id
    end
end

if not _pz_create_mock_zombie then
    function _pz_create_mock_zombie(opts)
        opts = opts or {}
        local z = {
            _type = "IsoZombie",
            _health = opts.health or 1.8,
            _staggerBack = false,
            _onFire = false,
            _id = _pz_gen_id(),
        }
        z.getHealth = function(self) return self._health end
        z.setHealth = function(self, v) self._health = v end
        z.isAlive = function(self) return self._health > 0 end
        z.setStaggerBack = function(self, v) self._staggerBack = v end
        z.isStaggerBack = function(self) return self._staggerBack end
        z.SetOnFire = function(self) self._onFire = true end
        z.isOnFire = function(self) return self._onFire end
        z.getOnlineID = function(self) return self._id end
        return z
    end
end

if not _pz_create_mock_square then
    function _pz_create_mock_square(opts)
        opts = opts or {}
        local sq = {
            _type = "IsoGridSquare",
            _isOutside = opts.isOutside or false,
            _room = opts.room,
            _x = opts.x or 0, _y = opts.y or 0, _z = opts.z or 0,
        }
        sq.isOutside = function(self) return self._isOutside end
        sq.getRoom = function(self)
            if self._room then return { getName = function() return self._room end } end
            if self._isOutside then return nil end
            return { getName = function() return "room" end }
        end
        sq.getX = function(self) return self._x end
        sq.getY = function(self) return self._y end
        sq.getZ = function(self) return self._z end
        return sq
    end
end

-- ============================================================================
-- TEST REGISTRATION
-- ============================================================================

function PZTestKit.registerTests(name, testTable)
    if type(testTable) ~= "table" then return end
    -- Avoid double-registration (PZ auto-load + require from hub)
    for _, existing in ipairs(PZTestKit._testFiles) do
        if existing.name == name then return end
    end
    table.insert(PZTestKit._testFiles, { name = name, tests = testTable })
end

-- ============================================================================
-- TEST RUNNER
-- ============================================================================

function PZTestKit.runTests()
    local grandTotal, grandPass, grandFail, grandErr = 0, 0, 0, 0
    local lines = {}

    table.insert(lines, "====================================================")
    table.insert(lines, "PZ Test Kit — In-Game Runner")
    table.insert(lines, "====================================================")

    if #PZTestKit._testFiles == 0 then
        table.insert(lines, "  No tests registered!")
        table.insert(lines, "====================================================")
        for _, line in ipairs(lines) do print(line) end
        return true
    end

    for _, group in ipairs(PZTestKit._testFiles) do
        local names = {}
        for name in pairs(group.tests) do table.insert(names, name) end
        table.sort(names)

        local total, passed, failed, errors = 0, 0, 0, 0

        for _, name in ipairs(names) do
            total = total + 1
            local ok, err = pcall(function()
                local result = group.tests[name]()
                if result then passed = passed + 1
                else failed = failed + 1 end
            end)
            if not ok then
                errors = errors + 1
                local msg = "  [ERROR] " .. name .. " -- " .. tostring(err)
                print(msg)
                table.insert(lines, msg)
            end
        end

        grandTotal = grandTotal + total
        grandPass = grandPass + passed
        grandFail = grandFail + failed
        grandErr = grandErr + errors

        local flag = (failed + errors == 0) and "" or " *** FAILURES ***"
        table.insert(lines, string.format("--- %s (%d tests) ---%s", group.name, total, flag))
    end

    local summary = string.format("TOTAL: %d tests, %d passed, %d failed, %d errors",
        grandTotal, grandPass, grandFail, grandErr)
    table.insert(lines, "====================================================")
    table.insert(lines, summary)
    table.insert(lines, "====================================================")

    for _, line in ipairs(lines) do print(line) end

    local writer = getFileWriter("PZTestKitResults.txt", true, false)
    if writer then
        for _, line in ipairs(lines) do writer:write(line .. "\n") end
        writer:close()
        print("[PZTestKit] Results written to Lua/PZTestKitResults.txt")
    end

    return grandFail + grandErr == 0
end

print("[PZTestKit] Framework loaded — tests self-register on load")
