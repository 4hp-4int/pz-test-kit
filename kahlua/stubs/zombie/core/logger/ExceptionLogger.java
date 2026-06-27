package zombie.core.logger;

/**
 * Stub for PZ's ExceptionLogger. Kahlua's KahluaThread calls
 * ExceptionLogger.logException() when a Lua error bubbles through
 * certain paths. Without this class on the classpath, the JVM throws
 * NoClassDefFoundError and subsequent catches fail.
 *
 * IMPORTANT: Kahlua routes errors through here as they UNWIND — including
 * errors that an enclosing pcall then catches (the "...in pcall" messages).
 * Mods are pcall-guarded by design (headless-safe providers deliberately let a
 * missing-Java-API call error so pcall swallows it and the source yields
 * nothing), so logging every such caught error floods a perfectly green run
 * with hundreds of harmless lines. Test FAILURES are reported by the runner on
 * its own path, not here — so this side-channel is quiet by default and only
 * prints when explicitly debugging (env PZTEST_VERBOSE or -Dpztest.verbose).
 */
public class ExceptionLogger {
    private static final boolean VERBOSE =
        System.getenv("PZTEST_VERBOSE") != null || System.getProperty("pztest.verbose") != null;

    public static void logException(Throwable t) {
        if (VERBOSE) System.err.println("[PZTestKit] Lua error: " + t.getMessage());
    }

    public static void logException(Throwable t, String context) {
        if (VERBOSE) System.err.println("[PZTestKit] Lua error in " + context + ": " + t.getMessage());
    }
}
