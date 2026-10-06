# SousVide MP: two burners and the Pass

Status: **phase 1 built; phase 2 core built** (2026-10-05). Decisions: separate JVMs per side;
first proving ground SaucedCarts.

## Why separate JVMs

Every MP bug in this portfolio comes from **two copies of the same thing
disagreeing**:

- a SaucedCarts item in the cart on the server and still in the bag on the
  client (dupes);
- a VorpallySauced tape whose media index was wiped on deserialization (blank
  tapes);
- `complete()` never running on an MP client;
- anti-cheat kicking a client for an item delete only an admin may send.

`DualVMSim` (one JVM, many Kahlua envs) shares Java objects and the
`GameServer.server` flag between sides, so there is only ever one copy and
this class of bug cannot show. SousVide MP runs **one JVM per side**. Each side
holds its own copy of every item, and anything that crosses the wire crosses
as real bytes.

## Topology

```
  client SousVide (c1)  ──┐                    ┌── client SousVide (c2)
  GameClient.client=true  │   the Pass         │   GameClient.client=true
                          ├── (dashboard) ─────┤
                          │   ordered, logged, │
                          │   fault-injectable │
                     server SousVide
                     GameServer.server=true
```

One MP session per mod: `<mod>@server`, `<mod>@c1`, `<mod>@c2`. These are
ordinary SousVide bridges booted with a role. The dashboard routes between
them; nothing talks directly.

## Roles: boot like the game

| | server | client |
|---|---|---|
| Java flags | `GameServer.server = true` for the life of the VM | `GameClient.client = true` |
| Lua `isServer/isClient/isMultiplayer` | true / false / true | false / true / true |
| Lua folders run (LuaManager / GameServer.java:1472-1474) | `shared`, `server` (`client` checksummed only) | `shared`, `client`, then `server` at game load (GameLoadingState.java:149) |
| Start events | `OnServerStarted` (no `OnGameStart` on a dedi) | `OnGameBoot`, `OnGameStart` |
| Player(s) | one IsoPlayer per connected client (onlineID, username) | its own local player, same onlineID and username |

Today's single-role bridge loads only the modules a mod's preload and
requires reach. Role VMs load **every file the game would run**, in the
game's order.

## The Pass (the network)

Each VM intercepts the Lua globals the game routes to the network, at the
global layer. They become **packets**: queued, serialized with the engine's
own code, logged and delivered by the dashboard.

| Packet | Sender global(s) | Bytes | Applied on the receiver |
|---|---|---|---|
| client command | `sendClientCommand` | `TableNetworkUtils` | `OnClientCommand(module, cmd, player, args)` with the server-side player |
| server command | `sendServerCommand` (3-arg broadcast, 4-arg targeted) | `TableNetworkUtils` | `OnServerCommand(module, cmd, args)` |
| item add | `sendAddItemToContainer`, `sendItemsInContainer` | `InventoryItem` save | load into the same container (by owner + container type), same ID |
| item remove | `sendRemoveItemFromContainer` | id | remove by ID |
| item replace | `sendReplaceItemInContainer` | ids + item bytes | swap |
| item state | `syncItemFields`, `syncItemModData` | fields / `TableNetworkUtils` | apply to the item with that ID |
| world item | `transmitCompleteItemToClients`, `transmitRemoveItemFromSquare` | object bytes | add / remove on the square |
| equip | `sendEquip` | ids | set hands |
| global ModData | `ModData.transmit` | `TableNetworkUtils` | `OnReceiveGlobalModData` |
| player stats | `syncPlayerStats(player, mask)` (server only); `mpPlayerTick` every 1 s: the full `PlayerStats` push | `Stats.save` + `BodyDamage.saveMainFields` (all) or the masked values | `Stats.load` / set on the client's player |
| player health | `mpPlayerTick` every 0.5 s (`PlayerHealthPacket`) | every body part's health | `SetHealth` per part |
| player body | `mpPlayerTick` every 2 s (`PlayerDamagePacket`) | `BodyDamage.save` | `BodyDamage.load` |
| body part | `syncBodyPart(part, fields)` (server only) | the fields its mask names (`BD_Health` = 1, `BD_stiffness` = 2^40) | those fields on that part |
| traits | `sendSyncPlayerFields(player, 2)` (server only, `PF_Traits`) | `CharacterTraits.write` | `CharacterTraits.read` |
| client stat | `sendPlayerStat(player, stat)` (client) | stat | **refused**: `SyncPlayerStatsPacket` needs `CanModifyBodyStats` |

