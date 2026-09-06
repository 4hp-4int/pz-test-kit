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

    // Engine mode (EngineBridge): real script-load code paths read
    // LuaManager.platform to build Kahlua tables (VehicleScript.LoadTable is
    // the first to trip it). A real J2SEPlatform is safe headless — it is
    // just a table factory — and keeping the stub, rather than letting the
    // real LuaManager in, keeps the rest of the real class's heavy static
    // surface (env, exposer, event wiring) out of the harness.
    public static se.krka.kahlua.j2se.J2SEPlatform platform = new se.krka.kahlua.j2se.J2SEPlatform();

    public static StackTraceElement[] getLuaStackStrace(Coroutine c) {
        return new StackTraceElement[0];
    }

    // Engine mode: the real debug/exception pipeline decorates Java stack
    // traces with Lua frames. No Lua frames here — identity pass-through.
    public static StackTraceElement[] insertAnyLuaTraceElements(StackTraceElement[] elements) {
        return elements;
    }
}
