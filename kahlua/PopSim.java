import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Semaphore;

/**
 * The game's own zombie population (PZPopMan64.dll) in a SousVide VM.
 *
 * Zombie population in B42 is native code behind thin Java wrappers
 * (zombie.popman.ZombiePopulationManager, zombie.MapCollisionData). This drives
 * those natives directly, the way the game does on a dedicated server, minus
 * the parts that need a live IsoCell:
 *
 *   init      MapCollisionData.init (:97) and ZombiePopulationManager.init
 *             (:296) + onConfigReloaded (:325), with the map's real per-chunk
 *             intensity (LotHeader.getZombieIntensityForChunk) and a TEMP save
 *             directory (Core.noSave as well): nothing is ever written to a
 *             real save.
 *   worker    MapCollisionData's MCDThread runs MapCollisionData.n_update and
 *             ZombiePopulationManager.n_updateThread; here a daemon thread does
 *             the same, one pass per main update, and the main side waits for it
 *             (so a step is complete when step() returns).
 *   area      n_loadChunk per chunk + n_loadedAreas (chunk units), as a player's
 *             chunk map does (LoadedAreas.set, :55): zombies are made real inside it.
 *   step      n_updateMain(multiplier, worldAgeHours) (:551). The game calls it
 *             every frame; here SUB_STEPS calls per game minute, multiplier
 *             GameTime units per sub-step (48 a real second at 1x, a game minute
 *             = 2.5 real seconds at the default one-hour day: 120 a game minute).
 *   take      n_getAddZombieCount / n_getAddZombieData (:553-590): the zombies
 *             the game would now create (x, y, z, facing, descriptor, state,
 *             path target or standing, persistent id). They are then REAL: kept
 *             here and reported back each step through n_updateRealZombies
 *             (:541), until kill() releases them (IsoZombie death,
 *             ZombiePopulationManager.releaseZombie :174).
 *   sound     n_worldSound (:501), radius already multiplied by hearing.
 *   radar     n_requestRadarData / n_getRadarZombieData (:605-615).
 *
 * One population per JVM: the library's state is process-global.
 */
public final class PopSim {
    private PopSim() { }

    public static final int SUB_STEPS = 4;
    public static final float MULT_PER_GAME_MINUTE = 120f;

    private static boolean ready;
    private static String error;
    private static Path tempDir;
    private static Method mcdUpdate, popUpdateThread, updateMain, addCount, addData, loadChunk, loadedAreas,
        worldSound, releaseZombie, updateReal, reqRadar, hasRadar, getRadar, popHasData, mcdHasData, addZombie, popShouldWait, mcdShouldWait;
    private static Thread worker;
    private static final Semaphore go = new Semaphore(0), done = new Semaphore(0);
    private static volatile Throwable workerError;
    private static final int MAX_PASSES = 2000;
    private static volatile int lastPasses;
    private static double worldAgeHours = 7.0;
    private static int minX, minY, width, height;
    private static final java.util.Set<Long> loaded = new java.util.HashSet<>();
    private static int[] area;   // chunk x, y, w, h
    // real zombies handed out and not yet killed: id -> { x, y, z, state, dir, descriptor }
    private static final Map<Integer, float[]> real = new LinkedHashMap<>();
    private static final List<Map<String, Object>> pending = new ArrayList<>();
    private static int made, killed;
    private static int zombiesOption, distributionOption;

    // THE VIRTUAL CLOCK (native/PopClock.java): the library's three time imports
    // answer simulated time, so stepping game time is what it sees. Without it
    // (clockError set) the library runs on the wall clock and sounds and cell
    // loads race the fast-forward.
    private static Method clockAdvance;
    private static String clockError;
    public static final double SECONDS_PER_GAME_MINUTE = 2.5;   // the default one-hour day

