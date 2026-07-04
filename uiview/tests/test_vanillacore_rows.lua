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
    -- java:930/936 gate the BASE ammo rows on NOT instanceof HandWeapon —
    -- weapons get their own wpnAmmo row (HandWeapon.java:405) instead.
    local F = plainFacts({ isHandWeapon = true, maxAmmo = 6, ammoTypeName = "Bullets",
        weapon = { bulletName = "Bullets" } })
    local n, breakdown = VC.rowsFor(F, ENV)
    local ids = {}
    for i = 1, #breakdown do ids[breakdown[i].id] = breakdown[i].n end
    return Assert.equal(n, 3, "weight + wpnCondition + wpnAmmo")
        and Assert.isNil(ids.ammoCount, "base ammoCount suppressed")
        and Assert.equal(ids.wpnAmmo, 1, "override ammo row fires")
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
-- Weapon rows (HandWeapon.DoTooltip port, at the java:1030 hook)
-- ---------------------------------------------------------------------------

local function weaponFacts(over, wpnOver)
    local W = {
        headCondition = 10, headConditionMax = 10,
        maxDamage = 0, minDamage = 0, bloodLevel = 0,
        attachments = {},
    }
    for k, v in pairs(wpnOver or {}) do W[k] = v end
    local F = plainFacts({ isHandWeapon = true, weapon = W })
    for k, v in pairs(over or {}) do F[k] = v end
    return F
end

tests["weapon_baseline_is_weight_plus_condition"] = function()
    -- wpnCondition is UNCONDITIONAL for weapons (HandWeapon.java:287) —
    -- unlike the base condition row, which is suppressed for weapons.
    local n, breakdown = VC.rowsFor(weaponFacts(), ENV)
    local ids = {}
    for i = 1, #breakdown do ids[breakdown[i].id] = true end
    return Assert.equal(n, 2, "weight + wpnCondition")
        and Assert.isTrue(ids.wpnCondition == true)
        and Assert.isNil(ids.condition and true, "base condition row stays suppressed")
end

tests["weapon_melee_axe_rows"] = function()
    -- damaged two-hand axe with sharpness and blood
    local F = weaponFacts({ hasSharpness = true, sharpness = 0.6,
        condition = 6, conditionMax = 10 },
        { maxDamage = 1.5, minDamage = 0.5, bloodLevel = 0.3, twoHand = true })
    local n = VC.rowsFor(F, ENV)
    return Assert.equal(n, 6,
        "weight + sharpness + condition + damage + bloody + twoHand")
end

tests["weapon_firearm_rows"] = function()
    local F = weaponFacts({ maxAmmo = 6, currentAmmo = 2 }, {
        maxDamage = 1.2, ranged = true, maxRange = 10,
        fireMode = "Single", magazineType = "Base.9mmClip",
        containsClip = true, bulletName = "9mm Magazine",
        jammed = true,
    })
    local n = VC.rowsFor(F, ENV)
    -- weight + condition + damage + range + fireMode + ammo + jammed + clip
    return Assert.equal(n, 8, "firearm row set")
end

tests["weapon_chamber_chain_is_exclusive"] = function()
    -- java:424-453 — jammed / no-round-chambered / spent-rounds are an
    -- if-else chain: exactly one row (or none) ever fires.
    local jammed = weaponFacts({ maxAmmo = 6, currentAmmo = 2 },
        { jammed = true, haveChamber = true, spentRoundCount = 3 })
    local noRound = weaponFacts({ maxAmmo = 6, currentAmmo = 2 },
        { haveChamber = true, spentRoundCount = 3 })
    local spentOnly = weaponFacts({ maxAmmo = 6, currentAmmo = 0 },
        { spentRoundCount = 3 })
    local clean = weaponFacts({ maxAmmo = 6, currentAmmo = 0 }, {})
    local function chamberN(F)
        for i = 1, #VC.ROWS do
            if VC.ROWS[i].id == "wpnChamber" then return VC.ROWS[i].gate(F, ENV) end
        end
    end
    return Assert.equal(chamberN(jammed), 1, "jammed wins the chain")
        and Assert.equal(chamberN(noRound), 1, "chamber empty with ammo")
        and Assert.equal(chamberN(spentOnly), 1, "spent rounds")
        and Assert.equal(chamberN(clean), 0, "clean gun, no chamber row")
