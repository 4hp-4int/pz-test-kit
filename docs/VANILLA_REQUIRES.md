# Vanilla Requires

`vanilla_requires` is a config key in `pz-test.lua` that pulls real vanilla PZ Lua files from your local PZ install into the offline test environment.

If your mod intercepts, wraps, or hooks a vanilla function — `ISTransferAction:transferItem`, `ISDropWorldItemAction:complete`, `ISHandcraftAction:performRecipe`, `forceDropHeavyItems`, etc. — your tests should run against the actual vanilla code those functions live in, not a hand-written stub.

## Why

Testing against a mock you wrote has a fundamental problem: **your mock drifts from reality every time TIS patches the game.**

The vanilla v2.1.4 release of PZ Test Kit landed because SaucedCarts's offline tests were passing against a mock `ISTransferAction:transferItem` that worked by our assumptions, while the real vanilla function on B42.15 had subtly different behavior around clothing unequip + `OnClothingUpdated` dispatch. The bug only surfaced in-game when real vanilla ran. Once we switched that test to use `vanilla_requires`, the same test broke the moment we introduced a regression — because the test was now exercising the same code path the game would.

**Use `vanilla_requires` when:**

- You wrap/hook/intercept a vanilla PZ function (`ISTransferAction:transferItem`, `ISBaseTimedAction.new`, etc.)
- Your mod's correctness depends on vanilla side effects (clothing refresh, radio swaps, mannequin clothing, OnClothingUpdated events)
- You want regression signal when PZ patches touch the vanilla file you depend on

**Skip it when:**

- Your mod is self-contained and doesn't call vanilla Lua from its hot paths
- You're writing a pure-logic test (math, data shape validation, state machine transitions)

## Configure

In `pz-test.lua` at your mod root:

```lua
return {
    -- paths relative to $PZ_INSTALL/media/lua/, without the .lua extension
    vanilla_requires = {
        "shared/ISBaseObject",
        "shared/TimedActions/ISBaseTimedAction",
        "shared/TimedActions/ISTransferAction",
        "shared/TimedActions/ISDropWorldItemAction",
        "client/TimedActions/ISInventoryTransferAction",
        "client/ISUI/ISInventoryPage",
    },
    -- ... rest of your config
}
```

Files are loaded **in order**, so list dependencies first (e.g., `ISBaseObject` before anything that `:derive()`s from it).

## PZ install detection

The kit looks for PZ in this order:

1. `$PZ_INSTALL_DIR` env var (highest priority — set this on CI if you stage the game)
2. Common Steam paths:
   - Windows: `C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid`
   - Windows (alt drive): `D:\SteamLibrary\steamapps\common\ProjectZomboid`
   - Linux: `~/.steam/steam/steamapps/common/ProjectZomboid`
   - macOS: `~/Library/Application Support/Steam/steamapps/common/ProjectZomboid`
3. Fallback: log a warning, use mocks for each `vanilla_requires` entry

When detection succeeds, you'll see:

```
[PZTestKit] vanilla_requires: loading 3 file(s) from C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\media\lua
  [vanilla_requires] OK   (shared/ISBaseObject)
  [vanilla_requires] OK   (shared/TimedActions/ISBaseTimedAction)
  [vanilla_requires] OK   (shared/TimedActions/ISTransferAction)
```

When detection fails:

```
[PZTestKit] vanilla_requires: PZ install not found — set PZ_INSTALL_DIR env var or add to common Steam paths. Falling back to mocks for 3 entries.
```

Tests still run with the fallback — mocks in `mock_environment.lua` stand in. You **lose vanilla-drift detection** but keep suite green.

## CI considerations

### Option 1: accept the fallback

Easiest. Your CI runs on Ubuntu with no PZ install, `vanilla_requires` falls back to mocks, tests pass if your assertions don't depend on vanilla-only behavior.

**Risk:** your local dev machine uses real vanilla (via Steam install), your CI uses mocks. A bug that only manifests against real vanilla passes CI and breaks in-game. The v2.1.4 `ISBaseTimedAction.new` mock-missing-character bug was exactly this: tests passed locally where vanilla set `o.character`, failed on CI where the mock didn't.

