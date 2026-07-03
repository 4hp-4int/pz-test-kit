--[[
    SauceTooltips VanillaCore — row-table gates, emit parity, corpus replay
    =======================================================================
    The vanilla-tooltip mirror (SauceTooltips/VanillaCore/Rows.lua) is a
    declarative table of {gate, emit} pairs ported branch-by-branch from
    InventoryItem.DoTooltipEmbedded. Two invariants keep it honest:

      1. GATE FIDELITY — gates reproduce vanilla's row counts. Verified
         in-game by the live oracle; verified HERE by replaying the recorded
         corpus (Corpus.lua): for every recorded item, Σ gates over its
         recorded facts must equal the oracle-measured vanillaRows.

      2. EMIT PARITY — emit() adds exactly gate() ctx rows, each single-line.
         If this drifts, our own card disagrees with the count the oracle
         validated, and the ornament geometry (one lineSpacing per ctx row)
         misaligns.
]]

local Assert = PZTestKit.Assert

require "SauceTooltips/VanillaCore/Rows"
require "SauceTooltips/VanillaCore/Corpus"

local VC = SauceTooltips_VanillaCore
local Corpus = SauceTooltips_VanillaCore_Corpus

local ENV = {
    scriptSpam = false, taintedText = true,
    debugMode = false, tooltipDebugInfo = false, admin = false, showModInfo = false,
}

local function plainFacts(over)
    local F = {
        fullType = "Base.TestThing", class = "InventoryItem",
        weightOfStack = 0,
        unequippedWeight = 1.0, equippedWeight = 0.7, hotbarEquippedWeight = 0.8,
        attachedSlot = -1, equipped = false, fakeEquipped = false,
        maxAmmo = 0, currentAmmo = 0,
        condition = 10, conditionMax = 0, mechanicType = 0,
        visionModifier = 1, hearingModifier = 1, discomfortModifier = 0,
        forageCategories = {},
        isVanilla = true,
    }
    for k, v in pairs(over or {}) do F[k] = v end
    return F
end

local function mockCtx()
    local c = { rows = 0 }
    function c:addLabel() self.rows = self.rows + 1 end
    function c:addKeyValue() self.rows = self.rows + 1 end
    function c:addProgress() self.rows = self.rows + 1 end
    return c
end

local tests = {}

-- ---------------------------------------------------------------------------
-- Table shape
-- ---------------------------------------------------------------------------

