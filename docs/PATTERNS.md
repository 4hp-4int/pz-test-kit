# Patterns for advanced mods

Real patterns drawn from shipped PZ mods (SaucedCarts, VorpallySauced, and others), each framed as: "here's a bug we shipped → here's the test that would have caught it → here's the refactor the test implies."

Every pattern here comes from a bug report, not a hypothetical. If you're about to write a test and can't think of a specific regression it prevents, you're probably testing plumbing — skip it.

---

## Container override

**Scenario:** Your mod extends or replaces `ItemContainer.getCapacity` / `hasRoomFor` via `__classmetatables` hooks. Capacity is read dynamically from sandbox vars or ModData. Every transfer, drag-and-drop, or HUD render queries it.

**Shipped bug:** SaucedCarts v2.1.2 cached capacity at cart creation. When admin changed sandbox mid-game, live carts kept the old cap. Users reported "I changed the multiplier but my existing carts still have 50kg cap."

### Test that would have caught it

```lua
local F = PZTestKit.Fixtures

tests["capacity_recomputes_on_each_call_no_caching"] = function()
    local cart = makeRegisteredCart()
    local inner = cart:getItemContainer()

    local cap200
    F.withSandbox("YourMod", { CapacityMultiplier = 200 }, function()
        cap200 = YourMod.CapacityOverride._getCartRawCapacity(inner)
    end)

    local cap100
    F.withSandbox("YourMod", { CapacityMultiplier = 100 }, function()
        cap100 = YourMod.CapacityOverride._getCartRawCapacity(inner)
    end)

    if not Assert.equal(cap200, 200, "first call saw 200%") then return false end
    return Assert.equal(cap100, 100, "second call saw 100% (no caching)")
end
```

### Design rule the test implies

**Read sandbox on every call, never on creation.** If a function's return value depends on a sandbox var, never cache it. The cost of recomputing is pennies; the cost of a caching bug is a user-facing inconsistency that takes a weekend to hunt.

### Related coverage to add

