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
    -- A FLOOR, not a fingerprint. This guards the failure that actually matters
    -- -- a blank or chrome-less page -- and the earlier `> 20` was neither: the
    -- scene became a layout tree (it paints 18 now) and a threshold sitting one
    -- piece above whatever the scene happened to emit goes red on every
    -- legitimate reflow. Do not re-tighten it to track the current count.
    if not Assert.isTrue(textures > 10,
        ("chrome pieces painted (%d)"):format(textures)) then return false end
    return Assert.isTrue(texts > 10, ("index entries painted (%d)"):format(texts))
end

tests["index_shows_all_three_states_at_once"] = function()
    -- The messy middle is the only interesting preview. If the fixture ever
    -- drifts to all-known or all-unknown, this scene stops being able to show
    -- whether the states are visually distinguishable.
    --
    -- The three states are read off the copy the scene paints TODAY. It used to
    -- print one "N witnessed / M studied / K unmet" line; it now prints a
    -- "%d of %d met" summary plus a per-volume note, so witnessed-vs-unmet comes
    -- from the summary and studied from the notes.
    Render.frame(Index.build(), Index.W, Index.H)
    local painted = {}
    for _, op in ipairs(Recorder.ops) do
        if op.op == "text" then painted[#painted + 1] = tostring(op.str) end
    end

    local met, total
    for _, s in ipairs(painted) do
        local a, b = s:match("^(%d+) of (%d+) met$")
        if a then met, total = tonumber(a), tonumber(b) end
    end
    if not Assert.notNil(met, "the count line is on the page") then return false end

    -- Witnessed and unmet both come from the summary: a strict middle proves the
    -- fixture has not drifted to all-known or all-unknown.
    if not Assert.isTrue(met > 0, "some entries witnessed") then return false end
    if not Assert.isTrue(met < total,
        ("and some still unmet (%d of %d)"):format(met, total)) then return false end

    -- Studied shows up as a volume whose note says so: "complete" when every
    -- entry in it is also witnessed, "studied - N met in the field" otherwise.
    local studied = false
    for _, s in ipairs(painted) do
        if s == "complete" or s:match("^studied %- %d+ met in the field$") then
            studied = true
        end
    end
    return Assert.isTrue(studied, "some entries studied")
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
