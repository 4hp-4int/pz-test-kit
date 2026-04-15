package zombie.debug;
public class DebugOptions {
    public static DebugOptions instance = new DebugOptions();
    public Checks checks = new Checks();
    public static void init() {}

    public static class Checks {
        public BooleanDebugOption objectPoolContains = new BooleanDebugOption();
        public BooleanDebugOption kahluaTableImplRawset = new BooleanDebugOption();
        public boolean isDebugOptionEnabled(String name) { return false; }
    }
}
