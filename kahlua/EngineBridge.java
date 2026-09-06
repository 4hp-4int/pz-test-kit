import se.krka.kahlua.converter.KahluaConverterManager;
import se.krka.kahlua.integration.expose.LuaJavaClassExposer;
import se.krka.kahlua.vm.JavaFunction;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.LuaCallFrame;
import se.krka.kahlua.vm.Platform;

import java.io.PrintStream;
import java.lang.reflect.Method;
import java.net.URL;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.stream.Stream;

/**
 * PZ Test Kit — Engine Bridge ("real engine adoption")
 * =====================================================
 * Loads the REAL Project Zomboid Java classes (projectzomboid.jar) into the
 * kit's StubbingClassLoader and boots just enough of the engine headlessly to
 * give tests real script objects and real inventory items:
 *
 *   PZEngine.available()            -> boolean
 *   instanceItem("Base.LightBulb")  -> real zombie.inventory.* item
 *   getScriptManager()              -> real ScriptManager (parsed scripts)
 *
 * WHY THIS IS POSSIBLE: the dedicated server runs the whole script/item layer
 * with no OpenGL and no FMOD — headless operation is a supported mode of
 * these classes, not a hack. What the bridge does is reach the same state
 * without the server's world/network boot:
 *
 *   1. addJar(projectzomboid.jar) onto the StubbingClassLoader. Precedence
 *      is unchanged: runtime-jar baked stubs > stubs/ dir > REAL PZ classes >
 *      synthesized empties. The stubs keep absorbing the GL/FMOD-adjacent
 *      edges; everything else resolves real.
 *   2. Walk media/scripts of the PZ install + the mod under test ourselves
 *      (ScriptManager.Load() is welded to ZomboidFileSystem, which wants a
 *      full game-home boot; ParseScript(loadMode, text) is public and takes
 *      the file CONTENTS, so the file walk is the only part we replace).
 *   3. Reflectively run the same post-parse passes Load() runs:
 *      loadScripts(Init, all) then resolveItemTypes(). The Lua-coupled and
 *      world-coupled passes (RecipeManager.LoadedAfterLua, WorldDictionary,
 *      GameSounds) are skipped — item/script fidelity does not need them.
 *
 * All zombie.* access is reflective so this file compiles and loads with no
 * PZ install present; in that case boot() reports unavailable and tests
 * guard on PZEngine.available().
 *
 * Lua exposure mirrors LuaManager exactly: KahluaConverterManager +
 * NumberConverter + ArrayConverter, and a LuaJavaClassExposer subclass with
 * a curated shouldExpose set, exposeLikeJavaRecursively into the env — the
 * same machinery that builds __classmetatables in game, so real objects
 * answer obj:method() with the game's own dispatch.
 */
public final class EngineBridge {

    private EngineBridge() {}

    // Process-global boot state: scripts parse once, envs are per test file.
    private static boolean bootAttempted = false;
    private static boolean booted = false;
    private static String bootError = null;
    private static ClassLoader loader = null;

    // Classes exposed to Lua. Curated: the item/script surface tests touch.
    // Mods can extend via engine_expose in pz-test.lua (config_loader passes
    // them through _pz_engine_expose).
    private static final String[] DEFAULT_EXPOSED = {
        "zombie.inventory.InventoryItem",
        "zombie.inventory.InventoryItemFactory",
        "zombie.inventory.ItemContainer",
        "zombie.inventory.types.Food",
        "zombie.inventory.types.DrainableComboItem",
        "zombie.inventory.types.HandWeapon",
        "zombie.inventory.types.Clothing",
        "zombie.inventory.types.InventoryContainer",
        "zombie.inventory.types.Literature",
        "zombie.inventory.types.Key",
        "zombie.inventory.types.Moveable",
        "zombie.scripting.ScriptManager",
        "zombie.scripting.objects.Item",
        "zombie.scripting.objects.ScriptModule",
        "zombie.scripting.entity.GameEntityScript",
        "zombie.scripting.entity.components.crafting.CraftRecipe",
        "zombie.entity.components.fluids.FluidContainer",
        "zombie.entity.components.fluids.Fluid",
        "zombie.core.Color",
        "zombie.core.Colors",
        // The collections PZ itself exposes; getInputs()/getAllItems() etc.
        // hand these back and Lua calls :size()/:get() on them.
        "java.util.ArrayList",
        "java.util.HashMap",
    };