tests["rows_have_unique_ids_and_java_citations"] = function()
    local seen = {}
    for i = 1, #VC.ROWS do
        local r = VC.ROWS[i]
        if not r.id or seen[r.id] then
            return Assert.isTrue(false, "duplicate/missing row id at index " .. i)
        end
        seen[r.id] = true
        if type(r.java) ~= "string" or not r.java:find("%.java") then
            return Assert.isTrue(false, "row '" .. tostring(r.id) .. "' missing java citation")
        end
        if type(r.gate) ~= "function" or type(r.emit) ~= "function" then
            return Assert.isTrue(false, "row '" .. tostring(r.id) .. "' missing gate/emit")
        end
    end
    return Assert.isTrue(#VC.ROWS >= 30, "expected the full base-method port, got " .. #VC.ROWS)
end

-- ---------------------------------------------------------------------------
-- Gate fidelity on synthetic facts
-- ---------------------------------------------------------------------------

tests["plain_item_is_weight_row_only"] = function()
    local n, breakdown = VC.rowsFor(plainFacts(), ENV)
    return Assert.equal(n, 1, "plain item = weight row only")
        and Assert.equal(breakdown[1].id, "weight")
end

tests["ammo_and_gun_rows_gate_on_facts"] = function()
    local F = plainFacts({ maxAmmo = 6, currentAmmo = 2,
        ammoTypeName = "Bullets", gunTypeString = "Revolver" })
    local n = VC.rowsFor(F, ENV)
    return Assert.equal(n, 4, "weight + ammoCount + ammoType + gunType")
end

tests["ammo_rows_suppressed_for_handweapons"] = function()
    -- java:930/936 gate ammo rows on NOT instanceof HandWeapon (weapons show
    -- ammo in their own DoTooltip override).
    local F = plainFacts({ isHandWeapon = true, maxAmmo = 6, ammoTypeName = "Bullets" })
    local n = VC.rowsFor(F, ENV)
    return Assert.equal(n, 1, "weapon ammo rows belong to the override, not the base")
end

tests["condition_gate_matches_vanilla_exclusions"] = function()
    -- java:1095: conditionMax>0 AND (mechanicType>0 OR SHOW_CONDITION tag OR damaged)
    local pristine = VC.rowsFor(plainFacts({ conditionMax = 10, condition = 10 }), ENV)
    local damaged = VC.rowsFor(plainFacts({ conditionMax = 10, condition = 7 }), ENV)
    local tagged = VC.rowsFor(plainFacts({ conditionMax = 10, condition = 10,
        showConditionTag = true }), ENV)
    local mech = VC.rowsFor(plainFacts({ conditionMax = 10, condition = 10,
        mechanicType = 2 }), ENV)
    return Assert.equal(pristine, 1, "pristine untagged = no condition row")
        and Assert.equal(damaged, 2, "damaged shows condition")
        and Assert.equal(tagged, 2, "SHOW_CONDITION tag shows condition")
        and Assert.equal(mech, 2, "mechanic part shows condition")
end

tests["drainable_remaining_bar_honours_hide_tag"] = function()
    local shown = VC.rowsFor(plainFacts({ isDrainable = true, drainableUses = 0.5 }), ENV)
    local hidden = VC.rowsFor(plainFacts({ isDrainable = true, drainableUses = 0.5,
        hideRemainingTag = true }), ENV)
    return Assert.equal(shown, 2, "weight + Remaining bar")
        and Assert.equal(hidden, 1, "HIDE_REMAINING suppresses the bar")
end

tests["tooltip_text_counts_one_row_per_line"] = function()
    local n = VC.rowsFor(plainFacts({ tooltipText = "line one\nline two\nline three" }), ENV)
    return Assert.equal(n, 4, "weight + 3 tooltip lines")
end

tests["media_rows_gate_on_recorded_data"] = function()
    local F = plainFacts({ recordedMedia = true, mediaTitle = "Title",
        mediaSubtitle = "Sub", mediaAuthor = "Author",
        mediaSeen = true, mediaHeard = true })
    local n = VC.rowsFor(F, ENV)
    return Assert.equal(n, 6, "weight + title + subtitle + author + watched + heard")
end

tests["component_rows_attributes_and_durability"] = function()
    local F = plainFacts({
        attributes = {
            { name = "Alpha", bar = true, unit = 0.4 },
            { name = "Beta", value = "12" },
        },
        hasDurability = true, durabilityMaterial = "WOOD", durabilityHitPoints = 40,
    })
    local n = VC.rowsFor(F, ENV)
    return Assert.equal(n, 5, "weight + 2 attributes + Material + Hit Points")
end

tests["stack_weight_row_gates_on_tooltip_state"] = function()
    local n = VC.rowsFor(plainFacts({ weightOfStack = 4.5 }), ENV)
    return Assert.equal(n, 2, "weight + stack weight")
end

tests["forage_focus_emits_one_row_per_category"] = function()
    local n = VC.rowsFor(plainFacts({ forageCategories = { "Junk", "Medical" } }), ENV)
    return Assert.equal(n, 3, "weight + 2 forage categories")
end

tests["env_gates_script_spam_row"] = function()
    local env = { scriptSpam = true, taintedText = true,
        debugMode = false, admin = false, showModInfo = false }
    local n = VC.rowsFor(plainFacts(), env)
    return Assert.equal(n, 2, "Item Report + weight")
end

-- ---------------------------------------------------------------------------
-- Emit parity: emit() must add exactly gate() rows
-- ---------------------------------------------------------------------------

tests["emit_parity_kitchen_sink"] = function()
    -- One facts table that fires nearly every row at once.
    local F = plainFacts({
        maxAmmo = 6, currentAmmo = 1, ammoTypeName = "Shells",
        gunTypeString = "Shotgun",
        isDrainable = true, drainableUses = 0.3,
        forageCategories = { "Junk" },
        fatigueChange = -0.2,
        remoteControlID = 3,
        haveBeenRepaired = 2, hasTimesHeadRepaired = true, timesHeadRepaired = 1,
        equippedNoSprint = true,
        isWet = true, wetCooldown = 5000,
        maxCapacity = 8, itemCapacity = 3,
        hasSharpness = true, sharpness = 0.6,
        conditionMax = 10, condition = 4,
        hasReadMap = true,
        recordedMedia = true, mediaTitle = "T", mediaSubtitle = "S",
        mediaAuthor = "A", mediaSeen = true, mediaHeard = true,
        compassTag = true, inPlayerInventory = true, compassDir = "NW",
        fishingLure = true,
        attributes = { { name = "A", bar = true, unit = 0.5 }, { name = "B", value = "x" } },
        hasDurability = true, durabilityMaterial = "METAL", durabilityHitPoints = 12,
        visionModifier = 0.8, hearingModifier = 1.2, discomfortModifier = 0.1,
        tooltipText = "lore line 1\nlore line 2",
        weightOfStack = 2.0,
    })
    local predicted = VC.rowsFor(F, ENV)
    local ctx = mockCtx()
    local emitted = VC.emitAll(ctx, F, ENV)
    return Assert.equal(predicted, ctx.rows, "ctx rows == predicted rows")
        and Assert.equal(predicted, emitted, "emitAll return == predicted")
        and Assert.isTrue(predicted >= 25, "kitchen sink fired a lot of rows: " .. predicted)
end

tests["emit_parity_per_row"] = function()
    -- Every row entry individually: gate n implies emit adds exactly n.
    local F = plainFacts({
        maxAmmo = 6, currentAmmo = 1, ammoTypeName = "Shells",
        gunTypeString = "Shotgun",
        isDrainable = true, drainableUses = 0.3,
        forageCategories = { "Junk", "Trash" },
        fatigueChange = 0.4,
        remoteControlID = 3,
        haveBeenRepaired = 2, hasTimesHeadRepaired = true, timesHeadRepaired = 1,
        equippedNoSprint = true,
        isWet = true, wetCooldown = 5000,
        maxCapacity = 8, itemCapacity = -1, conditionAffectsCapacity = true,
        capacityByCondition = 5,
        hasSharpness = true, sharpness = 0.6,
        conditionMax = 10, condition = 4, hasHeadCondition = true,
        hasReadMap = true,
        recordedMedia = true, mediaTitle = "T", mediaAuthor = "A",
        mediaSeen = true, mediaHeard = true,
        compassTag = true, inPlayerInventory = true, compassDir = "E",
        fishingLure = true,
        attributes = { { name = "A", bar = true, unit = 0.5 } },
        hasDurability = true, durabilityMaterial = "METAL", durabilityHitPoints = 12,
        visionModifier = 1.3, hearingModifier = 0.6, discomfortModifier = -0.2,
        tooltipText = "only line",
        weightOfStack = 2.0, attachedSlot = 2,
    })
    for i = 1, #VC.ROWS do
        local row = VC.ROWS[i]
        local n = row.gate(F, ENV) or 0
        local ctx = mockCtx()
        if n > 0 then
            row.emit(ctx, F, ENV)
        end
        if ctx.rows ~= n then
            return Assert.isTrue(false, "row '" .. row.id .. "' gate=" .. n
                .. " but emit added " .. ctx.rows)
        end
    end
    return Assert.isTrue(true)
end

tests["emit_parity_weight_branches"] = function()
    -- All four weight variants stay a single row.
    local variants = {
        plainFacts(),                                                -- plain
        plainFacts({ attachedSlot = 1 }),                            -- hotbar
        plainFacts({ isDrainable = true, hideRemainingTag = true }), -- equippable branch, unequipped
        plainFacts({ isDrainable = true, hideRemainingTag = true, equipped = true }), -- equipped
    }
    for i = 1, #variants do
        local ctx = mockCtx()
        local predicted = VC.rowsFor(variants[i], ENV)
        VC.emitAll(ctx, variants[i], ENV)
        if ctx.rows ~= predicted then
            return Assert.isTrue(false, "weight variant " .. i .. ": predicted "
                .. predicted .. ", emitted " .. ctx.rows)
        end
    end
    return Assert.isTrue(true)
end

-- ---------------------------------------------------------------------------
-- Claim discipline
-- ---------------------------------------------------------------------------

tests["claims_accepts_plain_and_drainable"] = function()
    return Assert.isTrue(VC.claims(plainFacts(), ENV), "plain item claimable")
        and Assert.isTrue(VC.claims(plainFacts({ isDrainable = true }), ENV),
            "drainable claimable (Remaining bar is a base-method row)")
end

tests["claims_refuses_override_classes_and_components"] = function()
    local refusals = {
        { plainFacts({ isHandWeapon = true }), "class-HandWeapon" },
        { plainFacts({ isFood = true }), "class-Food" },
        { plainFacts({ isClothing = true }), "class-Clothing" },
        { plainFacts({ isInventoryContainer = true }), "class-InventoryContainer" },
        { plainFacts({ isLiterature = true }), "class-Literature" },
        { plainFacts({ hasFluidContainer = true }), "fluid-container" },
        { plainFacts({ hasExtraItems = true }), "extra-items-strip" },
        { plainFacts({ incomplete = true }), "facts-incomplete" },
    }
    for i = 1, #refusals do
        local ok, reason = VC.claims(refusals[i][1], ENV)
        if ok or reason ~= refusals[i][2] then
            return Assert.isTrue(false, "expected refusal '" .. refusals[i][2]
                .. "', got ok=" .. tostring(ok) .. " reason=" .. tostring(reason))
        end
    end
    return Assert.isTrue(true)
end

tests["claims_debug_admin_and_modinfo_sessions"] = function()
    -- Debug/admin sessions are claimable (the debug rows are ported) — the
    -- Lua console needs debug mode, so the audit MUST be able to claim there.
    -- Only an UNREADABLE Tooltip.Info option (nil) refuses.
    local dbgUnknown = { scriptSpam = false, taintedText = true, debugMode = true,
        tooltipDebugInfo = nil, admin = false, showModInfo = false }
    local dbgOff = { scriptSpam = false, taintedText = true, debugMode = true,
        tooltipDebugInfo = false, admin = false, showModInfo = false }
    local adm = { scriptSpam = false, taintedText = true, debugMode = false,
        tooltipDebugInfo = false, admin = true, showModInfo = false }
    local modinfo = { scriptSpam = false, taintedText = true, debugMode = false,
        tooltipDebugInfo = false, admin = false, showModInfo = true }
    local okU, reasonU = VC.claims(plainFacts(), dbgUnknown)
    local okD = VC.claims(plainFacts(), dbgOff)
    local okA = VC.claims(plainFacts(), adm)
    local okM = VC.claims(plainFacts({ isVanilla = false }), modinfo)
    local okMVanilla = VC.claims(plainFacts({ isVanilla = true }), modinfo)
    return Assert.isTrue(not okU, "unreadable Tooltip.Info refused")
        and Assert.equal(reasonU, "debug-option-unreadable")
        and Assert.isTrue(okD and true, "debug session with Tooltip.Info off claims")
        and Assert.isTrue(okA and true, "admin session claims (Loot Category ported)")
        and Assert.isTrue(not okM, "mod item refused while ShowItemModInfo on")
        and Assert.isTrue(okMVanilla and true, "vanilla item fine with ShowItemModInfo on")
end

tests["debug_rows_gate_and_emit_parity"] = function()
    -- java:950-992 — 5 weight KVs + ID + DictionaryID (7), +keyId, +ClothingItem,
    -- and Loot Category fires on tooltipDebugInfo OR admin.
    local dbgOn = { scriptSpam = false, taintedText = true, debugMode = true,
        tooltipDebugInfo = true, admin = false, showModInfo = false }
    local admOnly = { scriptSpam = false, taintedText = true, debugMode = false,
        tooltipDebugInfo = false, admin = true, showModInfo = false }
    local plain = plainFacts({ itemId = 12, registryId = 340, lootType = "Tool" })
    local keyed = plainFacts({ itemId = 12, registryId = 340, lootType = "Tool",
        keyDebugRow = true, keyId = 77, clothingItemName = "Vest" })
    local nPlain = VC.rowsFor(plain, dbgOn)
    local nKeyed = VC.rowsFor(keyed, dbgOn)
    local nAdmin = VC.rowsFor(plain, admOnly)
    local ctx = mockCtx()
    local emitted = VC.emitAll(ctx, keyed, dbgOn)
    return Assert.equal(nPlain, 9, "weight + 7 debug rows + Loot Category")
        and Assert.equal(nKeyed, 11, "+ keyId + ClothingItem")
        and Assert.equal(nAdmin, 2, "admin only = weight + Loot Category")
        and Assert.equal(ctx.rows, nKeyed, "debug emit parity")
        and Assert.equal(emitted, nKeyed, "emitAll return parity")
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

tests["cleanNum_matches_java_getCleanString"] = function()
    -- java:1260 — truncate to 2dp (with +0.005 rounding), Float.toString style
    return Assert.equal(VC.cleanNum(1.0), "1.0")
        and Assert.equal(VC.cleanNum(3), "3.0")
        and Assert.equal(VC.cleanNum(0.299), "0.3")
        and Assert.equal(VC.cleanNum(0.25), "0.25")
        and Assert.equal(VC.cleanNum(0.334), "0.33")
end

-- ---------------------------------------------------------------------------
-- Corpus replay — the record/replay fidelity layer
-- ---------------------------------------------------------------------------

tests["corpus_replay_gates_reproduce_recorded_vanilla_rows"] = function()
    local entries = (Corpus and Corpus.entries) or {}
    if #entries == 0 then
        -- Not recorded yet (or wiped by a PZ patch re-record). The in-game
        -- recorder is SauceTooltips_VanillaCore.audit({record=true}).
        print("  [vanillacore] corpus empty — replay pending first in-game recording")
        return Assert.isTrue(true)
    end
    local failures = {}
    for i = 1, #entries do
        local e = entries[i]
        local predicted = VC.rowsFor(e.facts, e.env)
        if math.abs(predicted - e.vanillaRows) > 0.01 then
            failures[#failures + 1] = tostring(e.fullType) .. " ["
                .. tostring(e.class) .. "] predicted=" .. predicted
                .. " recorded=" .. tostring(e.vanillaRows)
        end
    end
    if #failures > 0 then
        return Assert.isTrue(false, "corpus replay mismatches (" .. #failures .. "/"
            .. #entries .. "): " .. table.concat(failures, "; "))
    end
    print("  [vanillacore] corpus replay clean: " .. #entries
        .. " recorded items (pz " .. tostring(Corpus.pzVersion) .. ")")
    return Assert.isTrue(true)
end

tests["corpus_entries_replay_claims_too"] = function()
    -- Every recorded entry was claimable when recorded; the claims logic must
    -- still accept its facts (a claims regression would silently shrink
    -- coverage without failing the row replay).
    local entries = (Corpus and Corpus.entries) or {}
    for i = 1, #entries do
        local e = entries[i]
        local ok, reason = VC.claims(e.facts, e.env)
        if not ok then
            return Assert.isTrue(false, "recorded entry no longer claimable: "
                .. tostring(e.fullType) .. " (" .. tostring(reason) .. ")")
        end
    end
    return Assert.isTrue(true)
end

return tests
