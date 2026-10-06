package zombie.Lua;

import se.krka.kahlua.vm.KahluaThread;
import se.krka.kahlua.vm.Coroutine;

/**
 * Stub for PZ's LuaManager. Kahlua's KahluaThread reads these fields during
 * error handling and breakpoint checks — all gated by `Core.debug` in real PZ,
 * but the JVM still resolves the class. The real LuaManager lives inside PZ's
 * projectzomboid.jar.
 *
 * Leaving `thread` as null causes KahluaThread's `if (thread == this)` debug
 * guards to evaluate false, short-circuiting the debug-only branches.
 */
public class LuaManager {
    public static KahluaThread thread = null;
    public static KahluaThread debugthread = null;
    // Typed as the real fields are: engine bytecode resolves fields by name
    // AND type, so an Object-typed stand-in is a NoSuchFieldError. Null until
    // engine mode's EngineBridge.installIntoEnv points them at a real
    // LuaCaller; the non-engine harness never reaches the code that reads them.
    public static se.krka.kahlua.integration.LuaCaller caller = null;
    public static se.krka.kahlua.integration.LuaCaller debugcaller = null;

    // Engine mode: the CURRENT test file's env, for getFunctionObject. Kept
    // apart from `env` (the defines.lua scratch env ZomboidGlobals reads).
    public static se.krka.kahlua.vm.KahluaTable functionEnv = null;

    /**
     * Recipe Lua hooks (OnCreate, OnTest, OnStart...) are looked up by dotted
     * name -- CraftRecipeData.initLuaFunctions calls this for any recipe that
     * declares one, BEFORE outputs are created. Missing, every such recipe
     * died mid-craft with its inputs already consumed. Same walk as the real
     * method (LuaManager.java:1413); an unknown name is null, which the engine
     * treats as "no hook" and logs.
     */
    public static Object getFunctionObject(String functionName) {
        if (functionName == null || functionName.isEmpty() || functionEnv == null) return null;
        se.krka.kahlua.vm.KahluaTable t = functionEnv;
        String[] ss = functionName.split(java.util.regex.Pattern.quote("."));
        for (int i = 0; i < ss.length - 1; i++) {
            Object o = t.rawget(ss[i]);
            if (!(o instanceof se.krka.kahlua.vm.KahluaTable)) return null;
            t = (se.krka.kahlua.vm.KahluaTable) o;
        }
        return t.rawget(ss[ss.length - 1]);
    }

    public static Object getFunctionObject(String functionName, zombie.debug.DebugType logger) {
        return getFunctionObject(functionName);
    }

    /**
     * Real-shaped getTableObject: a Lua global (dotted path) by name, from the
     * test file's env, then the scratch env. Every world sound reaches it
     * (WorldSoundManager.addSound -> FishSchoolManager.isNoFishZone:264), so
     * missing it made every IsoGameCharacter.Hit die mid-hit with a
     * NoSuchMethodError -- after OnHitZombie fired and before any damage -- and
     * Kahlua swallowed the Error, so Lua saw a hit that silently did nothing.
     */
    public static Object getTableObject(String tableName) {
        if (tableName == null || tableName.isEmpty()) return null;
        for (se.krka.kahlua.vm.KahluaTable root : new se.krka.kahlua.vm.KahluaTable[] { functionEnv, env }) {
            if (root == null) continue;
            Object o = root;
            for (String part : tableName.split(java.util.regex.Pattern.quote("."))) {
                if (!(o instanceof se.krka.kahlua.vm.KahluaTable t)) { o = null; break; }
                o = t.rawget(part);
            }
            if (o != null) return o;
        }
        return null;
    }

    // Engine mode: ZomboidGlobals.Load() reads LuaManager.env's
    // "ZomboidGlobals" table. EngineBridge points this at a scratch env that
    // ran the game's real defines.lua, so encumbrance and metabolism
    // constants carry their real values instead of Java field defaults (0).
    public static se.krka.kahlua.vm.KahluaTable env = null;

    // Engine mode (EngineBridge): real script-load code paths read
    // LuaManager.platform to build Kahlua tables (VehicleScript.LoadTable is
    // the first to trip it). A real J2SEPlatform is safe headless — it is
    // just a table factory — and keeping the stub, rather than letting the
    // real LuaManager in, keeps the rest of the real class's heavy static
    // surface (env, exposer, event wiring) out of the harness.
    public static se.krka.kahlua.j2se.J2SEPlatform platform = new se.krka.kahlua.j2se.J2SEPlatform();

    // Engine mode: the thread boot ran defines.lua on, and the one RunLua
    // executes files on -- always against `env`, the same scratch env.
    public static KahluaThread scriptThread = null;
    public static java.util.List<String> loaded = new java.util.ArrayList<>();

    /**
     * Real-shaped RunLua: execute a Lua file into `env` and return its first
     * result. SandboxOptions' constructor (SandboxOptions.java:269-275) runs
     * defines.lua and the "Apocalypse" preset through this; missing, its
     * static init threw NoSuchMethodError, and every engine path that touches
     * SandboxOptions.instance failed -- IsoGridSquare.AddWorldInventoryItem
     * among them, which then reached Lua as a silent nil (Kahlua retries the
     * next overload when one throws). No-op (null) outside engine mode.
     */
    public static Object RunLua(String filename) { return RunLua(filename, false); }

