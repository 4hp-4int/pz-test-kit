/**
 * PZ Test Kit — Kahlua Test Runner
 * =================================
 * Runs Lua tests on PZ's actual Kahlua VM. Each test file gets a fresh
 * runtime with mocked PZ APIs, your mod's modules auto-indexed via the
 * require resolver, and weapon data loaded.
 *
 * Usage:
 *   javac -cp kahlua-runtime.jar TestPlatform.java KahluaTestRunner.java
 *   java -cp kahlua-runtime.jar:. KahluaTestRunner <mod_root> [modules...] [-- tests...]
 *
 * On Windows use ; instead of : for classpath.
 *
 * Test files can either:
 *   - Return a table of named test functions:
 *       local tests = {}; tests["my_test"] = function() ... end; return tests
 *   - Use require() to pull in mod modules:
 *       require "MyMod/Core"
 *       local tests = {}; tests["..."] = function() ... end; return tests
 *
 * With the require resolver active (default), modules are auto-discovered
 * from media/lua/{shared,client,server}/**&#47;*.lua — modder does not need
 * to list them explicitly on the CLI.
 */

import se.krka.kahlua.vm.*;
import se.krka.kahlua.luaj.compiler.LuaCompiler;

import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.stream.*;

public class KahluaTestRunner {

    // Resolved once at startup
    private static Path kahluaDir;

