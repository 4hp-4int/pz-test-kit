import com.sun.jna.Callback;
import com.sun.jna.CallbackReference;
import com.sun.jna.Library;
import com.sun.jna.Native;
import com.sun.jna.Pointer;
import com.sun.jna.WString;
import com.sun.jna.ptr.IntByReference;
import com.sun.jna.ptr.LongByReference;

/**
 * A virtual clock for ONE native library (PopSim: PZPopMan64.dll).
 *
 * The population library reads real time (QueryPerformanceCounter,
 * GetTickCount64, GetSystemTimeAsFileTime: its only time imports, all from
 * KERNEL32; the CRT is linked in statically). Fast-forwarding game time while
 * it reads the wall clock made cell loading and sound handling race (the same
 * noise drew 0 or 240 zombies run to run). This patches those three entries
 * of that library's import address table to callbacks answering SousVide's
 * virtual time, so the library sees time pass exactly as the simulation steps
 * it. Nothing else in the process is touched.
 *
 * Compiled at run time against projectzomboid.jar (JNA ships inside it), by
 * PopSim; it is not part of the kit's own build.
 */
public final class PopClock {
    private PopClock() { }

    public interface QpcFn extends Callback { int invoke(Pointer out); }
    public interface TickFn extends Callback { long invoke(); }
    public interface FileTimeFn extends Callback { void invoke(Pointer out); }

    interface K32 extends Library {
        Pointer GetModuleHandleW(WString name);
        boolean VirtualProtect(Pointer addr, long size, int newProtect, IntByReference oldProtect);
        boolean QueryPerformanceFrequency(LongByReference freq);
        boolean QueryPerformanceCounter(LongByReference count);
        void GetSystemTimeAsFileTime(LongByReference fileTime);
    }

    private static volatile long nanos;   // virtual time since install
    private static long freq, qpc0, ft0, tick0;

    // strong references: a collected callback would leave the table pointing at freed code
    private static final QpcFn QPC = out -> { out.setLong(0, PopClock.qpc0 + (long) ((double) nanos * freq / 1e9)); return 1; };
    private static final TickFn TICK = () -> PopClock.tick0 + nanos / 1_000_000L;
    private static final FileTimeFn FILETIME = out -> out.setLong(0, PopClock.ft0 + nanos / 100L);

    /** Patches the library's imports. Returns null, or what went wrong. */
    public static String install(String dllName) {
        try {
            K32 k = Native.load("kernel32", K32.class);
            LongByReference r = new LongByReference();
            k.QueryPerformanceFrequency(r); freq = r.getValue();
            // a FIXED epoch (popsim.epoch seconds, default one hour of uptime;
            // file time 2026-01-01): the library seeds from the clock, so a
            // fixed start makes a population run repeatable
            long epoch = Long.getLong("popsim.epoch", 3600L);
            qpc0 = epoch * freq;
            tick0 = epoch * 1000L;
            ft0 = 134_116_992_000_000_000L + epoch * 10_000_000L;
            Pointer base = k.GetModuleHandleW(new WString(dllName));
            if (base == null) return dllName + " is not loaded";
            int e = base.getInt(0x3c);
            int opt = e + 24;
            if ((base.getShort(opt) & 0xffff) != 0x20b) return "not a PE32+ image";
            int importRva = base.getInt(opt + 112 + 8);
            int patched = 0;
            for (int d = importRva; ; d += 20) {
                int oft = base.getInt(d), nameRva = base.getInt(d + 12), ft = base.getInt(d + 16);
                if (nameRva == 0) break;
                if (!base.getString(nameRva).equalsIgnoreCase("KERNEL32.dll")) continue;
                int names = oft != 0 ? oft : ft;
                for (int i = 0; ; i++) {
                    long thunk = base.getLong(names + 8L * i);
                    if (thunk == 0) break;
                    if (thunk < 0) continue;   // by ordinal
                    String fn = base.getString((thunk & 0x7fffffffL) + 2);
                    Callback cb = switch (fn) {
                        case "QueryPerformanceCounter" -> QPC;
                        case "GetTickCount64" -> TICK;
                        case "GetSystemTimeAsFileTime" -> FILETIME;
                        default -> null;
                    };
                    if (cb == null) continue;
                    Pointer slot = base.share(ft + 8L * i);
                    IntByReference old = new IntByReference();
                    if (!k.VirtualProtect(slot, 8, 0x04, old)) return "VirtualProtect failed for " + fn;
                    slot.setPointer(0, CallbackReference.getFunctionPointer(cb));
                    k.VirtualProtect(slot, 8, old.getValue(), new IntByReference());
                    patched++;
                }
            }
            return patched == 3 ? null : "patched " + patched + " of 3 clock imports";
        } catch (Throwable t) {
            return t.toString();
        }
    }

    public static void advance(long ns) { if (ns > 0) nanos += ns; }
    public static long now() { return nanos; }
}
