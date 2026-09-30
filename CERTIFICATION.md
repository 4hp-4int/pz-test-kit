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
| Sauce's Short Order | `palette` | 84% | 723 | Build 42 | 42.20 stable (`GameVersion(42, 20)` in decompiled Core.java) | `24449119` | 2026-08-04 |

> **DRIFT, 2026-09-30 — not re-stamped on purpose.** The install is now **42.21
> stable, buildid `25485521`** (`GameVersion(42, 21, "")`, `Core.java:160`). The
> toolchain was refreshed for it (fresh decompile, regenerated indexes,
> `kahlua-runtime.jar` rebuilt from the 42.21 jar) and the engine-mode stub breaks
> that patch caused are fixed — see `shared/pz-patch-log.md`. Certification stays
> at `24449119` because **the palette suite is not green**: 587/601 + 1 error,
> every failure in `test_palette_farming`. Those failures are NOT from 42.21 —
> they reproduce identically against the pre-refresh runtime jar — they are drift
> from the late-August uiview rework (real font metrics, real texture sizes) and
> the move of the order box's tests back into `sauce-shortorder`. Re-baseline that
> suite, then re-stamp. `RealRecipes.lua` was regenerated for this build and came
> out byte-identical (623 recipes), so the corpus fixture needs no change.

The palette suite includes a **real-corpus sweep** (`test_palette_recipe_corpus`): our
resolver is run over the actual 623 B42 craftRecipes, parsed from the game scripts by
`tools/parse_recipes.py` into `uiview/.../RealRecipes.lua`. That fixture is part of the
certification — **regenerate it whenever the buildid changes** so the sweep reflects the
installed game:

```bash
python tools/parse_recipes.py > uiview/media/lua/client/UIView/RealRecipes.lua
```

> **PZ version**: the **Steam buildid** is the authoritative auto-detected
> fingerprint; certify.sh compares against it. The `42.x.y` is readable from disk
> without launching the game, two ways:
>
> ```bash
> # major.minor, straight out of the jar's bytecode (what the stub bake uses)
> javap -p -c -cp "$PZ/projectzomboid.jar" zombie.core.Core \
>   | grep -B4 'Field gameVersion:'
>
> # full major.minor.patch + git revision, if the game has been run since the patch
> grep -m1 '^version=' ~/Zomboid/console.txt      # e.g. version=42.21.0 4a0e9546ec
> ```

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