    public static void main(String[] args) throws Exception {

        // ── Parse CLI args ──────────────────────────────────────────
        if (args.length < 1) { printUsage(); System.exit(1); }

        Path modRoot = Paths.get(args[0]).toAbsolutePath();
        List<String> modules  = new ArrayList<>();
        List<String> tests    = new ArrayList<>();

        // Flags
        String filterPattern  = null;
        boolean listOnly      = false;
        boolean failFast      = false;
        String junitXmlPath   = null;
        boolean eventCoverage = false;

        boolean afterSep = false;
        for (int i = 1; i < args.length; i++) {
            String a = args[i];
            if (a.equals("--")) { afterSep = true; continue; }
            if (!afterSep && a.startsWith("--")) {
                if (a.equals("--list"))      { listOnly = true; continue; }
                if (a.equals("--fail-fast")) { failFast = true; continue; }
                if (a.equals("--filter") && i + 1 < args.length) {
                    filterPattern = args[++i]; continue;
                }
                if (a.startsWith("--filter=")) {
                    filterPattern = a.substring("--filter=".length()); continue;
                }
                if (a.equals("--junit-xml") && i + 1 < args.length) {
                    junitXmlPath = args[++i]; continue;
                }
                if (a.startsWith("--junit-xml=")) {
                    junitXmlPath = a.substring("--junit-xml=".length()); continue;
                }
                if (a.equals("--event-coverage")) { eventCoverage = true; continue; }
                if (a.equals("--help") || a.equals("-h")) {
                    printUsage(); System.exit(0);
                }
                System.err.println("Unknown flag: " + a);
                printUsage();
                System.exit(2);
            }
            (afterSep ? tests : modules).add(a);
        }

        // Collected per-file records for JUnit XML output (each entry is one
        // test suite = one test file).
        List<JUnitSuite> junitSuites = junitXmlPath != null ? new ArrayList<>() : null;

        // Running totals across all files (set inside loop, used in summary).
        int grandSkip = 0;

        // Aggregated event coverage across files. Per event name: {registered,
        // fired} — registered counts Events[name].Add(fn) calls, fired counts
        // triggerEvent(name, ...) + sim dispatches. Used by --event-coverage.
        Map<String, int[]> eventAccum = eventCoverage ? new LinkedHashMap<>() : null;

        if (tests.isEmpty()) tests = discoverTests(modRoot);

        kahluaDir = resolveKahluaDir();
        KitLua.root = kahluaDir;  // enable Lua-file loading helper used by DualVMSim + buildEnv

        // Apply test_file_excludes from pz-test.lua (if configured). Evaluating
        // the full config here is cheap — a throwaway Kahlua env, no mocks.
        List<String> excludes = readExcludesFromConfig(modRoot);
        if (!excludes.isEmpty()) {
            List<String> filtered = new ArrayList<>();
            for (String t : tests) {
                boolean skip = false;
                for (String ex : excludes) {
                    if (t.endsWith(ex) || t.equals(ex)) { skip = true; break; }
                }
                if (!skip) filtered.add(t);
            }
            tests = filtered;
        }

        if (tests.isEmpty()) {
            System.err.println("No test files found.");
            System.exit(1);
        }

        // --list: enumerate test FILES (not individual tests — would need env
        // setup to enumerate per-file tests, but file list is usually enough
        // for filtering CI-style workflows).
        if (listOnly) {
            for (String t : tests) System.out.println(t);
            System.exit(0);
        }

        // ── Pre-scan module index (used by require resolver) ────────
        ModuleIndex index = indexModuleTree(modRoot);

        // ── Header ──────────────────────────────────────────────────
        System.out.println("====================================================");
        System.out.println("PZ Test Kit — Kahlua Runner (PZ's actual Lua VM)");
        System.out.println("====================================================");
        System.out.println("Mod root:         " + modRoot);
        System.out.println("Indexed modules:  " + index.size());
        System.out.println("Explicit modules: " + modules.size());
        System.out.println("Test files:       " + tests.size());

        // ── Run each test file in an isolated runtime ───────────────
        int grandTotal = 0, grandPass = 0, grandFail = 0, grandErr = 0;

        long grandStartNs = System.nanoTime();
        for (String testFile : tests) {
            Path testPath = modRoot.resolve(testFile);
            if (!Files.exists(testPath)) {
                System.out.println("\n  SKIP: " + testFile + " (not found)");
                continue;
            }
            long fileStartNs = System.nanoTime();

            // Fresh Kahlua runtime
            TestPlatform platform = new TestPlatform();
            KahluaTable  env      = platform.newEnvironment();
            KahluaThread thread   = new KahluaThread(platform, env);
            thread.debugOwnerThread = Thread.currentThread();

            // Capture the build recipe once so DualVMSim can construct
            // identical sub-environments on demand.
            final Path modRootFinal = modRoot;
            final ModuleIndex indexFinal = index;
            final List<String> modulesFinal = modules;
            DualVMSim.EnvBuilder envBuilder = (subThread, subEnv, isServer, clientIdx) -> {
                buildEnv(subThread, subEnv, modRootFinal, indexFinal, modulesFinal, isServer, clientIdx);
            };

            // Build the primary test env. Default context: client (mirrors
            // single-VM convention). DualVMSim overrides per-endpoint.
            buildEnv(thread, env, modRoot, index, modules, /*isServer*/ false, /*clientIdx*/ 0);

            // Expose PZTestKit.Sim.new() to test code
            DualVMSim.installLuaAPI(env, envBuilder);

            // Pass the filter pattern into the env so the test executor can
            // skip non-matching test names.
            if (filterPattern != null) {
                env.rawset("_pz_filter", filterPattern);
            }

            // 5. Test file → pass the source through to context/load_test_file.lua,
            //    which wraps it and captures the returned table into _pz_last_return.
            try {
                env.rawset("_pz_test_source", stripContextGuards(Files.readString(testPath)));
                env.rawset("_pz_test_name", testFile);
                loadFile(thread, env, kahluaDir.resolve("context/load_test_file.lua"));
            } catch (Exception e) {
                System.out.println("\n  ERROR loading " + testFile + ": " + e.getMessage());
                continue;
            }

            // 6. Execute tests via test_executor.lua
            Object[] res = execFile(thread, env, kahluaDir.resolve("test_executor.lua"));

            // Surface test_executor errors so they don't look like "0 tests"
            if (res != null && res.length > 0 && Boolean.FALSE.equals(res[0])) {
                System.out.println("\n  EXECUTOR ERROR in " + testFile + ": " +
                    (res.length > 1 ? res[1] : "unknown"));
                continue;
            }

            int total = intVal(res, 1);
            int pass  = intVal(res, 2);
            int fail  = intVal(res, 3);
            int errs  = intVal(res, 4);
            String detail = strVal(res, 5);

            grandTotal += total;
            grandPass  += pass;
            grandFail  += fail;
            grandErr   += errs;

            long fileMs = (System.nanoTime() - fileStartNs) / 1_000_000L;
            String flag = (fail + errs == 0) ? "" : " *** FAILURES ***";
            System.out.printf("\n--- %s (%d tests, %dms) ---%s%n", testFile, total, fileMs, flag);
            if (!detail.isEmpty()) {
                for (String line : detail.split("\n"))
                    System.out.println("    " + line);
            }

            // Pull the skipped count from the env (set by test_executor).
            int skipped = 0;
            Object skipRaw = env.rawget("_pz_last_skipped_count");
            if (skipRaw instanceof Number) skipped = ((Number) skipRaw).intValue();
            grandSkip += skipped;
            if (skipped > 0) {
                System.out.printf("    (%d skipped)%n", skipped);
            }

            // Collect per-test records for JUnit XML (if requested).
            if (junitSuites != null) {
                JUnitSuite suite = new JUnitSuite();
                suite.name = testFile;
                suite.tests = total;
                suite.failures = fail;
                suite.errors = errs;
                suite.skipped = skipped;
                Object raw = env.rawget("_pz_last_test_records");
                if (raw instanceof KahluaTable) {
                    KahluaTable tbl = (KahluaTable) raw;
                    int idx = 1;
                    while (true) {
                        Object rec = tbl.rawget(idx);
                        if (rec == null) break;
                        if (rec instanceof KahluaTable) {
                            KahluaTable r = (KahluaTable) rec;
                            JUnitCase c = new JUnitCase();
                            Object nm = r.rawget("name");
                            Object st = r.rawget("status");
                            Object msg = r.rawget("message");
                            c.name = nm instanceof String ? (String) nm : "unknown";
                            c.status = st instanceof String ? (String) st : "pass";
                            c.message = msg instanceof String ? (String) msg : "";
                            suite.cases.add(c);
                        }
                        idx++;
                    }
                }
                junitSuites.add(suite);
            }

            // Accumulate event coverage counts from this file's env.
            if (eventAccum != null) {
                Object cov = env.rawget("_pz_event_coverage");
                if (cov instanceof KahluaTable) {
                    KahluaTable t = (KahluaTable) cov;
                    KahluaTableIterator it = t.iterator();
                    while (it.advance()) {
                        Object k = it.getKey();
                        Object v = it.getValue();
                        if (k instanceof String && v instanceof KahluaTable) {
                            KahluaTable row = (KahluaTable) v;
                            int reg   = intFromTable(row, "registered");
                            int fired = intFromTable(row, "fired");
                            int[] agg = eventAccum.computeIfAbsent((String) k, _k -> new int[2]);
                            agg[0] += reg;
                            agg[1] += fired;
                        }
                    }
                }
            }

            if (failFast && (fail + errs) > 0) {
                System.out.println("\n--fail-fast: stopping on first failing file");
                break;
            }
        }

        if (eventAccum != null) {
            printEventCoverage(eventAccum);
        }

        // Write JUnit XML report if requested.
        if (junitXmlPath != null) {
            writeJUnitXml(junitSuites, Paths.get(junitXmlPath));
            System.out.println("JUnit XML written to " + junitXmlPath);
        }

        // ── Summary ─────────────────────────────────────────────────
        long grandMs = (System.nanoTime() - grandStartNs) / 1_000_000L;
        System.out.println("\n====================================================");
        if (grandSkip > 0) {
            System.out.printf("KAHLUA TOTAL: %d tests, %d passed, %d failed, %d errors, %d skipped (%dms)%n",
                    grandTotal, grandPass, grandFail, grandErr, grandSkip, grandMs);
        } else {
            System.out.printf("KAHLUA TOTAL: %d tests, %d passed, %d failed, %d errors (%dms)%n",
                    grandTotal, grandPass, grandFail, grandErr, grandMs);
        }
        System.out.println("====================================================");
        System.exit(grandFail + grandErr > 0 ? 1 : 0);
    }

