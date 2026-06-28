--[[
    UIView — PaletteAd storyboard emit + sanity tests
    =================================================
    Emits the ad storyboard (for the player) and one representative single frame
    (for the existing viewer path, so real-icon resolution is easy to eyeball).
]]

local Assert   = PZTestKit.Assert
local Render   = require "UIView/Render"
local Ad       = require "UIView/scenes/PaletteAd"

-- Emit at load: storyboard array + a single "adframe" for the viewer.
do
    Render.emitStoryboard("ad", Ad.storyboard())
    -- zero-state showcase frame: all rows visible so every real item icon shows.
    local one = Ad.build({})
    Render.emit(one, 1280, 800, "adframe")
end

local tests = {}

tests["storyboard_has_all_beats"] = function()
    local beats = Ad.storyboard()
    return Assert.equal(#beats, 9, "9 scripted beats captured")
end

tests["beats_carry_real_icon_textures"] = function()
    local beats = Ad.storyboard()
    -- find a texture op pointing at a real PZ item icon (Item_*)
    local found = nil
    for _, b in ipairs(beats) do
        for _, op in ipairs(b.frame.ops) do
            if op.op == "texture" and tostring(op.name):find("Item_", 1, true) then found = op.name break end
        end
        if found then break end
    end
    return Assert.notNil(found, "a real PZ item icon texture (Item_*) is recorded")
end

tests["typing_barri_narrows_to_barricade"] = function()
    local root = Ad.build({ query = "barri" })
    local labels = {}
    for _, r in ipairs(root.rows) do if r.cmd then labels[r.cmd.label] = true end end
    if not Assert.isTrue(labels["Barricade Window"] == true, "Barricade Window survives 'barri'") then return false end
    return Assert.isTrue(labels["Drink Water"] == nil, "Drink Water filtered out by 'barri'")
end

tests["bleeding_floats_bandage_to_top"] = function()
    local root = Ad.build({ bleeding = true })
    -- first runnable single row should be the med/Bandage command
    local top = nil
    for _, r in ipairs(root.rows) do
        if r.cmd then top = r.cmd break end
    end
    if not Assert.notNil(top, "a top row exists") then return false end
    return Assert.equal(top.label, "Bandage Wound", "Bandage ranks first while bleeding")
end

return tests