    public static boolean isBooted() { return booted; }
    public static String getBootError() { return bootError; }

    /** Find the PZ install the same way build_runtime_jar.py does. */
    public static Path findPzInstall(String override) {
        List<String> candidates = new ArrayList<>();
        if (override != null && !override.isEmpty()) candidates.add(override);
        String env = System.getenv("PZ_INSTALL_DIR");
        if (env != null && !env.isEmpty()) candidates.add(env);
        candidates.add("C:/Program Files (x86)/Steam/steamapps/common/ProjectZomboid");
        candidates.add("C:/Program Files/Steam/steamapps/common/ProjectZomboid");
        candidates.add(System.getProperty("user.home") + "/.steam/steam/steamapps/common/ProjectZomboid");
        for (String c : candidates) {
            Path p = Path.of(c);
            if (Files.exists(p.resolve("projectzomboid.jar"))) return p;
        }
        return null;
    }

    /**
     * Boot once per process. Safe to call repeatedly; only the first call
     * does work. Returns whether the engine is available afterwards.
     */
    public static synchronized boolean boot(String pzDirOverride, Path modRoot, PrintStream log) {
        if (bootAttempted) return booted;
        bootAttempted = true;
        long t0 = System.currentTimeMillis();

        Path pzDir = findPzInstall(pzDirOverride);
        if (pzDir == null) {
            bootError = "no PZ install found (set PZ_INSTALL_DIR); engine tests will report unavailable";
            log.println("[engine] " + bootError);
            return false;
        }

        loader = Thread.currentThread().getContextClassLoader();
        // Checked by NAME, not instanceof: when this class is itself loaded
        // through the StubbingClassLoader, its StubbingClassLoader class
        // literal is a different Class object than the running instance's.
        if (!loader.getClass().getName().equals("StubbingClassLoader")) {
            bootError = "context classloader is not the StubbingClassLoader; engine mode needs the launcher";
            log.println("[engine] " + bootError);
            return false;
        }

        try {
            loader.getClass().getMethod("addJar", URL.class)
                .invoke(loader, pzDir.resolve("projectzomboid.jar").toUri().toURL());
            log.println("[engine] adopted " + pzDir.resolve("projectzomboid.jar"));

            // The game seeds its RNGs during boot; entity scripts roll during
            // load (entity_piano rolls a random tune) and NPE without one.
            for (String randName : new String[] { "zombie.core.random.RandStandard", "zombie.core.random.RandLua" }) {
                try {
                    Class<?> randClass = cls(randName);
                    Object inst = randClass.getField("INSTANCE").get(null);
                    randClass.getMethod("init").invoke(inst);
                } catch (Throwable t) {
                    log.println("[engine] " + randName + ".init skipped: " + t);
                }
            }

            // Script bodies register their source file relative to the PZ
            // install (ZomboidFileSystem.getRelativeFile -> base.lowercaseUri)
            // — 219 item bodies died on base being null. The full init()
            // enumerates every media folder and assumes cwd is the install;
            // all the script layer needs is base and workdir set.
            Class<?> zfsClass = cls("zombie.ZomboidFileSystem");
            Object zfs = zfsClass.getField("instance").get(null);
            Object baseFolder = zfsClass.getField("base").get(zfs);
            baseFolder.getClass().getMethod("set", java.io.File.class)
                .invoke(baseFolder, pzDir.toFile());
            java.lang.reflect.Field workdirField = zfsClass.getDeclaredField("workdir");
            workdirField.setAccessible(true);
            Object workdirFolder = workdirField.get(zfs);
            workdirFolder.getClass().getMethod("set", java.io.File.class)
                .invoke(workdirFolder, pzDir.resolve("media").toFile());

            // Item display names route through the JAVA Translator
            // (Item.getDisplayName -> ItemName_* keys); unloaded, it echoes
            // the full type and name-derived logic sees nil. Same call the
            // dedicated-server translation fix makes. Best-effort: a failure
            // costs display names, not the boot.
            try {
                cls("zombie.core.Translator").getMethod("loadFiles").invoke(null);
                log.println("[engine] Translator loaded");
            } catch (Throwable t) {
                Throwable root = t; while (root.getCause() != null) root = root.getCause();
                log.println("[engine] Translator.loadFiles skipped: " + root);
            }

            // ZomboidGlobals (encumbrance multipliers, metabolism rates)
            // load from the game's defines.lua via LuaManager.env in real
            // boot; unloaded, every constant is a Java-default 0 and weight
            // math quietly collapses. Run the REAL defines.lua in a scratch
            // Kahlua env and hand it to the REAL loader. Best-effort.
            try {
                se.krka.kahlua.j2se.J2SEPlatform scratchPlatform = new se.krka.kahlua.j2se.J2SEPlatform();
                KahluaTable scratchEnv = scratchPlatform.newEnvironment();
                String defines = Files.readString(pzDir.resolve("media/lua/shared/defines.lua"));
                se.krka.kahlua.vm.LuaClosure definesClosure =
                    se.krka.kahlua.luaj.compiler.LuaCompiler.loadstring(defines, "defines.lua", scratchEnv);
                se.krka.kahlua.vm.KahluaThread scratchThread =
                    new se.krka.kahlua.vm.KahluaThread(System.out, scratchPlatform, scratchEnv);
                scratchThread.debugOwnerThread = Thread.currentThread();
                scratchThread.pcall(definesClosure, new Object[0]);
                cls("zombie.Lua.LuaManager").getField("env").set(null, scratchEnv);
                cls("zombie.ZomboidGlobals").getMethod("Load").invoke(null);
                log.println("[engine] ZomboidGlobals loaded from defines.lua");
            } catch (Throwable t) {
                Throwable root = t; while (root.getCause() != null) root = root.getCause();
                log.println("[engine] ZomboidGlobals load skipped: " + root);
            }

            Class<?> smClass = cls("zombie.scripting.ScriptManager");
            Object sm = smClass.getField("instance").get(null);
            Class<?> loadModeClass = cls("zombie.scripting.ScriptLoadMode");
            Object initMode = enumConst(loadModeClass, "Init");
            Method parse = smClass.getMethod("ParseScript", loadModeClass, String.class);

            // Load() sets these per file; script bodies capture the mod id
            // and NPE later without them ("pz-vanilla" is vanilla's own tag).
            java.lang.reflect.Field modField = smClass.getDeclaredField("currentLoadFileMod");
            modField.setAccessible(true);
            java.lang.reflect.Field absField = smClass.getDeclaredField("currentLoadFileAbsPath");
            absField.setAccessible(true);
            java.lang.reflect.Field nameField = smClass.getDeclaredField("currentLoadFileName");
            nameField.setAccessible(true);
            // Distinct from the static: ScriptBucket reads the INSTANCE field
            // ScriptManager.instance.currentFileName for body bookkeeping.
            java.lang.reflect.Field instFileField = smClass.getDeclaredField("currentFileName");
            instFileField.setAccessible(true);
            FileContext ctx = new FileContext(modField, absField, nameField, instFileField, sm);

            int files = 0;
            files += parseTree(sm, parse, initMode, pzDir.resolve("media/scripts"), "pz-vanilla", ctx, log);
            if (modRoot != null) {
                files += parseTree(sm, parse, initMode, modRoot.resolve("media/scripts"), modIdOf(modRoot), ctx, log);
            }
            log.println("[engine] parsed " + files + " script files");

            // The same post-parse passes ScriptManager.Load() runs, minus the
            // Lua-, sound- and world-dictionary-coupled ones.
            Method loadScripts = smClass.getDeclaredMethod("loadScripts", loadModeClass, java.util.EnumSet.class);
            loadScripts.setAccessible(true);
            Class<?> scriptType = cls("zombie.scripting.ScriptType");
            // ALLOWLIST of script types to load, not a denylist: vehicles
            // pull real-LuaManager table utilities, ragdoll/physics shapes
            // call straight into Bullet NATIVES, the Xui family is UI, and
            // models/sounds are assets. What offline tests touch is the
            // item/recipe/entity/fluid surface — so that is what loads.
            Set<String> wanted = Set.of(
                "Item", "Recipe", "UniqueRecipe", "EvolvedRecipe", "Fixing",
                "CraftRecipe", "Entity", "EntityTemplate", "EntityComponent",
                "ItemConfig", "ItemFilter", "FluidDefinition", "FluidFilter",
                "EnergyDefinition", "StringList", "TimedAction");
            @SuppressWarnings({"unchecked", "rawtypes"})
            java.util.EnumSet<?> types = java.util.EnumSet.allOf((Class) scriptType);
            types.removeIf(t -> !wanted.contains(((Enum<?>) t).name()));
            loadScripts.invoke(sm, initMode, types);

            Method resolve = smClass.getDeclaredMethod("resolveItemTypes");
            resolve.setAccessible(true);
            resolve.invoke(sm);

            Object allItems = smClass.getMethod("getAllItems").invoke(sm);
            log.println("[engine] " + allItems.getClass().getMethod("size").invoke(allItems)
                + " item scripts registered");

            // Smoke: the engine is only "available" if it can actually mint
            // a real item. Cheap and catches half-boots loudly.
            Object bulb = createItem("Base.LightBulb");
            if (bulb == null) {
                throw new IllegalStateException("boot smoke failed: CreateItem(Base.LightBulb) returned null");
            }

            booted = true;
            log.println("[engine] up in " + (System.currentTimeMillis() - t0) + "ms (real scripts, real items)");
        } catch (Throwable t) {
            Throwable root = t;
            while (root.getCause() != null) root = root.getCause();
            bootError = root.getClass().getSimpleName() + ": " + root.getMessage();
            log.println("[engine] boot failed: " + bootError);
            for (StackTraceElement el : root.getStackTrace()) {
                if (el.getClassName().startsWith("zombie.")) { log.println("[engine]   at " + el); break; }
            }
        }
        return booted;
    }

