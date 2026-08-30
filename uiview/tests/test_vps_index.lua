--[[
    UIView — VPS journal index emit + sanity

    Emits scene "vpsindex" (the shipping Knowledge model rendered through the
    shipping Chrome, not a mockup) and asserts the page is actually showing a
    MIXED state. A fully-known index and a fully-unknown one both render
    perfectly, so "it drew something" proves nothing -- what matters is that
    all three states appear on the page at once.
]]

local Assert = PZTestKit.Assert
local Render = require "UIView/Render"
local Recorder = require "UIView/Recorder"
local Index = require "UIView/scenes/VPSIndex"

do
    Render.emit(Index.build(), Index.W, Index.H, "vpsindex")
end

local tests = {}

tests["index_page_paints_chrome_and_text"] = function()
    Render.frame(Index.build(), Index.W, Index.H)
    local textures, texts = 0, 0
    for _, op in ipairs(Recorder.ops) do
        if op.op == "texture" then textures = textures + 1
        elseif op.op == "text" then texts = texts + 1 end
    end
    if not Assert.isTrue(textures > 20,
        ("chrome pieces painted (%d)"):format(textures)) then return false end
    return Assert.isTrue(texts > 10, ("index entries painted (%d)"):format(texts))
end

tests["index_shows_all_three_states_at_once"] = function()
    -- The messy middle is the only interesting preview. If the fixture ever
    -- drifts to all-known or all-unknown, this scene stops being able to show
    -- whether the states are visually distinguishable.
    Render.frame(Index.build(), Index.W, Index.H)
    local header
    for _, op in ipairs(Recorder.ops) do
        if op.op == "text" and tostring(op.str):find("witnessed") then
            header = tostring(op.str)
        end
    end
    if not Assert.notNil(header, "the count line is on the page") then return false end
    local w, s, u = header:match("(%d+) witnessed.-(%d+) studied.-(%d+) unmet")
    w, s, u = tonumber(w), tonumber(s), tonumber(u)
    if not Assert.isTrue(w and w > 0, "some entries witnessed") then return false end
    if not Assert.isTrue(s and s > 0, "some entries studied") then return false end
    return Assert.isTrue(u and u > 0, "and some still unmet")
end

tests["index_does_not_print_unknown_names"] = function()
    -- The blank rule is drawn as a RECT, never as text. If an unknown name
    -- ever reached drawText the collection loop would be pointless -- and it
    -- would look completely normal.
    Render.frame(Index.build(), Index.W, Index.H)
    local K = VorpallySauced.Knowledge
    -- Every affix name that should still be hidden, per the scene's fixture.
    local painted = {}
    for _, op in ipairs(Recorder.ops) do
        if op.op == "text" then painted[tostring(op.str)] = true end
    end
    -- Firearm prefixes are documented only by Vol VI, which the fixture has
    -- NOT studied, and none were witnessed -- so not one of their names may
    -- appear anywhere on the page.
    local leaked = nil
    for i, affix in ipairs(VorpallySauced.FirearmPrefixes or {}) do
        local nm = affix.name and getText(affix.name)
        if nm and painted[nm] then leaked = nm break end
    end
    return Assert.isNil(leaked,
        "no unstudied, unwitnessed affix name is printed (" .. tostring(leaked) .. ")")
end

return tests