    // ── Event coverage ──────────────────────────────────────────────

    /** Print a report: which events had listeners vs. which actually fired. */
    private static void printEventCoverage(Map<String, int[]> accum) {
        System.out.println("\n--- Event coverage ---");
        if (accum.isEmpty()) {
            System.out.println("  (no events observed)");
            return;
        }
        List<String> names = new ArrayList<>(accum.keySet());
        names.sort(null);
        int registeredButNeverFired = 0;
        for (String name : names) {
            int[] v = accum.get(name);
            int reg = v[0], fired = v[1];
            String flag = (reg > 0 && fired == 0) ? "  [NOT FIRED]" : "";
            if (reg > 0 && fired == 0) registeredButNeverFired++;
            System.out.printf("  %-40s reg=%-3d fired=%-3d%s%n", name, reg, fired, flag);
        }
        System.out.printf("%n  %d event(s) registered but never fired during the test run%n",
            registeredButNeverFired);
    }

    /** Safely extract an integer field from a KahluaTable (0 if absent/non-numeric). */
    private static int intFromTable(KahluaTable t, String key) {
        Object v = t.rawget(key);
        return v instanceof Number ? ((Number) v).intValue() : 0;
    }

    // ── JUnit XML output ────────────────────────────────────────────

    /** One test suite = one test file. */
    private static class JUnitSuite {
        String name;
        int tests, failures, errors, skipped;
        List<JUnitCase> cases = new ArrayList<>();
    }