end

tests["weapon_fishing_and_attachments"] = function()
    local F = weaponFacts({}, {
        fishingRod = true, lineCondition = 0.8, lineName = "Fishing Line",
        hookName = "Hook", lureName = nil,
        attachments = {
            { partType = "Scope", name = "x8 Scope" },
            { partType = "RedDot", name = "Red Dot", battery = true, batteryUses = 0.4 },
        },
    })
    local n = VC.rowsFor(F, ENV)
    -- weight + condition + fishing(4) + attachments(2 + 1 battery)
    return Assert.equal(n, 9, "fishing block is 4 rows; battery part adds a bar")
end

tests["weapon_emit_parity_kitchen_sink"] = function()
    local F = weaponFacts({ hasSharpness = true, sharpness = 0.5,
        hasHeadCondition = true, maxAmmo = 8, currentAmmo = 3 }, {
        headCondition = 7, headConditionMax = 10,
        maxDamage = 1.1, minDamage = 0.4, bloodLevel = 0.2,
        fishingRod = true, lineCondition = 0.9,
        ranged = true, maxRange = 12, twoHand = true,
        fireMode = "Auto", exertionBlock = true,
        haveChamber = true, roundChambered = false,
        spentRoundCount = 0, magazineType = "Base.Mag",
        containsClip = false, bulletName = "Mag",
        attachments = { { partType = "Laser", name = "Laser",
            battery = true, batteryUses = 0.7 } },
        noMaintXp = true,
    })
    local predicted = VC.rowsFor(F, ENV)
    local ctx = mockCtx()
    local emitted = VC.emitAll(ctx, F, ENV)
    return Assert.equal(ctx.rows, predicted, "weapon ctx rows == predicted")
        and Assert.equal(emitted, predicted, "weapon emitAll return parity")
        and Assert.isTrue(predicted >= 15, "weapon kitchen sink fired: " .. predicted)
end

tests["claims_accepts_weapons_with_facts"] = function()
    local ok = VC.claims(weaponFacts(), ENV)
    return Assert.isTrue(ok and true, "HandWeapon with weapon facts claims")
end

tests["multiline_labels_count_translated_lines"] = function()
    -- Tooltip_weapon_NoMaintenanceXp is "...XP<br>when used as a weapon."
    -- in EN — ONE setLabel, TWO layout rows (the 65-weapon +1 mismatch of
    -- 2026-07-03). env.lines records translated line counts live; gates
    -- multiply, emitLabel splits, and the corpus carries the counts so the
    -- replay uses the recorded truth instead of the mock's single-line keys.
    local envL = { scriptSpam = false, taintedText = true, debugMode = false,
        tooltipDebugInfo = false, admin = false, showModInfo = false,
        lines = { ["Tooltip_weapon_NoMaintenanceXp"] = 2 } }
    local F = weaponFacts({}, { noMaintXp = true })
    local n = VC.rowsFor(F, envL)
    local nDefault = VC.rowsFor(F, ENV)
    -- emit parity when the translation really is two lines
    local oldGetText = getText
    getText = function(k)
        if k == "Tooltip_weapon_NoMaintenanceXp" then return "line one\nline two" end
        return oldGetText(k)
    end
    local ctx = mockCtx()
    local emitted = VC.emitAll(ctx, F, envL)
    getText = oldGetText
    return Assert.equal(n, 4, "weight + wpnCondition + 2 NoMaintXp lines")
        and Assert.equal(nDefault, 3, "no env.lines entry -> 1 line")
        and Assert.equal(ctx.rows, n, "emitLabel splits to match the gate")
        and Assert.equal(emitted, n, "emitAll return parity")
end

-- ---------------------------------------------------------------------------
-- Clothing / InventoryContainer / Food rows
-- ---------------------------------------------------------------------------

local function clothingFacts(over, clOver)
    local C = {
        insulation = 0.4, windResistance = 0, waterResistance = 0,
        bloodLevel = 0, dirtyness = 0, wetness = 0, holes = 0,
        biteDefense = 0, scratchDefense = 0, bulletDefense = 0,
        runSpeedModifier = 1, combatSpeedModifier = 1,
    }
    for k, v in pairs(clOver or {}) do C[k] = v end
    local F = plainFacts({ isClothing = true, clothing = C,
        condition = 10, conditionMax = 10 })
    for k, v in pairs(over or {}) do F[k] = v end
    return F