Mitigation: keep the mock in `mock_environment.lua` faithful to vanilla. If you notice a CI-only failure, upstream a fix to the kit's mock so all downstream mods benefit.

### Option 2: stage vanilla files in your repo

Copy the vanilla files your tests need into a stable location in your repo (e.g., `test-fixtures/vanilla/`). Set `PZ_INSTALL_DIR` to that location on CI.

**Pros:** CI sees real vanilla code. Deterministic across PZ patches.
**Cons:** you freeze at one vanilla version. Need to manually refresh when you want to catch new regressions.

```yaml
# .github/workflows/test.yml
- run: |
    export PZ_INSTALL_DIR="${{ github.workspace }}/test-fixtures/vanilla"
    # PZ Test Kit expects PZ_INSTALL_DIR/media/lua/<rest of path>
    pztest
```

Check in only the specific files your `vanilla_requires` lists. Don't dump the whole game.

### Option 3: install PZ on CI via SteamCMD

Doable but slow (~2.5 GB download) and requires Steam credentials. Used by the PZ dedicated server Docker image. Overkill for most test suites.

## How it actually works

`vanilla_requires` runs after mock environment loads but before test files. For each entry:

1. Resolve `$PZ_INSTALL/media/lua/<entry>.lua` to an absolute path
2. If the file exists, `loadfile()` it in the test env. Any globals it defines (like `ISTransferAction`) become available.
3. If not found, leave the mock in place — whatever's in `mock_environment.lua` for that global.

The `ok` / `miss` log lines tell you which files loaded and which fell back.

## Interaction with the require resolver

`vanilla_requires` is **not** the same as `require "TimedActions/ISTransferAction"`. The require resolver only looks at your mod's own `media/lua/` tree plus listed cross-mod dependencies. It doesn't reach into PZ's install directory — that's what `vanilla_requires` is for.

If you need a vanilla file, put it in `vanilla_requires`. If you need a file from your own mod or a dependency, use `preload` or let auto-discovery handle it.

## Debugging

```bash
pztest                        # normal run
pztest --filter transferItem  # only tests matching "transferItem"
```

Add a print at the top of your test file to verify vanilla types loaded:

```lua
print("[diag] ISTransferAction.transferItem exists? " ..
    tostring(ISTransferAction and ISTransferAction.transferItem ~= nil))
```

If it logs `false`, your `vanilla_requires` entry missed. Check:
- Path is relative to `media/lua/` (not absolute)
- No `.lua` extension in the config
- File exists at `$PZ_INSTALL/media/lua/<path>.lua`

## FAQ

**Q: Can I load any vanilla file?**
A: In principle yes, but PZ Lua often requires game globals (`getPlayer()`, `getCell()`, `UIManager`) that aren't all mocked. Pure-data/logic files (`ISBaseObject`, `ISBaseTimedAction`, `ISTransferAction`) work out of the box. UI files (`ISInventoryPage`) may need extra stubs. Try it, see what breaks, file an issue.

**Q: What happens if a `vanilla_requires` file errors on load?**
A: The test runner reports it as a compile or runtime error. Fix your PZ install or stub the offending dependency in `mock_environment.lua`.

**Q: Does `vanilla_requires` replace `preload`?**
A: No. `vanilla_requires` loads vanilla PZ files. `preload` loads your mod's files. Use both.

**Q: Is there an order between `vanilla_requires` and `preload`?**
A: Yes — `vanilla_requires` runs first. Your preloaded modules will see the real vanilla globals if they reference them at load time.

**Q: Can I override a specific vanilla function for testing?**
A: Yes. After `vanilla_requires` runs, you can patch individual functions in your test setup:

```lua
-- In your test file's setup, after the config-driven loads:
local origTransferItem = ISTransferAction.transferItem
ISTransferAction.transferItem = function(self, ...)
    -- custom test behavior
    return origTransferItem(self, ...)
end
```

Remember to restore in teardown if your test suite shares state.