**The player's state is the server's** (`workbench/83_mp_player.lua`,
2026-10-06). `mpPlayerTick{seconds}` on the server sends what
`NetworkPlayerManager.update` sends in that time (health 0.5 s, stats 1 s,
body 2 s), so a client's write to its own stats, wounds or strain is erased
the way it is in game. Use it whenever a question is "does this player-state
change survive in MP".

Delivery is explicit: `pump` delivers everything queued, or one packet at a
time. **Fault injection** works per packet: hold, drop, duplicate, reorder.
Races and double-sends are where dupes come from, so the Pass must be able to
make them on purpose.

Each packet in the log shows sender, receiver, type, size, decoded payload,
and the step that caused it.

## The auditor

After every step and every delivered packet:

- **Census:** every item ID in every container on every side. Flagged:
  - the same ID in two places on one side (a **dupe**);
  - an ID on a client that the server doesn't have, or the reverse (**orphan**);
  - a client copy that differs from the server's in type, condition,
    ModData hash or media index (**divergence**).
- **Anti-cheat:** client-sent packets a real 42.20 server rejects, such as an
  item delete without `Capability.EditItem`, are flagged "a real server kicks
  this client".
- **Mod invariants:** an `mpChecks` addon kind, next to `boardActions` and
  `worldVerbs`. A mod declares what must hold across sides. For example:
  - SaucedCarts: "a cart's contents match on every side";
  - VorpallySauced: "the weapon's VPS data matches between the server and the
    owning client".

  The bench stays generic, and each mod states its own invariants.

## Scenarios

A scenario is a board with lanes (server, c1, c2). Each step runs on one side,
the Pass sits between the lanes, and expectations can be auditor clean,
invariant holds, or a packet was sent. Scenarios save like blueprints and run
as tests through the dashboard. Each also exports as a `pz-shell` probe
sequence for the docker dedi, which covers the netcode we only model.

## Phase 1 as built

- `pztest --bridge --engine --role server|client [--client-index N]`
  (KahluaTestRunner.bridgeMode). The server side holds `GameServer.server`
  (EngineBridge.setRole).
- `dashboard/mp.js` is the Pass: sessions, the queue, the log, and
  hold / deliver n / drop / duplicate. HTTP is `/api/mp/<mod>/...`. MCP tools:
  `mp_start`, `mp_eval`, `mp_call`, `mp_pump`, `mp_pass`, `mp_status`.
  The Workbench has a 🍳 mp panel.
- `workbench/80_mp.lua` boots a side:
  1. players: one per client on the server, `cook1..N`;
  2. network globals become packets, and `getPlayer()` is nil on the server;
  3. vanilla classes the mod names load first (index built by `mp.js`,
     parents ahead), with `require` falling back to vanilla files;
  4. every mod file that side runs, in folder order;
  5. start events.

  `mpDeliver` decodes the real wire bytes and fires
  OnClientCommand/OnServerCommand. `PZEngine.wireEncode/wireDecode`
  carry payloads between processes.
- Proof: SaucedCarts `requestAnimationSync` from c1 and c2. The server receives
  each with the right player and answers `fullAnimationSync` to that client
  only. Held + duplicated delivery makes the server answer twice.

Findings:
- **The single-VM bench is client-shaped**, not SP (`isClient()` true,
  `isServer()` false). Modules gated `if isClient() then return end` never ran
  there.
- **Kahlua cannot pass a Lua number to a `short`/`byte`/`long` parameter.**
  `IsoPlayer.setOnlineID(short)` needs `PZEngine.invokeTyped`.
- **Open:** a client side's vanilla UI tree (`ISUIElement` → `ISPanel` →
  `ISContextMenu`, `ISTimedActionQueue`) does not load headless yet; it needs
  uiview's UIMock layer. In SaucedCarts this shows as AttachmentTweaker (derive
  of nil), CorpseStorage `reconcileCartsInRange`, and `createPlayerData` at
  OnCreatePlayer. Phase 2 needs it, because transfers go through timed actions
  and the inventory UI.

## Phase 2 as built (core)

