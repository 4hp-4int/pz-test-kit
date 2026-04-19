--[[
    PZ Test Kit — Fixtures
    ======================
    Pure Lua-table factories for PZ game objects. Method names and return
    types are taken from PZ's decompiled Java source so tests can use them
    interchangeably with real PZ objects in-game.

    Usage:
        local w = PZTestKit.Fixtures.weapon({ maxDamage = 2.0 })
        local z = PZTestKit.Fixtures.zombie({ health = 1.5 })

    The factories live on `PZTestKit.Fixtures` but are also re-exported to
    the global helpers that mock_environment.lua already provides
    (`_pz_create_mock_weapon`, `_pz_create_mock_zombie`) for backwards
    compatibility with tests that call the lower-level API.
]]

PZTestKit = PZTestKit or {}
PZTestKit.Fixtures = PZTestKit.Fixtures or {}

local Fixtures = PZTestKit.Fixtures

--- Weapon fixture — Lua-table mock matching HandWeapon's public method
--- surface. Private state is held in a closure so external writes to
--- `weapon._privateField = x` do NOT change behavior (matching real PZ's
--- Java-object restrictions). To change state a test should call a setter
--- or pass a field via opts at construction time.
---
--- Verified against zombie/inventory/types/HandWeapon.java method names.
---
---@param opts table|nil Overrides: id, isRanged, name, maxDamage, minDamage,
---                      conditionMax, clipSize, maxAmmo, magazineType,
---                      containsClip, sharpness, hasSharpness
---@return table mock HandWeapon
function Fixtures.weapon(opts)
    opts = opts or {}
    local priv = {
        id            = opts.id          or (ZombRand and ZombRand(100000, 999999) or 123456),
        isRanged      = opts.isRanged    or false,
        name          = opts.name        or "MockWeapon",
        maxDamage     = opts.maxDamage   or 1.0,
        minDamage     = opts.minDamage   or 0.5,
        conditionMax  = opts.conditionMax or 10,
        condition     = opts.condition   or (opts.conditionMax or 10),
        clipSize      = opts.clipSize    or 0,
        maxAmmo       = opts.maxAmmo     or 0,
        magazineType  = opts.magazineType or "",
        containsClip  = opts.containsClip or false,
        sharpness     = opts.sharpness   or 1.0,
        hasSharpness  = opts.hasSharpness or false,
        modData       = {},
    }
    local w = { _type = "HandWeapon" }

    -- Identity / type
    w.getID           = function(self) return priv.id end
    w.getName         = function(self) return priv.name end
    w.getDisplayName  = function(self) return priv.name end
    w.getFullType     = function(self) return priv.name end
    w.getType         = function(self) return priv.name end
    w.IsWeapon        = function(self) return true end
    w.isRanged        = function(self) return priv.isRanged end
    w.getModData      = function(self) return priv.modData end

    -- Damage (sharpness-scaled delta for getMaxDamage matches HandWeapon.java)
    w.getMinDamage    = function(self) return priv.minDamage end
    w.setMinDamage    = function(self, v) priv.minDamage = v end
    w.getMaxDamage    = function(self)
        local raw = priv.maxDamage
        if priv.hasSharpness and raw > priv.minDamage then
            return priv.minDamage + (raw - priv.minDamage) * ((priv.sharpness + 1.0) / 2.0)
        end
        return raw
    end
    w.setMaxDamage    = function(self, v) priv.maxDamage = v end

    -- Condition
    w.getCondition    = function(self) return priv.condition end
    w.setCondition    = function(self, v) priv.condition = math.min(v, priv.conditionMax) end
    w.getConditionMax = function(self) return priv.conditionMax end
    w.setConditionMax = function(self, v)
        priv.conditionMax = v
        if priv.condition > v then priv.condition = v end
    end

    -- Sharpness
    w.hasSharpness    = function(self) return priv.hasSharpness end
    w.getSharpness    = function(self) return priv.sharpness end
    w.setSharpness    = function(self, v) priv.sharpness = v end

    -- Firearm / ammo (SyncHandWeaponFieldsPacket.java surface)
    w.getClipSize     = function(self) return priv.clipSize end
    w.setClipSize     = function(self, v) priv.clipSize = v end
    w.getMaxAmmo      = function(self) return priv.maxAmmo end
    w.setMaxAmmo      = function(self, v) priv.maxAmmo = v end
    w.getMagazineType = function(self) return priv.magazineType end
    w.setMagazineType = function(self, v) priv.magazineType = v end
    w.isContainsClip  = function(self) return priv.containsClip end

    -- Fire-on-hit fields (read by combat listeners that manually check traps)
    w.getFireStartingChance = function(self) return priv.fireStartingChance or 0 end
    w.setFireStartingChance = function(self, v) priv.fireStartingChance = v end
    w.getFireStartingEnergy = function(self) return priv.fireStartingEnergy or 0 end
    w.setFireStartingEnergy = function(self, v) priv.fireStartingEnergy = v end

    -- Script item surface for WeaponData.isValidWeapon validation
    w.getScriptItem   = function(self)
        return {
            getFullName    = function() return priv.name end,
            getDisplayName = function() return priv.name end,
            getMaxDamage   = function() return priv.maxDamage end,
            getMinDamage   = function() return priv.minDamage end,
        }
    end

    return w
end

