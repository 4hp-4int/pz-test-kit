import java.net.URL;
import java.net.URLClassLoader;
import java.util.Arrays;

/**
 * PZ Test Kit — Stubbing ClassLoader
 * ===================================
 * The Kahlua runtime jar was compiled against PZ's full Java codebase, so its
 * constant pool references hundreds of zombie.* classes (LuaManager, DebugLog,
 * IsoGameCharacter, etc.). Most of these are never actually invoked during
 * test execution — they're dead references guarded by `Core.debug = false`
 * short-circuits — but the JVM still resolves class references lazily, and if
 * a class is missing, throws NoClassDefFoundError.
 *
 * Rather than shipping 180+ hand-written .java stubs, this classloader
 * generates minimal empty classes on demand for any `zombie.*` name that
 * isn't found on the real classpath.
 *
 * CRITICAL: This loader MUST be the one that loaded kahlua-runtime.jar so
 * that when its classes reference zombie.*, resolution routes through here.
 * The launcher builds this loader with the full classpath and loads
 * KahluaTestRunner through it.
 */
public class StubbingClassLoader extends URLClassLoader {

    public StubbingClassLoader(URL[] urls, ClassLoader parent) {
        super(urls, parent);
    }

    /**
     * Every zombie.* class that got an EMPTY synthesized body, in load order.
     * Most are dead constant-pool references resolved at boot; one resolved
     * while tests run is a fidelity hole -- real code reached a class the
     * harness doesn't have (GameVersion.parse -> PZMath was one). Read by
     * KahluaTestRunner --fidelity through reflection: the runner is loaded BY
     * this loader, so its own StubbingClassLoader type is a different class.
     */
    public final java.util.Set<String> synthesized =
        java.util.Collections.synchronizedSet(new java.util.LinkedHashSet<>());

    /**
     * Engine mode (EngineBridge): attach a jar — projectzomboid.jar — at
     * runtime. Everything already on the classpath (the runtime jar's baked
     * stubs, the stubs/ dir) keeps overriding the real game classes, which
     * are consulted only after it (findClass / findResource below); the
     * synthetic-stub fallback still absorbs anything the jar doesn't have.
     *
     * Since 42.22 the jar is signed and a URL-loaded class carries its jar's 
     * signer certificates. The JVM requires every class of a package to share
     * one signer set, so the classes are defined from the jar's bytes
     * without certificates instead, like the unsigned jars before 42.22.
     */
    public void addJar(URL url) {
        try {
            realJar = new java.util.jar.JarFile(new java.io.File(url.toURI()));
            realJarUrl = url;
        } catch (Exception ignored) {
            realJar = null;
            realJarUrl = null;
            super.addURL(url);
        }
    }

    /** The game jar, once engine mode attaches it (see addJar). */
    private java.util.jar.JarFile realJar;
    private URL realJarUrl;

    /** Defines a class from the game jar's bytes, unsigned (see addJar). Null when the jar lacks it. */
    private Class<?> defineUnsigned(String name) {
        if (realJar == null) return null;
        try {
            java.util.jar.JarEntry e = realJar.getJarEntry(name.replace('.', '/') + ".class");
            if (e == null) return null;
            byte[] bytes;
            try (java.io.InputStream in = realJar.getInputStream(e)) { bytes = in.readAllBytes(); }
            return defineClass(name, bytes, 0, bytes.length);
        } catch (java.io.IOException ex) {
            return null;
        }
    }

    /** Classpath first, then the game jar. */
    @Override
    protected Class<?> findClass(String name) throws ClassNotFoundException {
        try {
            return super.findClass(name);
        } catch (ClassNotFoundException e) {
            Class<?> c = defineUnsigned(name);
            if (c != null) return c;
            throw e;
        }
    }

    /** Game-jar resources (scripts, service files) stay reachable after the classpath's. */
    @Override
    public URL findResource(String name) {
        URL u = super.findResource(name);
        if (u != null || realJar == null || realJar.getJarEntry(name) == null) return u;
        return gameJarResource(name);
    }

    /** jar:<game jar>!/<name>, the entry name percent-encoded; null if it can't be formed. */
    private URL gameJarResource(String name) {
        try {
            String entry = new java.net.URI(null, null, "/" + name, null).getRawPath();
            return java.net.URI.create("jar:" + realJarUrl + "!" + entry).toURL();
        } catch (java.net.URISyntaxException | java.net.MalformedURLException | IllegalArgumentException ex) {
            return null;
        }
    }