    /** One test case = one test function. */
    private static class JUnitCase {
        String name;
        String status;   // "pass" | "fail" | "error"
        String message;
    }

    /** Minimal JUnit XML (Surefire-compatible): enough for GitHub Actions,
     *  GitLab, CircleCI, Jenkins to parse test results and render them. */
    private static void writeJUnitXml(List<JUnitSuite> suites, Path outPath) throws IOException {
        Files.createDirectories(outPath.toAbsolutePath().getParent());
        StringBuilder sb = new StringBuilder();
        sb.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
        int totalTests = 0, totalFail = 0, totalErr = 0, totalSkip = 0;
        for (JUnitSuite s : suites) {
            totalTests += s.tests;
            totalFail  += s.failures;
            totalErr   += s.errors;
            totalSkip  += s.skipped;
        }
        sb.append(String.format("<testsuites tests=\"%d\" failures=\"%d\" errors=\"%d\" skipped=\"%d\">\n",
                totalTests, totalFail, totalErr, totalSkip));
        for (JUnitSuite s : suites) {
            String suiteName = xmlEscape(s.name);
            sb.append(String.format("  <testsuite name=\"%s\" tests=\"%d\" failures=\"%d\" errors=\"%d\" skipped=\"%d\">\n",
                    suiteName, s.tests, s.failures, s.errors, s.skipped));
            for (JUnitCase c : s.cases) {
                String caseName = xmlEscape(c.name);
                String classname = xmlEscape(s.name.replaceAll("\\.lua$", ""));
                if ("pass".equals(c.status)) {
                    sb.append(String.format("    <testcase classname=\"%s\" name=\"%s\"/>\n",
                            classname, caseName));
                } else if ("skip".equals(c.status)) {
                    sb.append(String.format("    <testcase classname=\"%s\" name=\"%s\">\n",
                            classname, caseName));
                    sb.append(String.format("      <skipped message=\"%s\"/>\n",
                            xmlEscape(c.message)));
                    sb.append(String.format("    </testcase>\n"));
                } else {
                    String tag = "error".equals(c.status) ? "error" : "failure";
                    sb.append(String.format("    <testcase classname=\"%s\" name=\"%s\">\n",
                            classname, caseName));
                    sb.append(String.format("      <%s message=\"%s\"/>\n",
                            tag, xmlEscape(c.message)));
                    sb.append(String.format("    </testcase>\n"));
                }
            }
            sb.append("  </testsuite>\n");
        }
        sb.append("</testsuites>\n");
        Files.writeString(outPath, sb.toString());
    }

    private static String xmlEscape(String s) {
        if (s == null) return "";
        return s.replace("&", "&amp;")
                .replace("<", "&lt;")
                .replace(">", "&gt;")
                .replace("\"", "&quot;")
                .replace("'", "&apos;");
    }

    // ── Reusable env builder (shared between primary test env + DualVMSim subs) ──

