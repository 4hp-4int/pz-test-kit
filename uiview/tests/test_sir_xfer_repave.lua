--[[
    SIR — transfer-glyph swap must survive vanilla's per-frame re-pave
    ==================================================================
    ISInventoryPage:update() calls controlsUI:arrange() EVERY frame, and
    arrange() -> handler:getImageButtonControl() re-runs setImage(vanilla
    strip) + forceImageSize(wide aspect) + setWidth on the SAME cached
    button. A one-shot swap latched on the button therefore shows for
    exactly one frame in-game while looking permanent in a build-once
    harness scene (the 2026-07-03 "harness shows the ink glyph, game shows
    vanilla" report). These tests model the re-pave between frames.
]]

local Assert = PZTestKit.Assert
local Render = require "UIView/Render"
local SIRInv = require "UIView/scenes/SIRInv"

local function frame(page)
    Render.frame(page, page.width + 16, page.height + 16)
end

-- what vanilla's getImageButtonControl does to the button on every arrange()
local function vanillaRepave(b, path)
    b:setImage(getTexture(path))
    local hgt = 14
    local wid = hgt * 3               -- the vanilla strips are wide
    if b.forceImageSize then b:forceImageSize(wid, hgt)
    else b.forcedWidthImage, b.forcedHeightImage = wid, hgt end
    if b.setWidth then b:setWidth(wid + 4) end
end

local VAN_ONE   = "media/ui/inventoryPanes/TransferSameTypeOneContainer.png"
local VAN_MULTI = "media/ui/inventoryPanes/TransferSameTypeMultiContainer.png"

local tests = {}

tests["first_frame_swaps_to_ink_glyph"] = function()
    local page = SIRInv.build({})
    frame(page)
    local b = page.controlsUI.controls[2]
    local nm = b.image and b.image.getName and b.image:getName() or tostring(b.image)
    return Assert.isTrue(tostring(nm):find("sir_ui%-xfer%-ink") ~= nil,
            "same-type button wears the ink glyph (got " .. tostring(nm) .. ")")
        and Assert.equal(b.width, b.height, "button squared to the glyph")
end

tests["swap_reasserts_after_vanilla_arrange_repave"] = function()
    local page = SIRInv.build({})
    frame(page)                                   -- frame 1: swap latches
    local b = page.controlsUI.controls[2]
    vanillaRepave(b, VAN_ONE)                     -- update() -> arrange() re-paves
    local paved = b.image and b.image.getName and b.image:getName() or ""
    frame(page)                                   -- frame 2: dress must win again
    local nm = b.image and b.image.getName and b.image:getName() or tostring(b.image)
    return Assert.isTrue(tostring(paved):find("SameType", 1, true) ~= nil,
            "re-pave restored the vanilla strip between frames")
        and Assert.isTrue(tostring(nm):find("sir_ui%-xfer%-ink") ~= nil,
            "dress re-asserted the ink glyph after the re-pave (got " .. tostring(nm) .. ")")
        and Assert.equal(b.width, b.height, "button re-squared after vanilla re-widened it")
end

tests["multi_container_variant_gets_multi_ink"] = function()
    local page = SIRInv.build({})
    local cui = page.controlsUI
    local b = ISButton:new(140, 3, 34, 20, "", page, function() end)
    b:initialise()
    b:setImage(getTexture(VAN_MULTI))
    b.textureColor = { r = 1, g = 1, b = 1, a = 1 }
    cui:addChild(b)
    cui.controls[#cui.controls + 1] = b
    frame(page)
    vanillaRepave(b, VAN_MULTI)
    frame(page)
    local nm = b.image and b.image.getName and b.image:getName() or tostring(b.image)
    return Assert.isTrue(tostring(nm):find("sir_ui%-xfer%-multi%-ink") ~= nil,
        "multi-container button wears (and keeps) the multi ink glyph (got " .. tostring(nm) .. ")")
end

tests["text_button_and_foreign_icons_left_alone"] = function()
    local page = SIRInv.build({})
    local cui = page.controlsUI
    -- a loot-window style icon button that is NOT a transfer control
    local b = ISButton:new(180, 3, 34, 20, "", page, function() end)
    b:initialise()
    b:setImage(getTexture("media/ui/inventoryPanes/MoveToFloor.png"))
    cui:addChild(b)
    cui.controls[#cui.controls + 1] = b
    frame(page)
    frame(page)
    local xferAll = cui.controls[1]
    local nm = b.image and b.image.getName and b.image:getName() or ""
    return Assert.isTrue(tostring(nm):find("MoveToFloor", 1, true) ~= nil,
            "non-transfer icon button keeps its own image")
        and Assert.isTrue(b._sirInkNo == true, "non-transfer icon latched as not-ours")
        and Assert.isTrue(xferAll.image == nil, "Transfer All stays a text button")
end

return tests