    private static String installClock(Path pzDir) {
        try {
            Path src = null;
            for (Path c : new Path[] { Path.of(System.getProperty("user.dir"), "native", "PopClock.java"),
                    Path.of(System.getProperty("user.dir"), "kahlua", "native", "PopClock.java") })
                if (Files.isRegularFile(c)) { src = c; break; }
            if (src == null) {
                Path here = Path.of(PopSim.class.getProtectionDomain().getCodeSource().getLocation().toURI());
                for (Path d = here; d != null; d = d.getParent()) {
                    Path c = d.resolve("native").resolve("PopClock.java");
                    if (Files.isRegularFile(c)) { src = c; break; }
                }
            }
            if (src == null) return "native/PopClock.java not found";
            javax.tools.JavaCompiler javac = javax.tools.ToolProvider.getSystemJavaCompiler();
            if (javac == null) return "no Java compiler (run on a JDK)";
            Path out = Files.createDirectories(tempDir.resolve("clock"));
            java.io.ByteArrayOutputStream errs = new java.io.ByteArrayOutputStream();
            int rc = javac.run(null, null, errs, "-nowarn", "-cp", pzDir.resolve("projectzomboid.jar").toString(),
                "-d", out.toString(), src.toString());
            if (rc != 0) return "PopClock did not compile: " + errs;
            ClassLoader cl = new java.net.URLClassLoader(new java.net.URL[] { out.toUri().toURL() }, loader());
            Class<?> clock = Class.forName("PopClock", true, cl);
            String err = (String) clock.getMethod("install", String.class).invoke(null, "PZPopMan64.dll");
            if (err != null) return err;
            clockAdvance = clock.getMethod("advance", long.class);
            return null;
        } catch (Throwable t) { return describe(t); }
    }

    private static void advanceClock(double seconds) throws Exception {
        if (clockAdvance != null) clockAdvance.invoke(null, (long) (seconds * 1e9));
    }

    private static ClassLoader loader() { return PopSim.class.getClassLoader(); }
    private static Class<?> cls(String n) throws ClassNotFoundException { return Class.forName(n, true, loader()); }
    private static Method nat(Class<?> c, String name, int params) {
        for (Method m : c.getDeclaredMethods())
            if (m.getName().equals(name) && m.getParameterCount() == params) { m.setAccessible(true); return m; }
        throw new IllegalStateException("no native " + c.getSimpleName() + "." + name + "/" + params);
    }
    private static String describe(Throwable t) {
        while (t instanceof java.lang.reflect.InvocationTargetException && t.getCause() != null) t = t.getCause();
        return t.getClass().getSimpleName() + ": " + t.getMessage();
    }

    public static boolean isReady() { return ready; }
    public static String getError() { return error; }

