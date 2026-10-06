--[[
    The Arena: headless one-way combat through the game's own hit pipeline
    (PZTestKit.Arena, kahlua/arena.lua). A real player swings a real weapon at
    real zombies on real squares; the mod's own OnHitZombie / OnZombieDead /
    OnWeaponHitXp listeners run as they do in game.

    Tool:   arenaFight{weapon | ref, zombies, swings, seed, mode, perks, fatigue,
                       records, setup}
              weapon   full type ("Base.Axe") or ref to a live item (a board's
                       weapon, a vpsWeapon result) -- the SAME object is swung,
                       so its affixes, condition and ModData are what fights
              zombies  how many stand around the player (kept topped up)
              mode     "sp" (default) | "server" -- how the hit resolves
              perks    { Axe = 5, Strength = 6 } on the fighter
              records  how many per-swing records to return (default 20)
            -> { summary = ledger, records = last swings, weapon = ref }

    Per swing: damage roll, split, range, moodles, hit location, IsoZombie.Hit,
    swing stamina, OnWeaponHitXp, and the real wear roll per target. Seeded
    (Lua and engine RNG): same args, same fight.
]]


WB.register("arenaFight", function(a)
    a = a or {}
    if not (PZTestKit and PZTestKit.Arena and PZTestKit.Arena.available()) then
        error("the Arena needs this kit's newer engine bridge: restart this VM to load it", 0)
    end
    local weapon = a.weapon
    if a.ref then weapon = WB.deref(a.ref) end
    local A = PZTestKit.Arena.new{ weapon = weapon or "Base.Axe", seed = tonumber(a.seed) or 7, mode = a.mode,
                                   perks = a.perks, fatigue = a.fatigue and true or false }
    local ok, err = pcall(function()
        A:spawn(math.max(1, math.min(tonumber(a.zombies) or 3, 8)))
        A:fight{ swings = math.max(1, math.min(tonumber(a.swings) or 100, 20000)), keep = tonumber(a.zombies) or 3 }
    end)
    local summary = A:summary()
    local recs = {}
    local want = tonumber(a.records) or 20
    for i = math.max(1, #A.records - want + 1), #A.records do
        local r = A.records[i]
        local ts = {}
        for _, t in ipairs(r.targets) do
            ts[#ts + 1] = { dealt = math.floor((t.dealt or 0) * 1000 + 0.5) / 1000, dead = t.dead, stagger = t.stagger,
                            knockdown = t.knockdown, fire = t.fire, cond = t.cond1 }
        end
        recs[#recs + 1] = { n = r.n, crit = r.crit, critChance = r.critChance, kills = r.kills, events = table.concat(r.events, ","), targets = ts }
    end
    local wref = WB.ref(A.weapon)
    A:close()
    if not ok then summary.errors[#summary.errors + 1] = tostring(err) end
    return { summary = summary, records = recs, weapon = wref }
end)
