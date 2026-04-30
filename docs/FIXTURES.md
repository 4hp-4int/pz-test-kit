# Fixtures

`PZTestKit.Fixtures` is a library of Lua-table stand-ins for PZ's Java-backed objects (`InventoryItem`, `ItemContainer`, `IsoGridSquare`, `IsoWorldInventoryObject`, `IsoPlayer`, `HandWeapon`, `IsoZombie`, etc.).

**Design principle: fidelity over convenience.** Every mutating method mirrors the observable side effect of the real Java class it stands in for, and bumps a counter for tests to assert on. When your mod code is supposed to fire "exactly once," a `Assert.equal(counter, 1)` catches the regression at the exact line it starts misbehaving.

This document is the API reference. For the "why counters" framing and war stories, see the [README](../README.md) and [PATTERNS.md](PATTERNS.md).

---

## Loading

`Fixtures.lua` is auto-loaded by the test runner. No require needed. Use it directly:

```lua
local F = PZTestKit.Fixtures
```

All counters are exposed on each mock's `_private` table — underscore prefix means "do not call from production code, only from tests."

---

## `Fixtures.item(opts) → InventoryItem`

Stand-in for `zombie.inventory.InventoryItem`. Used as the base for cart items, weapons, and anything your mod treats as a concrete inventory item.

### Options

| Key | Default | Purpose |
|---|---|---|
| `id` | random int | Stable ID for the item. Must be unique if you add multiple items to the same container. |
| `fullType` | `"Base.RippedSheets"` | PZ fullType string (`"Base.Axe"`, `"SaucedCarts.ShoppingCart"`, etc.). |
| `weight` | `0.1` | Actual weight in kg. Used by container `hasRoomFor` math. |
| `condition` | `100` | Current condition. |
| `conditionMax` | `100` | Max condition. |
| `modData` | `{}` | Pre-populated ModData table. Production code reads/writes via `:getModData()`. |
| `favorite` | `false` | Return value of `:isFavorite()`. |
| `uses` | `1.0` | Return value of `:getCurrentUsesFloat()`. Used by durability/drainable checks. |
| `isWeapon` | `false` | Return value of `:IsWeapon()`. |

### Methods (mirror InventoryItem.java)

Accessors: `getID`, `getFullType`, `getName`, `getDisplayName`, `getType`, `getActualWeight`, `getUnequippedWeight`, `getWeight`, `setActualWeight`, `getCondition`, `setCondition`, `getConditionMax`, `getModData`, `getContainer`, `getWorldItem`, `setWorldItem`, `IsWeapon`, `isFavorite`, `setFavorite`, `getCurrentUsesFloat`, `setUsedDelta`, `setJobDelta`, `setJobType`.

### Counters on `_private`

| Counter | Bumped by | Catches |
|---|---|---|
| `setWorldItemCount` | `:setWorldItem(v)` | **Pickup path firing twice.** Vanilla `ISGrabItemAction:transferItem` sets worldItem to nil exactly once. If your pickup code races with a second path, this counter fires 2+. |
| `setJobDeltaCount` | `:setJobDelta(v)` | **Progress-bar churn.** If your timed action updates the bar more than expected per tick, counter surges. Useful for catching infinite-loop regressions in `:update()`. |

---

## `Fixtures.container(opts) → ItemContainer`

Stand-in for `zombie.inventory.ItemContainer`. The most-mocked object in any cart / bag / vehicle-storage mod.

### Options

| Key | Default | Purpose |
|---|---|---|
| `parent` | nil | IsoObject parent. Character inventory → an `IsoPlayer` mock. Vehicle storage → a `BaseVehicle` placeholder `{_type = "BaseVehicle"}`. World item → an `IsoWorldInventoryObject`. |
| `containingItem` | nil | For cart/bag inner containers: the `InventoryItem` wrapping this container. Gives `:getContainingItem()` a real value. |
| `typeName` | `"none"` | `:getType()` return. Common values: `"none"` (player main inv), `"floor"` (ground container), `"ShoppingCart"` (custom type). |
| `capacity` | `50` | Default vanilla 50-cap. |
| `weightReduction` | `0` | Percentage. 95 = items weigh 5% inside this container. |
| `hasRoom` | nil (compute) | Force boolean for `:hasRoomFor()`. nil = compute from weight vs capacity. |

