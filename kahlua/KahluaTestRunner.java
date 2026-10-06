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

    // Coverage (set from --coverage[=<substr>]). Static so buildEnv (which builds
    // every env, incl. DualVMSim subs) can wire the instrumentation in.
    private static boolean coverageOn = false;
    // Engine mode (EngineBridge): real PZ classes, real scripts, real items.
    private static boolean engineOn = false;
    private static boolean engineForcedOff = false;
    // --engine-mods: also parse the config's `engine_mods` (third-party mods'
    // scripts). Opt-in PER RUN, never by config alone: packs commonly declare
    // `module Base` and REDEFINE vanilla items (Base.Shotgun, Base.Pistol...),
    // so loading them for a whole suite silently swaps vanilla out from under
    // every other test. Run the files that want them with the flag.
    private static boolean engineModsOn = false;
    // --lua-mod <spec> (repeatable): third-party mods whose LUA runs too, not
    // just their scripts (the interop smoke test: docs/lua-mods.md). Same
    // specs as engine_mods (workshop:<id>/<folder>, or a path). Their
    // scripts load with them, their files join the module index after the
    // mod under test and its dependencies, and _pz_mod_load lists every
    // mod's files in the game's load order (LuaManager.LoadDirBase: one mod
    // at a time; listed mods, then dependencies, then the mod under test).
    // Per run only, like --engine-mods.
    private static final List<String> luaModSpecs = new ArrayList<>();
    private static final List<Path> luaModVariants = new ArrayList<>();
    private static String  coverageScope = null;
    private static boolean coverageLines = false;   // --coverage-lines: dump uncovered line ranges
    private static boolean coveragePerTest = false; // --coverage-per-test: record which lines EACH test ran

    // --fidelity: which layer provides each global (mock / kit / vanilla /
    // engine / mod), which earlier layer it overrode, and how often the suite
    // called each mock, vanilla and engine function. Captured from the first
    // primary env; call counts aggregate across files.
    private static boolean fidelityOn = false;
    private static final Map<String, String> fidLayer = new LinkedHashMap<>();
    private static final Map<String, String> fidOverrode = new LinkedHashMap<>();
    private static final Map<String, String> fidKind = new HashMap<>();
    private static boolean fidCaptured = false;
    private static String reportFidelityJson = null;

    // --report-json: per-entry outcome of vanilla_requires ("ok" | "miss" |
    // "fail" | "exc" | "no-install"), last env wins (every env loads the same
    // list). Read only by the report writer.
    private static final Map<String, String> vanillaStatus = new LinkedHashMap<>();

    // Contract pass (contract.lua): 0 = auto (full-suite runs only),
    // 1 = --contract (always), -1 = --no-contract.
    private static int contractMode = 0;

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
        String reportJsonPath = null;   // --report-json <path>: full machine-readable run record
        String onlyListPath   = null;   // --only <file>: exact "testFile::testName" lines to run
        boolean eventCoverage = false;
        String serveScene     = null;   // --serve <scene>: resident UI render loop
        boolean bridgeOn      = false;  // --bridge: resident eval bridge (b64 line protocol)
        String  bridgeRole    = null;   // --role server|client: a SousVide MP side
        int     bridgeClient  = 0;      // --client-index N (role client)
        boolean verbose       = false;  // --verbose: stream all output live (legacy behavior)
        boolean noPrescan     = false;  // --no-prescan: disable filter file pre-skip

        boolean afterSep = false;
        for (int i = 1; i < args.length; i++) {
            String a = args[i];
            if (a.equals("--")) { afterSep = true; continue; }
            if (!afterSep && a.startsWith("--")) {
                if (a.equals("--list"))      { listOnly = true; continue; }
                if (a.equals("--fail-fast")) { failFast = true; continue; }
                if (a.equals("--contract")) { contractMode = 1; continue; }
                if (a.equals("--no-contract")) { contractMode = -1; continue; }
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
                if (a.equals("--report-json") && i + 1 < args.length) {
                    reportJsonPath = args[++i]; continue;
                }
                if (a.startsWith("--report-json=")) {
                    reportJsonPath = a.substring("--report-json=".length()); continue;
                }
                if (a.equals("--only") && i + 1 < args.length) {
                    onlyListPath = args[++i]; continue;
                }
                if (a.equals("--coverage-per-test")) { coverageOn = true; coveragePerTest = true; continue; }
                if (a.equals("--fidelity")) { fidelityOn = true; continue; }
                if (a.equals("--event-coverage")) { eventCoverage = true; continue; }
                if (a.equals("--coverage")) { coverageOn = true; continue; }
                if (a.equals("--coverage-lines")) { coverageOn = true; coverageLines = true; continue; }
                if (a.startsWith("--coverage=")) {
                    coverageOn = true; coverageScope = a.substring("--coverage=".length());
                    continue;
                }
                if (a.startsWith("--coverage-lines=")) {
                    coverageOn = true; coverageLines = true;
                    coverageScope = a.substring("--coverage-lines=".length()); continue;
                }
                if (a.equals("--serve") && i + 1 < args.length) {
                    serveScene = args[++i]; continue;
                }
                if (a.equals("--bridge")) { bridgeOn = true; continue; }
                if (a.equals("--role") && i + 1 < args.length) { bridgeRole = args[++i]; continue; }
                if (a.equals("--client-index") && i + 1 < args.length) { bridgeClient = Integer.parseInt(args[++i]); continue; }
                if (a.startsWith("--serve=")) {
                    serveScene = a.substring("--serve=".length()); continue;
                }
                if (a.equals("--verbose") || a.equals("-v")) { verbose = true; continue; }
                if (a.equals("--no-prescan")) { noPrescan = true; continue; }
                if (a.equals("--engine")) { engineOn = true; continue; }
                if (a.equals("--no-engine")) { engineOn = false; engineForcedOff = true; continue; }
                if (a.equals("--engine-mods")) { engineOn = true; engineModsOn = true; continue; }
                // one spec per --lua-mod: a ';'-joined list is a POSIX path
                // list to Git Bash, which rewrites it before java sees it
                if (a.equals("--lua-mod") && i + 1 < args.length) {
                    if (!args[++i].isBlank()) luaModSpecs.add(args[i].trim());
                    engineOn = true; continue;
                }
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

        // Aggregated line coverage across files: per source path, the union of
        // instrumented POINTS (denominator) and HIT lines (numerator). Used by
        // --coverage. A fresh env re-instruments each file, so unioning across
        // files gives whole-suite coverage.
        Map<String, CovFile> covAccum = coverageOn ? new LinkedHashMap<>() : null;

        // Positional args that LOOK like test files (test_*.lua / *Tests.lua)
        // are test files, not env modules. Historically `pztest path/Tests/Foo.lua`
        // fed the file to loadStripped() as a module — the require-stripper
        // mangled it, the env build blew up with an opaque nested
        // RuntimeException, AND the full suite still ran (tests stayed empty →
        // discovery). Single-file runs are what an agent reaches for first;
        // make the obvious invocation do the obvious thing.
        for (Iterator<String> it = modules.iterator(); it.hasNext(); ) {
            String m = it.next();
            String norm = m.replace('\\', '/');
            String base = norm.substring(norm.lastIndexOf('/') + 1);
            boolean looksLikeTest = base.endsWith(".lua")
                && (base.startsWith("test_") || base.endsWith("Tests.lua"));
            if (looksLikeTest && Files.exists(modRoot.resolve(norm))) {
                it.remove();
                tests.add(norm);
            }
        }

        // --only: an exact selection (smart reruns pick tests by coverage
        // impact). The listed files ARE the test files; each file's env gets
        // its name set as _pz_only. Blank lines and # comments are ignored; a
        // bare file line (no ::) runs that whole file.
        Map<String, Set<String>> onlyMap = null;
        // `--only Foo.lua` (the MCP `test` tool's `only`, and anyone typing it)
        // names ONE TEST FILE, not a list: run exactly that file. And a list
        // path that is not absolute resolves against the MOD ROOT -- the
        // runner cd's into kahlua/, so a relative path read from cwd never
        // existed (NoSuchFileException at this line, 2026-10-05).
        if (onlyListPath != null && onlyListPath.toLowerCase().endsWith(".lua")) {
            String f = onlyListPath.replace('\\', '/');
            Path abs = Paths.get(f);
            if (abs.isAbsolute()) {
                Path root = modRoot.toAbsolutePath().normalize();
                Path n = abs.toAbsolutePath().normalize();
                f = n.startsWith(root) ? root.relativize(n).toString().replace('\\', '/') : n.toString();
            }
            onlyMap = new LinkedHashMap<>();
            onlyMap.put(f, new LinkedHashSet<>());
            tests = new ArrayList<>(onlyMap.keySet());
            onlyListPath = null;
        } else if (onlyListPath != null && !Paths.get(onlyListPath).isAbsolute()
                   && !Files.exists(Paths.get(onlyListPath))) {
            onlyListPath = modRoot.resolve(onlyListPath).toString();
        }
        if (onlyListPath != null) {
            onlyMap = new LinkedHashMap<>();
            for (String ln : Files.readAllLines(Paths.get(onlyListPath))) {
                ln = ln.trim();
                if (ln.isEmpty() || ln.startsWith("#")) continue;
                int sep = ln.indexOf("::");
                if (sep < 0) { onlyMap.computeIfAbsent(ln, _k -> new LinkedHashSet<>()); continue; }
                onlyMap.computeIfAbsent(ln.substring(0, sep), _k -> new LinkedHashSet<>()).add(ln.substring(sep + 2));
            }
            tests = new ArrayList<>(onlyMap.keySet());
        }

        // A selective run (explicit files, --filter, --only) skips the
        // contract pass unless --contract asks for it: it is whole-mod.
        final boolean selectiveRun = !tests.isEmpty() || filterPattern != null || onlyListPath != null;

        if (tests.isEmpty()) tests = discoverTests(modRoot);

        kahluaDir = resolveKahluaDir();
        KitLua.root = kahluaDir;  // enable Lua-file loading helper used by DualVMSim + buildEnv

        // ── Engine mode (EngineBridge) ──────────────────────────────
        // Opt-in via `engine = true` in pz-test.lua or --engine; --no-engine
        // overrides. The config sniff is a regex on the source because the
        // config proper is parsed per-file in Lua, and the engine must boot
        // once, before any env exists. Boot failure is not fatal: PZEngine
        // installs as unavailable and engine-guarded tests skip themselves.
        if (!engineForcedOff && !engineOn) {
            Path cfg = modRoot.resolve("pz-test.lua");
            if (Files.exists(cfg)) {
                String src = Files.readString(cfg);
                engineOn = java.util.regex.Pattern
                    .compile("(?m)^\\s*engine\\s*=\\s*true").matcher(src).find();
            }
        }
        if (engineOn) {
            // engine_mods: other mods whose SCRIPTS the engine parses too
            // (real third-party items, no third-party Lua), only under
            // --engine-mods (see engineModsOn). Regex-sniffed
            // like `engine` above, and for a sharper reason than convenience:
            // building ANY Kahlua env before boot touches zombie.* classes
            // (PZMath among them) while projectzomboid.jar is not yet on the
            // loader, so StubbingClassLoader synthesizes EMPTY ones and caches
            // them -- every real caller then dies with NoSuchMethodError
            // (PZMath.nextPowerOfTwo in ObjectSet.tableSize). Strings only:
            // the block is `engine_mods = { "spec", "spec", ... }`.
            List<String> engineMods = new ArrayList<>();
            Path cfgPath = modRoot.resolve("pz-test.lua");
            if (engineModsOn && Files.exists(cfgPath)) {
                String src = Files.readString(cfgPath).replaceAll("--[^\\n]*", "");
                var block = java.util.regex.Pattern
                    .compile("(?s)\\bengine_mods\\s*=\\s*\\{(.*?)\\}").matcher(src);
                if (block.find()) {
                    var str = java.util.regex.Pattern.compile("\"([^\"]+)\"|'([^']+)'").matcher(block.group(1));
                    while (str.find()) engineMods.add(str.group(1) != null ? str.group(1) : str.group(2));
                }
            }
            // a mod whose Lua runs needs its items too
            for (String sp : luaModSpecs) if (!engineMods.contains(sp)) engineMods.add(sp);
            EngineBridge.fillFromGame = !luaModSpecs.isEmpty();
            EngineBridge.boot(null, modRoot, engineMods, System.out);
        }

        // ── Serve mode: resident VM that renders a scene + replays input ────
        // Build the env once, bootstrap the scene, then loop reading newline
        // input commands on stdin and printing one frame per command on stdout.
        // The bridge (Node) pipes browser events in and frames out.
        if (serveScene != null) {
            serveMode(modRoot, serveScene);
            return;
        }

        // ── Bridge mode: resident VM as an eval server ──────────────────────
        // Generic sibling of serve mode: the FULL kit environment (config,
        // module index, mocks, translations) stays resident, and a driver
        // process (e.g. a local designer-UI server) evals Lua chunks against
        // it. This is how external tooling drives REAL mod code — a story
        // designer scrubbing seeds runs the actual director, never a JS
        // reimplementation.
        if (bridgeOn) {
            bridgeMode(modRoot, bridgeRole, bridgeClient);
            return;
        }

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

        // Filter pre-scan: when the filter is a plain substring (no Lua
        // pattern magic), a test file whose SOURCE never contains that
        // substring cannot register a matching test name — skip it before
        // paying the per-file env boot (~60ms each; the whole point of
        // --filter is a fast loop). Dynamically concatenated test names are
        // the one blind spot; --no-prescan runs every file the old way.
        int preSkipped = 0;
        if (filterPattern != null && !noPrescan
                && filterPattern.matches("[A-Za-z0-9_ /:]+")) {
            List<String> kept = new ArrayList<>();
            for (String t : tests) {
                Path p = modRoot.resolve(t);
                boolean keep = true;
                if (t.contains(filterPattern)) {
                    keep = true;   // file-name match always runs
                } else {
                    try {
                        keep = Files.exists(p) && Files.readString(p).contains(filterPattern);
                    } catch (IOException e) {
                        keep = true;   // unreadable → run it, let the loop report
                    }
                }
                if (keep) kept.add(t); else preSkipped++;
            }
            tests = kept;
        }

        if (tests.isEmpty()) {
            if (preSkipped > 0) {
                System.out.println("No test file contains '" + filterPattern +
                    "' (" + preSkipped + " pre-skipped; --no-prescan to force-run all).");
                System.exit(1);
            }
            // A mod with no tests still gets the contract pass -- it needs
            // no tests, and untested mods are where it matters most.
            boolean contractRuns = contractMode == 1 || (contractMode == 0 && !selectiveRun);
            if (!contractRuns) {
                System.err.println("No test files found.");
                System.exit(1);
            }
            System.out.println("No test files found -- running the contract pass only.");
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
        if (!selectiveRun) noteUnreplayedBoards(modRoot, tests);

        // ── Run each test file in an isolated runtime ───────────────
        int grandTotal = 0, grandPass = 0, grandFail = 0, grandErr = 0;

        // Failure digest: (file, test, message) per failing/erroring test,
        // printed after the KAHLUA TOTAL block so `tail` shows totals AND
        // what broke without grepping the transcript.
        List<String[]> failDigest = new ArrayList<>();
        int hiddenNoMatch = 0;   // files whose filter matched 0 tests (suppressed)
        if (preSkipped > 0) {
            System.out.println("[filter] pre-skipped " + preSkipped +
                " file(s) without '" + filterPattern + "' in source (--no-prescan to run all)");
        }

        // --report-json: one record per test file, plus the resolved config
        // (captured once from the first env that loaded it).
        List<ReportFile> reportFiles = reportJsonPath != null ? new ArrayList<>() : null;
        String reportConfigJson = null;
        String reportStartedAt = java.time.OffsetDateTime.now().toString();

        // --fidelity: per-name call totals and files that called each; classes
        // synthesized empty AFTER boot (i.e. reached while tests ran) per file.
        Map<String, long[]> fidCalls = new TreeMap<>();   // name -> {calls, files}
        List<String[]> fidSynthRuntime = new ArrayList<>(); // {class, testFile}
        Set<String> synthSeen = fidelityOn ? new HashSet<>(synthesizedClasses()) : null;
        int synthAtBoot = synthSeen != null ? synthSeen.size() : 0;

        long grandStartNs = System.nanoTime();
        for (String testFile : tests) {
            Path testPath = modRoot.resolve(testFile);
            if (!Files.exists(testPath)) {
                System.out.println("\n  SKIP: " + testFile + " (not found)");
                continue;
            }
            long fileStartNs = System.nanoTime();

            // Buffer everything this file prints (env boot logs, mod debug
            // spew, DIAG lines) and replay it ONLY if the file fails. Lua's
            // print binds to the CURRENT System.out inside the TestPlatform
            // constructor (BaseLib.setPrintCallback), so the swap must happen
            // before construction. --verbose streams live (legacy behavior).
            PrintStream realOut = System.out;
            ByteArrayOutputStream fileBuf = null;
            if (!verbose) {
                fileBuf = new ByteArrayOutputStream();
                System.setOut(new PrintStream(fileBuf, true, java.nio.charset.StandardCharsets.UTF_8));
            }

            String fileError = null;
            Object[] res = null;
            KahluaTable env = null;

            try {
                // Fresh Kahlua runtime
                TestPlatform platform = new TestPlatform();
                env = platform.newEnvironment();
                KahluaThread thread = new KahluaThread(System.out, platform, env);
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
                // --only: exact names for this file (an empty set = whole file).
                Set<String> onlyNames = onlyMap != null ? onlyMap.get(testFile) : null;
                if (onlyNames != null && !onlyNames.isEmpty()) {
                    KahluaTable only = new se.krka.kahlua.j2se.KahluaTableImpl(new java.util.HashMap<>());
                    for (String n : onlyNames) only.rawset(n, Boolean.TRUE);
                    env.rawset("_pz_only", only);
                }

                // 5. Test file → pass the source through to context/load_test_file.lua,
                //    which wraps it and captures the returned table into _pz_last_return.
                try {
                    env.rawset("_pz_test_source", stripContextGuards(Files.readString(testPath)));
                    env.rawset("_pz_test_name", testFile);
                    loadFile(thread, env, kahluaDir.resolve("context/load_test_file.lua"));
                } catch (Exception e) {
                    fileError = "load error: " + e.getMessage();
                }

                // 6. Execute tests via test_executor.lua
                if (fileError == null) {
                    res = execFile(thread, env, kahluaDir.resolve("test_executor.lua"));
                    // Surface test_executor errors so they don't look like "0 tests"
                    if (res != null && res.length > 0 && Boolean.FALSE.equals(res[0])) {
                        fileError = "executor error: " + (res.length > 1 ? res[1] : "unknown");
                    }
                }
            } catch (Exception e) {
                fileError = "env build error: " + e.getMessage();
            } finally {
                if (fileBuf != null) System.setOut(realOut);
            }

            long fileMs = (System.nanoTime() - fileStartNs) / 1_000_000L;

            // File-level failure (load / env / executor): counts as an error —
            // a broken file must never exit 0 just because other files passed.
            if (reportFiles != null) {
                if (reportConfigJson == null && env != null && env.rawget("_pz_config") instanceof KahluaTable)
                    reportConfigJson = luaToJson(env.rawget("_pz_config"), 0);
            }

            if (fidelityOn && env != null) {
                // Globals that appeared only after buildEnv were defined by
                // the mod's modules or the test file itself.
                KahluaTableIterator git = env.iterator();
                while (git.advance()) {
                    if (!(git.getKey() instanceof String)) continue;
                    String k = (String) git.getKey();
                    if (k.startsWith("_pz") || k.startsWith("__") || fidLayer.containsKey(k)) continue;
                    fidLayer.put(k, "mod");
                    fidKind.put(k, luaKind(git.getValue()));
                }
                if (env.rawget("_pz_fid_calls") instanceof KahluaTable calls) {
                    KahluaTableIterator ci = calls.iterator();
                    while (ci.advance()) {
                        if (!(ci.getKey() instanceof String) || !(ci.getValue() instanceof Number)) continue;
                        long[] agg = fidCalls.computeIfAbsent((String) ci.getKey(), _k -> new long[2]);
                        agg[0] += ((Number) ci.getValue()).longValue();
                        agg[1]++;
                    }
                }
                List<String> now;
                synchronized (synthesizedClasses()) { now = new ArrayList<>(synthesizedClasses()); }
                for (String c : now) if (synthSeen.add(c)) fidSynthRuntime.add(new String[]{ c, testFile });
            }

            if (fileError != null) {
                if (reportFiles != null) {
                    ReportFile rf = new ReportFile();
                    rf.file = testFile; rf.ms = fileMs; rf.error = fileError; rf.errors = 1;
                    rf.output = bufferText(fileBuf);
                    reportFiles.add(rf);
                }
                grandErr += 1;
                failDigest.add(new String[]{ testFile, "<file>", fileError });
                System.out.printf("%n--- %s (ERROR, %dms) --- *** %s ***%n",
                    testFile, fileMs, fileError);
                replayBuffer(fileBuf);
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

            // Pull the skipped count from the env (set by test_executor).
            int skipped = 0;
            Object skipRaw = env.rawget("_pz_last_skipped_count");
            if (skipRaw instanceof Number) skipped = ((Number) skipRaw).intValue();
            grandSkip += skipped;

            // Parse per-test records once — feeds the failure digest and JUnit.
            List<JUnitCase> cases = parseTestRecords(env);
            for (JUnitCase c : cases) {
                if ("fail".equals(c.status) || "error".equals(c.status)) {
                    failDigest.add(new String[]{ testFile, c.name, c.message });
                }
            }

            boolean failedFile = (fail + errs) > 0;
            if (total == 0 && filterPattern != null && !failedFile) {
                hiddenNoMatch++;   // filter matched nothing in this file — stay quiet
            } else {
                String flag = failedFile ? " *** FAILURES ***" : "";
                System.out.printf("%n--- %s (%d tests, %dms) ---%s%n", testFile, total, fileMs, flag);
                if (!detail.isEmpty()) {
                    for (String line : detail.split("\n"))
                        System.out.println("    " + line);
                }
                if (skipped > 0) {
                    System.out.printf("    (%d skipped)%n", skipped);
                }
                if (failedFile) replayBuffer(fileBuf);
            }

            if (reportFiles != null) {
                ReportFile rf = new ReportFile();
                rf.file = testFile; rf.ms = fileMs;
                rf.tests = total; rf.passed = pass; rf.failures = fail; rf.errors = errs; rf.skipped = skipped;
                rf.cases.addAll(cases);
                if (failedFile) rf.output = bufferText(fileBuf);
                reportFiles.add(rf);
            }

            // Collect per-test records for JUnit XML (if requested).
            if (junitSuites != null) {
                JUnitSuite suite = new JUnitSuite();
                suite.name = testFile;
                suite.tests = total;
                suite.failures = fail;
                suite.errors = errs;
                suite.skipped = skipped;
                suite.cases.addAll(cases);
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

            // Accumulate line coverage from this file's env.
            if (covAccum != null) {
                Object cov = env.rawget("_pz_coverage");
                if (cov instanceof KahluaTable) {
                    KahluaTable t = (KahluaTable) cov;
                    KahluaTableIterator it = t.iterator();
                    while (it.advance()) {
                        Object k = it.getKey();
                        Object v = it.getValue();
                        if (k instanceof String && v instanceof KahluaTable) {
                            KahluaTable e = (KahluaTable) v;
                            CovFile cf = covAccum.computeIfAbsent((String) k, _p -> new CovFile());
                            Object nm = e.rawget("name");
                            if (nm instanceof String) cf.name = (String) nm;
                            if (Boolean.TRUE.equals(e.rawget("fallback"))) cf.fallback = true;
                            unionLineSet(e.rawget("points"), cf.points);
                            unionLineSet(e.rawget("hit"), cf.hit);
                        }
                    }
                }
            }

            if (failFast && (fail + errs) > 0) {
                System.out.println("\n--fail-fast: stopping on first failing file");
                break;
            }
        }

        // -- Contract pass: whole-mod MP invariants, no test required --
        if (contractMode == 1 || (contractMode == 0 && !selectiveRun)) {
            int[] c = runContract(modRoot, index, modules, verbose, failDigest);
            grandTotal += c[0]; grandPass += c[1]; grandFail += c[2]; grandErr += c[3];
            grandSkip += c[4];
        }

        if (eventAccum != null) {
            printEventCoverage(eventAccum);
        }

        if (covAccum != null) {
            printCoverage(covAccum, coverageScope);
        }

        // Write JUnit XML report if requested.
        if (junitXmlPath != null) {
            writeJUnitXml(junitSuites, Paths.get(junitXmlPath));
            System.out.println("JUnit XML written to " + junitXmlPath);
        }

        // ── Summary ─────────────────────────────────────────────────
        long grandMs = (System.nanoTime() - grandStartNs) / 1_000_000L;

        if (reportJsonPath != null) {
            if (fidelityOn) {
                StringBuilder fj = new StringBuilder("{\"layers\":{");
                boolean f = true;
                for (Map.Entry<String, String> e : new TreeMap<>(fidLayer).entrySet()) {
                    if (!f) fj.append(',');
                    f = false;
                    fj.append(js(e.getKey())).append(":[").append(js(e.getValue())).append(',')
                      .append(js(fidKind.getOrDefault(e.getKey(), "?"))).append(',')
                      .append(js(fidOverrode.get(e.getKey()))).append(']');
                }
                fj.append("},\"calls\":{");
                f = true;
                for (Map.Entry<String, long[]> e : fidCalls.entrySet()) {
                    if (!f) fj.append(',');
                    f = false;
                    fj.append(js(e.getKey())).append(":[").append(e.getValue()[0]).append(',').append(e.getValue()[1]).append(']');
                }
                fj.append("},\"synthAtBoot\":").append(synthAtBoot).append(",\"synthRuntime\":[");
                for (int i = 0; i < fidSynthRuntime.size(); i++) {
                    if (i > 0) fj.append(',');
                    fj.append('[').append(js(fidSynthRuntime.get(i)[0])).append(',').append(js(fidSynthRuntime.get(i)[1])).append(']');
                }
                fj.append("]}");
                reportFidelityJson = fj.toString();
            }
            writeReportJson(Paths.get(reportJsonPath), modRoot, args, reportStartedAt, grandMs,
                grandTotal, grandPass, grandFail, grandErr, grandSkip,
                filterPattern, reportFiles, reportConfigJson, covAccum, eventAccum, preSkipped);
            System.out.println("Report JSON written to " + reportJsonPath);
        }
        if (hiddenNoMatch > 0) {
            System.out.printf("%n(%d file(s) with no tests matching the filter — hidden)%n", hiddenNoMatch);
        }
        // Engine-mode coverage visibility: a config that asked for the
        // engine on a machine without PZ still exits green (engine-guarded
        // files contribute no tests) — but that reduced coverage must be
        // SAID, not silent. CI greps for this exact prefix.
        if (engineOn && !EngineBridge.isBooted()) {
            System.out.println("\nENGINE UNAVAILABLE: " + EngineBridge.getBootError());
            System.out.println("ENGINE UNAVAILABLE: engine-guarded test files contributed no tests — coverage is reduced on this machine.");
        }

        System.out.println("\n====================================================");
        if (grandSkip > 0) {
            System.out.printf("KAHLUA TOTAL: %d tests, %d passed, %d failed, %d errors, %d skipped (%dms)%n",
                    grandTotal, grandPass, grandFail, grandErr, grandSkip, grandMs);
        } else {
            System.out.printf("KAHLUA TOTAL: %d tests, %d passed, %d failed, %d errors (%dms)%n",
                    grandTotal, grandPass, grandFail, grandErr, grandMs);
        }
        System.out.println("====================================================");

        // Failure digest LAST so `tail -20` always shows the totals AND every
        // failing test with its assertion message — no transcript grepping.
        if (!failDigest.isEmpty()) {
            System.out.println("FAILED TESTS (" + failDigest.size() + "):");
            for (String[] f : failDigest) {
                System.out.println("  FAIL " + f[0] + " :: " + f[1]);
                if (f[2] != null && !f[2].isEmpty()) {
                    for (String line : f[2].split("\n"))
                        System.out.println("       " + line);
                }
            }
            System.out.println("====================================================");
        }
        // A run that executed ZERO tests is a failure, not a success. The
        // usual cause is a --filter that matched nothing (filter matches
        // test NAMES; a fresh test whose name lacks the filter string used
        // to run 0 tests and exit green — the worst kind of green).
        if (grandTotal == 0) {
            if (filterPattern != null) {
                System.out.println("*** ZERO TESTS RAN: filter '" + filterPattern
                        + "' matched no test names (filters match test names, not file names) ***");
            } else {
                System.out.println("*** ZERO TESTS RAN: no test produced a result — "
                        + "check test_paths/test_file_patterns in pz-test.lua ***");
            }
            System.exit(1);
        }
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

    // ── Line coverage ───────────────────────────────────────────────

    /** Accumulated coverage for one source file across the whole suite. */
    private static class CovFile {
        String name;
        final Set<Integer> points = new HashSet<>();   // instrumented lines (denominator)
        final Set<Integer> hit    = new HashSet<>();   // executed lines (numerator)
        boolean fallback = false;                       // instrumentation fell back -> not covered
    }

    /** Union a Kahlua line-set ({[line]=true}) into a Java Set<Integer>. */
    private static void unionLineSet(Object raw, Set<Integer> into) {
        if (!(raw instanceof KahluaTable)) return;
        KahluaTableIterator it = ((KahluaTable) raw).iterator();
        while (it.advance()) {
            Object k = it.getKey();
            if (k instanceof Number) into.add(((Number) k).intValue());
        }
    }

    /** Print a per-file line-coverage report + a suite total. */
    private static void printCoverage(Map<String, CovFile> accum, String scope) {
        System.out.println("\n--- Line coverage" + (scope != null ? " (scope: " + scope + ")" : "") + " ---");
        // Stable, readable order: by display name.
        List<CovFile> files = new ArrayList<>(accum.values());
        files.sort(Comparator.comparing(c -> c.name != null ? c.name : ""));

        int grandPoints = 0, grandHit = 0, covered = 0;
        boolean any = false;
        List<String> fellBack = new ArrayList<>();
        for (CovFile cf : files) {
            if (cf.fallback || cf.points.isEmpty()) {
                if (cf.fallback) fellBack.add(cf.name != null ? cf.name : "?");
                continue;
            }
            any = true;
            int total = cf.points.size();
            int h = 0;
            for (Integer ln : cf.points) if (cf.hit.contains(ln)) h++;
            grandPoints += total; grandHit += h; covered++;
            int pct = total > 0 ? (int) Math.round(100.0 * h / total) : 100;
            System.out.printf("  %-44s %3d%%  (%4d/%4d)%n",
                cf.name != null ? cf.name : "?", pct, h, total);
            // --coverage-lines: list the uncovered statement-lines, compressed to
            // ranges (a-b), so you can jump straight to the untested code.
            if (coverageLines && h < total) {
                List<Integer> miss = new ArrayList<>();
                for (Integer ln : cf.points) if (!cf.hit.contains(ln)) miss.add(ln);
                Collections.sort(miss);
                StringBuilder sb = new StringBuilder();
                for (int i = 0; i < miss.size(); ) {
                    int start = miss.get(i), end = start, j = i + 1;
                    while (j < miss.size() && miss.get(j) == end + 1) { end = miss.get(j); j++; }
                    if (sb.length() > 0) sb.append(", ");
                    sb.append(start == end ? String.valueOf(start) : (start + "-" + end));
                    i = j;
                }
                System.out.printf("        uncovered: %s%n", sb.toString());
            }
        }
        if (!any) {
            System.out.println("  (no instrumented lines — check --coverage scope)");
        } else {
            int pct = grandPoints > 0 ? (int) Math.round(100.0 * grandHit / grandPoints) : 0;
            System.out.printf("  %-44s %3d%%  (%4d/%4d)  [%d files]%n",
                "TOTAL", pct, grandHit, grandPoints, covered);
        }
        if (!fellBack.isEmpty()) {
            System.out.printf("  (%d file(s) fell back to uninstrumented, not counted: %s)%n",
                fellBack.size(), String.join(", ", fellBack));
        }
    }

    // ── JSON report (--report-json) ─────────────────────────────────
    //
    // One self-contained record of a run, for dashboard/ (and anything else
    // that would otherwise scrape console text). Schema version bumps on any
    // breaking change; additive fields don't bump it.

    private static class ReportFile {
        String file, error, output;
        long ms;
        int tests, passed, failures, errors, skipped;
        List<JUnitCase> cases = new ArrayList<>();
    }

    private static String bufferText(ByteArrayOutputStream buf) {
        if (buf == null || buf.size() == 0) return null;
        String s = buf.toString(java.nio.charset.StandardCharsets.UTF_8);
        int cap = 64 * 1024;
        return s.length() > cap ? "... (truncated)\n" + s.substring(s.length() - cap) : s;
    }

    private static String js(String s) {
        if (s == null) return "null";
        StringBuilder sb = new StringBuilder(s.length() + 2).append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"':  sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\n': sb.append("\\n"); break;
                case '\r': sb.append("\\r"); break;
                case '\t': sb.append("\\t"); break;
                default:
                    if (c < 0x20) sb.append(String.format("\\u%04x", (int) c));
                    else sb.append(c);
            }
        }
        return sb.append('"').toString();
    }

    /** Sorted line set -> "1-4,9,12-13". */
    private static String ranges(Set<Integer> sorted) {
        StringBuilder sb = new StringBuilder();
        Integer start = null, prev = null;
        for (Integer n : sorted) {
            if (start == null) { start = prev = n; continue; }
            if (n == prev + 1) { prev = n; continue; }
            if (sb.length() > 0) sb.append(',');
            sb.append(start.equals(prev) ? String.valueOf(start) : start + "-" + prev);
            start = prev = n;
        }
        if (start != null) {
            if (sb.length() > 0) sb.append(',');
            sb.append(start.equals(prev) ? String.valueOf(start) : start + "-" + prev);
        }
        return sb.toString();
    }

    private static String jsonInts(Collection<Integer> xs) {
        List<Integer> l = new ArrayList<>(xs);
        Collections.sort(l);
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < l.size(); i++) { if (i > 0) sb.append(','); sb.append(l.get(i)); }
        return sb.append(']').toString();
    }

    /** Lua value → JSON. Sequences become arrays; functions/userdata become
     *  a "<type>" string so the config viewer shows they exist. */
    private static String luaToJson(Object v, int depth) {
        if (v == null) return "null";
        if (v instanceof Boolean) return v.toString();
        if (v instanceof Number) {
            double d = ((Number) v).doubleValue();
            if (Double.isNaN(d) || Double.isInfinite(d)) return js(String.valueOf(d));
            return d == Math.rint(d) && Math.abs(d) < 1e15 ? String.valueOf((long) d) : String.valueOf(d);
        }
        if (v instanceof String) return js((String) v);
        if (v instanceof KahluaTable) {
            if (depth > 8) return js("<table: too deep>");
            KahluaTable t = (KahluaTable) v;
            List<Object> keys = new ArrayList<>();
            KahluaTableIterator it = t.iterator();
            while (it.advance()) keys.add(it.getKey());
            boolean seq = !keys.isEmpty();
            for (int i = 1; seq && i <= keys.size(); i++) if (t.rawget(i) == null) seq = false;
            StringBuilder sb = new StringBuilder();
            if (seq) {
                sb.append('[');
                for (int i = 1; i <= keys.size(); i++) {
                    if (i > 1) sb.append(',');
                    sb.append(luaToJson(t.rawget(i), depth + 1));
                }
                return sb.append(']').toString();
            }
            keys.sort(Comparator.comparing(String::valueOf));
            sb.append('{');
            boolean first = true;
            for (Object k : keys) {
                if (!first) sb.append(',');
                first = false;
                sb.append(js(String.valueOf(k))).append(':').append(luaToJson(t.rawget(k), depth + 1));
            }
            return sb.append('}').toString();
        }
        if (v instanceof LuaClosure || v instanceof JavaFunction) return js("<function>");
        return js("<" + v.getClass().getSimpleName() + ">");
    }

    private static void writeReportJson(Path outPath, Path modRoot, String[] args, String startedAt, long ms,
            int total, int pass, int fail, int err, int skip, String filter,
            List<ReportFile> files, String configJson,
            Map<String, CovFile> cov, Map<String, int[]> events, int preSkipped) throws IOException {
        StringBuilder sb = new StringBuilder(64 * 1024);
        sb.append("{\n\"schema\":1");
        sb.append(",\n\"modRoot\":").append(js(modRoot.toString().replace('\\', '/')));
        sb.append(",\n\"startedAt\":").append(js(startedAt));
        sb.append(",\n\"ms\":").append(ms);
        sb.append(",\n\"args\":[");
        for (int i = 1; i < args.length; i++) { if (i > 1) sb.append(','); sb.append(js(args[i])); }
        sb.append(']');
        sb.append(",\n\"filter\":").append(js(filter));
        sb.append(",\n\"preSkipped\":").append(preSkipped);
        sb.append(",\n\"gameVersion\":").append(js(installedBuildVersion()));
        Path pz = resolvePZInstall();
        sb.append(",\n\"pzInstall\":").append(js(pz != null ? pz.toString().replace('\\', '/') : null));
        sb.append(",\n\"engine\":{\"requested\":").append(engineOn)
          .append(",\"booted\":").append(engineOn && EngineBridge.isBooted())
          .append(",\"error\":").append(js(engineOn && !EngineBridge.isBooted() ? EngineBridge.getBootError() : null))
          .append('}');
        sb.append(",\n\"totals\":{\"tests\":").append(total).append(",\"passed\":").append(pass)
          .append(",\"failed\":").append(fail).append(",\"errors\":").append(err)
          .append(",\"skipped\":").append(skip).append('}');
        sb.append(",\n\"config\":").append(configJson != null ? configJson : "null");
        sb.append(",\n\"fidelity\":").append(reportFidelityJson != null ? reportFidelityJson : "null");

        sb.append(",\n\"vanillaRequires\":{");
        boolean first = true;
        for (Map.Entry<String, String> e : vanillaStatus.entrySet()) {
            if (!first) sb.append(',');
            first = false;
            sb.append(js(e.getKey())).append(':').append(js(e.getValue()));
        }
        sb.append('}');

        // Coverage file order, fixed up front so per-test coverage can refer to
        // files by index (coverage.files below is written in the same order).
        List<Map.Entry<String, CovFile>> covEntries = new ArrayList<>();
        Map<String, Integer> covIdx = new HashMap<>();
        if (cov != null) {
            covEntries.addAll(cov.entrySet());
            covEntries.sort(Comparator.comparing(e -> e.getValue().name != null ? e.getValue().name : ""));
            for (int i = 0; i < covEntries.size(); i++) covIdx.put(covEntries.get(i).getKey(), i);
        }

        sb.append(",\n\"files\":[");
        for (int i = 0; i < files.size(); i++) {
            ReportFile f = files.get(i);
            sb.append(i > 0 ? ",\n" : "\n");
            sb.append("{\"file\":").append(js(f.file))
              .append(",\"ms\":").append(f.ms)
              .append(",\"tests\":").append(f.tests).append(",\"passed\":").append(f.passed)
              .append(",\"failures\":").append(f.failures).append(",\"errors\":").append(f.errors)
              .append(",\"skipped\":").append(f.skipped)
              .append(",\"error\":").append(js(f.error))
              .append(",\"output\":").append(js(f.output))
              .append(",\"cases\":[");
            for (int j = 0; j < f.cases.size(); j++) {
                JUnitCase c = f.cases.get(j);
                if (j > 0) sb.append(',');
                sb.append("{\"name\":").append(js(c.name)).append(",\"status\":").append(js(c.status));
                if (c.message != null && !c.message.isEmpty()) sb.append(",\"message\":").append(js(c.message));
                if (c.ms >= 0) sb.append(",\"ms\":").append(String.format(java.util.Locale.ROOT, "%.2f", c.ms));
                if (c.output != null) sb.append(",\"output\":").append(js(c.output));
                if (c.cov != null && !c.cov.isEmpty()) {
                    // {"<coverage file index>": "1-4,9"}: ranges keep a
                    // 1000-test suite's report in the low megabytes.
                    sb.append(",\"cov\":{");
                    boolean fc = true;
                    for (Map.Entry<String, Set<Integer>> e : c.cov.entrySet()) {
                        Integer ix = covIdx.get(e.getKey());
                        if (ix == null || e.getValue().isEmpty()) continue;
                        if (!fc) sb.append(',');
                        fc = false;
                        sb.append('"').append(ix).append("\":\"").append(ranges(e.getValue())).append('"');
                    }
                    sb.append('}');
                }
                sb.append('}');
            }
            sb.append("]}");
        }
        sb.append("\n]");

        sb.append(",\n\"coverage\":");
        if (cov == null) sb.append("null");
        else {
            sb.append("{\"scope\":").append(js(coverageScope))
              .append(",\"perTest\":").append(coveragePerTest).append(",\"files\":[");
            boolean f1 = true;
            for (Map.Entry<String, CovFile> entry : covEntries) {
                String path = entry.getKey();
                CovFile cf = entry.getValue();
                Set<Integer> miss = new TreeSet<>(cf.points);
                miss.removeAll(cf.hit);
                Set<Integer> hit = new TreeSet<>(cf.points);
                hit.retainAll(cf.hit);
                if (!f1) sb.append(',');
                f1 = false;
                sb.append("\n{\"name\":").append(js(cf.name))
                  .append(",\"path\":").append(js(path != null ? path.replace('\\', '/') : null))
                  .append(",\"fallback\":").append(cf.fallback)
                  .append(",\"points\":").append(cf.points.size())
                  .append(",\"hit\":").append(jsonInts(hit))
                  .append(",\"miss\":").append(jsonInts(miss)).append('}');
            }
            sb.append("\n]}");
        }

        sb.append(",\n\"events\":");
        if (events == null) sb.append("null");
        else {
            sb.append('{');
            boolean f2 = true;
            for (Map.Entry<String, int[]> e : new TreeMap<>(events).entrySet()) {
                if (!f2) sb.append(',');
                f2 = false;
                sb.append(js(e.getKey())).append(":{\"registered\":").append(e.getValue()[0])
                  .append(",\"fired\":").append(e.getValue()[1]).append('}');
            }
            sb.append('}');
        }
        sb.append("\n}\n");

        Path abs = outPath.toAbsolutePath();
        if (abs.getParent() != null) Files.createDirectories(abs.getParent());
        Files.writeString(abs, sb.toString(), java.nio.charset.StandardCharsets.UTF_8);
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
        double ms = -1;  // --report-json only
        String output;   // --report-json only: what the test printed (capped)
        Map<String, Set<Integer>> cov;   // --coverage-per-test: path -> lines this test ran
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
    /**
     * Resident render loop. Builds one env, bootstraps the named scene via
     * UIView/ServeBoot (which defines UIView_serve_tick), then reads input
     * commands from stdin one per line and calls the tick — each tick prints a
     * single "@@FRAME@@<json>" line. Exits on EOF or "__quit__".
     *
     * Input command grammar (handled in ServeBoot.lua):
     *   click|down|up|move <x> <y> | wheel <x> <y> <d> | text <str> | reset | render
     */
    private static void serveMode(Path modRoot, String scene) throws Exception {
        ModuleIndex index = indexModuleTree(modRoot);
        TestPlatform platform = new TestPlatform();
        KahluaTable  env      = platform.newEnvironment();
        KahluaThread thread   = new KahluaThread(System.out, platform, env);
        thread.debugOwnerThread = Thread.currentThread();

        buildEnv(thread, env, modRoot, index, new ArrayList<>(), /*isServer*/ false, /*clientIdx*/ 0);

        env.rawset("_uiview_scene", scene);
        exec(thread, env, "require 'UIView/ServeBoot'", "serve_boot");

        System.out.println("@@SERVE_READY@@");
        System.out.flush();

        BufferedReader in = new BufferedReader(new InputStreamReader(System.in));
        String line;
        while ((line = in.readLine()) != null) {
            if (line.equals("__quit__")) break;
            env.rawset("_uiview_event", line);
            try {
                exec(thread, env, "UIView_serve_tick()", "serve_tick");
            } catch (Exception e) {
                System.out.println("@@ERR@@" + e.getMessage());
            }
            System.out.flush();
        }
    }

    /**
     * Bridge mode — line protocol, base64 both directions so multi-line Lua
     * chunks and multi-line results survive a newline-framed stream:
     *
     *   stdin:   base64(utf8(lua chunk))         one chunk per line
     *   stdout:  @@OK@@base64(utf8(tostring(first return value)))
     *            @@ERR@@base64(utf8(error message))
     *
     * Anything else on stdout is Lua print() noise — drivers must filter by
     * prefix. "@@BRIDGE_READY@@" marks the env as built; "__quit__" ends the
     * session. Chunks conventionally `return` a JSON string built Lua-side.
     */
    private static void bridgeMode(Path modRoot, String role, int clientIdx) throws Exception {
        ModuleIndex index = indexModuleTree(modRoot);
        TestPlatform platform = new TestPlatform();
        KahluaTable  env      = platform.newEnvironment();
        KahluaThread thread   = new KahluaThread(System.out, platform, env);
        thread.debugOwnerThread = Thread.currentThread();

        // SousVide MP (docs/sousvide-mp.md): one bridge per side. A server
        // side builds the env in server context (isServer/isClient flipped)
        // and holds GameServer.server for its whole life; a client side is
        // the default client context, tagged with its index. The dashboard
        // routes packets between them.
        boolean server = "server".equals(role);
        buildEnv(thread, env, modRoot, index, new ArrayList<>(), server, server ? 0 : clientIdx);
        if (role != null) {
            env.rawset("_pz_role", role);
            env.rawset("_pz_client_index", Double.valueOf(server ? 0 : clientIdx));
            EngineBridge.setRole(role);
        }

        java.util.Base64.Encoder b64e = java.util.Base64.getEncoder();
        java.util.Base64.Decoder b64d = java.util.Base64.getDecoder();
        java.nio.charset.Charset utf8 = java.nio.charset.StandardCharsets.UTF_8;

        System.out.println("@@BRIDGE_READY@@");
        System.out.flush();

        BufferedReader in = new BufferedReader(new InputStreamReader(System.in, utf8));
        String line;
        int chunkNo = 0;
        while ((line = in.readLine()) != null) {
            line = line.trim();
            if (line.isEmpty()) continue;
            if (line.equals("__quit__")) break;
            chunkNo++;
            String reply;
            try {
                String src = new String(b64d.decode(line), utf8);
                LuaClosure c = LuaCompiler.loadstring(src, "bridge#" + chunkNo, env);
                Object[] r = thread.pcall(c, new Object[0]);
                if (r != null && r.length > 0 && Boolean.TRUE.equals(r[0])) {
                    Object v = r.length > 1 ? r[1] : null;
                    String out = v == null ? "" : String.valueOf(v);
                    reply = "@@OK@@" + b64e.encodeToString(out.getBytes(utf8));
                } else {
                    String msg = (r != null && r.length > 1) ? String.valueOf(r[1]) : "unknown error";
                    reply = "@@ERR@@" + b64e.encodeToString(msg.getBytes(utf8));
                }
            } catch (Exception e) {
                String msg = e.getMessage() == null ? e.toString() : e.getMessage();
                reply = "@@ERR@@" + b64e.encodeToString(msg.getBytes(utf8));
            }
            System.out.println(reply);
            System.out.flush();
        }
        // stdin closed (the dashboard is gone, even killed outright) or
        // __quit__: leave. Returning was not enough -- the engine's
        // non-daemon threads kept the JVM alive, and dashboards that died
        // left their VMs running for days.
        System.out.flush();
        System.exit(0);
    }

    private static void buildEnv(KahluaThread thread, KahluaTable env,
                                 Path modRoot, ModuleIndex index, List<String> modules,
                                 boolean isServer, int clientIdx) throws Exception {
        // 0. Verbosity flag for Lua-side diagnostic prints (e.g. the UIView render
        //    walk logging a caught update/render error on a stubbed element). Mirrors
        //    the Java ExceptionLogger gate: quiet by default, on with PZTEST_VERBOSE /
        //    -Dpztest.verbose. Test failures report via the runner, not these prints.
        env.rawset("_pz_verbose",
            (System.getenv("PZTEST_VERBOSE") != null || System.getProperty("pztest.verbose") != null)
                ? Boolean.TRUE : Boolean.FALSE);

        // --fidelity: layer bookkeeping only for the primary env (DualVMSim
        // endpoints build the same surface; counting them would double up).
        final boolean fid = fidelityOn && !isServer && clientIdx == 0;
        Map<Object, Object> snap = fid ? snapshot(env) : null;

        // 1. Mocks + Assert + Fixtures
        loadFile(thread, env, kahluaDir.resolve("mock_environment.lua"));
        if (fid) snap = fidPhase(thread, env, snap, "mock", true);
        loadFile(thread, env, kahluaDir.resolve("Assert.lua"));
        loadFile(thread, env, kahluaDir.resolve("Fixtures.lua"));
        // Timed-action lifecycle simulator (PZTestKit.TimedActions) — runs
        // actions through the hook dispatch PZ actually uses per context
        // (IsoGameCharacter.java:9730-9738), so tests cannot invent an MP
        // where complete() runs on the acting client. Born from the
        // VorpallySauced v1.13.0 journal-study incident.
        loadFile(thread, env, kahluaDir.resolve("TimedActionSim.lua"));
        // Engine Workbench blueprints as tests (PZTestKit.Blueprints.tests()):
        // defines functions only; nothing runs until a test file asks.
        loadFile(thread, env, kahluaDir.resolve("blueprints.lua"));
        // The Arena (PZTestKit.Arena): headless one-way combat through the
        // game's own hit pipeline. Defines functions only; engine mode only.
        loadFile(thread, env, kahluaDir.resolve("arena.lua"));
        loadFile(thread, env, kahluaDir.resolve("perf.lua"));

        // 1b. Override context functions. mock_environment defaults to client.
        if (isServer) {
            loadFile(thread, env, kahluaDir.resolve("context/server.lua"));
        }
        // Contract pass: the profile's context must hold before config
        // preloads read isServer()/isClient() at file load.
        if (env.rawget("_pz_contract_profile") != null) {
            loadFile(thread, env, kahluaDir.resolve("context/contract_profile.lua"));
        }
        // Tag the player with its client index so server-targeted sends can
        // route to the correct endpoint.
        if (clientIdx > 0) {
            env.rawset("_pz_client_index", Double.valueOf(clientIdx));
            loadFile(thread, env, kahluaDir.resolve("context/client_tag.lua"));
        }

        // 2. Module index + require resolver
        installModuleIndex(env, index);
        installCompiler(env);
        installFileReader(env, modRoot, kahluaDir);
        loadFile(thread, env, kahluaDir.resolve("require_resolver.lua"));

        // 2b. Coverage instrumentation runtime (opt-in via --coverage). Loaded
        // AFTER the resolver so its _pz_cov_compile hook is available before any
        // module is required during the test run.
        if (coverageOn) {
            env.rawset("_pz_cov_on", Boolean.TRUE);
            if (coveragePerTest) env.rawset("_pz_cov_per_test", Boolean.TRUE);
            if (coverageScope != null) env.rawset("_pz_cov_scope", coverageScope);
            loadFile(thread, env, kahluaDir.resolve("coverage.lua"));
        }

        // 3. Config — pass the raw source through to context/load_config.lua,
        //    which handles compile/runtime errors as warnings.
        Path configFile = modRoot.resolve("pz-test.lua");
        if (Files.exists(configFile)) {
            env.rawset("_pz_config_source", Files.readString(configFile));
            loadFile(thread, env, kahluaDir.resolve("context/load_config.lua"));
        }
        loadFile(thread, env, kahluaDir.resolve("config_loader.lua"));
        if (fid) snap = fidPhase(thread, env, snap, "kit", false);

        // 3b. Sandbox auto-discovery — parse media/sandbox-options.txt and
        //     fill in defaults NOT already covered by pz-test.lua's sandbox
        //     block. Zero-config for mods with vanilla-style sandbox files.
        Path sandboxFile = modRoot.resolve("media/sandbox-options.txt");
        if (Files.exists(sandboxFile)) {
            env.rawset("_pz_sandbox_source", Files.readString(sandboxFile));
            loadFile(thread, env, kahluaDir.resolve("context/sandbox_auto.lua"));
        }
        if (fid) snap = fidPhase(thread, env, snap, "mod", false);

        // 3c. Vanilla requires — for mods that want to exercise real vanilla
        //     PZ Lua (ISTransferAction, ISBaseTimedAction, etc.) instead of
        //     hand-written mocks. Reads `vanilla_requires` list from pz-test.lua
        //     and loads each file from $PZ_INSTALL/media/lua/<path>.lua. On
        //     load failure, logs a warning and continues — the hand-written
        //     mock from mock_environment.lua remains as fallback.
        loadVanillaRequires(thread, env);
        if (fid) snap = fidPhase(thread, env, snap, "vanilla", true);

        // 3d. Translations — install a Translator-faithful getText. The format
        //     semantics (formatFixer + String.formatted + the WARN it logs when
        //     a specifier goes unfed) are ALWAYS on, because they apply to any
        //     string and cost nothing for a key with no placeholders. Loading
        //     the mod's actual strings is opt-in via `translate = "EN"` in
        //     pz-test.lua — without it getText echoes the key, as before.
        loadTranslations(thread, env, modRoot, kahluaDir);
        if (fid) snap = fidPhase(thread, env, snap, "kit", false);

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

        if (fid) snap = fidPhase(thread, env, snap, "mod", false);

        // 6. Post-scripts hook
        loadFile(thread, env, kahluaDir.resolve("post_scripts.lua"));
        if (fid) snap = fidPhase(thread, env, snap, "kit", false);

        // 6b. Engine mode — real PZ classes for this env. Installed LAST
        //     among the surface-defining steps, because mods can (and VPS
        //     does) ship their own `instanceItem` factory via extra_scripts,
        //     which would clobber an earlier install. The engine version
        //     CHAINS: real item when the registry knows the type, delegate
        //     to whatever instanceItem existed before (the mod's factory or
        //     the kit mock) otherwise — so contrived test-only types keep
        //     working while every real type upgrades to a real item. When
        //     boot failed or never ran, PZEngine still exists and reports
        //     unavailable, so engine-guarded tests skip loudly, not crash.
        if (engineOn) {
            List<String> extraExpose = new ArrayList<>();
            boolean chainItems = false;
            Object cfgObj = env.rawget("_pz_config");
            if (cfgObj instanceof KahluaTable cfgTable) {
                if (cfgTable.rawget("engine_expose") instanceof KahluaTable exposeTable) {
                    int i = 1;
                    while (exposeTable.rawget(i) instanceof String s) { extraExpose.add(s); i++; }
                }
                chainItems = Boolean.TRUE.equals(cfgTable.rawget("engine_items"));
                // engine_wire = true: DualVMSim payloads ride the REAL
                // TableNetworkUtils serialization instead of pass-by-
                // reference. Opt-in like engine_items — same lesson: sim
                // suites may legitimately send mock structures the real
                // wire refuses.
                DualVMSim.setWireTransport(Boolean.TRUE.equals(cfgTable.rawget("engine_wire")));
            }
            // Never chain inside DualVMSim endpoints (server or client>0):
            // the sim models MP transport over mock item tables — real Java
            // items can't ride its serialization, and sim tests exist to
            // exercise the protocol, not item fidelity.
            if (isServer || clientIdx > 0) chainItems = false;
            EngineBridge.installIntoEnv(new TestPlatform(), thread, env, extraExpose, chainItems, System.out);
            if (fid) snap = fidPhase(thread, env, snap, "engine", true);
        }
        if (fid) fidCaptured = fidCaptured || !fidLayer.isEmpty();

        // 7. Match PZ's runtime surface. LAST, so every harness file above has
        //    already been compiled and switched to _pz_compile.
        removeRemovedGlobals(env);
    }

    /** Last PZ build line that shipped WITHOUT loadstring (see below). */
    private static final int LOADSTRING_RESTORED_IN = 42021;   // GameVersion.getInt()

    /**
     * Strip globals the INSTALLED PZ build does NOT have, so mod code cannot
     * depend on one and pass here while failing in the game.
     *
     * `loadstring` / `loadstream` have been removed and restored once each:
     * PZ's 2026-08 security patch took them out (42.20.4), and 42.21 put them
     * back after further investigation. Kahlua ships them either way — which is
     * why this needs a gate at all, and why the gate has to point BOTH ways.
     *
     *   - Unstripped on a build that lacks them, the harness is more permissive
     *     than the game. That shipped a real bug: TooltipLib carried a
     *     `loadstring` closure a green suite said nothing about, torn out in
     *     v1.6.2.
     *   - Stripped on a build that has them, the harness is more restrictive
     *     than the game. That is the same fidelity error wearing a different
     *     hat: it fails code the runtime would have accepted.
     *
     * So gate on the installed version rather than picking a side. The version
     * comes from the Core stub, which reads it out of the real Core.class at
     * jar-build time (see build_runtime_jar.py) — no table to keep current.
     *
     * RESOLUTION LIMIT, deliberate: the baked version is major.minor, so 42.20.0
     * (had them) and 42.20.4 (did not) are indistinguishable here and the whole
     * 42.20 line gets stripped. That errs toward the stricter harness on builds
     * nobody is on any more, which is the safe direction of the two.
     *
     * The harness's own infrastructure still needs a compiler (the require
     * resolver, coverage instrumentation and the config/test-file loaders all
     * compile source at runtime), so it uses `_pz_compile` regardless: same
     * semantics, a name no one will mistake for a PZ API, and consistent with
     * the `_pz_`-prefixed harness globals already in the env. `PZTestKit.compile`
     * (syntax check only) is likewise unaffected by this gate.
     */
    private static void removeRemovedGlobals(KahluaTable env) {
        if (installedBuildHasLoadstring()) return;
        env.rawset("loadstring", null);
        env.rawset("loadstream", null);
    }

    /**
     * The installed build's GameVersion, or null if it cannot be read.
     * Reflective so this class still loads with no PZ install present.
     */
    private static Object installedGameVersion() {
        try {
            Class<?> core = Class.forName("zombie.core.Core");
            return core.getMethod("getGameVersion")
                .invoke(core.getMethod("getInstance").invoke(null));
        } catch (Throwable t) {
            return null;
        }
    }

    /** "major.minor", or null when unreadable. */
    private static String installedBuildVersion() {
        Object version = installedGameVersion();
        if (version == null) return null;
        try {
            return (String) version.getClass().getMethod("toString").invoke(version);
        } catch (Throwable t) {
            return null;
        }
    }

    private static boolean installedBuildHasLoadstring() {
        Object version = installedGameVersion();
        if (version == null) {
            // Version unreadable: keep them stripped. An unknown build is
            // likelier to be old than to be newer than the one we know about,
            // and the stricter direction fails loudly instead of silently.
            return false;
        }
        try {
            int asInt = (Integer) version.getClass().getMethod("getInt").invoke(version);
            return asInt >= LOADSTRING_RESTORED_IN;
        } catch (Throwable t) {
            return false;
        }
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
        // every file of every mod in the game's load order (see indexModuleTree)
        final List<LoadEntry> order = new ArrayList<>();
        final List<String> modIds = new ArrayList<>();
        // each mod's media/registries.lua, in mod order (ModRegistries.init)
        final List<Path> registries = new ArrayList<>();
        int size() { return byName.size(); }
    }

    /** One file as the game's LoadDirBase runs it: its mod, folder and require name. */
    private static class LoadEntry {
        String mod, folder, name;
        Path path;
    }

    /** One mod's directories (B42: common/ plus its version folder; else the mod root). */
    private record ModGroup(String id, List<Path> variants, List<String> requires) {}

    /** Scan media/lua/{shared,client,server}/**&#47;*.lua and build a name->source
     *  index. First match wins (shared > client > server) to mirror real PZ
     *  semantics; the mod under test beats its dependencies, which beat
     *  --lua-mod. Also records every mod's files in the game's load order
     *  (idx.order): LuaManager.LoadDirBase runs one folder at a time, and in
     *  it ONE MOD AT A TIME in mod order, each mod's common/ and version
     *  files together, sorted case-insensitively by path. A path already run
     *  (an earlier mod's) is not run again; the later mod's file is the one
     *  that runs there. */
    private static ModuleIndex indexModuleTree(Path modRoot) throws IOException {
        ModuleIndex idx = new ModuleIndex();

        // load order: listed --lua-mod mods, then dependencies, then the mod under
        // test; then, as the game sorts the mod list, each mod moves after the
        // mods its mod.info require= names (SauceTooltips after TooltipLib)
        List<ModGroup> groups = new ArrayList<>();
        Set<Path> seen = new HashSet<>();
        luaModVariants.clear();
        for (String spec : luaModSpecs) {
            Path pz = pzInstallCached();
            List<Path> v = pz == null && spec.startsWith("workshop:") ? List.of()
                : EngineBridge.resolveModSpec(pz, modRoot, spec);
            if (v.isEmpty()) { System.out.println("  WARNING: lua mod not found: " + spec); continue; }
            addGroup(groups, seen, v);
            luaModVariants.addAll(v);
        }
        for (Path dep : readDependencyRoots(modRoot)) {
            List<Path> v = EngineBridge.resolveModSpec(null, modRoot, dep.toString());
            addGroup(groups, seen, v.isEmpty() ? List.of(dep) : v);
        }
        addGroup(groups, seen, List.of(modRoot));
        groups = requiresFirst(groups);

        // the index: the mod under test first, then dependencies, then lua
        // mods; within a mod its version folder before common/ (it overrides)
        List<ModGroup> byPriority = new ArrayList<>(groups);
        Collections.reverse(byPriority);
        String[] contexts = { "shared", "client", "server" };
        for (ModGroup g : byPriority) {
            List<Path> variants = new ArrayList<>(g.variants());
            Collections.reverse(variants);
            for (Path root : variants) {
                for (String ctx : contexts) {
                    Path base = root.resolve("media/lua/" + ctx);
                    for (Path p : luaFiles(base)) {
                        String rel = base.relativize(p).toString().replace('\\', '/');
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

        // the load order
        for (ModGroup g : groups) {
            idx.modIds.add(g.id());
            // ModRegistries.init: the version folder's registries.lua, else common/'s
            for (int vi = g.variants().size() - 1; vi >= 0; vi--) {
                Path r = g.variants().get(vi).resolve("media/registries.lua");
                if (Files.isRegularFile(r)) { idx.registries.add(r); break; }
            }
        }
        for (String ctx : contexts) {
            Map<String, LoadEntry> at = new HashMap<>();   // lower-case rel path -> its entry
            for (ModGroup g : groups) {
                TreeMap<String, LoadEntry> mine = new TreeMap<>();
                for (Path root : g.variants()) {   // common/ first: the version folder's file replaces it
                    Path base = root.resolve("media/lua/" + ctx);
                    for (Path p : luaFiles(base)) {
                        String rel = base.relativize(p).toString().replace('\\', '/');
                        LoadEntry e = new LoadEntry();
                        e.mod = g.id(); e.folder = ctx; e.path = p;
                        e.name = rel.substring(0, rel.length() - 4);
                        mine.put(rel.toLowerCase(Locale.ROOT), e);
                    }
                }
                for (Map.Entry<String, LoadEntry> me : mine.entrySet()) {
                    LoadEntry prev = at.get(me.getKey());
                    if (prev != null) { prev.path = me.getValue().path; prev.mod = me.getValue().mod; continue; }
                    at.put(me.getKey(), me.getValue());
                    idx.order.add(me.getValue());
                }
            }
        }
        return idx;
    }

    private static void addGroup(List<ModGroup> groups, Set<Path> seen, List<Path> variants) {
        Path key;
        try { key = variants.get(0).toRealPath(); } catch (IOException e) { key = variants.get(0).toAbsolutePath().normalize(); }
        if (!seen.add(key)) return;
        Path info = null;
        for (Path v : variants) if (Files.exists(v.resolve("mod.info"))) { info = v; break; }
        Path first = variants.get(0);
        String id = info != null ? EngineBridge.modIdOf(info)
            : first.getParent() != null && Files.exists(first.getParent().resolve("mod.info")) ? EngineBridge.modIdOf(first.getParent())
            : EngineBridge.modIdOf(first);
        groups.add(new ModGroup(id, variants, requiresOf(info != null ? info
            : first.getParent() != null && Files.exists(first.getParent().resolve("mod.info")) ? first.getParent() : first)));
    }

    /** mod.info require= ("\\TooltipLib,\\Foo" in B42, "TooltipLib,Foo" before). */
    private static List<String> requiresOf(Path dir) {
        List<String> out = new ArrayList<>();
        try {
            Path info = dir.resolve("mod.info");
            if (!Files.exists(info)) return out;
            for (String line : Files.readAllLines(info)) {
                String l = line.trim();
                if (!l.toLowerCase(Locale.ROOT).startsWith("require=")) continue;
                for (String r : l.substring(8).split(",")) {
                    String id = r.replace("\\", "").trim();
                    if (!id.isEmpty()) out.add(id);
                }
            }
        } catch (Exception ignored) {}
        return out;
    }

    /** Stable: each mod after the present mods it requires, otherwise as listed. */
    private static List<ModGroup> requiresFirst(List<ModGroup> groups) {
        Set<String> present = new HashSet<>();
        for (ModGroup g : groups) present.add(g.id());
        List<ModGroup> out = new ArrayList<>();
        Set<String> placed = new HashSet<>();
        List<ModGroup> left = new ArrayList<>(groups);
        while (!left.isEmpty()) {
            ModGroup pick = null;
            for (ModGroup g : left) {
                boolean ready = true;
                for (String r : g.requires()) if (present.contains(r) && !placed.contains(r) && !r.equals(g.id())) { ready = false; break; }
                if (ready) { pick = g; break; }
            }
            if (pick == null) pick = left.get(0);   // a require cycle: as listed
            left.remove(pick);
            out.add(pick);
            placed.add(pick.id());
        }
        return out;
    }

    private static List<Path> luaFiles(Path dir) throws IOException {
        if (!Files.isDirectory(dir)) return List.of();
        try (Stream<Path> walk = Files.walk(dir)) {
            return walk.filter(Files::isRegularFile)
                .filter(p -> p.getFileName().toString().toLowerCase(Locale.ROOT).endsWith(".lua"))
                .sorted()
                .collect(Collectors.toList());
        }
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
        KahluaTable order = new se.krka.kahlua.j2se.KahluaTableImpl(new java.util.HashMap<>());
        int n = 0;
        for (LoadEntry e : idx.order) {
            KahluaTable t = new se.krka.kahlua.j2se.KahluaTableImpl(new java.util.HashMap<>());
            t.rawset("mod", e.mod);
            t.rawset("folder", e.folder);
            t.rawset("name", e.name);
            t.rawset("path", e.path.toString());
            order.rawset(Double.valueOf(++n), t);
        }
        env.rawset("_pz_mod_load", order);
        KahluaTable regs = new se.krka.kahlua.j2se.KahluaTableImpl(new java.util.HashMap<>());
        int ri = 0;
        for (Path r : idx.registries) regs.rawset(Double.valueOf(++ri), r.toString());
        env.rawset("_pz_mod_registries", regs);
        // getActivatedMods() lists the mods loaded, only under --lua-mod
        // (suites have always run with it empty)
        if (!luaModSpecs.isEmpty()) {
            KahluaTable ids = new se.krka.kahlua.j2se.KahluaTableImpl(new java.util.HashMap<>());
            int k = 0;
            for (String id : idx.modIds) ids.rawset(Double.valueOf(++k), id);
            env.rawset("_pz_active_mods", ids);
        }
    }

    /**
     * Install `PZTestKit.compile(src [, chunkname])` — a SYNTAX CHECK for Lua
     * source, returning `true` or `nil, message`.
     *
     * This exists because PZ REMOVED `loadstring` from its runtime. Kahlua still
     * has the compiler, so the global happens to be present in this harness —
     * which makes it a trap: a test written against `loadstring` passes here and
     * describes an API the game does not have, so the habit leaks into mod code
     * and breaks on load. (VorpallySauced's TooltipLib dependency shipped exactly
     * that call and had to drop it in v1.6.2.)
     *
     * So the capability is exposed under the kit's own namespace instead. It
     * cannot be mistaken for a PZ API, and it deliberately does NOT return the
     * compiled chunk: the use case is "does this file parse", which matters for
     * the dozen or so UI modules that derive from ISPanel and therefore cannot
     * be executed offline at all. Handing back a runnable chunk would invite
     * exactly the dynamic-code habit PZ removed the global to prevent.
     */
    // ── Fidelity (--fidelity) ──────────────────────────────────────

    private static Map<Object, Object> snapshot(KahluaTable env) {
        Map<Object, Object> m = new HashMap<>();
        KahluaTableIterator it = env.iterator();
        while (it.advance()) m.put(it.getKey(), it.getValue());
        return m;
    }

    private static String luaKind(Object v) {
        if (v instanceof LuaClosure || v instanceof JavaFunction) return "function";
        if (v instanceof KahluaTable) return "table";
        if (v == null) return "nil";
        if (v instanceof String || v instanceof Number || v instanceof Boolean) return "value";
        return "java";
    }

    /** Attribute every global the last phase added or replaced to `layer`
     *  (first env only), optionally wrap its functions with call counters,
     *  and return the new snapshot. Harness internals (_pz*, __*) are skipped. */
    private static Map<Object, Object> fidPhase(KahluaThread thread, KahluaTable env,
                                                Map<Object, Object> before, String layer, boolean count) throws Exception {
        List<String> changed = new ArrayList<>();
        KahluaTableIterator it = env.iterator();
        while (it.advance()) {
            if (!(it.getKey() instanceof String)) continue;
            String k = (String) it.getKey();
            if (k.startsWith("_pz") || k.startsWith("__")) continue;
            Object v = it.getValue();
            if (before.containsKey(k) && before.get(k) == v) continue;
            changed.add(k);
            if (!fidCaptured) {
                String prev = fidLayer.get(k);
                if (prev != null && !prev.equals(layer)) fidOverrode.put(k, prev);
                fidLayer.put(k, layer);
                fidKind.put(k, luaKind(v));
            }
        }
        if (count && !changed.isEmpty()) {
            KahluaTable names = new se.krka.kahlua.j2se.KahluaTableImpl(new java.util.HashMap<>());
            for (int i = 0; i < changed.size(); i++) names.rawset(i + 1, changed.get(i));
            env.rawset("_pz_fid_env", env);
            env.rawset("_pz_fid_names", names);
            loadFile(thread, env, kahluaDir.resolve("fidelity.lua"));
        }
        return snapshot(env);
    }

    /** The StubbingClassLoader's synthesized-class set, or an empty set. */
    @SuppressWarnings("unchecked")
    private static Set<String> synthesizedClasses() {
        try {
            ClassLoader cl = KahluaTestRunner.class.getClassLoader();
            return (Set<String>) cl.getClass().getField("synthesized").get(cl);
        } catch (Throwable t) {
            return Collections.emptySet();
        }
    }

    /** Read-only file access for kit Lua that works from files rather than
     *  modules -- PZTestKit.Blueprints loads the Engine Workbench's tools and
     *  a mod's workbench/blueprints/*.json. Confined to the kit, the mod's
     *  parent folder (the mod and its sibling dependencies) and the PZ install:
     *    _pz_read_file(path) -> text | nil      _pz_list_dir(path) -> {names} | nil
     *  _pz_kit_dir / _pz_mod_root carry the two anchors. */
    private static void installFileReader(KahluaTable env, Path modRoot, Path kahluaDir) {
        final Path kit = kahluaDir.toAbsolutePath().getParent().normalize();
        final Path mods = modRoot.toAbsolutePath().getParent().normalize();
        final Path pzRaw = pzInstallCached();
        final Path pz = pzRaw != null ? pzRaw.toAbsolutePath().normalize() : null;
        java.util.function.Function<Object, Path> allowed = (o) -> {
            if (!(o instanceof String)) return null;
            Path p = Paths.get((String) o).toAbsolutePath().normalize();
            if (p.startsWith(kit) || p.startsWith(mods) || (pz != null && p.startsWith(pz))) return p;
            // --lua-mod mods (their registries.lua; a file run by path)
            for (Path v : luaModVariants) if (p.startsWith(v.toAbsolutePath().normalize())) return p;
            return null;
        };
        env.rawset("_pz_kit_dir", kit.toString().replace('\\', '/'));
        // Every env, not only configs with vanilla_requires: the blueprint
        // runner's bench index scans the install's entity scripts, and without
        // this every vanilla bench (kilns, forges, the charcoal pit) silently
        // resolved to none, so suite boards crafted in hand.
        if (pz != null) env.rawset("_pz_install_dir", pz.toString());
        env.rawset("_pz_mod_root", modRoot.toAbsolutePath().normalize().toString().replace('\\', '/'));
        env.rawset("_pz_read_file", (JavaFunction) (frame, n) -> {
            Path p = n > 0 ? allowed.apply(frame.get(0)) : null;
            try { frame.push(p != null && Files.isRegularFile(p) ? Files.readString(p) : null); }
            catch (Exception e) { frame.push(null); }
            return 1;
        });
        env.rawset("_pz_list_dir", (JavaFunction) (frame, n) -> {
            Path p = n > 0 ? allowed.apply(frame.get(0)) : null;
            if (p == null || !Files.isDirectory(p)) { frame.push(null); return 1; }
            KahluaTable t = new se.krka.kahlua.j2se.KahluaTableImpl(new java.util.HashMap<>());
            try (java.util.stream.Stream<Path> s = Files.list(p)) {
                int i = 1;
                for (Path f : s.sorted().toArray(Path[]::new)) t.rawset(Double.valueOf(i++), f.getFileName().toString());
            } catch (Exception e) { frame.push(null); return 1; }
            frame.push(t);
            return 1;
        });
    }

    private static void installCompiler(KahluaTable env) {
        KahluaTable pzTestKit = env.rawget("PZTestKit") instanceof KahluaTable
            ? (KahluaTable) env.rawget("PZTestKit")
            : new se.krka.kahlua.j2se.KahluaTableImpl(new java.util.HashMap<>());
        env.rawset("PZTestKit", pzTestKit);

        // The build the harness is modelling, as "major.minor" (e.g. "42.21"),
        // or nil when it cannot be determined. Read out of the real Core.class
        // at jar-build time, so it is the INSTALLED game's version and not a
        // number anyone maintains by hand. Tests need this for the same reason
        // the harness does: anything PZ has added or taken away across builds
        // (loadstring, for one) has to be asserted against the build in front of
        // you rather than against whichever one was current when the test was
        // written. Mods read the same value in game via getCore():getGameVersion().
        pzTestKit.rawset("gameVersion", installedBuildVersion());

        final KahluaTable envRef = env;

        // Wall clock for per-test timings in --report-json. Kahlua's os lib
        // has no usable clock, and getTimestampMs is mocked to 0 on purpose.
        env.rawset("_pz_now_ms", new JavaFunction() {
            @Override
            public int call(LuaCallFrame frame, int nArguments) {
                frame.push(System.nanoTime() / 1_000_000.0);
                return 1;
            }
        });

        // Declared parameter names of a Lua function, the way PZ reads them:
        // NetTimedAction.set (NetTimedAction.java:42-51) walks the class's
        // new() prototype locvars[1..numParams-1] to decide what to send.
        // `...` is not a declared parameter. nil for a non-Lua function.
        env.rawset("_pz_closure_params", new JavaFunction() {
            @Override
            public int call(LuaCallFrame frame, int nArguments) {
                Object fn = nArguments >= 1 ? frame.get(0) : null;
                if (!(fn instanceof LuaClosure)) {
                    frame.push(null);
                    return 1;
                }
                Prototype p = ((LuaClosure) fn).prototype;
                KahluaTable names = frame.getPlatform().newTable();
                for (int i = 0; i < p.numParams; i++) {
                    names.rawset(Double.valueOf(i + 1), p.locvars[i]);
                }
                frame.push(names);
                frame.push(p.isVararg ? Boolean.TRUE : Boolean.FALSE);
                return 2;
            }
        });

        // Vanilla source access for the contract pass (contract.lua):
        // _pz_vanilla_list("shared/TimedActions") -> sorted relpaths without
        // .lua ("shared/TimedActions/ISEatFoodAction", ...), recursive;
        // _pz_vanilla_source(relpath) -> source string. Both nil when there
        // is no PZ install (CI), which the contract reports as a skip.
        env.rawset("_pz_vanilla_list", new JavaFunction() {
            @Override
            public int call(LuaCallFrame frame, int nArguments) {
                Path install = pzInstallCached();
                if (install == null || nArguments < 1 || !(frame.get(0) instanceof String)) {
                    frame.push(null);
                    return 1;
                }
                Path luaRoot = install.resolve("media/lua");
                Path dir = luaRoot.resolve((String) frame.get(0));
                KahluaTable out = frame.getPlatform().newTable();
                if (Files.isDirectory(dir)) {
                    try (Stream<Path> s = Files.walk(dir)) {
                        List<String> rels = s.filter(f -> f.toString().endsWith(".lua"))
                            .map(f -> luaRoot.relativize(f).toString().replace('\\', '/'))
                            .map(r -> r.substring(0, r.length() - 4))
                            .sorted(String.CASE_INSENSITIVE_ORDER)
                            .collect(Collectors.toList());
                        int i = 1;
                        for (String r : rels) out.rawset(Double.valueOf(i++), r);
                    } catch (IOException e) {
                        frame.push(null);
                        return 1;
                    }
                }
                frame.push(out);
                return 1;
            }
        });
        env.rawset("_pz_vanilla_source", new JavaFunction() {
            @Override
            public int call(LuaCallFrame frame, int nArguments) {
                Path install = pzInstallCached();
                if (install == null || nArguments < 1 || !(frame.get(0) instanceof String)) {
                    frame.push(null);
                    return 1;
                }
                Path file = install.resolve("media/lua").resolve(frame.get(0) + ".lua");
                try {
                    frame.push(Files.exists(file) ? Files.readString(file) : null);
                } catch (IOException e) {
                    frame.push(null);
                }
                return 1;
            }
        });

        // The harness's own drop-in for the removed global: same signature and
        // same return contract as loadstring (chunk, or nil + message), under a
        // name that reads as infrastructure. Everything in kahlua/*.lua that
        // used to call loadstring calls this.
        env.rawset("_pz_compile", new JavaFunction() {
            @Override
            public int call(LuaCallFrame frame, int nArguments) {
                if (nArguments < 1 || !(frame.get(0) instanceof String)) {
                    frame.push(null);
                    frame.push("_pz_compile: expected a source string");
                    return 2;
                }
                String src = (String) frame.get(0);
                String name = (nArguments >= 2 && frame.get(1) instanceof String)
                    ? (String) frame.get(1) : "chunk";
                try {
                    frame.push(LuaCompiler.loadstring(src, name, envRef));
                    return 1;
                } catch (Exception e) {
                    String msg = e.getMessage();
                    if (msg == null || msg.isEmpty()) msg = e.toString();
                    frame.push(null);
                    frame.push(name + ": " + msg);
                    return 2;
                }
            }
        });

        pzTestKit.rawset("compile", new JavaFunction() {
            @Override
            public int call(LuaCallFrame frame, int nArguments) {
                if (nArguments < 1 || !(frame.get(0) instanceof String)) {
                    frame.push(null);
                    frame.push("PZTestKit.compile: expected a source string");
                    return 2;
                }
                String src = (String) frame.get(0);
                String name = (nArguments >= 2 && frame.get(1) instanceof String)
                    ? (String) frame.get(1) : "chunk";
                try {
                    LuaCompiler.loadstring(src, name, envRef);
                    frame.push(Boolean.TRUE);
                    return 1;
                } catch (Exception e) {
                    // Kahlua nests the useful part; an empty message here would
                    // make a failing parse check impossible to act on.
                    String msg = e.getMessage();
                    if (msg == null || msg.isEmpty()) msg = e.toString();
                    frame.push(null);
                    frame.push(name + ": " + msg);
                    return 2;
                }
            }
        });
    }

    // ── File loading helpers ───────────────────────────────────────

    /**
     * The contract pass. Loads the WHOLE mod three times -- as SP, as an MP
     * client, as a dedicated server -- each time on top of every vanilla
     * timed action from the PZ install, firing only the boot events that
     * profile really gets (contract.lua). contract_report.lua then compares
     * the three and turns MP invariants into checks: a vanilla action's new()
     * signature changed by a wrapper (NetTimedAction sends by parameter
     * name), and server-run hooks that SP installs but a dedi never does.
     * No test has to exist for either to fail.
     * @return {total, pass, fail, errors, skipped}
     */
    private static int[] runContract(Path modRoot, ModuleIndex index, List<String> modules,
                                     boolean verbose, List<String[]> failDigest) {
        long startNs = System.nanoTime();
        String[] profiles = { "sp", "client", "dedi" };
        KahluaTable results = new se.krka.kahlua.j2se.KahluaTableImpl(new java.util.HashMap<>());
        PrintStream realOut = System.out;
        ByteArrayOutputStream buf = verbose ? null : new ByteArrayOutputStream();
        String error = null;
        Object[] report = null;
        try {
            if (buf != null) System.setOut(new PrintStream(buf, true, java.nio.charset.StandardCharsets.UTF_8));
            KahluaTable env = null;
            KahluaThread thread = null;
            for (String profile : profiles) {
                TestPlatform platform = new TestPlatform();
                env = platform.newEnvironment();
                thread = new KahluaThread(System.out, platform, env);
                thread.debugOwnerThread = Thread.currentThread();
                env.rawset("_pz_contract_profile", profile);
                buildEnv(thread, env, modRoot, index, modules, false, 0);
                Object[] r = execFile(thread, env, kahluaDir.resolve("contract.lua"));
                if (r == null || r.length < 2 || Boolean.FALSE.equals(r[0]) || !(r[1] instanceof KahluaTable)) {
                    error = profile + ": " + (r != null && r.length > 1 ? r[1] : "no result");
                    break;
                }
                results.rawset(profile, r[1]);
            }
            if (error == null) {
                env.rawset("_pz_contract_results", results);
                report = execFile(thread, env, kahluaDir.resolve("contract_report.lua"));
                if (report == null || report.length < 2 || Boolean.FALSE.equals(report[0])
                        || !(report[1] instanceof KahluaTable)) {
                    error = "report: " + (report != null && report.length > 1 ? report[1] : "no result");
                }
            }
        } catch (Exception e) {
            error = e.getMessage();
        } finally {
            if (buf != null) System.setOut(realOut);
        }
        long ms = (System.nanoTime() - startNs) / 1_000_000L;
        String label = "[contract]";
        if (error != null) {
            System.out.printf("%n--- %s (ERROR, %dms) --- *** %s ***%n", label, ms, error);
            replayBuffer(buf);
            failDigest.add(new String[]{ label, "<pass>", error });
            return new int[]{ 0, 0, 0, 1, 0 };
        }
        KahluaTable checks = (KahluaTable) ((KahluaTable) report[1]).rawget("checks");
        int total = 0, pass = 0, fail = 0, skip = 0;
        StringBuilder out = new StringBuilder();
        for (int i = 1; checks != null && checks.rawget(Double.valueOf(i)) instanceof KahluaTable c; i++) {
            String name = String.valueOf(c.rawget("name"));
            String status = String.valueOf(c.rawget("status"));
            String text = c.rawget("text") instanceof String t ? t : "";
            if ("skip".equals(status)) {
                skip++;
                out.append("    ").append(name).append(": SKIPPED ").append(text).append('\n');
                continue;
            }
            total++;
            if ("pass".equals(status)) {
                pass++;
                out.append("    ").append(name).append(": ok");
                if (!text.isEmpty()) out.append(" (").append(text.split("\n")[0]).append(')');
                out.append('\n');
            } else {
                fail++;
                out.append("    ").append(name).append(": FAILED\n");
                for (String ln : text.split("\n")) out.append("      ").append(ln).append('\n');
                failDigest.add(new String[]{ label, name, text.split("\n")[0] });
            }
        }
        Object notes = ((KahluaTable) report[1]).rawget("notes");
        if (notes instanceof String n && !n.isEmpty()) {
            for (String ln : n.split("\n")) out.append("    note: ").append(ln).append('\n');
        }
        System.out.printf("%n--- %s (%d checks, %dms) ---%s%n", label, total, ms, fail > 0 ? " *** FAILURES ***" : "");
        System.out.print(out);
        if (fail > 0) replayBuffer(buf);
        return new int[]{ total, pass, fail, 0, skip };
    }

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

    /** Compile + pcall a Lua source string. Throws on error, carrying the
     *  chunk name + Lua error message — a bare nested RuntimeException here
     *  once made env-build failures undebuggable from the CLI. */
    private static void exec(KahluaThread t, KahluaTable env, String src, String name) throws Exception {
        LuaClosure c;
        try {
            c = LuaCompiler.loadstring(src, name, env);
        } catch (Exception e) {
            throw new RuntimeException(name + ": compile error: " + e.getMessage(), e);
        }
        Object[] r = t.pcall(c, new Object[0]);
        if (r != null && r.length > 0 && Boolean.FALSE.equals(r[0])) {
            String msg = r.length > 1 ? String.valueOf(r[1]) : "unknown error";
            throw new RuntimeException(name + ": " + msg);
        }
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
    /**
     * Saved Workbench boards (workbench/blueprints/*.json) are tests only if a
     * test file replays them (PZTestKit.Blueprints.tests()). vps-story carried
     * three boards that had never run in its suite -- two of them failing.
     * Say so loudly on every full run rather than let a board look like a test.
     */
    private static void noteUnreplayedBoards(Path modRoot, List<String> tests) {
        Path dir = modRoot.resolve("workbench").resolve("blueprints");
        if (!Files.isDirectory(dir)) return;
        long boards;
        try (Stream<Path> s = Files.list(dir)) {
            boards = s.filter(p -> p.getFileName().toString().endsWith(".json")).count();
        } catch (IOException e) { return; }
        if (boards == 0) return;
        for (String t : tests) {
            try {
                if (Files.readString(modRoot.resolve(t)).contains("Blueprints.tests")) return;
            } catch (IOException ignored) { }
        }
        System.out.println("*** NOTE: " + boards + " saved Workbench board(s) in workbench/blueprints/ but no test file "
            + "replays them -- add Tests/EngineBlueprintTests.lua: `return PZTestKit.Blueprints.tests()` "
            + "(engine-guarded). Until then they are not tests.");
    }

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
            KahluaThread thread = new KahluaThread(System.out, platform, env);
            thread.debugOwnerThread = Thread.currentThread();
            env.rawset("_pz_config_source", Files.readString(configFile));
            // load_config.lua compiles the config source, so this bare env needs
            // the compiler too. It is NOT a test env and never goes through
            // buildEnv, which is precisely how it got missed: the config load
            // failed, the catch below swallowed it, and the only symptom was
            // `dependencies` and `test_file_excludes` quietly having no effect.
            installCompiler(env);
            LuaClosure c = LuaCompiler.loadstring(
                Files.readString(kahluaDir.resolve("context/load_config.lua")),
                "context/load_config.lua", env);
            // pcall RETURNS false on error rather than throwing, so the catch
            // below never saw config failures. A pz-test.lua that does not load
            // silently drops `dependencies` and `test_file_excludes` -- the mod
            // still tests, just against a different set of files than the author
            // asked for, which is worse than a hard failure because it looks
            // like a pass.
            Object[] r = thread.pcall(c, new Object[0]);
            if (r != null && r.length > 0 && Boolean.FALSE.equals(r[0])) {
                System.out.println("  WARNING: pz-test.lua failed to load: "
                    + (r.length > 1 ? String.valueOf(r[1]) : "unknown error"));
                return null;
            }
            Object cfg = env.rawget("_pz_config");
            return cfg instanceof KahluaTable ? (KahluaTable) cfg : null;
        } catch (Exception e) {
            System.out.println("  WARNING: failed to read pz-test.lua: " + e.getMessage());
            return null;
        }
    }

    /** Read the `vanilla_requires` list from the env's loaded config and
     *  execute each referenced file from the PZ install's media/lua tree.
     *  On any failure (PZ install not found, file missing, load exception)
     *  a warning is logged and the entry is skipped — the hand-written
     *  mock in mock_environment.lua stays as the fallback. */
    private static void loadVanillaRequires(KahluaThread thread, KahluaTable env) {
        Object cfgRaw = env.rawget("_pz_config");
        if (!(cfgRaw instanceof KahluaTable)) return;
        Object list = ((KahluaTable) cfgRaw).rawget("vanilla_requires");
        if (!(list instanceof KahluaTable)) return;

        List<String> entries = new ArrayList<>();
        KahluaTable t = (KahluaTable) list;
        int i = 1;
        while (true) {
            Object v = t.rawget(i);
            if (v == null) break;
            if (v instanceof String) entries.add((String) v);
            i++;
        }
        if (entries.isEmpty()) return;

        Path pzInstall = resolvePZInstall();
        if (pzInstall == null) {
            System.out.println("[PZTestKit] vanilla_requires: PZ install not found — set PZ_INSTALL_DIR env var or add to common Steam paths. Falling back to mocks for "
                + entries.size() + " entries.");
            for (String e : entries) vanillaStatus.put(e, "no-install");
            return;
        }
        Path luaRoot = pzInstall.resolve("media/lua");
        System.out.println("[PZTestKit] vanilla_requires: loading " + entries.size()
            + " file(s) from " + luaRoot);

        // Make the install location visible to Lua so tests or mocks can
        // reason about it if needed.
        env.rawset("_pz_install_dir", pzInstall.toString());

        for (String entry : entries) {
            // Entry is a path relative to media/lua/, without the .lua
            // extension: e.g. "shared/TimedActions/ISTransferAction"
            Path file = luaRoot.resolve(entry + ".lua");
            if (!Files.exists(file)) {
                System.out.println("  [vanilla_requires] MISS (" + entry + "): file not found at " + file);
                vanillaStatus.put(entry, "miss");
                continue;
            }
            try {
                String src = Files.readString(file);
                LuaClosure c = LuaCompiler.loadstring(src, "vanilla:" + entry, env);
                Object[] res = thread.pcall(c, new Object[0]);
                if (res != null && res.length >= 1 && Boolean.FALSE.equals(res[0])) {
                    String err = res.length >= 2 ? String.valueOf(res[1]) : "unknown";
                    System.out.println("  [vanilla_requires] FAIL (" + entry + "): " + err + " — falling back to mock");
                    vanillaStatus.put(entry, "fail: " + err);
                } else {
                    System.out.println("  [vanilla_requires] OK   (" + entry + ")");
                    vanillaStatus.put(entry, "ok");
                    markVanillaRequireSatisfied(env, entry);
                    // contract.lua keeps these classes instead of reloading
                    // them; anything else of the same name is a mock.
                    Object loaded = env.rawget("_pz_vanilla_loaded");
                    if (!(loaded instanceof KahluaTable)) {
                        loaded = new se.krka.kahlua.j2se.KahluaTableImpl(new java.util.HashMap<>());
                        env.rawset("_pz_vanilla_loaded", loaded);
                    }
                    ((KahluaTable) loaded).rawset(entry, Boolean.TRUE);
                }
            } catch (Exception e) {
                System.out.println("  [vanilla_requires] EXC  (" + entry + "): " + e.getMessage() + " — falling back to mock");
                vanillaStatus.put(entry, "exc: " + e.getMessage());
            }
        }
    }

    /**
     * A vanilla file that loaded successfully must also SATISFY a `require`
     * for it, or the config is a trap: the kit reports "OK (ISReadABook)" and
     * then any module doing `require "TimedActions/ISReadABook"` dies with
     * "not found in module index". The class is right there in the env; the
     * resolver just never heard about it.
     *
     * Both spellings are registered because both are legitimate. PZ resolves
     * requires relative to media/lua/<context>/, so mod code writes
     * "TimedActions/ISReadABook" while the config names the file
     * "shared/TimedActions/ISReadABook".
     */
    private static void markVanillaRequireSatisfied(KahluaTable env, String entry) {
        Object stubsRaw = env.rawget("_pz_stub_requires");
        if (!(stubsRaw instanceof KahluaTable)) return;
        KahluaTable stubs = (KahluaTable) stubsRaw;
        stubs.rawset(entry, Boolean.TRUE);
        int slash = entry.indexOf('/');
        if (slash > 0) {
            String ctx = entry.substring(0, slash);
            if (ctx.equals("shared") || ctx.equals("client") || ctx.equals("server")) {
                stubs.rawset(entry.substring(slash + 1), Boolean.TRUE);
            }
        }
    }

    /** Install kahlua/translate.lua, optionally preloaded with the mod's real
     *  strings. `translate` in pz-test.lua accepts a language code ("EN"), a
     *  boolean (true == "EN"), or a path relative to the mod root pointing at
     *  the directory of .json files. Dependency mods listed under
     *  `dependencies` contribute their strings too, mirroring how PZ merges
     *  every enabled mod's bundle into one table. */
    private static void loadTranslations(KahluaThread thread, KahluaTable env,
                                         Path modRoot, Path kahluaDir) throws Exception {
        Map<String, String> strings = new LinkedHashMap<>();
        String label = null;

        Object cfgRaw = env.rawget("_pz_config");
        Object opt = (cfgRaw instanceof KahluaTable) ? ((KahluaTable) cfgRaw).rawget("translate") : null;
        if (opt != null && !Boolean.FALSE.equals(opt)) {
            String lang = (opt instanceof String) ? (String) opt : "EN";
            List<Path> roots = new ArrayList<>();
            if (lang.indexOf('/') >= 0 || lang.indexOf('\\') >= 0) {
                roots.add(modRoot.resolve(lang));                    // explicit directory
            } else {
                roots.add(modRoot.resolve("media/lua/shared/Translate").resolve(lang));
                if (cfgRaw instanceof KahluaTable) {
                    Object deps = ((KahluaTable) cfgRaw).rawget("dependencies");
                    if (deps instanceof KahluaTable) {
                        KahluaTable dt = (KahluaTable) deps;
                        for (int i = 1; ; i++) {
                            Object d = dt.rawget(i);
                            if (d == null) break;
                            if (d instanceof String) {
                                roots.add(modRoot.resolve((String) d)
                                    .resolve("media/lua/shared/Translate").resolve(lang));
                            }
                        }
                    }
                }
                for (Path v : luaModVariants) roots.add(v.resolve("media/lua/shared/Translate").resolve(lang));
            }
            label = lang;
            for (Path dir : roots) {
                if (!Files.isDirectory(dir)) continue;
                try (java.util.stream.Stream<Path> files = Files.list(dir)) {
                    for (Path f : files.sorted().toArray(Path[]::new)) {
                        if (!f.getFileName().toString().endsWith(".json")) continue;
                        try {
                            parseFlatJson(Files.readString(f, java.nio.charset.StandardCharsets.UTF_8),
                                          strings);
                        } catch (Exception e) {
                            System.out.println("  [translate] SKIP (" + f.getFileName()
                                + "): " + e.getMessage());
                        }
                    }
                }
            }
            System.out.println("[PZTestKit] translate: loaded " + strings.size()
                + " " + lang + " string(s)");
        }

        // Hand the table to Lua as source rather than building it through the
        // VM's table API — same "read raw, let Lua own it" shape as the config
        // and sandbox loaders above.
        StringBuilder lua = new StringBuilder("_pz_translations = {\n");
        for (Map.Entry<String, String> e : strings.entrySet()) {
            lua.append("[").append(luaQuote(e.getKey())).append("]=")
               .append(luaQuote(e.getValue())).append(",\n");
        }
        lua.append("}\n");
        exec(thread, env, lua.toString(), "translations");
        env.rawset("_pz_translate_lang", label);
        loadFile(thread, env, kahluaDir.resolve("translate.lua"));
    }

    /** Quote a string as a Lua literal.
     *
     *  BYTES, NOT CHARS, and the old comment claiming "UTF-8 passes through
     *  untouched" was the bug. Lua 5.1 strings are byte strings and Kahlua
     *  compiles from a Java String, so any char above 0xFF was narrowed to its
     *  low byte on the way in: an em-dash (U+2014) arrived as 0x14, a raw
     *  control character.
     *
     *  That is not cosmetic. It rendered as tofu in every preview, and when
     *  the recorder emitted the same string into the scene JSON it produced
     *  INVALID JSON -- which the viewer answered by resolving zero textures,
     *  so an entire page previewed as placeholder boxes with nothing saying
     *  why. Every non-ASCII string in every locale was affected; the ES, RU
     *  and CN bundles were unreadable here by construction.
     *
     *  Encoding to UTF-8 and escaping each byte as \\ddd gives the Lua string
     *  the same bytes the game holds, which is the only way measurement and
     *  rendering here can match measurement and rendering there. */
    private static String luaQuote(String s) {
        byte[] bytes = s.getBytes(java.nio.charset.StandardCharsets.UTF_8);
        StringBuilder sb = new StringBuilder("\"");
        for (byte raw : bytes) {
            int v = raw & 0xFF;
            switch (v) {
                case '"':  sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\n': sb.append("\\n");  break;
                case '\r': sb.append("\\r");  break;
                case '\t': sb.append("\\t");  break;
                default:
                    if (v < 0x20 || v >= 0x7F) sb.append('\\').append(v);
                    else sb.append((char) v);
            }
        }
        return sb.append('"').toString();
    }

    /** Minimal parser for PZ's translation JSON: a flat object of string keys
     *  to string values. Deliberately not a general JSON parser — anything
     *  nested or non-string is skipped rather than tolerated silently wrong. */
    private static void parseFlatJson(String src, Map<String, String> out) {
        int i = 0, n = src.length();
        if (n > 0 && src.charAt(0) == '﻿') i = 1;              // BOM
        while (i < n && src.charAt(i) != '{') i++;
        i++;
        String pendingKey = null;
        while (i < n) {
            char c = src.charAt(i);
            if (c == '"') {
                StringBuilder sb = new StringBuilder();
                i++;
                while (i < n) {
                    char d = src.charAt(i);
                    if (d == '\\' && i + 1 < n) {
                        char e = src.charAt(++i);
                        switch (e) {
                            case 'n':  sb.append('\n'); break;
                            case 't':  sb.append('\t'); break;
                            case 'r':  sb.append('\r'); break;
                            case 'b':  sb.append('\b'); break;
                            case 'f':  sb.append('\f'); break;
                            case 'u':
                                sb.append((char) Integer.parseInt(src.substring(i + 1, i + 5), 16));
                                i += 4;
                                break;
                            default:   sb.append(e);
                        }
                        i++;
                    } else if (d == '"') {
                        i++;
                        break;
                    } else {
                        sb.append(d);
                        i++;
                    }
                }
                if (pendingKey == null) {
                    pendingKey = sb.toString();
                } else {
                    out.put(pendingKey, sb.toString());
                    pendingKey = null;
                }
            } else {
                if (c == '}') break;
                if (c == ',') pendingKey = null;                     // non-string value: drop
                i++;
            }
        }
    }

    /** Locate the PZ install via the shared locator (env var → Steam
     *  registry/libraryfolders.vdf/appmanifest → legacy guesses).
     *  vanilla_requires' validity bar is media/lua/shared. Null when
     *  nothing valid is found. */
    private static Path resolvePZInstall() {
        String env = System.getenv("PZ_INSTALL_DIR");
        if (env != null && !env.isEmpty() &&
                !Files.isDirectory(Paths.get(env).resolve("media/lua/shared"))) {
            System.out.println("[PZTestKit] PZ_INSTALL_DIR=" + env + " does not contain media/lua/shared");
        }
        return PzLocator.find(null, p -> Files.isDirectory(p.resolve("media/lua/shared")));
    }

    private static Path cachedInstall;
    private static boolean installResolved = false;
    private static Path pzInstallCached() {
        if (!installResolved) { cachedInstall = resolvePZInstall(); installResolved = true; }
        return cachedInstall;
    }

    /** Find the kahlua/ directory (where mocks and executor live). */
    private static Path resolveKahluaDir() {
        Path cwd = Paths.get("").toAbsolutePath();
        for (Path p : new Path[]{ cwd, cwd.resolve("kahlua") }) {
            if (Files.exists(p.resolve("mock_environment.lua"))) return p.normalize();
        }
        throw new RuntimeException("Cannot find mock_environment.lua — run from the kahlua/ directory");
    }

    /** Replay a per-file output buffer, indented, between grep-stable markers.
     *  No-op for null (--verbose mode: output already streamed) or empty buffers. */
    private static void replayBuffer(ByteArrayOutputStream buf) {
        if (buf == null || buf.size() == 0) return;
        String out = buf.toString(java.nio.charset.StandardCharsets.UTF_8);
        System.out.println("    --- captured output ---");
        for (String line : out.split("\r?\n"))
            System.out.println("    | " + line);
        System.out.println("    --- end captured output ---");
    }

    /** Parse _pz_last_test_records from the env into JUnitCase entries.
     *  Feeds both the failure digest and JUnit XML. */
    private static List<JUnitCase> parseTestRecords(KahluaTable env) {
        List<JUnitCase> out = new ArrayList<>();
        Object raw = env.rawget("_pz_last_test_records");
        if (!(raw instanceof KahluaTable)) return out;
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
                Object ms = r.rawget("ms");
                if (ms instanceof Number) c.ms = ((Number) ms).doubleValue();
                Object outp = r.rawget("output");
                if (outp instanceof String) c.output = (String) outp;
                Object cv = r.rawget("cov");
                if (cv instanceof KahluaTable) {
                    c.cov = new LinkedHashMap<>();
                    KahluaTableIterator ci = ((KahluaTable) cv).iterator();
                    while (ci.advance()) {
                        if (!(ci.getKey() instanceof String) || !(ci.getValue() instanceof KahluaTable)) continue;
                        Set<Integer> lines = new TreeSet<>();
                        KahluaTable lt = (KahluaTable) ci.getValue();
                        for (int k = 1; lt.rawget(k) != null; k++) {
                            Object n = lt.rawget(k);
                            if (n instanceof Number) lines.add(((Number) n).intValue());
                        }
                        c.cov.put((String) ci.getKey(), lines);
                    }
                }
                out.add(c);
            }
            idx++;
        }
        return out;
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
        System.out.println("Usage: pztest [mod_root] [flags] [testfiles|modules...] [-- tests...]");
        System.out.println();
        System.out.println("  mod_root         Path to your mod (defaults to cwd via the wrapper).");
        System.out.println();
        System.out.println("Flags:");
        System.out.println("  --list             List discovered test files and exit (no execution)");
        System.out.println("  --filter <pat>     Run only tests whose name matches the Lua pattern.");
        System.out.println("                     Plain substrings also pre-skip files that don't");
        System.out.println("                     contain the substring (fast loop).");
        System.out.println("  --no-prescan       Disable the filter file pre-skip (needed only for");
        System.out.println("                     dynamically concatenated test names)");
        System.out.println("  --fail-fast        Stop at the first file containing a failure");
        System.out.println("  -v, --verbose      Stream all output live (default buffers per file and");
        System.out.println("                     replays captured output only for failing files)");
        System.out.println("  --junit-xml <path> Write JUnit XML report (CI integration)");
        System.out.println("  --coverage-per-test Also record which lines EACH test ran (impact data for smart reruns)");
        System.out.println("  --only <file>      Run exactly the \"testFile::testName\" lines listed in <file>");
        System.out.println("  --contract         Run the whole-mod MP contract checks even on a selective run");
        System.out.println("  --no-contract      Skip them (they run by default on full-suite runs)");
        System.out.println("  --fidelity         Record which layer (mock/kit/vanilla/engine/mod) provides each global + mock call counts");
        System.out.println("  --report-json <path> Write the full run as JSON (tests, timings, coverage, config) — dashboard/ reads this");
        System.out.println("  --event-coverage   Report which Events.* listeners fired vs. registered");
        System.out.println("  --coverage[=sub]   Report line coverage of modules (optionally scoped to");
        System.out.println("                     names/paths containing <sub>, e.g. --coverage=palette/)");
        System.out.println("  --bridge           Resident eval bridge: build the env once, then eval");
        System.out.println("                     base64(lua) lines from stdin, replying @@OK@@/@@ERR@@");
        System.out.println("                     + base64(result). For external tooling (designer UIs)");
        System.out.println("                     that must drive REAL mod code, not a reimplementation.");
        System.out.println("  -h, --help         Show this message");
        System.out.println();
        System.out.println("  testfiles        Positional args matching test_*.lua / *Tests.lua run");
        System.out.println("                   as single test files (skips discovery).");
        System.out.println("  modules          Other .lua positionals load as env modules (legacy;");
        System.out.println("                   usually unnecessary — the require resolver auto-");
        System.out.println("                   discovers modules from media/lua/).");
        System.out.println("  --               Separator (tests auto-discovered if omitted)");
        System.out.println();
        System.out.println("Examples:");
        System.out.println("  pztest                                # run everything from cwd");
        System.out.println("  pztest --filter upgrade               # only tests with 'upgrade' in name");
        System.out.println("  pztest media/lua/client/My/Tests/FooTests.lua   # single file");
        System.out.println("  pztest --list                         # list test files");
        System.out.println("  pztest /path/to/MyMod --fail-fast     # stop at first failure");
    }
}