    /** Load mocks, resolver, config, scripts, modules, post-scripts into a
     *  fresh Kahlua env. Used by the main test loop AND by DualVMSim for each
     *  sub-environment so every endpoint has identical setup.
     *
     *  @param isServer true to mark this env as the server endpoint
     *                  (isServer()=true, isClient()=false)
     *  @param clientIdx 0 for server; positive integer for client N (stored on
     *                   the player table as `_client_index` so targeted sends
     *                   can resolve to this endpoint) */
    private static void buildEnv(KahluaThread thread, KahluaTable env,
                                 Path modRoot, ModuleIndex index, List<String> modules,
                                 boolean isServer, int clientIdx) throws Exception {
        // 1. Mocks + Assert + Fixtures
        loadFile(thread, env, kahluaDir.resolve("mock_environment.lua"));
        loadFile(thread, env, kahluaDir.resolve("Assert.lua"));
        loadFile(thread, env, kahluaDir.resolve("Fixtures.lua"));

        // 1b. Override context functions. mock_environment defaults to client.
        if (isServer) {
            loadFile(thread, env, kahluaDir.resolve("context/server.lua"));
        }
        // Tag the player with its client index so server-targeted sends can
        // route to the correct endpoint.
        if (clientIdx > 0) {
            env.rawset("_pz_client_index", Double.valueOf(clientIdx));
            loadFile(thread, env, kahluaDir.resolve("context/client_tag.lua"));
        }

        // 2. Module index + require resolver
        installModuleIndex(env, index);
        loadFile(thread, env, kahluaDir.resolve("require_resolver.lua"));

        // 3. Config — pass the raw source through to context/load_config.lua,
        //    which handles compile/runtime errors as warnings.
        Path configFile = modRoot.resolve("pz-test.lua");
        if (Files.exists(configFile)) {
            env.rawset("_pz_config_source", Files.readString(configFile));
            loadFile(thread, env, kahluaDir.resolve("context/load_config.lua"));
        }
        loadFile(thread, env, kahluaDir.resolve("config_loader.lua"));

        // 3b. Sandbox auto-discovery — parse media/sandbox-options.txt and
        //     fill in defaults NOT already covered by pz-test.lua's sandbox
        //     block. Zero-config for mods with vanilla-style sandbox files.
        Path sandboxFile = modRoot.resolve("media/sandbox-options.txt");
        if (Files.exists(sandboxFile)) {
            env.rawset("_pz_sandbox_source", Files.readString(sandboxFile));
            loadFile(thread, env, kahluaDir.resolve("context/sandbox_auto.lua"));
        }

        // 4. Scripts
        List<String> scriptPaths = new ArrayList<>();
        scriptPaths.add("weapon_scripts.lua");
        Object cfgRaw = env.rawget("_pz_config");
        if (cfgRaw instanceof KahluaTable) {
            KahluaTable cfg = (KahluaTable) cfgRaw;
            Object v = cfg.rawget("weapon_scripts");
            if (v instanceof String) scriptPaths.set(0, (String) v);
            Object extra = cfg.rawget("extra_scripts");
            if (extra instanceof KahluaTable) {
                KahluaTable t = (KahluaTable) extra;
                int i = 1;
                while (true) {
                    Object e = t.rawget(i);
                    if (e == null) break;
                    if (e instanceof String) scriptPaths.add((String) e);
                    i++;
                }
            }
        }
        for (String sp : scriptPaths) {
            Path p = modRoot.resolve(sp);
            if (Files.exists(p)) loadFile(thread, env, p);
        }

        // 5. Explicit CLI modules
        for (String mod : modules) {
            Path p = modRoot.resolve(mod);
            if (Files.exists(p)) loadStripped(thread, env, p);
        }

        // 6. Post-scripts hook
        loadFile(thread, env, kahluaDir.resolve("post_scripts.lua"));
    }

    // ── Module index ───────────────────────────────────────────────

    /** A scanned module: the require name ("MyMod/Core"), its file path, and contents. */
    private static class ModuleEntry {
        String name;
        Path path;
        String source;
    }