### Methods

Full surface: `getType`, `getParent`, `getContainingItem`, `getCapacity`, `setCapacity`, `getEffectiveCapacity`, `getWeightReduction`, `setWeightReduction`, `getCapacityWeight`, `hasRoomFor`, `contains`, `containsID`, `getItemWithID`, `getItemById`, `AddItem` / `addItem`, `DoAddItemBlind`, `Remove` / `DoRemoveItem`, `getItems`, `setDrawDirty`, `isDrawDirty`, `setExplored`, `isExistYet`, `isItemAllowed`, `isInside`, `isInCharacterInventory`, `setHasBeenLooted`.

### Fidelity-critical behavior

- **`AddItem` dupe-id guard.** Matches `ItemContainer.java:453-455`: if `containsID(item.id)` is true, returns the existing item without adding a duplicate. Production code that assumes "AddItem always grows the list" gets caught.
- **`AddItem` back-ref management.** Sets `item.container = self` (via `_setContainer`) and, if the item had a previous container, removes it from there first. Matches lines 466-471.
- **`getItemById` recursion.** Walks into nested `InventoryContainer` items' inner containers. Matches lines 3369-3385. This is the contract `player:getInventory():getItemById(cartId)` relies on.
- **Dirty flag semantics.** `AddItem`/`Remove` bump `dirtyCount` only when `parent` is set, matching the Java guard.

### Counters on `_private`

| Counter | Bumped by | Catches |
|---|---|---|
| `drawDirtyCount` | `AddItem`, `Remove`, `setDrawDirty` | **UI refresh storms.** If your code marks the container dirty too often, the inventory pane re-renders every frame. |
| `dirtyCount` | `AddItem`, `Remove` (with parent) | **Save-data storms.** Dirty containers get persisted on next tick. High count = your code is thrashing the save layer. |
| `flagForHotSaveCount` | `AddItem` (with parent) | **Hot-save pressure.** Parent objects marked for hot save get serialized repeatedly. |

### Regression pattern

```lua
-- Your mod's transfer code should fire exactly 1 AddItem per logical move.
-- If it fires 2, something in your code is duplicate-dispatching.
tests["transfer_produces_one_AddItem_per_move"] = function()
    local src = F.container()
    local dst = F.container()
    local item = F.item({ id = 100 })
    src:AddItem(item)
    YourMod.doTransfer(item, src, dst)
    return Assert.equal(dst._private.drawDirtyCount, 1,
        "dst marked dirty exactly once per transfer")
end
```

---

## `Fixtures.square(x, y, z) → IsoGridSquare`

Stand-in for `zombie.iso.IsoGridSquare`. Critical for testing ground-item flows.

### Methods

`getX`, `getY`, `getZ`, `getApparentZ`, `isAdjacentTo`, `isBlockedTo`, `getObjects`, `getWorldObjects`, `transmitRemoveItemFromSquare`, `removeWorldObject`, `AddWorldInventoryItem`, `AddSpecialObject`, `RecalcProperties`, `RecalcAllWithNeighbours`, `getBuilding`.

### The fidelity story — 4-arg vs 5-arg AddWorldInventoryItem

The real Java class has multiple overloads:

```java
public InventoryItem AddWorldInventoryItem(InventoryItem item, float x, float y, float height) {
    return this.AddWorldInventoryItem(item, x, y, height, true);  // transmit DEFAULTS TO TRUE
}
public InventoryItem AddWorldInventoryItem(InventoryItem item, float x, float y, float height, boolean transmit) {
    ...
}
```

**The 4-arg overload broadcasts `transmitCompleteItemToClients` internally** (defaults `transmit=true`). If your mod calls the 4-arg form AND then manually calls `transmitCompleteItemToClients`, you double-broadcast. Every client sees two world items with the same ID. This is exactly how the SaucedCarts v2.1.4 mid-session "ghost items on every drop" regression shipped.

