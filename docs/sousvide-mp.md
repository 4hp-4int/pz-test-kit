# SousVide MP: two burners and the Pass

Status: design (2026-10-05). Decisions: separate JVMs per side; first proving
ground SaucedCarts.

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
