# pz-shell — live Lua REPL for dedi servers

**Dev-only.** Arbitrary code execution against a running PZ Build 42 dedicated server. Ships offline-test parity for the "is this function returning what I think it's returning *right now*?" question without a server restart.

## What it does

Seven things that collapse the dedi debug loop:

1. **`eval`** — execute arbitrary Lua in the server's live VM; return value + `print()` output come back on stdout.
2. **`reload <Module>`** — re-execute a module's top-level code without restarting. Works because PZ's `require()` has no cache (see caveats).
3. **`tail [regex]`** — follow the dedi's debug log filtered by a regex. Strips the 95% of the log you don't care about.
4. **`tail-mod <ModName>` + `PZShell.tap(modName)`** — per-mod structured log file. Any mod that calls `PZShell.tap("Foo")` gets a logger writing to `Zomboid/Lua/pz-shell/stream/Foo.log`. `tail-mod` streams just that one file. Clean per-mod streams with no regex dance.
5. **`profile`** — install call-counting wrappers on `sendServerCommand`, `sendClientCommand`, `syncItemModData`, `syncHandWeaponFields`, `syncItemFields`. Snapshot totals + per-(module, command) histogram. Catches over-sync, sync-storms, runaway command loops.
6. **`snapshot save/restore/list/show/delete`** — dump server state (or any eval'd expression) to a Lua source file, round-trippable via `loadstring`. Default capture: VPS runtime accumulators, sandbox, connected-player weapon ModData. Supports `--expr '<lua>'` or `-f <path>` for arbitrary captures.
7. **`puppet <action> [--as <user>] [args]`** — script server-side player actions: `equip`, `unequip`, `inventory`, `drop`, `reload`, `damage`, `credit-kills`, `whoami`. Operates on first connected player by default; `--as <username>` targets a specific one. `credit-kills N` is the fastest way to exercise VPS affix/trait thresholds.

`eval` and `reload` sit on a file-queue protocol between the host CLI (`./pz-shell`) and a tiny server mod (`./mod/`): the mod polls `Zomboid/Lua/pz-shell/queue.lua`, runs whatever lands there through `loadstring()+pcall()`, writes the result to `Zomboid/Lua/pz-shell/result.lua`. `tail` bypasses that — it just `docker exec`s a `tail -F | grep` pipe against the debug log file.

## Install

```bash
# 1. Deploy the server mod into your Zomboid/mods/ (same dir pz-dedicated-docker bind-mounts)
cd pz-test-kit/shell
./deploy.sh                          # uses $USERPROFILE/Zomboid/mods
# or
./deploy.sh /custom/Zomboid/mods

# 2. Add PZShell to your servertest.ini Mods= list and restart the dedi
docker compose --env-file .env --project-directory /path/to/tools/pz-dedicated-docker \
    restart pzserver

# 3. Arm the gate (creates Zomboid/Lua/pz-shell/enabled inside the container)
./pz-shell enable

# 4. Probe
./pz-shell eval 'return 1+1'
# => 2
```

## Usage

```bash
# One-liners
./pz-shell eval 'return getNumActivePlayers()'
./pz-shell eval 'return getPlayer():getUsername()'

# Multi-line via stdin
./pz-shell eval - <<'EOF'
local w = getPlayer():getPrimaryHandItem()
if not w then return "no weapon" end
return w:getMaxAmmo() .. "/" .. w:getClipSize()
EOF

# From a file
./pz-shell eval -f ./probe.lua

# Hot-reload a module (iterate on pure logic without a server restart)
./pz-shell reload VorpallySauced/StatModifiers/Reapply

# Follow the dedi debug log, filtered
./pz-shell tail                       # everything (noisy)
./pz-shell tail VorpallySauced        # only VPS lines
./pz-shell tail "VorpallySauced|SaucedCarts"   # regex, multiple mods

# Profile network sync / command traffic
./pz-shell profile start              # install counting wrappers
# ... have players do things, run probes, etc. ...
./pz-shell profile snap               # totals + per-(module, command) top-N
./pz-shell profile stop               # restore originals

# Snapshot + restore server state
./pz-shell snapshot save mysession    # default VPS capture
./pz-shell snapshot save mysession --expr 'return { bonds = VorpallySauced.DiscoveryLog.getBondList() }'
./pz-shell snapshot save mysession -f ./capture.lua
./pz-shell snapshot list
./pz-shell snapshot show mysession
./pz-shell snapshot restore mysession   # puts data on _G._pzshell_snapshot_mysession
./pz-shell snapshot delete mysession

# Script server-side player actions (requires ≥1 connected player)
./pz-shell puppet whoami
./pz-shell puppet equip Base.Shotgun
./pz-shell puppet credit-kills 250           # blast through affix + trait thresholds
./pz-shell puppet inventory
./pz-shell puppet damage 5
./pz-shell puppet --as bob drop

# Per-mod log streams (mod calls PZShell.tap first)
./pz-shell tail-mod VorpallySauced           # stream one mod's log file
./pz-shell taps                              # list all mod streams

# Gate management
./pz-shell enable
./pz-shell disable
./pz-shell status
```

### Live probes + tail together

The dual-pane pattern for diagnosing a live bug: one terminal tails the log, another sends probes.

```bash
# Terminal A
./pz-shell tail VorpallySauced

# Terminal B
./pz-shell eval 'print("[VorpallySauced] equipped: " .. tostring(getPlayer():getPrimaryHandItem() and getPlayer():getPrimaryHandItem():getName() or "nothing"))'
```

## Env

| Var | Default | Meaning |
|---|---|---|
| `PZ_CONTAINER` | `pzserver` | docker container to `exec` into |
| `PZ_SHELL_TIMEOUT` | `15` | max seconds to wait for a response |

## Protocol

```
          host                                server
           │                                    │
           │ wait for queue.lua empty           │
           │──────────────────────────────────▶ │ (polling at ~4 Hz)
           │ write code to queue.lua            │
           │──────────────────────────────────▶ │ read queue, execute,
           │                                    │ write result.lua,
           │                                    │ truncate queue.lua
           │ poll result.lua until non-empty    │
           │──────────────────────────────────▶ │
           │ read result.lua, truncate          │
           │                                    │
```

Single file per direction, truncate-to-consume. No directory listing needed (PZ's Lua API doesn't expose one). Host serialises requests by waiting for queue truncation, so two concurrent invocations queue naturally.

Latency: ~100-300ms per eval (server polls at 4 Hz + docker-exec overhead). Fine for interactive use.

## Safety

The server mod **executes arbitrary Lua**. Anyone who can write to the container's `Zomboid/Lua/pz-shell/queue.lua` can run code with the server's privileges.

Defences in place:

- **Gate file.** The mod does nothing unless `Zomboid/Lua/pz-shell/enabled` exists. `pz-shell disable` removes it without restarting the server. If the mod ever ships to a production server by accident, forgetting to `touch enabled` means it's inert.
- **MP client skip.** `if isClient() then return end` at the top — MP clients don't run the poll loop.

Defences NOT in place:

- No auth on the queue file itself. Anyone with `docker exec` access to the container is already root-equivalent inside it, so this isn't new attack surface against docker setups.
- No rate limit. A spin-loop of `eval 'while true do end'` will hang the server's Lua VM.

**Don't enable this mod on a public server.** That's not a complicated rule — the `enabled` gate file is the enforcement mechanism.

## Caveats

- **Hot reload duplicates listeners.** PZ's `require()` has no cache — each call re-runs the file's top-level code (decomp: `LuaManager.require` just delegates to `RunLua`, no `package.loaded` equivalent; the `package` table doesn't even exist in PZ's Kahlua). Any module that does `Events.X.Add(handler)` in its body registers `handler` a second time on reload with the old handler still attached. Use `reload` for pure-def modules and for modules whose `Add` calls are conditional / de-duplicating. Otherwise a full restart is still correct.
- **`print()` during eval is captured.** The mod temporarily redirects `_G.print` while the snippet runs. Any other code that fires during the pcall (event handlers in the same tick) and calls `print()` will also land in your result. Annoying but rare.
- **Long evals block the server tick.** `loadstring()+pcall()` runs inline with the poll tick. A 2-second eval freezes the dedi for 2 seconds. Keep probes fast.
- **Windows paths.** The host CLI is bash-only for now. Run from Git Bash / WSL / Docker Desktop terminal. A `.ps1` twin is a nice-to-have.

## Profiling example: catching over-sync

```bash
./pz-shell profile start
# fire whatever you want to measure — PR test scenario, player equipping,
# a specific mod interaction. One or more probes + natural play.
./pz-shell profile snap
```

Example output on a synthetic 4-call workload:
```
elapsed: 4s
totals:
  sendServerCommand        4  (0.95/s)
  sendClientCommand        1  (0.24/s)
  syncItemModData          2  (0.48/s)
  syncHandWeaponFields     1  (0.24/s)
  syncItemFields           1  (0.24/s)

top commands:
     2  TestModA:ping       <-- same command twice in the window
     1  TestModA:pong
     1  TestModB:boom
     1  C>S TestModC:hello  <-- client→server tagged
```

What to look for:
- A single (module, command) pair accounting for >50% of all traffic during a short window = probable over-sync bug.
- `syncItemModData` rate >> `syncHandWeaponFields` rate = a mod updating ModData without the corresponding stat sync, or vice versa.
- Non-zero traffic with no one doing anything = a polling handler running on a tick event.

## PZShell.tap — use from your own mod

Drop this into any server-side file:

```lua
if PZShell and PZShell.tap then
    MyMod.log = PZShell.tap("MyMod")
end

-- later
MyMod.log.info("player " .. name .. " did the thing")
MyMod.log.warn("config missing, using default")
MyMod.log.error("sync failed: " .. reason)
```

Then host-side: `./pz-shell tail-mod MyMod`. Clean stream of just your mod's lines, timestamped, severity-tagged, immune to PZ's debug-log noise. If PZShell isn't loaded on the server, the `if` guard no-ops gracefully.

## Known puppet gotcha

`puppet equip <type>` sets the target's primary hand item **and** adds the item to inventory. The primary-hand assignment is server-authoritative only until the client's next tick, which overwrites it with whatever the client thinks it has equipped (nil, usually). So between separate puppet calls, the primary field on the server will flip back to nil even after a "successful" equip.

All actions that need a weapon (`credit-kills`, `damage`, `reload`, `drop`) handle this by falling back to "first weapon in inventory" if primary is nil. So scripted sequences work. If you need the character to actually be *holding* the weapon visually, the player must do the equip client-side (hotbar drag) after the give.

## Phase 2 wishlist — all shipped

- ✓ Log streaming (raw filter + per-mod streams via `PZShell.tap`)
- ✓ Profiling
- ✓ Snapshots
- ✓ Puppet (server-side; no headless-client Java project required)

Future ideas if the need arises:
- **Headless Java puppet** — a real fake client that connects via TCP/UDP and can actually equip items client-authoritatively. Big project; server-side puppet covers 90% of the use case.
- **Snapshot diff** — `pz-shell snapshot diff <a> <b>` shows what changed between two captures. Useful for "before/after affix earn" comparisons.
- **Profile replay** — record a sequence of puppet actions + snapshots as a single script, replay it against a fresh dedi for CI-style regression testing.
