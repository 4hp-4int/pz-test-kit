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
    CLOCK: each swing or shot takes secondsPerSwing REAL seconds (default 1).
    The arena keeps real seconds (A:now()) and advances the engine's GameTime
    by the matching game time (real x 1440 / GameTime:getMinutesPerDay()), then
    fires OnTick and OnPlayerUpdate to mod Lua and runs timers that fell due
    (A:at(delay, fn)). So "for 20 seconds", cooldowns and night/day gates run
    on a clock that really moves.
    COMBAT (combat = true; docs/melee-combat-rules.md): a fight as a real
    character has it, from the engine's own rules where it exposes them.
      cost     CombatManager.processWeaponEndurance every swing (hit or miss,
               :1267) on top of applyMeleeEnduranceLoss per target hit (:3900)
      moodles  Moodles:Update() before each swing and on every clock step, so
               the Endurance / Tired moodles really rise and their damage
               (x0.5 / 0.2 / 0.1 / 0.05) and speed penalties bite. (Headless,
               nothing else updates them: without this a drained fighter hit
               at full strength.)
      time     a swing takes clip / calculateCombatSpeed() (the engine's own,
               IsoGameCharacter.java:10362: weapon, skill, Fitness, moodles,
               its random factor) plus the melee delay (12, or 8 for knives
               and spears, draining at 30/s). Clip: 1.0 s, 2.5 s for Heavy.
      regen    each clock step, standing still: +0.000031 x EndRegen x
               getRecoveryMod (Fitness) x (1 - 0.85 x fatigue) x 48 per real
               second (IsoPlayer.updateEndurance :3350, at 1x speed)
      xp       per target hit, as XpUpdate.lua's OnWeaponHitXp handler and
               processMaintenanceCheck do (that one needs a live attack
               animation, so it is mirrored): each weapon category min(3,
               0.9 x damageSplit), Fitness +1 while endurance > 0.5, Strength
               +1, Maintenance 2.0 (20 / CLC above CLC 10) half the time,
               through the engine's XP.AddXP (its boosts and level thresholds)
    Arena:life{...} runs encounter after encounter, resting between them,
    until the weapon breaks; it reports kills, swings, time, the skills grown
    and the time spent tired.
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
                                mode = opts.mode or "sp", realSeconds = 0, timers = {}, spawned = {} }, Arena)
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
                    -- in the cell's zombie list, as the game's own are (code that looks
                    -- around the player -- a chain, an area stagger -- searches it)
                    pcall(function() if not self.cell:getZombieList():contains(z) then self.cell:getZombieList():add(z) end end)
                    if opts.health then z:setHealth(opts.health) end
                    if opts.setup then opts.setup(z) end
                    self.zombies[#self.zombies + 1] = z
                    -- every zombie ever spawned, so close() cleans up even the ones a test
                    -- dropped from self.zombies (A.zombies = {} to start a fresh phase)
                    self.spawned[#self.spawned + 1] = z
                    placed = placed + 1
                end
            end
        end
    end)
    return self
end

-- ---------------------------------------------------------------------------
-- the clock
-- ---------------------------------------------------------------------------
function Arena:now() return self.realSeconds end

local function gameSecondsPerReal()
    local mpd = try(function() return PZEngine.gameTime():getMinutesPerDay() end) or 60
    return 1440 / math.max(1, mpd)   -- 60-minute day: 24 game seconds per real second
end

local function setWorldAge(h)
    local g = PZEngine.gameTime and PZEngine.gameTime()
    if not g then return end
    local nights = math.floor(h / 24)
    local tod = h - nights * 24 + 7
    if tod >= 24 then tod = tod - 24 end
    g:setNightsSurvived(nights)
    g:setTimeOfDay(tod)
end

function Arena:advance(seconds)
    seconds = seconds or 1
    self.realSeconds = self.realSeconds + seconds
    if self.opts.combat then self:_combatTick(seconds) end   -- defined with the combat helpers, below
    local g = PZEngine.gameTime and PZEngine.gameTime()
    if g then setWorldAge(g:getWorldAgeHours() + seconds * gameSecondsPerReal() / 3600) end
    if triggerEvent then
        pcall(triggerEvent, "OnTick", 0)
        pcall(triggerEvent, "OnPlayerUpdate", self.player)
    end
    local due, keep = {}, {}
    for _, t in ipairs(self.timers) do
        if t.at <= self.realSeconds then due[#due + 1] = t else keep[#keep + 1] = t end
    end
    self.timers = keep
    table.sort(due, function(a, b) return a.at < b.at end)
    for _, t in ipairs(due) do
        local ok, err = pcall(t.fn, self)
        if not ok then self.ledger.errors[#self.ledger.errors + 1] = "timer: " .. tostring(err) end
    end
end

function Arena:at(delay, fn)
    self.timers[#self.timers + 1] = { at = self.realSeconds + (delay or 0), fn = fn }
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

-- ---------------------------------------------------------------------------
-- combat mode helpers (docs/melee-combat-rules.md)
-- ---------------------------------------------------------------------------
-- the weapon's categories as SKILL names. getWeaponCategories() holds ids
-- ("base:blunt"); getCategories is not exposed, and WeaponCategory is not a Lua
-- global, so the ids are mapped here.
local CATEGORY_PERK = { ["base:blunt"] = "Blunt", ["base:smallblunt"] = "SmallBlunt", ["base:axe"] = "Axe",
                        ["base:longblade"] = "LongBlade", ["base:smallblade"] = "SmallBlade", ["base:spear"] = "Spear" }
local function categories(w)
    local out = {}
    pcall(function()
        local it = w:getScriptItem():getWeaponCategories():iterator()
        while it:hasNext() do
            local perk = CATEGORY_PERK[tostring(it:next())]
            if perk then out[#out + 1] = perk end
        end
    end)
    return out
end
Arena._categories = categories

local function refreshMoodles(p) pcall(function() p:getMoodles():Update() end) end

--- Seconds one melee swing takes for this fighter, weapon and state.
function Arena:swingSeconds()
    local p, w = self.player, self.weapon
    local clip = 1.0
    pcall(function() if tostring(w:getSwingAnim()) == "Heavy" then clip = 2.5 end end)
    local cs = try(function() return p:calculateCombatSpeed() end) or 1
    if not cs or cs <= 0 then cs = 1 end
    local delay = 12
    for _, c in ipairs(categories(w)) do if c == "SmallBlade" or c == "Spear" then delay = 8 end end
    return clip / cs + delay / 30
end

local function regen(self, seconds)
    local p = self.player
    pcall(function()
        local st = p:getStats()
        local endRegen = try(function() return getSandboxOptions():getEnduranceRegenMultiplier() end) or 1.0
        local rec = try(function() return p:getRecoveryMod() end) or 1.0
        local fatigue = try(function() return st:get(CharacterStat.FATIGUE) end) or 0
        local add = 0.000031 * endRegen * rec * (1 - 0.85 * fatigue) * 48 * seconds
        st:set(CharacterStat.ENDURANCE, math.min(1, (st:get(CharacterStat.ENDURANCE) or 0) + add))
    end)
end

--- The combat mode's share of a clock step: regen, the moodles, time spent tired.
function Arena:_combatTick(seconds)
    regen(self, seconds)
    refreshMoodles(self.player)
    if moodle(self.player, "ENDURANCE") >= 1 then
        self.ledger.tiredSeconds = (self.ledger.tiredSeconds or 0) + seconds
    end
end

local function addXp(p, perkName, amount)
    if not (amount and amount > 0) then return end
    local perk = Perks and Perks[perkName]
    -- the 5-argument form: AddXP(perk, amount) only acts for the LOCAL player
    -- (IsoGameCharacter.java:18222), which a headless player is not; doXPBoost
    -- keeps the engine's multipliers (x0.25 without a profession boost)
    if perk then pcall(function() p:getXp():AddXP(perk, amount, false, true, false) end) end
end

local function hitXp(self, dmgSplit)
    local p, w = self.player, self.weapon
    local exp = math.min(3, (dmgSplit or 0) * 0.9)
    for _, c in ipairs(categories(w)) do addXp(p, c, exp) end
    local endurance = try(function() return p:getStats():get(CharacterStat.ENDURANCE) end) or 0
    if endurance > 0.5 then addXp(p, "Fitness", 1) end
    addXp(p, "Strength", 1)
    if ZombRand(2) == 0 then
        local twoInOne = w:isTwoHandWeapon() and not (try(function() return p:isItemInBothHands(w) end) or false)
        if not (twoInOne and ZombRand(3) == 0) then
            local clc = w:getConditionLowerChance()
            addXp(p, "Maintenance", (clc > 10) and (2.0 * 10 / clc) or 2.0)
        end
    end
end

-- one melee swing, the attackCollisionCheck way
function Arena:swing(opts)
    opts = opts or {}
    local p, w, L = self.player, self.weapon, self.ledger
    local rec = { n = L.swings + 1, t = self.realSeconds, targets = {}, events = {}, kills = 0, crit = false }
    self.current = rec
    local mark = soundMark()
    asServer(self, function()
        L.swings = L.swings + 1
        local combat = self.opts.combat
        if not (self.opts.fatigue or combat) then pcall(function() p:getStats():set(CharacterStat.ENDURANCE, 1.0) end) end
        if combat then
            refreshMoodles(p)
            local e0 = try(function() return p:getStats():get(CharacterStat.ENDURANCE) end)
            pcall(function() CombatManager.getInstance():processWeaponEndurance(p, w) end)
            local e1 = try(function() return p:getStats():get(CharacterStat.ENDURANCE) end)
            if e0 and e1 and e1 < e0 then L.staminaSpent = L.staminaSpent + (e0 - e1) end
        end
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
        rec.minD, rec.maxD = minD, maxD
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
            if self.opts.combat then hitXp(self, dmgSplit) end
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
    if triggerEvent then pcall(triggerEvent, "OnPlayerAttackFinished", p, w) end
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
    if triggerEvent then pcall(triggerEvent, "OnPlayerAttackFinished", p, w) end
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
        local secs = opts.secondsPerSwing or self.opts.secondsPerSwing
        if not secs and self.opts.combat and not self.weapon:isRanged() then secs = self:swingSeconds() end
        if self.weapon:isRanged() then self:shoot(opts) else self:swing(opts) end
        self:advance(secs or 1)
        if opts.kills and self.ledger.kills >= opts.kills then break end
        if self.ledger.broke then break end
    end
    return self:summary()
end

--- Zombies step back in: any live zombie out of the weapon's reach (a stagger
--- or knockdown moves it, and in this one-way arena it never walks back) is put
--- on a free tile beside the fighter, as it would close in during a real fight.
--- Returns how many were moved.
function Arena:closeIn()
    local p, w = self.player, self.weapon
    local reach = try(function() return w:getMaxRange(p) end) or try(function() return w:getMaxRange() end) or 1
    local moved = 0
    asServer(self, function()
        for _, z in ipairs(self:alive()) do
            if dist(p, z) > reach + 0.0001 then
                for i = 1, 4 do
                    local o = OFFSETS[i]
                    local x, y = self.at.x + o[1], self.at.y + o[2]
                    local taken = false
                    for _, other in ipairs(self:alive()) do
                        if other ~= z and math.floor(other:getX()) == x and math.floor(other:getY()) == y then taken = true end
                    end
                    if not taken then
                        local sq = self.cell:getGridSquare(x, y, self.at.z)
                        if sq then
                            pcall(function() z:setX(x + 0.5); z:setY(y + 0.5); z:setCurrent(sq) end)
                            moved = moved + 1
                            break
                        end
                    end
                end
            end
        end
    end)
    self.ledger.closedIn = (self.ledger.closedIn or 0) + moved
    return moved
end

--- A WEAPON'S LIFE (combat = true): encounter after encounter until it breaks.
--- opts: group = { min, max } zombies per encounter (default 1..3), rest =
--- seconds of rest between encounters (default 60), repairs = how many times
--- it is repaired when it breaks (each restores 50% / (n + 1) of its max,
--- FixingManager.getCondRepaired), maxKills (default 3000), perks to report.
--- Returns the summary plus { encounters, seconds, repairsUsed, skills = {
--- name = { from, to } } }.
function Arena:life(opts)
    opts = opts or {}
    local p, w, L = self.player, self.weapon, self.ledger
    local gmin, gmax = (opts.group or {})[1] or 1, (opts.group or {})[2] or 3
    local rest, repairs, maxKills = opts.rest or 60, opts.repairs or 0, opts.maxKills or 3000
    local watch = opts.perks or { "Blunt", "SmallBlunt", "Axe", "LongBlade", "SmallBlade", "Spear", "Maintenance", "Fitness", "Strength" }
    -- zombie toughness: the ENGINE's option (new zombies read it for their
    -- health; the Lua SandboxVars table does not reach them), restored after
    -- (getSandboxOptions does not exist headless; PZEngine.sandboxSet does)
    if opts.toughness then pcall(PZEngine.sandboxSet, "ZombieLore.Toughness", opts.toughness) end
    -- BACK OFF: a player stops swinging when exhausted and recovers (the one-way
    -- arena's zombies wait); without it a drained fighter flails at x0.05 damage
    local backOff = opts.backOff or 2
    local skills = {}
    for _, name in ipairs(watch) do
        local perk = Perks and Perks[name]
        if perk then skills[name] = { from = try(function() return p:getPerkLevel(perk) end) or 0 } end
    end
    -- zombie health by toughness, as IsoZombie does at creation (:4477-4490);
    -- headless, the engine's SandboxOptions do not follow the sandbox here
    local HEALTH = { [1] = { 3.5, 0.3 }, [2] = { 1.8, 0.3 }, [3] = { 0.5, 0.3 } }
    local setup = opts.toughness and HEALTH[opts.toughness] and function(z)
        local h = HEALTH[opts.toughness]
        local hp = h[1] + ZombRandFloat(0, h[2])
        z:setHealth(hp)
        L.hpMin = math.min(L.hpMin or hp, hp)
        L.hpMax = math.max(L.hpMax or hp, hp)
    end or nil
    local encounters, used = 0, 0
    while L.kills < maxKills do
        encounters = encounters + 1
        -- an encounter of N, at most four at a time: the four tiles beside the
        -- fighter are the ones in reach (a diagonal is 1.41 tiles, past a bat's
        -- reach, and in this one-way arena zombies never step in)
        local toSpawn = gmin + ZombRand(gmax - gmin + 1)
        local guard = 0
        while (toSpawn > 0 or #self:alive() > 0) and not L.broke and guard < 400 do
            local a = #self:alive()
            if a < 4 and toSpawn > 0 then
                local n = math.min(4 - a, toSpawn)
                self:spawn(n, { setup = setup })
                toSpawn = toSpawn - n
            end
            guard = guard + 1
            self:closeIn()
            if backOff and moodle(p, "ENDURANCE") >= backOff then
                local waited = 0
                while waited < 900 and (try(function() return p:getStats():get(CharacterStat.ENDURANCE) end) or 1) < 0.75 do
                    self:advance(5); waited = waited + 5
                end
                L.backOffSeconds = (L.backOffSeconds or 0) + waited
                L.backOffs = (L.backOffs or 0) + 1
            end
            local secs = self:swingSeconds()
            self:swing(opts)
            self:advance(secs)
        end
        if L.broke then
            if used >= repairs then break end
            used = used + 1
            L.broke = false
            w:setCondition(math.max(1, math.floor(w:getConditionMax() * 0.5 / used + 0.5)))
        end
        -- clear any survivor (the fighter walked away), then rest
        for _, z in ipairs(self:alive()) do pcall(function() z:setHealth(0) end) end
        local left = rest
        while left > 0 do local step = math.min(5, left); self:advance(step); left = left - step end
    end
    for name, sk in pairs(skills) do
        sk.to = try(function() return p:getPerkLevel(Perks[name]) end) or sk.from
        sk.xp = try(function() return p:getXp():getXP(Perks[name]) end) or 0
    end
    if opts.toughness then pcall(PZEngine.sandboxSet, "ZombieLore.Toughness", opts.restoreToughness or 2) end
    local out = self:summary()
    out.encounters, out.seconds, out.repairsUsed, out.skills = encounters, self.realSeconds, used, skills
    out.tiredSeconds, out.backOffs, out.backOffSeconds = L.tiredSeconds or 0, L.backOffs or 0, L.backOffSeconds or 0
    return out
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
    for _, z in ipairs(self.spawned) do
        pcall(function() if not z:isDead() then z:removeFromWorld() end end)
        pcall(function() self.cell:getZombieList():remove(z) end)
    end
    self.zombies, self.spawned = {}, {}
    PZEngine.setServer(false)
end

return Arena
