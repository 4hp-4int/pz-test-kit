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
| Sauce's Short Order | `palette` | 85% | 601 | Build 42 | 42.21 stable (`GameVersion(42, 21, "")` at Core.java:160) | `25485521` | 2026-09-30 |

> **Test count went 723 → 601 without losing coverage.** The order box's unit
> tests moved out of `uiview/tests/` and into `sauce-shortorder` (kit commit
> `3304675`); what stayed in the kit is the genuinely cross-mod set (render
> snapshots, palette×SIR lens, accent coherence, pack manifest). 601 is the
> `sauce-shortorder` suite alone, which is what this scope now certifies —
> coverage rose 84% → 85% over it.
>
> Certified against the 42.21 refresh: fresh decompile, regenerated
> `pz-dev-tools` indexes, `kahlua-runtime.jar` rebuilt from the 42.21 jar, and the
> two engine-mode stub breaks that patch caused fixed — see
> `shared/pz-patch-log.md`. `RealRecipes.lua` was regenerated for this build and
> came out **byte-identical** (623 recipes), so the corpus fixture is unchanged
> 42.20 → 42.21.
>
> Known-red elsewhere, NOT blocking this scope and NOT caused by 42.21: 5 SIR
> render tests in `uiview` and 1 in `PZ-TooltipLib`. Both look like real product
> bugs that the late-August switch to real font metrics and real texture sizes
> exposed — bottom-anchored SIR icon badges falling outside the row stencil, and a
> TooltipLib gauge band computing narrower than the `bw > 8` threshold
> SauceTooltips draws gauges behind. Tracked in the patch log; the tests are
> correctly failing and should stay that way until the geometry is fixed.

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
