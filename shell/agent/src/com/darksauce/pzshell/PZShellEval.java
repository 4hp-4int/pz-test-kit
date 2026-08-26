package com.darksauce.pzshell;

import me.zed_0xff.zombie_buddy.Exposer;
import se.krka.kahlua.integration.annotations.LuaMethod;
import se.krka.kahlua.luaj.compiler.LuaCompiler;
import se.krka.kahlua.vm.LuaClosure;
import zombie.Lua.LuaManager;

/**
 * Gives pz-shell back the one thing PZ's 2026-08 security patch took away:
 * turning a string into a callable Lua function.
 *
 * WHAT THE PATCH ACTUALLY DID. It did not remove the compiler. Checked against
 * the patched jar (buildid 24909800): se.krka.kahlua.luaj.compiler.LuaCompiler
 * is byte-identical to the pre-patch build, static initialiser and all, and its
 * loadstring/loadis entry points are still public static -- PZ itself calls
 * loadis every time it loads a .lua file off disk (LuaManager.java:1367). What
 * changed is that LuaManager no longer CALLS LuaCompiler.register(), which is
 * what used to install the `loadstring` and `loadstream` globals. Its sibling
 * registrations (LuaEventManager, LuaHookManager, CoopMaster) still fire. So
 * the machinery is intact; only the Lua-side binding was withdrawn.
 *
 * This re-exposes that binding, and nothing else. It is not a reimplementation:
 * same compiler, same environment table, same resulting LuaClosure that
 * loadstring returned.
 *
 * WHY LuaManager.env. That is the environment `platform.newEnvironment()`
 * produced at boot (LuaManager.java:1092) -- the mod VM's own global table. A
 * chunk compiled against it sees VorpallySauced, SaucePalette and everything
 * else exactly as an eval'd probe always did. Compiling against a fresh table
 * would produce a closure that can see nothing, which is worse than useless for
 * a debugging shell.
 *
 * DEV TOOLING ONLY. This is arbitrary code execution by design -- it is the
 * whole point of a REPL -- and it is why the mod that calls it stays behind its
 * gate file and never goes near a production server. It ships in pz-test-kit,
 * not in any released mod.
 */
@Exposer.LuaClass
public class PZShellEval {

    public static final String VERSION = "1.0.0";

    /** Last compile error, or null. Kahlua multi-return from Java is fiddlier
     *  than it is worth, so the message comes back through a second call
     *  rather than as a second return value. Set on every loadchunk. */
    private static volatile String lastError = null;

    /**
     * Compile `code` into a callable Lua function in the mod VM's environment.
     * Returns nil on a compile error, mirroring the shape loadstring had, so
     * the Lua side's `if not fn then` handling is unchanged.
     */
    @LuaMethod(name = "PZShell_loadchunk", global = true)
    public static LuaClosure loadchunk(String code, String chunkname) {
        lastError = null;
        if (code == null) {
            lastError = "nil code";
            return null;
        }
        try {
            return LuaCompiler.loadstring(
                code, chunkname == null ? "=pz-shell" : chunkname, LuaManager.env);
        } catch (Throwable t) {
            // Throwable, not Exception: a malformed chunk can surface as an
            // Error out of the compiler, and a shell that dies on bad input is
            // a shell you stop trusting.
            lastError = String.valueOf(t.getMessage());
            if (lastError == null) lastError = t.getClass().getName();
            return null;
        }
    }

    /** The compile error from the most recent loadchunk, or nil. */
    @LuaMethod(name = "PZShell_lastError", global = true)
    public static String lastError() {
        return lastError;
    }

    /** Liveness probe: confirms the agent attached and is reachable from Lua. */
    @LuaMethod(name = "PZShell_agentVersion", global = true)
    public static String agentVersion() {
        return VERSION;
    }

    /**
     * Confirms the environment we compile against is the one the mods live in.
     * Worth asserting once rather than assuming: if PZ ever ran the server VM
     * in a separate environment, every probe would silently see an empty world.
     */
    @LuaMethod(name = "PZShell_envIsShared", global = true)
    public static boolean envIsShared() {
        try {
            return LuaManager.env != null && LuaManager.env.rawget("Events") != null;
        } catch (Throwable t) {
            return false;
        }
    }
}
