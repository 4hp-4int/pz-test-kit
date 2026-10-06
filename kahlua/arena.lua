--[[
    PZTestKit.Arena -- headless one-way combat through the game's own logic.

    A real IsoPlayer swings a real HandWeapon at real IsoZombies standing on
    real map squares. Each swing runs the steps CombatManager.attackCollisionCheck
    runs (CombatManager.java:966-1225), in its order:

      OnWeaponSwing (fired to mod Lua)
      targets: live zombies in weapon range, nearest first, up to getMaxHitCount
      crit:    wielder:setCriticalHit(roll < IsoPlayer:calculateCritChance(target))
      per target:
        damage  = Rand(min,max) * getDamageMod * getHittingMod   (:966-968)
                  two-handed one-handed rule (:970-972), trait reduction (:1003-1005)
        split   = damage / (split++ * 0.5)                       (:1007-1009)
        rangeDel= dist / maxRange * 2, below 0.3 -> 1            (:1012-1031)
        moodles: panic/stress -0.1 per level, endurance/tired multipliers (:1034-1095)
        hit location: CombatManager.applyMeleeHitLocationDamage  (:1139, private)
        IsoZombie.Hit(weapon, wielder, split, false, rangeDel)   (:1161; fires
                  OnHitZombie, OnWeaponHitCharacter, OnPlayerGetDamage; applies
                  damage, death, stagger, knockdown)
        CombatManager.applyMeleeEnduranceLoss                    (:1163)
        OnWeaponHitXp (fired to mod Lua; the engine fires it from Java in game)
        the wear roll: weapon:damageCheck(0, 1, true, true, wielder) -- one roll
                  PER TARGET for melee, as the real per-target loop does

    Engine events the engine fires itself (OnHitZombie, OnZombieDead...) are
    FORWARDED to mod listeners for the arena's lifetime (PZEngine.forwardEvent),
    so a mod's real handlers run exactly as in game. Both RNGs are seeded
    (Lua ZombRand and the engine's Rand), so a run replays.

    MODE: "sp" (default) runs each hit as single player does -- the knockdown
    on a crit (IsoZombie.hitConsequences:4279) and Kill() on death only happen
    when the process is neither server nor client. "server" runs it the way a
    dedicated server does. World lookups always run with the server flag (the
    map is the engine's ServerMap).
    STAMINA: by default the fighter is rested before each swing (no time passes
    headless, so nothing regenerates); each swing's cost is still recorded.
    fatigue = true lets it drain, and the endurance moodle's damage penalty bite.
    A weapon at 0 condition ends the fight (in game it breaks).
    KNOWN GAP: a corpse is not created (IsoDeadBody wants an animation model
    headless); the death, OnZombieDead and every effect before it are real.

    Every swing returns a record and feeds a ledger: damage, kills, crits,
    staggers, knockdowns, fires, wear rolls and condition lost, stamina spent,
    and every event fired.

        local A = PZTestKit.Arena.new{ weapon = "Base.Axe", seed = 7, perks = { Axe = 5, Strength = 5 } }
        A:spawn(3)
        local led = A:fight{ swings = 200, keep = 3 }
        A:close()
]]

PZTestKit = PZTestKit or {}
local Arena = {}
Arena.__index = Arena
PZTestKit.Arena = Arena

Arena.DEFAULT_AT = { x = 12544, y = 3330, z = 0 }   -- an open cemetery tile in Muldraugh's map
Arena.FORWARDED = { "OnHitZombie", "OnZombieDead", "OnWeaponHitCharacter", "OnPlayerGetDamage" }
-- BodyPartType order: Hand_L(0) .. Neck(9) is the melee partHit range (:1131)
local PART_LO, PART_HI = 0, 9
local OFFSETS = { { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 }, { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }

local function try(f, ...) local ok, v = pcall(f, ...); if ok then return v end end

function Arena.available()
    return PZEngine and PZEngine.available and PZEngine.available() and PZEngine.hit ~= nil and PZEngine.forwardEvent ~= nil
end

local function asServer(self, f)
    PZEngine.setServer(true)
    local ok, a, b = pcall(f)
    PZEngine.setServer(self.wasServer or false)
    if not ok then error(a, 0) end
    return a, b
end

local function newLedger()
    -- kills = OnZombieDead events seen; deaths = zombies the arena saw die.
    -- They should match; a gap means the death event did not reach Lua.
    return { swings = 0, hits = 0, kills = 0, deaths = 0, damage = 0, crits = 0, staggers = 0, knockdowns = 0, fires = 0,
             wearRolls = 0, conditionLost = 0, staminaSpent = 0, misses = 0, corpsesSkipped = 0, broke = false,
             shots = 0, shotHits = 0, shotMisses = 0, jams = 0, reloads = 0, ammoUsed = 0, hitChanceSum = 0,
             sounds = 0, soundRadiusSum = 0, soundRadiusMax = 0, events = {}, errors = {} }
end

function Arena.new(opts)
    if not Arena.available() then error("Arena: this kit's engine bridge lacks hit/forwardEvent (rebuild the kit, restart the VM)", 0) end
    opts = opts or {}
    local self = setmetatable({ opts = opts, zombies = {}, ledger = newLedger(), records = {}, forwards = {}, wasServer = false,
                                mode = opts.mode or "sp" }, Arena)
    local at = opts.at or Arena.DEFAULT_AT
    self.at = at
    -- seeds: Lua rolls (ZombRand, used for the damage roll and crit) and the engine's Rand
    self.seed = opts.seed
    if self.seed then
        if PZTestKit.Random and PZTestKit.Random.seeded then PZTestKit.Random.seeded(self.seed) end
        PZEngine.seedRand(self.seed)
    end
    asServer(self, function()
        if PZEngine.loadWorld then PZEngine.loadWorld() end
        -- the entity system: without it equipping an item dies of an NPE (see initEntities)
        if PZEngine.initEntities then
            local okE, errE = PZEngine.initEntities()
            if not okE then error("Arena: entity system would not start: " .. tostring(errE), 0) end
        end
        if PZEngine.loadCell then
            local cx, cy = math.floor(at.x / 256), math.floor(at.y / 256)
            local lx, ly = math.floor((at.x % 256) / 8), math.floor((at.y % 256) / 8)
            PZEngine.loadCell(cx, cy, math.max(0, lx - 2), math.max(0, ly - 2), math.min(31, lx + 2), math.min(31, ly + 2))
        end
        self.cell = PZEngine.cell()
        local sq = self.cell:getGridSquare(at.x, at.y, at.z)
        if not sq then error("Arena: no square at " .. at.x .. "," .. at.y .. " (map not loaded?)", 0) end
        local p = opts.player or PZEngine.newPlayer()
        p:setX(at.x + 0.5); p:setY(at.y + 0.5); p:setZ(at.z)
        pcall(function() p:setCurrent(sq) end)
        self.player = p
        for name, lvl in pairs(opts.perks or {}) do
            local perk = Perks and Perks[name]
            if perk then pcall(function() p:setPerkLevelDebug(perk, lvl) end) end
        end
        local w = opts.weapon or "Base.Axe"
        if type(w) == "string" then w = PZEngine.instanceItem(w) end
        if not w then error("Arena: no weapon", 0) end
        self.weapon = w
        -- in hand the way the game puts it there: in the inventory first
        pcall(function() if not p:getInventory():contains(w) then p:getInventory():AddItem(w) end end)
        local okEq, eqErr = pcall(function() p:setPrimaryHandItem(w) end)
        if try(function() return w:isTwoHandWeapon() end) and opts.twoHands ~= false then pcall(function() p:setSecondaryHandItem(w) end) end
        if p:getPrimaryHandItem() ~= w then
            error("Arena: the weapon would not go in hand (" .. tostring(okEq and "no error" or eqErr) .. "); crit, two-handed and skill maths all read the hand", 0)
        end
    end)
    -- engine events reach mod listeners while the arena is open
    for _, name in ipairs(opts.forward or Arena.FORWARDED) do
        local fn = function(...)
            local c = self.current
            if c then c.events[#c.events + 1] = name end
            self.ledger.events[name] = (self.ledger.events[name] or 0) + 1
            if name == "OnZombieDead" then self.ledger.kills = self.ledger.kills + 1; if c then c.kills = c.kills + 1 end end
            if triggerEvent then triggerEvent(name, ...) end
        end
        local ok, err = PZEngine.forwardEvent(name, fn)
        if ok then self.forwards[name] = fn else self.ledger.errors[#self.ledger.errors + 1] = "forward " .. name .. ": " .. tostring(err) end
    end
    return self
end

-- zombies on the squares around the player, ring by ring
function Arena:spawn(n, opts)
    opts = opts or {}
    asServer(self, function()
        local placed = 0
        for _, o in ipairs(OFFSETS) do
            if placed >= n then break end
            local x, y = self.at.x + o[1] * (opts.distance or 1), self.at.y + o[2] * (opts.distance or 1)
            local taken = false
            for _, z in ipairs(self.zombies) do if not z:isDead() and math.floor(z:getX()) == x and math.floor(z:getY()) == y then taken = true end end
            if not taken then
                local sq = self.cell:getGridSquare(x, y, self.at.z)
                if sq then
                    local z = PZEngine.newZombie(sq)
                    pcall(function() z:setX(x + 0.5); z:setY(y + 0.5); z:setZ(self.at.z); z:setCurrent(sq) end)
                    if opts.health then z:setHealth(opts.health) end
                    if opts.setup then opts.setup(z) end
                    self.zombies[#self.zombies + 1] = z
                    placed = placed + 1
                end
            end
        end
    end)
    return self
end

function Arena:alive()
    local out = {}
    for _, z in ipairs(self.zombies) do if not z:isDead() then out[#out + 1] = z end end
    return out
end

local function soundMark()
    local _, n = PZEngine.sounds(1e9)
    return n or 0
end
local function takeSounds(self, rec, since)
    local list = PZEngine.sounds(since) or {}
    local L = self.ledger
    rec.sounds = {}
    for _, snd in ipairs(list) do
        rec.sounds[#rec.sounds + 1] = snd.radius
        L.sounds = L.sounds + 1
        L.soundRadiusSum = L.soundRadiusSum + snd.radius
        if snd.radius > L.soundRadiusMax then L.soundRadiusMax = snd.radius end
    end
end

local function dist(p, z)
    local dx, dy = z:getX() - p:getX(), z:getY() - p:getY()
    return math.sqrt(dx * dx + dy * dy)
end

local function moodle(p, kind)
    return try(function() return p:getMoodles():getMoodleLevel(MoodleType[kind]) end) or 0
end
local MOODLE_MULT = { [0] = 1, 0.5, 0.2, 0.1, 0.05 }

-- one melee swing, the attackCollisionCheck way
function Arena:swing(opts)
    opts = opts or {}
    local p, w, L = self.player, self.weapon, self.ledger
    local rec = { n = L.swings + 1, targets = {}, events = {}, kills = 0, crit = false }
    self.current = rec
    local mark = soundMark()
    asServer(self, function()
        L.swings = L.swings + 1
        if not self.opts.fatigue then pcall(function() p:getStats():set(CharacterStat.ENDURANCE, 1.0) end) end
        if triggerEvent then triggerEvent("OnWeaponSwing", p, w) end
        rec.events[#rec.events + 1] = "OnWeaponSwing"
        local maxRange = try(function() return w:getMaxRange(p) end) or w:getMaxRange()
        local cand = {}
        for _, z in ipairs(self:alive()) do
            local d = dist(p, z)
            if d <= maxRange + 0.0001 then cand[#cand + 1] = { z = z, d = d } end
        end
        table.sort(cand, function(a, b) return a.d < b.d end)
        local maxHit = try(function() return w:getMaxHitCount() end) or 1
        if #cand == 0 then L.misses = L.misses + 1; return end
        -- crit: one roll for the swing against the first target
        local chance = try(function() return p:calculateCritChance(cand[1].z) end) or 0
        if opts.forceCrit ~= nil then rec.crit = opts.forceCrit else rec.crit = ZombRand(100) < chance end
        rec.critChance = chance
        L.critChanceSum = (L.critChanceSum or 0) + (tonumber(chance) or 0)
        p:setCriticalHit(rec.crit)
        if rec.crit then L.crits = L.crits + 1 end
        local minD, maxD = w:getMinDamage(), w:getMaxDamage()
        local split = 1
        for i = 1, math.min(maxHit, #cand) do
            local z, d = cand[i].z, cand[i].d
            local t = { hp0 = z:getHealth(), cond0 = w:getCondition() }
            t.stam0 = try(function() return p:getStats():get(CharacterStat.ENDURANCE) end)
            local damage = minD + (maxD - minD) * ZombRandFloat(0, 1)
            damage = damage * (try(function() return w:getDamageMod(p) end) or 1) * (try(function() return p:getHittingMod() end) or 1)
            local twoHanded = not w:isTwoHandWeapon() or (try(function() return p:isItemInBothHands(w) end) or false)
            if not twoHanded and maxD > minD then damage = damage - minD end
            damage = damage * (try(function() return p:getCharacterTraits():getTraitDamageDealtReductionModifier() end) or 1)
            local dmgSplit = damage / (split * 0.5)
            split = split + 1
            local rangeDel = d / maxRange * 2
            if rangeDel < 0.3 then rangeDel = 1 end
            if moodle(p, "PANIC") > 1 then dmgSplit = dmgSplit - moodle(p, "PANIC") * 0.1 end
            if moodle(p, "STRESS") > 1 then dmgSplit = dmgSplit - moodle(p, "STRESS") * 0.1 end
            if dmgSplit < 0 then dmgSplit = 0.1 end
            dmgSplit = dmgSplit * (MOODLE_MULT[moodle(p, "ENDURANCE")] or 1) * (MOODLE_MULT[moodle(p, "TIRED")] or 1)
            local partHit = PART_LO + ZombRand(PART_HI - PART_LO + 1)
            local loc, locErr = PZEngine.meleeHitLocation(z, w, partHit, 0, false, dmgSplit)
            if loc then dmgSplit = loc elseif locErr then L.errors[#L.errors + 1] = "hitLocation: " .. tostring(locErr) end
            t.split, t.rangeDel = dmgSplit, rangeDel
            -- the swing's own noise, as attackCollisionCheck makes it per target (:1110-1120)
            pcall(function()
                p:addWorldSoundUnlessInvisible(8, 8, false)
                if ZombRand(3) ~= 0 then
                    if ZombRand(7) == 0 then p:addWorldSoundUnlessInvisible(16, 16, false) end
                else
                    p:addWorldSoundUnlessInvisible(10, 10, false)
                end
            end)
            if self.mode == "sp" then PZEngine.setServer(false) end
            local dealt, hitErr = PZEngine.hit(z, w, p, dmgSplit, false, rangeDel)
            if self.mode == "sp" then PZEngine.setServer(true) end
            if hitErr then
                if tostring(hitErr):find("IsoDeadBody", 1, true) then L.corpsesSkipped = L.corpsesSkipped + 1
                else L.errors[#L.errors + 1] = "hit: " .. tostring(hitErr) end
            end
            dealt = dealt or 0
            pcall(function() CombatManager.getInstance():applyMeleeEnduranceLoss(p, z, w, dealt) end)
            if triggerEvent then triggerEvent("OnWeaponHitXp", p, w, z, dmgSplit, 1) end
            -- the wear roll, once per target
            local cBefore = w:getCondition()
            pcall(function() w:damageCheck(0, 1.0, true, true, p) end)
            L.wearRolls = L.wearRolls + 1
            t.cond1 = w:getCondition()
            if t.cond1 < cBefore then L.conditionLost = L.conditionLost + (cBefore - t.cond1) end
            if t.cond1 <= 0 then L.broke = true; rec.broke = true end
            -- what the hit did
            t.hp1, t.dead = z:getHealth(), z:isDead()
            t.dealt = t.hp0 - t.hp1
            if t.dead and t.hp0 > 0 then L.deaths = L.deaths + 1 end
            t.stagger = try(function() return z:isStaggerBack() end) or false
            t.knockdown = try(function() return z:isKnockedDown() end) or false
            t.fire = try(function() return z:isOnFire() end) or false
            t.stam1 = try(function() return p:getStats():get(CharacterStat.ENDURANCE) end)
            if t.stam0 and t.stam1 and t.stam1 < t.stam0 then L.staminaSpent = L.staminaSpent + (t.stam0 - t.stam1) end
            L.hits = L.hits + 1
            L.damage = L.damage + math.max(0, t.dealt)
            if t.stagger then L.staggers = L.staggers + 1 end
            if t.knockdown then L.knockdowns = L.knockdowns + 1 end
            if t.fire then L.fires = L.fires + 1 end
            rec.targets[#rec.targets + 1] = t
            if rec.broke then break end
        end
    end)
    takeSounds(self, rec, mark)
    self.current = nil
    self.records[#self.records + 1] = rec
    if #self.records > 2000 then table.remove(self.records, 1) end
    if opts.after then opts.after(rec, self) end
    return rec
end

-- ---------------------------------------------------------------------------
-- FIREARMS: one shot, vanilla's way.
--   ready     a jam is cleared and an empty gun reloaded instantly (the
--             player's rack/reload stand-in), both counted
--   sound     ISReloadWeaponAction.attackHook: soundRadius x FirearmNoiseMultiplier,
--             halved indoors, addWorldSoundUnlessInvisible(radius, volume)
--   ammo/jam  ISReloadWeaponAction.onShoot (OnWeaponSwingHitPoint): chamber,
--             ammo, and the REAL jam roll (HandWeapon.checkJam); vanilla's own
--             onShoot runs instead when it is loaded
--   hit       CombatManager.calculateHitChanceData (the game's to-hit chance),
--             calculateCritChance, Rand(min,max), processHit (body part),
--             applyRangeHitLocationDamage, IsoZombie.Hit
--   wear      one roll per SHOT, after the targets (CombatManager:1224-1225)
--   rack      rack-after-shoot guns (shotguns) chamber the next round and
--             roll the jam, as ISRackFirearm does
-- ---------------------------------------------------------------------------
local function noiseMult()
    return try(function() return getSandboxOptions():getOptionByName("FirearmNoiseMultiplier"):getValue() end) or 1
end

function Arena:shoot(opts)
    opts = opts or {}
    local p, w, L = self.player, self.weapon, self.ledger
    local rec = { n = L.shots + 1, gun = true, targets = {}, events = {}, kills = 0, crit = false }
    self.current = rec
    local mark = soundMark()
    asServer(self, function()
        L.shots = L.shots + 1
        L.swings = L.swings + 1
        if not self.opts.fatigue then pcall(function() p:getStats():set(CharacterStat.ENDURANCE, 1.0) end) end
        local per = try(function() return w:getAmmoPerShoot() end) or 1
        -- ready the gun
        if w:isJammed() then w:setJammed(false); rec.unjammed = true end
        if w:haveChamber() and not w:isRoundChambered() and w:getCurrentAmmoCount() >= per then
            w:setRoundChambered(true); w:setCurrentAmmoCount(w:getCurrentAmmoCount() - per)
        end
        local empty = (w:haveChamber() and not w:isRoundChambered()) or ((not w:haveChamber()) and w:getCurrentAmmoCount() < per)
        if empty then
            w:setCurrentAmmoCount(w:getMaxAmmo())
            if w:haveChamber() then w:setRoundChambered(true); w:setCurrentAmmoCount(w:getMaxAmmo() - per) end
            L.reloads = L.reloads + 1; rec.reloaded = true
        end
        -- the shot's sound
        local radius = w:getSoundRadius() * noiseMult()
        if not (try(function() return p:isOutside() end) or false) then radius = radius * 0.5 end
        pcall(function() p:addWorldSoundUnlessInvisible(radius, w:getSoundVolume(), true) end)
        rec.radius = radius
        if triggerEvent then triggerEvent("OnWeaponSwing", p, w) end
        -- ammo + jam
        local ammo0 = w:getCurrentAmmoCount() + ((w:haveChamber() and w:isRoundChambered()) and per or 0)
        local vanillaShoot = ISReloadWeaponAction and ISReloadWeaponAction.onShoot
        if not vanillaShoot then
            if w:haveChamber() then w:setRoundChambered(false); w:setSpentRoundChambered(true) end
            if not w:isRackAfterShoot() then
                if not w:isManuallyRemoveSpentRounds() then w:setSpentRoundChambered(false) end
                if w:getCurrentAmmoCount() >= per then
                    if w:haveChamber() then w:setRoundChambered(true) end
                    w:setCurrentAmmoCount(w:getCurrentAmmoCount() - per)
                    if w:getJamGunChance() > 0 then w:checkJam(p, false) end
                end
            end
            if w:isManuallyRemoveSpentRounds() then w:setSpentRoundCount(w:getSpentRoundCount() + per) end
        end
        if triggerEvent then triggerEvent("OnWeaponSwingHitPoint", p, w) end
        local ammo1 = w:getCurrentAmmoCount() + ((w:haveChamber() and w:isRoundChambered()) and per or 0)
        if ammo0 > ammo1 then L.ammoUsed = L.ammoUsed + (ammo0 - ammo1) end
        if w:isJammed() then L.jams = L.jams + 1; rec.jammed = true end
        -- targets in range
        local maxRange = try(function() return w:getMaxRange(p) end) or w:getMaxRange()
        local cand = {}
        for _, z in ipairs(self:alive()) do
            local d = dist(p, z)
            if d <= maxRange + 0.0001 then cand[#cand + 1] = { z = z, d = d } end
        end
        table.sort(cand, function(a, b) return a.d < b.d end)
        if #cand == 0 then L.misses = L.misses + 1; return end
        local cm = CombatManager.getInstance()
        local hcd, hcErr = PZEngine.call(cm, "calculateHitChanceData", p, w, nil)
        local chance = hcd and PZEngine.field(hcd, "hitChance") or nil
        if not chance then L.errors[#L.errors + 1] = "hitChance: " .. tostring(hcErr); chance = w:getHitChance() end
        rec.hitChance = chance
        L.hitChanceSum = L.hitChanceSum + chance
        local critChance = try(function() return p:calculateCritChance(cand[1].z) end) or 0
        if opts.forceCrit ~= nil then rec.crit = opts.forceCrit else rec.crit = ZombRand(100) < critChance end
        rec.critChance = critChance
        L.critChanceSum = (L.critChanceSum or 0) + critChance
        p:setCriticalHit(rec.crit)
        if rec.crit then L.crits = L.crits + 1 end
        local maxHit = try(function() return w:getMaxHitCount() end) or 1
        local rangeDel = ((try(function() return w:isRangeFalloff() end)) and 1 or 0.5) * 2
        local hitAny = false
        for i = 1, math.min(maxHit, #cand) do
            local z = cand[i].z
            if ZombRand(100) < chance then
                hitAny = true
                local t = { hp0 = z:getHealth() }
                local dmg = w:getMinDamage() + (w:getMaxDamage() - w:getMinDamage()) * ZombRandFloat(0, 1)
                local part = try(function() return cm:processHit(w, p, z) end)
                if part then
                    local loc, locErr = PZEngine.call(cm, "applyRangeHitLocationDamage", z, w, part, dmg)
                    if loc then dmg = loc elseif locErr then L.errors[#L.errors + 1] = "rangeLocation: " .. tostring(locErr) end
                end
                if self.mode == "sp" then PZEngine.setServer(false) end
                local _, hitErr = PZEngine.hit(z, w, p, dmg, false, rangeDel)
                if self.mode == "sp" then PZEngine.setServer(true) end
                if hitErr and not tostring(hitErr):find("IsoDeadBody", 1, true) then L.errors[#L.errors + 1] = "hit: " .. tostring(hitErr) end
                if triggerEvent then triggerEvent("OnWeaponHitXp", p, w, z, dmg, 1) end
                t.hp1, t.dead = z:getHealth(), z:isDead()
                t.dealt = t.hp0 - t.hp1
                if t.dead and t.hp0 > 0 then L.deaths = L.deaths + 1 end
                t.stagger = try(function() return z:isStaggerBack() end) or false
                t.knockdown = try(function() return z:isKnockedDown() end) or false
                t.fire = try(function() return z:isOnFire() end) or false
                L.hits = L.hits + 1; L.shotHits = L.shotHits + 1
                L.damage = L.damage + math.max(0, t.dealt)
                if t.stagger then L.staggers = L.staggers + 1 end
                if t.knockdown then L.knockdowns = L.knockdowns + 1 end
                if t.fire then L.fires = L.fires + 1 end
                rec.targets[#rec.targets + 1] = t
            end
        end
        if not hitAny then L.shotMisses = L.shotMisses + 1 end
        -- wear: one roll per shot
        local c0 = w:getCondition()
        pcall(function() w:damageCheck(0, 1.0, false, true, p) end)
        L.wearRolls = L.wearRolls + 1
        if w:getCondition() < c0 then L.conditionLost = L.conditionLost + (c0 - w:getCondition()) end
        if w:getCondition() <= 0 then L.broke = true; rec.broke = true end
        -- rack-after-shoot (shotguns): chamber the next round, roll the jam
        if w:isRackAfterShoot() and w:getCurrentAmmoCount() >= per and not w:isJammed() then
            w:setSpentRoundChambered(false)
            w:setRoundChambered(true); w:setCurrentAmmoCount(w:getCurrentAmmoCount() - per)
            if w:getJamGunChance() > 0 then w:checkJam(p, false) end
            if w:isJammed() then L.jams = L.jams + 1; rec.jammed = true end
        end
    end)
    takeSounds(self, rec, mark)
    self.current = nil
    self.records[#self.records + 1] = rec
    if #self.records > 2000 then table.remove(self.records, 1) end
    if opts.after then opts.after(rec, self) end
    return rec
end


-- swing until `swings` swings (or `kills` kills), keeping `keep` zombies standing
function Arena:fight(opts)
    opts = opts or {}
    local swings, keep = opts.swings or 100, opts.keep
    for _ = 1, swings do
        if keep then
            local a = #self:alive()
            if a < keep then self:spawn(keep - a, opts.spawn) end
        end
        if #self:alive() == 0 and not keep then break end
        if self.weapon:isRanged() then self:shoot(opts) else self:swing(opts) end
        if opts.kills and self.ledger.kills >= opts.kills then break end
        if self.ledger.broke then break end
    end
    return self:summary()
end

function Arena:summary()
    local L = self.ledger
    local s = {}
    for k, v in pairs(L) do s[k] = v end
    s.condition = self.weapon:getCondition()
    s.conditionMax = self.weapon:getConditionMax()
    s.swingsPerKill = L.kills > 0 and (math.floor(L.swings / L.kills * 100 + 0.5) / 100) or nil
    s.damagePerHit = L.hits > 0 and (math.floor(L.damage / L.hits * 1000 + 0.5) / 1000) or 0
    s.soundRadiusMean = L.sounds > 0 and (math.floor(L.soundRadiusSum / L.sounds * 100 + 0.5) / 100) or 0
    s.hitRate = L.shots > 0 and (math.floor(L.shotHits / L.shots * 1000 + 0.5) / 1000) or nil
    s.jamRate = L.shots > 0 and (math.floor(L.jams / L.shots * 10000 + 0.5) / 10000) or nil
    return s
end

function Arena:close()
    for name, fn in pairs(self.forwards) do pcall(PZEngine.unforwardEvent, name, fn) end
    self.forwards = {}
    if self.seed then pcall(PZEngine.seedRand, nil) end
    for _, z in ipairs(self.zombies) do
        pcall(function() if not z:isDead() then z:removeFromWorld() end end)
    end
    self.zombies = {}
    PZEngine.setServer(false)
end

return Arena
