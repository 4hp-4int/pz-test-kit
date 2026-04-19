package zombie.core.logger;

/**
 * Stub for PZ's ExceptionLogger. Kahlua's KahluaThread calls
 * ExceptionLogger.logException() when a Lua error bubbles through
 * certain paths. Without this class on the classpath, the JVM throws
 * NoClassDefFoundError and subsequent catches fail.
 *
 * Real PZ logs to a crash file; for tests we just print to stderr.
 */
public class ExceptionLogger {
    public static void logException(Throwable t) {
        System.err.println("[PZTestKit] Lua error: " + t.getMessage());
    }

    public static void logException(Throwable t, String context) {
        System.err.println("[PZTestKit] Lua error in " + context + ": " + t.getMessage());
    }
}