    /** The per-file fields Load()/LoadFile maintain while parsing. */
    private record FileContext(java.lang.reflect.Field mod, java.lang.reflect.Field absPath,
                               java.lang.reflect.Field name, java.lang.reflect.Field instFile,
                               Object scriptManager) {
        void set(String modId, Path file) throws IllegalAccessException {
            mod.set(null, modId);
            absPath.set(null, file.toAbsolutePath().toString());
            name.set(null, file.getFileName().toString());
            instFile.set(scriptManager, file.toAbsolutePath().toString());
        }
    }

    /** Mod id from mod.info, falling back to the directory name. */
    private static String modIdOf(Path modRoot) {
        try {
            Path info = modRoot.resolve("mod.info");
            if (Files.exists(info)) {
                for (String line : Files.readAllLines(info)) {
                    if (line.startsWith("id=")) return line.substring(3).trim();
                }
            }
        } catch (Exception ignored) {}
        return modRoot.getFileName().toString();
    }

    private static int parseTree(Object sm, Method parse, Object mode, Path scriptsDir,
                                 String modId, FileContext ctx, PrintStream log) throws Exception {
        if (!Files.isDirectory(scriptsDir)) return 0;
        List<Path> files;
        try (Stream<Path> walk = Files.walk(scriptsDir)) {
            files = walk.filter(p -> p.toString().endsWith(".txt"))
                .sorted(Comparator.comparing(p -> scriptsDir.relativize(p).toString().toLowerCase()))
                .toList();
        }
        int parsed = 0;
        for (Path f : files) {
            String text = Files.readString(f);
            try {
                ctx.set(modId, f);
                // LoadFile strips block comments BEFORE ParseScript; skip it
                // and a /* header */ above `module Base` becomes part of the
                // module name and every definition in the file goes missing —
                // silently. (The same failure mode script authors hit with //
                // comments, from the other side.)
                text = zombie.scripting.ScriptParser.stripComments(text);
                parse.invoke(sm, mode, text);
                parsed++;
            } catch (Throwable t) {
                Throwable root = t; while (root.getCause() != null) root = root.getCause();
                log.println("[engine] parse failed, skipping " + scriptsDir.relativize(f) + ": " + root);
            }
        }
        return parsed;
    }