    private static class ModuleIndex {
        final Map<String, ModuleEntry> byName = new LinkedHashMap<>();
        int size() { return byName.size(); }
    }

    /** Scan media/lua/{shared,client,server}/**&#47;*.lua and build a name→source
     *  index. First match wins (shared > client > server) to mirror real PZ
     *  semantics. Also scans dependency mods declared in pz-test.lua so a
     *  mod's tests can `require` modules from another mod it depends on. */
    private static ModuleIndex indexModuleTree(Path modRoot) throws IOException {
        ModuleIndex idx = new ModuleIndex();

        // Dependency roots get indexed FIRST — so the target mod's own files
        // naturally win on name conflicts via the "first match wins" rule
        // reversed: we walk the primary mod LAST. Wait, actually the opposite
        // makes more sense: target mod's modules should beat deps. Walk target
        // first, then deps (they'll be skipped for any name the target shares).
        List<Path> roots = new ArrayList<>();
        roots.add(modRoot);
        for (Path dep : readDependencyRoots(modRoot)) {
            roots.add(dep);
        }

        String[] contexts = { "shared", "client", "server" };
        for (Path root : roots) {
            for (String ctx : contexts) {
                Path ctxRoot = root.resolve("media/lua/" + ctx);
                if (!Files.isDirectory(ctxRoot)) continue;
                try (Stream<Path> walk = Files.walk(ctxRoot)) {
                    List<Path> files = walk
                        .filter(Files::isRegularFile)
                        .filter(p -> p.getFileName().toString().endsWith(".lua"))
                        .sorted()
                        .collect(Collectors.toList());
                    for (Path p : files) {
                        String rel = ctxRoot.relativize(p).toString().replace('\\', '/');
                        String name = rel.substring(0, rel.length() - 4);
                        if (idx.byName.containsKey(name)) continue;
                        ModuleEntry e = new ModuleEntry();
                        e.name = name;
                        e.path = p;
                        e.source = Files.readString(p);
                        idx.byName.put(name, e);
                    }
                }
            }
        }
        return idx;
    }

    /** Read the `dependencies` array from pz-test.lua. Each entry is either
     *  a string path or a table with `path` (relative to the target mod root).
     *  Returns absolute, existing paths only. */
    private static List<Path> readDependencyRoots(Path modRoot) {
        List<Path> out = new ArrayList<>();
        KahluaTable cfgTable = loadConfigInThrowawayEnv(modRoot);
        if (cfgTable == null) return out;
        Object cfg = cfgTable;
        try {
            if (!(cfg instanceof KahluaTable)) return out;
            Object deps = ((KahluaTable) cfg).rawget("dependencies");
            if (!(deps instanceof KahluaTable)) return out;
            KahluaTable t = (KahluaTable) deps;
            int i = 1;
            while (true) {
                Object entry = t.rawget(i);
                if (entry == null) break;
                String path = null;
                if (entry instanceof String) {
                    path = (String) entry;
                } else if (entry instanceof KahluaTable) {
                    Object p = ((KahluaTable) entry).rawget("path");
                    if (p instanceof String) path = (String) p;
                }
                if (path != null) {
                    Path depPath = modRoot.resolve(path).normalize();
                    if (Files.isDirectory(depPath)) {
                        out.add(depPath);
                    } else {
                        System.out.println("  WARNING: dependency path not found: " + depPath);
                    }
                }
                i++;
            }
        } catch (Exception e) {
            System.out.println("  WARNING: failed to read dependencies: " + e.getMessage());
        }
        return out;
    }

    /** Push the module index into the Kahlua env as _pz_module_sources / _pz_module_files. */
    private static void installModuleIndex(KahluaTable env, ModuleIndex idx) {
        KahluaTable sources = new se.krka.kahlua.j2se.KahluaTableImpl(new java.util.HashMap<>());
        KahluaTable files   = new se.krka.kahlua.j2se.KahluaTableImpl(new java.util.HashMap<>());
        for (ModuleEntry e : idx.byName.values()) {
            sources.rawset(e.name, e.source);
            files.rawset(e.name, e.path.toString());
        }
        env.rawset("_pz_module_sources", sources);
        env.rawset("_pz_module_files", files);
    }

