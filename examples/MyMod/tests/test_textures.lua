--[[
    Textures, headless (PZEngine.loadTextures). The game's own texture lookup
    (Texture.getSharedTexture / trygetTexture) answers with real
    zombie.core.textures.Texture objects -- right name and size, a pack
    sub-texture's rect and offsets -- with no pixels decoded and nothing sent
    to GL. Guards the kit itself: a loose PNG, a vanilla pack texture, a mod
    pack's texture (SauceTooltips' STChrome, when the monorepo holds it), and
    a real Java draw call with one.
]]

if not (PZEngine and PZEngine.available() and PZEngine.loadTextures) then return {} end
local Assert = PZTestKit.Assert

-- SauceTooltips is a sibling of the kit in the monorepo (pz-mods/); the path
-- is relative to this mod's root (pz-test-kit/examples/MyMod)
local ST = "../../../SauceTooltips"

local res, err
local function load()
    if res == nil then res, err = PZEngine.loadTextures({ mods = { ST } }) end
    return res
end

local tests = {}

tests["load_textures_reports_counts"] = function()
    local r = load()
    if not Assert.notNil(r, "loadTextures: " .. tostring(err)) then return false end
    print(string.format("[textures] loose=%d vanilla=%d mods=%d packs=%d lookup=%d",
        r.loose, r.vanilla, r.mods, r.packs, r.lookup))
    if not Assert.isTrue(r.loose > 1000, "loose PNGs mapped") then return false end
    if not Assert.isTrue(r.vanilla > 1000, "vanilla pack sub-textures") then return false end
    local again = PZEngine.loadTextures({ mods = { ST } })
    return Assert.equal(again.packs, r.packs, "idempotent: no pack mounted twice")
end

tests["a_loose_png_resolves_with_its_size"] = function()
    load()
    local t = PZEngine.texture("media/ui/Panel_Icon_Close.png")
    if not Assert.notNil(t, "media/ui/Panel_Icon_Close.png") then return false end
    if not Assert.isTrue(instanceof(t, "Texture"), "a real Texture") then return false end
    -- 11x10 is the file's own IHDR; nothing decoded it (Texture.syncReadSize)
    if not Assert.equal(t:getWidth(), 11, "width from the PNG header") then return false end
    if not Assert.equal(t:getHeight(), 10, "height from the PNG header") then return false end
    if not Assert.isFalse(t:isReady(), "no pixels: its data load stays queued") then return false end
    if not Assert.isTrue(tryGetTexture ~= nil and getTexture("media/ui/Panel_Icon_Close.png") == t,
        "the getTexture global (installed: this env had none) is the game's") then return false end
    -- the same object again: the game's shared table caches it
    return Assert.isTrue(PZEngine.texture("media/ui/Panel_Icon_Close.png") == t, "cached")
end

tests["a_vanilla_pack_texture_resolves_with_its_rect"] = function()
    load()
    local t = PZEngine.texture("Item_Axe")
    if not Assert.notNil(t, "Item_Axe") then return false end
    if not Assert.equal(t:getName(), "Item_Axe", "name") then return false end
    -- UI2.pack's table: a 31x31 rect trimmed from a 32x32 icon at offset 1,1
    if not Assert.isTrue(t:getWidth() > 0 and t:getHeight() > 0, "trimmed rect") then return false end
    if not Assert.isTrue(t:getOffsetX() + t:getWidth() <= t:getWidthOrig()
        and t:getOffsetY() + t:getHeight() <= t:getHeightOrig(), "rect + offset inside the original size") then return false end
    return Assert.isTrue(tryGetTexture("Item_Axe") == t, "trygetTexture finds the same one")
end

tests["a_mod_pack_texture_resolves"] = function()
    load()
    local t = PZEngine.texture("st_ledger_tl")
    if (res and res.mods or 0) == 0 then
        print("[textures] SauceTooltips not beside the kit; mod pack case skipped")
        return true
    end
    if not Assert.notNil(t, "st_ledger_tl") then return false end
    if not Assert.equal(t:getName(), "st_ledger_tl", "name") then return false end
    if not Assert.equal(t:getWidth(), 20, "width") then return false end
    if not Assert.equal(t:getHeight(), 20, "height") then return false end
    -- the whole nine-patch Dress.lua resolves (SauceTooltips/media/lua/client/SauceTooltips/Dress.lua)
    for _, sheet in ipairs({ "ledger", "wincap", "entry", "chip" }) do
        for _, k in ipairs({ "tl", "t", "tr", "l", "r", "bl", "b", "br" }) do
            if not Assert.notNil(PZEngine.texture("st_" .. sheet .. "_" .. k), "st_" .. sheet .. "_" .. k) then return false end
        end
    end
    return true
end

tests["unknown_names_stay_nil"] = function()
    load()
    if not Assert.isNil(PZEngine.texture("no_such_texture_anywhere"), "unknown sub-texture") then return false end
    return Assert.isNil(PZEngine.texture("media/ui/no_such_file.png"), "unknown file")
end

tests["a_java_draw_with_a_real_texture_does_not_throw"] = function()
    load()
    if PZEngine.loadFonts then PZEngine.loadFonts() end
    PZEngine.expose("zombie.ui.ObjectTooltip")
    local tip = zombie.ui.ObjectTooltip.new()   -- the real Java UIElement
    if not Assert.isTrue(instanceof(tip, "ObjectTooltip"), "a real ObjectTooltip") then return false end
    local tex = PZEngine.texture("Item_Axe")
    local ok, e = pcall(function()
        tip:DrawTextureScaledColor(tex, 0, 0, 32, 32, 1, 1, 1, 1)
        tip:DrawTextureScaled(tex, 0, 0, 16, 16, 1)
        tip:DrawTexture(tex, 0, 0, 1)
        tip:DrawTextureScaledColor(PZEngine.texture("media/ui/Panel_Icon_Close.png"), 4, 4, 8, 8, 1, 1, 1, 1)
        if PZEngine.texture("st_ledger_tl") then
            tip:DrawTextureScaledColor(PZEngine.texture("st_ledger_tl"), 0, 0, 20, 20, 1, 1, 1, 1)
        end
    end)
    -- They reach SpriteRenderer, whose state drops a texture that is not
    -- ready (SpriteRenderState.render: `tex == null || tex.isReady()`), as it
    -- does in game for a texture still loading: no GL, no queued draw.
    return Assert.isTrue(ok, "draws: " .. tostring(e))
end

return tests