**The fixture reproduces this.** Our mock's `AddWorldInventoryItem` fires the internal `transmitCompleteItemToClients` when called with 4 args (or 5 args with `transmit=true`) and skips it when `transmit=false`. Your test captures the `argCount` that was used:

```lua
sq:AddWorldInventoryItem(item, 0.5, 0.5, 0.0)         -- argCount = 4, transmit defaults true
sq:AddWorldInventoryItem(item, 0.5, 0.5, 0.0, false)  -- argCount = 5, no internal transmit
```

### Counters on `_private`

| Counter | Bumped by | Catches |
|---|---|---|
| `transmitRemoveCount` | `:transmitRemoveItemFromSquare(obj)` | **Pickup/drop broadcast storm.** If your code fires remove twice per logical pickup, this counts it. |
| `transmitRemoveArgs` (table) | same | Lets you assert WHICH worldItem was removed (catches "removed the wrong object" bugs). |
| `addWorldInvCalls` (table) | `:AddWorldInventoryItem(...)` | Each call recorded with `{item, x, y, h, transmit, argCount}`. Assert `argCount == 5` to lock the non-double-broadcast form. |

### Regression patterns

**Lock the 5-arg form:**

```lua
tests["drop_uses_5arg_AddWorldInventoryItem_not_4arg"] = function()
    local sq = F.square(0, 0, 0)
    YourMod.dropToGround(item, sq)
    return Assert.equal(sq._private.addWorldInvCalls[1].argCount, 5,
        "5-arg form used — prevents engine-side double-broadcast")
end
```

**Lock single-broadcast:**

```lua
tests["drop_broadcasts_complete_item_exactly_once"] = function()
    local sq = F.square(0, 0, 0)
    YourMod.dropToGround(item, sq)
    return Assert.equal(item:getWorldItem()._private.transmitCompleteCount, 1,
        "one broadcast per drop, not two")
end
```

---

## `Fixtures.worldItem(item, square) → IsoWorldInventoryObject`

Stand-in for `zombie.iso.objects.IsoWorldInventoryObject`. The wrapper around an `InventoryItem` when it's sitting on the ground.

Usually you don't create these directly — `square:AddWorldInventoryItem(item, ...)` creates one and attaches it to `item` via `setWorldItem`. Build one explicitly only when you want to test a pickup action against a pre-existing world item.

### Methods

`getItem`, `getSquare`, `getX`, `getY`, `getZ`, `getObjectIndex`, `removeFromWorld`, `removeFromSquare`, `setSquare`, `setWorldZRotation`, `setIgnoreRemoveSandbox`, `setExtendedPlacement`, `transmitCompleteItemToClients`.

### Counters on `_private`

The lifecycle counters correspond to vanilla `ISGrabItemAction:transferItem`'s pickup sequence:

```lua
-- Vanilla pickup, one of each:
self.item:getSquare():transmitRemoveItemFromSquare(self.item)
self.item:removeFromWorld()
self.item:removeFromSquare()
self.item:setSquare(nil)
inventoryItem:setWorldItem(nil)
```

| Counter | Bumped by | Catches |
|---|---|---|
| `removeFromWorldCount` | `:removeFromWorld()` | **Pickup fired twice.** Should be 1 per pickup. |
| `removeFromSquareCount` | `:removeFromSquare()` | Same. |
| `setSquareNilCount` | `:setSquare(v)` when v is nil | **Stale-square regression.** Old code used `sq:removeWorldObject(obj)` which skips this call, leaving `worldItem.square` dangling. |
| `transmitCompleteCount` | `:transmitCompleteItemToClients()` | **Drop broadcasts twice** (see 4-arg vs 5-arg above). |
| `setIgnoreRemoveSandboxCount` | `:setIgnoreRemoveSandbox(flag)` | **Sandbox-despawn regression.** Vanilla's floor-sandbox auto-removes world items after N hours. If your drop code skips this, your dropped items vanish. |

---

## `Fixtures.player(opts) → IsoPlayer`

