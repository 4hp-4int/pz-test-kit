import zombie.scripting.ScriptParser;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.stream.Collectors;
import java.util.stream.Stream;

/**
 * ScriptCheck — validate PZ .txt script files with PZ's OWN parser.
 *
 * <p>Why the real parser and not a regex pass: PZ's script format has rules
 * that look like other languages' rules and are not. The one that cost a day:
 * {@code ScriptParser.stripComments} handles block comments ONLY. A {@code //}
 * line comment is not an error and is not ignored — its words are tokenised as
 * script, so
 *
 * <pre>
 *   module Base {
 *       // this is a line comment, which PZ does NOT support
 *       item WelderMask { DisplayName = Welding Mask, }
 *   }
 * </pre>
 *
 * parses to a block named {@code which PZ} and the {@code item} block is gone.
 * The game logs nothing. Every item in the file silently ceases to exist. A
 * hand-written linter has to KNOW that rule to catch it; the engine's parser
 * simply demonstrates it. That is the whole argument for extracting this class
 * rather than reimplementing it — the same argument as running the real Kahlua
 * VM instead of a Lua-alike.
 *
 * <p>Checks:
 * <ul>
 *   <li>unknown top-level and nested block types (catches comment residue,
 *       typos, and brace nesting that silently reparents blocks)</li>
 *   <li>blocks with no id where the type requires one</li>
 *   <li>duplicate ids within the same module</li>
 *   <li>empty modules (usually a brace that closed early)</li>
 *   <li>a parse that yields nothing at all from a non-empty file</li>
 * </ul>
 *
 * <p>Usage: {@code java -cp kahlua-runtime.jar:. ScriptCheck <dir-or-file>...}
 * Exit 0 clean, 1 if any ERROR was reported. Warnings never fail the build.
 */
public final class ScriptCheck {

    /**
     * Block types PZ recognises directly under a module. NOT a guess and NOT
     * harvested from what vanilla happens to use -- this is every scriptTag in
     * zombie.scripting.ScriptType, which is the enum ScriptModule's buckets
     * register themselves with, plus the two the engine handles outside that
     * registry: "imports" (special-cased in ScriptModule.CreateFromTokenPP)
     * and "template" (the isTemplate=true bucket prefix).
     *
     * <p>ScriptModule warns `unknown script object "%s"` for anything no
     * bucket claims -- into the debug log, where nobody looks. This turns that
     * into a build failure.
     *
     * <p>Compared case-insensitively on purpose: the enum spells one tag
     * "uniquerecipe" and scripts in the wild write "uniqueRecipe". Casing
     * pedantry would cost false positives without catching anything real, and
     * the failure this exists to stop (prose parsed as script) is not a
     * casing question.
     */
    private static final Set<String> KNOWN_BLOCKS = lower(
        "imports", "template",
        "entityComponent", "vehicle", "entity", "item", "recipe",
        "uniquerecipe", "evolvedrecipe", "fixing", "animationsMesh",
        "mannequin", "model", "spriteModel", "sound", "soundTimeline",
        "animation", "vehicleEngineRPM", "itemConfig", "xuiLayout",
        "xuiStyle", "xuiDefaultStyle", "xuiGlobalColors", "xuiSkin",
        "xuiConfig", "itemFilter", "craftRecipe", "fluidFilter",
        "stringList", "energy", "fluid", "physicsShape", "timedAction",
        "ragdoll", "physicsHitReaction", "clock",
        "character_trait_definition", "character_profession_definition"
    );

    /**
     * Types that must carry an id: these are referenced BY NAME from Lua and
     * from other scripts, so a nameless one is unreachable. Deliberately not
     * every type -- `imports` has no id by design, and template blocks carry a
     * compound header that is not an id in this sense.
     */
    private static final Set<String> REQUIRE_ID = lower(
        "item", "recipe", "craftRecipe", "evolvedrecipe", "uniquerecipe",
        "fluid", "energy", "timedAction"
    );

    /** Types where a repeat is more likely a slip than an intentional merge. */
    private static final Set<String> DUPE_WORTH_FLAGGING = lower(
        "item", "craftRecipe"
    );

    private static Set<String> lower(String... xs) {
        Set<String> s = new HashSet<>();
        for (String x : xs) s.add(x.toLowerCase(Locale.ROOT));
        return s;
    }

    private static String norm(String s) {
        return s == null ? "" : s.trim().toLowerCase(Locale.ROOT);
    }

    private static final List<String> errors = new ArrayList<>();
    private static final List<String> warnings = new ArrayList<>();

    private static void err(Path f, String msg) {
        errors.add("ERROR  " + f + ": " + msg);
    }

    private static void warn(Path f, String msg) {
        warnings.add("WARN   " + f + ": " + msg);
    }

