/**
 * PZ Test Kit — Generic Kahlua Test Runner
 * ==========================================
 * Runs Lua tests on PZ's actual Kahlua VM (same Lua runtime the game uses).
 * No PZ install needed — uses the self-contained kahlua-runtime.jar.
 *
 * Usage:
 *   cd kahlua
 *   javac -cp kahlua-runtime.jar TestPlatform.java KahluaTestRunner.java
 *   java -cp kahlua-runtime.jar:. KahluaTestRunner <mod_root> [lua_modules...] -- [test_files...]
 *
 * Examples:
 *   # Run the included example
 *   java -cp kahlua-runtime.jar:. KahluaTestRunner ../examples/MyMod \
 *       media/lua/shared/MyMod/Core.lua -- tests/test_core.lua
 *
 *   # Run with multiple modules
 *   java -cp kahlua-runtime.jar:. KahluaTestRunner /path/to/YourMod \
 *       media/lua/shared/YourMod/Core.lua \
 *       media/lua/shared/YourMod/Combat.lua \
 *       -- tests/test_core.lua tests/test_combat.lua
 */

import se.krka.kahlua.vm.*;
import se.krka.kahlua.luaj.compiler.LuaCompiler;

import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.regex.*;

public class KahluaTestRunner {

    private static TestPlatform platform;
    private static Path kahluaDir;

    public static void main(String[] args) throws Exception {
        if (args.length < 1) {
            System.out.println("PZ Test Kit — Kahlua Runner (PZ's actual Lua VM)");
            System.out.println();
            System.out.println("Usage: java -cp kahlua-runtime.jar:. KahluaTestRunner <mod_root> [modules...] -- [tests...]");
            System.out.println();
            System.out.println("  mod_root     Path to your mod directory");
            System.out.println("  modules      Lua files to load (relative to mod_root)");
            System.out.println("  --           Separator between modules and test files");
            System.out.println("  tests        Test files to run (relative to mod_root)");
            System.out.println();
            System.out.println("Example:");
            System.out.println("  java -cp kahlua-runtime.jar:. KahluaTestRunner ../examples/MyMod \\");
            System.out.println("      media/lua/shared/MyMod/Core.lua -- tests/test_core.lua");
            System.exit(1);
        }

        // Parse args: <mod_root> [modules...] -- [test_files...]
        Path modRoot = Paths.get(args[0]).toAbsolutePath();
        List<String> modules = new ArrayList<>();
        List<String> testFiles = new ArrayList<>();
        boolean inTests = false;

        for (int i = 1; i < args.length; i++) {
            if (args[i].equals("--")) {
                inTests = true;
            } else if (inTests) {
                testFiles.add(args[i]);
            } else {
                modules.add(args[i]);
            }
        }

        // Auto-discover test files if none specified
        if (testFiles.isEmpty()) {
            Path testsDir = modRoot.resolve("tests");
            if (Files.isDirectory(testsDir)) {
                try (var stream = Files.list(testsDir)) {
                    stream.filter(p -> p.getFileName().toString().startsWith("test_")
                                    && p.getFileName().toString().endsWith(".lua"))
                          .sorted()
                          .forEach(p -> testFiles.add("tests/" + p.getFileName()));
                }
            }
        }

        if (testFiles.isEmpty()) {
            System.err.println("ERROR: No test files found. Specify test files after -- or put them in tests/test_*.lua");
            System.exit(1);
        }

        // Find kahlua directory (where this class lives)
        kahluaDir = Paths.get("").toAbsolutePath();
        // Also check parent's kahlua/ if run from repo root
        if (!Files.exists(kahluaDir.resolve("stdlib.lua"))) {
            kahluaDir = kahluaDir.resolve("kahlua");
        }

        System.out.println("====================================================");
        System.out.println("PZ Test Kit — Kahlua Runner (PZ's actual Lua VM)");
        System.out.println("====================================================");
        System.out.println("Mod root:  " + modRoot);
        System.out.println("Modules:   " + modules.size());
        System.out.println("Tests:     " + testFiles.size());

        // Run each test file in its own fresh runtime
        int grandTotal = 0, grandPassed = 0, grandFailed = 0, grandErrors = 0;

        for (String testFile : testFiles) {
            Path testPath = modRoot.resolve(testFile);
            if (!Files.exists(testPath)) {
                System.out.println("\n  SKIP: " + testFile + " (not found)");
                continue;
            }

            // Fresh runtime per test file
            platform = new TestPlatform();
            KahluaTable env = platform.newEnvironment();
            KahluaThread thread = new KahluaThread(platform, env);
            thread.debugOwnerThread = Thread.currentThread();

            // Load mock environment + Assert
            Path luaDir = findLuaDir();
            loadLuaFile(thread, env, luaDir.resolve("mock_environment.lua"), false);
            loadLuaFile(thread, env, luaDir.resolve("Assert.lua"), false);

            // Load weapon scripts if present
            Path weaponScripts = modRoot.resolve("weapon_scripts.lua");
            if (Files.exists(weaponScripts)) {
                loadLuaFile(thread, env, weaponScripts, false);
            }

            // Load mod modules
            for (String mod : modules) {
                Path modPath = modRoot.resolve(mod);
                if (Files.exists(modPath)) {
                    loadLuaFile(thread, env, modPath, true);
                } else {
                    System.out.println("  WARNING: Module not found: " + mod);
                }
            }

            // Load test file
            try {
                loadLuaFile(thread, env, testPath, true);
            } catch (Exception e) {
                System.out.println("  ERROR loading " + testFile + ": " + e.getMessage());
                continue;
            }

            // The test file returns a table of test functions
            // Run them and collect results
            String runScript =
                "local testTable = ...\n" +
                "if type(testTable) ~= 'table' then\n" +
                "    -- Test file might have registered via a global; try to find returned tests\n" +
                "    testTable = _pz_last_return\n" +
                "end\n" +
                "if type(testTable) ~= 'table' then return 0, 0, 0, 0, 'No test table returned' end\n" +
                "\n" +
                "local names = {}\n" +
                "for name in pairs(testTable) do table.insert(names, name) end\n" +
                "table.sort(names)\n" +
                "\n" +
                "local total, passed, failed, errors = 0, 0, 0, 0\n" +
                "local firstErrors = {}\n" +
                "\n" +
                "for _, name in ipairs(names) do\n" +
                "    total = total + 1\n" +
                "    -- Reset player state\n" +
                "    _pz_player._primaryHand = nil\n" +
                "    _pz_player._secondaryHand = nil\n" +
                "    _pz_player_inventory._items = {}\n" +
                "    _pz_player_moddata = {}\n" +
                "\n" +
                "    local ok, err = pcall(function()\n" +
                "        local result = testTable[name]()\n" +
                "        if result then passed = passed + 1\n" +
                "        else failed = failed + 1 end\n" +
                "    end)\n" +
                "    if not ok then\n" +
                "        errors = errors + 1\n" +
                "        if #firstErrors < 5 then\n" +
                "            table.insert(firstErrors, name .. ': ' .. tostring(err))\n" +
                "        end\n" +
                "    end\n" +
                "end\n" +
                "\n" +
                "local errStr = #firstErrors > 0 and table.concat(firstErrors, '\\n') or ''\n" +
                "return total, passed, failed, errors, errStr\n";

            // Load the test file and capture its return value
            String wrapperScript =
                "local chunk = ...\n" +
                "_pz_last_return = chunk\n";

            // Execute test file, capture return
            String testSource = readAndStrip(testPath);
            LuaClosure testClosure = LuaCompiler.loadstring(
                "_pz_last_return = (function()\n" + testSource + "\nend)()",
                testFile, env
            );
            thread.pcall(testClosure, new Object[0]);

            // Run the test execution script
            LuaClosure runClosure = LuaCompiler.loadstring(runScript, "runner", env);
            Object[] results = thread.pcall(runClosure, new Object[]{ env.rawget("_pz_last_return") });

            if (results != null && results.length >= 5 && Boolean.TRUE.equals(results[0])) {
                int total = ((Number) results[1]).intValue();
                int pass = ((Number) results[2]).intValue();
                int fail = ((Number) results[3]).intValue();
                int errs = ((Number) results[4]).intValue();
                String errStr = results.length >= 6 && results[5] != null ? results[5].toString() : "";

                grandTotal += total;
                grandPassed += pass;
                grandFailed += fail;
                grandErrors += errs;

                String status = (fail + errs == 0) ? "" : " *** FAILURES ***";
                System.out.printf("\n--- %s (%d tests) ---%s%n", testFile, total, status);

                if (!errStr.isEmpty()) {
                    for (String line : errStr.split("\n")) {
                        System.out.println("    " + line);
                    }
                }
            } else {
                System.out.println("\n--- " + testFile + " — execution failed ---");
                if (results != null && results.length >= 2 && results[1] != null) {
                    System.out.println("    " + results[1]);
                }
            }
        }

        System.out.println("\n====================================================");
        System.out.printf("KAHLUA TOTAL: %d tests, %d passed, %d failed, %d errors%n",
            grandTotal, grandPassed, grandFailed, grandErrors);
        System.out.println("====================================================");
        System.exit(grandFailed + grandErrors > 0 ? 1 : 0);
    }