Stand-in for `zombie.characters.IsoPlayer` + parent class `IsoGameCharacter`. Comprehensive surface for timed actions, hand management, vehicles, farming state.

### Options

| Key | Default | Purpose |
|---|---|---|
| `onlineId` | `1` | `:getOnlineID()` return. Unique per player in MP. |
| `playerNum` | `0` | `:getPlayerNum()` return (split-screen). |
| `square` | nil | Current IsoGridSquare (the player's position). |
| `instantActions` | `false` | `:isTimedActionInstant()` return. `true` = debug/admin mode with 0-duration actions. |
| `fullName` | `"Test Player"` | `:getFullName()` return. |
| `traits` | `{}` | Map of trait name → bool. `{ ["Organized"] = true }` makes `hasTrait("Organized")` return true. |

### Methods

Identity: `getOnlineID`, `getPlayerNum`, `getCurrentSquare`, `getSquare`, `setCurrentSquare`, `getX`, `getY`, `getZ`, `getInventory`, `setInventory`, `getFullName`.

Hand slots: `getPrimaryHandItem`, `getSecondaryHandItem`, `setPrimaryHandItem`, `setSecondaryHandItem`, `isEquipped`, `removeFromHands`, `removeAttachedItem`, `removeWornItem`.

State: `hasTrait`, `getVehicle`, `isSeatedInVehicle`, `isFarming`, `setIsFarming`, `isAsleep`, `shouldBeTurning`, `isTimedActionInstant`, `isImpactFromBehind`, `getBodyDamage` (stub), `setMetabolicTarget`.

### Auto-wired inventory

`Fixtures.player()` automatically creates a main inventory container parented to the player. `player:getInventory()` returns it.

### Counters on `_private`

| Counter | Bumped by | Catches |
|---|---|---|
| `setPrimaryCount` | `:setPrimaryHandItem(item)` | **Equip fired twice.** If your pickup flow sets primary on both client and server (without `isClient` gating), count hits 2+. |
| `setSecondaryCount` | `:setSecondaryHandItem(item)` | **Two-handed cart double-equip.** |
| `removeFromHandsCount` | `:removeFromHands(item)` | **Unequip fired twice.** |
| `removeAttachedItemCount` | `:removeAttachedItem(item)` | **Worn-item unequip storm.** |

### Regression pattern

```lua
tests["pickup_sets_primary_hand_exactly_once"] = function()
    local p = F.player()
    YourMod.pickupCart(p, cartWorldItem)
    return Assert.equal(p._private.setPrimaryCount, 1,
        "primary hand set once — catches client+server dual-dispatch")
end
```

---

## `Fixtures.weapon(opts) / Fixtures.firearm(opts) → HandWeapon`

Full `HandWeapon` surface with 60+ getters/setters and sharpness math verified against decompiled `HandWeapon.java`. Documented extensively in the top of `Fixtures.lua`. Key options: `isRanged`, `maxDamage`, `minDamage`, `conditionMax`, `clipSize`, `maxAmmo`, `magazineType`, `containsClip`, `sharpness`, `hasSharpness`.

Closure-based private state: writes like `weapon._maxDamage = x` are silently discarded, matching real PZ's Java-object behavior. Tests that rely on direct field writes fail offline exactly the way they'd fail in-game.

```lua
local w = F.weapon({ maxDamage = 2.0, hasSharpness = true, sharpness = 0.5 })
w:getMaxDamage()  -- 1.25 (minDmg + (maxDmg - minDmg) * ((0.5 + 1) / 2))
```

See `Fixtures.lua` lines 28-120 for full option list.

---

## `Fixtures.zombie(opts) → IsoZombie`

Full `IsoZombie` surface verified against `IsoZombie.java` / `IsoGameCharacter.java` / `IsoMovingObject.java`. Method signatures match real PZ.

```lua
local z = F.zombie({ health = 2.5, crawling = false, onFire = false })
z:getHealth()           -- 2.5
z:setStaggerBack(true)
z:isStaggerBack()       -- true
z:SetOnFire()           -- capital S, matches IsoGameCharacter.java
z:isOnFire()            -- true
```

See `Fixtures.lua` lines 140-200 for full option list.

---

## `Fixtures.networkSpy() → NetworkSpy`

Patches global network functions to record every call. Essential for assertions like "my transfer produces exactly one send-add and one send-remove."

```lua
local spy = F.networkSpy()
spy:install()

YourMod.transferItemBetweenContainers(...)

spy:count("sendAddItemToContainer")        -- 1 (hopefully)
spy:count("sendRemoveItemFromContainer")   -- 1
spy:callsFor("sendAddItemToContainer")     -- [{ <args> }, ...]
spy:total()                                -- sum across all kinds

spy:uninstall()   -- restore originals
```

### Patched functions

All of these, captured by name:

- `sendClientCommand(player, module, command, args)`
- `sendServerCommand(module, command, args)` / `sendServerCommand(player, module, command, args)` (both 3-arg and 4-arg forms)
- `sendAddItemToContainer(container, item)`
- `sendRemoveItemFromContainer(container, item)`
- `syncItemModData(player, item)`
- `syncHandWeaponFields(player, item)`
- `syncItemFields(player, item)`
- `transmitPlayerModData(player)`

### Regression pattern

```lua
-- v2.1.4 MP transfer: proved that moving an item to a cart produces exactly
-- one AddItem packet (no double-broadcast).
tests["inventory_to_cart_produces_one_add_packet"] = function()
    local w = F.world()   -- auto-installs networkSpy
    YourMod.transferToCart(item, playerInv, cartInner)
    local count = w.network:count("sendAddItemToContainer")
    w:teardown()
    return Assert.equal(count, 1, "one add packet per transfer")
end
```

`Fixtures.world()` auto-installs the spy. Call `.install()` manually only if you need one without a full world fixture.

---

## `Fixtures.eventSpy() → EventSpy`

Patches global `triggerEvent` and `LuaEventManager.triggerEvent`. Records event name + args per call.

```lua
local spy = F.eventSpy()
spy:install()

YourMod.doSomething()

spy:count("OnClothingUpdated")     -- how many times fired
spy:count("OnContainerUpdate")

spy:uninstall()
```

### Regression pattern — dispatch storm

Spongie's Character Customisation freeze (VPS v1.9.0) was caused by our mod dispatching `OnServerCommand` twice per cycle. Spongie's guard was tuned for one-per-cycle. Would have caught it instantly:

```lua
tests["sp_command_shim_dispatches_OnServerCommand_at_most_once_per_cycle"] = function()
    local w = F.world()
    YourMod.fireOneCommand()
    local count = w.events:count("OnServerCommand")
    w:teardown()
    return Assert.lessEq(count, 1, "never dispatches OnServerCommand more than once per cycle")
end
```

---

## `Fixtures.world(opts) → World`

Top-level fixture. Ties everything together:

- Auto-installs `getCell()`, `getWorld()`, `getGameTime()`, `getTimestampMs()` globals
- Auto-installs `networkSpy` and `eventSpy`
- Provides a square registry for `getCell():getGridSquare(x, y, z)` to resolve against
- `:teardown()` cleanly restores globals and uninstalls spies

```lua
local w = F.world()          -- installs everything

local sq = w:square(10, 10, 0)      -- registers square at (10, 10, 0)
local p  = w:player({ square = sq }) -- creates player + inventory, positioned on sq

YourMod.doStuff(p)

w.network:count("sendAddItemToContainer")  -- assertion
w.events:count("OnEquipPrimary")

w:teardown()                 -- MUST call in all paths (use a helper for guard)
```

### Options

| Key | Default | Purpose |
|---|---|---|
| `install` | `true` | Auto-install globals on construction. Pass `false` to defer, then call `w:install()` later. |

### API

| Method | Purpose |
|---|---|
| `:square(x, y, z)` | Get (or create) the fixture square at those coords. Same instance across calls. |
| `:player(popts)` | Create a player mock. Appends to `_players`. Accepts all `Fixtures.player` opts. |
| `:install()` | Install globals + spies. Called by constructor unless `{install = false}`. |
| `:teardown()` | Restore all patched globals, uninstall spies. **Required in every test that constructs a world.** |

### Pattern: auto-teardown with pcall

```lua
local function withWorld(fn)
    local w = F.world()
    local ok, err = pcall(fn, w)
    w:teardown()
    if not ok then error(err) end
end

tests["my_test"] = function()
    return withWorld(function(w)
        -- ...
    end)
end
```

---

## `Fixtures.withSandbox(namespace, overrides, fn)`

Scoped `SandboxVars.X` override. Perfect for testing capacity multipliers, feature flags, difficulty settings without polluting other tests.

```lua
F.withSandbox("YourMod", { CapacityMultiplier = 200 }, function()
    local cap = YourMod.getEffectiveCapacity(cart)
    Assert.equal(cap, cartBaseCapacity * 2, "200% multiplier applied")
end)
-- SandboxVars.YourMod.CapacityMultiplier restored to its prior value here
```

### Correct restoration semantics

- Keys that were set before `withSandbox` → restored to their original value
- Keys that didn't exist before `withSandbox` → deleted on exit (set to nil)

No pollution between tests regardless of mock state at entry.

### Regression pattern

```lua
-- Lock "sandbox change takes effect immediately, no caching"
tests["sandbox_change_recomputes_capacity_on_next_read"] = function()
    local cart = makeCart()
    local cap1, cap2
    F.withSandbox("YourMod", { CapacityMultiplier = 100 }, function()
        cap1 = YourMod.computeCapacity(cart)
    end)
    F.withSandbox("YourMod", { CapacityMultiplier = 200 }, function()
        cap2 = YourMod.computeCapacity(cart)
    end)
    return Assert.equal(cap2, cap1 * 2, "multiplier picked up live on second read")
end
```

---

## Extending fixtures

Need a fixture for a PZ class we don't cover yet? Add it to `PZTestKit.Fixtures` in your test file's setup or via a preload module. Keep the pattern:

1. Mirror every public method the real Java class exposes
2. Bump a counter on every mutating call
3. Expose counters on `_private`
4. Cross-reference the decompiled file/line in a comment

Once stable, consider contributing back to pz-test-kit — shared fixtures save every mod author writing the same stand-ins.

Example mock for a PZ class we don't cover (decompile the Java first to know the method names):

```lua
function F.deadBody(opts)
    opts = opts or {}
    local priv = {
        checkClothingCount = 0,
        -- ...
    }
    local b = { _type = "IsoDeadBody" }
    b.checkClothing = function(self, item)
        priv.checkClothingCount = priv.checkClothingCount + 1
        -- ...
    end
    b._private = priv
    return b
end
```

Assertion:

```lua
Assert.equal(body._private.checkClothingCount, 1, "checkClothing fired once per container op")
```

---

## Appendix — counter cheat sheet

If you're deciding which counters to assert on for your mod, here's a mapping of common PZ operations to the counter that catches a regression:

| Bug class | Counter to assert on | Expected value |
|---|---|---|
| World item duplicates on drop | `worldItem._private.transmitCompleteCount` | 1 per drop |
| World item duplicates on drop (2nd vector) | `square._private.addWorldInvCalls[i].argCount` | 5 (not 4) |
| Container add fires twice per logical move | `container._private.drawDirtyCount` | 1 per move |
| Pickup clears world state fully | `worldItem._private.setSquareNilCount` | 1 per pickup |
| Equip fires on both client + server | `player._private.setPrimaryCount` | 1 per equip |
| sendAddItemToContainer broadcast storm | `networkSpy:count("sendAddItemToContainer")` | 1 per move |
| OnClothingUpdated dispatch storm | `eventSpy:count("OnClothingUpdated")` | ≤ 1 per cycle |
| Item-ID collision on cart pickup | `container._private.itemsList` after add | size increments by exactly 1 |

When in doubt: **expected = 1 per logical operation.** If the assertion fires 2 or more, there's a dupe vector somewhere in the flow.