    /** Boots the population over the loaded world. Returns null or an error. */
    public static synchronized String init(Path pzDir) {
        if (ready) return null;
        if (error != null) return error;
        try {
            Class<?> worldC = cls("zombie.iso.IsoWorld");
            Object world = worldC.getField("instance").get(null);
            Object grid = worldC.getMethod("getMetaGrid").invoke(world);
            Class<?> gridC = grid.getClass();
            minX = gridC.getField("minX").getInt(grid);
            minY = gridC.getField("minY").getInt(grid);
            width = (int) gridC.getMethod("getWidth").invoke(grid);
            height = (int) gridC.getMethod("getHeight").invoke(grid);
            if (width <= 0 || height <= 0) return error = "no world: call PZEngine.loadWorld first";
            if (pzDir == null) return error = "no PZ install";
            System.load(pzDir.resolve("PZPopMan64.dll").toString());
            tempDir = Files.createTempDirectory("sousvide-popman");
            clockError = System.getProperty("popsim.realclock") != null ? "real clock (popsim.realclock)" : installClock(pzDir);

            Path save = Files.createDirectories(tempDir.resolve("save"));
            Path cache = Files.createDirectories(tempDir.resolve("cache"));
            Class<?> mcd = cls("zombie.MapCollisionData");
            Class<?> pm = cls("zombie.popman.ZombiePopulationManager");
            Method gsS = null, gsB = null, gsI = null;
            for (Method m : mcd.getDeclaredMethods()) if (m.getName().equals("n_setGameState")) {
                m.setAccessible(true);
                Class<?> p = m.getParameterTypes()[1];
                if (p == String.class) gsS = m; else if (p == boolean.class) gsB = m; else if (p == int.class) gsI = m;
            }
            Object sbo = cls("zombie.SandboxOptions").getField("instance").get(null);
            gsS.invoke(null, "Core.GameMode", "Sandbox");
            gsS.invoke(null, "Core.GameSaveWorld", "sousvide-popman");
            gsB.invoke(null, "Core.bLastStand", false);
            gsB.invoke(null, "Core.noSave", true);
            gsS.invoke(null, "GameWindow.CacheDir", cache.toString());
            gsS.invoke(null, "GameWindow.GameModeCacheDir", cache + java.io.File.separator);
            gsS.invoke(null, "GameWindow.SaveDir", save.toString());
            distributionOption = intOption(sbo, "distribution", 1);
            zombiesOption = intOption(sbo, "zombies", 4);
            gsI.invoke(null, "SandboxOptions.Distribution", distributionOption);
            gsI.invoke(null, "SandboxOptions.Zombies", zombiesOption);
            gsS.invoke(null, "SavefileNaming.SUBDIR_CHUNKDATA", "chunkdata");
            gsS.invoke(null, "SavefileNaming.SUBDIR_ZPOP", "zpop");
            gsB.invoke(null, "World.ZombiesDisabled", false);
            gsB.invoke(null, "PAUSED", true);

            nat(mcd, "n_initMetaGrid", 4).invoke(null, minX, minY, width, height);
            Class<?> lh = cls("zombie.iso.LotHeader");
            Method intensity = lh.getMethod("getZombieIntensityForChunk", lh, int.class, int.class);
            Method cellData = gridC.getMethod("getCellData", int.class, int.class);
            List<?> mapFiles = (List<?>) cls("zombie.iso.IsoLot").getField("MapFiles").get(null);
            Method initCell = nat(mcd, "n_initMetaCell", 3), initChunk = nat(mcd, "n_initMetaChunk", 5);
            for (int cy = minY; cy < minY + height; cy++) for (int cx = minX; cx < minX + width; cx++) {
                Object mc = cellData.invoke(grid, cx, cy);
                for (Object mf : mapFiles) {
                    Map<?, ?> names = (Map<?, ?>) mf.getClass().getField("infoFileNames").get(mf);
                    initCell.invoke(null, cx, cy, (String) names.get("chunkdata_" + cx + "_" + cy + ".bin"));
                }
                if (mc == null) continue;
                Object info = mc.getClass().getField("info").get(mc);
                for (int wy = 0; wy < 32; wy++) for (int wx = 0; wx < 32; wx++)
                    initChunk.invoke(null, cx, cy, wx, wy, Math.max(0, (int) intensity.invoke(null, info, wx, wy)));
            }
            nat(mcd, "n_init", 4).invoke(null, minX, minY, width, height);

            nat(pm, "n_init", 6).invoke(null, false, true, minX, minY, width, height);
            configure(pm, sbo);
            String[] outfits;
            try {
                Object po = cls("zombie.PersistentOutfits").getField("instance").get(null);
                outfits = ((List<?>) po.getClass().getMethod("getOutfitNames").invoke(po)).stream()
                    .map(o -> o.toString().toLowerCase()).toArray(String[]::new);
            } catch (Throwable t) { outfits = new String[0]; }
            nat(pm, "n_setOutfitNames", 1).invoke(null, (Object) outfits);
            nat(pm, "n_setSpawnOrigins", 1).invoke(null, (Object) new int[0]);

            mcdUpdate = nat(mcd, "n_update", 0);
            popHasData = nat(pm, "n_hasDataForThread", 0);
            addZombie = nat(pm, "n_addZombie", 9);
            popShouldWait = nat(pm, "n_shouldWait", 0);
            mcdShouldWait = nat(mcd, "n_shouldWait", 0);
            mcdHasData = nat(mcd, "n_hasDataForThread", 0);
            popUpdateThread = nat(pm, "n_updateThread", 0);
            updateMain = nat(pm, "n_updateMain", 2);
            addCount = nat(pm, "n_getAddZombieCount", 0);
            addData = nat(pm, "n_getAddZombieData", 2);
            loadChunk = nat(pm, "n_loadChunk", 3);
            loadedAreas = nat(pm, "n_loadedAreas", 3);
            worldSound = nat(pm, "n_worldSound", 4);
            releaseZombie = nat(pm, "n_releaseZombie", 1);
            updateReal = nat(pm, "n_updateRealZombies", 3);
            reqRadar = nat(pm, "n_requestRadarData", 0);
            hasRadar = nat(pm, "n_hasRadarData", 0);
            getRadar = nat(pm, "n_getRadarZombieData", 1);
            gsB.invoke(null, "PAUSED", false);

            worker = new Thread(() -> {
                try {
                    while (true) {
                        go.acquire();
                        // MCDThread.runInner + shouldWait (MapCollisionData:459-505):
                        // passes until BOTH libraries have nothing left to do. One
                        // pass per update cut multi-pass work (routing the zombies
                        // a sound reached) off at random.
                        int passes = 0;
                        do {
                            mcdUpdate.invoke(null);
                            popUpdateThread.invoke(null);
                            passes++;
                        } while (passes < MAX_PASSES && !((boolean) mcdShouldWait.invoke(null) && (boolean) popShouldWait.invoke(null)));
                        lastPasses = passes;
                        done.release();
                    }
                } catch (InterruptedException ignored) {
                } catch (Throwable t) { workerError = t; done.release(); }
            }, "MapCollisionDataJNI");
            worker.setDaemon(true);
            worker.start();
            ready = true;
            return null;
        } catch (Throwable t) {
            return error = describe(t);
        }
    }