- **Client UI layer:** a client side boots uiview's UIMock (clean-room
  ISUIElement, ISPanel, ISBaseObject...) before vanilla, and skips the vanilla
  files defining those classes (by class and by `require` name). All 72
  SaucedCarts client files load (AttachmentTweaker included).
  `ISTimedActionQueue` loads now that the AI states it indexes at file load
  are exposed (ClimbThroughWindowState and six more).
- **Items cross the wire** (`workbench/81_mp_items.lua`):
  - `sendAddItemToContainer` / `sendAddItemsToContainer` /
    `sendItemsInContainer` (server only), `sendRemoveItemFromContainer` (both
    sides), `sendReplaceItemInContainer`, `syncItemFields`, `syncItemModData`.
  - Item bytes are the real packet's (`CompressIdenticalItems`, via
    `PZEngine.itemsEncode/itemsDecode`), and IDs survive.
  - Applied with the real handlers' logic: an add of an ID the container
    already holds is refused ("Error: Dupe item ID"); a client remove uses
    `removeItemWithID`, a server remove uses `Remove`, else "already removed".
  - Containers are addressed by player inventory, or by the item holding them
    (bag, held cart) by ID.
- **The auditor** (`mp.js`): after every step and every delivery,
  `mpCensus` on every side, and every item ID compared. It reports
  dupe / ghost / missing / diverged (location, type, condition, uses,
  ModData).
- `WB.prepareTimed` (the Java action stand-in) for running one side's half of
  an action, and `getServerOptions` on role VMs.
- **Proof** (SaucedCarts, 1 client):
  1. The server gives a cart and 3 apples: clean.
  2. cook1 moves an apple in through the real `ISCartTransferAction`
     (isValid/start/perform). That sends `cartTransfer`; the server sends
     remove + add + `ui/DirtyUI`; clean.
  3. Dropping the server's remove in flight is caught: DUPE on c1 (cart + main
     inventory) and DIVERGED vs the server.
  4. A duplicated `cartTransfer` is a no-op the second time (SaucedCarts'
     "already in destination" guard): clean.

Findings:
- **Engine: every loaded item gets `ModData.customName`.**
  `InventoryItem.load` calls `setCustomName(flag)` unconditionally
  (`InventoryItem.java:2070`), and the setter writes the key whatever the
  flag (`:3528-3531`). A received copy has it; a fresh server copy doesn't, so
  `hasModData()` disagrees between sides for every new item. The auditor
  reports it as an engine note, not a finding.
- **SaucedCarts: a client ghost is never healed.** When the server's remove
  is lost, the client keeps the item in its inventory as well as the cart.
  Retrying the move hits the "already in destination" guard, which correctly
  does nothing server-side but sends nothing back, so the client stays wrong
  until it reconnects. Healing option: on "already in destination", send the
  client a remove for the stale source.

**Client UI, finished.** Both sides now boot with **zero** vanilla, mod or
start-event failures (SaucedCarts: server 36 files, client 72, about 1.5 s
each). What it took:
- **`require` returns the file's value**, as the game's does (`SandboxVars =
  require "Sandbox/Apocalypse"`).
- **Folder-scoped loading.** While a `shared/` vanilla file runs, its
  requires and class reads see only `shared/`, the game's shared pass
  (`LuaManager.paths` grows per `LoadDirBase`). That ended the
  ISInventoryPane → corpseStorageCheck → ISVehicleMenu cycle faithfully.
- **Lazy class loading.** A global read of a not-yet-loaded vanilla class
  loads its file (class → file index from `mp.js`); "every vanilla file has
  run" done on demand. A missed `require` warns and returns nil, as in game.
- Role-VM stand-ins:
  - the real cell behind `getCell()`;
  - `getCore():isDedicated()`;
  - `LuaEventManager.AddEvent`;
  - `Hook`'s eight tables;
  - `getPlayerScreen*`;
  - `getSandboxOptions():initSandboxVars()`, which merges mod sandbox
    defaults back.
- Exposed: `org.joml.Vector2f/Vector3f`.

The four remaining require misses are faithful. Two are client files that
shared files require during the shared pass. Two are for a file that does
not exist in the install (`ISUI/InventoryWindow/ISLootWindowControlHandler`).

**`full` boot mode (opt-in, `mp_start {full: true}`)** runs every vanilla file
of a side in game order (~1,400 for a client, ~5 s). It currently surfaces
about 250 vanilla failures from Java the bench does not expose yet
(TraitFactory, ProfessionFactory, SurvivorFactory pools, Fitness, Foraging,
keybindings...). That's the fidelity frontier, worked through as needed.