    // ------------------------------------------------------------------
    // Per-env Lua exposure
    // ------------------------------------------------------------------

    private static final class KitExposer extends LuaJavaClassExposer {
        private final Set<Class<?>> exposed = new LinkedHashSet<>();
        KitExposer(KahluaConverterManager manager, Platform platform, KahluaTable env) {
            super(manager, platform, env);
        }
        void expose(Class<?> clazz) { exposed.add(clazz); }
        @Override
        public boolean shouldExpose(Class<?> clazz) {
            return clazz != null && exposed.contains(clazz);
        }
    }

    /**
     * Install PZEngine + class exposure into a freshly built test env.
     * No-op (installs an unavailable PZEngine) when boot failed or was
     * never attempted, so tests can always ask PZEngine.available().
     */
    public static void installIntoEnv(Platform platform, se.krka.kahlua.vm.KahluaThread thread,
                                      KahluaTable env, List<String> extraExpose,
                                      boolean chainGlobalInstanceItem, PrintStream log) {
        KahluaTable pzEngine = platform.newTable();
        env.rawset("PZEngine", pzEngine);
        pzEngine.rawset("available", (JavaFunction) (frame, n) -> { frame.push(booted); return 1; });
        pzEngine.rawset("bootError", (JavaFunction) (frame, n) -> { frame.push(bootError); return 1; });
        if (!booted) return;

        try {
            KahluaConverterManager manager = new KahluaConverterManager();
            // PZ relocated the number/array converters into zombie.Lua, so in
            // engine mode they come from the game jar, reflectively.
            Class<?> numConv = cls("zombie.Lua.KahluaNumberConverter");
            numConv.getMethod("install", KahluaConverterManager.class).invoke(null, manager);
            // Its ctor demands a J2SEPlatform specifically; it only ever asks
            // it for newTable(), and a KahluaTableImpl is a KahluaTableImpl
            // whichever platform minted it.
            Class<?> arrConv = cls("zombie.Lua.KahluaArrayConverter");
            se.krka.kahlua.j2se.J2SEPlatform arrPlatform = new se.krka.kahlua.j2se.J2SEPlatform();
            Object arrConvInst = arrConv.getConstructor(se.krka.kahlua.j2se.J2SEPlatform.class, KahluaConverterManager.class)
                .newInstance(arrPlatform, manager);
            arrConv.getMethod("install").invoke(arrConvInst);
            KitExposer exposer = new KitExposer(manager, platform, env);

            List<String> names = new ArrayList<>(List.of(DEFAULT_EXPOSED));
            if (extraExpose != null) names.addAll(extraExpose);
            List<Class<?>> classes = new ArrayList<>();
            for (String name : names) {
                try {
                    classes.add(Class.forName(name, true, loader));
                } catch (Throwable t) {
                    log.println("[engine] cannot expose " + name + ": " + t);
                }
            }
            for (Class<?> c : classes) exposer.expose(c);
            for (Class<?> c : classes) exposer.exposeLikeJavaRecursively(c, env);

            // Real minting is ALWAYS on PZEngine.instanceItem — engine test
            // files reach it regardless of what the mod's harness did to the
            // global. The GLOBAL instanceItem chain is opt-in per mod
            // (engine_items = true): the migration to real items surfaced
            // that legacy suites legitimately poke mock internals (_stats
            // writes, spy-wrapped methods, dual-VM sim items) — things a
            // real Java object cannot do — so flipping a whole suite is a
            // per-test migration, not a default.
            JavaFunction realInstanceItem = (frame, n) -> {
                Object name = frame.get(0);
                frame.push(name instanceof String s ? createItem(s) : null);
                return 1;
            };
            pzEngine.rawset("instanceItem", realInstanceItem);
            if (chainGlobalInstanceItem) {
                // Chain, don't replace: real when the parsed registry knows
                // the type, delegate to the mod's factory / kit mock for
                // contrived test-only types.
                env.rawset("_pz_engine_instanceItem", realInstanceItem);
                String chain = "local real, prev = _pz_engine_instanceItem, instanceItem\n"
                    + "instanceItem = function(fullType)\n"
                    + "    local item = real(fullType)\n"
                    + "    if item ~= nil then return item end\n"
                    + "    if prev ~= nil then return prev(fullType) end\n"
                    + "    return nil\n"
                    + "end\n";
                se.krka.kahlua.vm.LuaClosure closure =
                    se.krka.kahlua.luaj.compiler.LuaCompiler.loadstring(chain, "engine_instanceItem_chain", env);
                thread.pcall(closure, new Object[0]);
                log.println("[engine] global instanceItem chained (engine_items = true)");
            }
            env.rawset("getScriptManager", (JavaFunction) (frame, n) -> {
                try {
                    frame.push(cls("zombie.scripting.ScriptManager").getField("instance").get(null));
                } catch (Throwable t) { frame.push(null); }
                return 1;
            });

            // PZEngine.wireRoundTrip(tbl) -> (received, drops): the payload
            // as the OTHER side of a sendClientCommand/sendServerCommand
            // would see it (real TableNetworkUtils bytes in the middle),
            // plus a 1..N array describing every top-level entry the wire
            // dropped. Usable from any engine test to pin a command payload
            // as wire-safe without spinning up a full sim.
            pzEngine.rawset("wireRoundTrip", (JavaFunction) (frame, n) -> {
                Object[] saved = wireSave(frame.get(0));
                if (saved == null) { frame.push(null); return 1; }
                frame.push(wireLoad((byte[]) saved[0]));
                frame.push(saved[1]);
                return 2;
            });

            // instanceof must answer for two worlds. Java objects get a walk
            // of the real class hierarchy by simple name (the same answer
            // the game's typeMap gives for exposed classes). Mock tables go
            // to whatever instanceof was installed before us — dispatched in
            // LUA, because answering for a table can mean running its
            // metamethods, and invoking Lua from inside a JavaFunction frame
            // corrupts the VM stack. (Found the hard way: a sealed fixture's
            // __index closure, reached via tableget from Java, died silently
            // inside an event pcall and a cart unequip never announced.)
            env.rawset("_pz_engine_instanceof", (JavaFunction) (frame, n) -> {
                Object obj = frame.get(0);
                Object nameArg = frame.get(1);
                if (obj == null || !(nameArg instanceof String name) || obj instanceof KahluaTable) {
                    frame.push(Boolean.FALSE);
                    return 1;
                }
                for (Class<?> c = obj.getClass(); c != null; c = c.getSuperclass()) {
                    if (c.getSimpleName().equals(name)) { frame.push(Boolean.TRUE); return 1; }
                    for (Class<?> i : c.getInterfaces()) {
                        if (i.getSimpleName().equals(name)) { frame.push(Boolean.TRUE); return 1; }
                    }
                }
                frame.push(Boolean.FALSE);
                return 1;
            });
            String isChain = "local javaIs, prev = _pz_engine_instanceof, instanceof\n"
                + "instanceof = function(obj, name)\n"
                + "    if type(obj) == \"table\" then\n"
                + "        if prev ~= nil then return prev(obj, name) end\n"
                + "        return false\n"
                + "    end\n"
                + "    return javaIs(obj, name)\n"
                + "end\n";
            se.krka.kahlua.vm.LuaClosure isClosure =
                se.krka.kahlua.luaj.compiler.LuaCompiler.loadstring(isChain, "engine_instanceof_chain", env);
            thread.pcall(isClosure, new Object[0]);
        } catch (Throwable t) {
            log.println("[engine] env install failed: " + t);
        }
    }

