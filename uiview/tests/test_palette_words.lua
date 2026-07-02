--[[ pal_words — taught words: teach/forget round-trip, alternate-query rewriting in
     the filter (incl. the narrowing bypass), the miss-fallback teach offer, and the
     pal_ui pick-mode flow (Enter BINDS, Esc cancels, never runs/closes). ]]
local Assert = PZTestKit.Assert
require "palette/pal_words"
require "palette/pal_filter"
local States = require "UIView/scenes/PaletteStates"
local D = States.D
local SP = _G.SaucePalette
local W = SP.Words

-- getFileReader nil -> load() starts empty; harness getFileWriter is a no-op.
local function noFile(fn)
    local savedR = _G.getFileReader
    _G.getFileReader = function() return nil end
    local ok, err = pcall(fn)
    _G.getFileReader = savedR
    if not ok then error(err) end
end

-- wipe taught words between tests (module state persists across the file)
local function reset()
    for w in pairs(W.all()) do W.forget(w) end
end

local function fakeSelf(cmds)
    return { allCommands = cmds, playerNum = 0 }
end
local function cmd(label, cat)
    return { label = label, category = cat or "use", kind = cat or "use",
             runnable = true, run = function() end }
end
local function labels(self)
    local out = {}
    for _, c in ipairs(self.filtered) do out[#out + 1] = c.label end
    return table.concat(out, "|")
end

local tests = {}

tests["teach_forget_roundtrip"] = function()
    noFile(function()
        reset()
        if not Assert.isTrue(W.teach("genny", "Equip Generator"), "teach accepts") then error("t") end
        if not Assert.equal(W.get("genny"), "Equip Generator", "get returns the label") then error("t") end
        if not Assert.equal(W.get(" 'GENNY' "), "Equip Generator", "lookup normalizes case/quotes") then error("t") end
        if not Assert.isTrue(W.forget("genny"), "forget removes") then error("t") end
        if not Assert.isNil(W.get("genny"), "gone after forget") then error("t") end
        if not Assert.isTrue(W.teach("x", "Y") == false, "1-char word rejected") then error("t") end
        if not Assert.isTrue(W.teach("generator", "Generator") == false, "word == its own label rejected") then error("t") end
    end)
    return true
end

tests["altQueries_prefix_rule"] = function()
    noFile(function()
        reset()
        W.teach("genny", "Equip Generator")
        if not Assert.isNil(W.altQueries("g"), "1 char: no alternates") then error("t") end
        local a = W.altQueries("ge")
        if not (a and a[1] == "equip generator") then error(Assert.equal(a and a[1], "equip generator", "2-char prefix fires")) end
        a = W.altQueries("genny")
        if not (a and #a == 1) then error(Assert.equal(a and #a, 1, "exact word fires once")) end
        if not Assert.isNil(W.altQueries("xyz"), "unrelated query: nil") then error("t") end
    end)
    return true
end

tests["filter_matches_taught_word"] = function()
    noFile(function()
        reset()
        W.teach("genny", "Equip Generator")
        local s = fakeSelf({ cmd("Equip Generator", "equip"), cmd("Eat Apple", "eat") })
        SP.Filter.run(s, "genny")
        if not Assert.equal(#s.filtered, 1, "taught word finds exactly its binding") then error("t") end
        if not Assert.equal(s.filtered[1].label, "Equip Generator", "the bound row") then error("t") end
    end)
    return true
end

tests["filter_taught_word_reaches_minor_rows"] = function()
    noFile(function()
        reset()
        W.teach("genny", "Equip Generator")
        local minorRow = cmd("Equip Generator", "equip"); minorRow.minor = true
        local s = fakeSelf({ minorRow })
        SP.Filter.run(s, "genny")
        if not Assert.equal(#s.filtered, 1, "teaching overrides minor hiding") then error("t") end
    end)
    return true
end

tests["filter_narrowing_bypassed_while_alts_live"] = function()
    noFile(function()
        reset()
        W.teach("genny", "Equip Generator")
        local s = fakeSelf({ cmd("Equip Generator", "equip"), cmd("Eat Apple", "eat"),
                             cmd("Grab Nails", "grab") })
        SP.Filter.run(s, "g")     -- 1 char: no alts; "g" matches Grab/Generator...
        SP.Filter.run(s, "ge")    -- alts fire here — extension MUST full-scan
        if not Assert.equal(SP.Filter._lastScan, #s.allCommands,
            "alternate queries force a full scan on extension") then error("t") end
        if not Assert.equal(s.filtered[1].label, "Equip Generator", "bound row found at 2 chars") then error("t") end
    end)
    return true
end

tests["miss_offers_teach_row"] = function()
    noFile(function()
        reset()
        local s = fakeSelf({ cmd("Eat Apple", "eat") })
        SP.Filter.run(s, "zorbl")
        if not Assert.equal(#s.filtered, 1, "miss appends exactly the offer") then error("t") end
        local r = s.filtered[1]
        if not Assert.equal(r.kind, "teach", "offer row kind") then error("t") end
        if not Assert.equal(r._word, "zorbl", "offer carries the word") then error("t") end
        -- short queries stay a plain miss
        SP.Filter.run(s, "zo")
        if not Assert.equal(#s.filtered, 0, "2-char miss: no offer") then error("t") end
        -- real matches: no offer
        SP.Filter.run(s, "apple")
        if not Assert.equal(s.filtered[1].label, "Eat Apple", "hit shows the real row, no offer") then error("t") end
    end)
    return true
end

tests["pick_mode_binds_on_enter_and_stays_open"] = function()
    local root
    noFile(function()
        reset()
        root = States.build({ commands = { cmd("Equip Generator", "equip"), cmd("Eat Apple", "eat") } })
        root:enterPickMode("genny")
        if not root._pickWord then error(Assert.isTrue(false, "pick mode entered")) end
        -- search for the target, select it, Enter binds (never runs/closes)
        D.type(root, "generator")
        root.sel = 1
        D.enter(root)
        if not Assert.isNil(root._pickWord, "pick mode exits after binding") then error("t") end
        if not Assert.equal(D.closed, false, "palette stayed open") then error("t") end
        if not Assert.equal(W.get("genny"), "Equip Generator", "word bound to the picked label") then error("t") end
        -- and the binding works immediately
        D.type(root, "genny")
        local found = false
        for _, r in ipairs(root.rows) do
            if r.cmd and r.cmd.label == "Equip Generator" then found = true end
        end
        if not Assert.isTrue(found, "taught word matches with no reopen") then error("t") end
    end)
    return true
end

tests["pick_mode_esc_cancels_clean"] = function()
    local root
    noFile(function()
        reset()
        root = States.build({ commands = { cmd("Eat Apple", "eat") } })
        root:enterPickMode("zorbl")
        D.key(root, Keyboard.KEY_ESCAPE)
        if not Assert.isNil(root._pickWord, "Esc exits pick mode") then error("t") end
        if not Assert.equal(D.closed, false, "palette stayed open (Esc consumed by pick)") then error("t") end
        if not Assert.isNil(W.get("zorbl"), "nothing was bound") then error("t") end
    end)
    return true
end

tests["teach_offer_enter_starts_pick_mode"] = function()
    local root
    noFile(function()
        reset()
        root = States.build({ commands = { cmd("Eat Apple", "eat") } })
        D.type(root, "zorbl")                       -- miss -> offer row
        root.sel = 1
        D.enter(root)
        if not Assert.equal(root._pickWord, "zorbl", "Enter on the offer enters pick mode") then error("t") end
        if not Assert.equal(D.closed, false, "no close") then error("t") end
        local q = root.entry:getText()
        if not Assert.equal(q, "", "box cleared for the pick") then error("t") end
    end)
    return true
end

tests["forget_rows_enumerate"] = function()
    noFile(function()
        reset()
        W.teach("genny", "Equip Generator")
        W.teach("zeds", "Shout")
        local desc
        for _, s in ipairs(SP.sources) do if s.id == "words" then desc = s end end
        if not Assert.notNil(desc, "words source registered") then error("t") end
        if not Assert.isTrue(desc.volatile == true, "volatile (set changes without cache keys)") then error("t") end
        local rows = desc.collect(0)
        if not Assert.equal(#rows, 2, "one forget row per taught word") then error("t") end
        if not Assert.isTrue(rows[1].alwaysMinor == true, "typed-only") then error("t") end
        rows[1].run()
        local n = 0
        for _ in pairs(W.all()) do n = n + 1 end
        if not Assert.equal(n, 1, "forget row forgets") then error("t") end
    end)
    return true
end

return tests
