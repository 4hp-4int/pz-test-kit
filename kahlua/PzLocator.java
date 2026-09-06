import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.concurrent.TimeUnit;
import java.util.function.Predicate;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * PZ Test Kit — Project Zomboid install locator
 * ==============================================
 * One resolver for every consumer (runner's vanilla_requires, engine boot),
 * so "works on the author's machine" stops being an install-path property.
 *
 * Resolution ladder:
 *   1. Explicit override (CLI / caller argument)
 *   2. $PZ_INSTALL_DIR environment variable
 *   3. Steam library discovery:
 *      - find Steam root(s): Windows registry (HKCU SteamPath, HKLM
 *        InstallPath via `reg query` — Java has no registry API), then
 *        default roots per OS (incl. Linux flatpak)
 *      - parse each root's steamapps/libraryfolders.vdf for every library
 *        path (games live in ANY library, not just the root)
 *      - in each library: read appmanifest_108600.acf's "installdir" when
 *        present (names the actual folder), else try the stock names
 *   4. A few legacy guesses (D:/E: SteamLibrary) for setups with no
 *      readable registry/VDF.
 *
 * Every candidate is gated by the caller's validity predicate (the engine
 * wants projectzomboid.jar; vanilla_requires wants media/lua/shared), so a
 * half-uninstalled leftover directory never wins.
 */
public final class PzLocator {

    private PzLocator() {}

    /** Steam appid of Project Zomboid. */
    private static final String PZ_APPID = "108600";

    /** Resolve the PZ install. Null when nothing valid is found. */
    public static Path find(String override, Predicate<Path> valid) {
        for (String c : candidates(override)) {
            try {
                Path p = Paths.get(c);
                if (Files.isDirectory(p) && valid.test(p)) return p.normalize();
            } catch (Exception ignored) { /* malformed path string */ }
        }
        return null;
    }

    /** Ordered, de-duplicated candidate directories. */
    private static List<String> candidates(String override) {
        LinkedHashSet<String> out = new LinkedHashSet<>();
        if (override != null && !override.isEmpty()) out.add(override);

        String env = System.getenv("PZ_INSTALL_DIR");
        if (env != null && !env.isEmpty()) out.add(env);

        for (Path lib : steamLibraries()) {
            Path steamapps = lib.resolve("steamapps");
            // appmanifest names the real install folder; PZ has shipped as
            // both "ProjectZomboid" and "Project Zomboid" over the years.
            String installDir = readInstallDir(steamapps.resolve("appmanifest_" + PZ_APPID + ".acf"));
            if (installDir != null) out.add(steamapps.resolve("common").resolve(installDir).toString());
            out.add(steamapps.resolve("common/ProjectZomboid").toString());
            out.add(steamapps.resolve("common/Project Zomboid").toString());
        }

        // Legacy guesses for machines where no registry/VDF was readable.
        String home = System.getProperty("user.home", "");
        out.add("C:/Program Files (x86)/Steam/steamapps/common/ProjectZomboid");
        out.add("C:/Program Files/Steam/steamapps/common/ProjectZomboid");
        out.add("D:/SteamLibrary/steamapps/common/ProjectZomboid");
        out.add("E:/SteamLibrary/steamapps/common/ProjectZomboid");
        out.add(home + "/.steam/steam/steamapps/common/ProjectZomboid");
        out.add(home + "/.local/share/Steam/steamapps/common/ProjectZomboid");
        out.add(home + "/Library/Application Support/Steam/steamapps/common/Project Zomboid");
        return new ArrayList<>(out);
    }

    /** Every Steam library directory on this machine (roots + VDF entries). */
    private static List<Path> steamLibraries() {
        LinkedHashSet<Path> roots = new LinkedHashSet<>();
        String os = System.getProperty("os.name", "").toLowerCase();
        String home = System.getProperty("user.home", "");

        if (os.contains("win")) {
            String reg = queryRegistry("HKCU\\Software\\Valve\\Steam", "SteamPath");
            if (reg == null) reg = queryRegistry("HKLM\\SOFTWARE\\WOW6432Node\\Valve\\Steam", "InstallPath");
            if (reg != null) roots.add(Paths.get(reg));
            roots.add(Paths.get("C:/Program Files (x86)/Steam"));
            roots.add(Paths.get("C:/Program Files/Steam"));
        } else if (os.contains("mac")) {
            roots.add(Paths.get(home, "Library/Application Support/Steam"));
        } else {
            roots.add(Paths.get(home, ".steam/steam"));
            roots.add(Paths.get(home, ".local/share/Steam"));
            roots.add(Paths.get(home, ".var/app/com.valvesoftware.Steam/.local/share/Steam"));
        }

        LinkedHashSet<Path> libraries = new LinkedHashSet<>();
        for (Path root : roots) {
            if (!Files.isDirectory(root)) continue;
            libraries.add(root);
            libraries.addAll(parseLibraryFolders(root.resolve("steamapps/libraryfolders.vdf")));
        }
        return new ArrayList<>(libraries);
    }

    /** Pull every "path" value out of a libraryfolders.vdf. Tolerant of both
     *  the old flat format and the current nested one — the key/value shape
     *  of the "path" line is identical in each. */
    private static List<Path> parseLibraryFolders(Path vdf) {
        List<Path> out = new ArrayList<>();
        if (!Files.isRegularFile(vdf)) return out;
        try {
            String text = Files.readString(vdf, StandardCharsets.UTF_8);
            Matcher m = Pattern.compile("\"path\"\\s+\"([^\"]+)\"").matcher(text);
            while (m.find()) {
                out.add(Paths.get(m.group(1).replace("\\\\", "\\")));
            }
        } catch (Exception ignored) { }
        return out;
    }

    /** The "installdir" value from an appmanifest .acf, or null. */
    private static String readInstallDir(Path acf) {
        if (!Files.isRegularFile(acf)) return null;
        try {
            String text = Files.readString(acf, StandardCharsets.UTF_8);
            Matcher m = Pattern.compile("\"installdir\"\\s+\"([^\"]+)\"").matcher(text);
            if (m.find()) return m.group(1);
        } catch (Exception ignored) { }
        return null;
    }

    /** `reg query <key> /v <value>` — the only registry access a stock JVM
     *  has. Returns the value or null; never throws, never hangs (2s cap). */
    private static String queryRegistry(String key, String value) {
        try {
            Process p = new ProcessBuilder("reg", "query", key, "/v", value)
                    .redirectErrorStream(true).start();
            if (!p.waitFor(2, TimeUnit.SECONDS)) { p.destroyForcibly(); return null; }
            if (p.exitValue() != 0) return null;
            try (BufferedReader r = new BufferedReader(
                    new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = r.readLine()) != null) {
                    int idx = line.indexOf("REG_SZ");
                    if (line.trim().startsWith(value) && idx >= 0) {
                        return line.substring(idx + "REG_SZ".length()).trim();
                    }
                }
            }
        } catch (Exception ignored) { }
        return null;
    }
}