    private static Path findLuaDir() {
        // Check relative to working directory
        Path[] candidates = {
            Paths.get("").toAbsolutePath().resolve("../lua"),
            Paths.get("").toAbsolutePath().resolve("lua"),
            kahluaDir.resolve("../lua"),
        };
        for (Path p : candidates) {
            if (Files.exists(p.resolve("mock_environment.lua"))) {
                return p.normalize();
            }
        }
        throw new RuntimeException("Cannot find lua/ directory with mock_environment.lua");
    }

    private static String readAndStrip(Path path) throws IOException {
        String source = Files.readString(path);

        // Strip require() calls
        source = source.replaceAll(
            "(local\\s+\\w+\\s*=\\s*)require\\s+\"[^\"]*\"",
            "$1nil -- [stripped]"
        );
        source = source.replaceAll(
            "(?m)^(\\s*)require\\s+\"[^\"]*\"",
            "$1-- [stripped]"
        );

        // Strip context guards
        source = source.replaceAll(
            "if\\s+isServer\\s*\\(\\s*\\)\\s+and\\s+not\\s+isClient\\s*\\(\\s*\\)\\s+then\\s+return\\s+end",
            "-- [stripped]"
        );
        source = source.replaceAll(
            "if\\s+isClient\\s*\\(\\s*\\)\\s+then\\s+return\\s+end",
            "-- [stripped]"
        );

        return source;
    }

    private static void loadLuaFile(KahluaThread thread, KahluaTable env, Path path, boolean strip) throws Exception {
        String source = strip ? readAndStrip(path) : Files.readString(path);
        LuaClosure closure = LuaCompiler.loadstring(source, path.getFileName().toString(), env);
        Object[] result = thread.pcall(closure, new Object[0]);
        if (result != null && result.length > 0 && Boolean.FALSE.equals(result[0])) {
            throw new RuntimeException("Error loading " + path.getFileName() +
                ": " + (result.length > 1 ? result[1] : "unknown"));
        }
    }
}