    // ------------------------------------------------------------------
    // Reflection helpers
    // ------------------------------------------------------------------

    private static Class<?> cls(String name) throws ClassNotFoundException {
        return Class.forName(name, true, loader);
    }

    private static Object enumConst(Class<?> enumClass, String name) {
        for (Object c : enumClass.getEnumConstants()) {
            if (((Enum<?>) c).name().equals(name)) return c;
        }
        throw new IllegalArgumentException(enumClass + " has no constant " + name);
    }

    /** Real InventoryItemFactory.CreateItem(String). Null when not booted. */
    public static Object createItem(String fullType) {
        if (loader == null) return null;
        try {
            Class<?> factory = cls("zombie.inventory.InventoryItemFactory");
            return factory.getMethod("CreateItem", String.class).invoke(null, fullType);
        } catch (Throwable t) {
            Throwable root = t; while (root.getCause() != null) root = root.getCause();
            System.err.println("[engine] CreateItem(" + fullType + ") failed: " + root);
            return null;
        }
    }

    // ------------------------------------------------------------------
    // Real wire serialization (zombie.network.TableNetworkUtils)
    // ------------------------------------------------------------------
    // The EXACT save/load pair every command payload rides in real MP:
    // GameClient.sendClientCommand (:1858) and GameServer's send (:3487)
    // both call TableNetworkUtils.save; the receiving side loads with the
    // same class. Round-tripping through it makes the wire's silent-drop
    // semantics observable offline: functions, non-string/number keys and
    // any other unsendable entry vanish exactly as they do on a live
    // server (vanilla logs an ERROR per dropped top-level entry at send;
    // DualVMSim mirrors that line). Nested tables recurse; drops INSIDE a
    // nested table are silent in vanilla too — canSave only scans the top
    // level — so they are silent here, faithfully.

