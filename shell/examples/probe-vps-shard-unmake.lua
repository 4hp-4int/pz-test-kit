-- probe-vps-shard-unmake.lua -- VorpallySauced 1.14.0 live checks for the two
-- MP fixes from the 2026-10-04 pre-release review, on REAL items in the dedi VM.
--
--   SHARD  (ServerLogic useVorpalShard): a real VorpalShard whose container
--          field is nulled while it still sits in a list -- the field case
--          (IsoWorldInventoryObject's constructor does exactly that).
--          A. last use: charged, reroll happens, shard removed from the list
--          B. already spent (0 uses): refused, NO reroll, shard removed
--   UNMAKE (ServerLogic resetMagazine): a real stamped magazine.
--          C. server copy restored to the stored original
--          D. the magazineReset command carries maxAmmo == original (the
--             client applies it; SyncItemFieldsPacket has no maxAmmo)
--
-- No player needed: a stub player carries a REAL ItemContainer. The Java sync
-- globals reject a table player, so they are swapped for recorders for this
-- one synchronous run and restored after.
--   ./pz-shell eval -f examples/probe-vps-shard-unmake.lua

local V = VorpallySauced
local WD, MS = V.WeaponData, V.MagazineSync
local out = {}
local function line(s) out[#out + 1] = s end
local function check(label, cond, detail)
    line((cond and "PASS " or "FAIL ") .. label .. (detail and ("  (" .. detail .. ")") or ""))
end

line("VPS " .. tostring(V.VERSION))
if V.VERSION ~= "1.14.0" then
    return table.concat(out, "\n") .. "\nSTALE BUILD on the server -- deploy + restart first"
end

local SWAP = { "sendServerCommand", "syncHandWeaponFields", "syncItemModData", "syncItemFields",
               "sendAddItemToContainer", "sendRemoveItemFromContainer" }
local saved, sent = {}, {}
for _, n in ipairs(SWAP) do
    saved[n] = _G[n]
    _G[n] = function(...) local a = { ... }; sent[#sent + 1] = { fn = n, args = a } end
end

local function stubPlayer(inv)
    return {
        getInventory = function() return inv end,
        getUsername = function() return "probe" end,
        getDisplayName = function() return "probe" end,
        getPrimaryHandItem = function() return nil end,
        getSecondaryHandItem = function() return nil end,
        removeFromHands = function() end,
        getAccessLevel = function() return "admin" end,
        getRole = function() return nil end,
    }
end

local function shardScenario(uses)
    local inv = instanceItem("Base.Bag_DuffelBag"):getItemContainer()
    local weapon = instanceItem("Base.Axe")
    local d = WD.getOrCreateModData(weapon)
    d.kills = 500; d.prefixId = 1
    WD.noteAffixIds(d)
    inv:AddItem(weapon)
    local shard = instanceItem("VorpallySauced.VorpalShard")
    inv:AddItem(shard)
    shard:setCurrentUses(uses)
    shard:setContainer(nil)                -- in the list, field nulled
    local rerolled = false
    local UM = V.UpgradeManager
    local real = UM.rerollAffixes
    UM.rerollAffixes = function(...) rerolled = true; return real(...) end
    local ok, err = pcall(triggerEvent, "OnClientCommand", "VorpallySauced", "useVorpalShard",
        stubPlayer(inv), { shardId = shard:getID(), weaponId = weapon:getID() })
    UM.rerollAffixes = real
    return { ok = ok, err = err, rerolled = rerolled, stillListed = inv:contains(shard),
             uses = shard:getCurrentUses() }
end

local function run()
    local a = shardScenario(1)
    check("A shard last use: no error", a.ok, tostring(a.err))
    check("A shard last use: rerolled", a.rerolled)
    check("A shard last use: removed from the list", not a.stillListed, "uses now " .. tostring(a.uses))

    local b = shardScenario(0)
    check("B spent shard: no error", b.ok, tostring(b.err))
    check("B spent shard: did NOT reroll", not b.rerolled)
    check("B spent shard: removed from the list", not b.stillListed)

    local inv = instanceItem("Base.Bag_DuffelBag"):getItemContainer()
    local mag = instanceItem("Base.9mmClip")
    local pristine = mag:getMaxAmmo()
    MS.applyBonusToMagazine(mag, 7, 12345, 4, nil)
    mag:setCurrentAmmoCount(0)
    inv:AddItem(mag)
    local before = #sent
    local ok, err = pcall(triggerEvent, "OnClientCommand", "VorpallySauced", "resetMagazine",
        stubPlayer(inv), { magazineId = mag:getID() })
    check("C unmake: no error", ok, tostring(err))
    check("C unmake: server copy restored", mag:getMaxAmmo() == pristine,
        mag:getMaxAmmo() .. " vs original " .. pristine)
    local cmdMax
    for i = before + 1, #sent do
        local s = sent[i]
        if s.fn == "sendServerCommand" and s.args[3] == "magazineReset" and type(s.args[4]) == "table" then
            cmdMax = s.args[4].maxAmmo
        end
    end
    check("D unmake: magazineReset carries maxAmmo", cmdMax == pristine, "sent " .. tostring(cmdMax))
end

local ok, err = pcall(run)
for _, n in ipairs(SWAP) do _G[n] = saved[n] end
if not ok then line("PROBE ERROR: " .. tostring(err)) end
return table.concat(out, "\n")