    private static int intOption(Object sbo, String field, int dflt) {
        try {
            Object o = sbo.getClass().getField(field).get(sbo);
            return (int) o.getClass().getMethod("getValue").invoke(o);
        } catch (Throwable t) { return dflt; }
    }

    /** ZombiePopulationManager.onConfigReloaded (:325), from the engine's sandbox. */
    private static void configure(Class<?> pm, Object sbo) throws Exception {
        Method cf = nat(pm, "n_configFloat", 2), ci = nat(pm, "n_configInt", 2);
        Object cfg = null;
        try { cfg = sbo.getClass().getField("zombieConfig").get(sbo); } catch (Throwable ignored) { }
        String[][] floats = { { "PopulationMultiplier", "populationMultiplier", "1.0" },
            { "PopulationStartMultiplier", "populationStartMultiplier", "1.0" },
            { "PopulationPeakMultiplier", "populationPeakMultiplier", "1.5" },
            { "RespawnHours", "respawnHours", "72" }, { "RespawnUnseenHours", "respawnUnseenHours", "16" },
            { "RespawnMultiplier", "respawnMultiplier", "0.1" }, { "RedistributeHours", "redistributeHours", "12" } };
        for (String[] f : floats) cf.invoke(null, f[0], (float) number(cfg, f[1], Double.parseDouble(f[2])));
        ci.invoke(null, "PopulationPeakDay", (int) number(cfg, "populationPeakDay", 28));
        ci.invoke(null, "FollowSoundDistance", (int) number(cfg, "followSoundDistance", 100));
        cf.invoke(null, "MinZombiesPerChunk", 0f);
        cf.invoke(null, "MaxZombiesPerChunk", 255f);
        cf.invoke(null, "UniformZombiesPerChunk", 0.2f);
    }

    private static double number(Object cfg, String field, double dflt) {
        if (cfg == null) return dflt;
        try {
            Object o = cfg.getClass().getField(field).get(cfg);
            return ((Number) o.getClass().getMethod("getValue").invoke(o)).doubleValue();
        } catch (Throwable t) { return dflt; }
    }

    // ZombiePopulationManager.updateMain ends by asking both libraries whether
    // the worker has data (:629-633); the ask itself hands the main side's
    // queued work (chunk loads, areas, sounds) over, so it must be made
    private static void pump() throws Exception {
        popHasData.invoke(null);
        mcdHasData.invoke(null);
        go.release();
        done.acquire();
        if (workerError != null) throw new IllegalStateException("worker: " + describe(workerError));
    }