    // ── File loading helpers ───────────────────────────────────────

    /** Load a Lua file as-is (no stripping). */
    private static void loadFile(KahluaThread t, KahluaTable env, Path path) throws Exception {
        exec(t, env, Files.readString(path), path.getFileName().toString());
    }

    /** Load a Lua file with require/context-guard stripping (legacy: for explicit -m modules). */
    private static void loadStripped(KahluaThread t, KahluaTable env, Path path) throws Exception {
        exec(t, env, stripSource(Files.readString(path)), path.getFileName().toString());
    }

    /** Execute a Lua file and return the pcall results array. */
    private static Object[] execFile(KahluaThread t, KahluaTable env, Path path) throws Exception {
        LuaClosure c = LuaCompiler.loadstring(Files.readString(path), path.getFileName().toString(), env);
        return t.pcall(c, new Object[0]);
    }

    /** Compile + pcall a Lua source string. Throws on error. */
    private static void exec(KahluaThread t, KahluaTable env, String src, String name) throws Exception {
        LuaClosure c = LuaCompiler.loadstring(src, name, env);
        Object[] r = t.pcall(c, new Object[0]);
        if (r != null && r.length > 0 && Boolean.FALSE.equals(r[0]))
            throw new RuntimeException(r.length > 1 ? String.valueOf(r[1]) : "unknown error");
    }

    /** Legacy: strip require() calls AND context guards. */
    private static String stripSource(String src) {
        src = src.replaceAll("(local\\s+\\w+\\s*=\\s*)require\\s+\"[^\"]*\"", "$1nil -- [stripped]");
        src = src.replaceAll("(?m)^(\\s*)require\\s+\"[^\"]*\"", "$1-- [stripped]");
        return stripContextGuards(src);
    }

    /** Strip only the `if isServer/isClient then return end` guards at file tops. */
    private static String stripContextGuards(String src) {
        src = src.replaceAll("if\\s+isServer\\s*\\(\\s*\\)\\s+and\\s+not\\s+isClient\\s*\\(\\s*\\)\\s+then\\s+return\\s+end", "-- [stripped guard]");
        src = src.replaceAll("if\\s+isClient\\s*\\(\\s*\\)\\s+then\\s+return\\s+end", "-- [stripped guard]");
        return src;
    }

    // ── Test discovery ─────────────────────────────────────────────

    /** Auto-discover test files in the mod root. Checks:
     *  - tests/test_*.lua (standalone test dir)
     *  - media/lua/client/&#42;/Tests/test_*.lua
     *  - media/lua/client/&#42;/Tests/*Tests.lua (VPS-style) */
    private static List<String> discoverTests(Path modRoot) throws IOException {
        List<String> found = new ArrayList<>();

        // Check tests/ directory
        Path testsDir = modRoot.resolve("tests");
        if (Files.isDirectory(testsDir))
            collectTestFiles(modRoot, testsDir, found);

        // Check media/lua/client/*/Tests/ directories
        Path clientDir = modRoot.resolve("media/lua/client");
        if (Files.isDirectory(clientDir)) {
            try (var mods = Files.list(clientDir)) {
                mods.filter(Files::isDirectory).forEach(modDir -> {
                    Path modTests = modDir.resolve("Tests");
                    if (Files.isDirectory(modTests)) {
                        try { collectTestFiles(modRoot, modTests, found); }
                        catch (IOException e) { /* skip */ }
                    }
                });
            }
        }

        Collections.sort(found);
        return found;
    }

    /** Match both test_*.lua and *Tests.lua (VPS convention). */
    private static void collectTestFiles(Path root, Path dir, List<String> out) throws IOException {
        try (var stream = Files.list(dir)) {
            stream.filter(p -> {
                String n = p.getFileName().toString();
                return (n.startsWith("test_") && n.endsWith(".lua"))
                    || (n.endsWith("Tests.lua") && !n.startsWith("_"));
            }).sorted()
              .forEach(p -> out.add(root.relativize(p).toString().replace('\\', '/')));
        }
    }

