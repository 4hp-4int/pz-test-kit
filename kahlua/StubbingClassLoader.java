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

    @Override
    protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
        if (name.startsWith("zombie.")) {
            synchronized (getClassLoadingLock(name)) {
                Class<?> c = findLoadedClass(name);
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