- Non-cart container returns nil (don't apply override to bags)
- Unregistered cart type returns nil (graceful fallback)
- Missing sandbox var defaults to 100% (defensive init)
- Floor-type guard (trait bonuses don't apply to floor containers)
- 10 capacity lookups produce 0 network packets (read-only contract)

---

## Interceptor

**Scenario:** You hook `ISInventoryTransferAction.new` to redirect specific transfer cases through a custom action that bypasses vanilla's `TransactionManager.isConsistent` (which breaks on dedi MP when server-Java `getEffectiveCapacity` disagrees with your Lua override).

**Shipped bug:** SaucedCarts v2.1.3 matched only on `destContainer`. Of the 4 cart-involved transfer directions (player↔in-hand-cart, player↔ground-cart), 3 silently fell through to vanilla. Users reported "transfers to ground carts work but taking items out doesn't."

### Test that would have caught it

Build a direction matrix. Prove the classifier matches every cart-involved case:

```lua
local function classifyCase(srcKind, destKind, expectedDirection)
    local src = (srcKind == "cart")  and makeCartInner() or makePlayerInv()
    local dst = (destKind == "cart") and makeCartInner() or makePlayerInv()
    local direction, matched = YourMod.CartTransferInterceptor.classifyTransfer(src, dst)
    return direction, matched
end

tests["classify_inv_to_ground_cart_is_in"] = function()
    local direction, cart = classifyCase("inv", "cart")
    return Assert.equal(direction, "in", "inv -> cart is direction=in")
end

tests["classify_ground_cart_to_inv_is_out"] = function()
    local direction, cart = classifyCase("cart", "inv")
    return Assert.equal(direction, "out", "cart -> inv is direction=out")
end

tests["classify_inv_to_inhand_cart_is_in"] = function()
    -- In-hand cart = cart container parented to IsoGameCharacter.
    -- Earlier code had a "parent is character → skip" guard that broke this case.
    local direction, cart = classifyInHandCartCase()
    return Assert.equal(direction, "in")
end

tests["classify_inhand_cart_to_inv_is_out"] = function()
    local direction, cart = classifyInHandCartCase("out")
    return Assert.equal(direction, "out")
end
```

### Design rule the test implies

**Any symmetric interceptor needs a matrix test.** If your classifier looks at src AND dest, every (src-kind × dest-kind) cell needs a test. A single direction's worth of assertions silently lets three others ship broken.

### Simulate the regression

Once the matrix tests pass, revert your widening fix and prove the tests catch the regression:

```lua
-- Temporarily replace the src-or-dest classifier with the v2.1.3 dest-only version.
-- Rerun the matrix tests. Confirm the 3 broken cases fail. Restore the fix.
```

This "regression simulation" step is how you know your tests actually guard the behavior rather than just asserting what the code already does.

---

## Timed action MP-safety

**Scenario:** Your mod defines a timed action (`ISMyAction = ISBaseTimedAction:derive(...)`) that runs on both client and server in MP. PZ's `NetTimedAction` sync serializes the action's fields across the wire. Only primitives survive.

**Shipped bug:** Early SaucedCarts versions stored `cartItem` (an `InventoryItem` reference) on the action. On the server side, the reference deserialized as a different object (or nil on full-load conditions), causing `isValid()` to fail mysteriously.

### Test that would have caught it

Lock the primitives-only contract:

```lua
tests["pickup_constructor_stores_primitives_only"] = function()
    local action = ISCartPickupAction:new(player, 10, 20, 0, 12345)

    for k, v in pairs(action) do
        local t = type(v)
        -- `character` is a known exception (ISBaseTimedAction.new sets it)
        -- `action` is the Java LuaTimedActionNew wrapper
        if t ~= "number" and t ~= "string" and t ~= "boolean" and t ~= "nil"
            and k ~= "character" and k ~= "action" then
            return Assert.isTrue(false,
                "unexpected non-primitive field '" .. k .. "' of type " .. t)
        end
    end
    return true
end
```

### Companion: the "From" helper extracts primitives correctly

The UX entry points (context menu, hotkey) receive live Java refs and need to extract primitives for the constructor:

```lua
function ISCartPickupAction.FromWorldItem(character, worldItem)
    local square = worldItem:getSquare()
    return ISCartPickupAction:new(
        character,
        square:getX(), square:getY(), square:getZ(),
        worldItem:getItem():getID()
    )
end
```

Prove the extraction:

```lua
tests["FromWorldItem_extracts_squareX_squareY_itemId"] = function()
    local worldItem = makeWorldItemAt(5, 7, 0, 42)
    local action = ISCartPickupAction.FromWorldItem(player, worldItem)
    if not Assert.equal(action.squareX, 5) then return false end
    if not Assert.equal(action.squareY, 7) then return false end
    return Assert.equal(action.itemId, 42)
end
```

### Design rule the test implies

**Store serializable IDs, re-find references on each method call.** `findWorldItem()` / `findItem()` / `findCart()` helpers re-resolve by stored IDs + coords. This costs a few cycles but survives NetTimedAction serialization losslessly.

---

## ModData migration

**Scenario:** Your mod's ModData schema evolves. v1 has `kills`, v2 adds `attachments`, v3 splits `capacity` into `rawCapacity + sandbox multiplier`. Load-time migrator upgrades old saves in place.

**Shipped bug:** Migrator ran twice on the same cart per load because the version check was broken. Users reported capacity values doubling after reload.

### Test pattern — load fixtures for each version

Seed fixtures in your tests directory:

```lua
-- tests/fixtures/moddata_v1.lua
return {
    SaucedCarts = {
        kills = 42,
        schemaVersion = 1,
    },
    SaucedCarts_capacity = 100,
}
```

Tests:

```lua
tests["v1_save_migrated_to_v3_shape"] = function()
    local cart = F.item({ modData = loadModDataFixture("moddata_v1.lua") })
    YourMod.Migration.run(cart)

    local md = cart:getModData()
    if not Assert.equal(md.SaucedCarts.schemaVersion, 3, "version bumped") then return false end
    if not Assert.notNil(md.SaucedCarts_rawCapacity, "rawCapacity populated") then return false end
    -- v1's kills preserved
    return Assert.equal(md.SaucedCarts.kills, 42, "kills not lost in migration")
end

tests["migration_is_idempotent"] = function()
    local cart = F.item({ modData = loadModDataFixture("moddata_v3.lua") })
    local before = deepCopy(cart:getModData())
    YourMod.Migration.run(cart)
    YourMod.Migration.run(cart)   -- second run should be a no-op
    return Assert.equal(deepCompare(cart:getModData(), before), true,
        "idempotent: running migration on v3 ModData twice leaves it unchanged")
end

tests["unknown_future_version_logged_and_skipped"] = function()
    local cart = F.item({ modData = { SaucedCarts = { schemaVersion = 99 } } })
    local ok = pcall(YourMod.Migration.run, cart)
    return Assert.isTrue(ok, "future-version ModData doesn't crash the migrator")
end
```

### Design rule the test implies

**Every schema version needs a fixture + a round-trip test.** Migrations are one of the few paths where a bug corrupts user saves irreversibly. Cheap tests, very expensive failure mode.

### Bonus: MP load-time race

On MP dedi, `OnGameStart` doesn't fire for mod Lua. Migrators tied to `OnGameStart` never run on dedi. Use `OnServerStarted` + load-time guard:

```lua
tests["migration_install_hooks_both_OnGameStart_and_OnServerStarted"] = function()
    -- Count Events.OnGameStart and Events.OnServerStarted listeners added.
    local gsCount = countListeners("OnGameStart", YourMod.Migration.run)
    local ssCount = countListeners("OnServerStarted", YourMod.Migration.run)
    if not Assert.greater(gsCount, 0, "hooked OnGameStart") then return false end
    return Assert.greater(ssCount, 0, "hooked OnServerStarted (dedi fallback)")
end
```

---

## OnBreak hook

**Scenario:** Your mod extends `OnBreak.HeadHandler` to preserve state when a weapon breaks (e.g., soul transfer: axe breaks → axe head still carries the kill count so reassembly restores it).

**Shipped bug:** OnBreak ran twice for the same break event on dedicated servers (both client and server dispatch fired). Each ran produced a duplicate axe head in the world.

### Test

```lua
tests["OnBreak_preserves_soul_exactly_once_per_break"] = function()
    local axe = makeBloodedAxe({ kills = 100 })
    local sq = F.square(0, 0, 0)
    local player = F.player({ square = sq })

    YourMod.onWeaponBreak(axe, player)
    -- Count head items on the square
    local heads = 0
    for i = 0, sq:getWorldObjects():size() - 1 do
        local obj = sq:getWorldObjects():get(i)
        if obj:getItem() and obj:getItem():getFullType():find("AxeHead") then
            heads = heads + 1
        end
    end
    return Assert.equal(heads, 1, "exactly one head dropped per break (no dual-dispatch dupe)")
end
```

And for soul preservation:

```lua
tests["OnBreak_writes_soul_to_head_modData"] = function()
    local axe = makeBloodedAxe({ kills = 100 })
    local sq = F.square(0, 0, 0)
    YourMod.onWeaponBreak(axe, F.player({ square = sq }))
    local head = sq:getWorldObjects():get(0):getItem()
    return Assert.equal(head:getModData().YourMod_Transfer.kills, 100,
        "soul ModData transferred to head for reassembly")
end
```

### Design rule the test implies

**Hooks that fire on both client and server need dedup.** Either gate with `isServer()` / `isClient()`, use a transaction ID, or use the kit's `eventSpy` to test "event fires at most once per logical break."

---

## Custom network commands (client → server)

**Scenario:** Your client triggers a server-authoritative operation via `sendClientCommand("YourMod", "doThing", args)`. Server handler runs, modifies state, broadcasts result. Client receives `OnServerCommand` and updates UI.

### Test the full round-trip offline

Use `networkSpy` to prove the client fires exactly one command, the server handler is invokable directly, and the state mutation persisted:

```lua
tests["client_server_roundtrip_doThing"] = function()
    local w = F.world()

    -- Client side: trigger the action
    YourMod.Client.doThing(argsTable)

    -- Assert exactly one command went out
    if not Assert.equal(w.network:count("sendClientCommand"), 1,
        "one command per logical client action") then
        w:teardown(); return false
    end
    local sent = w.network:callsFor("sendClientCommand")[1]

    -- Directly invoke the server handler (simulates server-side receipt)
    local handler = YourMod.Network._getServerHandler("doThing")
    if not Assert.notNil(handler, "server handler registered") then
        w:teardown(); return false
    end
    handler(mockPlayer, sent[4])   -- sent[4] is the args table

    -- Assert server-side state mutation
    local ok = Assert.equal(YourMod.State.thingCount, 1,
        "server handler applied the state change")
    w:teardown()
    return ok
end
```

### Design rule the test implies

**Expose your server handlers as `_getServerHandler(name)` for testing.** If your Network module stashes handlers in a private table, add a test-only accessor. Underscore prefix signals "do not call from production."

---

## Rate-limiting / throttling

**Scenario:** Your mod wraps `sendServerCommand` with a rate limiter to prevent spam. Maybe one command per 100ms per player.

**Shipped bug:** Rate limiter applied to legitimate inventory-drag-storm operations (user drags 10 items rapidly). 9 of 10 silently dropped. Users reported "sometimes the cart doesn't accept items when I drag fast."

### Test

```lua
tests["rate_limiter_does_not_drop_legitimate_rapid_transfers"] = function()
    local w = F.world()
    local player = w:player({ square = w:square(0, 0, 0) })

    for i = 1, 10 do
        YourMod.transferItem(player, F.item({ id = 100 + i }), src, dst)
    end

    local count = w.network:count("sendServerCommand")
    w:teardown()
    return Assert.equal(count, 10, "all 10 transfers went through, no throttling")
end
```

### Design rule the test implies

**If you add a rate limiter, write the test that proves legitimate bursts pass.** If the test fails, the rate limit is wrong for your use case. Vanilla PZ doesn't rate-limit inventory transfers — your mod probably shouldn't either.

---

## Cross-mod integration

**Scenario:** Your mod depends on TooltipLib / another shared library. You want to test your integration without forcing users to install the dependency for your tests.

### Option 1: declare dependency in `pz-test.lua`

```lua
return {
    dependencies = { "../TooltipLib" },
    -- ...
}
```

The sibling directory's `media/lua/` tree is indexed into the require resolver. `require "TooltipLib/Core"` works from your test code.

### Option 2: stub the dependency

For integrations where the dep's full surface isn't needed, stub specific functions in a test setup file:

```lua
-- tests/setup/stub_tooltiplib.lua
TooltipLib = TooltipLib or {}
TooltipLib.registerProvider = function(name, provider)
    YourMod._testStubProviders = YourMod._testStubProviders or {}
    YourMod._testStubProviders[name] = provider
end
```

Test:

```lua
tests["tooltip_provider_registered_with_correct_id"] = function()
    YourMod.Tooltips.init()
    return Assert.notNil(YourMod._testStubProviders.YourMod_CartInfo,
        "provider registered via stubbed TooltipLib")
end
```

---

## Translation formatting

**Scenario:** Your mod has UI strings with placeholders — `"Hold %1 for the weapon's personality"` — and a helper that fills them in.

**Shipped bug:** VorpallySauced 1.12.0 fetched those strings with a bare `getText(key)` and substituted the placeholder in Lua. Every hover over a weapon wrote a line to the user's debug log:

```
WARN: ERROR: Missing arguments for "UI_VorpallySauced_Personality_Hint"
```

The tooltip rendered correctly the whole time. Nobody noticed until a user pasted their log.

The mechanism is two Translator behaviors composing. The JSON loader's `formatFixer` (`FORMAT_TOKEN = "%%|%([1-9])"`) rewrites the file's `%1` into the Java specifier `%1$s`. Then, since 42.20.1, `getText` runs the result through `String.formatted()` whether or not you passed arguments. A bare fetch leaves the specifier unfed, Java throws `MissingFormatArgumentException`, Translator catches it and hands the text back untouched. Correct output, one WARN per call.

### Why no test caught it

The kit's old `getText` mock was `function getText(key) return key end`. An identity function has no formatter, so it cannot produce this failure. Any suite built on it is blind to the entire class: bugs whose only symptom is a side channel.

Turn on the real one:

```lua
-- pz-test.lua
translate = "EN",
```

The runner parses `media/lua/shared/Translate/EN/*.json` for your mod and its declared `dependencies`, then reproduces the loader pass, `fixupArgs`, and `String.formatted` with its catch ladder. Warnings are recorded rather than thrown, so you can assert on them.

### Test that would have caught it

```lua
tests["fmttext_feeds_specifier_so_no_missing_argument_warn"] = function()
    local out
    local warns = PZTestKit.Translate.capture(function()
        out = YourMod.fmtText("UI_YourMod_Hint", "Shift")
    end)
    if not Assert.equal(#warns, 0, "no MissingFormatArgument WARN logged") then return false end
    return Assert.isNil(out:find("%%1"), "specifier consumed, none left in the text")
end
```

### Sweep the whole bundle

The single-string test guards one key. The sweep guards the ones you haven't written yet. Fetch every key with no arguments and assert that the set which warns is the set you expect:

```lua
local EXPECTED_PLACEHOLDER_KEYS = {
    UI_YourMod_Hint = true,
    UI_YourMod_KillsToUpgrade = true,
    -- ...
}

tests["bundle_has_no_unexpected_format_specifiers"] = function()
    local unexpected = {}
    local warns = PZTestKit.Translate.capture(function()
        for key in pairs(_pz_translations) do
            if key:find("^UI_YourMod_") then getText(key) end
        end
    end)
    for _, w in ipairs(warns) do
        if not EXPECTED_PLACEHOLDER_KEYS[w.key] then
            unexpected[#unexpected + 1] = w.key .. " (" .. w.kind .. ")"
        end
    end
    return Assert.equal(#unexpected, 0,
        "no unlisted string carries a format specifier: " .. table.concat(unexpected, ", "))
end
```

Filter to your own prefix — the harness also loads your dependencies' bundles, and their strings are not your suite's business. A new key with a `%1` in it now fails on the next run, and whoever added it has to either feed it or add it to the list deliberately.

### The `%d` corollary

`fixupArgs` converts **every** Double to a String on the way into the formatter, both branches:

```java
args[i] = d == (long)d ? Long.toString((long)d) : args[i].toString();
```

A Lua number reaches Java as a Double, so it arrives at the formatter as a String. `%d` cannot take a String. Any `%d` in a translation throws `IllegalFormatConversionException` every single time and renders with a literal `%d` in the text. The kit reports these with `kind = "formatting"`. Use `%1` and let the loader make it `%1$s`.

### Design rule the test implies

**Assert on the side channel, not only the output.** A whole class of bug produces correct rendering and a log line. If your only assertion is "the string looks right," you will ship it. This generalizes past translations: silent `pcall` swallows, deprecation warnings, and double-dispatch all behave the same way.

---

## Don't assert on mock artifacts

**Scenario:** Turning on a more faithful mock breaks tests that were passing.

**What happened:** enabling `translate = "EN"` broke two VorpallySauced tests that read like this:

```lua
if canMockTime() then
    -- Offline: mock getText returns the key verbatim
    local hasTraitKey = string.find(result, "Trait_Proven") ~= nil
    ok = Assert.isTrue(hasTraitKey, "formatCharacter contains primary trait key") and ok
else
    -- In-game: getText returns localized text. Just verify length.
    ok = Assert.greater(#result, #primaryOnly, "modifier adds text") and ok
end
```

Both branches are the same test written twice, and the offline branch asserts on a property of the harness rather than a property of the code. The moment the harness got closer to the game, it failed — while the production code was fine.

### The fix

Resolve the same key the implementation resolves:

```lua
local primary = getText("UI_YourMod_Trait_Proven")
ok = Assert.notNil(string.find(result, primary, 1, true),
    "formatCharacter contains the primary trait text") and ok
```

One branch. Passes offline, passes in game, and now actually checks that `formatCharacter` used the key you think it used.

### Design rule the test implies

**When a test branches on which environment it's in, one of the branches is usually testing the mock.** Route the assertion through the same call the production code makes and the branch disappears. Watch for `find(result, text)` without the plain flag while you're there — a translated string with a `(` in it turns into a pattern and matches nothing.

---

## Prove the harness can fail

The Interceptor section above suggests reverting your fix by hand to confirm the tests catch the regression. That works once. Better to keep the check.

Sitting next to the WARN test is a second one asserting that the removed shape still trips the harness:

```lua
tests["fmttext_harness_detects_the_unfed_specifier"] = function()
    local raw
    local warns = PZTestKit.Translate.capture(function()
        raw = getText("UI_YourMod_Hint")           -- the old, bad shape
    end)
    if not Assert.equal(#warns, 1, "bare getText on a %1 string logs one WARN") then return false end
    if not Assert.equal(warns[1].kind, "missing", "and it is the missing-argument kind") then return false end
    return Assert.notNil(raw:find("%%1%$s"), "text comes back with the specifier unconsumed")
end
```

Without it, `Assert.equal(#warns, 0)` also passes when the warning plumbing is broken, when the bundle failed to load, or when the key is missing. A zero-count assertion is worth exactly as much as your confidence that a nonzero count is reachable.

### Design rule the test implies

**Every "this doesn't happen" assertion needs a sibling proving it can.** Cheap to write, and it's the difference between a green suite and a green suite that means something.

---

## Static checks for what runtime tests can't see

**Scenario:** The invariant is about call sites, and a runtime test only visits the call sites your tests happen to exercise.

The translation fix above left a hole. The suite proves that the code paths it runs don't warn. It says nothing about a bare `getText("UI_YourMod_Hint")` sitting in a context menu nobody wrote a test for. Coverage would tell you the line is unvisited; it wouldn't tell you the line is wrong.

So pair the runtime test with a source scan. VorpallySauced's `localisation_validator.py` collects every EN key whose value matches `%[1-9]`, then greps the Lua tree for a literal single-argument fetch of it:

```python
bare = re.compile(r'getText\s*\(\s*"' + re.escape(key) + r'"\s*\)')
```

Test directories are skipped, since the sensitivity test above fetches bare on purpose. Keys with no call site at all are reported as a note rather than a failure — inert, but worth knowing about. It found six dead keys nobody had noticed.

Then plant a regression and confirm the check fails:

```bash
printf 'local x = getText("UI_YourMod_Hint")\n' > media/lua/client/_tmp.lua
python tools/validators/localisation_validator.py    # expect FAIL
rm media/lua/client/_tmp.lua
```

### Design rule the test implies

**Ask whether your invariant is about behavior or about text.** Behavior belongs in the Kahlua suite. "No call site anywhere may do X" is a property of the source, and a fifteen-line regex in CI covers all of it, including the code your tests never reach.

---

## Closing observations

**A good test prevents a specific regression.** If you can't name the regression, the test is decoration.

**A great test prevents a regression that costs more than the test does to maintain.** Duplication bugs that corrupt user saves: worth any test cost. Plumbing tests of private helpers: likely not.

**Test counters, not behavior.** "Did the function succeed?" is table stakes. "Did it fire `transmitCompleteItemToClients` exactly once?" is the assertion that survives TIS refactors.

**When a test is hard to write, the code is probably wrong.** If testing requires mocking 15 methods, your code does too much. Split it.

**A mock that can't reproduce the failure hides it forever.** Every simplification in the harness marks off a region of bug-space your suite cannot reach. That's usually a fine trade, but make it knowingly: when a user reports something your green suite should have caught, check whether the mock was even capable of producing it before you go looking for the missing assertion.

When you find a new pattern worth documenting, contribute it back — these case studies are the highest-value docs in the repo for advanced users.
