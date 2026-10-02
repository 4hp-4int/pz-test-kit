-- probe-mag-swap-fuzz.lua — VorpallySauced magazine lifecycle, fuzzed LIVE.
--
-- Twin of VorpallySauced/Tests/MagFuzzTests.lua (offline, `pztest
-- --engine-mods`). Same families, ops and invariants, but in the dedi's VM
-- where the gun packs' LUA runs too: SWMG's StatsFactory, VFE's attachment
-- wraps, Modern Firearms' hooks -- all layered over ISInsertMagazine /
-- ISEjectMagazine exactly as on a player's server. Pair with
-- tools/pz-dedicated-docker/presets/gunmods.env.
--
-- Differences from the offline file, on purpose:
--   * No fake configs. Compat flags are whatever the loaded mods set; the
--     header prints them.
--   * VPS's hooks are the PRODUCTION install (OnServerStarted), not
--     _installHooksForTest.
--   * The character is a stub carrying a REAL ItemContainer (no player
--     needs to be connected). The sync globals (sendServerCommand,
--     syncHandWeaponFields, ...) are Java functions that reject a table, so
--     they are swapped for recorders for the duration of this ONE synchronous
--     run and restored after -- the counts are reported.
--
-- Slicing (a probe runs inside one server tick; pz-shell waits 15s):
--   ./pz-shell eval 'MAGFUZZ_OPTS = { from = 1, to = 24, seeds = {1, 7}, steps = 30 }'
--   ./pz-shell eval -f examples/probe-mag-swap-fuzz.lua
-- Defaults: families 1..20, seeds {1}, 30 steps.
--
-- Replaying one failure with full state after every op:
--   ./pz-shell eval 'MAGFUZZ_OPTS = { family = "<magType>", seeds = {7}, trace = true }'
-- NOTE: a live corpus is NOT stable run to run -- framework Lua randomizes a
-- freshly created gun (a Marz AKS74U spawns empty/30 or already holding its
-- 100-round drum with 69 rounds), so a seed replays the op sequence, not the
-- exact starting state. Trace until the failure reappears.

local V = VorpallySauced
local WD, MS, SM = V.WeaponData, V.MagazineSync, V.StatModifiers
local opts = MAGFUZZ_OPTS or {}
local FROM, TO = opts.from or 1, opts.to or 20
local SEEDS, STEPS = opts.seeds or { 1 }, opts.steps or 30
local t0 = getTimestampMs and getTimestampMs() or 0