**World containers** (`workbench/82_mp_world.lua`):
- `mpWorld` loads the same real map box on every side and watches it;
  `mpPlace` moves a player on its client and on the server.
- World changes are Java METHODS, so they're hooked where mods hook Java,
  `__classmetatables` (Lua→Java calls):
  - `obj:transmitCompleteItemToClients()` and `sq:AddWorldInventoryItem`
    (the 4-arg form transmits inside Java, so it's wrapped) become
    `worldAdd`. That's the object's own `writeToRemoteBuffer` bytes; the
    receiver does `createFromBuffer` + `loadFromRemoteBuffer` (placed at the
    sent index) + `addToWorld`, and `OnContainerUpdate`/`OnObjectAdded` fire.
  - `sq:transmitRemoveItemFromSquare(obj)` becomes `worldRemove`, BY OBJECT
    INDEX as the real packet. The server also removes its own copy; a client
    only removes locally (IsoGridSquare.java:5995-5999).
- Item packets address world containers as a ground item (by ID, on its
  square) or an object (index + container index). They go to every client.
- The census walks watched squares (ground items, their containers, object
  containers), and the auditor compares the world between sides.
- **Proof:**
  1. The server drops a ground cart (`AddWorldInventoryItem`): 192 B
     `worldAdd`; the client places it at the same index; clean.
  2. cook1 moves an apple into the GROUND cart via the real action: the
     server finds it with SaucedCarts' radius sweep around cook1's
     server-side position, then sends a remove (inventory) and an add
     (ground-item container); clean.
- **Finding: index-based world removal.** Dropping one `worldAdd` (apple X)
  shifts the client's object list. The server's later removal of X (index 2)
  removes the client's ORANGE at index 2 instead. The orange is still on the
  server and gone on the client (auditor: MISSING). This is vanilla
  RemoveItemFromSquarePacket behaviour: any lost world add makes later
  removals on that square hit the wrong object for that client.

Still to do in phase 2: `mpChecks` (mod-declared invariants). Corpses and
vehicle containers are addressable as world objects; their own packets are
untested.


## MP checks: proofs that run again (2026-10-06)

`mp-check.mjs` turns MP proofs into repeatable checks. A mod keeps scenario
modules (VorpallySauced: `mpchecks/*.mjs`); each step runs Lua on one side and
must return a string matching its `expect`; `save` captures a value (an item
ID) for later steps as `{{key}}`. The runner starts a fresh session, runs the
steps, always stops the session, and exits non-zero on any failure. It
**refuses** to run while a session for that mod is already up, so it never
disturbs one somebody is working in.

    node ../pz-test-kit/mp-check.mjs mpchecks/genome_life.mjs

Engine events raised from Java (OnCharacterDeath, OnZombieDead...) reach mod
Lua on an MP side only through `PZEngine.forwardEvent`, as the Arena forwards
its combat events. And each side now starts the entity system at boot
(`80_mp.lua`): without it `setPrimaryHandItem` silently did nothing, so a held
weapon was never held on any MP side.

## Phases

1. **Two burners.** Role boot (flags, game-faithful loading, start events),
   player identity, client and server commands across the Pass with real
   `TableNetworkUtils` bytes, the packet log, and MCP `mp_*` tools.
   Proof: a SaucedCarts command round trip with the server player attributed.
2. **Items cross.** Item replication (give, add, remove, replace, sync
   fields and ModData, world items) and the census auditor. Proof: a
   SaucedCarts transfer into a cart, with the cart-contents invariant holding,
   then a planted dupe caught.
3. **Actions split, anti-cheat.** NetTimedAction semantics: `perform` on the
   client, `serverStart`/`complete` on the server. Plus capability flags.
   Proof: VorpallySauced's perform/complete split, and the 42.20
   SyncItemDelete kick.
4. **Fault injection and scenarios as tests.** Hold, drop, duplicate and
   reorder; lane boards; saved scenarios in the suite.
5. **Dedi handoff.** Scenario → pz-shell probe export.

## Out of scope (on purpose)

PZ's real netcode (UdpConnection, packet classes, prediction, physics sync)
is not emulated. The Pass models the Lua-visible sync surface the mods
actually use. Anything below it is confirmed on the docker dedi.