    /** The player's loaded area, in squares (the chunk grid around them). */
    public static synchronized String setArea(int x, int y, int w, int h) {
        if (!ready) return "population not started";
        try {
            int wx0 = Math.floorDiv(x, 8), wy0 = Math.floorDiv(y, 8);
            int wx1 = Math.floorDiv(x + Math.max(1, w) - 1, 8), wy1 = Math.floorDiv(y + Math.max(1, h) - 1, 8);
            java.util.Set<Long> want = new java.util.HashSet<>();
            for (int wy = wy0; wy <= wy1; wy++) for (int wx = wx0; wx <= wx1; wx++) want.add(((long) wx << 32) | (wy & 0xffffffffL));
            // real zombies left outside the new area go back to the library, as
            // a real one does when its chunk unloads (IsoMovingObject:1048 ->
            // ZombiePopulationManager.virtualizeZombie :450)
            for (Integer id : new ArrayList<>(real.keySet())) {
                float[] r = real.get(id);
                long k = ((long) Math.floorDiv((int) r[0], 8) << 32) | (Math.floorDiv((int) r[1], 8) & 0xffffffffL);
                if (!want.contains(k)) virtualize(id);
            }
            for (Long k : new ArrayList<>(loaded)) if (!want.contains(k)) {
                loadChunk.invoke(null, (int) (k >> 32), (int) (long) k, false);
                loaded.remove(k);
            }
            for (Long k : want) if (loaded.add(k)) loadChunk.invoke(null, (int) (k >> 32), (int) (long) k, true);
            area = new int[] { wx0, wy0, Math.min(128, wx1 - wx0 + 1), Math.min(128, wy1 - wy0 + 1) };
            loadedAreas.invoke(null, 1, area.clone(), false);
            // a dedicated server also reports the 64x64 ServerMap cells it holds
            // (ServerMap.characterIn :272 loads those under a player's chunk grid;
            // LoadedAreas.set :33 sends each as 8x8 chunks, serverCells = true)
            int sx0 = Math.floorDiv(x, 64), sy0 = Math.floorDiv(y, 64);
            int sx1 = Math.floorDiv(x + Math.max(1, w) - 1, 64), sy1 = Math.floorDiv(y + Math.max(1, h) - 1, 64);
            List<Integer> cells = new ArrayList<>();
            for (int cy = sy0; cy <= sy1; cy++) for (int cx = sx0; cx <= sx1; cx++) {
                if (cells.size() >= 64 * 4) break;
                cells.add(cx * 8); cells.add(cy * 8); cells.add(8); cells.add(8);
            }
            int[] serverCells = new int[256];
            for (int i = 0; i < cells.size(); i++) serverCells[i] = cells.get(i);
            loadedAreas.invoke(null, cells.size() / 4, serverCells, true);
            return null;
        } catch (Throwable t) { return describe(t); }
    }

    /** Advance the population by game minutes. Returns the zombies made real. */
    public static synchronized Object[] step(double minutes) { return step(minutes, 0); }

    public static synchronized Object[] step(double minutes, int wallMs) { return step(minutes, wallMs, SUB_STEPS); }

    public static synchronized Object[] step(double minutes, int wallMs, int subSteps) {
        if (!ready) return new Object[] { null, "population not started" };
        try {
            int before = made;
            subSteps = Math.max(1, subSteps);
            int n = Math.max(1, (int) Math.round(minutes * subSteps));
            for (int i = 0; i < n; i++) {
                worldAgeHours += minutes / 60.0 / n;
                advanceClock(minutes * SECONDS_PER_GAME_MINUTE / n);
                updateMain.invoke(null, MULT_PER_GAME_MINUTE / subSteps, worldAgeHours);
                drainAdds();
                pushReal();
                pump();
                if (wallMs > 0) Thread.sleep(wallMs);
            }
            return new Object[] { made - before, null };
        } catch (Throwable t) { return new Object[] { null, describe(t) }; }
    }

    private static void drainAdds() throws Exception {
        int total = (int) addCount.invoke(null);
        int offset = 0;
        ByteBuffer bb = ByteBuffer.allocateDirect(1024);
        while (offset < total) {
            bb.clear();
            int count = (int) addData.invoke(null, offset, bb);
            if (count <= 0) break;
            offset += count;
            for (int i = 0; i < count; i++) {
                float x = bb.getFloat(), y = bb.getFloat(), z = bb.getFloat();
                int dir = bb.get();
                int descriptor = bb.getInt(), state = bb.getInt(), tx = bb.getInt(), ty = bb.getInt(), id = bb.getInt();
                Map<String, Object> zed = new HashMap<>();
                zed.put("x", (double) x); zed.put("y", (double) y); zed.put("z", (double) z);
                zed.put("dir", (double) dir); zed.put("descriptor", (double) descriptor);
                zed.put("state", (double) state); zed.put("id", (double) id);
                zed.put("hour", worldAgeHours);
                boolean standing = tx == Integer.MIN_VALUE;
                zed.put("standing", standing);
                if (!standing) { zed.put("tx", (double) tx); zed.put("ty", (double) ty); }
                pending.add(zed);
                real.put(id, new float[] { x, y, z, state, dir, descriptor });
                made++;
            }
        }
    }