local out = {}
local function line(s) out[#out + 1] = s end

-- Same-code check: these exist only in the 2026-10-02 build. If either is
-- missing the server is running an older VPS (a Steam/Workshop copy
-- outranking Zomboid\mods) and every number below would describe old code.
if not (MS.resolveEjectState and WD.pristineMagazineCapacity) then
    return "STALE VPS ON SERVER: resolveEjectState/pristineMagazineCapacity missing (VERSION "
        .. tostring(V.VERSION) .. ") -- check mod folder precedence before trusting anything"
end

-- ── Sync globals -> recorders, restored at the end ──────────────────────────
local SWAP = { "sendServerCommand", "syncHandWeaponFields", "syncItemModData", "syncItemFields",
               "sendAddItemToContainer", "sendRemoveItemFromContainer" }
local saved, calls = {}, {}
for _, name in ipairs(SWAP) do
    saved[name] = _G[name]
    calls[name] = 0
    _G[name] = function() calls[name] = calls[name] + 1 end
end

local function run()
    local function noop() end
    local function makeRng(seed)
        local s = (seed * 7919) % 2147483647
        if s <= 0 then s = s + 2147483646 end
        return function(n) s = (s * 16807) % 2147483647; return (s % n) + 1 end
    end

    local CLIP, MAXPCT = {}, 0
    for i, sfx in ipairs(V.FirearmSuffixes) do
        local pct = sfx.stat == "clipSize" and sfx.value or (sfx.stats and sfx.stats.clipSize)
        if pct then CLIP[#CLIP + 1] = { id = i, pct = pct }; if pct > MAXPCT then MAXPCT = pct end end
    end

    -- Families, same selection as the offline file (6 per source mod + all > 40).
    local byType, order = {}, {}
    local items = getScriptManager():getAllItems()
    for i = 0, items:size() - 1 do
        local s = items:get(i)
        if tostring(s:getItemType()) == "base:weapon" then
            local ft = s:getModuleName() .. "." .. s:getName()
            local ok, w = pcall(instanceItem, ft)
            if ok and w and w.isRanged and w:isRanged() and WD.isValidFirearm(w) then
                local mt = w:getMagazineType() or ""
                if mt ~= "" then
                    local okm, mag = pcall(instanceItem, mt)
                    if okm and mag and mag.getMaxAmmo and mag:getMaxAmmo() > 0 then
                        if not byType[mt] then
                            byType[mt] = { magType = mt, cap = mag:getMaxAmmo(), guns = {},
                                           module = s:getModID() or s:getModuleName() }
                            order[#order + 1] = mt
                        end
                        table.insert(byType[mt].guns, ft)
                        -- A gun declaring LESS than its own magazine holds is
                        -- the class that lost rounds (2026-10-02): always fuzz it.
                        if w:getMaxAmmo() < mag:getMaxAmmo() then byType[mt].mism = true end
                    end
                end
            end
        end
    end
    table.sort(order)
    local perMod, fams = {}, {}
    for _, mt in ipairs(order) do
        local f = byType[mt]
        perMod[f.module] = (perMod[f.module] or 0) + 1
        if f.cap > 40 or f.mism or perMod[f.module] <= 6 then fams[#fams + 1] = f end
    end

    local Cm = V.Compat or {}
    line(("== MAG SWAP FUZZ (live) == VPS %s | Compat SWMG=%s DynamicMagazines=%s RAF=%s | families %d-%d of %d (%d total types)"):format(
        tostring(V.VERSION), tostring(Cm.SWMG), tostring(Cm.DynamicMagazines), tostring(Cm.RAF),
        FROM, math.min(TO, #fams), #fams, #order))

    local function magsOf(w)
        local r, its = {}, w.inv:getItems()
        for i = 0, its:size() - 1 do
            local it = its:get(i)
            if it:getFullType() == w.fam.magType then r[#r + 1] = it end
        end
        return r
    end
    -- Rounds are counted in EVERY magazine in the inventory, not just the
    -- family's type: framework Lua randomizes a fresh gun's magazine (SWMG
    -- spawned a Marz AKS74U holding its 30-round mag though its script type
    -- is the 100-round drum), and ejecting that gun yields a mag of the
    -- OTHER type. Counting only the family's type read those rounds as
    -- deleted -- a probe artifact, not a VPS bug (2026-10-02).
    local function total(w)
        local n = 0
        for _, g in ipairs(w.guns) do n = n + g:getCurrentAmmoCount() end
        local its = w.inv:getItems()
        for i = 0, its:size() - 1 do
            local it = its:get(i)
            if it.getCurrentAmmoCount and not instanceof(it, "HandWeapon") then
                n = n + (it:getCurrentAmmoCount() or 0)
            end
        end
        return n
    end
    local function scriptCap(mt) return instanceItem(mt):getMaxAmmo() end

    local function makeWorld(fam, rng)
        local inv = instanceItem("Base.Bag_DuffelBag"):getItemContainer()
        local ch = { getInventory = function() return inv end, removeFromHands = noop,
                     clearVariable = noop, reportEvent = noop, playSound = noop,
                     getPerkLevel = function() return 0 end }
        local w = { ch = ch, inv = inv, fam = fam, guns = {}, log = {}, went = {} }
        for g = 1, 3 do
            local gun = instanceItem(fam.guns[((g - 1) % #fam.guns) + 1])
            local d = WD.getOrCreateModData(gun)
            d.isFirearm = true
            local pick = rng(#CLIP + 1)
            d.suffixId = CLIP[pick] and CLIP[pick].id or nil
            SM.reapplyUpgrades(gun)
            w.guns[g] = gun
        end
        for _ = 1, 3 do
            local m = instanceItem(fam.magType)
            m:setCurrentAmmoCount(m:getMaxAmmo())
            inv:AddItem(m)
        end
        return w
    end

    local OPS = {}
    OPS[#OPS + 1] = { 5, function(w, rng)    -- insert
        local free = {}
        for i, g in ipairs(w.guns) do if not g:isContainsClip() then free[#free + 1] = i end end
        local mags = magsOf(w)
        if #free == 0 or #mags == 0 then return nil end
        local gi = free[rng(#free)]
        local gun, mag = w.guns[gi], mags[rng(#mags)]
        local before = mag:getCurrentAmmoCount()
        w.went[gi] = MS.getMagazineBonus(mag) or 0
        local act = setmetatable({ character = w.ch, gun = gun, magazine = mag }, { __index = ISInsertMagazine })
        act.setAnimVariable, act.setOverrideHandModels, act.setActionAnim, act.initVars = noop, noop, noop, noop
        ISInsertMagazine.start(act); ISInsertMagazine.loadAmmo(act); ISInsertMagazine.complete(act)
        local held = gun:getCurrentAmmoCount()
        local own = WD.calculateClipSizeBonus(gun) or 0
        local loss = before - held
        local allowed = (loss > 0 and held == gun:getMaxAmmo() and w.went[gi] > own) and loss or 0
        return ("insert(%d,+%d)->g%d[own+%d cap%d]"):format(before, w.went[gi], gi, own, gun:getMaxAmmo()), allowed
    end }
    OPS[#OPS + 1] = { 5, function(w, rng)    -- eject
        local loaded = {}
        for i, g in ipairs(w.guns) do if g:isContainsClip() then loaded[#loaded + 1] = i end end
        if #loaded == 0 then return nil end
        local gi = loaded[rng(#loaded)]
        local seen = {}
        for _, m in ipairs(magsOf(w)) do seen[m:getID()] = true end
        ISEjectMagazine.unloadAmmo({ character = w.ch, gun = w.guns[gi] })
        local newMag
        for _, m in ipairs(magsOf(w)) do if not seen[m:getID()] then newMag = m end end
        return ("eject g%d"):format(gi), 0, { eject = true, mag = newMag, went = w.went[gi] or 0 }
    end }
    OPS[#OPS + 1] = { 2, function(w, rng)    -- fill
        local mags = magsOf(w)
        if #mags == 0 then return nil end
        local m = mags[rng(#mags)]
        MS.restoreMagazineBonus(m)
        local gained = m:getMaxAmmo() - m:getCurrentAmmoCount()
        m:setCurrentAmmoCount(m:getMaxAmmo())
        return "fill", -gained
    end }
    OPS[#OPS + 1] = { 3, function(w, rng)    -- fire
        local live = {}
        for i, g in ipairs(w.guns) do if g:getCurrentAmmoCount() > 0 then live[#live + 1] = i end end
        if #live == 0 then return nil end
        local g = w.guns[live[rng(#live)]]
        local k = math.min(g:getCurrentAmmoCount(), rng(5))
        g:setCurrentAmmoCount(g:getCurrentAmmoCount() - k)
        return "fire x" .. k, k
    end }
    OPS[#OPS + 1] = { 2, function(w, rng)    -- B42 field reset + reapply
        local gi = rng(#w.guns)
        local g = w.guns[gi]
        g:setMaxAmmo(instanceItem(g:getFullType()):getMaxAmmo())
        SM.reapplyUpgrades(g)
        return "reset g" .. gi, 0
    end }
    OPS[#OPS + 1] = { 2, function(w, rng)    -- save/load on a mag
        local mags = magsOf(w)
        if #mags == 0 then return nil end
        local m = mags[rng(#mags)]
        local ammo = m:getCurrentAmmoCount()
        m:setMaxAmmo(scriptCap(w.fam.magType))
        MS.restoreMagazineBonus(m)
        m:setCurrentAmmoCount(ammo)
        return "saveload mag", 0
    end }
    OPS[#OPS + 1] = { 1, function(w, rng)    -- reroll
        local gi = rng(#w.guns)
        local d = WD.getModData(w.guns[gi])
        local pick = rng(#CLIP + 1)
        d.suffixId = CLIP[pick] and CLIP[pick].id or nil
        WD.noteAffixIds(d)
        SM.reapplyUpgrades(w.guns[gi])
        return "reroll g" .. gi, 0
    end }
    local WT = 0
    for _, o in ipairs(OPS) do WT = WT + o[1] end

    local function check(w, expected, info)
        local t = total(w)
        if t ~= expected then return ("I1 rounds %s: %d expected, %d present"):format(t < expected and "DELETED" or "created", expected, t) end
        for i, g in ipairs(w.guns) do
            if g:getCurrentAmmoCount() > g:getMaxAmmo() then return ("I2 g%d %d > cap %d"):format(i, g:getCurrentAmmoCount(), g:getMaxAmmo()) end
            SM.reapplyUpgrades(g); local once = g:getMaxAmmo(); SM.reapplyUpgrades(g)
            if g:getMaxAmmo() ~= once then return ("I6 g%d reapply %d -> %d"):format(i, once, g:getMaxAmmo()) end
            if WD.hasStaleFirearmStats(g) then return ("I7 g%d stale after reapply (cap %d)"):format(i, g:getMaxAmmo()) end
        end
        local pristine = scriptCap(w.fam.magType)
        local bound = WD.clipSizePctBonus(pristine, MAXPCT)
        for _, m in ipairs(magsOf(w)) do
            if m:getCurrentAmmoCount() > m:getMaxAmmo() then return ("I2 mag %d > cap %d"):format(m:getCurrentAmmoCount(), m:getMaxAmmo()) end
            local orig = MS.getOriginalMaxAmmo(m)
            if orig then
                local b = MS.getMagazineBonus(m) or 0
                if orig ~= pristine then return ("I3 original %d ~= script %d"):format(orig, pristine) end
                if m:getMaxAmmo() ~= orig + b then return ("I4 cap %d ~= %d+%d"):format(m:getMaxAmmo(), orig, b) end
                if b > bound then return ("I4 bonus +%d > best +%d"):format(b, bound) end
            end
        end
        if info and info.eject and info.mag then
            local b = MS.getMagazineBonus(info.mag) or 0
            if b < info.went then return ("I5 eject lowered bonus +%d -> +%d"):format(info.went, b) end
        end
    end

    local function state(w)
        local parts = {}
        for i, g in ipairs(w.guns) do
            parts[#parts + 1] = ("g%d[%s clip=%s ammo=%d cap=%d own+%d pend=%s ins=%s]"):format(i,
                g:getFullType(), tostring(g:isContainsClip()), g:getCurrentAmmoCount(), g:getMaxAmmo(),
                WD.calculateClipSizeBonus(g) or 0, tostring(MS.getPendingMagazineBonus(g)),
                tostring(MS.getInsertedMagazineBonus(g)))
        end
        for _, m in ipairs(magsOf(w)) do
            parts[#parts + 1] = ("mag[%d/%d orig=%s +%s]"):format(m:getCurrentAmmoCount(), m:getMaxAmmo(),
                tostring(MS.getOriginalMaxAmmo(m)), tostring(MS.getMagazineBonus(m)))
        end
        return table.concat(parts, " ")
    end

    local runs, fails, threw = 0, 0, 0
    if opts.family then
        local only = {}
        for _, f in ipairs(fams) do if f.magType == opts.family then only[1] = f end end
        fams, FROM, TO = only, 1, 1
    end
    for fi = FROM, math.min(TO, #fams) do
        local fam = fams[fi]
        for _, seed in ipairs(SEEDS) do
            runs = runs + 1
            local rng = makeRng(seed)
            local w = makeWorld(fam, rng)
            local expected = total(w)
            if opts.trace then line("start: " .. state(w)) end
            for step = 1, STEPS do
                local r = rng(WT)
                local op
                for _, o in ipairs(OPS) do if r <= o[1] then op = o[2]; break end; r = r - o[1] end
                local ok, label, loss, info = pcall(op, w, rng)
                if not ok then
                    threw = threw + 1
                    line(("THREW %s seed %d step %d: %s | %s"):format(fam.magType, seed, step, tostring(label), table.concat(w.log, " | ")))
                    break
                end
                if label then
                    w.log[#w.log + 1] = label
                    if opts.trace then line(("step %d %s -> %s"):format(step, label, state(w))) end
                    local bad = check(w, expected - (loss or 0), info)
                    if bad then
                        fails = fails + 1
                        line(("FAIL [%s] %s (cap %d) seed %d step %d: %s\n    ops: %s"):format(
                            fam.module, fam.magType, fam.cap, seed, step, bad, table.concat(w.log, " | ")))
                        break
                    end
                    expected = total(w)
                end
            end
        end
    end
    line(("%d sequences x %d steps: %d FAIL, %d THREW"):format(runs, STEPS, fails, threw))
end

local ok, err = pcall(run)
for _, name in ipairs(SWAP) do _G[name] = saved[name] end
if not ok then line("PROBE ERROR: " .. tostring(err)) end
local c = {}
for _, name in ipairs(SWAP) do c[#c + 1] = name .. "=" .. calls[name] end
line("sync calls (recorded, not sent): " .. table.concat(c, " "))
if getTimestampMs then line(("elapsed %d ms"):format(getTimestampMs() - t0)) end
return table.concat(out, "\n")