    public static void main(String[] args) throws Exception {
        if (args.length == 0) {
            System.err.println("usage: ScriptCheck <dir-or-file>...");
            System.exit(2);
        }

        List<Path> files = new ArrayList<>();
        for (String a : args) collect(Paths.get(a), files);

        if (files.isEmpty()) {
            System.out.println("scriptcheck: no .txt script files found");
            return;
        }

        for (Path f : files) check(f);

        for (String w : warnings) System.out.println(w);
        for (String e : errors) System.out.println(e);

        System.out.println(String.format(
            "scriptcheck: %d file(s), %d error(s), %d warning(s)",
            files.size(), errors.size(), warnings.size()));

        if (!errors.isEmpty()) System.exit(1);
    }

    private static void collect(Path p, List<Path> out) throws IOException {
        if (Files.isRegularFile(p)) {
            if (p.toString().endsWith(".txt")) out.add(p);
            return;
        }
        if (!Files.isDirectory(p)) return;
        try (Stream<Path> s = Files.walk(p)) {
            out.addAll(s.filter(Files::isRegularFile)
                        .filter(x -> x.toString().endsWith(".txt"))
                        .sorted()
                        .collect(Collectors.toList()));
        }
    }

    private static void check(Path f) {
        String src;
        try {
            src = new String(Files.readAllBytes(f), StandardCharsets.UTF_8);
        } catch (IOException e) {
            err(f, "unreadable: " + e.getMessage());
            return;
        }

        if (src.trim().isEmpty()) return;

        // Brace balance first: the parser is lenient about imbalance and will
        // happily return a lopsided tree, so a raw count gives a clearer
        // message than "unknown block type" fifty lines further down.
        String stripped;
        try {
            stripped = ScriptParser.stripComments(src);
        } catch (Exception e) {
            err(f, "stripComments threw " + e);
            return;
        }
        long open = stripped.chars().filter(c -> c == '{').count();
        long close = stripped.chars().filter(c -> c == '}').count();
        if (open != close) {
            err(f, "unbalanced braces after comment stripping: " + open
                   + " '{' vs " + close + " '}'");
            return;
        }

        ScriptParser.Block root;
        try {
            root = ScriptParser.parse(stripped);
        } catch (Exception e) {
            err(f, "parser threw " + e);
            return;
        }

        if (root == null || root.children.isEmpty()) {
            err(f, "parsed to nothing — no module block was produced");
            return;
        }

        for (ScriptParser.Block top : root.children) {
            if (!"module".equals(top.type)) {
                err(f, "top-level block is '" + top.type + "', expected 'module'"
                       + hint(top.type));
                continue;
            }
            if (top.id == null || top.id.trim().isEmpty()) {
                err(f, "module has no name");
            }
            if (top.children.isEmpty()) {
                warn(f, "module '" + top.id + "' declares no blocks");
            }

            Map<String, String> seen = new HashMap<>();
            for (ScriptParser.Block b : top.children) {
                String type = b.type == null ? "" : b.type.trim();

                if (!KNOWN_BLOCKS.contains(norm(type))) {
                    err(f, "module '" + top.id + "' contains unknown block type '"
                           + type + "'" + (b.id != null ? " (id '" + b.id + "')" : "")
                           + hint(type));
                    continue;
                }

                if (REQUIRE_ID.contains(norm(type))
                        && (b.id == null || b.id.trim().isEmpty())) {
                    err(f, type + " block in module '" + top.id + "' has no id");
                    continue;
                }

                // Repeated blocks are a WARNING, never an error, and only for
                // the two types where a copy-paste slip is plausible.
                //
                // PZ MERGES repeated bodies onto one object rather than
                // replacing -- that is what makes thin targeted overrides work,
                // and it is a technique we use deliberately. Vanilla leans on
                // it too: `template vehicle`, `fixing Fix` and several sounds
                // repeat inside a single file, which made an earlier cut of
                // this check fail on 65 of the game's own files. When the
                // engine's own content fails your linter, the linter is wrong.
                if (DUPE_WORTH_FLAGGING.contains(norm(type)) && b.id != null) {
                    String key = norm(type) + " " + b.id;
                    if (seen.put(key, key) != null) {
                        warn(f, "repeated " + type + " '" + b.id + "' in module '"
                                + top.id + "' -- bodies MERGE, so this is legal;"
                                + " flagging in case it was a copy-paste");
                    }
                }
            }
        }
    }

    /**
     * The failure mode is confusing enough on its own that a bare "unknown
     * block type 'which'" sends you looking for a typo. Say what actually
     * happened when the evidence points at a line comment.
     */
    private static String hint(String type) {
        if (type == null) return "";
        return "  (if this looks like prose, a '//' line comment is being parsed"
             + " as script -- PZ strips /* */ ONLY)";
    }
}