    private static void pushReal() throws Exception {
        int n = real.size();
        int[] ids = new int[Math.max(2, n * 2)];
        float[] pos = new float[Math.max(3, n * 3)];
        int i = 0;
        for (Map.Entry<Integer, float[]> e : real.entrySet()) {
            ids[i * 2] = e.getKey(); ids[i * 2 + 1] = (int) e.getValue()[3];
            pos[i * 3] = e.getValue()[0]; pos[i * 3 + 1] = e.getValue()[1]; pos[i * 3 + 2] = e.getValue()[2];
            i++;
        }
        updateReal.invoke(null, n, ids, pos);
    }

    /** The zombies made real since the last take, nearest first to (x, y) when given. */
    public static synchronized List<Map<String, Object>> take(Double nearX, Double nearY) {
        List<Map<String, Object>> out = new ArrayList<>(pending);
        pending.clear();
        if (nearX != null && nearY != null) {
            double px = nearX, py = nearY;
            out.sort(Comparator.comparingDouble(z -> Math.hypot((double) z.get("x") - px, (double) z.get("y") - py)));
        }
        return out;
    }

    /** A real zombie died (IsoZombie -> ZombiePopulationManager.releaseZombie). */
    public static synchronized boolean kill(int id) {
        if (!ready || real.remove(id) == null) return false;
        try { releaseZombie.invoke(null, id); killed++; return true; } catch (Throwable t) { return false; }
    }

    /** A real zombie leaves the loaded world and becomes virtual again. */
    public static synchronized boolean virtualize(int id) {
        float[] r = real.remove(id);
        if (r == null) return false;
        try {
            addZombie.invoke(null, r[0], r[1], r[2], (byte) (int) r[4], (int) r[5], (int) r[3], Integer.MIN_VALUE, Integer.MIN_VALUE, id);
            return true;
        } catch (Throwable t) { return false; }
    }

    /** A real zombie moved (it is reported where it now stands). */
    public static synchronized boolean move(int id, double x, double y) {
        float[] r = real.get(id);
        if (r == null) return false;
        r[0] = (float) x; r[1] = (float) y;
        return true;
    }

    /** A world sound, its radius already multiplied by hearing (ZPM.addWorldSound :501). */
    public static synchronized String sound(int x, int y, int radius, int volume) {
        if (!ready) return "population not started";
        try { worldSound.invoke(null, x, y, radius, volume); return null; } catch (Throwable t) { return describe(t); }
    }

    /** Every zombie's position as the radar sees it (x, y pairs), or null if the
     *  library has not answered within the wait. */
    public static synchronized float[] radar(int waitSteps) {
        if (!ready) return null;
        try {
            reqRadar.invoke(null);
            float[] buf = new float[2 * 400000];
            for (int i = 0; i < Math.max(1, waitSteps); i++) {
                updateMain.invoke(null, 0f, worldAgeHours);
                pump();
                if ((boolean) hasRadar.invoke(null)) {
                    int n = (int) getRadar.invoke(null, (Object) buf);
                    return java.util.Arrays.copyOf(buf, Math.max(0, n) * 2);
                }
            }
            return null;
        } catch (Throwable t) { return null; }
    }

