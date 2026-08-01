-- v1.10.2 audit Tier-3 probe — exercises every fixed entry point against a
-- weapon forced into v1.10.0+ packed-format ModData on the live dedi VM.
--
-- Background: 11 sites in VPS were reading raw `weapon:getModData().VorpallySauced.<field>`
-- which on packed-format weapons (the wire format used post-save) is the
-- wrapper { _ = "..." } whose direct field access returns nil. The audit
-- replaced these reads with `WeaponData.getModData()` which expands.
--
-- This probe asserts each entry point works on a packed weapon. Pass = the
-- audit fixes are live in the dedi VM and the contract holds end-to-end.
--
-- Usage:
--   ./pz-shell eval -f examples/probe-packed-fixes.lua

local CT  = VorpallySauced and VorpallySauced.CraftTransfer
local API = VorpallySauced and VorpallySauced.API
local WD  = VorpallySauced and VorpallySauced.WeaponData
local EH  = VorpallySauced and VorpallySauced.EquipHandler
local VSM = VorpallySauced and VorpallySauced.VorpalShardMenu

if not CT or not API or not WD then return "FAIL: VPS modules not loaded" end

local lines = {}
local function add(s) table.insert(lines, s) end
local results = { pass = 0, fail = 0 }
local function check(label, cond, detail)
    if cond then
        add("  [PASS] " .. label)
        results.pass = results.pass + 1
    else
        add("  [FAIL] " .. label .. (detail and (" — " .. detail) or ""))
        results.fail = results.fail + 1
    end
end

add("=== v1.10.2 packed-format audit probe ===")

-- ── helper: spawn weapon, populate VPS data, force packed ──────────────────
local function packedWeapon(itemType, fields)
    local w = instanceItem(itemType)
    if not w then return nil end
    local d = WD.getOrCreateModData(w)
    if not d then return nil end
    for k, v in pairs(fields or {}) do d[k] = v end
    WD.compactModData(w)
    return w
end

-- ── meta: confirm compaction actually packs ────────────────────────────────
add("")
add("compaction contract:")
local sample = packedWeapon("Base.BaseballBat", {
    kills = 250, prefixId = 4, suffixId = 6, bondingId = 2,
})
if not sample then return "FAIL: could not spawn Base.BaseballBat" end

local raw = sample:getModData().VorpallySauced
check("packed wrapper present (._  set)",      raw and raw._ ~= nil)
check("not expanded (raw.version absent)",     raw and raw.version == nil)
check("raw.prefixId nil while packed",         raw and raw.prefixId == nil)

local expanded = WD.getModData(sample)
check("getModData returns table",              type(expanded) == "table")
check("expanded.kills correct",                expanded and expanded.kills == 250)
check("expanded.bondingId correct",            expanded and expanded.bondingId == 2)

-- ── CraftTransfer.captureForTransfer (Blooded) ─────────────────────────────
add("")
add("CraftTransfer.captureForTransfer (Blooded):")
local blooded = packedWeapon("Base.BaseballBat", {
    kills = 500, prefixId = 2, suffixId = 3, bondingId = 1, isFirearm = false,
})
local snap = blooded and CT.captureForTransfer(blooded)
check("snapshot non-nil for packed Blooded",   snap ~= nil)
check("snap.bondingId = 1",                    snap and snap.bondingId == 1)
check("snap.kills = 500",                      snap and snap.kills == 500)
check("snap.prefixId = 2",                     snap and snap.prefixId == 2)

-- ── CraftTransfer.captureForTransfer (Mark only — should NOT transfer) ────
add("")
add("CraftTransfer.captureForTransfer (Mark only — gate intact):")
local marked = packedWeapon("Base.Axe", { kills = 50, prefixId = 4 })
local nilSnap = marked and CT.captureForTransfer(marked)
check("snapshot nil for non-Blooded",          nilSnap == nil)

-- ── EquipHandler / VorpalShardMenu are client-only ────────────────────────
-- These modules live under media/lua/client/ and skip on dedi (correctly).
-- Their packed-format fixes are certified by Tier 1 (PackedFormatTests.lua)
-- + Tier 2 (TestRunner.runAll() in SP). Skip here, don't fail.
add("")
add("client-only modules (covered by Tier 1+2):")
add("  [SKIP] EquipHandler._snapshotForRecovery — client module, not on dedi")
add("  [SKIP] VorpalShardMenu._canReroll — client module, not on dedi")

-- ── API.getWeaponInfo / captureProgression / getWeaponBonuses ─────────────
add("")
add("API public methods:")
local apiW = packedWeapon("Base.Axe", {
    kills = 300, prefixId = 6, suffixId = 9, bondingId = 3, isFirearm = false,
})
local info = apiW and API.getWeaponInfo(apiW)
check("getWeaponInfo non-nil for packed",      info ~= nil)
check("info.kills = 300",                      info and info.kills == 300)
check("info.isBlooded = true",                 info and info.isBlooded == true)

local progSnap = apiW and API.captureProgression(apiW)
check("captureProgression non-nil for packed", progSnap ~= nil)
check("progSnap.bondingId = 3",                progSnap and progSnap.bondingId == 3)

local bonuses = apiW and API.getWeaponBonuses(apiW)
check("getWeaponBonuses non-nil for packed",   bonuses ~= nil)

-- ── verdict ────────────────────────────────────────────────────────────────
add("")
add(string.format("results: %d passed, %d failed", results.pass, results.fail))
add(results.fail == 0
    and ">>> PASS: v1.10.2 packed-format audit verified live"
    or  ">>> FAIL: audit fixes incomplete or not loaded — review above")

return table.concat(lines, "\n")