    public static Object RunLua(String filename, boolean rewriteEvents) {
        if (env == null || scriptThread == null || filename == null) return null;
        String key = filename.replace("\\", "/");
        try {
            String src = new String(java.nio.file.Files.readAllBytes(java.nio.file.Paths.get(filename)),
                java.nio.charset.StandardCharsets.UTF_8);
            se.krka.kahlua.vm.LuaClosure c = se.krka.kahlua.luaj.compiler.LuaCompiler.loadstring(src, key, env);
            Object[] r = scriptThread.pcall(c, new Object[0]);
            if (!loaded.contains(key)) loaded.add(key);
            if (r != null && r.length >= 1 && Boolean.FALSE.equals(r[0])) {
                System.err.println("[engine] RunLua(" + key + ") failed: " + (r.length > 1 ? r[1] : "?"));
                return null;
            }
            return r != null && r.length >= 2 ? r[1] : null;
        } catch (Exception e) {
            System.err.println("[engine] RunLua(" + key + "): " + e);
            return null;
        }
    }

    public static String getSandboxCacheDir() {
        java.io.File d = new java.io.File(System.getProperty("java.io.tmpdir"), "pztest-zomboid/Sandbox Presets");
        d.mkdirs();
        return d.getAbsolutePath();
    }

    public static StackTraceElement[] getLuaStackStrace(Coroutine c) {
        return new StackTraceElement[0];
    }

    // Engine mode: the real debug/exception pipeline decorates Java stack
    // traces with Lua frames. No Lua frames here — identity pass-through.
    public static StackTraceElement[] insertAnyLuaTraceElements(StackTraceElement[] elements) {
        return elements;
    }

    // Engine mode: real InventoryContainer construction copies its Lua-side
    // defaults through these. Shallow copy matches the constructor's use.
    public static se.krka.kahlua.vm.KahluaTable copyTable(se.krka.kahlua.vm.KahluaTable target,
                                                          se.krka.kahlua.vm.KahluaTable source) {
        if (source == null || target == null) return target;
        se.krka.kahlua.vm.KahluaTableIterator it = source.iterator();
        while (it.advance()) {
            target.rawset(it.getKey(), it.getValue());
        }
        return target;
    }

    public static se.krka.kahlua.vm.KahluaTable copyTable(se.krka.kahlua.vm.KahluaTable source) {
        se.krka.kahlua.vm.KahluaTable target = platform.newTable();
        return copyTable(target, source);
    }

    /**
     * Engine code calls LuaManager.GlobalObject's statics directly (the XP
     * award: CraftRecipe.addXP -> GlobalObject.getCore(), CraftRecipe:1459).
     * The REAL nested class cannot load beside this stub outer class: its
     * static init builds a private nested comparator, and the JVM rejects the
     * access because the stub outer does not list it as a nest member
     * (IllegalAccessError in GlobalObject.<clinit>:10355). Kahlua swallowed
     * it, so every recipe with an xpAward consumed its inputs, created its
     * outputs and then skipped OnCreate (repairs, sharpening, smelting...)
     * and the craft history. Declared here it is a true nestmate; each
     * method mirrors the real body (LuaManager.java line in the comment).
     * Engine calls to a method not listed here are a NoSuchMethodError at
     * that call: add it from the real class.
     */
    public static class GlobalObject {
        public static zombie.core.Core getCore() { return zombie.core.Core.getInstance(); }                         // :6287
        public static String getRecipeDisplayName(String name) { return zombie.core.Translator.getRecipeName(name); } // :7536
        public static zombie.characters.IsoPlayer getSpecificPlayer(int player) { return zombie.characters.IsoPlayer.players[player]; } // :3798
        public static zombie.characters.IsoPlayer getPlayer() { return zombie.characters.IsoPlayer.getInstance(); }  // :3603
        public static zombie.iso.IsoWorld getWorld() { return zombie.iso.IsoWorld.instance; }                        // :5008
        public static zombie.iso.IsoCell getCell() { return zombie.iso.IsoWorld.instance.getCell(); }                // :5013
        public static zombie.SandboxOptions getSandboxOptions() { return zombie.SandboxOptions.instance; }           // :5043
        public static boolean isMultiplayer() { return zombie.network.GameClient.client || zombie.network.GameServer.server; } // :3973
        public static boolean isAdmin() { return false; }   // :7697 (headless: no client connection)
        public static double ZombRand(double max) {                                                                  // :6147
            if (max == 0.0) return 0.0;
            return max < 0.0 ? -zombie.core.random.RandLua.INSTANCE.Next(-((long) max)) : zombie.core.random.RandLua.INSTANCE.Next((long) max);
        }
        public static double ZombRand(double min, double max) { return zombie.core.random.RandLua.INSTANCE.Next((int) min, (int) max); } // :6175
        public static zombie.inventory.InventoryItem instanceItem(String item) { return zombie.inventory.InventoryItemFactory.CreateItem(item); } // :4903
        public static zombie.iso.sprite.IsoSprite getSprite(String sprite) { return zombie.iso.sprite.IsoSpriteManager.instance.getSprite(sprite); } // :7551
        public static zombie.radio.ZomboidRadio getZomboidRadio() {                                                  // :2874
            return zombie.radio.ZomboidRadio.hasInstance() ? zombie.radio.ZomboidRadio.getInstance() : null;
        }
        public static void sendAddItemToContainer(zombie.inventory.ItemContainer container, zombie.inventory.InventoryItem item) { // :10336
            if (zombie.network.GameServer.server) zombie.network.GameServer.sendAddItemToContainer(container, item);
        }
        public static boolean isSystemWindows() { return System.getProperty("os.name").startsWith("Win"); }         // :6381
    }
}