end

local function foodFacts(over, fdOver)
    local D = {
        hungerChange = 0, thirstChange = 0, enduranceChange = 0,
        stressChange = 0, boredomChange = 0, unhappyChange = 0,
        heat = 1, freezingTime = 0, hasCharacter = true,
    }
    for k, v in pairs(fdOver or {}) do D[k] = v end
    local F = plainFacts({ isFood = true, food = D })
    for k, v in pairs(over or {}) do F[k] = v end
    return F
end

tests["clothing_core_block_gates_on_cosmetic"] = function()
    -- java:157 — condition + insulation always for non-cosmetic; wind/water
    -- resist only when > 0; cosmetic items get NONE of the block.
    local plain = VC.rowsFor(clothingFacts(), ENV)
    local resists = VC.rowsFor(clothingFacts({}, { windResistance = 0.3,
        waterResistance = 0.5 }), ENV)
    local cosmetic = VC.rowsFor(clothingFacts({}, { cosmetic = true }), ENV)
    return Assert.equal(plain, 3, "weight + condition + insulation")
        and Assert.equal(resists, 5, "+ wind + water resist bars")
        and Assert.equal(cosmetic, 1, "cosmetic = weight only")
end

tests["clothing_defense_compare_mode"] = function()
    -- unequipped with character: row when new != worn sum OR stat nonzero
    local delta = VC.rowsFor(clothingFacts({}, { compareMode = true,
        biteDefense = 20, prevBite = 10 }), ENV)
    local equal = VC.rowsFor(clothingFacts({}, { compareMode = true,
        biteDefense = 0, prevBite = 0 }), ENV)
    local equipped = VC.rowsFor(clothingFacts({}, { compareMode = false,
        biteDefense = 20 }), ENV)
    return Assert.equal(delta, 4, "delta row shown")
        and Assert.equal(equal, 3, "0 == 0 -> no row")
        and Assert.equal(equipped, 4, "equipped nonzero stat -> plain row")
end

tests["clothing_filter_and_condition_bars"] = function()
    local mask = VC.rowsFor(clothingFacts({}, { gasMask = true, hasFilter = true,
        filterName = "Filter", usedDelta = 0.5 }), ENV)
    local maskNoFilter = VC.rowsFor(clothingFacts({}, { gasMask = true }), ENV)
    local wornOut = VC.rowsFor(clothingFacts({}, { bloodLevel = 30,
        dirtyness = 40, wetness = 50, holes = 2, runSpeedModifier = 0.9 }), ENV)
    -- weight + condition + insulation + blood + dirt + wet + holes + runSpeed
    return Assert.equal(mask, 4, "filter bar")
        and Assert.equal(maskNoFilter, 4, "NoFilter label")
        and Assert.equal(wornOut, 8, "blood/dirt/wet/holes/runSpeed rows")
end

tests["container_rows"] = function()
    local F = plainFacts({ isInventoryContainer = true, containerFacts = {
        effectiveCapacity = 20, weightReduction = 60, maxItemSize = 10,
        hasBloodType = true, bloodLevel = 0.5,
    } })
    local n = VC.rowsFor(F, ENV)
    local ctx = mockCtx()
    local emitted = VC.emitAll(ctx, F, ENV)
    return Assert.equal(n, 5, "weight + capacity + reduction + maxSize + blood")
        and Assert.equal(ctx.rows, n, "container emit parity")
        and Assert.equal(emitted, n)
end

tests["food_nutrition_visibility_matrix"] = function()
    -- java:1579-1608 — full panel for nutritionist/readable-package/debug;
    -- 2-row stub for packaged+illiterate or packaged+tooDark; else nothing.
    local hidden = VC.rowsFor(foodFacts(), ENV)
    local nutri = VC.rowsFor(foodFacts({}, { nutritionist = true }), ENV)
    local package_ = VC.rowsFor(foodFacts({}, { packaged = true,
        canReadPackage = true }), ENV)
    local illit = VC.rowsFor(foodFacts({}, { packaged = true, illiterate = true }), ENV)
    local dark = VC.rowsFor(foodFacts({}, { packaged = true, tooDark = true }), ENV)
    return Assert.equal(hidden, 1, "unpackaged non-nutritionist: weight only")
        and Assert.equal(nutri, 6, "nutritionist: + Nutrition + 4 macros")
        and Assert.equal(package_, 6, "readable package: same")
        and Assert.equal(illit, 3, "+ Nutrition + Illiterate stub")
        and Assert.equal(dark, 3, "+ Nutrition + TooDark stub")
