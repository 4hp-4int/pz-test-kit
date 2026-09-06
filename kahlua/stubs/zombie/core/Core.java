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
}