    /** The library's loaded population cells (MPDebugInfo.serverUpdate :92-112):
     *  { cx, cy, current, desired, lastRepop } each, or null if it did not answer. */
    public static synchronized List<Map<String, Object>> cells(int waitSteps) {
        if (!ready) return null;
        try {
            Class<?> dbg = cls("zombie.popman.MPDebugInfo");
            Method req = nat(dbg, "n_requestData", 0), has = nat(dbg, "n_hasData", 1);
            Method count = nat(dbg, "n_getLoadedCellsCount", 0), data = nat(dbg, "n_getLoadedCellsData", 2);
            req.invoke(null);
            for (int i = 0; i < Math.max(1, waitSteps); i++) {
                updateMain.invoke(null, 0f, worldAgeHours);
                pump();
                if ((boolean) has.invoke(null, false)) {
                    List<Map<String, Object>> out = new ArrayList<>();
                    int total = (int) count.invoke(null), offset = 0;
                    ByteBuffer bb = ByteBuffer.allocateDirect(1024);
                    while (offset < total) {
                        bb.clear();
                        int n = (int) data.invoke(null, offset, bb);
                        if (n <= 0) break;
                        offset += n;
                        for (int k = 0; k < n; k++) {
                            Map<String, Object> c = new HashMap<>();
                            c.put("cx", (double) bb.getShort()); c.put("cy", (double) bb.getShort());
                            c.put("current", (double) bb.getShort()); c.put("desired", (double) bb.getShort());
                            c.put("lastRepop", (double) bb.getFloat());
                            out.add(c);
                        }
                    }
                    return out;
                }
            }
            return null;
        } catch (Throwable t) { return null; }
    }

    /** The map's zombie intensity per chunk over a square rectangle (no
     *  library needed): { wx0, wy0, w, h, values (row-major, -1 = no map) }. */
    public static Object[] density(int x0, int y0, int x1, int y1) {
        try {
            Class<?> worldC = cls("zombie.iso.IsoWorld");
            Object grid = worldC.getMethod("getMetaGrid").invoke(worldC.getField("instance").get(null));
            Method cellData = grid.getClass().getMethod("getCellData", int.class, int.class);
            Class<?> lh = cls("zombie.iso.LotHeader");
            Method intensity = lh.getMethod("getZombieIntensityForChunk", lh, int.class, int.class);
            int wx0 = Math.floorDiv(Math.min(x0, x1), 8), wy0 = Math.floorDiv(Math.min(y0, y1), 8);
            int wx1 = Math.floorDiv(Math.max(x0, x1), 8), wy1 = Math.floorDiv(Math.max(y0, y1), 8);
            int w = wx1 - wx0 + 1, h = wy1 - wy0 + 1;
            if ((long) w * h > 4_000_000L) return new Object[] { null, "area too large" };
            int[] values = new int[w * h];
            Map<Long, Object> infos = new HashMap<>();
            for (int wy = wy0; wy <= wy1; wy++) for (int wx = wx0; wx <= wx1; wx++) {
                int cx = Math.floorDiv(wx, 32), cy = Math.floorDiv(wy, 32);
                long key = ((long) cx << 32) | (cy & 0xffffffffL);
                Object info = infos.computeIfAbsent(key, k -> {
                    try {
                        Object mc = cellData.invoke(grid, cx, cy);
                        return mc == null ? "none" : mc.getClass().getField("info").get(mc);
                    } catch (Throwable t) { return "none"; }
                });
                values[(wy - wy0) * w + (wx - wx0)] = "none".equals(info) || info == null ? -1
                    : (int) intensity.invoke(null, info, Math.floorMod(wx, 32), Math.floorMod(wy, 32));
            }
            return new Object[] { new int[] { wx0, wy0, w, h }, values };
        } catch (Throwable t) { return new Object[] { null, describe(t) }; }
    }

    public static synchronized Map<String, Object> status() {
        Map<String, Object> s = new HashMap<>();
        s.put("ready", ready);
        if (error != null) s.put("error", error);
        s.put("hour", worldAgeHours);
        s.put("real", (double) real.size());
        s.put("made", (double) made);
        s.put("killed", (double) killed);
        s.put("zombiesOption", (double) zombiesOption);
        s.put("lastPasses", (double) lastPasses);
        s.put("clock", clockError == null ? "virtual" : clockError);
        s.put("distributionOption", (double) distributionOption);
        s.put("pending", (double) pending.size());
        s.put("chunks", (double) loaded.size());
        if (area != null) { s.put("x", (double) area[0] * 8); s.put("y", (double) area[1] * 8); s.put("w", (double) area[2] * 8); s.put("h", (double) area[3] * 8); }
        if (tempDir != null) s.put("dir", tempDir.toString());
        return s;
    }
}
