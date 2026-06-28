# Test Kit Certification

A green suite proves the mod matches the **mocks** — not that the mocks match the
**game**. The kit mirrors a lot of vanilla and leans on internal knowledge of PZ's
API (crafting logic, recipe schema, context-menu internals, timed actions). If PZ
changes those underneath us, the suite stays green while the mod breaks in-game.

Certification records the PZ build the suite + mocks were last validated against, so
we know when the game has moved and a re-validation is due.

## Stability model

- **Within Build 42 the vanilla API is locked.** Minor `42.x` patches almost never
  touch the crafting / inventory / timed-action internals we mirror. A Steam buildid
  change is worth a quick `./certify.sh` re-run, not a re-audit.
- **Build 43 is the divergence line.** A major version bump is where method
  signatures, the recipe/output-mapper schema, and menu internals can change
  wholesale. Treat a B43 install as a **full re-validation**: re-derive every mocked
  API against the decompiled B43 tree before trusting a green suite again.

So certify.sh distinguishes three cases: same build (✓), a `42.x` patch (re-run to
re-stamp), and a major-line jump to B43 (🛑 stop and re-validate).

## Current certification

| Mod | Scope | Coverage | Tests | PZ build line | PZ version | Steam buildid | Date |
|-----|-------|----------|-------|---------------|------------|---------------|------|
| Sauce's Short Order | `palette` | 79% | 426 | Build 42 | 42.x (confirm in-game) | `23504596` | 2026-06-28 |

> **PZ version**: the exact `42.x.y` isn't readable from disk — read it from the
> game's main menu and record it here. The **Steam buildid** is the authoritative
> auto-detected fingerprint; certify.sh compares against it.

## Coverage floor

- **Providers** (the enumerate/declare sources — craft, build, place, lookup,
  medical, vehicle, …): target **≥ 80%**. These carry branchy logic where a
  definition-order/nil bug ships silently (see the `unpackCommands` regression).
- **Engines** (action, resolve, groups, filter, families, score): target **≥ 90%**.
- **UI / lifecycle** (`pal_ui`, `pal_main`): best-effort — render + event paths are
  hard to drive headlessly; don't block a release on them.

A brand-new function sitting at **0%** is un-shippable: nothing has run it, so it can
hide exactly the class of load-time/typo/nil bug the harness exists to catch.

## How to (re-)certify

From `pz-test-kit/`:

```bash
./certify.sh            # runs the suite + coverage, compares the live build
```

It prints PASS/FAIL, the coverage TOTAL, and the build comparison. When the suite is
green against a NEW build, update the table above (coverage %, test count, buildid,
version, date) and commit — that's the new certification of record.
