/**
 * Minimal Kahlua Platform — no PZ game dependencies.
 * Uses the 3 stub classes (Core, DebugOptions, BooleanDebugOption)
 * to satisfy KahluaTableImpl's debug assertions.
 */

import se.krka.kahlua.vm.*;
import se.krka.kahlua.j2se.KahluaTableImpl;
import se.krka.kahlua.j2se.MathLib;
import se.krka.kahlua.stdlib.*;
import se.krka.kahlua.luaj.compiler.LuaCompiler;

import java.io.*;
import java.nio.file.*;
import java.util.HashMap;

public class TestPlatform implements Platform {

    @Override
    public double pow(double x, double y) {
        return Math.pow(x, y);
    }

    @Override
    public KahluaTable newTable() {
        return new KahluaTableImpl(new HashMap<>());
    }

    @Override
    public KahluaTable newEnvironment() {
        KahluaTable env = newTable();
        setupEnvironment(env);
        return env;
    }

    @Override
    public void setupEnvironment(KahluaTable env) {
        env.rawset("_G", env);
        env.rawset("_VERSION", "Lua 5.1");

        MathLib.register(this, env);
        BaseLib.register(env);
        // The game's platform (J2SEPlatform.setupEnvironment) registers these
        // too: newrandom() and newarray(). Missing, any mod calling newrandom()
        // died at load (Gunworks' ItemSpawnCore, and every Guns of Marz file
        // behind it, found by the lua_mods smoke test 2026-10-06).
        RandomLib.register(this, env);
        se.krka.kahlua.test.UserdataArray.register(this, env);
        // 42.20 print routing: BaseLib.print writes to KahluaThread.getOut() (the
        // per-thread stream) AND the static callback. The kit passes System.out to
        // every KahluaThread constructor (null would route to PZ's DebugLogStream,
        // a dead end headless — the silent-print regression of the 42.20 jar
        // rebuild). The old setPrintCallback wiring is intentionally GONE: with
        // both bound, every line printed twice.
        StringLib.register(this, env);
        CoroutineLib.register(this, env);
        OsLib.register(this, env);
        TableLib.register(this, env);
        LuaCompiler.register(env);

        try {
            loadLuaLib(env, "stdlib.lua");
            loadLuaLib(env, "serialize.lua");
        } catch (Exception e) {
            throw new RuntimeException("Failed to load Kahlua stdlib: " + e.getMessage(), e);
        }
    }

    private void loadLuaLib(KahluaTable env, String filename) throws Exception {
        Path path = Path.of(filename);
        if (!Files.exists(path)) {
            throw new FileNotFoundException(filename + " not found in " + Path.of(".").toAbsolutePath());
        }
        String source = Files.readString(path);
        LuaClosure closure = LuaCompiler.loadstring(source, filename, env);
        KahluaThread thread = new KahluaThread(System.out, this, env);
        thread.debugOwnerThread = Thread.currentThread();
        thread.pcall(closure, new Object[0]);
    }
}
