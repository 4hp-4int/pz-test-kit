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
    /** The install boot adopted; PZEngine.loadVanilla reads media/lua from it. */
    private static Path pzInstallDir;
    private static String bootError = null;
    private static ClassLoader loader = null;

    // Classes exposed to Lua. Curated: the item/script surface tests touch.
    // Mods can extend via engine_expose in pz-test.lua (config_loader passes
    // them through _pz_engine_expose).
    private static final String[] DEFAULT_EXPOSED = {
        "zombie.inventory.InventoryItem",
        "zombie.inventory.InventoryItemFactory",
        // PZEngine.newPlayer (character spike, 2026-10-04)
        "zombie.characters.IsoGameCharacter",
        "zombie.characters.IsoPlayer",
        "zombie.characters.IsoZombie",   // PZEngine.newZombie (event lab)
        // The server's authoritative gate for every vanilla item transfer
        // (ItemTransactionPacket -> isConsistent, all Java-internal calls):
        // MP probes ask it directly what a dedi would accept.
        "zombie.core.TransactionManager",
        // Vanilla logs through it (DebugType.ClientCommand:noise(...) in
        // server/ClientCommands.lua, before it dispatches); the game exposes
        // it (LuaManager.java:1877). Unexposed, every vanilla client command
        // died on its log line.
        "zombie.debug.DebugType",
        // The Arena (headless combat): the damage pipeline's own steps and its
        // tunables (CombatManager.attackCollisionCheck's per-target maths,
        // applyMeleeEnduranceLoss, the CombatConfig multipliers).
        "zombie.CombatManager",
        "zombie.combat.CombatConfig",
        "zombie.combat.CombatConfigKey",
        // The game exposes it (LuaManager.java:1824); without it a mod's
        // traits:set(...) silently did nothing here (EffectChannels.setTrait).
        "zombie.characters.traits.CharacterTraits",
        // Weather reads (LuaManager.java:9661 exposes getClimateManager()):
        // rain/fog/snow intensity are plain reads of its ClimateFloats, so a
        // test sets them with PZEngine.setField on the float's finalValue.
        "zombie.iso.weather.ClimateManager",
        // Repairs by fixing script (guns, vehicle parts): vanilla ISFixAction
        // reads FixingManager.getFixes at :new and calls fixItem at complete
        // (the game exposes all four, LuaManager.java:2077, 2310-2312).
        "zombie.inventory.FixingManager",
        // Global ModData (LuaManager.java:2657 exposes the static facade as
        // the `ModData` global): world-saved tables keyed by name. In memory
        // here (GlobalModData.instance, no save to disk); absent, a mod's
        // ModData.getOrCreate died on a nil global.
        "zombie.world.moddata.ModData",
        "zombie.scripting.objects.Fixing$Fixer",
        "zombie.scripting.objects.Fixing$FixerSkill",
        // The AI states vanilla ISTimedActionQueue indexes at file load
        // (STATES[ClimbThroughWindowState.instance()] = true; LuaManager.java
        // :1741-1750): unexposed, the queue -- and every timed action an MP
        // client side queues -- fails to load.
        "zombie.ai.states.ClimbThroughWindowState",
        "zombie.ai.states.ClimbOverFenceState",
        "zombie.ai.states.ClimbOverWallState",
        "zombie.ai.states.ClimbSheetRopeState",
        "zombie.ai.states.ClimbDownSheetRopeState",
        "zombie.ai.states.CloseWindowState",
        "zombie.ai.states.OpenWindowState",
        // JOML vectors (LuaManager.java:1720-1721): vanilla builds them at
        // file load (ISVehicleMenu: local SORTVARS = { pos = Vector3f.new() }).
        "org.joml.Vector2f",
        "org.joml.Vector3f",
        "zombie.entity.components.crafting.recipe.HandcraftLogic",
        "zombie.entity.components.crafting.recipe.CraftRecipeData",
        // A bench's recipe list is CraftRecipeManager.queryRecipes(its
        // Recipes string); the game exposes it to Lua (the debug recipe
        // panels use it). Its results, and CraftRecipe.getTags(), are
        // PZUnmodifiableList, unindexable from Lua until exposed.
        "zombie.entity.components.crafting.recipe.CraftRecipeManager",
        "zombie.util.list.PZUnmodifiableList",
        "zombie.entity.components.crafting.CraftRecipeMonitor",
        "zombie.scripting.entity.components.crafting.CraftRecipe",
        "zombie.scripting.entity.components.crafting.InputScript",
        "zombie.scripting.entity.components.crafting.CraftRecipe$RequiredSkill",
        "zombie.scripting.objects.CharacterTrait",
        "zombie.util.list.PZArrayList",
        "zombie.iso.objects.IsoDeadBody",
        "zombie.network.id.ObjectIDType",
        "zombie.inventory.ItemPickerJava",
        "zombie.GameTime",
        "zombie.SandboxOptions",
        "zombie.SandboxOptions$IntegerSandboxOption",
        "zombie.SandboxOptions$DoubleSandboxOption",
        "zombie.SandboxOptions$BooleanSandboxOption",
        "zombie.SandboxOptions$StringSandboxOption",
        "zombie.SandboxOptions$EnumSandboxOption",
        "zombie.iso.IsoGridSquare",
        "zombie.iso.IsoCell",
        "zombie.iso.IsoMovingObject",
        "zombie.iso.IsoObject",
        "zombie.iso.objects.IsoWorldInventoryObject",
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
        // Vanilla recipe/item Lua hooks. In 42.21 OnCreate/OnTest names like
        // RecipeCodeOnCreate.smeltIronOrSteelLarge resolve to static methods
        // on these classes, which the game exposes (LuaManager.java:1960-1965).
        // Unexposed, every vanilla hook silently no-ops offline: a smelted
        // crucible came out full (20 uses) instead of +4.
        "zombie.scripting.logic.RecipeCodeOnCreate",
        "zombie.scripting.logic.RecipeCodeOnTest",
        "zombie.scripting.logic.RecipeCodeOnCooked",
        "zombie.scripting.logic.RecipeCodeOnEat",
        "zombie.scripting.logic.ItemCodeOnCreate",
        "zombie.scripting.logic.ItemCodeOnTest",
        // Skills, as LuaManager.java:1798-1800 exposes them: vanilla timed
        // actions read Perks.Reloading etc. (ISInsertMagazine's start and
        // reload XP); without them every such action dies in start().
        "zombie.characters.skills.PerkFactory",
        "zombie.characters.skills.PerkFactory$Perk",
        "zombie.characters.skills.PerkFactory$Perks",
        // A character's XP ledger (LuaManager.java:1823): player:getXp()
        // returns it, and getXP / getPerkBoost live on it.
        "zombie.characters.IsoGameCharacter$XP",
        // The body and its stats (LuaManager.java:1785-1787, 1806-1807):
        // fractures, wounds and infection live on BodyPart; sickness is a
        // CharacterStat read through Stats.get (B42).
        "zombie.characters.BodyDamage.BodyPartType",
        "zombie.characters.BodyDamage.BodyPart",
        "zombie.characters.BodyDamage.BodyDamage",
        "zombie.characters.Stats",
        "zombie.characters.CharacterStat",
        // Action animation names (LuaManager.java:1836): vanilla timed
        // actions call setActionAnim(CharacterActionAnims.Reload) in start().
        "zombie.characters.CharacterActionAnims",
        // Moodles (LuaManager.java:1796-1797, 2271): ISReloadWeaponAction.
        // setReloadSpeed reads getMoodleLevel(MoodleType.PANIC) in start().
        "zombie.characters.Moodles.Moodle",
        "zombie.characters.Moodles.Moodles",
        // Real body locations (LuaManager.java:1959). mock_environment's
        // string registry stands in for non-engine suites; in engine mode the
        // real class must win, or vanilla getWornItem(ItemBodyLocation.X)
        // gets a String ("expected argument of type ItemBodyLocation").
        "zombie.scripting.objects.ItemBodyLocation",
        "zombie.scripting.objects.ItemTag",   // same story (LuaManager.java:2270)
        // Ammo (LuaManager.java:2267): magazine:getAmmoType() returns one,
        // and ISLoadBulletsInMagazine calls :getItemKey() on it.
        "zombie.scripting.objects.AmmoType",
        "zombie.scripting.objects.MoodleType",
        // Script objects (LuaManager.java:1852, 2202, 2305-2349, 2443): the
        // ScriptManager getAll*() lists hand these back; unexposed, Lua can
        // hold them but not call getScriptObjectName() on them.
        "zombie.core.skinnedmodel.runtime.RuntimeAnimationScript",
        "zombie.iso.SpriteModel",
        "zombie.scripting.itemConfig.ItemConfig",
        "zombie.scripting.objects.AnimationsMesh",
        "zombie.scripting.objects.EnergyDefinitionScript",
        "zombie.scripting.objects.EvolvedRecipe",
        "zombie.scripting.objects.Fixing",
        "zombie.scripting.objects.FluidDefinitionScript",
        "zombie.scripting.objects.FluidFilterScript",
        "zombie.scripting.objects.GameSoundScript",
        "zombie.scripting.objects.ItemFilterScript",
        "zombie.scripting.objects.MannequinScript",
        "zombie.scripting.objects.ModelScript",
        "zombie.scripting.objects.PhysicsShapeScript",
        "zombie.scripting.objects.SoundTimelineScript",
        "zombie.scripting.objects.StringListScript",
        "zombie.scripting.objects.TimedActionScript",
        "zombie.scripting.objects.VehicleScript",
        "zombie.scripting.objects.VehicleTemplate",
        "zombie.scripting.objects.XuiColorsScript",
        "zombie.scripting.objects.XuiConfigScript",
        "zombie.scripting.objects.XuiLayoutScript",
        "zombie.scripting.objects.XuiSkinScript",
        "zombie.vehicles.VehicleEngineRPM",
        // Vehicles as the game exposes them (LuaManager.java:2437, :2445): a
        // BaseVehicle built from its script has its parts and their
        // containers (trunk, glovebox, seats) without entering the physics
        // world -- enough for every container rule (hasRoomFor's empty-seat
        // exemption, ItemContainer.java:243-247; TransactionManager's
        // vehicle branches).
        "zombie.vehicles.BaseVehicle",
        "zombie.vehicles.VehiclePart",
        // Its parts are built by the private createParts() when a vehicle
        // enters the world; VehicleParts.createParts()/initParts() (public,
        // via getParts()) do the same without physics.
        "zombie.vehicles.VehicleParts",
        // Entities (LuaManager.java:1885-1889, 1940): workstation crafts build an
        // IsoObject entity from its script and hand HandcraftLogic its CraftBench.
        "zombie.entity.ComponentType",
        "zombie.entity.GameEntity",
        "zombie.entity.GameEntityFactory",
        "zombie.entity.components.crafting.CraftBench",
        // The world (LuaManager.java setExposed, zombie.iso.*): what a real map
        // square holds after PZEngine.loadCell -- object classes, sprites and
        // their properties, rooms, buildings, zones. Data classes only: the
        // renderer-side ones (camera, FBO, fog, puddles) would run GL statics.
        "zombie.core.properties.PropertyContainer",
        "zombie.core.properties.IsoPropertyType",
        "zombie.core.properties.IsoObjectChange",
        "zombie.iso.BuildingDef",
        "zombie.iso.RoomDef",
        "zombie.iso.IsoDirections",
        "zombie.iso.IsoMetaGrid",
        "zombie.iso.IsoMetaChunk",
        "zombie.iso.MetaObject",
        "zombie.iso.Vector2",
        "zombie.iso.Vector3",
        "zombie.iso.IsoHeatSource",
        "zombie.iso.IsoLightSource",
        "zombie.iso.BentFences",
        "zombie.iso.BrokenFences",
        "zombie.iso.IsoButcherHook",
        "zombie.iso.SpriteDetails.IsoObjectType",
        "zombie.iso.areas.IsoBuilding",
        "zombie.iso.areas.IsoRoom",
        "zombie.iso.areas.SafeHouse",
        "zombie.iso.areas.NonPvpZone",
        "zombie.iso.areas.DesignationZone",
        "zombie.iso.areas.DesignationZoneAnimal",
        "zombie.iso.areas.isoregion.regions.IsoWorldRegion",
        "zombie.iso.areas.isoregion.regions.IsoChunkRegion",
        "zombie.iso.objects.GridSquareEdge",
        "zombie.iso.objects.GridSquareEdgeFacingDirection",
        "zombie.iso.objects.IsoAnimalTrack",
        "zombie.iso.objects.IsoBarbecue",
        "zombie.iso.objects.IsoBarricade",
        "zombie.iso.objects.IsoBrokenGlass",
        "zombie.iso.objects.IsoCarBatteryCharger",
        "zombie.iso.objects.IsoClothingDryer",
        "zombie.iso.objects.IsoClothingWasher",
        "zombie.iso.objects.IsoCombinationWasherDryer",
        "zombie.iso.objects.IsoCompost",
        "zombie.iso.objects.IsoCurtain",
        "zombie.iso.objects.IsoDoor",
        "zombie.iso.objects.IsoFeedingTrough",
        "zombie.iso.objects.IsoFire",
        "zombie.iso.objects.IsoFireManager",
        "zombie.iso.objects.IsoFireplace",
        "zombie.iso.objects.IsoGenerator",
        "zombie.iso.objects.IsoHutch",
        "zombie.iso.objects.IsoJukebox",
        "zombie.iso.objects.IsoLightSwitch",
        "zombie.iso.objects.IsoMannequin",
        "zombie.iso.objects.IsoRadio",
        "zombie.iso.objects.IsoStackedWasherDryer",
        "zombie.iso.objects.IsoStove",
        "zombie.iso.objects.IsoTelevision",
        "zombie.iso.objects.IsoThumpable",
        "zombie.iso.objects.IsoTrap",
        "zombie.iso.objects.IsoTree",
        "zombie.iso.objects.IsoWaveSignal",
        // Recorded media (LuaManager.java setExposed + the getZomboidRadio
        // global): the tape registry vanilla ISRecordedMedia.init fills from
        // RecMedia, its lines, and the device a TV/radio plays them on.
        "zombie.radio.ZomboidRadio",
        "zombie.radio.media.RecordedMedia",
        "zombie.radio.media.MediaData",
        "zombie.radio.media.MediaData$MediaLineData",
        "zombie.radio.devices.DeviceData",
        "zombie.inventory.types.Radio",
        "zombie.iso.objects.IsoWheelieBin",
        "zombie.iso.objects.IsoWindow",
        "zombie.iso.objects.IsoWindowFrame",
        "zombie.iso.objects.interfaces.BarricadeAble",
        "zombie.iso.sprite.IsoSpriteGrid",
        "zombie.iso.sprite.IsoSpriteInstance",
        "zombie.iso.zones.Zone",
        "zombie.iso.zones.VehicleZone",
        "zombie.iso.zones.Trigger",
        "zombie.iso.sprite.IsoSprite",
        "zombie.iso.sprite.IsoSpriteManager",
        "zombie.iso.IsoWorld",
        "zombie.iso.IsoChunk",
        "zombie.iso.SpriteDetails.IsoFlagType",
        // The collections PZ itself exposes (LuaManager.java:1703-1712);
        // getInputs()/getAllItems() etc. hand these back and Lua calls
        // :size()/:get() on them. Only ArrayList and HashMap were here, so
        // vanilla ISFixAction died on Fixing.getFixers() (a LinkedList).
        "java.util.ArrayList",
        "java.util.List",
        "java.util.EnumMap",
        "java.util.HashMap",
        "java.util.HashSet",
        "java.util.LinkedHashMap",
        "java.util.LinkedList",
        "java.util.Stack",
        "java.util.Vector",
        "java.util.Iterator",
    };

    public static boolean isBooted() { return booted; }
    public static String getBootError() { return bootError; }

    /** Find the PZ install via the shared locator (override → env →
     *  Steam registry/libraryfolders.vdf/appmanifest → legacy guesses).
     *  The engine's validity bar is the game jar itself. */
    public static Path findPzInstall(String override) {
        return PzLocator.find(override, p -> Files.exists(p.resolve("projectzomboid.jar")));
    }

    /**
     * Boot once per process. Safe to call repeatedly; only the first call
     * does work. Returns whether the engine is available afterwards.
     */
    public static synchronized boolean boot(String pzDirOverride, Path modRoot, PrintStream log) {
        return boot(pzDirOverride, modRoot, List.of(), log);
    }

    /** Mod ids whose scripts were parsed (engine_mods entries + the mod under test). */
    private static final Set<String> loadedModIds = new LinkedHashSet<>();
    public static boolean isModLoaded(String id) { return loadedModIds.contains(id); }

    /**
     * Boot, additionally parsing the scripts of each {@code engine_mods}
     * entry (after vanilla, before the mod under test — the order a server's
     * mod list would load them in when the mod under test comes last).
     * An entry is either a path (relative to the mod root, or absolute) or
     * {@code workshop:<itemId>/<modFolder>}, resolved against the Steam
     * Workshop dir next to the PZ install (override: PZ_WORKSHOP_DIR).
     * Missing entries are logged and skipped, never fatal: a machine without
     * that Workshop item still boots, and suites guard on
     * {@code PZEngine.modLoaded(id)}.
     */
    public static synchronized boolean boot(String pzDirOverride, Path modRoot,
                                            List<String> extraMods, PrintStream log) {
        if (bootAttempted) return booted;
        pendingExtraMods = extraMods == null ? List.of() : List.copyOf(extraMods);
        bootAttempted = true;
        long t0 = System.currentTimeMillis();

        Path pzDir = findPzInstall(pzDirOverride);
        if (pzDir == null) {
            bootError = "no PZ install found (set PZ_INSTALL_DIR); engine tests will report unavailable";
            log.println("[engine] " + bootError);
            return false;
        }

        pzInstallDir = pzDir;
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

            // The Zomboid home dir, pointed at a scratch dir so the harness
            // never reads the developer's real one. 42.20 and earlier took the
            // local-mods folder from Core.getMyDocumentFolder(), which the Core
            // stub already redirected here; 42.21 takes it from
            // ZomboidFileSystem.getCacheDirSub("mods") instead (and mkdirs it),
            // so the stub stopped covering it and getAllModFolders walked the
            // REAL ~/Zomboid/mods — every mod the developer had deployed, on a
            // machine-dependent code path. setCacheDir puts it back.
            // Asked of the stub by reflection, like every other PZ class here,
            // so the scratch location stays defined in exactly one place.
            String zomboidHome = (String) cls("zombie.core.Core")
                .getMethod("getMyDocumentFolder").invoke(null);
            zfsClass.getMethod("setCacheDir", String.class).invoke(zfs, zomboidHome);
            log.println("[engine] Zomboid home -> " + zomboidHome);

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
                // The engine reads a few Lua globals from Java through this env.
                // CraftRecipeManager.itemGetQueuedAmount rawgets
                // ISTimedActionQueue.queues on every test-only input check; absent,
                // each canPerform / setManualInputsFor NPEs and reads as false.
                // Seed an empty queue (vanilla ISTimedActionQueue.lua:7). Keep the
                // env scratch: LuaEventManager.AddEvent registers unknown events
                // into env.Events, which would clobber the kit's mock Events.
                KahluaTable taq = scratchPlatform.newTable();
                taq.rawset("queues", scratchPlatform.newTable());
                scratchEnv.rawset("ISTimedActionQueue", taq);
                cls("zombie.Lua.LuaManager").getField("env").set(null, scratchEnv);
                cls("zombie.Lua.LuaManager").getField("scriptThread").set(null, scratchThread);
                cls("zombie.ZomboidGlobals").getMethod("Load").invoke(null);
                log.println("[engine] ZomboidGlobals loaded from defines.lua");
                // The skill tree, as GameWindow.java:197 / GameServer.java:1421
                // build it at boot: AddPerk assigns every perk its parent
                // category and XP curve. Without it every perk's parent reads
                // None, so code that walks skills the way vanilla's own stats
                // panel does (ISPlayerStatsUI.lua:720 -- skip parent == None)
                // skips every real skill and sees nothing.
                try {
                    cls("zombie.characters.skills.PerkFactory").getMethod("init").invoke(null);
                    log.println("[engine] PerkFactory initialised (skill tree)");
                } catch (Throwable pt) {
                    Throwable r = pt; while (r.getCause() != null) r = r.getCause();
                    log.println("[engine] PerkFactory init FAILED: " + r);
                }
                // SandboxOptions.instance is built in its static init (defines
                // + the Apocalypse preset via LuaManager.RunLua). Force it now so
                // a failure is one boot-log line, not a silent nil deep inside
                // whichever engine call first touched it.
                try {
                    Class.forName("zombie.SandboxOptions", true, loader);
                    log.println("[engine] SandboxOptions initialised (Apocalypse preset)");
                } catch (Throwable st) {
                    Throwable r = st; while (r.getCause() != null) r = r.getCause();
                    log.println("[engine] SandboxOptions init FAILED: " + r);
                }
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

            // Collect every script file BY RELATIVE PATH first, then parse.
            // PZ resolves mod files by path: when two sources ship the same
            // media/scripts/<path> (case-insensitive), the LATER one replaces
            // the earlier file wholesale. Parsing both would build a
            // combination that cannot exist in game -- GaelGunStore's
            // ammo/9mm.txt replacing Modern Firearms' is exactly how a server
            // lost Base.9mmDrum_cat and refused to load the world.
            // ScriptManager.Load brackets script loading with
            // WorldDictionary.StartScriptLoading() ... ScriptsLoaded(); every
            // Item (a GameEntityScript) registers itself in between via
            // WorldDictionary.onLoadEntity. Without the bracket each one is
            // refused ("loaded after WorldDictionary is initialised"), no item
            // gets a registry id, and every item saves as id -1 -- so a saved
            // square loads back EMPTY (PZEngine.reloadSquare).
            cls("zombie.world.WorldDictionary").getMethod("StartScriptLoading").invoke(null);
            ScriptFiles collected = new ScriptFiles();
            collected.addTree(pzDir.resolve("media/scripts"), "pz-vanilla");
            for (String spec : pendingExtraMods) {
                List<Path> variants = resolveModSpec(pzDir, modRoot, spec);
                if (variants.isEmpty()) {
                    log.println("[engine] engine_mods: not found, skipping " + spec);
                    continue;
                }
                String id = null;
                for (Path v : variants) {
                    if (id == null && Files.exists(v.resolve("mod.info"))) id = modIdOf(v);
                }
                if (id == null) id = modIdOf(variants.get(0).getParent());
                int added = 0;
                for (Path v : variants) added += collected.addTree(v.resolve("media/scripts"), id);
                loadedModIds.add(id);
                log.println("[engine] engine_mods: " + id + " (" + added + " script files from "
                    + variants.stream().map(p -> p.getFileName().toString()).toList() + ")");
            }
            if (modRoot != null) {
                collected.addTree(modRoot.resolve("media/scripts"), modIdOf(modRoot));
                loadedModIds.add(modIdOf(modRoot));
            }
            for (String o : collected.overrides) log.println("[engine] override: " + o);
            int files = 0;
            for (ScriptFiles.Entry e : collected.byPath.values()) {
                files += parseFile(sm, parse, initMode, e.file(), e.modId(), ctx, log);
            }
            log.println("[engine] parsed " + files + " script files");
            // Kept for PZEngine.reloadScripts: the game's own reload re-reads
            // files through ZomboidFileSystem, which the harness never maps.
            bootCollected = collected; bootCtx = ctx; bootParse = parse; bootModRoot = modRoot;

            // The mod under test's sandbox options, through the engine's own
            // parser (CustomSandboxOptions.readFile) and registration
            // (initInstance -> SandboxOptions.newCustomOption), as a game load
            // does for every enabled mod. PZEngine.sandboxSet then sets values
            // through the real typed option, min/max enforced.
            if (modRoot != null) {
                try {
                    Path so = modRoot.resolve("media/sandbox-options.txt");
                    if (Files.exists(so)) {
                        Class<?> cso = cls("zombie.sandbox.CustomSandboxOptions");
                        Object csoInst = cso.getField("instance").get(null);
                        Method read = cso.getDeclaredMethod("readFile", String.class);
                        read.setAccessible(true);
                        read.invoke(csoInst, so.toString());
                        Object sbo = cls("zombie.SandboxOptions").getField("instance").get(null);
                        cso.getMethod("initInstance", cls("zombie.SandboxOptions")).invoke(csoInst, sbo);
                        log.println("[engine] sandbox options registered from " + modRoot.relativize(so));
                    }
                } catch (Throwable t) {
                    Throwable r = t; while (r.getCause() != null) r = r.getCause();
                    log.println("[engine] mod sandbox options skipped: " + r);
                }
            }

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
            cls("zombie.world.WorldDictionary").getMethod("ScriptsLoaded").invoke(null);

            // The step IsoWorld.init runs right after WorldDictionary.init:
            // recipes resolve their inputs/outputs (tags -> item lists, output
            // mappers) here. Without it every craftRecipe input matches ZERO
            // items, so no recipe can ever be performed offline -- found by the
            // character spike (GetLongStick: canUseItem(broom) false,
            // getPossibleInputItems() empty). ScriptManager catches per-
            // collection failures itself; a throw here is logged, never fatal.
            // WorldDictionary.init first, as IsoWorld.init orders them. Items
            // serialize as the registry ids it assigns, so it must exist
            // BEFORE any item is minted -- an item made earlier saves an id
            // the dictionary does not know, and is silently dropped when its
            // square is loaded back (PZEngine.reloadSquare).
            try {
                ensureWorldDictionary();
                log.println("[engine] WorldDictionary initialised (new game)");
            } catch (Throwable t) {
                Throwable root = t; while (root.getCause() != null) root = root.getCause();
                log.println("[engine] WorldDictionary init failed: " + root);
            }
            try {
                smClass.getMethod("PostWorldDictionaryInit").invoke(sm);
                log.println("[engine] PostWorldDictionaryInit done (recipe inputs/outputs resolved)");
            } catch (Throwable t) {
                Throwable root = t; while (root.getCause() != null) root = root.getCause();
                log.println("[engine] PostWorldDictionaryInit failed: " + root);
            }

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

    private static List<String> pendingExtraMods = List.of();

    /**
     * The directories whose media/ a mod actually loads from, B42 layout:
     * {@code common/} plus the NEWEST {@code 42*} version folder. A folder
     * with media/ directly (a flat or dev-layout mod) is its own single
     * variant. Empty when nothing resolves.
     */
    static List<Path> resolveModSpec(Path pzDir, Path modRoot, String spec) {
        Path dir;
        if (spec.startsWith("workshop:")) {
            String rest = spec.substring("workshop:".length());
            int slash = rest.indexOf('/');
            if (slash < 0) return List.of();
            String env = System.getenv("PZ_WORKSHOP_DIR");
            Path ws = env != null && !env.isBlank() ? Path.of(env)
                // <steamapps>/common/ProjectZomboid -> <steamapps>/workshop/content/108600
                : pzDir.getParent().getParent().resolve("workshop/content/108600");
            dir = ws.resolve(rest.substring(0, slash)).resolve("mods").resolve(rest.substring(slash + 1));
        } else {
            Path p = Path.of(spec);
            dir = p.isAbsolute() || modRoot == null ? p : modRoot.resolve(p);
        }
        if (!Files.isDirectory(dir)) return List.of();
        // Versioned folders WIN over a root media/: dual-build mods ship B41
        // content at the root next to common/ + 42/, and B42 loads only the
        // latter (Modern Firearms, GaelGunStore parsed 0 files before this).
        List<Path> out = new ArrayList<>();
        if (Files.isDirectory(dir.resolve("common"))) out.add(dir.resolve("common"));
        try (Stream<Path> kids = Files.list(dir)) {
            kids.filter(Files::isDirectory)
                .filter(p -> p.getFileName().toString().startsWith("42"))
                .max(Comparator.comparing(EngineBridge::versionKey))
                .ifPresent(out::add);
        } catch (Exception ignored) {}
        boolean versioned = out.stream().anyMatch(p -> !p.getFileName().toString().equals("common"));
        if (!versioned && Files.isDirectory(dir.resolve("media"))) return List.of(dir);
        return out;
    }

    /** "42.13" -> sortable key; non-numeric parts sort low. */
    private static String versionKey(Path p) {
        StringBuilder sb = new StringBuilder();
        for (String part : p.getFileName().toString().split("\\.")) {
            String digits = part.replaceAll("\\D", "");
            sb.append(String.format("%06d.", digits.isEmpty() ? 0 : Integer.parseInt(digits)));
        }
        return sb.toString();
    }

    /** Mod id from mod.info, falling back to the directory name. */
    static String modIdOf(Path modRoot) {
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

    /** media/scripts files keyed by lowercase relative path; later adds replace earlier ones. */
    private static final class ScriptFiles {
        record Entry(Path file, String modId) {}
        final java.util.LinkedHashMap<String, Entry> byPath = new java.util.LinkedHashMap<>();
        final List<String> overrides = new ArrayList<>();

        int addTree(Path scriptsDir, String modId) throws java.io.IOException {
            if (!Files.isDirectory(scriptsDir)) return 0;
            List<Path> files;
            try (Stream<Path> walk = Files.walk(scriptsDir)) {
                files = walk.filter(p -> p.toString().endsWith(".txt"))
                    .sorted(Comparator.comparing(p -> scriptsDir.relativize(p).toString().toLowerCase()))
                    .toList();
            }
            for (Path f : files) {
                String key = scriptsDir.relativize(f).toString().replace('\\', '/').toLowerCase();
                Entry prev = byPath.remove(key);
                if (prev != null && !prev.modId().equals(modId)) {
                    overrides.add(modId + " replaces " + prev.modId() + "'s media/scripts/" + key);
                }
                byPath.put(key, new Entry(f, modId));
            }
            return files.size();
        }
    }

    private static int parseFile(Object sm, Method parse, Object mode, Path f,
                                 String modId, FileContext ctx, PrintStream log) {
        try {
            String text = Files.readString(f);
            ctx.set(modId, f);
            // LoadFile strips block comments BEFORE ParseScript; skip it
            // and a /* header */ above `module Base` becomes part of the
            // module name and every definition in the file goes missing.
            text = zombie.scripting.ScriptParser.stripComments(text);
            parse.invoke(sm, mode, text);
            return 1;
        } catch (Throwable t) {
            Throwable root = t; while (root.getCause() != null) root = root.getCause();
            log.println("[engine] parse failed, skipping " + f.getFileName() + " (" + modId + "): " + root);
            return 0;
        }
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
        // Performance (PZTestKit.Perf). nanoTime: a monotonic clock in
        // nanoseconds, as a double (exact to 2^53 ns, ~104 days of uptime).
        // memUsed: heap in use (bytes); gc: a collection request, so a
        // measurement starts from a settled heap. Coarse by nature: the JVM
        // decides when to collect, so allocation numbers are estimates.
        pzEngine.rawset("nanoTime", (JavaFunction) (frame, n) -> { frame.push((double) System.nanoTime()); return 1; });
        pzEngine.rawset("memUsed", (JavaFunction) (frame, n) -> {
            Runtime rt = Runtime.getRuntime();
            frame.push((double) (rt.totalMemory() - rt.freeMemory()));
            return 1;
        });
        pzEngine.rawset("gc", (JavaFunction) (frame, n) -> { System.gc(); return 0; });
        pzEngine.rawset("bootError", (JavaFunction) (frame, n) -> { frame.push(bootError); return 1; });
        // The Lua thread engine code uses to call back into Lua and to print Lua
        // stacks (KahluaThread.doStacktraceProper via UIManager.defaultthread).
        // Null, the first Java->Lua error on a crafting path NPE'd inside the
        // error reporter itself. Each test file has its own thread; point the
        // engine at the current one.
        if (booted) {
            try {
                cls("zombie.ui.UIManager").getField("defaultthread").set(null, thread);
            } catch (Throwable t) {
                log.println("[engine] could not set UIManager.defaultthread: " + t);
            }
        }
        pzEngine.rawset("newSquare", (JavaFunction) (frame, n) -> {
            int x = n > 0 && frame.get(0) instanceof Double d0 ? d0.intValue() : 100;
            int y = n > 1 && frame.get(1) instanceof Double d1 ? d1.intValue() : 100;
            int z = n > 2 && frame.get(2) instanceof Double d2 ? d2.intValue() : 0;
            Object[] r = newSquare(x, y, z);
            frame.push(r[0]);
            frame.push(r[1]);
            return 2;
        });
        // GameServer.server gates the engine's render-side work (sprites,
        // textures) the harness has no GPU for -- a dedicated server takes
        // exactly the headless branch. Flip it around world mutations.
        pzEngine.rawset("setServer", (JavaFunction) (frame, n) -> {
            try {
                java.lang.reflect.Field f = cls("zombie.network.GameServer").getField("server");
                boolean prev = f.getBoolean(null);
                boolean on = n > 0 && Boolean.TRUE.equals(frame.get(0));
                f.setBoolean(null, on);
                if (on) ensureServerNetwork();
                frame.push(prev);
            } catch (Throwable t) { frame.push(null); }
            return 1;
        });
        // The real IsoCell the harness squares live in (nil until the first
        // newSquare). The global getCell() stays the kit's mock -- most suites
        // are written against it -- so a test that wants the engine's own
        // square lookup swaps it in: getCell = PZEngine.cell, then restores.
        // SpriteConfigManager.InitScriptsPostTileDef: the game runs it after
        // tile definitions load (ScriptManager.java:366). Without it no
        // SpriteConfig resolves, so isMultiSquareMaster() is false and an
        // entity built on a tile gets no CraftBench/UiConfig (master-only
        // components). The harness loads no tiles, so the sprite-property
        // stamping step logs a missing-sprite error per entity; the object
        // infos it needs are registered before that check. On demand only,
        // so ordinary suites never pay for (or log) it. Returns the count.
        pzEngine.rawset("initSpriteConfigs", (JavaFunction) (frame, n) -> {
            try {
                Class<?> scm = cls("zombie.entity.components.spriteconfig.SpriteConfigManager");
                scm.getMethod("InitScriptsPostTileDef").invoke(null);
                // It creates any sprite it names (IsoSpriteManager.getSprite ->
                // AddSprite), but only the tile loader sets IsoSprite.name, and
                // SpriteConfig finds its tile BY that name. Name them after
                // their key so a tile object resolves as the master.
                Class<?> ism = cls("zombie.iso.sprite.IsoSpriteManager");
                Object mgr = ism.getField("instance").get(null);
                java.lang.reflect.Field nm = ism.getDeclaredField("namedMap");
                nm.setAccessible(true);
                java.lang.reflect.Field nameF = cls("zombie.iso.sprite.IsoSprite").getField("name");
                for (Object o : ((java.util.Map<?, ?>) nm.get(mgr)).entrySet()) {
                    java.util.Map.Entry<?, ?> en = (java.util.Map.Entry<?, ?>) o;
                    if (en.getValue() != null && nameF.get(en.getValue()) == null) nameF.set(en.getValue(), String.valueOf(en.getKey()));
                }
                java.lang.reflect.Field f = scm.getDeclaredField("objectInfosList");
                f.setAccessible(true);
                frame.push((double) ((java.util.List<?>) f.get(null)).size());
            } catch (Throwable t) {
                Throwable r = t; while (r.getCause() != null) r = r.getCause();
                frame.push(null);
                frame.push(String.valueOf(r));
                return 2;
            }
            return 1;
        });
        // Script types the boot leaves out (the ALLOWLIST above), on demand:
        // every file was already PARSED at boot, so their buckets hold the
        // blocks; this runs the load pass boot skipped for them
        // (ScriptManager.loadScripts(Init, types)). For tests that need, e.g.,
        // real vehicles: loadScriptTypes("VehicleTemplate,Vehicle"), then
        // BaseVehicle.new(cell):setScriptName/setScript + getParts():
        // createParts(). Returns (ms) or (nil, error).
        pzEngine.rawset("loadScriptTypes", (JavaFunction) (frame, n) -> {
            try {
                long t0 = System.currentTimeMillis();
                Class<?> stC = cls("zombie.scripting.ScriptType");
                java.util.EnumSet set = java.util.EnumSet.noneOf((Class) stC);
                for (String t : String.valueOf(frame.get(0)).split(",")) {
                    if (t.isBlank()) continue;
                    set.add(Enum.valueOf((Class) stC, t.trim()));
                }
                Class<?> smC = cls("zombie.scripting.ScriptManager");
                Object sm = smC.getField("instance").get(null);
                Class<?> modeC = cls("zombie.scripting.ScriptLoadMode");
                Method load = smC.getDeclaredMethod("loadScripts", modeC, java.util.EnumSet.class);
                load.setAccessible(true);
                // Loaded the way a dedicated server loads them: VehicleScript.Loaded
                // hands every vehicle's shape to the Bullet natives unless
                // GameServer.server (VehicleScript.java:538-540), and headless has
                // no natives (UnsatisfiedLinkError: Bullet.defineVehicleScript).
                java.lang.reflect.Field srv = cls("zombie.network.GameServer").getField("server");
                boolean wasServer = srv.getBoolean(null);
                srv.setBoolean(null, true);
                try {
                    load.invoke(sm, enumConst(modeC, "Init"), set);
                } finally {
                    srv.setBoolean(null, wasServer);
                }
                frame.push((double) (System.currentTimeMillis() - t0));
            } catch (Throwable t) {
                frame.push(null);
                frame.push(describe(t));
                return 2;
            }
            return 1;
        });
        // The game's debug script reload (ScriptManager.ReloadScripts): clear the
        // named buckets (PreReloadScripts), re-read every script file from disk,
        // run the post-load passes -- an edited craftRecipe/item/entity is picked
        // up WITHOUT the append-on-redefine doubling a plain LoadFile would give.
        // Arg: comma-separated ScriptType names. Returns (ms, hadErrors) or (nil, error).
        pzEngine.rawset("reloadScripts", (JavaFunction) (frame, n) -> {
            try {
                Class<?> stC = cls("zombie.scripting.ScriptType");
                java.util.EnumSet set = java.util.EnumSet.noneOf((Class) stC);
                for (String t : String.valueOf(frame.get(0)).split(",")) {
                    if (t.isBlank()) continue;
                    set.add(Enum.valueOf((Class) stC, t.trim()));
                }
                Class<?> smC = cls("zombie.scripting.ScriptManager");
                Object sm = smC.getField("instance").get(null);
                java.lang.reflect.Field errs = smC.getDeclaredField("hasLoadErrors");
                errs.setAccessible(true);
                errs.setBoolean(sm, false);
                frame.push(reloadScriptTypes(set));
                frame.push(errs.getBoolean(sm));
            } catch (Throwable t) {
                frame.push(null);
                frame.push(describe(t));
            }
            return 2;
        });
        pzEngine.rawset("cell", (JavaFunction) (frame, n) -> { frame.push(harnessCell); return 1; });
        // The real world, opt-in (see loadWorld/loadCell): returns (summary) or (nil, error).
        pzEngine.rawset("loadWorld", (JavaFunction) (frame, n) -> {
            Object[] r = loadWorld(n > 0 && frame.get(0) instanceof String s0 ? s0 : null);
            frame.push(r[0]); frame.push(r[1]); return 2;
        });
        pzEngine.rawset("loadCell", (JavaFunction) (frame, n) -> {
            int[] a = new int[] { 0, 0, 0, 0, 31, 31 };
            for (int i = 0; i < Math.min(n, 6); i++) if (frame.get(i) instanceof Double d) a[i] = d.intValue();
            Object[] r = loadCell(a[0], a[1], a[2], a[3], a[4], a[5]);
            frame.push(r[0]); frame.push(r[1]); return 2;
        });
        // Set a sandbox option through the engine's typed option and return
        // what the engine kept: an out-of-range value is refused and the old
        // one stays (IntegerConfigOption.setValue). nil if no such option.
        pzEngine.rawset("sandboxSet", (JavaFunction) (frame, n) -> {
            try {
                Object sbo = cls("zombie.SandboxOptions").getField("instance").get(null);
                Object opt = sbo.getClass().getMethod("getOptionByName", String.class).invoke(sbo, (String) frame.get(0));
                if (opt == null) { frame.push(null); return 1; }
                Object cfg = opt.getClass().getMethod("asConfigOption").invoke(opt);
                java.lang.reflect.Method set = cfg.getClass().getMethod("setValueFromObject", Object.class);
                Object v = frame.get(1);
                set.invoke(cfg, v);
                Object got = cfg.getClass().getMethod("getValueAsObject").invoke(cfg);
                frame.push(got instanceof Integer i ? (Object) i.doubleValue() : got);
            } catch (Throwable t) { frame.push(null); }
            return 1;
        });
        // Change sandbox options the way a running game does: an admin's edit
        // reaches the server through GameServer.receiveSandboxOptions (load +
        // applySettings + toLua) and fires NO Lua event -- the mid-run class of
        // bug (VPS affix gates going stale, 2026-10-05). Sets every option in
        // the table through its typed option (out-of-range values are refused,
        // the old one stays), runs the engine's applySettings(), and mirrors
        // what the engine KEPT into the Lua SandboxVars (the kit's SandboxVars
        // is its own table, so the engine's toLua() -- which would replace it
        // wholesale and drop pz-test.lua's values -- is not called).
        // Keys: "Mod.Option" (SandboxVars.Mod.Option) or "Option" (top level).
        // Returns { [key] = kept value }; an unknown key maps to false.
        pzEngine.rawset("sandboxApply", (JavaFunction) (frame, n) -> {
            KahluaTable out = platform.newTable();
            try {
                Object in = n > 0 ? frame.get(0) : null;
                if (!(in instanceof KahluaTable)) { frame.push(out); return 1; }
                Object sbo = cls("zombie.SandboxOptions").getField("instance").get(null);
                java.lang.reflect.Method byName = sbo.getClass().getMethod("getOptionByName", String.class);
                Object sv = env.rawget("SandboxVars");
                if (!(sv instanceof KahluaTable)) { sv = platform.newTable(); env.rawset("SandboxVars", sv); }
                se.krka.kahlua.vm.KahluaTableIterator it = ((KahluaTable) in).iterator();
                while (it.advance()) {
                    if (!(it.getKey() instanceof String)) continue;
                    String key = (String) it.getKey();
                    Object opt = byName.invoke(sbo, key);
                    if (opt == null) { out.rawset(key, Boolean.FALSE); continue; }
                    Object cfg = opt.getClass().getMethod("asConfigOption").invoke(opt);
                    cfg.getClass().getMethod("setValueFromObject", Object.class).invoke(cfg, it.getValue());
                    Object got = cfg.getClass().getMethod("getValueAsObject").invoke(cfg);
                    if (got instanceof Integer i) got = i.doubleValue();
                    out.rawset(key, got);
                    int dot = key.indexOf('.');
                    KahluaTable page = (KahluaTable) sv;
                    String field = key;
                    if (dot > 0) {
                        Object p = page.rawget(key.substring(0, dot));
                        if (!(p instanceof KahluaTable)) { p = platform.newTable(); page.rawset(key.substring(0, dot), p); }
                        page = (KahluaTable) p;
                        field = key.substring(dot + 1);
                    }
                    page.rawset(field, got);
                }
                sbo.getClass().getMethod("applySettings").invoke(sbo);
            } catch (Throwable t) {
                log.println("[engine] sandboxApply: " + t);
            }
            frame.push(out);
            return 1;
        });
        pzEngine.rawset("gameTime", (JavaFunction) (frame, n) -> {
            try { frame.push(cls("zombie.GameTime").getField("instance").get(null)); }
            catch (Throwable t) { frame.push(null); }
            return 1;
        });
        // Vanilla's corpse rot ticker, with any exception RETURNED. Called
        // straight from Lua, an exception inside it came back as a silent
        // success while aborting the loop for every body after the bad one --
        // a test then "proves" a body that was never even visited survives.
        pzEngine.rawset("updateBodies", (JavaFunction) (frame, n) -> {
            try { cls("zombie.iso.objects.IsoDeadBody").getMethod("updateBodies").invoke(null); frame.push(null); }
            catch (Throwable t) {
                Throwable r = t; while (r.getCause() != null) r = r.getCause();
                StringBuilder sb = new StringBuilder(r.toString());
                for (StackTraceElement el : r.getStackTrace())
                    if (el.getClassName().startsWith("zombie.")) { sb.append(" @ ").append(el); break; }
                frame.push(sb.toString());
            }
            return 1;
        });
        pzEngine.rawset("newCorpse", (JavaFunction) (frame, n) -> {
            Object[] r = newCorpse(frame.get(0), n > 1 && Boolean.TRUE.equals(frame.get(1)));
            frame.push(r[0]); frame.push(r[1]);
            return 2;
        });
        // Save a square to bytes and load it into a fresh square at the same
        // coordinates -- what a chunk unload + reload does to it. Vanilla's
        // own IsoGridSquare.load runs, including the world-item cleanup filter
        // (WorldItemRemovalList / HoursForWorldItemRemoval vs
        // isIgnoreRemoveSandbox). Returns the NEW square (the old one is
        // detached from the chunk), or nil, err. Items on it are new objects
        // with the same ids.
        pzEngine.rawset("reloadSquare", (JavaFunction) (frame, n) -> {
            Object[] r = reloadSquare(frame.get(0));
            frame.push(r[0]); frame.push(r[1]);
            return 2;
        });
        // Where a Lua function was defined: (file, line) from its prototype --
        // Kahlua has no debug library. The event lab names each listener so.
        pzEngine.rawset("fnInfo", (JavaFunction) (frame, n) -> {
            Object f = n > 0 ? frame.get(0) : null;
            if (f instanceof se.krka.kahlua.vm.LuaClosure c && c.prototype != null) {
                se.krka.kahlua.vm.Prototype p = c.prototype;
                frame.push(p.filename != null ? p.filename : p.name);
                frame.push(p.lines != null && p.lines.length > 0 ? (Object) Double.valueOf(p.lines[0]) : null);
                return 2;
            }
            frame.push(f == null ? null : f.getClass().getSimpleName());
            return 1;
        });
        pzEngine.rawset("newZombie", (JavaFunction) (frame, n) -> {
            Object[] r = newZombie(n > 0 ? frame.get(0) : null);
            frame.push(r[0]); frame.push(r[1]);
            return 2;
        });
        pzEngine.rawset("newPlayer", (JavaFunction) (frame, n) -> {
            Object[] r = newPlayer();
            frame.push(r[0]);
            frame.push(r[1]);
            return 2;
        });
        // Run one vanilla Lua file (path under media/lua, no .lua) in this
        // env, on demand. vanilla_requires loads files for EVERY test file;
        // this is for a test that wants the real class without replacing the
        // mock the rest of the suite was written against -- it can save the
        // global, load, take what it needs, and restore. Returns ok, err.
        pzEngine.rawset("loadVanilla", (JavaFunction) (frame, n) -> {
            Object entry = n > 0 ? frame.get(0) : null;
            if (pzInstallDir == null || !(entry instanceof String e)) {
                frame.push(false); frame.push("no PZ install or bad path"); return 2;
            }
            try {
                Path f = pzInstallDir.resolve("media/lua").resolve(e + ".lua");
                se.krka.kahlua.vm.LuaClosure c = se.krka.kahlua.luaj.compiler.LuaCompiler
                    .loadstring(Files.readString(f), "vanilla:" + e, env);
                Object[] res = thread.pcall(c, new Object[0]);
                if (res != null && res.length >= 1 && Boolean.FALSE.equals(res[0])) {
                    frame.push(false); frame.push(res.length >= 2 ? String.valueOf(res[1]) : "error"); return 2;
                }
                frame.push(true); return 1;
            } catch (Exception ex) {
                frame.push(false); frame.push(String.valueOf(ex)); return 2;
            }
        });
        // Core.debug gates the engine's own diagnostics -- CraftRecipeMonitor
        // only records with it on (CraftRecipeMonitor.canLog). Flip it around
        // a single call to ask the engine WHY a craft refused; leaving it on
        // changes behaviour (debug-only throws), so restore it after.
        pzEngine.rawset("setCoreDebug", (JavaFunction) (frame, n) -> {
            try {
                java.lang.reflect.Field f = cls("zombie.core.Core").getField("debug");
                boolean prev = f.getBoolean(null);
                f.setBoolean(null, n > 0 && Boolean.TRUE.equals(frame.get(0)));
                frame.push(prev);
            } catch (Throwable t) { frame.push(null); }
            return 1;
        });
        pzEngine.rawset("modLoaded", (JavaFunction) (frame, n) -> {
            Object id = n > 0 ? frame.get(0) : null;
            frame.push(booted && id instanceof String s && loadedModIds.contains(s));
            return 1;
        });
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

            // Engine -> Lua calls (recipe OnCreate/OnTest/OnStart hooks) go
            // through LuaManager.caller on LuaManager.thread, looking the
            // function up with LuaManager.getFunctionObject. Point all three at
            // THIS test file's thread and env. LuaManager.thread is otherwise
            // read only behind Core.debug (KahluaThread/KahluaUtil/Coroutine)
            // or for debug local-var tracking (LuaCallFrame), so a non-null
            // value changes nothing else.
            try {
                Class<?> lm = cls("zombie.Lua.LuaManager");
                se.krka.kahlua.integration.LuaCaller caller = new se.krka.kahlua.integration.LuaCaller(manager);
                lm.getField("caller").set(null, caller);
                lm.getField("debugcaller").set(null, caller);
                lm.getField("thread").set(null, thread);
                // Core.debug-only engine paths hand LuaManager.debugthread to
                // the caller; left null, flipping Core.debug (PZEngine.
                // setCoreDebug, e.g. for CraftRecipeMonitor) turned a craft
                // with xpAward into an NPE mid-craft, after inputs were
                // consumed. The interactive debugger stays off headless
                // (UIManager.showLuaDebuggerOnError is only set by GameWindow).
                lm.getField("debugthread").set(null, thread);
                lm.getField("functionEnv").set(null, env);
            } catch (Throwable t) {
                log.println("[engine] could not wire LuaManager caller: " + t);
            }

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
            // A kit mock registry (mock_environment's _pz_open_registry,
            // e.g. ItemBodyLocation) must not shadow the real class: the
            // exposer fills the EXISTING global table, so the mock's __index
            // would keep answering with strings. Drop marked mocks first.
            for (Class<?> c : classes) {
                String simple = c.getSimpleName();
                Object cur = env.rawget(simple);
                if (cur instanceof KahluaTable kt && kt.getMetatable() != null
                        && kt.getMetatable().rawget("__pz_open_registry") != null) {
                    env.rawset(simple, null);
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
            // The game's global (LuaManager.java:9661). The mock world's
            // getClimateManager stays for non-engine tests; this is the real one.
            env.rawset("getClimateManager", (JavaFunction) (frame, n) -> {
                try {
                    frame.push(cls("zombie.iso.weather.ClimateManager").getMethod("getInstance").invoke(null));
                } catch (Throwable t) { frame.push(null); }
                return 1;
            });
            // World sounds, the game's globals (LuaManager.java:9865 addSound,
            // :3662 getWorldSoundManager). Unexposed, every mod sound that
            // calls zombies (a lure, a decoy, a noisy price) died on a nil
            // global, usually inside a pcall, so it passed while doing nothing.
            // PZEngine.sounds() reads what they put into the world.
            env.rawset("getWorldSoundManager", (JavaFunction) (frame, n) -> {
                try {
                    frame.push(cls("zombie.WorldSoundManager").getField("instance").get(null));
                } catch (Throwable t) { frame.push(null); }
                return 1;
            });
            env.rawset("addSound", (JavaFunction) (frame, n) -> {
                try {
                    Class<?> wsmCls = cls("zombie.WorldSoundManager");
                    Object wsm = wsmCls.getField("instance").get(null);
                    java.lang.reflect.Method m = wsmCls.getMethod("addSound", Object.class, int.class, int.class, int.class, int.class, int.class);
                    m.invoke(wsm, frame.get(0), ((Number) frame.get(1)).intValue(), ((Number) frame.get(2)).intValue(),
                        ((Number) frame.get(3)).intValue(), ((Number) frame.get(4)).intValue(), ((Number) frame.get(5)).intValue());
                } catch (Throwable t) { throw new RuntimeException("addSound: " + describeDeep(t)); }
                return 0;
            });
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
            // SousVide MP: the Pass carries payloads BETWEEN processes, so
            // the two halves of wireRoundTrip are exposed separately.
            // wireEncode(tbl) -> (base64 bytes, drops); wireDecode(b64) -> tbl.
            pzEngine.rawset("wireEncode", (JavaFunction) (frame, n) -> {
                Object[] saved = wireSave(frame.get(0));
                if (saved == null) { frame.push(null); return 1; }
                frame.push(java.util.Base64.getEncoder().encodeToString((byte[]) saved[0]));
                frame.push(saved[1]);
                return 2;
            });
            pzEngine.rawset("wireDecode", (JavaFunction) (frame, n) -> {
                Object b = n > 0 ? frame.get(0) : null;
                frame.push(b instanceof String s ? wireLoad(java.util.Base64.getDecoder().decode(s)) : null);
                return 1;
            });
            pzEngine.rawset("role", (JavaFunction) (frame, n) -> { frame.push(role); return 1; });
            // Kahlua converts a Lua number to double/float/int but not to
            // short, byte or long ("expected argument of type short, got
            // Double"): IsoPlayer.setOnlineID(short) is unreachable from Lua.
            // invokeTyped(obj, method, "short"|"byte"|"long"|"int"|"float", n)
            // calls the one-argument overload of that primitive type.
            // Items over the Pass: the bytes the real add-item packet carries
            // (AddInventoryItemToContainerPacket.write: CompressIdenticalItems
            // .save; parse: CompressIdenticalItems.load). Items keep their IDs.
            // itemsEncode({item...}) -> base64 | nil, err
            // itemsDecode(b64) -> {item...} | nil, err
            pzEngine.rawset("itemsEncode", (JavaFunction) (frame, n) -> {
                try {
                    ensureWorldDictionary();
                    java.util.ArrayList<Object> items = new java.util.ArrayList<>();
                    if (frame.get(0) instanceof KahluaTable t) {
                        for (int i = 1; t.rawget(i) != null; i++) items.add(t.rawget(i));
                    }
                    Class<?> cii = cls("zombie.inventory.CompressIdenticalItems");
                    java.nio.ByteBuffer bb = java.nio.ByteBuffer.allocate(4 << 20);
                    cii.getMethod("save", java.nio.ByteBuffer.class, java.util.ArrayList.class, cls("zombie.characters.IsoGameCharacter"))
                        .invoke(null, bb, items, null);
                    bb.flip();
                    byte[] bytes = new byte[bb.remaining()];
                    bb.get(bytes);
                    frame.push(java.util.Base64.getEncoder().encodeToString(bytes));
                    return 1;
                } catch (Throwable t) { frame.push(null); frame.push(describe(t)); return 2; }
            });
            pzEngine.rawset("itemsDecode", (JavaFunction) (frame, n) -> {
                try {
                    ensureWorldDictionary();
                    byte[] bytes = java.util.Base64.getDecoder().decode(String.valueOf(frame.get(0)));
                    Class<?> cii = cls("zombie.inventory.CompressIdenticalItems");
                    int worldVersion = cls("zombie.iso.IsoWorld").getField("WorldVersion").getInt(null);
                    @SuppressWarnings("unchecked")
                    java.util.List<Object> items = (java.util.List<Object>) cii
                        .getMethod("load", java.nio.ByteBuffer.class, int.class, java.util.ArrayList.class, java.util.ArrayList.class)
                        .invoke(null, java.nio.ByteBuffer.wrap(bytes), worldVersion, null, null);
                    KahluaTable out = WIRE_PLATFORM.newTable();
                    int i = 1;
                    for (Object it : items) out.rawset(i++, it);
                    frame.push(out);
                    return 1;
                } catch (Throwable t) { frame.push(null); frame.push(describe(t)); return 2; }
            });
            // World objects over the Pass: the AddItemToMapPacket bytes
            // (write: obj.writeToRemoteBuffer; parse: WorldItemTypes
            // .createFromBuffer + obj.loadFromRemoteBuffer, which puts the
            // object on its square at the sent index). The caller runs
            // obj:addToWorld() as processClient does.
            // objectEncode(obj) -> base64 | nil, err; objectDecode(b64) -> obj | nil, err
            pzEngine.rawset("objectEncode", (JavaFunction) (frame, n) -> {
                try {
                    ensureWorldDictionary();
                    Object obj = frame.get(0);
                    java.nio.ByteBuffer bb = java.nio.ByteBuffer.allocate(4 << 20);
                    Class<?> writerCls = cls("zombie.core.network.ByteBufferWriter");
                    Object writer = writerCls.getConstructor(java.nio.ByteBuffer.class).newInstance(bb);
                    obj.getClass().getMethod("writeToRemoteBuffer", writerCls).invoke(obj, writer);
                    bb.flip();
                    byte[] bytes = new byte[bb.remaining()];
                    bb.get(bytes);
                    frame.push(java.util.Base64.getEncoder().encodeToString(bytes));
                    return 1;
                } catch (Throwable t) { frame.push(null); frame.push(describe(t)); return 2; }
            });
            pzEngine.rawset("objectDecode", (JavaFunction) (frame, n) -> {
                try {
                    ensureWorldDictionary();
                    byte[] bytes = java.util.Base64.getDecoder().decode(String.valueOf(frame.get(0)));
                    Class<?> readerCls = cls("zombie.core.network.ByteBufferReader");
                    Object reader = readerCls.getConstructor(java.nio.ByteBuffer.class).newInstance(java.nio.ByteBuffer.wrap(bytes));
                    Object obj = cls("zombie.network.WorldItemTypes").getMethod("createFromBuffer", readerCls).invoke(null, reader);
                    obj.getClass().getMethod("loadFromRemoteBuffer", readerCls).invoke(obj, reader);
                    frame.push(obj);
                    return 1;
                } catch (Throwable t) { frame.push(null); frame.push(describe(t)); return 2; }
            });
            pzEngine.rawset("invokeTyped", (JavaFunction) (frame, n) -> {
                try {
                    Object obj = frame.get(0);
                    String name = String.valueOf(frame.get(1));
                    String type = String.valueOf(frame.get(2));
                    Number v = (Number) frame.get(3);
                    Class<?> pt; Object arg;
                    switch (type) {
                        case "short" -> { pt = short.class; arg = v.shortValue(); }
                        case "byte"  -> { pt = byte.class;  arg = v.byteValue(); }
                        case "long"  -> { pt = long.class;  arg = v.longValue(); }
                        case "int"   -> { pt = int.class;   arg = v.intValue(); }
                        case "float" -> { pt = float.class; arg = v.floatValue(); }
                        default -> throw new IllegalArgumentException("type " + type);
                    }
                    java.lang.reflect.Method m = null;
                    for (Class<?> c = obj.getClass(); c != null && m == null; c = c.getSuperclass()) {
                        try { m = c.getMethod(name, pt); } catch (NoSuchMethodException ignored) { break; }
                    }
                    if (m == null) throw new NoSuchMethodException(name + "(" + type + ")");
                    frame.push(m.invoke(obj, arg));
                } catch (Throwable t) { frame.push(null); frame.push(describe(t)); return 2; }
                return 1;
            });
            // Reflective field access, walking superclasses: Kahlua exposes no
            // public fields at all, and the gates worth diagnosing (a zombie's
            // avoidDamage/noDamage, an item's private counters) are private.
            pzEngine.rawset("field", (JavaFunction) (frame, n) -> {
                try {
                    java.lang.reflect.Field f = findField(frame.get(0).getClass(), String.valueOf(frame.get(1)));
                    Object v = f.get(frame.get(0));
                    frame.push(v instanceof Number num ? (Object) num.doubleValue() : v);
                } catch (Throwable t) { frame.push(null); frame.push(describe(t)); return 2; }
                return 1;
            });
            pzEngine.rawset("setField", (JavaFunction) (frame, n) -> {
                try {
                    Object obj = frame.get(0);
                    java.lang.reflect.Field f = findField(obj.getClass(), String.valueOf(frame.get(1)));
                    Object v = frame.get(2);
                    Class<?> t = f.getType();
                    if (v instanceof Number num) {
                        if (t == int.class) v = num.intValue(); else if (t == float.class) v = num.floatValue();
                        else if (t == long.class) v = num.longValue(); else if (t == short.class) v = num.shortValue();
                        else if (t == byte.class) v = num.byteValue(); else if (t == double.class) v = num.doubleValue();
                    }
                    f.set(obj, v);
                    frame.push(true);
                } catch (Throwable t) { frame.push(false); frame.push(describe(t)); return 2; }
                return 1;
            });
            // ENGINE EVENTS -> MOD LUA. The engine fires OnHitZombie, OnZombieDead,
            // OnWeaponHitXp... through LuaEventManager into the env it was handed
            // (a scratch env here, so its Events never clobber the kit's mock).
            // forwardEvent(name, fn) adds fn to that engine Event's own callback
            // list, so an engine-fired event reaches the mod's listeners the way
            // it does in game. Idempotent per (name, fn); unforwardEvent removes.
            pzEngine.rawset("forwardEvent", (JavaFunction) (frame, n) -> {
                try {
                    Object ev = cls("zombie.Lua.LuaEventManager").getMethod("AddEvent", String.class).invoke(null, String.valueOf(frame.get(0)));
                    @SuppressWarnings("unchecked")
                    java.util.List<Object> cbs = (java.util.List<Object>) findField(ev.getClass(), "callbacks").get(ev);
                    Object fn = frame.get(1);
                    if (!cbs.contains(fn)) cbs.add(fn);
                    frame.push(true);
                } catch (Throwable t) { frame.push(false); frame.push(describe(t)); return 2; }
                return 1;
            });
            pzEngine.rawset("unforwardEvent", (JavaFunction) (frame, n) -> {
                try {
                    Object ev = cls("zombie.Lua.LuaEventManager").getMethod("AddEvent", String.class).invoke(null, String.valueOf(frame.get(0)));
                    @SuppressWarnings("unchecked")
                    java.util.List<Object> cbs = (java.util.List<Object>) findField(ev.getClass(), "callbacks").get(ev);
                    frame.push(cbs.remove(frame.get(1)));
                } catch (Throwable t) { frame.push(false); frame.push(describe(t)); return 2; }
                return 1;
            });
            // THE ARENA'S HIT: IsoZombie.Hit(weapon, wielder, damageSplit,
            // bIgnoreDamage, modDelta, bRemote=false), called by reflection on the
            // exact overload so Kahlua's overload pick and its silent return
            // conversion are out of the way. Returns damage, or nil + the cause.
            pzEngine.rawset("hit", (JavaFunction) (frame, n) -> {
                try {
                    Object target = frame.get(0), weapon = frame.get(1), wielder = frame.get(2);
                    float split = ((Number) frame.get(3)).floatValue();
                    boolean ignore = Boolean.TRUE.equals(frame.get(4));
                    float modDelta = n > 5 && frame.get(5) instanceof Number md ? md.floatValue() : 1.0f;
                    java.lang.reflect.Method m = target.getClass().getMethod("Hit", cls("zombie.inventory.types.HandWeapon"),
                        cls("zombie.characters.IsoGameCharacter"), float.class, boolean.class, float.class, boolean.class);
                    Object r = m.invoke(target, weapon, wielder, split, ignore, modDelta, false);
                    frame.push(r instanceof Number num ? (Object) num.doubleValue() : r);
                } catch (java.lang.reflect.InvocationTargetException ite) {
                    frame.push(null); frame.push(describeDeep(ite.getCause() != null ? ite.getCause() : ite)); return 2;
                } catch (Throwable t) { frame.push(null); frame.push(describeDeep(t)); return 2; }
                return 1;
            });
            // The engine's own RNG (zombie.core.random.Rand -> RandStandard.INSTANCE,
            // a CellularAutomatonRNG). The wear roll (InventoryItem.damageCheck),
            // hit reactions and crits draw from it, not from Lua's ZombRand, so an
            // Arena run only replays if this is seeded too. seedRand(n) swaps in a
            // seeded java.util.Random; seedRand(nil) restores the real one.
            pzEngine.rawset("seedRand", (JavaFunction) (frame, n) -> {
                try {
                    Object inst = cls("zombie.core.random.RandStandard").getField("INSTANCE").get(null);
                    java.lang.reflect.Field f = findField(inst.getClass(), "rand");
                    Object seed = n > 0 ? frame.get(0) : null;
                    if (seed instanceof Number num) {
                        if (savedRand == null) savedRand = f.get(inst);
                        f.set(inst, new java.util.Random(num.longValue()));
                    } else if (savedRand != null) {
                        f.set(inst, savedRand); savedRand = null;
                    }
                    frame.push(true);
                } catch (Throwable t) { frame.push(false); frame.push(describe(t)); return 2; }
                return 1;
            });
            // CombatManager.applyMeleeHitLocationDamage (private): the head/leg
            // split modifiers and calculateHitLocationDamage, exactly as
            // attackCollisionCheck applies them before IsoZombie.Hit.
            pzEngine.rawset("meleeHitLocation", (JavaFunction) (frame, n) -> {
                try {
                    Object cm = cls("zombie.CombatManager").getMethod("getInstance").invoke(null);
                    java.lang.reflect.Method m = cm.getClass().getDeclaredMethod("applyMeleeHitLocationDamage",
                        cls("zombie.characters.IsoGameCharacter"), cls("zombie.inventory.types.HandWeapon"), int.class, int.class, boolean.class, float.class);
                    m.setAccessible(true);
                    Object r = m.invoke(cm, frame.get(0), frame.get(1), ((Number) frame.get(2)).intValue(),
                        ((Number) frame.get(3)).intValue(), Boolean.TRUE.equals(frame.get(4)), ((Number) frame.get(5)).floatValue());
                    frame.push(((Number) r).doubleValue());
                } catch (java.lang.reflect.InvocationTargetException ite) {
                    frame.push(null); frame.push(describe(ite.getCause() != null ? ite.getCause() : ite)); return 2;
                } catch (Throwable t) { frame.push(null); frame.push(describe(t)); return 2; }
                return 1;
            });
            // PZEngine.call(obj, "method", args...): a reflective call that picks
            // the overload by argument count and type, and RETURNS a failure
            // (nil, "Error: msg @ frames") instead of letting Kahlua swallow it.
            // Kahlua drops java.lang.Error thrown inside a method call, so an
            // engine method that dies of NoSuchMethodError/NoSuchFieldError just
            // looks like it did nothing. Use it whenever a call "had no effect".
            pzEngine.rawset("call", (JavaFunction) (frame, n) -> {
                try {
                    Object obj = frame.get(0);
                    String name = String.valueOf(frame.get(1));
                    Object[] args = new Object[Math.max(0, n - 2)];
                    for (int i = 0; i < args.length; i++) args[i] = frame.get(i + 2);
                    java.lang.reflect.Method pick = null; Object[] conv = null;
                    java.util.List<java.lang.reflect.Method> cands = new java.util.ArrayList<>(java.util.Arrays.asList(obj.getClass().getMethods()));
                    // then private/protected ones up the hierarchy (the engine keeps
                    // whole pipeline steps private: CombatManager.calculateHitChanceData)
                    for (Class<?> k = obj.getClass(); k != null; k = k.getSuperclass()) cands.addAll(java.util.Arrays.asList(k.getDeclaredMethods()));
                    for (java.lang.reflect.Method m : cands) {
                        if (!m.getName().equals(name) || m.getParameterCount() != args.length) continue;
                        Class<?>[] pt = m.getParameterTypes();
                        Object[] c = new Object[args.length];
                        boolean ok = true;
                        for (int i = 0; i < args.length && ok; i++) {
                            Object a = args[i];
                            Class<?> t = pt[i];
                            if (a == null) { ok = !t.isPrimitive(); c[i] = null; }
                            else if (a instanceof Double d && (t.isPrimitive() || Number.class.isAssignableFrom(t))) {
                                if (t == int.class || t == Integer.class) c[i] = d.intValue();
                                else if (t == float.class || t == Float.class) c[i] = d.floatValue();
                                else if (t == long.class || t == Long.class) c[i] = d.longValue();
                                else if (t == short.class || t == Short.class) c[i] = d.shortValue();
                                else if (t == byte.class || t == Byte.class) c[i] = d.byteValue();
                                else if (t == double.class || t == Double.class) c[i] = d;
                                else ok = false;
                            }
                            else if (a instanceof Boolean b && (t == boolean.class || t == Boolean.class)) c[i] = b;
                            else if (t.isInstance(a)) c[i] = a;
                            else ok = false;
                        }
                        if (ok) { pick = m; conv = c; break; }
                    }
                    if (pick == null) throw new NoSuchMethodException(obj.getClass().getName() + "." + name + "/" + args.length);
                    pick.setAccessible(true);
                    Object r = pick.invoke(obj, conv);
                    frame.push(r instanceof Number num && !(r instanceof Double) ? (Object) num.doubleValue() : r);
                    frame.push(null);
                    return 2;
                } catch (java.lang.reflect.InvocationTargetException ite) {
                    frame.push(null); frame.push(describeDeep(ite.getCause() != null ? ite.getCause() : ite)); return 2;
                } catch (Throwable t) { frame.push(null); frame.push(describeDeep(t)); return 2; }
            });
            // The entity system (zombie.entity.GameEntityManager), which the game
            // starts in IsoWorld load (IsoWorld.java:2053). Headless boot never
            // runs that, so GameEntityManager.engine is null and anything that
            // registers an entity -- EQUIPPING AN ITEM (GameEntity.onEquip) among
            // them -- dies of an NPE that Kahlua swallows. Idempotent.
            pzEngine.rawset("initEntities", (JavaFunction) (frame, n) -> {
                try {
                    Class<?> gem = cls("zombie.entity.GameEntityManager");
                    java.lang.reflect.Field eng = findField(gem, "engine");
                    if (eng.get(null) == null) {
                        int wv = cls("zombie.iso.IsoWorld").getField("WorldVersion").getInt(null);
                        gem.getMethod("Init", int.class).invoke(null, wv);
                    }
                    frame.push(eng.get(null) != null);
                } catch (java.lang.reflect.InvocationTargetException ite) {
                    frame.push(false); frame.push(describeDeep(ite.getCause() != null ? ite.getCause() : ite)); return 2;
                } catch (Throwable t) { frame.push(false); frame.push(describeDeep(t)); return 2; }
                return 1;
            });
            // The client's own player, registered as the game registers it
            // (IsoPlayer.players[index], numPlayers): IsoPlayer.isLocalPlayer()
            // walks that array (IsoPlayer.java:6555), so a player the bench made
            // without it read as REMOTE on its own client, and every "is this
            // my player" check (observer gating, CombatManager's local paths)
            // answered wrong. setLocalPlayer(player[, index]) -> true
            pzEngine.rawset("setLocalPlayer", (JavaFunction) (frame, n) -> {
                try {
                    Object player = frame.get(0);
                    int idx = n > 1 && frame.get(1) instanceof Number num ? num.intValue() : 0;
                    Class<?> ip = cls("zombie.characters.IsoPlayer");
                    Object arr = ip.getField("players").get(null);
                    java.lang.reflect.Array.set(arr, idx, player);
                    java.lang.reflect.Field np = ip.getField("numPlayers");
                    if (np.getInt(null) < idx + 1) np.setInt(null, idx + 1);
                    frame.push(true);
                } catch (Throwable t) { frame.push(false); frame.push(describeDeep(t)); return 2; }
                return 1;
            });
            // A static field by class name (Kahlua reads no fields, static or not):
            // PZEngine.static("zombie.WorldSoundManager", "instance").
            pzEngine.rawset("static", (JavaFunction) (frame, n) -> {
                try {
                    java.lang.reflect.Field f = findField(cls(String.valueOf(frame.get(0))), String.valueOf(frame.get(1)));
                    Object v = f.get(null);
                    frame.push(v instanceof Number num ? (Object) num.doubleValue() : v);
                } catch (Throwable t) { frame.push(null); frame.push(describeDeep(t)); return 2; }
                return 1;
            });
            // World sounds emitted since index `since` (WorldSoundManager.instance
            // .soundList; headless nothing ages them out, so the list only grows):
            // returns { {x,y,z,radius,volume,player}, ... }, newCount. This is how
            // "did the weapon get louder or quieter" is read: the radius the game
            // actually put into the world, which zombies hear.
            pzEngine.rawset("sounds", (JavaFunction) (frame, n) -> {
                try {
                    Object wsm = cls("zombie.WorldSoundManager").getField("instance").get(null);
                    java.util.List<?> list = (java.util.List<?>) findField(wsm.getClass(), "soundList").get(wsm);
                    int since = n > 0 && frame.get(0) instanceof Number num ? num.intValue() : 0;
                    KahluaTable out = platform.newTable();
                    int k = 1;
                    for (int i = Math.max(0, since); i < list.size(); i++) {
                        Object ws = list.get(i);
                        KahluaTable t = platform.newTable();
                        for (String fld : new String[] { "x", "y", "z", "radius", "volume" }) {
                            t.rawset(fld, ((Number) findField(ws.getClass(), fld).get(ws)).doubleValue());
                        }
                        t.rawset("player", findField(ws.getClass(), "sourceIsPlayer").get(ws));
                        out.rawset(k++, t);
                    }
                    frame.push(out); frame.push((double) list.size());
                } catch (Throwable t) { frame.push(null); frame.push(describeDeep(t)); return 2; }
                return 2;
            });
            // An engine object through the engine's own byte form, as its network
            // packet carries it: bytesSave(obj, "save"|"write"|"saveMainFields")
            // -> base64; bytesLoad(obj, "load"|"read"|"loadMainFields", b64[, int])
            // calls the method with a ByteBuffer (or ByteBufferWriter/Reader) and,
            // when it takes one, the int (world version). The MP bench's player
            // sync packets ride on these (PlayerStatsPacket: Stats.save/load,
            // SyncPlayerFieldsPacket: CharacterTraits.write/read).
            pzEngine.rawset("bytesSave", (JavaFunction) (frame, n) -> {
                try {
                    Object obj = frame.get(0);
                    String name = String.valueOf(frame.get(1));
                    java.nio.ByteBuffer bb = java.nio.ByteBuffer.allocate(1 << 16);
                    Class<?> bbw = cls("zombie.core.network.ByteBufferWriter");
                    java.lang.reflect.Method pick = null;
                    for (java.lang.reflect.Method m : obj.getClass().getMethods()) {
                        if (m.getName().equals(name) && m.getParameterCount() == 1
                            && (m.getParameterTypes()[0] == java.nio.ByteBuffer.class || m.getParameterTypes()[0] == bbw)) { pick = m; break; }
                    }
                    if (pick == null) throw new NoSuchMethodException(obj.getClass().getName() + "." + name + "(ByteBuffer)");
                    Object arg = pick.getParameterTypes()[0] == java.nio.ByteBuffer.class ? bb : bbw.getConstructor(java.nio.ByteBuffer.class).newInstance(bb);
                    pick.invoke(obj, arg);
                    bb.flip();
                    byte[] out = new byte[bb.remaining()];
                    bb.get(out);
                    frame.push(java.util.Base64.getEncoder().encodeToString(out));
                } catch (java.lang.reflect.InvocationTargetException ite) {
                    frame.push(null); frame.push(describeDeep(ite.getCause() != null ? ite.getCause() : ite)); return 2;
                } catch (Throwable t) { frame.push(null); frame.push(describeDeep(t)); return 2; }
                return 1;
            });
            pzEngine.rawset("bytesLoad", (JavaFunction) (frame, n) -> {
                try {
                    Object obj = frame.get(0);
                    String name = String.valueOf(frame.get(1));
                    java.nio.ByteBuffer bb = java.nio.ByteBuffer.wrap(java.util.Base64.getDecoder().decode(String.valueOf(frame.get(2))));
                    Integer extra = n > 3 && frame.get(3) instanceof Number num ? num.intValue() : null;
                    Class<?> bbr = cls("zombie.core.network.ByteBufferReader");
                    java.lang.reflect.Method pick = null;
                    for (java.lang.reflect.Method m : obj.getClass().getMethods()) {
                        if (!m.getName().equals(name)) continue;
                        Class<?>[] pt = m.getParameterTypes();
                        if (pt.length == 0 || !(pt[0] == java.nio.ByteBuffer.class || pt[0] == bbr)) continue;
                        if (pt.length == 1 || (pt.length == 2 && pt[1] == int.class && extra != null)) { pick = m; if (pt.length == 2) break; }
                    }
                    if (pick == null) throw new NoSuchMethodException(obj.getClass().getName() + "." + name + "(ByteBuffer)");
                    Object arg = pick.getParameterTypes()[0] == java.nio.ByteBuffer.class ? bb : bbr.getConstructor(java.nio.ByteBuffer.class).newInstance(bb);
                    if (pick.getParameterCount() == 2) pick.invoke(obj, arg, extra); else pick.invoke(obj, arg);
                    frame.push(true);
                } catch (java.lang.reflect.InvocationTargetException ite) {
                    frame.push(false); frame.push(describeDeep(ite.getCause() != null ? ite.getCause() : ite)); return 2;
                } catch (Throwable t) { frame.push(false); frame.push(describeDeep(t)); return 2; }
                return 1;
            });
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

    /**
     * EXPERIMENTAL (character spike, 2026-10-04): construct a real IsoPlayer
     * headless -- no cell, position 0,0,0 -- with GameServer.server forced true
     * for the duration of the constructor (the dedicated server builds players
     * headless exactly this way: dummy sound emitter, no client-only paths).
     * Returns {player, null} or {null, "Root: message @ first zombie.* frame"}.
     */
    /** The one headless cell every newSquare lives in (created on first use). */
    private static Object harnessCell;
    private static final int HARNESS_SQUARES = 256;   // one metagrid cell: squares 0..255 on x and y

    private static java.lang.reflect.Field field(Class<?> c, String name) throws Exception {
        java.lang.reflect.Field f = c.getDeclaredField(name);
        f.setAccessible(true);
        return f;
    }

    /**
     * A real IsoGridSquare, registered where the engine's own lookups find it.
     *
     * IsoCell.getGridSquare answers from ServerMap when GameServer.server is
     * set (IsoCell.java:3345) -- the branch a dedicated server runs, and the
     * one the harness runs world mutations under (the render-side work in
     * IsoWorldInventoryObject is skipped on a server, which is what makes
     * dropping items headless-safe). So the square goes where ServerMap reads:
     * the metagrid is given one 256x256 cell (isValidSquare), ServerMap is
     * sized to it, and the square is set into a real IsoChunk inside a loaded
     * ServerCell. getCell():getGridSquare(x, y, z) from mod Lua is then the
     * game's own lookup, unchanged. Coordinates must be within 0..255.
     */
    public static Object[] newSquare(int x, int y, int z) {
        if (!booted) return new Object[] { null, "engine not booted" };
        if (x < 0 || y < 0 || x >= HARNESS_SQUARES || y >= HARNESS_SQUARES)
            return new Object[] { null, "harness squares are 0.." + (HARNESS_SQUARES - 1) };
        try {
            Class<?> cellC = cls("zombie.iso.IsoCell");
            Class<?> worldC = cls("zombie.iso.IsoWorld");
            Object world = worldC.getField("instance").get(null);
            Class<?> mapC = cls("zombie.network.ServerMap");
            Object map = mapC.getField("instance").get(null);
            Class<?> serverCellC = cls("zombie.network.ServerMap$ServerCell");
            int serverCellsPerSide = HARNESS_SQUARES / 64;
            if (harnessCell == null) {
                harnessCell = cellC.getConstructor(int.class, int.class).newInstance(300, 300);
                Object grid = worldC.getMethod("getMetaGrid").invoke(world);
                Class<?> gridC = grid.getClass();
                for (String f : new String[] { "minX", "minY", "maxX", "maxY" }) gridC.getField(f).setInt(grid, 0);
                field(mapC, "grid").set(map, grid);
                field(mapC, "width").setInt(map, serverCellsPerSide);
                field(mapC, "height").setInt(map, serverCellsPerSide);
                mapC.getField("cellMap").set(map, java.lang.reflect.Array.newInstance(serverCellC, serverCellsPerSide * serverCellsPerSide));
            }
            Object[] cellMap = (Object[]) mapC.getField("cellMap").get(map);
            int cx = x / 64, cy = y / 64;
            Object sc = cellMap[cy * serverCellsPerSide + cx];
            if (sc == null) {
                java.lang.reflect.Constructor<?> k = serverCellC.getDeclaredConstructor();
                k.setAccessible(true);
                sc = k.newInstance();
                serverCellC.getField("wx").setInt(sc, cx);
                serverCellC.getField("wy").setInt(sc, cy);
                serverCellC.getField("isLoaded").setBoolean(sc, true);
                cellMap[cy * serverCellsPerSide + cx] = sc;
            }
            Object[][] chunks = (Object[][]) serverCellC.getField("chunks").get(sc);
            int chx = (x - cx * 64) / 8, chy = (y - cy * 64) / 8;
            Class<?> chunkC = cls("zombie.iso.IsoChunk");
            if (chunks[chx][chy] == null) {
                Object chunk = chunkC.getConstructor(cellC).newInstance(harnessCell);
                field(chunkC, "wx").setInt(chunk, x / 8);
                field(chunkC, "wy").setInt(chunk, y / 8);
                chunks[chx][chy] = chunk;
            }
            Object chunk = chunks[chx][chy];
            Class<?> sqC = cls("zombie.iso.IsoGridSquare");
            Object existing = chunkC.getMethod("getGridSquare", int.class, int.class, int.class).invoke(chunk, x % 8, y % 8, z);
            if (existing != null) return new Object[] { existing, null };
            Object sq = sqC.getMethod("getNew", cellC, cls("zombie.iso.SliceY"), int.class, int.class, int.class)
                .invoke(null, harnessCell, null, x, y, z);
            chunkC.getMethod("setSquare", int.class, int.class, int.class, sqC).invoke(chunk, x % 8, y % 8, z, sq);
            // Ground, as a real square is: a floor tile gives it the solidfloor
            // property, and engine code asks for it (dropHeavyItems only drops
            // onto TreatAsSolidFloor squares; items "fall" through anything else).
            Object props = sqC.getMethod("getProperties").invoke(sq);
            Class<?> flagC = cls("zombie.iso.SpriteDetails.IsoFlagType");
            Object solid = flagC.getField("solidfloor").get(null);
            props.getClass().getMethod("set", flagC).invoke(props, solid);
            return new Object[] { sq, null };
        } catch (Throwable t) {
            return new Object[] { null, describe(t) };
        }
    }

    // ── the real world (opt-in: the workbench, never an ordinary suite) ──────
    private static ScriptFiles bootCollected;
    private static FileContext bootCtx;
    private static Method bootParse;
    private static Path bootModRoot;

    /** ScriptManager.loadScripts' Reload branch, with the bridge's file loop:
     *  clear the chosen buckets, re-parse every collected file in Reload mode
     *  (the mod tree is re-scanned so new files count), then the collections'
     *  load and post-load passes. Returns ms. */
    @SuppressWarnings({"unchecked", "rawtypes"})
    private static double reloadScriptTypes(java.util.EnumSet set) throws Exception {
        if (bootCollected == null) throw new IllegalStateException("no boot script list (engine booted without scripts?)");
        long t0 = System.currentTimeMillis();
        Class<?> smC = cls("zombie.scripting.ScriptManager");
        Object sm = smC.getField("instance").get(null);
        Class<?> modeC = cls("zombie.scripting.ScriptLoadMode");
        Object reload = enumConst(modeC, "Reload");
        // Anonymous subclasses (ScriptManager$29...): look methods up on the
        // public base class, or reflection refuses the call.
        Class<?> SBC = cls("zombie.scripting.ScriptBucketCollection");
        java.util.List<Object> colls = (java.util.List<Object>) field(smC, "bucketCollectionList").get(sm);
        java.util.List<Object> chosen = new ArrayList<>();
        for (Object c : colls) if (set.contains(SBC.getMethod("getScriptType").invoke(c))) chosen.add(c);
        for (Object c : chosen) {
            SBC.getMethod("setReloadBuckets", boolean.class).invoke(c, true);
            SBC.getMethod("PreReloadScripts").invoke(c);
        }
        // A reload refuses NEW scripts of a type without AllowNewScriptDiscovery-
        // OnReload (ScriptBucket.CreateFromTokenPP). Entity and Item drop it on
        // purpose (world-dictionary types: registry ids are assigned at world
        // load). For the live loop, grant it while reloading -- a script added
        // this way works in the VM but has no registry id, so a SAVED square
        // would not keep it (restart the VM for that).
        Class<?> stC = cls("zombie.scripting.ScriptType");
        Class<?> flagC = cls("zombie.scripting.ScriptType$Flags");
        java.lang.reflect.Field flagsF = field(stC, "flags");
        java.util.Map<Object, Object> savedFlags = new java.util.HashMap<>();
        Object allowNew = enumConst(flagC, "AllowNewScriptDiscoveryOnReload");
        for (Object t : set) {
            java.util.Set<Object> cur = (java.util.Set<Object>) flagsF.get(t);
            if (!cur.contains(allowNew)) {
                savedFlags.put(t, cur);
                java.util.Set<Object> more = new java.util.HashSet<>(cur);
                more.add(allowNew);
                flagsF.set(t, java.util.Collections.unmodifiableSet(more));
            }
        }
        try {
        if (bootModRoot != null) bootCollected.addTree(bootModRoot.resolve("media/scripts"), modIdOf(bootModRoot));
        for (ScriptFiles.Entry e : bootCollected.byPath.values()) parseFile(sm, bootParse, reload, e.file(), e.modId(), bootCtx, System.out);
        for (Object c : chosen) SBC.getMethod("setReloadBuckets", boolean.class).invoke(c, false);
        for (String m : new String[] { "LoadScripts", "PostLoadScripts", "OnScriptsLoaded" })
            for (Object c : chosen) SBC.getMethod(m, modeC).invoke(c, reload);
        for (String m : new String[] { "OnLoadedAfterLua", "OnPostTileDefinitions", "OnPostWorldDictionaryInit" })
            for (Object c : chosen) {
                try { SBC.getMethod(m).invoke(c); }
                catch (java.lang.reflect.InvocationTargetException ite) { System.out.println("[engine] reload " + m + ": " + describe(ite)); }
            }
        } finally {
            for (java.util.Map.Entry<Object, Object> e : savedFlags.entrySet()) flagsF.set(e.getKey(), e.getValue());
        }
        return System.currentTimeMillis() - t0;
    }

    private static boolean worldLoaded;
    private static String worldError;
    private static final java.util.Set<Long> loadedChunks = new java.util.HashSet<>();

    /**
     * Load the game's world the way IsoWorld.init does on a dedicated server:
     * tile definitions (sprite names AND properties -- what decides a tile's
     * object class), the metagrid (every lotheader: cells, rooms, buildings),
     * then ServerMap sized to it. After this, loadCell() places real map
     * data at real world coordinates. Once per VM; the harness's 0..255
     * newSquare cell is replaced (squares already handed out keep working
     * as objects but are no longer registered).
     * Returns { ms per phase as "a=.. b=..", null } or { null, error }.
     */
    public static Object[] loadWorld(String gameMap) {
        if (!booted) return new Object[] { null, "engine not booted" };
        if (worldLoaded) return new Object[] { "already loaded", null };
        if (worldError != null) return new Object[] { null, worldError };
        StringBuilder t = new StringBuilder();
        java.lang.reflect.Field server = null;
        boolean prev = false;
        try {
            server = cls("zombie.network.GameServer").getField("server");
            prev = server.getBoolean(null);
            server.setBoolean(null, true);
            ensureServerNetwork();
            String map = gameMap == null || gameMap.isEmpty() ? "Muldraugh, KY" : gameMap;
            cls("zombie.core.Core").getField("gameMap").set(null, map);
            cls("zombie.network.GameServer").getField("gameMap").set(null, map);

            long t0 = System.currentTimeMillis();
            Class<?> worldC = cls("zombie.iso.IsoWorld");
            Object world = worldC.getField("instance").get(null);
            Class<?> smC = cls("zombie.iso.sprite.IsoSpriteManager");
            Object sprMan = smC.getField("instance").get(null);
            Class<?> zfsC = cls("zombie.ZomboidFileSystem");
            Object zfs = zfsC.getField("instance").get(null);
            java.lang.reflect.Method media = zfsC.getMethod("getMediaPath", String.class);
            // IsoWorld.init's exact sequence (IsoWorld.java:1974-1996).
            Object[][] files = { { "newtiledefinitions.tiles", 1 }, { "tiledefinitions_erosion.tiles", 2 },
                { "tiledefinitions_overlays.tiles", 4 }, { "tiledefinitions_b42chunkcaching.tiles", 5 },
                { "tiledefinitions_noiseworks.patch.tiles", -1 }, { "jumbo_trees_big.tiles", 6 }, { "jumbo_trees.tiles", 8 } };
            java.lang.reflect.Method props = worldC.getMethod("LoadTileDefinitionsPropertyStrings", smC, String.class, int.class);
            java.lang.reflect.Method defs = worldC.getMethod("LoadTileDefinitions", smC, String.class, int.class);
            for (Object[] f : files) props.invoke(world, sprMan, media.invoke(zfs, f[0]), f[1]);
            try { zfsC.getMethod("loadModTileDefPropertyStrings").invoke(zfs); } catch (Throwable ignored) { }
            for (String m : new String[] { "SetCustomPropertyValues", "GenerateTilePropertyLookupTables" }) {
                java.lang.reflect.Method mm = worldC.getDeclaredMethod(m);
                mm.setAccessible(true);
                mm.invoke(world);
            }
            for (Object[] f : files) defs.invoke(world, sprMan, media.invoke(zfs, f[0]), f[1]);
            try {
                java.lang.reflect.Method jt = worldC.getDeclaredMethod("registerFakeJumboTree", smC, int.class);
                jt.setAccessible(true);
                jt.invoke(world, sprMan, 7);
            } catch (Throwable ignored) { }
            try { zfsC.getMethod("loadModTileDefs").invoke(zfs); } catch (Throwable ignored) { }
            try { cls("zombie.scripting.ScriptManager").getMethod("PostTileDefinitions")
                    .invoke(cls("zombie.scripting.ScriptManager").getField("instance").get(null)); } catch (Throwable ignored) { }
            long t1 = System.currentTimeMillis();
            t.append("tiledefs=").append(t1 - t0).append("ms");

            Object grid = worldC.getMethod("getMetaGrid").invoke(world);
            createMetaGrid(grid, zfs, map);
            long t2 = System.currentTimeMillis();
            t.append(" metagrid=").append(t2 - t1).append("ms");

            Class<?> mapC = cls("zombie.network.ServerMap");
            Object smap = mapC.getField("instance").get(null);
            try {
                mapC.getMethod("init", grid.getClass()).invoke(smap, grid);
            } catch (java.lang.reflect.InvocationTargetException e) {
                // init ends with StashSystem.init(); the cell map is allocated
                // before it, which is all the harness needs.
                if (mapC.getField("cellMap").get(smap) == null) throw e;
                t.append(" (StashSystem skipped: ").append(describe(e)).append(")");
            }
            if (harnessCell == null) {
                harnessCell = cls("zombie.iso.IsoCell").getConstructor(int.class, int.class).newInstance(300, 300);
            }
            for (String f : new String[] { "minX", "minY", "maxX", "maxY" }) t.append(" ").append(f).append("=").append(grid.getClass().getField(f).getInt(grid));
            worldLoaded = true;
            loadedChunks.clear();
            return new Object[] { t.toString(), null };
        } catch (Throwable e) {
            worldError = describe(e) + " (after " + t + ")";
            return new Object[] { null, worldError };
        } finally {
            if (server != null) try { server.setBoolean(null, prev); } catch (Throwable ignored) { }
        }
    }

    /**
     * IsoMetaGrid.CreateStep1 minus procedural world generation, then the
     * real CreateStep2. Step 1 also builds WorldGenChunk/BiomeMap/... from
     * vanilla's `worldgen` Lua tables, which exist to generate cells that
     * have NO map data; every cell of a real map has lotpacks, and none of
     * PlaceLot reads them. Everything else is step 1 verbatim
     * (IsoMetaGrid.java:1397-1486): MapFiles per lot dir, IsoLot registries
     * in reverse priority, bounds, the cell grid, and the game's own eight
     * MetaGridLoaderThreads reading every lotheader (rooms, buildings).
     */
    @SuppressWarnings("unchecked")
    private static void createMetaGrid(Object grid, Object zfs, String map) throws Exception {
        Class<?> mg = grid.getClass();
        Class<?> isoLot = cls("zombie.iso.IsoLot");
        for (String f : new String[] { "InfoHeaders", "InfoFileNames", "InfoFileModded" })
            ((java.util.Map<?, ?>) isoLot.getField(f).get(null)).clear();
        java.util.List<Object> infoHeaderNames = (java.util.List<Object>) isoLot.getField("InfoHeaderNames").get(null);
        java.util.List<Object> mapFilesList = (java.util.List<Object>) isoLot.getField("MapFiles").get(null);
        infoHeaderNames.clear();
        mapFilesList.clear();
        // The map stack as a dedicated server's Map= line ("A;B;Muldraugh, KY"),
        // getLotDirectories' own ';' branch: its other branch resolves through
        // ChooseGameInfo's map.info scan, which the harness never ran.
        java.util.List<String> lotDirs = new java.util.ArrayList<>();
        for (String d : map.split(";")) if (!d.trim().isEmpty() && !lotDirs.contains(d.trim())) lotDirs.add(d.trim());
        Class<?> mfC = cls("zombie.iso.MapFiles");
        java.lang.reflect.Method dirStr = zfs.getClass().getMethod("getDirectoryString", String.class);
        for (int i = 0; i < lotDirs.size(); i++) {
            String path = (String) dirStr.invoke(zfs, "media/maps/" + lotDirs.get(i) + "/");
            java.io.File file = new java.io.File(path);
            if (!file.isDirectory()) {
                // Headless, getDirectoryString can resolve against a home the
                // harness never populated; getMediaPath is the install's media.
                path = (String) zfs.getClass().getMethod("getMediaPath", String.class).invoke(zfs, "maps/" + lotDirs.get(i));
                file = new java.io.File(path);
                if (!file.isDirectory()) continue;
                if (!path.endsWith("/") && !path.endsWith(java.io.File.separator)) path = path + java.io.File.separator;
            }
            mapFilesList.add(mfC.getConstructor(String.class, String.class, String.class, int.class)
                .newInstance(lotDirs.get(i), path, file.getAbsolutePath(), i));
        }
        if (mapFilesList.isEmpty()) throw new IllegalStateException("no map folders for " + lotDirs);
        // MapFiles.load asks ChooseGameInfo.getMapDetails for each folder's
        // map.info (fixed2x decides whether lot tile names get Fix2x'd). It
        // resolves the file through ZomboidFileSystem.getString, which the
        // harness's file system doesn't map; parse the same keys from the
        // real file and seed the cache getMapDetails reads first.
        Class<?> cgi = cls("zombie.gameStates.ChooseGameInfo");
        Class<?> mapInfoC = cls("zombie.gameStates.ChooseGameInfo$Map");
        @SuppressWarnings("unchecked")
        java.util.Map<String, Object> maps = (java.util.Map<String, Object>) field(cgi, "Maps").get(null);
        for (Object mf : mapFilesList) {
            String name = (String) mfC.getField("mapDirectoryName").get(mf);
            String abs = (String) mfC.getField("mapDirectoryAbsolutePath").get(mf);
            if (maps.containsKey(name)) continue;
            java.io.File info = new java.io.File(abs, "map.info");
            Object mi = mapInfoC.getConstructor().newInstance();
            field(mapInfoC, "dir").set(mi, abs);
            field(mapInfoC, "title").set(mi, name);
            java.util.ArrayList<String> lots = new java.util.ArrayList<>();
            field(mapInfoC, "lotsDir").set(mi, lots);
            if (info.isFile()) {
                for (String line : java.nio.file.Files.readAllLines(info.toPath())) {
                    line = line.trim();
                    if (line.startsWith("title=")) field(mapInfoC, "title").set(mi, line.substring(6));
                    else if (line.startsWith("lots=")) lots.add(line.substring(5).trim());
                    else if (line.startsWith("fixed2x=")) field(mapInfoC, "fixed2x").setBoolean(mi, Boolean.parseBoolean(line.substring(8).trim()));
                }
            }
            maps.put(name, mi);
        }
        for (Object mf : mapFilesList) if ((Boolean) mfC.getMethod("load").invoke(mf)) mfC.getMethod("postLoad").invoke(mf);
        int minX = Integer.MAX_VALUE, minY = Integer.MAX_VALUE, maxX = Integer.MIN_VALUE, maxY = Integer.MIN_VALUE;
        for (int ix = mapFilesList.size() - 1; ix >= 0; ix--) {
            Object mf = mapFilesList.get(ix);
            ((java.util.Map<Object, Object>) isoLot.getField("InfoFileNames").get(null)).putAll((java.util.Map<Object, Object>) mfC.getField("infoFileNames").get(mf));
            ((java.util.Map<Object, Object>) isoLot.getField("InfoFileModded").get(null)).putAll((java.util.Map<Object, Object>) mfC.getField("infoFileModded").get(mf));
            ((java.util.Map<Object, Object>) isoLot.getField("InfoHeaders").get(null)).putAll((java.util.Map<Object, Object>) mfC.getField("infoHeaders").get(mf));
            java.util.List<Object> names = (java.util.List<Object>) mfC.getField("infoHeaderNames").get(mf);
            infoHeaderNames.removeAll(names);
            infoHeaderNames.addAll(names);
            minX = Math.min(minX, mfC.getField("minX").getInt(mf));
            minY = Math.min(minY, mfC.getField("minY").getInt(mf));
            maxX = Math.max(maxX, mfC.getField("maxX").getInt(mf));
            maxY = Math.max(maxY, mfC.getField("maxY").getInt(mf));
        }
        if (minX > maxX) throw new IllegalStateException("no .lotheader files in " + lotDirs);
        for (String f : new String[] { "minX", "minNonProceduralX" }) field(mg, f).setInt(grid, minX);
        for (String f : new String[] { "minY", "minNonProceduralY" }) field(mg, f).setInt(grid, minY);
        for (String f : new String[] { "maxX", "maxNonProceduralX" }) field(mg, f).setInt(grid, maxX);
        for (String f : new String[] { "maxY", "maxNonProceduralY" }) field(mg, f).setInt(grid, maxY);
        Class<?> metaCellC = cls("zombie.iso.IsoMetaCell");
        field(mg, "grid").set(grid, java.lang.reflect.Array.newInstance(metaCellC, maxX - minX + 1, maxY - minY + 1));
        field(mg, "width").setInt(grid, maxX - minX + 1);
        field(mg, "height").setInt(grid, maxY - minY + 1);
        field(mg, "createStartTime").setLong(grid, System.currentTimeMillis());
        Class<?> threadC = cls("zombie.iso.IsoMetaGrid$MetaGridLoaderThread");
        java.lang.reflect.Constructor<?> tk = threadC.getDeclaredConstructor(mg, int.class);
        tk.setAccessible(true);
        Object[] threads = (Object[]) field(mg, "threads").get(grid);
        for (int ix = 0; ix < 8; ix++) {
            Thread th = (Thread) tk.newInstance(grid, minY + ix);
            th.setDaemon(true);
            th.setName("MetaGridLoaderThread" + ix);
            th.start();
            threads[ix] = th;
        }
        mg.getMethod("CreateStep2").invoke(grid);
    }

    /**
     * Place real map data for one 256x256 cell (or a sub-rectangle of its
     * chunks) through the game's own loader: CellLoader.LoadCellBinaryChunk
     * -> IsoCell.PlaceLot -> CellLoader.DoTileObjectCreation, i.e. the right
     * object class per tile (doors, windows, containers, light switches,
     * sprite-bound entities). Chunks register into ServerMap, so
     * getCell():getGridSquare(x, y, z) at REAL coordinates finds them.
     * Returns { "chunks=N squares=M ms=T", null } or { null, error }.
     */
    public static Object[] loadCell(int cellX, int cellY, int chunkX0, int chunkY0, int chunkX1, int chunkY1) {
        if (!worldLoaded) return new Object[] { null, "call loadWorld first" };
        java.lang.reflect.Field server = null;
        boolean prev = false;
        long t0 = System.currentTimeMillis();
        int chunks = 0, squares = 0;
        try {
            server = cls("zombie.network.GameServer").getField("server");
            prev = server.getBoolean(null);
            server.setBoolean(null, true);
            Class<?> cellC = cls("zombie.iso.IsoCell");
            Class<?> chunkC = cls("zombie.iso.IsoChunk");
            Class<?> mapC = cls("zombie.network.ServerMap");
            Object smap = mapC.getField("instance").get(null);
            java.lang.reflect.Method load = cls("zombie.iso.CellLoader").getMethod("LoadCellBinaryChunk", cellC, int.class, int.class, chunkC);
            java.lang.reflect.Method register = mapC.getMethod("setSoftResetChunk", chunkC);
            java.lang.reflect.Method getSq = chunkC.getMethod("getGridSquare", int.class, int.class, int.class);
            for (int lx = Math.max(0, chunkX0); lx <= Math.min(31, chunkX1); lx++) {
                for (int ly = Math.max(0, chunkY0); ly <= Math.min(31, chunkY1); ly++) {
                    int wx = cellX * 32 + lx, wy = cellY * 32 + ly;
                    long key = ((long) wx << 32) | (wy & 0xffffffffL);
                    if (!loadedChunks.add(key)) continue;
                    Object chunk = chunkC.getConstructor(cellC).newInstance(harnessCell);
                    field(chunkC, "wx").setInt(chunk, wx);
                    field(chunkC, "wy").setInt(chunk, wy);
                    load.invoke(null, harnessCell, wx, wy, chunk);
                    register.invoke(smap, chunk);
                    try { field(chunkC, "loaded").setBoolean(chunk, true); } catch (Throwable ignored) { }
                    chunks++;
                    for (int z = -8; z <= 8; z++) for (int x = 0; x < 8; x++) for (int y = 0; y < 8; y++) {
                        try { if (getSq.invoke(chunk, x, y, z) != null) squares++; } catch (Throwable ignored) { }
                    }
                }
            }
            return new Object[] { "chunks=" + chunks + " squares=" + squares + " ms=" + (System.currentTimeMillis() - t0), null };
        } catch (Throwable e) {
            return new Object[] { null, describe(e) + " (after " + chunks + " chunks)" };
        } finally {
            if (server != null) try { server.setBoolean(null, prev); } catch (Throwable ignored) { }
        }
    }

    /**
     * A server's broadcasts (INetworkPacket.sendToRelative, sendToAll, ...)
     * iterate GameServer.udpEngine.connections. The harness is a dedicated
     * server with nobody connected: a UdpEngine whose connection list is
     * empty, allocated WITHOUT its constructor (which binds sockets). Every
     * broadcast then reaches zero clients, which is the truth.
     */
    private static void ensureServerNetwork() {
        try {
            Class<?> gs = cls("zombie.network.GameServer");
            java.lang.reflect.Field ue = gs.getField("udpEngine");
            if (ue.get(null) != null) return;
            Class<?> udpC = cls("zombie.core.raknet.UdpEngine");
            java.lang.reflect.Field uf = Class.forName("sun.misc.Unsafe").getDeclaredField("theUnsafe");
            uf.setAccessible(true);
            Object unsafe = uf.get(null);
            Object udp = unsafe.getClass().getMethod("allocateInstance", Class.class).invoke(unsafe, udpC);
            field(udpC, "connections").set(udp, new java.util.ArrayList<>());
            ue.set(null, udp);
        } catch (Throwable t) {
            System.err.println("[engine] could not stand up an empty server network: " + describe(t));
        }
    }

    public static Object[] newCorpse(Object sq, boolean wasZombie) {
        if (!booted || harnessCell == null) return new Object[] { null, "no harness cell (call newSquare first)" };
        try {
            Class<?> sqC = cls("zombie.iso.IsoGridSquare");
            Class<?> bodyC = cls("zombie.iso.objects.IsoDeadBody");
            Object body = bodyC.getConstructor(cls("zombie.iso.IsoCell")).newInstance(harnessCell);
            // The save-load constructor leaves the visual unset; the dying-
            // character constructor gives a human corpse a HumanVisual
            // (IsoDeadBody.java:324), and save() refuses anything else.
            Class<?> hv = cls("zombie.core.skinnedmodel.visual.HumanVisual");
            Object visual = hv.getConstructor(cls("zombie.core.skinnedmodel.visual.IHumanVisual")).newInstance(body);
            field(bodyC, "baseVisual").set(body, visual);
            // A zombie's corpse, the usual cart cargo: vanilla's rot ticker
            // ages it unconditionally, a player corpse only when
            // removePlayerCorpsesOnCorpseRemoval is on (IsoDeadBody.updateBodies).
            if (wasZombie) field(bodyC, "wasZombie").setBoolean(body, true);
            // Every real corpse carries an inventory (the dying constructor
            // hands it the character's, IsoDeadBody.java:327). Vanilla's rot
            // ticker clears it when a body skeletonizes (updateRotting) -- a
            // container-less corpse NPEs there and aborts updateBodies for
            // every body after it.
            bodyC.getMethod("setContainer", cls("zombie.inventory.ItemContainer"))
                .invoke(body, cls("zombie.inventory.ItemContainer").getConstructor().newInstance());
            bodyC.getMethod("setSquare", sqC).invoke(body, sq);
            bodyC.getMethod("setCurrent", sqC).invoke(body, sq);
            float x = ((Number) sqC.getMethod("getX").invoke(sq)).floatValue() + 0.5f;
            float y = ((Number) sqC.getMethod("getY").invoke(sq)).floatValue() + 0.5f;
            bodyC.getMethod("setX", float.class).invoke(body, x);
            bodyC.getMethod("setY", float.class).invoke(body, y);
            sqC.getMethod("addCorpse", bodyC, boolean.class).invoke(sq, body, false);
            return new Object[] { body, null };
        } catch (Throwable t) {
            return new Object[] { null, describe(t) };
        }
    }

    private static boolean worldDictionaryReady;

    /**
     * Items serialize as short registry ids; WorldDictionary maps them back on
     * load. A game builds it at world load from the parsed scripts (and the
     * save's WorldDictionary.bin, absent on a new game -- the harness is
     * always a new game, in the temp Zomboid home). Built once, on demand.
     */
    private static void ensureWorldDictionary() throws Exception {
        if (worldDictionaryReady) return;
        Class<?> wd = cls("zombie.world.WorldDictionary");
        wd.getMethod("setIsNewGame", boolean.class).invoke(null, true);
        wd.getMethod("init").invoke(null);
        worldDictionaryReady = true;
    }

    public static Object[] reloadSquare(Object sq) {
        if (!booted || harnessCell == null) return new Object[] { null, "no harness cell" };
        try {
            ensureWorldDictionary();
            Class<?> sqC = cls("zombie.iso.IsoGridSquare");
            Class<?> cellC = cls("zombie.iso.IsoCell");
            Class<?> chunkC = cls("zombie.iso.IsoChunk");
            int x = ((Number) sqC.getMethod("getX").invoke(sq)).intValue();
            int y = ((Number) sqC.getMethod("getY").invoke(sq)).intValue();
            int z = ((Number) sqC.getMethod("getZ").invoke(sq)).intValue();
            java.nio.ByteBuffer buf = java.nio.ByteBuffer.allocate(4 << 20);
            sqC.getMethod("save", java.nio.ByteBuffer.class, java.io.ObjectOutputStream.class).invoke(sq, buf, null);
            buf.flip();
            Object chunk = sqC.getMethod("getChunk").invoke(sq);
            if (chunk == null) return new Object[] { null, "square has no chunk (not from newSquare?)" };
            Object fresh = sqC.getMethod("getNew", cellC, cls("zombie.iso.SliceY"), int.class, int.class, int.class)
                .invoke(null, harnessCell, null, x, y, z);
            chunkC.getMethod("setSquare", int.class, int.class, int.class, sqC).invoke(chunk, x % 8, y % 8, z, fresh);
            int worldVersion = cls("zombie.iso.IsoWorld").getField("WorldVersion").getInt(null);
            sqC.getMethod("load", java.nio.ByteBuffer.class, int.class).invoke(fresh, buf, worldVersion);
            return new Object[] { fresh, null };
        } catch (Throwable t) {
            return new Object[] { null, describe(t) };
        }
    }

    private static Object savedRand = null;   // seedRand's stash of the engine's own RNG

    private static java.lang.reflect.Field findField(Class<?> c, String name) throws NoSuchFieldException {
        for (Class<?> k = c; k != null; k = k.getSuperclass()) {
            try {
                java.lang.reflect.Field f = k.getDeclaredField(name);
                f.setAccessible(true);
                return f;
            } catch (NoSuchFieldException ignored) { }
        }
        throw new NoSuchFieldException(c.getName() + "." + name);
    }

    // describe() plus the first engine frames: where a hit died, and who called it
    private static String describeDeep(Throwable t) {
        Throwable root = t;
        while (root.getCause() != null) root = root.getCause();
        StringBuilder sb = new StringBuilder(root.getClass().getSimpleName() + ": " + root.getMessage());
        int k = 0;
        for (StackTraceElement el : root.getStackTrace()) {
            if (el.getClassName().startsWith("zombie.")) { sb.append(k == 0 ? " @ " : " < ").append(el.getClassName().substring(el.getClassName().lastIndexOf('.') + 1)).append(".").append(el.getMethodName()).append(":").append(el.getLineNumber()); if (++k >= 8) break; }
        }
        return sb.toString();
    }

    private static String describe(Throwable t) {
        Throwable root = t;
        while (root.getCause() != null) root = root.getCause();
        String at = "";
        for (StackTraceElement el : root.getStackTrace()) {
            if (el.getClassName().startsWith("zombie.")) { at = " @ " + el; break; }
        }
        return root.getClass().getSimpleName() + ": " + root.getMessage() + at;
    }

    /**
     * A real IsoZombie (the event lab's subject for OnHitZombie, OnZombieDead,
     * OnWeaponHitCharacter...), built like newPlayer: GameServer.server on so
     * the constructor skips the client-only animation variable callbacks
     * (IsoZombie.java:551), the appearance pools a session would have filled,
     * the XML noise swallowed. Placed on `sq` when given (a real map square).
     */
    public static Object[] newZombie(Object sq) {
        if (!booted) return new Object[] { null, "engine not booted" };
        java.lang.reflect.Field server = null;
        boolean prev = false;
        PrintStream realOut = System.out, realErr = System.err;
        java.io.ByteArrayOutputStream sink = new java.io.ByteArrayOutputStream();
        PrintStream quiet = new PrintStream(sink, true);
        System.setOut(quiet); System.setErr(quiet);
        try {
            server = cls("zombie.network.GameServer").getField("server");
            prev = server.getBoolean(null);
            server.setBoolean(null, true);
            Class<?> cell = cls("zombie.iso.IsoCell");
            Class<?> desc = cls("zombie.characters.SurvivorDesc");
            Object grey = cls("zombie.core.ImmutableColor").getConstructor(float.class, float.class, float.class, float.class)
                .newInstance(0.5f, 0.5f, 0.5f, 1.0f);
            @SuppressWarnings("unchecked")
            java.util.List<Object> hair = (java.util.List<Object>) desc.getField("HairCommonColors").get(null);
            if (hair.isEmpty()) hair.add(grey);
            // Name pools (SurvivorFactory.randomName): a session fills them
            // from the SurvivorNames strings; a zombie draws a name too.
            Class<?> sf = cls("zombie.characters.SurvivorFactory");
            for (String pool : new String[] { "FemaleForenames", "MaleForenames", "Surnames" }) {
                @SuppressWarnings("unchecked")
                java.util.List<Object> list = (java.util.List<Object>) sf.getField(pool).get(null);
                if (list.isEmpty()) list.add(pool.equals("Surnames") ? "Doe" : "Pat");
            }
            for (String pop : new String[] { "BeardStyles", "HairStyles", "OutfitManager" }) {
                Class<?> c = cls("zombie.core.skinnedmodel.population." + pop);
                if (c.getField("instance").get(null) == null) c.getMethod("init").invoke(null);
            }
            Class<?> ptm = cls("zombie.core.skinnedmodel.population.PopTemplateManager");
            Object ptmInst = ptm.getField("instance").get(null);
            if (((java.util.List<?>) ptm.getField("maleSkins").get(ptmInst)).isEmpty()) ptm.getMethod("init").invoke(ptmInst);
            Class<?> zC = cls("zombie.characters.IsoZombie");
            Object cellObj = sq != null ? cls("zombie.iso.IsoGridSquare").getMethod("getCell").invoke(sq) : harnessCell;
            Object z = zC.getConstructor(cell).newInstance(cellObj);
            if (sq != null) {
                Class<?> sqC = cls("zombie.iso.IsoGridSquare");
                float x = ((Number) sqC.getMethod("getX").invoke(sq)).floatValue() + 0.5f;
                float y = ((Number) sqC.getMethod("getY").invoke(sq)).floatValue() + 0.5f;
                float zz = ((Number) sqC.getMethod("getZ").invoke(sq)).floatValue();
                zC.getMethod("setX", float.class).invoke(z, x);
                zC.getMethod("setY", float.class).invoke(z, y);
                zC.getMethod("setZ", float.class).invoke(z, zz);
                zC.getMethod("setCurrent", sqC).invoke(z, sq);
            }
            return new Object[] { z, null };
        } catch (Throwable t) {
            return new Object[] { null, describe(t) };
        } finally {
            try { if (server != null) server.setBoolean(null, prev); } catch (Throwable ignored) {}
            System.setOut(realOut); System.setErr(realErr);
        }
    }

    public static Object[] newPlayer() {
        if (!booted) return new Object[] { null, "engine not booted" };
        java.lang.reflect.Field server = null;
        boolean prev = false;
        // Construction parses the clothing and AnimSet XML and logs a line per
        // file it can't fully resolve without a renderer -- ~3500 lines, all
        // of it unrelated to what a test is checking. Swallow it and say so
        // once, so a test's own output stays readable.
        PrintStream realOut = System.out, realErr = System.err;
        java.io.ByteArrayOutputStream sink = new java.io.ByteArrayOutputStream();
        PrintStream quiet = new PrintStream(sink, true);
        System.setOut(quiet); System.setErr(quiet);
        try {
            server = cls("zombie.network.GameServer").getField("server");
            prev = server.getBoolean(null);
            server.setBoolean(null, true);
            Class<?> cell = cls("zombie.iso.IsoCell");
            Class<?> desc = cls("zombie.characters.SurvivorDesc");
            // Appearance pools a game session fills before any character
            // exists; empty, SurvivorDesc's random hair/trouser pick indexes
            // into nothing. One neutral colour each -- appearance is not what a
            // harness character is for.
            Class<?> immutable = cls("zombie.core.ImmutableColor");
            Object grey = immutable.getConstructor(float.class, float.class, float.class, float.class)
                .newInstance(0.5f, 0.5f, 0.5f, 1.0f);
            for (String pool : new String[] { "HairCommonColors" }) {
                @SuppressWarnings("unchecked")
                java.util.List<Object> list = (java.util.List<Object>) desc.getField(pool).get(null);
                if (list.isEmpty()) list.add(grey);
            }
            // The appearance data the game loads at startup (Core.java:3938-3940,
            // IngameState.java:1060): plain XML under media/, no rendering.
            for (String pop : new String[] { "BeardStyles", "HairStyles", "OutfitManager" }) {
                Class<?> c = cls("zombie.core.skinnedmodel.population." + pop);
                if (c.getField("instance").get(null) == null) c.getMethod("init").invoke(null);
            }
            // Skin texture NAME lists (PopTemplateManager.init: string adds only).
            // The game calls it from ModelManager, which the harness never
            // starts; the lists themselves touch no textures.
            Class<?> ptm = cls("zombie.core.skinnedmodel.population.PopTemplateManager");
            Object ptmInst = ptm.getField("instance").get(null);
            if (((java.util.List<?>) ptm.getField("maleSkins").get(ptmInst)).isEmpty()) {
                ptm.getMethod("init").invoke(ptmInst);
            }
            Object p = cls("zombie.characters.IsoPlayer")
                .getConstructor(cell, desc, int.class, int.class, int.class)
                .newInstance(null, null, 0, 0, 0);
            return new Object[] { p, null };
        } catch (Throwable t) {
            Throwable root = t;
            while (root.getCause() != null) root = root.getCause();
            String at = "";
            for (StackTraceElement el : root.getStackTrace()) {
                if (el.getClassName().startsWith("zombie.")) { at = " @ " + el; break; }
            }
            return new Object[] { null, root.getClass().getSimpleName() + ": " + root.getMessage() + at };
        } finally {
            try { if (server != null) server.setBoolean(null, prev); } catch (Throwable ignored) {}
            System.setOut(realOut); System.setErr(realErr);
            long lines = sink.toString().lines().count();
            if (lines > 0)
                realOut.println("[engine] newPlayer: suppressed " + lines + " lines of appearance/anim XML load output");
        }
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

    // ------------------------------------------------------------------
    // SousVide MP role (docs/sousvide-mp.md)
    // ------------------------------------------------------------------
    /** "server" | "client" | null (the single-VM bench). */
    private static String role;

    /** A server side holds GameServer.server for the life of the VM, as a
     *  dedicated server does: server-side engine paths take the server
     *  branch (and ServerMap answers square lookups). Tools that flip it
     *  around a call (PZEngine.setServer) restore TRUE afterwards.
     *  GameClient.client is NOT set on a client side yet: engine paths
     *  under it reach for a live connection the bench does not have
     *  (phase 3 of the MP design gives them one). */
    public static void setRole(String r) {
        role = r;
        if (!"server".equals(r) || loader == null) return;
        try { cls("zombie.network.GameServer").getField("server").setBoolean(null, true); }
        catch (Throwable t) { System.out.println("[engine] setRole server: " + describe(t)); }
    }

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