    @Override
    public java.util.Enumeration<URL> findResources(String name) throws java.io.IOException {
        java.util.List<URL> out = java.util.Collections.list(super.findResources(name));
        if (realJar != null && realJar.getJarEntry(name) != null) {
            URL u = gameJarResource(name);
            if (u != null) out.add(u);
        }
        return java.util.Collections.enumeration(out);
    }

    /**
     * Packages whose REAL classes win over stubs once the game jar is attached.
     * Their stubs exist only so the non-engine harness (no PZ install) can
     * load the Kahlua runtime; in engine mode real game code reaches deep into
     * them -- character construction reads dozens of DebugOptions groups
     * (character.debug.*, cheat.player.*, terrain.renderTiles.*) that a
     * hand-kept stub would have to grow field by field.
     */
    private static final String[] PREFER_REAL = { "zombie.debug." };

    private Class<?> defineFromRealJar(String name) {
        for (String p : PREFER_REAL) {
            if (name.startsWith(p)) return defineUnsigned(name);
        }
        return null;
    }

    @Override
    protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
        if (name.startsWith("zombie.")) {
            synchronized (getClassLoadingLock(name)) {
                Class<?> c = findLoadedClass(name);
                if (c == null) {
                    c = defineFromRealJar(name);
                }
                if (c == null) {
                    // Try real stubs on classpath first
                    try {
                        c = findClass(name);
                    } catch (ClassNotFoundException e) {
                        // Fall through to synthetic stub
                    }
                    if (c == null) {
                        byte[] bytes = generateEmptyClass(name);
                        c = defineClass(name, bytes, 0, bytes.length);
                        synthesized.add(name);
                    }
                }
                if (resolve) resolveClass(c);
                return c;
            }
        }
        return super.loadClass(name, resolve);
    }

    /**
     * Hand-rolled bytecode for an empty public class.
     * Java 17 target (major = 61).
     */
    private static byte[] generateEmptyClass(String dottedName) {
        String slashedName = dottedName.replace('.', '/');
        byte[] nameBytes = slashedName.getBytes();
        byte[] superBytes = "java/lang/Object".getBytes();

        int cpSize =
            (1 + 2) + (1 + 2) +
            (1 + 2 + nameBytes.length) +
            (1 + 2 + superBytes.length);

        int total = 4 + 2 + 2 + 2 + cpSize + 2 + 2 + 2 + 2 + 2 + 2 + 2;
        byte[] out = new byte[total];
        int i = 0;

        // magic CAFEBABE
        out[i++] = (byte)0xCA; out[i++] = (byte)0xFE; out[i++] = (byte)0xBA; out[i++] = (byte)0xBE;
        // minor = 0
        out[i++] = 0; out[i++] = 0;
        // major = 61 (Java 17)
        out[i++] = 0; out[i++] = 0x3D;
        // constant_pool_count = 5 (count is entries + 1)
        out[i++] = 0; out[i++] = 5;

        // #1 Class tag(7) name_index=3
        out[i++] = 7; out[i++] = 0; out[i++] = 3;
        // #2 Class tag(7) name_index=4
        out[i++] = 7; out[i++] = 0; out[i++] = 4;
        // #3 Utf8 <name>
        out[i++] = 1;
        out[i++] = (byte)((nameBytes.length >> 8) & 0xFF);
        out[i++] = (byte)(nameBytes.length & 0xFF);
        System.arraycopy(nameBytes, 0, out, i, nameBytes.length);
        i += nameBytes.length;
        // #4 Utf8 java/lang/Object
        out[i++] = 1;
        out[i++] = (byte)((superBytes.length >> 8) & 0xFF);
        out[i++] = (byte)(superBytes.length & 0xFF);
        System.arraycopy(superBytes, 0, out, i, superBytes.length);
        i += superBytes.length;

        // access_flags = ACC_PUBLIC | ACC_SUPER = 0x0021
        out[i++] = 0; out[i++] = 0x21;
        // this_class = #1
        out[i++] = 0; out[i++] = 1;
        // super_class = #2
        out[i++] = 0; out[i++] = 2;
        // interfaces_count = 0
        out[i++] = 0; out[i++] = 0;
        // fields_count = 0
        out[i++] = 0; out[i++] = 0;
        // methods_count = 0
        out[i++] = 0; out[i++] = 0;
        // attributes_count = 0
        out[i++] = 0; out[i++] = 0;

        return Arrays.copyOf(out, i);
    }
}