--- Firearm preset — defaults to pistol-like stats. Pure convenience wrapper
--- over Fixtures.weapon({ isRanged = true, ... }).
function Fixtures.firearm(opts)
    opts = opts or {}
    local defaults = {
        isRanged     = true,
        name         = "MockPistol",
        magazineType = "Base.9mmClip",
        clipSize     = 15,
        maxAmmo      = 15,
        maxDamage    = 0.7,
        minDamage    = 0.3,
        conditionMax = 10,
    }
    for k, v in pairs(opts) do defaults[k] = v end
    return Fixtures.weapon(defaults)
end

--- Zombie fixture — matches real IsoZombie's Lua-exposed method surface.
--- Verified against IsoZombie.java / IsoGameCharacter.java / IsoMovingObject.java:
---   getHealth()        → float  (IsoGameCharacter)
---   setHealth(float)            (IsoGameCharacter)
---   isAlive()          → bool   (IsoGameCharacter)
---   isOnFire()         → bool   (IsoGameCharacter)
---   SetOnFire()                 (IsoGameCharacter — note capital S)
---   isCrawling()       → bool   (IsoZombie)
---   isStaggerBack()    → bool   (IsoZombie)
---   setStaggerBack(bool)        (IsoZombie)
---   getOnlineID()      → short  (IsoZombie)
---   getLastHitPart()   → String (IsoZombie)
---   getX/Y/Z()         → float  (IsoMovingObject)
---
---@param opts table|nil Overrides: health, crawling, onFire, id, x, y
---@return table mock IsoZombie
function Fixtures.zombie(opts)
    opts = opts or {}
    local priv = {
        health       = opts.health    or 1.8,
        alive        = opts.health == nil or opts.health > 0,
        onFire       = opts.onFire    or false,
        crawling     = opts.crawling  or false,
        staggerBack  = opts.staggerBack or false,
        id           = opts.id        or (ZombRand and ZombRand(1, 30000) or 42),
        x            = opts.x         or 0.0,
        y            = opts.y         or 0.0,
        z            = opts.z         or 0.0,
        lastHitPart  = opts.lastHitPart or nil,
        attachedItems = {},
    }
    local z = { _type = "IsoZombie" }

    z.getHealth         = function(self) return priv.health end
    z.setHealth         = function(self, v)
        priv.health = v
        priv.alive  = v > 0
    end
    z.isAlive           = function(self) return priv.alive end
    z.isDead            = function(self) return not priv.alive end
    z.isOnFire          = function(self) return priv.onFire end
    z.SetOnFire         = function(self) priv.onFire = true end
    z.setFireSpreadProbability = function(self, v) priv.fireSpread = v end
    z.setFireKillRate   = function(self, v) priv.fireKillRate = v end
    z.isCrawling        = function(self) return priv.crawling end
    z.isStaggerBack     = function(self) return priv.staggerBack end
    z.setStaggerBack    = function(self, v) priv.staggerBack = v end
    z.setStaggerTimeMod = function(self, v) priv.staggerTimeMod = v end
    z.getStaggerTimeMod = function(self) return priv.staggerTimeMod end
    z.getID             = function(self) return priv.id end
    z.getOnlineID       = function(self) return priv.id end
    z.getLastHitPart    = function(self) return priv.lastHitPart end
    z.getX              = function(self) return priv.x end
    z.getY              = function(self) return priv.y end
    z.getZ              = function(self) return priv.z end
    z.getAttachedItem   = function(self, loc) return priv.attachedItems[loc] end
    z.setAttachedItem   = function(self, loc, item) priv.attachedItems[loc] = item end

    return z
end

-- Re-export to the existing globals the mock_environment already uses so
-- test code that calls `_pz_create_mock_zombie` keeps working.
_pz_create_mock_weapon_fixture  = Fixtures.weapon
_pz_create_mock_firearm_fixture = Fixtures.firearm
_pz_create_mock_zombie_fixture  = Fixtures.zombie

-- ============================================================================
-- SKIP SUPPORT
-- ============================================================================
-- A test function that returns `PZTestKit.SKIP` (or a table with
-- `__pztestkit_skip = true`) is recorded as SKIPPED rather than passed or
-- failed. This lets mods mark tests that only work in one environment (e.g.,
-- offline-only tests that synthesize a fake ISHandcraftAction, or in-game-
-- only tests that need real game state) without lying about the result.

PZTestKit.SKIP = { __pztestkit_skip = true, message = "skipped" }

--- Return from a test function to mark it skipped. Optional reason string
--- shows up in test output and JUnit XML.
function PZTestKit.skip(reason)
    return { __pztestkit_skip = true, message = reason or "skipped" }
end

--- Convenience gate: register a test that auto-skips when running in real PZ
--- (no require resolver present), and runs normally under pz-test-kit.
---
--- The environment fingerprint is `_pz_module_sources`, a global populated
--- by pz-test-kit's require_resolver.lua and nil in real PZ.
---
---@param runner VorpallySauced.TestRunner-style runner with .registerSync
---@param name string Test name
---@param fn function Test body (runs only when offline)
function PZTestKit.skipInGame(runner, name, fn)
    if not runner or not runner.registerSync then
        error("PZTestKit.skipInGame: first arg must be a TestRunner-like object", 2)
    end
    runner.registerSync(name, function(self)
        if _pz_module_sources == nil then
            return PZTestKit.skip("offline-only test")
        end
        return fn(self)
    end)
end