    private static final se.krka.kahlua.j2se.J2SEPlatform WIRE_PLATFORM =
            new se.krka.kahlua.j2se.J2SEPlatform();

    /** Serialize a payload table through the real wire format. Returns
     *  { byte[] bytes, KahluaTable drops } where drops is a 1..N array of
     *  "key,value" descriptions of entries the wire refused (the same
     *  key,value rendering vanilla's ERROR line uses). Null when the
     *  engine is down or the input is not a table. Serializer failures
     *  propagate as RuntimeException — a payload that crashes the real
     *  serializer should fail the test loudly, not quietly fall back. */
    public static Object[] wireSave(Object table) {
        if (loader == null || !booted || !(table instanceof KahluaTable tbl)) return null;
        try {
            Class<?> tnu = cls("zombie.network.TableNetworkUtils");
            java.lang.reflect.Method canSave = tnu.getMethod("canSave", Object.class, Object.class);

            KahluaTable drops = WIRE_PLATFORM.newTable();
            int dropCount = 0;
            se.krka.kahlua.vm.KahluaTableIterator it = tbl.iterator();
            while (it.advance()) {
                if (!Boolean.TRUE.equals(canSave.invoke(null, it.getKey(), it.getValue()))) {
                    drops.rawset(++dropCount, it.getKey() + "," + it.getValue());
                }
            }

            java.nio.ByteBuffer bb = java.nio.ByteBuffer.allocate(1 << 20);
            Class<?> writerCls = cls("zombie.core.network.ByteBufferWriter");
            Object writer = writerCls.getConstructor(java.nio.ByteBuffer.class).newInstance(bb);
            tnu.getMethod("save", KahluaTable.class, writerCls).invoke(null, tbl, writer);
            bb.flip();
            byte[] bytes = new byte[bb.remaining()];
            bb.get(bytes);
            return new Object[] { bytes, drops };
        } catch (Throwable t) {
            Throwable root = t; while (root.getCause() != null) root = root.getCause();
            throw new RuntimeException("real wire save failed: " + root, root);
        }
    }