end

tests["food_state_rows"] = function()
    local F = foodFacts({}, {
        hungerChange = -0.2, thirstChange = -0.1, enduranceChange = 0.05,
        stressChange = -0.1, boredomChange = -10, unhappyChange = -10,
        cookable = true, heat = 2.0, cookingTime = 5, minutesToCook = 10,
        minutesToBurn = 20, freezingTime = 50,
        dangerousUncooked = true, goodHot = true,
        cookedInMicrowave = true, milkType = "Cow",
        removeUnhappyWhenCooked = true,
    })
    local n = VC.rowsFor(F, ENV)
    local ctx = mockCtx()
    local emitted = VC.emitAll(ctx, F, ENV)
    -- weight + hunger + thirst + endurance + stress + boredom + unhappy
    -- + cooking + freezing + dangerous + cookToRemove + microwave + milk
    -- (betterHot suppressed: heat 2.0 >= 1.3)
    return Assert.equal(n, 13, "food state row set")
        and Assert.equal(ctx.rows, n, "food emit parity")
        and Assert.equal(emitted, n)
end

tests["food_hunger_hidden_by_tag_and_egg_danger"] = function()
    local hidden = VC.rowsFor(foodFacts({}, { hungerChange = -0.2,
        hideHungerTag = true }), ENV)
    local egg = foodFacts({}, { dangerousUncooked = true, eggTag = true })
    local n = VC.rowsFor(egg, ENV)
    return Assert.equal(hidden, 1, "HIDE_HUNGER_CHANGE suppresses hunger row")
        and Assert.equal(n, 2, "egg slight-danger label")
end

tests["clothing_emit_parity_kitchen_sink"] = function()
    local F = clothingFacts({ equippedNoSprint = true }, {
        windResistance = 0.2, waterResistance = 0.3,
        bloodLevel = 10, dirtyness = 20, wetness = 30, holes = 1,
        compareMode = true, biteDefense = 15, prevBite = 5,
        scratchDefense = 10, prevScratch = 10, bulletDefense = 0, prevBullet = 4,
        gasMask = true, hasFilter = true, filterName = "Filter", usedDelta = 0.4,
        runSpeedModifier = 1.1, combatSpeedModifier = 0.9,
    })
    local predicted = VC.rowsFor(F, ENV)
    local ctx = mockCtx()
    local emitted = VC.emitAll(ctx, F, ENV)
    return Assert.equal(ctx.rows, predicted, "clothing ctx rows == predicted")
        and Assert.equal(emitted, predicted)
        and Assert.isTrue(predicted >= 13, "clothing sink fired: " .. predicted)
end

-- ---------------------------------------------------------------------------
-- Literature / WeaponPart / AlarmClock / Animal / Fluid rows
-- ---------------------------------------------------------------------------

local function litFacts(over, ltOver)
    local L = {
        hasCharacter = true, statsVisible = true,
        boredomChange = 0, stressChange = 0, unhappyChange = 0,
        numberOfPages = -1, lvlSkillTrained = -1, maxLevelTrained = -1,
    }
    for k, v in pairs(ltOver or {}) do L[k] = v end
    local F = plainFacts({ isLiterature = true, lit = L })
    for k, v in pairs(over or {}) do F[k] = v end
    return F
end

tests["literature_stat_and_page_rows"] = function()
    local skill = VC.rowsFor(litFacts({}, { boredomChange = -20,
        unhappyChange = -10, numberOfPages = 220, alreadyRead = 40,
        lvlSkillTrained = 1, maxLevelTrained = 3 }), ENV)
    -- weight + boredom + unhappy + pages + skillXp
    local readTitle = VC.rowsFor(litFacts({}, { title = "abc", titleRead = true,
        statsVisible = false, boredomChange = -20 }), ENV)
    -- weight + RecentlyRead (stats hidden once read)
    return Assert.equal(skill, 5, "skill book rows")
        and Assert.equal(readTitle, 2, "read title hides stats, shows RecentlyRead")