    /** Read `test_file_excludes` from pz-test.lua at mod root, if present. */
    private static List<String> readExcludesFromConfig(Path modRoot) {
        List<String> out = new ArrayList<>();
        KahluaTable cfg = loadConfigInThrowawayEnv(modRoot);
        if (cfg == null) return out;
        Object excludes = cfg.rawget("test_file_excludes");
        if (excludes instanceof KahluaTable) {
            KahluaTable t = (KahluaTable) excludes;
            int i = 1;
            while (true) {
                Object v = t.rawget(i);
                if (v == null) break;
                if (v instanceof String) out.add((String) v);
                i++;
            }
        }
        return out;
    }

    /** Evaluate pz-test.lua in a throwaway Kahlua env and return the config
     *  table. Used for startup reads (excludes, dependencies) before the
     *  full test env is built. Returns null if the config is missing or
     *  didn't produce a table. */
    private static KahluaTable loadConfigInThrowawayEnv(Path modRoot) {
        Path configFile = modRoot.resolve("pz-test.lua");
        if (!Files.exists(configFile)) return null;
        try {
            TestPlatform platform = new TestPlatform();
            KahluaTable env = platform.newEnvironment();
            KahluaThread thread = new KahluaThread(platform, env);
            thread.debugOwnerThread = Thread.currentThread();
            env.rawset("_pz_config_source", Files.readString(configFile));
            LuaClosure c = LuaCompiler.loadstring(
                Files.readString(kahluaDir.resolve("context/load_config.lua")),
                "context/load_config.lua", env);
            thread.pcall(c, new Object[0]);
            Object cfg = env.rawget("_pz_config");
            return cfg instanceof KahluaTable ? (KahluaTable) cfg : null;
        } catch (Exception e) {
            System.out.println("  WARNING: failed to read pz-test.lua: " + e.getMessage());
            return null;
        }
    }

    /** Find the kahlua/ directory (where mocks and executor live). */
    private static Path resolveKahluaDir() {
        Path cwd = Paths.get("").toAbsolutePath();
        for (Path p : new Path[]{ cwd, cwd.resolve("kahlua") }) {
            if (Files.exists(p.resolve("mock_environment.lua"))) return p.normalize();
        }
        throw new RuntimeException("Cannot find mock_environment.lua — run from the kahlua/ directory");
    }

    /** Safe int extraction from pcall result array. */
    private static int intVal(Object[] r, int i) {
        return (r != null && r.length > i && r[i] instanceof Number) ? ((Number)r[i]).intValue() : 0;
    }

    /** Safe string extraction from pcall result array. */
    private static String strVal(Object[] r, int i) {
        return (r != null && r.length > i && r[i] != null) ? r[i].toString() : "";
    }

    private static void printUsage() {
        System.out.println("PZ Test Kit — runs mod tests on PZ's actual Kahlua VM.");
        System.out.println();
        System.out.println("Usage: pztest [mod_root] [flags] [modules...] [-- tests...]");
        System.out.println();
        System.out.println("  mod_root         Path to your mod (defaults to cwd via the wrapper).");
        System.out.println();
        System.out.println("Flags:");
        System.out.println("  --list             List discovered test files and exit (no execution)");
        System.out.println("  --filter <pat>     Run only tests whose name matches the Lua pattern");
        System.out.println("  --fail-fast        Stop at the first file containing a failure");
        System.out.println("  --junit-xml <path> Write JUnit XML report (CI integration)");
        System.out.println("  --event-coverage   Report which Events.* listeners fired vs. registered");
        System.out.println("  -h, --help         Show this message");
        System.out.println();
        System.out.println("  modules          (optional) Lua files to load before tests. Usually");
        System.out.println("                   unnecessary — the require resolver auto-discovers");
        System.out.println("                   modules from media/lua/.");
        System.out.println("  --               Separator (tests auto-discovered if omitted)");
        System.out.println("  tests            Test files to run (relative to mod_root)");
        System.out.println();
        System.out.println("Examples:");
        System.out.println("  pztest                                # run everything from cwd");
        System.out.println("  pztest --filter upgrade               # only tests with 'upgrade' in name");
        System.out.println("  pztest --list                         # list test files");
        System.out.println("  pztest /path/to/MyMod --fail-fast     # stop at first failure");
    }
}
