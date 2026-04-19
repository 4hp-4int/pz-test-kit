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
    public static Object debugcaller = null;

    public static StackTraceElement[] getLuaStackStrace(Coroutine c) {
        return new StackTraceElement[0];
    }
}
