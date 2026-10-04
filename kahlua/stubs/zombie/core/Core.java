package zombie.core;

/**
 * Stub for PZ's Core. Kahlua's debug assertions read `Core.debug`; that was
 * the whole stub until engine mode (EngineBridge) started running REAL
 * script-loading and item-creation code, which reads a little more:
 *
 *   IS_DEV                          Book statics gate dev-only logging on it
 *   getInstance() + poisonous*      InventoryItemFactory.CreateItem checks
 *                                   which berry/mushroom is this world's
 *                                   poisonous one; null = "not decided",
 *                                   which is also what a fresh game has
 *                                   before world creation.
 *
 * Kept as a stub on purpose: the real Core's static surface reaches
 * rendering/GL configuration the harness must never touch.
 */
public class Core {
    public static boolean debug = false;
    public static boolean IS_DEV = false;

    // 42.21 added `&& !Core.tutorial` to InventoryItem.setCondition, which the
    // item factory runs -- so every real item minted offline reads this now.
    // false is the real default and the one tests want: during the tutorial the
    // engine refuses condition DECREASES, and a harness that silently did the
    // same would hide every wear/degradation bug.
    public static boolean tutorial = false;
    // Character construction (PZEngine.newPlayer, 2026-10-04 spike). Real
    // defaults except soundDisabled: the harness is headless, so true -- the
    // same branch the dedicated server takes (dummy CharacterSoundEmitter).
    public static int tileScale = 2;
    public static String gameMode = "Sandbox";
    public static boolean soundDisabled = true;

    private static final Core instance = new Core();

    public static Core getInstance() {
        return instance;
    }

    private String poisonousBerry = null;
    private String poisonousMushroom = null;

    public String getPoisonousBerry() { return poisonousBerry; }
    public void setPoisonousBerry(String s) { poisonousBerry = s; }
    public String getPoisonousMushroom() { return poisonousMushroom; }
    public void setPoisonousMushroom(String s) { poisonousMushroom = s; }

    // ZomboidFileSystem.getAllModFolders wants the Zomboid home dir. The
    // harness has no game home; a temp dir means "no workshop, no user mods",
    // which is exactly right — the mod under test is fed to the engine
    // explicitly by EngineBridge, not discovered.
    public static String getMyDocumentFolder() {
        return System.getProperty("java.io.tmpdir") + java.io.File.separator + "pztest-zomboid";
    }

    // Translator.getLanguage asks Core which language the player picked.
    public String getOptionLanguageName() { return "EN"; }

    // ZomboidFileSystem.getModVersionDirName reads this to pick which versioned
    // directory of a mod to load (our own mods ship common/ + 42.0/), and mods
    // read it from Lua to gate on build. It must be the version of the INSTALLED
    // game or the harness lies about the runtime it models -- so it is not a
    // constant here: build_runtime_jar.py reads it out of the real Core.class
    // and bakes it into the jar next to this stub, which means it is re-derived
    // every time the runtime jar is rebuilt for a new patch.
    private static final String VERSION_RESOURCE = "/zombie/core/pz-game-version.txt";

    private static final GameVersion gameVersion = readBakedGameVersion();

    private static GameVersion readBakedGameVersion() {
        try (java.io.InputStream in = Core.class.getResourceAsStream(VERSION_RESOURCE)) {
            if (in != null) {
                // Parsed here, NOT via GameVersion.parse: that calls
                // zombie.core.math.PZMath, which the runtime jar doesn't carry,
                // so outside engine mode StubbingClassLoader hands it an empty
                // synthesized PZMath, parse throws, and every non-engine suite
                // reported 42.0 under a "resource missing" warning that was
                // false. The constructor touches nothing else.
                String s = new String(in.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8).trim();
                java.util.regex.Matcher m = java.util.regex.Pattern.compile("(\\d+)\\.(\\d+)(.*)").matcher(s);
                if (m.matches())
                    return new GameVersion(Integer.parseInt(m.group(1)), Integer.parseInt(m.group(2)), m.group(3).trim());
                System.err.println("[pztest] WARNING: " + VERSION_RESOURCE + " is unparseable ('" + s + "') -- reporting 42.0.");
                return new GameVersion(42, 0, "");
            }
        } catch (Throwable t) {
            System.err.println("[pztest] WARNING: reading " + VERSION_RESOURCE + " failed: " + t);
            return new GameVersion(42, 0, "");
        }
        // Reached only if the jar was built without the bake step. Deliberately
        // NOT a plausible-looking version: 42.0 makes getModVersionDirName skip
        // every versioned mod dir, which fails visibly, where a stale-but-
        // plausible number would quietly load the wrong manifest.
        System.err.println("[pztest] WARNING: " + VERSION_RESOURCE + " missing from "
            + "kahlua-runtime.jar -- reporting 42.0. Rebuild with build_runtime_jar.py.");
        return new GameVersion(42, 0, "");
    }

    public GameVersion getGameVersion() { return gameVersion; }

    public String getVersionNumber() { return gameVersion.toString(); }
}