    /** Deserialize wire bytes into a fresh table — the receiving side's
     *  view. Each call returns an independent copy, exactly like every
     *  client of a broadcast deserializing its own packet. */
    public static Object wireLoad(byte[] bytes) {
        if (loader == null || !booted || bytes == null) return null;
        try {
            Class<?> tnu = cls("zombie.network.TableNetworkUtils");
            Class<?> readerCls = cls("zombie.core.network.ByteBufferReader");
            Object reader = readerCls.getConstructor(java.nio.ByteBuffer.class)
                    .newInstance(java.nio.ByteBuffer.wrap(bytes));
            Object out = WIRE_PLATFORM.newTable();
            tnu.getMethod("load", KahluaTable.class, readerCls).invoke(null, out, reader);
            return out;
        } catch (Throwable t) {
            Throwable root = t; while (root.getCause() != null) root = root.getCause();
            throw new RuntimeException("real wire load failed: " + root, root);
        }
    }

    // ------------------------------------------------------------------
    // Standalone smoke: java -cp <jar>;<stubs>;. EngineBridge [pzDir] [modRoot]
    // Relaunches itself through the StubbingClassLoader like the launcher.
    // ------------------------------------------------------------------

    public static void main(String[] args) throws Exception {
        if (!(EngineBridge.class.getClassLoader() instanceof StubbingClassLoader)) {
            String cp = System.getProperty("java.class.path");
            String[] entries = cp.split(java.util.regex.Pattern.quote(java.io.File.pathSeparator));
            URL[] urls = new URL[entries.length];
            for (int i = 0; i < entries.length; i++) {
                urls[i] = Path.of(entries[i]).toAbsolutePath().toUri().toURL();
            }
            StubbingClassLoader scl = new StubbingClassLoader(urls, EngineBridge.class.getClassLoader().getParent());
            Thread.currentThread().setContextClassLoader(scl);
            Class<?> self = Class.forName("EngineBridge", true, scl);
            self.getMethod("runSmoke", String[].class).invoke(null, (Object) args);
            return;
        }
        runSmoke(args);
    }