end

tests["literature_recipe_book_rows"] = function()
    local unread = VC.rowsFor(litFacts({}, { recipes = { "A", "B", "C" },
        allKnown = false }), ENV)
    -- weight + 3 recipe rows + NotBeenRead
    local known = VC.rowsFor(litFacts({}, { recipes = { "A" },
        allKnown = true, alreadyKnownRow = true }), ENV)
    -- weight + 1 recipe + HasBeenRead + AlreadyKnown
    local illit = VC.rowsFor(litFacts({}, { recipes = { "A", "B" },
        illiterate = true }), ENV)
    -- weight + single illiterate stub
    return Assert.equal(unread, 5, "unread recipe book")
        and Assert.equal(known, 4, "known recipe book + granted row")
        and Assert.equal(illit, 2, "illiterate stub")
end

tests["weaponpart_alarm_animal_rows"] = function()
    local part = plainFacts({ isWeaponPart = true, wpart = {
        partType = "Scope", mountText = "Rifle, Shotgun",
        batteryRow = true, batteryUses = 0.5 } })
    local clock = plainFacts({ isAlarmClock = true,
        alarm = { set = true, hour = 7, minutes = 30 } })
    local clockOff = plainFacts({ isAlarmClock = true, alarm = { set = false } })
    local animal = plainFacts({ isAnimal = true, animalFacts = {
        typeText = "Chicken", female = true, ageText = "Adult",
        appearanceText = "White", healthText = "Good" } })
    local nPart = VC.rowsFor(part, ENV)
    local nClock = VC.rowsFor(clock, ENV)
    local nClockOff = VC.rowsFor(clockOff, ENV)
    local nAnimal = VC.rowsFor(animal, ENV)
    local ctx = mockCtx()
    local emitted = VC.emitAll(ctx, animal, ENV)
    return Assert.equal(nPart, 4, "part: weight + type + mount + battery")
        and Assert.equal(nClock, 3, "clock: weight + time + alarm")
        and Assert.equal(nClockOff, 2, "clock unset: weight + time")
        and Assert.equal(nAnimal, 6, "animal: weight + 5 info rows")
        and Assert.equal(ctx.rows, nAnimal, "animal emit parity")
        and Assert.equal(emitted, nAnimal)
end

tests["alarmclockclothing_shows_alarm_not_clothing_rows"] = function()
    -- AlarmClockClothing.DoTooltip REPLACES the clothing rows (no super call)
    local F = plainFacts({ isClothing = true, isAlarmClockClothing = true,
        alarm = { set = true, hour = 6, minutes = 0 } })
    local n, breakdown = VC.rowsFor(F, ENV)
    local ids = {}
    for i = 1, #breakdown do ids[breakdown[i].id] = true end
    local ok = VC.claims(F, ENV)
    return Assert.equal(n, 3, "weight + time + alarm, NO clothing rows")
        and Assert.isNil(ids.clCore and true, "clCore suppressed")
        and Assert.isTrue(ok and true, "AlarmClockClothing claims via alarm facts")
end

