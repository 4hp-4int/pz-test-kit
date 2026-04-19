import java.io.File;
import java.lang.reflect.Method;
import java.net.URL;
import java.nio.file.Path;
import java.nio.file.Paths;

/**
 * PZ Test Kit — Launcher
 * =======================
 * Builds a StubbingClassLoader over the full classpath (kahlua-runtime.jar,
 * stubs/, current dir) so that when Kahlua's VM classes reference zombie.*
 * at runtime, resolution routes through our synthetic-class generator. Then
 * loads KahluaTestRunner through that loader and invokes main(args).
 *
 * Use as the main class: `java -cp kahlua-runtime.jar;stubs;. PZTestKitLauncher <mod_root> [...]`
 * (Only this class needs to be on the system classpath — the launcher builds
 * the real classpath for everything else.)
 */
public class PZTestKitLauncher {

    public static void main(String[] args) throws Exception {
        // Build classpath URLs from the same classpath this launcher was invoked with.
        String cp = System.getProperty("java.class.path");
        String sep = File.pathSeparator;
        String[] entries = cp.split(java.util.regex.Pattern.quote(sep));
        URL[] urls = new URL[entries.length];
        for (int i = 0; i < entries.length; i++) {
            Path p = Paths.get(entries[i]).toAbsolutePath();
            urls[i] = p.toUri().toURL();
        }

        StubbingClassLoader loader = new StubbingClassLoader(urls, PZTestKitLauncher.class.getClassLoader().getParent());

        // Set this loader as the context for the current thread so any getContextClassLoader()
        // calls from within Kahlua's VM also hit our stubbing path.
        Thread.currentThread().setContextClassLoader(loader);

        Class<?> runner = Class.forName("KahluaTestRunner", true, loader);
        Method main = runner.getMethod("main", String[].class);
        main.invoke(null, (Object) args);
    }
}