    public static void runSmoke(String[] args) {
        String pzDir = args.length > 0 ? args[0] : null;
        Path modRoot = args.length > 1 ? Path.of(args[1]) : null;
        boolean up = boot(pzDir, modRoot, System.out);
        if (!up) { System.out.println("[engine] SMOKE FAIL: " + bootError); System.exit(1); }

        Object bulb = createItem("Base.LightBulb");
        try {
            Object cond = bulb.getClass().getMethod("getCondition").invoke(bulb);
            Object max = bulb.getClass().getMethod("getConditionMax").invoke(bulb);
            Object type = bulb.getClass().getMethod("getFullType").invoke(bulb);
            System.out.println("[engine] SMOKE: " + type + " condition " + cond + "/" + max
                + " class " + bulb.getClass().getName());
            Object food = createItem("Base.PanFriedVegetables2");
            if (food != null) {
                Object hunger = food.getClass().getMethod("getHungChange").invoke(food);
                System.out.println("[engine] SMOKE: roast hunger " + hunger + " class " + food.getClass().getSimpleName());
            }
            System.out.println("[engine] SMOKE PASS");
        } catch (Throwable t) {
            Throwable root = t; while (root.getCause() != null) root = root.getCause();
            System.out.println("[engine] SMOKE FAIL: " + root);
            System.exit(1);
        }
    }
}