tests["fluid_rows_and_claims"] = function()
    local empty = plainFacts({ hasFluidContainer = true, fluid = {
        amount = 0, capacity = 10, empty = true, mixture = false,
        amountText = "0 / 10" } })
    local single = plainFacts({ hasFluidContainer = true, fluid = {
        amount = 5, capacity = 10, empty = false, mixture = false,
        amountText = "5 / 10", fluidName = "Water", fluidRatio = 0.5,
        poisonous = true, poisonEffectNone = false, tainted = true,
        otherPoison = false } })
    local mixture = plainFacts({ hasFluidContainer = true, fluid = {
        amount = 5, capacity = 10, empty = false, mixture = true } })
    local nEmpty = VC.rowsFor(empty, ENV)
    local nSingle = VC.rowsFor(single, ENV) -- taintedText=true -> poison row
    local okE = VC.claims(empty, ENV)
    local okS = VC.claims(single, ENV)
    local okM, reasonM = VC.claims(mixture, ENV)
    local dbgEnv = { scriptSpam = false, taintedText = true, debugMode = true,
        tooltipDebugInfo = false, admin = false, showModInfo = false }
    local okDbg, reasonDbg = VC.claims(single, dbgEnv)
    local ctx = mockCtx()
    local emitted = VC.emitAll(ctx, single, ENV)
    return Assert.equal(nEmpty, 2, "empty: weight + Amount")
        and Assert.equal(nSingle, 4, "single: weight + Amount + bar + tainted")
        and Assert.isTrue(okE and okS and true, "empty/single claim")
        and Assert.isTrue(not okM, "mixture refused")
        and Assert.equal(reasonM, "fluid-mixture")
        and Assert.isTrue(not okDbg, "fluid refuses in debug")
        and Assert.equal(reasonDbg, "fluid-debug-rows")
        and Assert.equal(ctx.rows, nSingle, "fluid emit parity")
        and Assert.equal(emitted, nSingle)
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
        { plainFacts({ isHandWeapon = true }), "weapon-facts-missing" },
        { plainFacts({ isFood = true }), "food-facts-missing" },
        { plainFacts({ isFood = true, food = {}, hasSpices = true }), "spices-strip" },
        { plainFacts({ isClothing = true }), "clothing-facts-missing" },
        { plainFacts({ isClothing = true, clothing = {}, isAlarmClockClothing = true }),
            "alarm-facts-missing" },
        { plainFacts({ isInventoryContainer = true }), "container-facts-missing" },
        { plainFacts({ isLiterature = true }), "literature-facts-missing" },
        { plainFacts({ isWeaponPart = true }), "weaponpart-facts-missing" },
        { plainFacts({ isAnimal = true }), "animal-facts-missing" },
        { plainFacts({ isAnimal = true, animalFacts = { cheat = true } }),
            "animal-cheat-rows" },
        { plainFacts({ hasFluidContainer = true }), "fluid-facts-missing" },
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
    local okM, reasonM = VC.claims(plainFacts({ isVanilla = false }), modinfo)
    local okMRead = VC.claims(plainFacts({ isVanilla = false,
        modInfo = { name = "VPS", overrides = 0, names = {} } }), modinfo)
    local okMVanilla = VC.claims(plainFacts({ isVanilla = true }), modinfo)
    return Assert.isTrue(not okU, "unreadable Tooltip.Info refused")
        and Assert.equal(reasonU, "debug-option-unreadable")
        and Assert.isTrue(okD and true, "debug session with Tooltip.Info off claims")
        and Assert.isTrue(okA and true, "admin session claims (Loot Category ported)")
        and Assert.isTrue(not okM, "mod item with unreadable WorldDictionary refused")
        and Assert.equal(reasonM, "mod-info-unreadable")
        and Assert.isTrue(okMRead and true, "mod item with readable mod info claims")
        and Assert.isTrue(okMVanilla and true, "vanilla item fine with ShowItemModInfo on")
end

tests["modinfo_rows_gate_and_emit"] = function()
    -- java:1213-1232 — 'Mod: X' + override rows (1 => inline, >1 => header +
    -- one per mod), only while the ShowItemModInfo option is on.
    local modinfo = { scriptSpam = false, taintedText = true, debugMode = false,
        tooltipDebugInfo = false, admin = false, showModInfo = true }
    local plain = plainFacts({ isVanilla = false,
        modInfo = { name = "VorpallySauced", overrides = 0, names = {} } })
    local one = plainFacts({ isVanilla = false,
        modInfo = { name = "VPS", overrides = 1, names = { "OtherMod" } } })
    local many = plainFacts({ isVanilla = false,
        modInfo = { name = "VPS", overrides = 3, names = { "A", "B", "C" } } })
    local offOpt = VC.rowsFor(plain, ENV) -- option off: no rows
    local nPlain = VC.rowsFor(plain, modinfo)
    local nOne = VC.rowsFor(one, modinfo)
    local nMany = VC.rowsFor(many, modinfo)
    local ctx = mockCtx()
    local emitted = VC.emitAll(ctx, many, modinfo)
    return Assert.equal(offOpt, 1, "option off: weight only")
        and Assert.equal(nPlain, 2, "weight + Mod name")
        and Assert.equal(nOne, 3, "+ inline override")
        and Assert.equal(nMany, 6, "+ header + 3 override rows")
        and Assert.equal(ctx.rows, nMany, "modinfo emit parity")
        and Assert.equal(emitted, nMany)
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
