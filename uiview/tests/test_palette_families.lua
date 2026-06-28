--[[
    SaucePalette command-families engine + magazine adapter — offline tests
    =======================================================================
    Verifies the mod-compat abstraction: harvested variant options (e.g. multi-
    capacity magazines from a gun framework) collapse into ONE family keyed per
    gun, with the right DEFAULT (best loaded, else highest capacity). Members are
    recognised by DUCK-TYPING the onSelect params — no mod is named — so the mock
    magazines/weapons here exercise the exact path Gunworks/MarzGuns/vanilla hit.
]]

local Assert = PZTestKit.Assert
local SP = require "palette/pal_families"
local Families = SP.Families

-- ---- mock harvested-command builders --------------------------------------
-- A magazine item answers getMaxAmmo (>0) + getCurrentAmmoCount. A weapon answers
-- getMagazineType + getFullType/getName and is NOT a magazine. The command mirrors
-- a harvested onInsertMagazine(player, weapon, clip): target=player, params={weapon, clip}.
-- _type drives the harness's instanceof(): a magazine is an InventoryItem, a gun
-- is a HandWeapon (which the real game also reports as an InventoryItem via the
-- class hierarchy — the adapter excludes guns explicitly, so exact-match is fine).
local function mockMag(maxAmmo, loaded)
    return {
        _type               = "InventoryItem",
        getMaxAmmo          = function() return maxAmmo end,
        getCurrentAmmoCount = function() return loaded end,
    }
end

local function mockGun(fullType, name)
    return {
        _type           = "HandWeapon",
        getMagazineType = function() return "Base.SomeMag" end,
        getFullType     = function() return fullType end,
        getName         = function() return name end,
    }
end

local function magCmd(label, gun, mag)
    return { label = label, source = "Rifle", target = {}, params = { gun, mag } }
end

local function apply(cmds) Families.apply(cmds); return cmds end
local function defaultOf(cmds)
    for _, c in ipairs(cmds) do if c.familyDefault then return c end end
    return nil
end
local function familyCount(cmds)
    local keys = {}
    for _, c in ipairs(cmds) do if c.familyKey then keys[c.familyKey] = true end end
    local n = 0; for _ in pairs(keys) do n = n + 1 end; return n
end

local tests = {}

tests["adapter_registered"] = function()
    return Assert.notNil(Families and Families.apply, "Families.apply exists")
end

tests["three_mags_one_gun_collapse"] = function()
    local gun = mockGun("Base.M16", "M16")
    local cmds = apply({
        magCmd("Insert 20-round", gun, mockMag(20, 0)),
        magCmd("Insert 30-round", gun, mockMag(30, 0)),
        magCmd("Insert 60-round", gun, mockMag(60, 0)),
    })
    if not Assert.equal(familyCount(cmds), 1, "all three collapse into ONE family") then return false end
    for _, c in ipairs(cmds) do
        if not Assert.notNil(c.familyKey, "member stamped with familyKey") then return false end
    end
    return Assert.isTrue(true)
end

tests["default_is_highest_capacity_when_none_loaded"] = function()
    local gun = mockGun("Base.M16", "M16")
    local cmds = apply({
        magCmd("Insert 20-round", gun, mockMag(20, 0)),
        magCmd("Insert 60-round", gun, mockMag(60, 0)),
        magCmd("Insert 30-round", gun, mockMag(30, 0)),
    })
    local def = defaultOf(cmds)
    if not Assert.notNil(def, "a default was chosen") then return false end
    return Assert.equal(def.label, "Insert 60-round", "highest capacity is default when none loaded")
end

tests["default_is_best_loaded_over_capacity"] = function()
    local gun = mockGun("Base.M16", "M16")
    -- 30-round with 25 loaded should beat an empty 60-round (more rounds READY)
    local cmds = apply({
        magCmd("Insert 60-round", gun, mockMag(60, 0)),
        magCmd("Insert 30-round", gun, mockMag(30, 25)),
        magCmd("Insert 20-round", gun, mockMag(20, 5)),
    })
    local def = defaultOf(cmds)
    if not Assert.notNil(def, "a default was chosen") then return false end
    return Assert.equal(def.label, "Insert 30-round", "most-loaded magazine wins over bigger-but-empty")
end

tests["two_guns_two_families"] = function()
    local m16 = mockGun("Base.M16", "M16")
    local ak  = mockGun("Base.AK", "AK")
    local cmds = apply({
        magCmd("Insert 20-round", m16, mockMag(20, 0)),
        magCmd("Insert 60-round", m16, mockMag(60, 0)),
        magCmd("Insert 30-round", ak,  mockMag(30, 0)),
        magCmd("Insert 75-round", ak,  mockMag(75, 0)),
    })
    return Assert.equal(familyCount(cmds), 2, "magazines collapse per-gun, not globally")
end

tests["lone_option_is_not_a_family"] = function()
    local gun = mockGun("Base.Revolver", "Revolver")
    local cmds = apply({ magCmd("Insert speedloader", gun, mockMag(6, 0)) })
    return Assert.isNil(cmds[1].familyKey, "a single compatible magazine needs no family")
end

tests["non_magazine_commands_ignored"] = function()
    local gun = mockGun("Base.M16", "M16")
    local cmds = apply({
        magCmd("Insert 20-round", gun, mockMag(20, 0)),
        magCmd("Insert 60-round", gun, mockMag(60, 0)),
        { label = "Eat Apple", source = "Apple", target = {}, params = {} },
        { label = "Sharpen Knife", source = "Knife", target = {}, params = {} },
    })
    if not Assert.equal(familyCount(cmds), 1, "only the magazines form a family") then return false end
    return Assert.isNil(cmds[3].familyKey, "unrelated command is untouched")
end

tests["eject_unload_excluded"] = function()
    local gun = mockGun("Base.M16", "M16")
    -- an eject carries a mag param too, but must NOT join the load family
    local cmds = apply({
        magCmd("Insert 30-round", gun, mockMag(30, 0)),
        magCmd("Insert 60-round", gun, mockMag(60, 0)),
        magCmd("Eject magazine",  gun, mockMag(30, 30)),
    })
    local ejected = cmds[3]
    return Assert.isNil(ejected.familyKey, "eject/unload is excluded from the load family")
end

tests["apply_is_idempotent"] = function()
    local gun = mockGun("Base.M16", "M16")
    local cmds = {
        magCmd("Insert 20-round", gun, mockMag(20, 0)),
        magCmd("Insert 60-round", gun, mockMag(60, 0)),
    }
    apply(cmds); apply(cmds)            -- reuse across opens (cached commands)
    if not Assert.equal(familyCount(cmds), 1, "still one family after re-apply") then return false end
    local n = 0; for _, c in ipairs(cmds) do if c.familyDefault then n = n + 1 end end
    return Assert.equal(n, 1, "exactly one default after re-apply (no double-stamp)")
end

return tests
